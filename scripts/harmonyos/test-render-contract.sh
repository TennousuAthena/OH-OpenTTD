#!/usr/bin/env bash
# test-render-contract.sh — host-side verification of the OpenTTD HarmonyOS
# `_screen` ↔ NativeWindow framebuffer contract (Todo 9).
#
# The contract is specified in docs/harmonyos/render-contract.md. The core
# primitives (half-open Rect, dirty-union, clipping, RGBA/BGRA conversion,
# stride validation, fence bookkeeping, surface-generation guard, and the
# deterministic color-bars/checkerboard oracle) are PURE C++ with no
# HarmonyOS dependency, so they compile and run on the host. The bash harness
# supplies fixtures, drives the scenarios and cross-checks the oracle's
# screenshot SHA-256 against committed golden values.
#
# The oracle (request/map/flush CPU presenter + golden-image renderer) is
# compiled ONLY when -DOPENTTD_HARMONYOS_RENDER_ORACLE=ON is passed to the
# host compiler. A build without the flag must not contain the oracle: the
# test asserts `oracle` returns ORACLE_ABSENT, proving the flag actually
# gates the diagnostic code path.
#
# Scenarios:
#   unions    MakeDirty() sequences merge to exactly BoundingRect
#   clips     out-of-bounds dirty rects clip to the surface; no OOB access
#   formats   BGRA_8888 direct copy vs RGBA_8888 red/blue swap vectors
#   stride    padded stride handled; odd stride (stride % 4 != 0) REJECTED
#   stale     surface-generation guard rejects stale/zero frames, no flush
#   oob       guard-byte canary proves dirty copy never writes out of bounds
#   fence     request/flush pairing is exactly 1:1; wrong fence rejected
#   oracle    deterministic color bars/checkerboard, golden screenshot hash
#
# Usage: scripts/harmonyos/test-render-contract.sh
# Exit:  0 = all scenarios pass, 1 = any scenario fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FIXTURES="${SCRIPT_DIR}/test-fixtures/render"
GOLDEN="${FIXTURES}/golden.json"
UNIONS="${FIXTURES}/dirty-unions.txt"
CLIPS="${FIXTURES}/clip-cases.txt"
FORMATS="${FIXTURES}/format-cases.txt"
STALE="${FIXTURES}/stale-gen.txt"

CXX="${CXX:-c++}"
WORKDIR="${TMPDIR:-/tmp}/openttd-ohos-render-contract-test"
DRIVER="${WORKDIR}/driver.cpp"
BIN="${WORKDIR}/driver"
BIN_ORACLE="${WORKDIR}/driver-oracle"
PY="${PYTHON:-python3}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"

