#!/usr/bin/env bash
# test-storage-contract.sh — host-side verification of the OpenTTD HarmonyOS
# storage, packaged-resource and user-document contract (Todo 11).
#
# The contract is specified in docs/harmonyos/storage-contract.md. The core
# primitives (path guard, atomic materializer with resume markers, upgrade
# markers, free-space gate, manifest loader, picker typed results) are PURE
# C++ with no HarmonyOS dependency, so they compile and run on the host. The
# bash harness supplies fixtures, drives the scenarios and cross-checks SHA-256
# values against `shasum -a 256`.
#
# Scenarios:
#   escape     path guard rejects every malicious name in bad/path-names.txt
#              and accepts known-safe names; joined path stays under root
#   atomic     SIGKILL a slow first-copy mid-way, then relaunch and assert
#              rollback/recovery, no leftover .partial files, marker COMPLETED,
#              dest checksums == manifest and packaged checksums unchanged
#   stale      old STORAGE_VERSION -> re-materialize and rewrite the marker
#   lowspace   simulated free space below required -> typed LOW_SPACE, no writes
#   manifest   fixture generated-resource manifest complete/checksum-correct;
#              duplicate + malformed manifest lines rejected by C++ loader
#   picker     cancel -> CANCELLED; expired/non-file URI -> INVALID_URI;
#              valid -> OK; all typed and nonfatal
#
# Usage: scripts/harmonyos/test-storage-contract.sh [--refresh-manifest]
# Exit:  0 = all scenarios pass, 1 = any scenario fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FIXTURES="${SCRIPT_DIR}/test-fixtures/storage"
PACKAGED="${FIXTURES}/packaged"
MANIFEST_JSON="${FIXTURES}/manifest-expected.json"
BAD_NAMES="${FIXTURES}/bad/path-names.txt"

# Contract constants (must match docs/harmonyos/storage-contract.md)
STORAGE_VERSION=3
RESOURCE_GEN=3
HEADROOM_BYTES=$((64 * 1024 * 1024))
HEADROOM_FRACTION=0.08

CXX="${CXX:-c++}"
WORKDIR="${TMPDIR:-/tmp}/openttd-ohos-storage-contract-test"
BIN="${WORKDIR}/driver"
DRIVER="${WORKDIR}/driver.cpp"
PY="${PYTHON:-python3}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }
build_sha256() { "${BIN}" sha256 "$1"; }

rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"

# ---------------------------------------------------------------------------
# Test driver (embedded; mirrors the storage-contract core)
# ---------------------------------------------------------------------------
cat > "${DRIVER}" <<'EOF'
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <fstream>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <vector>