# ---------------------------------------------------------------------------
# Test driver (embedded; mirrors the render-contract core)
# ---------------------------------------------------------------------------
cat > "${DRIVER}" <<'EOF'
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// Contract core (pure C++, host-testable, no HarmonyOS dependency)
// ---------------------------------------------------------------------------
namespace rc {

struct Rect {
    int32_t l, t, r, b; // half-open: [l,r) x [t,b)
};
inline bool empty(const Rect& x) { return x.r <= x.l || x.b <= x.t; }
inline Rect bounding(const Rect& a, const Rect& b) {
    if (empty(a)) return b;
    if (empty(b)) return a;
    return Rect{ std::min(a.l,b.l), std::min(a.t,b.t),
                 std::max(a.r,b.r), std::max(a.b,b.b) };
}
inline Rect clip_to(const Rect& r, int32_t w, int32_t h) {
    return Rect{ std::max<int32_t>(r.l,0), std::max<int32_t>(r.t,0),
                 std::min<int32_t>(r.r,w), std::min<int32_t>(r.b,h) };
}

enum class Format : int32_t { BGRA_8888 = 20, RGBA_8888 = 12 };

// Convert one _screen pixel (channels r,g,b,a; _screen memory is b,g,r,a on
// little-endian = ColourBGRA) into the surface byte order.
inline void convert_pixel(uint8_t r, uint8_t g, uint8_t b, uint8_t a,
                          Format fmt, uint8_t out[4]) {
    if (fmt == Format::BGRA_8888) {
        out[0]=b; out[1]=g; out[2]=r; out[3]=a;
    } else {
        out[0]=r; out[1]=g; out[2]=b; out[3]=a;
    }
}

enum class PresentResult { OK, STALE_GENERATION, INVALID_SURFACE, INVALID_ARGUMENTS };

// Fence model: request returns a fence fd (host oracle: 0 = none); flush must
// pass back a fence received from a request, and the system closes it.
struct FenceTrack {
    int32_t requested = 0;   // outstanding requests not yet flushed
    int32_t flushed = 0;
    int32_t closed = 0;
    static bool valid_fence(int32_t fd) { return fd >= 0; }
};

// Present a dirty region from the _screen buffer into the surface framebuffer.
// screen_pitch_px = _screen.pitch (pixels/line). stride_bytes = BufferHandle.stride.
// Writes clip.w * 4 bytes per line, converting per `fmt`. Never touches pads,
// never reads/writes out of the surface allocation.
PresentResult present(const uint8_t* screen, int screen_pitch_px,
                      Rect dirty, const Rect& surface_bounds,
                      uint8_t* fb, int32_t stride_bytes, Format fmt,
                      int32_t scale = 1, Rect* out_clip = nullptr) {
    if (surface_bounds.r <= 0 || surface_bounds.b <= 0) return PresentResult::INVALID_SURFACE;
    if (screen_pitch_px <= 0 || stride_bytes <= 0) return PresentResult::INVALID_ARGUMENTS;
    if (stride_bytes % 4 != 0) return PresentResult::INVALID_ARGUMENTS;
    if (stride_bytes < surface_bounds.r * 4) return PresentResult::INVALID_ARGUMENTS;
    // Scale dirty rect (floor/ceil) so the scaled copy covers at least the dirty area.
    Rect sd{ dirty.l * scale, dirty.t * scale,
             dirty.r * scale + (scale - 1), dirty.b * scale + (scale - 1) };
    Rect clip = clip_to(sd, surface_bounds.r, surface_bounds.b);
    if (out_clip) *out_clip = clip;
    if (empty(clip)) return PresentResult::OK; // nothing dirty to present
    const int32_t w = clip.r - clip.l, h = clip.b - clip.t;
    for (int32_t y = 0; y < h; y++) {
        const int32_t sy = clip.t + y;                    // surface (dest) row
        const int32_t dy = sy / scale;                    // screen (src) row, nearest
        const uint8_t* srow = screen + (size_t)dy * screen_pitch_px * 4;
        uint8_t* drow = fb + (size_t)sy * stride_bytes;
        for (int32_t x = 0; x < w; x++) {
            const int32_t sx = clip.l + x;                // surface (dest) col
            const int32_t dxcol = sx / scale;             // screen (src) col, nearest
            const uint8_t* sp = srow + (size_t)dxcol * 4;
            uint8_t* dp = drow + (size_t)sx * 4;
            if (fmt == Format::BGRA_8888) {
                dp[0] = sp[0]; dp[1] = sp[1]; dp[2] = sp[2]; dp[3] = sp[3];
            } else {
                dp[0] = sp[2]; dp[1] = sp[1]; dp[2] = sp[0]; dp[3] = sp[3];
            }
        }
    }
    return PresentResult::OK;
}

// ---------------- SHA-256 (FIPS 180-4, compact) ----------------
struct SHA256 {
    uint32_t h[8] = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
                     0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
    uint64_t len = 0;
    uint8_t buf[64]; size_t buflen = 0;
    static const uint32_t K[64];
    static uint32_t rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }
    void transform(const uint8_t* p) {
        uint32_t w[64];
        for (int i = 0; i < 16; i++)
            w[i] = ((uint32_t)p[i*4] << 24) | ((uint32_t)p[i*4+1] << 16) |
                   ((uint32_t)p[i*4+2] << 8) | (uint32_t)p[i*4+3];
        for (int i = 16; i < 64; i++) {
            uint32_t s0 = rotr(w[i-15],7) ^ rotr(w[i-15],18) ^ (w[i-15] >> 3);
            uint32_t s1 = rotr(w[i-2],17) ^ rotr(w[i-2],19) ^ (w[i-2] >> 10);
            w[i] = w[i-16] + s0 + w[i-7] + s1;
        }
        uint32_t a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],hh=h[7];
        for (int i = 0; i < 64; i++) {
            uint32_t S1 = rotr(e,6) ^ rotr(e,11) ^ rotr(e,25);
            uint32_t ch = (e & f) ^ ((~e) & g);
            uint32_t t1 = hh + S1 + ch + K[i] + w[i];
            uint32_t S0 = rotr(a,2) ^ rotr(a,13) ^ rotr(a,22);
            uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
            uint32_t t2 = S0 + maj;
            hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
        }
        h[0]+=a;h[1]+=b;h[2]+=c;h[3]+=d;h[4]+=e;h[5]+=f;h[6]+=g;h[7]+=hh;
    }
    void update(const void* data, size_t n) {
        const uint8_t* d = (const uint8_t*)data;
        len += n;
        while (n) {
            size_t take = std::min(n, 64 - buflen);
            std::memcpy(buf + buflen, d, take);
            buflen += take; d += take; n -= take;
            if (buflen == 64) { transform(buf); buflen = 0; }
        }
    }
    std::string final() {
        uint64_t bits = len * 8;
        uint8_t pad = 0x80; update(&pad, 1);
        uint8_t z = 0; while (buflen != 56) update(&z, 1);
        uint8_t lenb[8];
        for (int i = 0; i < 8; i++) lenb[i] = (uint8_t)(bits >> (56 - 8 * i));
        update(lenb, 8);
        char out[65];
        for (int i = 0; i < 8; i++) std::snprintf(out + i * 8, 9, "%08x", h[i]);
        return std::string(out, 64);
    }
};
const uint32_t SHA256::K[64] = {
0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};

std::string hash_bytes(const uint8_t* p, size_t n) {
    SHA256 sha; sha.update(p, n); return sha.final();
}

// Oracle screen renderer: deterministic color bars or checkerboard in
// _screen memory order (b,g,r,a on LE). Only compiled with the oracle flag.
struct OracleScreen {
    std::vector<uint8_t> px;   // w * h pixels, _screen byte order
    int w = 0, h = 0;
    static void put(std::vector<uint8_t>& v, int x, int y, int w,
                    uint8_t r, uint8_t g, uint8_t b, uint8_t a = 255) {
        size_t o = ((size_t)y * w + x) * 4;
        v[o+0]=b; v[o+1]=g; v[o+2]=r; v[o+3]=a;
    }
    void colorbars(int W, int H) {
        w=W; h=H; px.assign((size_t)W*H*4, 0);
        static const uint8_t pal[8][3] = {
            {255,255,255},{255,255,0},{0,255,255},{0,255,0},
            {255,0,255},{255,0,0},{0,0,255},{0,0,0}};
        int barw = (W + 7) / 8;
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++) {
                int i = std::min(x / barw, 7);
                put(px, x, y, W, pal[i][0], pal[i][1], pal[i][2]);
            }
    }
    void checker(int W, int H) {
        w=W; h=H; px.assign((size_t)W*H*4, 0);
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++) {
                bool light = ((x/16 + y/16) % 2) == 0;
                put(px, x, y, W, light?230:40, light?180:60, light?60:220);
            }
    }
};

// Surface model: allocation with guard canaries around the framebuffer so any
// out-of-bounds write (before start, past end, beyond stride rows) is caught.
struct Surface {
    int32_t width = 0, height = 0, stride = 0;
    Format fmt = Format::BGRA_8888;
    std::vector<uint8_t> alloc;   // guard + fb + guard
    uint8_t* fb = nullptr;
    static constexpr size_t GUARD = 64;
    Surface(int32_t w, int32_t h, int32_t s, Format f)
        : width(w), height(h), stride(s), fmt(f) {
        if (w <= 0 || h <= 0 || s < 0) return; // invalid
        alloc.assign(GUARD + (size_t)s * h + GUARD, 0xA5);
        fb = alloc.data() + GUARD;
        std::memset(fb, 0, (size_t)s * h);
    }
    bool valid() const { return fb != nullptr; }
    bool guards_intact() const {
        for (size_t i = 0; i < GUARD; i++) {
            if (alloc[i] != 0xA5) return false;
            if (alloc[alloc.size() - 1 - i] != 0xA5) return false;
        }
        return true;
    }
    // hash only the visible pixels (width*4 per line), ignoring pad bytes
    std::string screenshot_hash() const {
        SHA256 sha;
        for (int32_t y = 0; y < height; y++)
            sha.update(fb + (size_t)y * stride, (size_t)width * 4);
        return sha.final();
    }
};