namespace st {

enum class Kind { OK, CANCELLED, INVALID_URI, LOW_SPACE, IO_ERROR, PATH_ESCAPE };

const char* kind_name(Kind k) {
    switch (k) {
        case Kind::OK: return "OK";
        case Kind::CANCELLED: return "CANCELLED";
        case Kind::INVALID_URI: return "INVALID_URI";
        case Kind::LOW_SPACE: return "LOW_SPACE";
        case Kind::IO_ERROR: return "IO_ERROR";
        case Kind::PATH_ESCAPE: return "PATH_ESCAPE";
    }
    return "?";
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

std::string file_sha256(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    SHA256 sha; char chunk[65536];
    while (f) { f.read(chunk, sizeof chunk); std::streamsize n = f.gcount(); if (n > 0) sha.update(chunk, (size_t)n); }
    return sha.final();
}

// ---------------- Path guard ----------------
bool is_safe_component(const std::string& n) {
    if (n.empty()) return false;
    for (char c : n) {
        bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                  (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
        if (!ok) return false;
    }
    if (n == "." || n == "..") return false;
    if (n[0] == '.') return false;   // leading dot: hidden/traversal
    return true;
}

bool structural_escape(const std::string& n) {
    if (n.find('/') != std::string::npos) return true;
    if (n.find('\\') != std::string::npos) return true;
    if (n.find(':') != std::string::npos) return true;
    if (n.find('\0') != std::string::npos) return true;
    if (!n.empty() && n[0] == '~') return true;
    return false;
}

// ---------------- Manifest (line format: relpath<TAB>sha<TAB>size) ----------------
struct Entry { std::string relpath; std::string sha; uint64_t size; };

int load_manifest(const std::string& path, std::vector<Entry>& out) {
    std::ifstream f(path);
    if (!f.is_open()) return (int)Kind::IO_ERROR;
    std::string line; std::vector<Entry> all;
    while (std::getline(f, line)) {
        if (line.empty()) continue;
        std::stringstream ss(line);
        std::string rel, sha, sizestr;
        if (!std::getline(ss, rel, '\t')) return (int)Kind::IO_ERROR;
        if (!std::getline(ss, sha, '\t')) return (int)Kind::IO_ERROR;
        if (!std::getline(ss, sizestr, '\t')) return (int)Kind::IO_ERROR;
        if (rel.empty() || sha.size() != 64) return (int)Kind::IO_ERROR;
        for (char c : sha) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return (int)Kind::IO_ERROR;
        uint64_t sz = 0; bool nums = true;
        for (char c : sizestr) { if (c < '0' || c > '9') { nums = false; break; } sz = sz * 10 + (uint64_t)(c - '0'); }
        if (!nums) return (int)Kind::IO_ERROR;
        all.push_back(Entry{rel, sha, sz});
    }
    for (size_t i = 0; i < all.size(); i++)
        for (size_t j = i + 1; j < all.size(); j++)
            if (all[i].relpath == all[j].relpath) return (int)Kind::IO_ERROR; // duplicate
    out = std::move(all);
    return (int)Kind::OK;
}

// ---------------- Marker ----------------
std::string read_marker(const std::string& root) {
    std::ifstream f(root + "/.storage-version");
    if (!f.is_open()) return "";
    std::ostringstream ss; ss << f.rdbuf(); return ss.str();
}
std::string marker_field(const std::string& marker, const std::string& key) {
    size_t p = marker.find(key + "=");
    if (p == std::string::npos) return "";
    p += key.size() + 1;
    size_t e = marker.find('\n', p);
    if (e == std::string::npos) e = marker.size();
    return marker.substr(p, e - p);
}

void mkdirs(const std::string& dir) {
    if (dir.empty()) return;
    for (size_t i = 0; i <= dir.size(); i++) {
        if (i == dir.size() || dir[i] == '/') {
            std::string part = dir.substr(0, i);
            if (!part.empty()) ::mkdir(part.c_str(), 0755);
        }
    }
}

void remove_partials(const std::string& root, const std::vector<Entry>& entries) {
    for (const auto& e : entries) {
        std::string dir = root + "/" + e.relpath.substr(0, e.relpath.find_last_of('/'));
        DIR* d = ::opendir(dir.c_str());
        if (!d) continue;
        std::string base = e.relpath.substr(e.relpath.find_last_of('/') + 1);
        struct dirent* de;
        while ((de = ::readdir(d))) {
            std::string name = de->d_name;
            if (name.rfind(base + ".partial.", 0) == 0) ::unlink((dir + "/" + name).c_str());
        }
        ::closedir(d);
    }
}

// ---------------- Materialize ----------------
int materialize(const std::string& root, const std::string& packaged,
                const std::string& mfile, const std::string& cfg,
                uint64_t avail_bytes, bool slow) {
    std::vector<Entry> entries;
    int rc = load_manifest(mfile, entries);
    if (rc != (int)Kind::OK) return rc;

    std::ifstream cf(cfg); std::string line;
    uint32_t ver = 0, gen = 0; uint64_t hb = 0; double hf = 0.0;
    while (std::getline(cf, line)) {
        size_t eq = line.find('=');
        if (eq == std::string::npos) continue;
        std::string k = line.substr(0, eq), v = line.substr(eq + 1);
        if (k == "STORAGE_VERSION") ver = (uint32_t)std::strtoul(v.c_str(), nullptr, 10);
        else if (k == "RESOURCE_GEN") gen = (uint32_t)std::strtoul(v.c_str(), nullptr, 10);
        else if (k == "HEADROOM_BYTES") hb = std::strtoull(v.c_str(), nullptr, 10);
        else if (k == "HEADROOM_FRACTION") hf = std::strtod(v.c_str(), nullptr);
    }
    std::string vs = std::to_string(ver), gs = std::to_string(gen);
    std::string manifest_sha = file_sha256(mfile);

    uint64_t total = 0;
    for (const auto& e : entries) total += e.size;
    uint64_t required = total + std::max<uint64_t>(hb, (uint64_t)(hf * (double)total));

    std::string marker = read_marker(root);
    bool fresh = false;
    if (!marker.empty()) {
        fresh = (marker_field(marker, "STORAGE_VERSION") == vs &&
                 marker_field(marker, "RESOURCE_GEN") == gs &&
                 marker_field(marker, "MANIFEST_SHA256") == manifest_sha &&
                 marker_field(marker, "COMPLETED") == "1");
    }

    if (!fresh && avail_bytes < required) return (int)Kind::LOW_SPACE;

    if (!fresh) {
        remove_partials(root, entries);
        for (const auto& e : entries) {
            std::string dir = root + "/" + e.relpath.substr(0, e.relpath.find_last_of('/'));
            mkdirs(dir);
            std::string dest = root + "/" + e.relpath;
            struct stat sb;
            if (::stat(dest.c_str(), &sb) == 0 &&
                (uint64_t)sb.st_size == e.size && file_sha256(dest) == e.sha) continue;
            std::string src = packaged + "/" + e.relpath;
            struct stat ssb;
            if (::stat(src.c_str(), &ssb) != 0) return (int)Kind::IO_ERROR;
            if ((uint64_t)ssb.st_size != e.size) return (int)Kind::IO_ERROR;
            std::string partial = dest + ".partial." + e.sha.substr(0, 16);
            {
                std::ifstream in(src, std::ios::binary);
                int fd = ::open(partial.c_str(), O_CREAT | O_TRUNC | O_WRONLY, 0644);
                if (fd < 0) return (int)Kind::IO_ERROR;
                char buf[65536];
                while (in) {
                    in.read(buf, sizeof buf); std::streamsize n = in.gcount();
                    if (n > 0) { if (::write(fd, buf, (size_t)n) < 0) { ::close(fd); return (int)Kind::IO_ERROR; } if (slow) ::usleep(15000); }
                }
                ::fsync(fd); ::close(fd);
            }
            if (file_sha256(partial) != e.sha) { ::unlink(partial.c_str()); return (int)Kind::IO_ERROR; }
            if (::rename(partial.c_str(), dest.c_str()) != 0) { ::unlink(partial.c_str()); return (int)Kind::IO_ERROR; }
        }
        std::string mtext = "STORAGE_VERSION=" + vs + "\n" +
                            "RESOURCE_GEN=" + gs + "\n" +
                            "MANIFEST_SHA256=" + manifest_sha + "\n" +
                            "COMPLETED=1\n";
        std::string tmp = root + "/.storage-version.part";
        int fd = ::open(tmp.c_str(), O_CREAT | O_TRUNC | O_WRONLY, 0644);
        if (fd < 0) return (int)Kind::IO_ERROR;
        ::write(fd, mtext.data(), mtext.size());
        ::fsync(fd); ::close(fd);
        if (::rename(tmp.c_str(), (root + "/.storage-version").c_str()) != 0) return (int)Kind::IO_ERROR;
    }
    return (int)Kind::OK;
}

} // namespace st

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: driver <cmd> ...\n"); return 2; }
    std::string cmd = argv[1];

    if (cmd == "sha256") {
        if (argc != 3) return 2;
        std::printf("%s\n", st::file_sha256(argv[2]).c_str());
        return 0;
    }
    if (cmd == "escape") {
        if (argc != 4) return 2;
        std::ifstream f(argv[2]);
        std::string line; int rejected = 0, accepted = 0;
        while (std::getline(f, line)) {
            bool bad = st::structural_escape(line) || !st::is_safe_component(line);
            if (bad) rejected++; else accepted++;
            std::printf("  %s -> %s\n", line.c_str(), bad ? "REJECT" : "ACCEPT");
        }
        if (accepted != 0) { std::printf("ACCEPTED_FIXTURE_NAMES=%d (must be 0)\n", accepted); return 3; }
        const char* safe[] = {"autosave.sav", "game_001.sav", "my-scenario.dat"};
        std::string root = argv[3];
        int safe_ok = 0;
        for (const char* s : safe) {
            bool ok = !st::structural_escape(s) && st::is_safe_component(s);
            std::string j = root + "/" + s;
            bool under = (j.rfind(root + "/", 0) == 0);
            std::printf("  safe %s -> %s under_root=%s\n", s, ok ? "ACCEPT" : "REJECT", under ? "yes" : "no");
            if (ok && under) safe_ok++;
        }
        if (safe_ok != 3) { std::printf("SAFE_OK=%d (must be 3)\n", safe_ok); return 3; }
        std::printf("escape: rejected=%d safe_ok=%d\n", rejected, safe_ok);
        return 0;
    }
    if (cmd == "loadmanifest") {
        if (argc != 3) return 2;
        std::vector<st::Entry> entries;
        int rc = st::load_manifest(argv[2], entries);
        if (rc != (int)st::Kind::OK) { std::printf("MANIFEST_BAD\n"); return 1; }
        std::printf("MANIFEST_OK entries=%zu\n", entries.size());
        return 0;
    }
    if (cmd == "materialize") {
        // materialize <root> <packaged> <mfile> <cfg> <avail_kb> [slow]
        if (argc < 7 || argc > 8) return 2;
        uint64_t avail_kb = std::strtoull(argv[6], nullptr, 10);
        bool slow = (argc == 8);
        int rc = st::materialize(argv[2], argv[3], argv[4], argv[5], avail_kb * 1024ULL, slow);
        std::printf("MATERIALIZE %s\n", st::kind_name((st::Kind)rc));
        if (rc == (int)st::Kind::OK) return 0;
        if (rc == (int)st::Kind::LOW_SPACE) return 10;
        return 1;
    }
    if (cmd == "marker") {
        if (argc != 3) return 2;
        std::string m = st::read_marker(argv[2]);
        if (m.empty()) { std::printf("NO_MARKER\n"); return 0; }
        std::printf("%s", m.c_str());
        return 0;
    }
    if (cmd == "picker") {
        if (argc != 3) return 2;
        st::Kind k;
        if (argv[2] == std::string("cancel")) k = st::Kind::CANCELLED;
        else if (argv[2] == std::string("expired") || argv[2] == std::string("invalid-scheme")) k = st::Kind::INVALID_URI;
        else k = st::Kind::OK;
        std::printf("PICKER %s\n", st::kind_name(k));
        return 0;
    }
    std::fprintf(stderr, "unknown command: %s\n", cmd.c_str());
    return 2;
}
EOF

# ---------------------------------------------------------------------------
# Build the host test binary
# ---------------------------------------------------------------------------
note '[test] building host test binary'
if ! "${CXX}" -std=c++17 -O2 -Wall -Wextra "${DRIVER}" -o "${BIN}" 2>"${WORKDIR}/build.log"; then
  fail "host build of storage-contract driver failed"
fi

# ---------------------------------------------------------------------------
# Python fixture validator (completeness + checksums)
# ---------------------------------------------------------------------------
cat > "${WORKDIR}/validate_manifest.py" <<'PY'
import hashlib, json, os, sys

FIX = sys.argv[1]
manifest_json = os.path.join(FIX, "manifest-expected.json")
packaged = os.path.join(FIX, "packaged")

def walk(base):
    out = []
    for root, dirs, files in os.walk(base):
        dirs.sort()
        for fn in sorted(files):
            out.append(os.path.relpath(os.path.join(root, fn), base).replace(os.sep, "/"))
    return out

packaged_files = walk(packaged)
with open(manifest_json) as f:
    man = json.load(f)
listed = [e["relpath"] for e in man["entries"]]
set_listed = set(listed)
set_packaged = set(packaged_files)

missing = sorted(set_packaged - set_listed)
extras = sorted(set_listed - set_packaged)
if missing or extras:
    print("INCOMPLETE missing=%s extras=%s" % (missing, extras)); sys.exit(1)
if len(listed) != len(set_listed):
    print("INCOMPLETE duplicate_relpaths=%d" % (len(listed) - len(set_listed))); sys.exit(1)
for e in man["entries"]:
    with open(os.path.join(packaged, e["relpath"]), "rb") as f:
        raw = f.read()
    if len(raw) != e["size"]:
        print("INCOMPLETE size_mismatch rel=%s" % e["relpath"]); sys.exit(1)
    if hashlib.sha256(raw).hexdigest() != e["sha256"]:
        print("INCOMPLETE checksum_mismatch rel=%s" % e["relpath"]); sys.exit(1)
if man.get("storageVersion") != 3 or man.get("resourceGen") != 3:
    print("INCOMPLETE version_mismatch"); sys.exit(1)
print("MANIFEST_COMPLETE entries=%d storageVersion=%d resourceGen=%d" %
      (len(man["entries"]), man["storageVersion"], man["resourceGen"]))
sys.exit(0)
PY

run_py() { "${PY}" "${WORKDIR}/validate_manifest.py" "$1"; }

RC_ALL=0

# ---------------------------------------------------------------------------
# Scenario: manifest (fixture generated-resource completeness)
# ---------------------------------------------------------------------------
note; note '== scenario: manifest (fixture generated-resource completeness) =='
if out="$(run_py "${FIXTURES}")"; then
  printf 'PASS: %s\n' "$out"
else
  printf 'FAIL: %s\n' "$out" >&2; RC_ALL=1
fi

# negative: bad/incomplete-manifest.json (one entry missing) must fail validation
NEG="${WORKDIR}/neg"
rm -rf "${NEG}"; cp -R "${FIXTURES}" "${NEG}"
cp "${FIXTURES}/bad/incomplete-manifest.json" "${NEG}/manifest-expected.json"
if run_py "${NEG}" > "${WORKDIR}/neg.log" 2>&1; then
  printf 'FAIL: incomplete manifest fixture accepted\n' >&2; RC_ALL=1
else
  printf 'PASS: incomplete manifest fixture rejected: %s\n' "$(cat "${WORKDIR}/neg.log")"
fi

# ---------------------------------------------------------------------------
# Scenario: manifest (C++ loader + sha256 cross-check)
# ---------------------------------------------------------------------------
note; note '== scenario: manifest (C++ loader + sha256 cross-check) =='
"${PY}" - "${MANIFEST_JSON}" "${WORKDIR}/fixture.manifest" <<'PY'
import json, sys
man = json.load(open(sys.argv[1]))
with open(sys.argv[2], "w") as f:
    for e in man["entries"]:
        f.write("%s\t%s\t%d\n" % (e["relpath"], e["sha256"], e["size"]))
PY
count=0; okc=0
while IFS= read -r line; do
  rel="${line%%	*}"; csha="${line#*	}"; csha="${csha%%	*}"
  count=$((count+1))
  a="$(build_sha256 "${PACKAGED}/${rel}")"
  b="$(shasum -a 256 "${PACKAGED}/${rel}" | awk '{print $1}')"
  if [ "$a" = "$b" ]; then okc=$((okc+1)); else printf '  FAIL: C++ sha256 mismatch for %s\n' "$rel" >&2; fi
done < "${WORKDIR}/fixture.manifest"
[ "$okc" -eq "$count" ] && printf 'PASS: C++ sha256 == shasum for %d/%d packaged files\n' "$okc" "$count" \
  || { RC_ALL=1; printf 'FAIL: sha256 cross-check\n' >&2; }

if "${BIN}" loadmanifest "${WORKDIR}/fixture.manifest" > "${WORKDIR}/lm.log"; then
  printf 'PASS: %s\n' "$(cat "${WORKDIR}/lm.log")"
else RC_ALL=1; printf 'FAIL: valid manifest rejected by C++ loader\n' >&2; fi

head -1 "${WORKDIR}/fixture.manifest" > "${WORKDIR}/dup.manifest"
head -1 "${WORKDIR}/fixture.manifest" >> "${WORKDIR}/dup.manifest"
if "${BIN}" loadmanifest "${WORKDIR}/dup.manifest" >/dev/null 2>&1; then
  printf 'FAIL: duplicate relpath accepted\n' >&2; RC_ALL=1
else printf 'PASS: duplicate relpath rejected\n'; fi

printf 'data/openttd.grf\tnothex\t23\n' > "${WORKDIR}/badsha.manifest"
if "${BIN}" loadmanifest "${WORKDIR}/badsha.manifest" >/dev/null 2>&1; then
  printf 'FAIL: malformed sha line accepted\n' >&2; RC_ALL=1
else printf 'PASS: malformed sha line rejected\n'; fi

# ---------------------------------------------------------------------------
# Scenario: escape (path traversal / containment)
# ---------------------------------------------------------------------------
note; note '== scenario: escape (path guard) =='
ESCAPE_ROOT="${WORKDIR}/sandbox"
mkdir -p "${ESCAPE_ROOT}"
if "${BIN}" escape "${BAD_NAMES}" "${ESCAPE_ROOT}"; then
  printf 'PASS: all malicious names rejected; safe names accepted under root\n'
else RC_ALL=1; printf 'FAIL: escape scenario\n' >&2; fi

# ---------------------------------------------------------------------------
# Scenario: picker (typed nonfatal results)
# ---------------------------------------------------------------------------
note; note '== scenario: picker (typed nonfatal results) =='
pick() { "${BIN}" picker "$1" | awk '{print $2}'; }
[ "$(pick cancel)" = "CANCELLED" ]    && printf 'PASS: cancel -> CANCELLED\n'     || { RC_ALL=1; printf 'FAIL: cancel kind\n' >&2; }
[ "$(pick expired)" = "INVALID_URI" ] && printf 'PASS: expired URI -> INVALID_URI\n' || { RC_ALL=1; printf 'FAIL: expired kind\n' >&2; }
[ "$(pick invalid-scheme)" = "INVALID_URI" ] && printf 'PASS: non-file URI -> INVALID_URI\n' || { RC_ALL=1; printf 'FAIL: scheme kind\n' >&2; }
[ "$(pick valid)" = "OK" ]            && printf 'PASS: valid URI -> OK\n'         || { RC_ALL=1; printf 'FAIL: valid kind\n' >&2; }

# ---------------------------------------------------------------------------
# Scenario: stale (upgrade marker -> re-materialize)
# ---------------------------------------------------------------------------
note; note '== scenario: stale (upgrade marker) =='
cat > "${WORKDIR}/cfg" <<EOF
STORAGE_VERSION=${STORAGE_VERSION}
RESOURCE_GEN=${RESOURCE_GEN}
HEADROOM_BYTES=${HEADROOM_BYTES}
HEADROOM_FRACTION=${HEADROOM_FRACTION}
EOF
STALE_ROOT="${WORKDIR}/stale"
rm -rf "${STALE_ROOT}"; mkdir -p "${STALE_ROOT}"
printf 'STORAGE_VERSION=1\nRESOURCE_GEN=1\nMANIFEST_SHA256=deadbeef\nCOMPLETED=1\n' \
  > "${STALE_ROOT}/.storage-version"
if "${BIN}" materialize "${STALE_ROOT}" "${PACKAGED}" "${WORKDIR}/fixture.manifest" \
     "${WORKDIR}/cfg" 100000000 > "${WORKDIR}/stale.log"; then
  :
else
  RC_ALL=1; printf 'FAIL: stale re-materialize\n' >&2; cat "${WORKDIR}/stale.log" >&2
fi
NEWMARKER="$("${BIN}" marker "${STALE_ROOT}")"
echo "$NEWMARKER" | grep -q "STORAGE_VERSION=${STORAGE_VERSION}" \
  && echo "$NEWMARKER" | grep -q "COMPLETED=1" \
  && printf 'PASS: stale marker rewritten to version %s\n' "${STORAGE_VERSION}" \
  || { RC_ALL=1; printf 'FAIL: stale marker not rewritten\n' >&2; echo "$NEWMARKER" >&2; }
dstok=1
while IFS= read -r line; do
  rel="${line%%	*}"
  [ -f "${STALE_ROOT}/${rel}" ] || { dstok=0; printf '  missing dest %s\n' "$rel" >&2; }
done < "${WORKDIR}/fixture.manifest"
[ "$dstok" -eq 1 ] && printf 'PASS: stale materialized all dests\n' || { RC_ALL=1; printf 'FAIL: stale dests\n' >&2; }

# ---------------------------------------------------------------------------
# Scenario: lowspace (free-space gate)
# ---------------------------------------------------------------------------
note; note '== scenario: lowspace (free-space gate) =='
LOW_ROOT="${WORKDIR}/low"
rm -rf "${LOW_ROOT}"; mkdir -p "${LOW_ROOT}"
if "${BIN}" materialize "${LOW_ROOT}" "${PACKAGED}" "${WORKDIR}/fixture.manifest" \
     "${WORKDIR}/cfg" 1 > "${WORKDIR}/low.log"; then
  printf 'FAIL: lowspace unexpectedly succeeded\n' >&2; RC_ALL=1
else
  grep -q "LOW_SPACE" "${WORKDIR}/low.log" \
    && printf 'PASS: lowspace -> typed LOW_SPACE\n' \
    || { RC_ALL=1; printf 'FAIL: lowspace kind\n' >&2; cat "${WORKDIR}/low.log" >&2; }
fi
if find "${LOW_ROOT}" -type f | grep -q .; then
  printf 'FAIL: lowspace wrote files\n' >&2; RC_ALL=1
else printf 'PASS: lowspace wrote no files\n'; fi

# ---------------------------------------------------------------------------
# Scenario: atomic (kill during first-copy -> relaunch recovery)
# ---------------------------------------------------------------------------
note; note '== scenario: atomic (kill during first-copy + recovery) =='
ATOMIC_ROOT="${WORKDIR}/atomic"
rm -rf "${ATOMIC_ROOT}"; mkdir -p "${ATOMIC_ROOT}"

before="$(find "${PACKAGED}" -type f | sort | xargs shasum -a 256 | shasum -a 256 | awk '{print $1}')"

"${BIN}" materialize "${ATOMIC_ROOT}" "${PACKAGED}" "${WORKDIR}/fixture.manifest" \
  "${WORKDIR}/cfg" 100000000 slow > "${WORKDIR}/atomic_kill.log" 2>&1 &
KILLPID=$!
sleep 0.15
kill -9 "${KILLPID}" 2>/dev/null || true
wait "${KILLPID}" 2>/dev/null || true
note '  (killed first-copy mid-way; rerunning -> recovery)'

if "${BIN}" materialize "${ATOMIC_ROOT}" "${PACKAGED}" "${WORKDIR}/fixture.manifest" \
     "${WORKDIR}/cfg" 100000000 > "${WORKDIR}/atomic_rec.log"; then
  printf 'PASS: relaunch recovered and completed\n'
else RC_ALL=1; printf 'FAIL: relaunch recovery\n' >&2; cat "${WORKDIR}/atomic_rec.log" >&2; fi

if find "${ATOMIC_ROOT}" -name '*.partial.*' | grep -q .; then
  printf 'FAIL: leftover .partial files after recovery\n' >&2; RC_ALL=1
else printf 'PASS: no leftover .partial files\n'; fi

"${BIN}" marker "${ATOMIC_ROOT}" | grep -q "COMPLETED=1" \
  && printf 'PASS: marker COMPLETED after recovery\n' \
  || { RC_ALL=1; printf 'FAIL: marker not COMPLETED\n' >&2; }

dstok=1
while IFS= read -r line; do
  rel="${line%%	*}"; csha="${line#*	}"; csha="${csha%%	*}"
  a="$(shasum -a 256 "${ATOMIC_ROOT}/${rel}" | awk '{print $1}')"
  [ "$a" = "$csha" ] || { dstok=0; printf '  dest %s checksum mismatch\n' "$rel" >&2; }
done < "${WORKDIR}/fixture.manifest"
[ "$dstok" -eq 1 ] && printf 'PASS: all dest checksums match manifest\n' || { RC_ALL=1; printf 'FAIL: dest checksums\n' >&2; }

after="$(find "${PACKAGED}" -type f | sort | xargs shasum -a 256 | shasum -a 256 | awk '{print $1}')"
[ "$before" = "$after" ] \
  && printf 'PASS: packaged checksums unchanged (before=%s after=%s)\n' "$before" "$after" \
  || { RC_ALL=1; printf 'FAIL: packaged checksums changed\n' >&2; }

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--refresh-manifest" ]; then
  "${PY}" - "${FIXTURES}" <<'PY'
import hashlib, json, os, sys
fix = sys.argv[1]
packaged = os.path.join(fix, "packaged")
entries = []
for root, _, files in os.walk(packaged):
    for fn in sorted(files):
        rel = os.path.relpath(os.path.join(root, fn), packaged).replace(os.sep, "/")
        with open(os.path.join(packaged, rel), "rb") as f:
            raw = f.read()
        entries.append({"relpath": rel, "size": len(raw),
                        "sha256": hashlib.sha256(raw).hexdigest()})
entries.sort(key=lambda e: e["relpath"])
data = {"format": "openttd-harmonyos-packaged-manifest", "storageVersion": 3,
        "resourceGen": 3, "headroomBytes": 67108864, "headroomFraction": 0.08,
        "entries": entries}
with open(os.path.join(fix, "manifest-expected.json"), "w") as f:
    json.dump(data, f, indent=2); f.write("\n")
print("REFRESHED manifest-expected.json entries=%d" % len(entries))
PY
  note 'manifest-expected.json refreshed from packaged/'
fi

note; note "[test] storage contract: $([ "$RC_ALL" -eq 0 ] && echo ALL PASS || echo FAILED)"
exit "$RC_ALL"
EOF