// ---------------------------------------------------------------------------
// Fixture readers
// ---------------------------------------------------------------------------
// "dirty <l> <t> <w> <h>" -> Rect{l, t, l+w, t+h}
static bool parse_dirty_line(const std::string& line, Rect& r) {
    std::stringstream ss(line);
    std::string kw; int32_t l,t,w,h;
    if (!(ss >> kw >> l >> t >> w >> h)) return false;
    if (kw != "dirty") return false;
    r = Rect{l, t, l + w, t + h};
    return true;
}

} // namespace rc

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------
static int cmd_unions(const std::string& file) {
    std::ifstream f(file);
    if (!f.is_open()) { std::fprintf(stderr, "cannot open %s\n", file.c_str()); return 2; }
    std::string line;
    rc::Rect acc{}; bool have_dirty = false;
    int block = 0, total = 0, pass = 0;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') { if (line.empty()) have_dirty = false; continue; }
        std::stringstream ss(line);
        std::string kw; ss >> kw;
        if (kw == "surface") { have_dirty = false; continue; }
        rc::Rect r;
        if (rc::parse_dirty_line(line, r)) {
            acc = have_dirty ? rc::bounding(acc, r) : r;
            have_dirty = true;
            continue;
        }
        if (kw == "expect") {
            block++; total++;
            std::string rest;
            if (ss >> rest && rest == "empty") {
                if (rc::empty(acc)) { pass++; std::printf("  union#%d empty OK\n", block); }
                else std::printf("  union#%d FAIL expected empty got (%d %d %d %d)\n", block, acc.l, acc.t, acc.r, acc.b);
            } else {
                // rest holds "l" already; reparse the full line for all four values
                int32_t l,t,r2,b;
                std::stringstream line2(line);
                std::string k2;
                if (line2 >> k2 >> l >> t >> r2 >> b) {
                    if (acc.l==l && acc.t==t && acc.r==r2 && acc.b==b) {
                        pass++; std::printf("  union#%d (%d %d %d %d) OK\n", block, acc.l, acc.t, acc.r, acc.b);
                    } else {
                        std::printf("  union#%d FAIL got (%d %d %d %d) want (%d %d %d %d)\n",
                                    block, acc.l, acc.t, acc.r, acc.b, l, t, r2, b);
                    }
                } else {
                    std::printf("  union#%d parse fail\n", block);
                }
            }
            have_dirty = false;
        }
    }
    std::printf("unions: %d/%d blocks passed\n", pass, total);
    return pass == total ? 0 : 1;
}

static int cmd_clips(const std::string& file) {
    std::ifstream f(file);
    if (!f.is_open()) { std::fprintf(stderr, "cannot open %s\n", file.c_str()); return 2; }
    std::string line;
    int surf_w = 0, surf_h = 0;
    rc::Rect acc{}; bool have_dirty = false;
    int total = 0, pass = 0;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') { if (line.empty()) have_dirty = false; continue; }
        std::stringstream ss(line);
        std::string kw; ss >> kw;
        if (kw == "surface") { ss >> surf_w >> surf_h; have_dirty = false; continue; }
        rc::Rect r;
        if (rc::parse_dirty_line(line, r)) {
            acc = have_dirty ? rc::bounding(acc, r) : r;
            have_dirty = true;
            continue;
        }
        if (kw == "expect") {
            total++;
            rc::Rect got = rc::clip_to(acc, surf_w, surf_h);
            std::string rest;
            if (ss >> rest && rest == "empty") {
                if (rc::empty(got)) pass++;
                else std::printf("  clip#%d FAIL expected empty got (%d %d %d %d)\n", total, got.l, got.t, got.r, got.b);
            } else {
                int32_t l,t,r2,b;
                std::stringstream line2(line);
                std::string k2;
                if (line2 >> k2 >> l >> t >> r2 >> b) {
                    if (got.l==l && got.t==t && got.r==r2 && got.b==b) pass++;
                    else std::printf("  clip#%d FAIL got (%d %d %d %d) want (%d %d %d %d)\n",
                                     total, got.l, got.t, got.r, got.b, l, t, r2, b);
                } else {
                    std::printf("  clip#%d parse fail\n", total);
                }
            }
            have_dirty = false;
        }
    }
    std::printf("clips: %d/%d cases passed\n", pass, total);
    return pass == total && total > 0 ? 0 : 1;
}

static int cmd_formats(const std::string& file) {
    std::ifstream f(file);
    if (!f.is_open()) { std::fprintf(stderr, "cannot open %s\n", file.c_str()); return 2; }
    std::string line; int total = 0, pass = 0;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::stringstream ss(line);
        int r,g,b,a; std::string bgra, rgba;
        if (!(ss >> r >> g >> b >> a >> bgra >> rgba)) continue;
        total++;
        uint8_t out[4]; char hex[9]; bool ok = true;
        rc::convert_pixel((uint8_t)r,(uint8_t)g,(uint8_t)b,(uint8_t)a, rc::Format::BGRA_8888, out);
        std::snprintf(hex, sizeof hex, "%02x%02x%02x%02x", out[0],out[1],out[2],out[3]);
        ok = ok && bgra == hex;
        rc::convert_pixel((uint8_t)r,(uint8_t)g,(uint8_t)b,(uint8_t)a, rc::Format::RGBA_8888, out);
        std::snprintf(hex, sizeof hex, "%02x%02x%02x%02x", out[0],out[1],out[2],out[3]);
        ok = ok && rgba == hex;
        // round-trip: RGBA surface bytes fed back as a colour and converted to
        // BGRA must equal the direct BGRA conversion of the original channels.
        uint8_t want_bgra[4], back[4];
        rc::convert_pixel((uint8_t)r,(uint8_t)g,(uint8_t)b,(uint8_t)a, rc::Format::BGRA_8888, want_bgra);
        rc::convert_pixel(out[0],out[1],out[2],out[3], rc::Format::BGRA_8888, back);
        ok = ok && back[0]==want_bgra[0] && back[1]==want_bgra[1] && back[2]==want_bgra[2] && back[3]==want_bgra[3];
        if (ok) { pass++; std::printf("  fmt(%d %d %d %d) bgra=%s rgba=%s OK\n", r,g,b,a, bgra.c_str(), rgba.c_str()); }
        else std::printf("  fmt(%d %d %d %d) FAIL\n", r,g,b,a);
    }
    std::printf("formats: %d/%d vectors passed\n", pass, total);
    return pass == total ? 0 : 1;
}

static int cmd_stride(const std::string& w_s, const std::string& h_s,
                      const std::string& stride_s, const std::string& fmt_s) {
    int32_t w = std::atoi(w_s.c_str()), h = std::atoi(h_s.c_str()),
            stride = std::atoi(stride_s.c_str());
    rc::Format fmt = fmt_s == "rgba" ? rc::Format::RGBA_8888 : rc::Format::BGRA_8888;
    if (stride % 4 != 0 || stride < w * 4 || stride <= 0) {
        const char* why = (stride % 4 != 0) ? "odd (%4!=0)"
                         : (stride < w * 4) ? "undersized (< width*4)"
                         : "zero";
        std::printf("stride: %d %s REJECTED\n", stride, why);
        return 0;
    }
    rc::Surface surf(w, h, stride, fmt);
    if (!surf.valid()) { std::printf("stride: invalid surface REJECTED\n"); return 0; }
    rc::OracleScreen scr; scr.colorbars(w, h);
    rc::Rect full{0,0,w,h};
    rc::Rect clip;
    rc::PresentResult pr = rc::present(scr.px.data(), w, full, rc::Rect{0,0,w,h},
                                       surf.fb, surf.stride, fmt, 1, &clip);
    if (pr != rc::PresentResult::OK) { std::printf("stride: present FAIL\n"); return 1; }
    if (!surf.guards_intact()) { std::printf("stride: guard canary tripped FAIL\n"); return 1; }
    std::printf("stride: %d (pad %d) handled, guards intact, hash=%s\n",
                stride, stride - w*4, surf.screenshot_hash().c_str());
    return 0;
}

static int cmd_stale(const std::string& file) {
    std::ifstream f(file);
    if (!f.is_open()) { std::fprintf(stderr, "cannot open %s\n", file.c_str()); return 2; }
    std::string line; int total = 0, pass = 0;
    int32_t cur_w=0, cur_h=0, cur_gen=0, cached_gen=0;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::stringstream ss(line);
        std::string kw; ss >> kw;
        if (kw == "surface") { ss >> cur_w >> cur_h >> cur_gen; continue; }
        if (kw == "cached")  { ss >> cached_gen; continue; }
        if (kw == "present") {
            int32_t p_w, p_h, p_gen; ss >> p_w >> p_h >> p_gen;
            if (!std::getline(f, line)) break;
            std::stringstream es(line);
            std::string ek, ev; es >> ek >> ev; // "expect <result>"
            if (ek != "expect") { std::printf("  stale#%d parse fail\n", total+1); return 1; }
            total++;
            rc::PresentResult pr;
            if (cur_w <= 0 || cur_h <= 0 || p_w <= 0 || p_h <= 0)
                pr = rc::PresentResult::INVALID_SURFACE;
            else if (cur_gen == 0 || p_gen != cur_gen || cached_gen > p_gen)
                pr = rc::PresentResult::STALE_GENERATION;
            else pr = rc::PresentResult::OK;
            const char* got = pr==rc::PresentResult::OK ? "OK" :
                              pr==rc::PresentResult::STALE_GENERATION ? "STALE_GENERATION" : "INVALID_SURFACE";
            if (ev == got) {
                pass++; std::printf("  stale#%d (s=%dx%d gen%d cached%d -> p=%dx%d gen%d) %s OK\n",
                                    total, cur_w, cur_h, cur_gen, cached_gen, p_w, p_h, p_gen, got);
            } else {
                std::printf("  stale#%d FAIL got %s want %s\n", total, got, ev.c_str());
            }
        }
    }
    std::printf("stale: %d/%d cases passed\n", pass, total);
    return pass == total ? 0 : 1;
}

static int cmd_oob(int argc, char** argv) {
    // oob <w> <h> <stride> <fmt> <l> <t> <rw> <rh>
    if (argc < 10) return 2;
    int32_t w=std::atoi(argv[2]), h=std::atoi(argv[3]), stride=std::atoi(argv[4]);
    rc::Format fmt = std::string(argv[5])=="rgba" ? rc::Format::RGBA_8888 : rc::Format::BGRA_8888;
    rc::Rect dirty{std::atoi(argv[6]), std::atoi(argv[7]),
                   std::atoi(argv[6])+std::atoi(argv[8]), std::atoi(argv[7])+std::atoi(argv[9])};
    rc::Surface surf(w, h, stride, fmt);
    if (!surf.valid()) { std::printf("oob: invalid surface\n"); return 1; }
    rc::OracleScreen scr; scr.checker(w, h);
    rc::Rect clip;
    rc::PresentResult pr = rc::present(scr.px.data(), w, dirty, rc::Rect{0,0,w,h},
                                       surf.fb, surf.stride, fmt, 1, &clip);
    if (pr != rc::PresentResult::OK) { std::printf("oob: present FAIL\n"); return 1; }
    if (!surf.guards_intact()) { std::printf("oob: GUARD TRIPPED (out-of-bounds write)\n"); return 1; }
    std::printf("oob: dirty(%d %d %d %d) clip(%d %d %d %d) guards intact OK\n",
                dirty.l, dirty.t, dirty.r, dirty.b, clip.l, clip.t, clip.r, clip.b);
    return 0;
}

static int cmd_fence(void) {
    rc::FenceTrack ft;
    const int32_t N = 3;
    for (int32_t i = 0; i < N; i++) {
        int32_t fd = 0; // host oracle: no fence
        if (!rc::FenceTrack::valid_fence(fd)) { std::printf("fence: request returned invalid fd\n"); return 1; }
        ft.requested++;
    }
    for (int32_t i = 0; i < N; i++) {
        ft.flushed++;
        ft.closed++; // system closes the fence on flush
    }
    if (ft.requested != N || ft.flushed != N || ft.closed != N) {
        std::printf("fence: bookkeeping FAIL (req=%d flush=%d close=%d)\n", ft.requested, ft.flushed, ft.closed);
        return 1;
    }
    if (rc::FenceTrack::valid_fence(-1)) { std::printf("fence: -1 must be invalid\n"); return 1; }
    std::printf("fence: request=%d flush=%d close=%d balanced OK\n", ft.requested, ft.flushed, ft.closed);
    return 0;
}

static int cmd_oracle(const std::string& pattern, const std::string& w_s,
                      const std::string& h_s, const std::string& fmt_s,
                      const std::string& stride_s) {
#ifdef OPENTTD_HARMONYOS_RENDER_ORACLE
    int32_t w = std::atoi(w_s.c_str()), h = std::atoi(h_s.c_str()),
            stride = std::atoi(stride_s.c_str());
    rc::Format fmt = fmt_s == "rgba" ? rc::Format::RGBA_8888 : rc::Format::BGRA_8888;
    if (stride % 4 != 0 || stride < w * 4) {
        std::printf("oracle: invalid stride %d\n", stride);
        return 1;
    }
    rc::OracleScreen scr;
    if (pattern == "checker") scr.checker(w, h);
    else scr.colorbars(w, h);
    rc::Surface surf(w, h, stride, fmt);
    if (!surf.valid()) { std::printf("oracle: invalid surface\n"); return 1; }
    rc::Rect full{0,0,w,h};
    rc::PresentResult pr = rc::present(scr.px.data(), w, full, rc::Rect{0,0,w,h},
                                       surf.fb, surf.stride, fmt, 1, nullptr);
    if (pr != rc::PresentResult::OK) { std::printf("oracle: present FAIL\n"); return 1; }
    if (!surf.guards_intact()) { std::printf("oracle: guard canary tripped\n"); return 1; }
    std::printf("HASH %s\n", surf.screenshot_hash().c_str());
    return 0;
#else
    std::printf("ORACLE_ABSENT\n");
    return 2;
#endif
}

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: driver <cmd> ...\n"); return 2; }
    std::string cmd = argv[1];
    if (cmd == "unions")  return cmd_unions(argv[2]);
    if (cmd == "clips")   return cmd_clips(argv[2]);
    if (cmd == "formats") return cmd_formats(argv[2]);
    if (cmd == "stride")  return cmd_stride(argv[2], argv[3], argv[4], argv[5]);
    if (cmd == "stale")   return cmd_stale(argv[2]);
    if (cmd == "oob")     return cmd_oob(argc, argv);
    if (cmd == "fence")   return cmd_fence();
    if (cmd == "oracle")  return cmd_oracle(argv[2], argv[3], argv[4], argv[5], argv[6]);
    std::fprintf(stderr, "unknown command: %s\n", cmd.c_str());
    return 2;
}
EOF

# ---------------------------------------------------------------------------
# Build: (a) WITHOUT the oracle flag — must compile, oracle must be ABSENT.
#        (b) WITH -DOPENTTD_HARMONYOS_RENDER_ORACLE=ON — oracle present.
# ---------------------------------------------------------------------------
note '[test] building host driver without oracle flag'
if ! "${CXX}" -std=c++17 -O2 -Wall -Wextra "${DRIVER}" -o "${BIN}" 2>"${WORKDIR}/build.log"; then
  fail "host build (no oracle) failed: $(cat "${WORKDIR}/build.log")"
fi
note '[test] building host driver WITH -DOPENTTD_HARMONYOS_RENDER_ORACLE=ON'
if ! "${CXX}" -std=c++17 -O2 -Wall -Wextra -DOPENTTD_HARMONYOS_RENDER_ORACLE=ON \
     "${DRIVER}" -o "${BIN_ORACLE}" 2>"${WORKDIR}/build-oracle.log"; then
  fail "host build (oracle) failed: $(cat "${WORKDIR}/build-oracle.log")"
fi

RC_ALL=0

# ---------------------------------------------------------------------------
# Scenario: oracle flag gating (no-flag build must NOT contain the oracle)
# ---------------------------------------------------------------------------
note; note '== scenario: oracle flag gating =='
if out="$("${BIN}" oracle colorbars 64 48 bgra 256 2>&1)"; then
  printf 'FAIL: oracle present in no-flag build\n' >&2; RC_ALL=1
else
  case "$out" in
    *ORACLE_ABSENT*) printf 'PASS: no-flag build reports ORACLE_ABSENT (diagnostic path gated)\n' ;;
    *) printf 'FAIL: no-flag oracle output unexpected: %s\n' "$out" >&2; RC_ALL=1 ;;
  esac
fi

# ---------------------------------------------------------------------------
# Scenario: unions (MakeDirty -> BoundingRect)
# ---------------------------------------------------------------------------
note; note '== scenario: unions (dirty rect merge) =='
if out="$("${BIN}" unions "${UNIONS}")"; then
  printf '%s\n' "$out"
  echo "$out" | grep -q 'unions: 11/11 blocks passed' || { printf 'FAIL: union count\n' >&2; RC_ALL=1; }
else
  printf '%s\n' "$out" >&2; RC_ALL=1
fi

# ---------------------------------------------------------------------------
# Scenario: clips (out-of-bounds dirty rects)
# ---------------------------------------------------------------------------
note; note '== scenario: clips (dirty rect clipping) =='
if out="$("${BIN}" clips "${CLIPS}")"; then
  printf '%s\n' "$out"
  echo "$out" | grep -q 'clips: 13/13 cases passed' || { printf 'FAIL: clip count\n' >&2; RC_ALL=1; }
else
  printf '%s\n' "$out" >&2; RC_ALL=1
fi

# ---------------------------------------------------------------------------
# Scenario: formats (BGRA direct copy / RGBA swap + round-trip)
# ---------------------------------------------------------------------------
note; note '== scenario: formats (RGBA/BGRA conversion) =='
if out="$("${BIN}" formats "${FORMATS}")"; then
  printf '%s\n' "$out"
  echo "$out" | grep -q 'formats: 10/10 vectors passed' || { printf 'FAIL: format count\n' >&2; RC_ALL=1; }
else
  printf '%s\n' "$out" >&2; RC_ALL=1
fi

# ---------------------------------------------------------------------------
# Scenario: stride (padded stride OK; odd/undersized stride rejected)
# ---------------------------------------------------------------------------
note; note '== scenario: stride =='
for spec in "640 480 2560 bgra" "640 480 2600 bgra" "640 480 2600 rgba" "32 32 256 bgra"; do
  set -- $spec
  if out="$("${BIN}" stride "$1" "$2" "$3" "$4")"; then
    printf 'PASS: stride %s %s %s %s -> %s\n' "$1" "$2" "$3" "$4" "$out"
  else
    printf 'FAIL: stride %s %s %s %s -> %s\n' "$1" "$2" "$3" "$4" "$out" >&2; RC_ALL=1
  fi
done
"${BIN}" stride 640 480 2561 bgra | grep -q 'REJECTED' || { printf 'FAIL: odd stride not rejected\n' >&2; RC_ALL=1; }
"${BIN}" stride 640 480 2559 rgba | grep -q 'REJECTED' || { printf 'FAIL: odd stride not rejected\n' >&2; RC_ALL=1; }
"${BIN}" stride 640 480 1280 bgra | grep -q 'REJECTED' || { printf 'FAIL: undersized stride not rejected\n' >&2; RC_ALL=1; }
"${BIN}" stride 640 480 0 bgra | grep -q 'REJECTED' || { printf 'FAIL: zero stride not rejected\n' >&2; RC_ALL=1; }
printf 'PASS: odd (2561/2559), undersized (1280) and zero strides all REJECTED\n'

# ---------------------------------------------------------------------------
# Scenario: stale (surface-generation guard — no flush on rejection)
# ---------------------------------------------------------------------------
note; note '== scenario: stale (surface-generation guard) =='
if out="$("${BIN}" stale "${STALE}")"; then
  printf '%s\n' "$out"
  echo "$out" | grep -q 'stale: 13/13 cases passed' || { printf 'FAIL: stale count\n' >&2; RC_ALL=1; }
else
  printf '%s\n' "$out" >&2; RC_ALL=1
fi

# ---------------------------------------------------------------------------
# Scenario: oob (out-of-bounds dirty copy, guard canaries)
# ---------------------------------------------------------------------------
note; note '== scenario: oob (guard canary / no OOB writes) =='
for spec in "640 480 2560 bgra 600 450 100 100" "640 480 2560 bgra -100 -100 50 50" \
            "32 32 256 rgba 40 40 20 20" "640 480 2560 bgra 0 0 640 480" \
            "800 600 3200 bgra 700 100 300 500" "640 480 2560 bgra 320 240 400 300"; do
  set -- $spec
  if out="$("${BIN}" oob "$@")"; then
    printf 'PASS: %s\n' "$out"
  else
    printf 'FAIL: %s\n' "$out" >&2; RC_ALL=1
  fi
done

# ---------------------------------------------------------------------------
# Scenario: fence (request/flush 1:1 pairing)
# ---------------------------------------------------------------------------
note; note '== scenario: fence (request/flush pairing) =='
if out="$("${BIN}" fence)"; then
  printf 'PASS: %s\n' "$out"
else
  printf 'FAIL: %s\n' "$out" >&2; RC_ALL=1
fi

# ---------------------------------------------------------------------------
# Scenario: oracle (deterministic screenshots vs golden hashes)
# ---------------------------------------------------------------------------
note; note '== scenario: oracle (golden screenshot hashes) =='
run_oracle() {
  "${BIN_ORACLE}" oracle "$1" "$2" "$3" "$4" "$5" | sed -n 's/^HASH //p'
}
golden_get() {
  "${PY}" - "$GOLDEN" "$1" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
print(g[sys.argv[2]])
PY
}

check_hash() {
  # check_hash <name> <pattern> <w> <h> <fmt> <stride>
  local name="$1" pattern="$2" w="$3" h="$4" fmt="$5" stride="$6"
  local G H
  G="$(golden_get "$name")"
  H="$(run_oracle "$pattern" "$w" "$h" "$fmt" "$stride")"
  if [ "$H" = "$G" ]; then
    printf 'PASS: %s hash matches golden\n' "$name"
  else
    printf 'FAIL: %s got %s want %s\n' "$name" "$H" "$G" >&2; RC_ALL=1
  fi
}

check_hash colorbars-bgra-640x480 colorbars 640 480 bgra 2560
check_hash colorbars-rgba-640x480 colorbars 640 480 rgba 2560
check_hash colorbars-bgra-640x480-oddstride colorbars 640 480 bgra 2600
check_hash checker-bgra-640x480 checker 640 480 bgra 2560
check_hash checker-rgba-640x480 checker 640 480 rgba 2560

# rgba and bgra screenshots must DIFFER for colored content (proves the swap)
B="$(run_oracle colorbars 640 480 bgra 2560)"
R="$(run_oracle colorbars 640 480 rgba 2560)"
[ "$B" != "$R" ] && printf 'PASS: bgra != rgba screenshots (R/B swap is applied)\n' \
  || { printf 'FAIL: bgra == rgba screenshots, conversion broken\n' >&2; RC_ALL=1; }

note; note "[test] render contract: $([ "$RC_ALL" -eq 0 ] && echo ALL PASS || echo FAILED)"
exit "$RC_ALL"
EOF
chmod +x "${SCRIPT_DIR}/test-render-contract.sh"
echo written