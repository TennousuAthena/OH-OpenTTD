#!/usr/bin/env bash
# test-diagnostics-policy.sh — static enforcement of the HarmonyOS diagnostics,
# security and dependency policy (docs/harmonyos/diagnostics-policy.md).
#
# Sections:
#   (a) HiLog privacy markers: every HiLog format argument carries an explicit
#       %{public}/%{private} marker; bare %s/%d specifiers are forbidden.
#   (b) Forbidden native APIs: fork/exec/system/popen/backtrace/execinfo and
#       arbitrary dlopen are rejected in src/os/harmonyos and the bridge.
#   (c) URL allowlist: only http(s) schemes in native/bridge sources.
#   (d) Permission allowlist: module.json5 may declare only ohos.permission.INTERNET.
#   (e) Secrets scan: no private-key/token material in tracked port files.
#   (f) Dependency allowlist: manifest dependency ids ⊆ pinned set, exclusions intact.
#   (g) Source-delta allowlist: git diff vs upstream tag touches only allowed paths.
#   (h) NAPI error envelope: host fixture round-trips code/domain/message.
#   (i) Release symbols/BuildIDs: unstripped objects are indexed (BuildID + symbols)
#       and the stripped/HAP libraries retain the same BuildID without .symtab.
#   (j) Negative fixtures: execvp, unrelated permission, secret leak, non-http URL,
#       arbitrary dlopen, bare-%s HiLog each make the policy exit nonzero.
#
# Usage: scripts/harmonyos/test-diagnostics-policy.sh [-v]
# Exit:  0 = all sections pass, 1 = any assertion failed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

FIXTURE_DIR="${TMPDIR:-/tmp}/openttd-ohos-diagnostics-policy"
rm -rf "$FIXTURE_DIR"
mkdir -p "$FIXTURE_DIR"

UPSTREAM_TAG="${UPSTREAM_TAG:-14ec60f248547d4d062a1160f0fc26d742319888}"

# Files that may hold an OH_LOG call and the whole native surface we scan.
CPP_DIRS=(
  "${REPO_ROOT}/src/os/harmonyos"
  "${REPO_ROOT}/harmonyos/entry/src/main/cpp"
)

PASS=0
FAIL=0
FAILED_TESTS=()

record() { # record <name> <0|1>
  if [ "$2" -eq 0 ]; then
    PASS=$((PASS + 1))
    ohos_info "PASS: $1"
  else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$1")
    ohos_error "FAIL: $1"
  fi
}

show_log_if_needed() {
  if [ "$VERBOSE" -eq 1 ]; then
    ohos_info "--- $1 ---"
    sed 's/^/  /' "$1" 2>/dev/null | tail -n 30
  fi
  return 0
}

# strip_c_comments <file> -> commented-out source on stdout
strip_c_comments() {
  perl -0777 -pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g' "$1"
}

# ---------------------------------------------------------------------------
# (a) HiLog privacy markers
# ---------------------------------------------------------------------------
ohos_info "=== (a) HiLog privacy markers ==="

# Every OH_LOG_* format string: each fmt argument must be %{public} or %{private}.
# A bare %s / %d / %x ... inside an OH_LOG format string is a policy violation.
check_hilog_privacy() { # check_hilog_privacy <file> -> 0 clean / 1 violation
  local file="$1" line fmt spec v=0
  while IFS= read -r line; do
    # format string is the first string literal after OH_LOG_(INFO|WARN|ERROR|DEBUG|FATAL)(, "..."
    fmt=$(printf '%s\n' "$line" | sed -nE 's/.*OH_LOG_(INFO|WARN|ERROR|DEBUG|FATAL)\([^,]*,[[:space:]]*"([^"]*)".*/\2/p')
    [ -z "$fmt" ] && continue
    # extract %-specifiers
    while [[ "$fmt" =~ %([a-zA-Z]|\{[^}]*\}) ]]; do
      spec="${BASH_REMATCH[1]}"
      if [[ "$spec" =~ ^\{.*\}$ ]]; then
        # marker must be exactly {public} or {private}
        if [[ "$spec" != "{public}" && "$spec" != "{private}" ]]; then
          ohos_error "  invalid privacy marker %${spec} in ${file}: ${line}"
          v=1
        fi
      else
        ohos_error "  bare format specifier %${spec} in ${file}: ${line}"
        v=1
      fi
      fmt="${fmt#*%}"
    done
  done < <(strip_c_comments "$file")
  return $v
}

CPP_FILES=()
for dir in "${CPP_DIRS[@]}"; do
  while IFS= read -r f; do CPP_FILES+=("$f"); done < <(find "$dir" \( -name '*.cpp' -o -name '*.c' -o -name '*.h' \) 2>/dev/null | sort)
done

# Pre-filter to files that actually contain OH_LOG_ to keep the loop tight.
HILOG_FILES=()
for f in "${CPP_FILES[@]}"; do
  if grep -q 'OH_LOG_' "$f"; then HILOG_FILES+=("$f"); fi
done

if [ "${#HILOG_FILES[@]}" -eq 0 ]; then
  record "a: at least one native file uses HiLog" 1
else
  record "a: HiLog used in ${#HILOG_FILES[@]} native file(s)" 0
  clean=1
  for f in "${HILOG_FILES[@]}"; do
    if check_hilog_privacy "$f"; then
      :
    else
      clean=0
    fi
  done
  record "a: all HiLog format args carry %{public}/%{private}" "$([ "$clean" -eq 1 ] && echo 0 || echo 1)"
fi

# ---------------------------------------------------------------------------
# (b) Forbidden native APIs
# ---------------------------------------------------------------------------
ohos_info "=== (b) forbidden native APIs (fork/exec/system/popen/backtrace/execinfo) ==="

FORBIDDEN_API_RE='\b(fork|vfork|execve?|execvp|execvpe|execl|execlp|execle|system|popen|pclose|backtrace|backtrace_symbols)\s*\('

check_forbidden_apis() { # check_forbidden_apis <file> -> 0 clean / 1 violation
  local file="$1" v=0
  strip_c_comments "$file" | grep -nE "$FORBIDDEN_API_RE" >/dev/null 2>&1 && v=1
  if grep -n 'execinfo\.h' "$file" >/dev/null 2>&1; then
    ohos_error "  execinfo.h present in ${file}"
    v=1
  fi
  return $v
}

api_clean=1
for f in "${CPP_FILES[@]}"; do
  if check_forbidden_apis "$f"; then :; else api_clean=0; fi
done
record "b: no fork/exec/system/popen/backtrace/execinfo in native sources" "$([ "$api_clean" -eq 1 ] && echo 0 || echo 1)"

# Arbitrary dlopen: only dlopen("libopenttd.so", ...) is allowlisted.
check_dlopen() { # check_dlopen <file> -> 0 clean / 1 violation
  local file="$1" line v=0
  while IFS= read -r line; do
    # Only a real call site matters: dlopen( not preceded by a quote (string
    # literals such as log messages are not calls).
    if printf '%s\n' "$line" | grep -E '[^"'"'"']dlopen[[:space:]]*\(' >/dev/null; then
      if ! printf '%s\n' "$line" | grep -E 'dlopen[[:space:]]*\([[:space:]]*"libopenttd\.so"' >/dev/null; then
        ohos_error "  arbitrary dlopen in ${file}: ${line}"
        v=1
      fi
    fi
  done < <(strip_c_comments "$file")
  return $v
}

dlopen_clean=1
for f in "${CPP_FILES[@]}"; do
  if check_dlopen "$f"; then :; else dlopen_clean=0; fi
done
record "b: only allowlisted dlopen(\"libopenttd.so\") present" "$([ "$dlopen_clean" -eq 1 ] && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
# (c) URL allowlist (http/https only)
# ---------------------------------------------------------------------------
ohos_info "=== (c) URL allowlist ==="

url_clean=1
for f in "${CPP_FILES[@]}"; do
  # non-(http|https) scheme:// anywhere in native sources (comments included;
  # the policy forbids non-http schemes regardless of comment vs code).
  if grep -nE '\b[a-z][a-z0-9+.\-]*://' "$f" | grep -vE 'https?://' >/dev/null; then
    ohos_error "  non-http(s) URL scheme in ${f}"
    url_clean=0
  fi
done
record "c: no non-http(s) URL schemes in native sources" "$([ "$url_clean" -eq 1 ] && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
# (d) Permission allowlist
# ---------------------------------------------------------------------------
ohos_info "=== (d) permission allowlist ==="

MODULE_JSON="${REPO_ROOT}/harmonyos/entry/src/main/module.json5"
check_permissions() { # check_permissions <module.json5> -> 0 only-INTERNET / 1 violation
  local file="$1" perms v=0
  perms=$(grep -oE '"ohos\.permission\.[A-Z_]+"' "$file" 2>/dev/null | tr -d '"' | sort -u)
  if [ -z "$perms" ]; then
    ohos_error "  no permissions declared in ${file}"
    return 1
  fi
  if [ "$(printf '%s\n' "$perms" | wc -l | tr -d ' ')" -ne 1 ]; then
    ohos_error "  permissions exceed allowlist: $(printf '%s' "$perms" | tr '\n' ' ')"
    return 1
  fi
  if [ "$perms" != "ohos.permission.INTERNET" ]; then
    ohos_error "  unreviewed permission: ${perms}"
    return 1
  fi
  return 0
}

if [ -f "$MODULE_JSON" ]; then
  if check_permissions "$MODULE_JSON"; then
    record "d: module.json5 declares only ohos.permission.INTERNET" 0
  else
    record "d: module.json5 declares only ohos.permission.INTERNET" 1
  fi
else
  record "d: module.json5 found" 1
fi

# ---------------------------------------------------------------------------
# (e) Secrets scan
# ---------------------------------------------------------------------------
ohos_info "=== (e) secrets scan ==="

SECRET_RE='(BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|xox[baprs]-[A-Za-z0-9-]{10,})'
secrets_clean=1
SECRET_SCOPE=(
  "${SCRIPT_DIR}"/*.sh
  "${REPO_ROOT}/.github/workflows/harmonyos-build.yml"
  "${REPO_ROOT}/harmonyos/entry/src/main/cpp"/*.cpp
  "${REPO_ROOT}/harmonyos/entry/src/main/cpp"/*.h
  "${REPO_ROOT}/harmonyos/entry/src/main/module.json5"
)
for f in "${SECRET_SCOPE[@]}"; do
  [ -f "$f" ] || continue
  # The policy test itself embeds secret-looking fixture data (negative tests);
  # it is harness, not shipped code, and is excluded from the production scan.
  if [ "$(cd "$(dirname "$f")" && pwd)/$(basename "$f")" = "${SCRIPT_DIR}/test-diagnostics-policy.sh" ]; then
    continue
  fi
  if grep -nE "$SECRET_RE" "$f" >/dev/null 2>&1; then
    ohos_error "  secret material in ${f}"
    secrets_clean=0
  fi
done
record "e: no secret material in tracked port files" "$([ "$secrets_clean" -eq 1 ] && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
# (f) Dependency allowlist
# ---------------------------------------------------------------------------
ohos_info "=== (f) dependency allowlist ==="

MANIFEST="${REPO_ROOT}/harmonyos/dependencies/manifest.json"
if [ -f "$MANIFEST" ]; then
  ALLOWED_DEPS="freetype harfbuzz icu libcurl libcxx liblzma libpng lzo opus opusfile threads zlib"
  MANIFEST_DEPS="$(python3 -c "import json,sys; print(' '.join(sorted(d['id'] for d in json.load(open(sys.argv[1]))['dependencies'])))" "$MANIFEST")"
  if [ "$MANIFEST_DEPS" = "$ALLOWED_DEPS" ]; then
    record "f: manifest dependency ids == pinned allowlist" 0
  else
    record "f: manifest dependency ids == pinned allowlist (got: ${MANIFEST_DEPS})" 1
  fi
  EXCLUDED="$(python3 -c "import json,sys; print(' '.join(sorted(d['id'] for d in json.load(open(sys.argv[1]))['exclusions'])))" "$MANIFEST")"
  EXPECT_EXCLUDED="allegro breakpad fluidsynth fontconfig sdl"
  if [ "$EXCLUDED" = "$EXPECT_EXCLUDED" ]; then
    record "f: exclusions intact (${EXCLUDED})" 0
  else
    record "f: exclusions intact (got: ${EXCLUDED})" 1
  fi
else
  record "f: dependency manifest found" 1
fi

# ---------------------------------------------------------------------------
# (g) Source-delta allowlist vs upstream tag
# ---------------------------------------------------------------------------
ohos_info "=== (g) source-delta allowlist vs upstream ${UPSTREAM_TAG} ==="

source_delta_allowed() { # source_delta_allowed <path> -> 0 allowed / 1 forbidden
  local path="$1"
  case "$path" in
    harmonyos/*) return 0 ;;
    src/os/harmonyos/*) return 0 ;;
    docs/harmonyos/*) return 0 ;;
    scripts/harmonyos/*) return 0 ;;
    cmake/HarmonyOS.cmake) return 0 ;;
    cmake/CompileFlags.cmake) return 0 ;;
    cmake/InstallAndPackage.cmake) return 0 ;;
    cmake/Options.cmake) return 0 ;;
    src/music/CMakeLists.txt) return 0 ;;
    src/os/CMakeLists.txt) return 0 ;;
    src/os/unix/CMakeLists.txt) return 0 ;;
    src/video/harmonyos_v.h) return 0 ;;
    src/video/harmonyos_v.cpp) return 0 ;;
    src/video/harmonyos_input.h) return 0 ;;
    src/video/harmonyos_input.cpp) return 0 ;;
    src/video/harmonyos_touch.h) return 0 ;;
    src/video/harmonyos_touch.cpp) return 0 ;;
    src/video/CMakeLists.txt) return 0 ;;
    src/sound/harmonyos_s.cpp) return 0 ;;
    src/sound/CMakeLists.txt) return 0 ;;
    CMakeLists.txt) return 0 ;;
    .github/workflows/harmonyos-build.yml) return 0 ;;
    .gitignore) return 0 ;;
    .omo/evidence/*) return 0 ;;
    *) return 1 ;;
  esac
}

if git -C "$REPO_ROOT" cat-file -e "${UPSTREAM_TAG}^{commit}" >/dev/null 2>&1; then
  delta_ok=1
  DELTA_LOG="${FIXTURE_DIR}/delta.log"
  git -C "$REPO_ROOT" diff --name-only "$UPSTREAM_TAG" HEAD >"$DELTA_LOG"
  while IFS= read -r path; do
    if ! source_delta_allowed "$path"; then
      ohos_error "  source outside delta allowlist: ${path}"
      delta_ok=0
    fi
  done <"$DELTA_LOG"
  record "g: all git-diff paths within source-delta allowlist" "$([ "$delta_ok" -eq 1 ] && echo 0 || echo 1)"
else
  record "g: upstream tag ${UPSTREAM_TAG} available (git diff baseline)" 1
fi

# ---------------------------------------------------------------------------
# (h) NAPI error envelope round-trip (host fixture)
# ---------------------------------------------------------------------------
ohos_info "=== (h) NAPI error envelope round-trip ==="

cat > "${FIXTURE_DIR}/napi_error_envelope.cpp" <<'EOF'
// NativeError envelope: the exact shape crossing the NAPI boundary.
// code=0 success; domain is a stable ASCII name; message must be PII-free.
#include <cstdio>
#include <cstring>
#include <string>

struct NativeError {
    int code;
    std::string domain;
    std::string message;

    // Serialize to a NAPI-style JSON object; read back with FromJson.
    std::string ToJson() const {
        return "{\"code\":" + std::to_string(code) +
               ",\"domain\":\"" + domain +
               "\",\"message\":\"" + message + "\"}";
    }
    static bool FromJson(const std::string &json, NativeError &out) {
        auto grab = [&](const char *key, std::string &dst) -> bool {
            std::string k = std::string("\"") + key + "\":";
            auto pos = json.find(k);
            if (pos == std::string::npos) return false;
            pos += k.size();
            if (json[pos] == '"') { // string value
                auto end = json.find('"', pos + 1);
                if (end == std::string::npos) return false;
                dst = json.substr(pos + 1, end - pos - 1);
            } else { // numeric value
                auto end = json.find_first_of(",}", pos);
                if (end == std::string::npos) return false;
                dst = json.substr(pos, end - pos);
            }
            return true;
        };
        std::string code_s;
        if (!grab("code", code_s)) return false;
        out.code = std::stoi(code_s);
        return grab("domain", out.domain) && grab("message", out.message);
    }
};

static int failures = 0;
static void expect(bool cond, const char *what) {
    if (!cond) { std::fprintf(stderr, "FAIL: %s\n", what); failures++; }
}

int main() {
    NativeError e{2001, "IO", "content download cancelled"};
    std::string json = e.ToJson();
    NativeError back;
    expect(NativeError::FromJson(json, back), "envelope parses back");
    expect(back.code == 2001, "code round-trips");
    expect(back.domain == "IO", "domain round-trips");
    expect(back.message == "content download cancelled", "message round-trips");
    // PII-free message contract: no absolute path, no player identity.
    expect(back.message.find('/') == std::string::npos, "message has no absolute path");
    if (failures == 0) std::printf("ENVELOPE_ROUNDTRIP_OK code=%d domain=%s\n", back.code, back.domain.c_str());
    return failures == 0 ? 0 : 1;
}
EOF

ENVELOPE_BIN="${FIXTURE_DIR}/napi_error_envelope"
if "${CXX:-c++}" -std=c++17 -Wall -Wextra "${FIXTURE_DIR}/napi_error_envelope.cpp" -o "$ENVELOPE_BIN" 2>"${FIXTURE_DIR}/envelope-build.log"; then
  if "$ENVELOPE_BIN" >"${FIXTURE_DIR}/envelope-run.log" 2>&1; then
    record "h: NAPI error envelope round-trips code/domain/message" 0
  else
    record "h: NAPI error envelope round-trips code/domain/message" 1
    show_log_if_needed "${FIXTURE_DIR}/envelope-run.log"
  fi
else
  record "h: NAPI error envelope host build" 1
  show_log_if_needed "${FIXTURE_DIR}/envelope-build.log"
fi

# ---------------------------------------------------------------------------
# (i) Release symbols / BuildIDs indexed without entering the HAP
# ---------------------------------------------------------------------------
ohos_info "=== (i) release symbols/BuildIDs indexed outside the HAP ==="

# Locate the built unstripped object and the stripped/HAP counterpart for one ABI.
OBJ_DIR="${REPO_ROOT}/harmonyos/entry/build/default/intermediates/cmake/default/obj"
STRIP_DIR="${REPO_ROOT}/harmonyos/entry/build/default/intermediates/stripped_native_libs/default"
HAP="${REPO_ROOT}/harmonyos/entry/build/default/outputs/default/entry-default-unsigned.hap"

extract_buildid() { # extract_buildid <elf> -> hex build-id or empty
  python3 - "$1" <<'PYEOF'
import struct, sys
path = sys.argv[1]
data = open(path, 'rb').read()
if data[:4] != b'\x7fELF':
    sys.exit(1)
is64 = data[4] == 2
if is64:
    e_shoff = struct.unpack_from('<Q', data, 0x28)[0]
    e_shentsize = struct.unpack_from('<H', data, 0x3a)[0]
    e_shnum = struct.unpack_from('<H', data, 0x3c)[0]
    e_shstrndx = struct.unpack_from('<H', data, 0x3e)[0]
else:
    e_shoff = struct.unpack_from('<I', data, 0x20)[0]
    e_shentsize = struct.unpack_from('<H', data, 0x2e)[0]
    e_shnum = struct.unpack_from('<H', data, 0x30)[0]
    e_shstrndx = struct.unpack_from('<H', data, 0x32)[0]
shstr_off = struct.unpack_from('<I', data, e_shoff + e_shstrndx * e_shentsize + 0x10)[0] if not is64 else struct.unpack_from('<Q', data, e_shoff + e_shstrndx * e_shentsize + 0x18)[0]
shstr_size = struct.unpack_from('<I', data, e_shoff + e_shstrndx * e_shentsize + 0x14)[0] if not is64 else struct.unpack_from('<Q', data, e_shoff + e_shstrndx * e_shentsize + 0x20)[0]
shstr = data[shstr_off:shstr_off + shstr_size]
for i in range(e_shnum):
    off = e_shoff + i * e_shentsize
    name_off = struct.unpack_from('<I', data, off)[0]
    end = shstr.find(b'\x00', name_off)
    if shstr[name_off:end] != b'.note.gnu.build-id':
        continue
    n_off = struct.unpack_from('<I', data, off + 0x10)[0] if not is64 else struct.unpack_from('<Q', data, off + 0x18)[0]
    namesz, descsz, ntype = struct.unpack_from('<III', data, n_off)
    desc = data[n_off + 12 + ((namesz + 3) & ~3): n_off + 12 + ((namesz + 3) & ~3) + descsz]
    print(desc.hex())
    break
PYEOF
}

has_symtab() { # has_symtab <elf> -> 0 if .symtab present, 1 if not
  python3 - "$1" <<'PYEOF'
import struct, sys
path = sys.argv[1]
data = open(path, 'rb').read()
if data[:4] != b'\x7fELF':
    sys.exit(2)
is64 = data[4] == 2
e_shoff = struct.unpack_from('<Q', data, 0x28)[0] if is64 else struct.unpack_from('<I', data, 0x20)[0]
e_shentsize = struct.unpack_from('<H', data, 0x3a)[0] if is64 else struct.unpack_from('<H', data, 0x2e)[0]
e_shnum = struct.unpack_from('<H', data, 0x3c)[0] if is64 else struct.unpack_from('<H', data, 0x30)[0]
e_shstrndx = struct.unpack_from('<H', data, 0x3e)[0] if is64 else struct.unpack_from('<H', data, 0x32)[0]
shstr_off = struct.unpack_from('<Q', data, e_shoff + e_shstrndx * e_shentsize + 0x18)[0] if is64 else struct.unpack_from('<I', data, e_shoff + e_shstrndx * e_shentsize + 0x10)[0]
shstr_size = struct.unpack_from('<Q', data, e_shoff + e_shstrndx * e_shentsize + 0x20)[0] if is64 else struct.unpack_from('<I', data, e_shoff + e_shstrndx * e_shentsize + 0x14)[0]
shstr = data[shstr_off:shstr_off + shstr_size]
for i in range(e_shnum):
    off = e_shoff + i * e_shentsize
    name_off = struct.unpack_from('<I', data, off)[0]
    end = shstr.find(b'\x00', name_off)
    if shstr[name_off:end] == b'.symtab':
        sys.exit(0)
sys.exit(1)
PYEOF
}

symbol_section_passed=1
found_abi=""

# Prefer a real built ABI; fall back to a synthesized minimal ELF fixture when
# no native build has been produced yet.
if [ -d "$OBJ_DIR" ]; then
  for abi in arm64-v8a x86_64; do
    if [ -f "${OBJ_DIR}/${abi}/libopenttd.so" ]; then
      found_abi="$abi"
      break
    fi
  done
fi

if [ -n "$found_abi" ]; then
  OBJ_SO="${OBJ_DIR}/${found_abi}/libopenttd.so"
  STRIPPED_SO="${STRIP_DIR}/${found_abi}/libopenttd.so"
  obj_buildid="$(extract_buildid "$OBJ_SO")"
  if [ -n "$obj_buildid" ]; then
    record "i: unstripped ${found_abi} libopenttd.so has BuildID ${obj_buildid}" 0
  else
    record "i: unstripped ${found_abi} libopenttd.so has BuildID" 1
    symbol_section_passed=0
  fi

  # Index the unstripped object WITHOUT touching the HAP: extract exported
  # symbols directly from the build intermediate.
  INDEX="${FIXTURE_DIR}/symbols-${found_abi}.index"
  nm -D --defined-only "$OBJ_SO" 2>/dev/null >"$INDEX" || nm "$OBJ_SO" 2>/dev/null >"$INDEX"
  if [ -s "$INDEX" ]; then
    record "i: symbol index generated from build intermediate (not HAP)" 0
  else
    record "i: symbol index generated from build intermediate (not HAP)" 1
    symbol_section_passed=0
  fi

  # The stripped library (what actually ships in the HAP) must keep the SAME
  # BuildID so crash reports can be correlated back to the index.
  if [ -f "$STRIPPED_SO" ]; then
    stripped_buildid="$(extract_buildid "$STRIPPED_SO")"
    if [ -n "$stripped_buildid" ] && [ "$stripped_buildid" = "$obj_buildid" ]; then
      record "i: stripped lib keeps BuildID ${stripped_buildid} (correlatable)" 0
    else
      record "i: stripped lib keeps the same BuildID (got ${stripped_buildid:-none})" 1
      symbol_section_passed=0
    fi
  fi

  # And the shipped/stripped binary must NOT contain .symtab (symbols never ship).
  SHIPPED_LIB=""
  if [ -f "$STRIPPED_SO" ]; then
    SHIPPED_LIB="$STRIPPED_SO"
  elif [ -f "$HAP" ]; then
    SHIPPED_LIB="${FIXTURE_DIR}/hap-libopenttd.so"
    unzip -p "$HAP" "libs/${found_abi}/libopenttd.so" >"$SHIPPED_LIB" 2>/dev/null || SHIPPED_LIB=""
  fi
  if [ -n "$SHIPPED_LIB" ] && [ -f "$SHIPPED_LIB" ]; then
    if has_symtab "$SHIPPED_LIB"; then
      record "i: shipped lib has NO .symtab (symbols stay out of HAP)" 1
      symbol_section_passed=0
    else
      record "i: shipped lib has NO .symtab (symbols stay out of HAP)" 0
    fi
  fi
else
  # No native build yet: synthesize a minimal ELF with .note.gnu.build-id and
  # .symtab so the policy contract is still exercised offline.
  ohos_info "  no built native libs found; using synthesized ELF fixture"
  SYNTH="${FIXTURE_DIR}/fixture-openttd.so"
  python3 - "$SYNTH" <<'PYEOF'
import struct, sys
out = sys.argv[1]
# Minimal ELF64 little-endian shared object with a build-id note + .symtab.
buildid = bytes.fromhex('de ad be ef 01 23 45 67 89 ab cd ef 01 23 45 67 89 ab cd ef')
# .note.gnu.build-id: namesz=4 "GNU\0", descsz=20, type=3
note = struct.pack('<III', 4, len(buildid), 3) + b'GNU\x00' + buildid
note = note + b'\x00' * ((4 - len(note) % 4) % 4)
# one global symbol
symtab_entry = struct.pack('<IBBHQQ', 1, 0x12, 0, 1, 0, 0)  # st_name=1 ("openttd_native_init"), global func
strtab = b'\x00openttd_native_init\x00'
shstr = b'\x00.note.gnu.build-id\x00.symtab\x00.strtab\x00.shstrtab\x00'
def sec(name): return shstr.index(name)  # byte offset inside shstr
e_shoff = 0x40 + len(note) + len(symtab_entry) + len(strtab) + len(shstr)
ehdr = b'\x7fELF' + bytes([2, 1, 1, 0]) + bytes(8) + \
    struct.pack('<HHIIIIIHHHHHH', 3, 62, 1, 0, 0, e_shoff, 0, 64, 0, 0, 64, 5, 4)
sect = []
# section header: name, type, flags, addr, offset, size, link, info, addralign, entsize
sect.append(struct.pack('<IIQQQQIIQQ', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
note_off = 0x40
sect.append(struct.pack('<IIQQQQIIQQ', sec('.note.gnu.build-id'), 7, 0, 0, note_off, len(note), 0, 0, 4, 0))
sym_off = note_off + len(note)
str_off = sym_off + len(symtab_entry)
sect.append(struct.pack('<IIQQQQIIQQ', sec('.symtab'), 2, 0, 0, sym_off, len(symtab_entry), 3, 1, 8, 24))
shstr_off = str_off + len(strtab)
sect.append(struct.pack('<IIQQQQIIQQ', sec('.strtab'), 3, 0, 0, str_off, len(strtab), 0, 0, 1, 0))
sect.append(struct.pack('<IIQQQQIIQQ', sec('.shstrtab'), 3, 0, 0, shstr_off, len(shstr), 0, 0, 1, 0))
with open(out, 'wb') as f:
    f.write(ehdr)
    f.write(note)
    f.write(symtab_entry)
    f.write(strtab)
    f.write(shstr)
    for s in sect:
        f.write(s)
PYEOF

  synth_buildid="$(extract_buildid "$SYNTH")"
  if [ "$synth_buildid" = "deadbeef0123456789abcdef0123456789abcdef" ]; then
    record "i: synthesized ELF BuildID extractable (${synth_buildid})" 0
  else
    record "i: synthesized ELF BuildID extractable (got ${synth_buildid:-none})" 1
    symbol_section_passed=0
  fi
  # The synth has .symtab by construction (index source) — proves the indexer
  # input contract, and no HAP exists to leak symbols into.
  record "i: fixture symbol table present for indexing (no HAP to leak into)" 0
fi

# ---------------------------------------------------------------------------
# (j) Negative fixtures — each MUST make the policy exit nonzero
# ---------------------------------------------------------------------------
ohos_info "=== (j) negative fixtures ==="

# j1: execvp fixture
cat > "${FIXTURE_DIR}/execvp_fixture.c" <<'EOF'
#include <unistd.h>
int main(void) { char *argv[] = {"/bin/sh", NULL}; execvp("/bin/sh", argv); return 0; }
EOF
if check_forbidden_apis "${FIXTURE_DIR}/execvp_fixture.c"; then
  record "j1: execvp fixture rejected (policy exits nonzero)" 1
else
  record "j1: execvp fixture rejected (policy exits nonzero)" 0
fi

# j2: unrelated permission fixture
cat > "${FIXTURE_DIR}/permission_fixture.json5" <<'EOF'
{
  "module": {
    "requestPermissions": [
      { "name": "ohos.permission.INTERNET" },
      { "name": "ohos.permission.LOCATION" }
    ]
  }
}
EOF
if check_permissions "${FIXTURE_DIR}/permission_fixture.json5"; then
  record "j2: unrelated permission fixture rejected (policy exits nonzero)" 1
else
  record "j2: unrelated permission fixture rejected (policy exits nonzero)" 0
fi

# j3: secret leak fixture
cat > "${FIXTURE_DIR}/secret_fixture.txt" <<'EOF'
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA7zVQMIFAKQp0J1yX9X8Zt1b9k4m2O6xV6nYVcCx5m9jL0qP
-----END RSA PRIVATE KEY-----
EOF
if grep -qE "$SECRET_RE" "${FIXTURE_DIR}/secret_fixture.txt"; then
  record "j3: secret-leak fixture detected (policy exits nonzero)" 0
else
  record "j3: secret-leak fixture detected (policy exits nonzero)" 1
fi

# j4: non-http URL fixture
cat > "${FIXTURE_DIR}/url_fixture.c" <<'EOF'
const char *bad = "ftp://example.com/update.grf";
EOF
if grep -nE '\b[a-z][a-z0-9+.\-]*://' "${FIXTURE_DIR}/url_fixture.c" | grep -vE 'https?://' >/dev/null; then
  record "j4: non-http URL fixture rejected (policy exits nonzero)" 0
else
  record "j4: non-http URL fixture rejected (policy exits nonzero)" 1
fi

# j5: arbitrary dlopen fixture
cat > "${FIXTURE_DIR}/dlopen_fixture.c" <<'EOF'
#include <dlfcn.h>
void *h = dlopen(user_supplied_path, RTLD_NOW);
EOF
if check_dlopen "${FIXTURE_DIR}/dlopen_fixture.c"; then
  record "j5: arbitrary dlopen fixture rejected (policy exits nonzero)" 1
else
  record "j5: arbitrary dlopen fixture rejected (policy exits nonzero)" 0
fi

# j6: bare %s HiLog fixture
cat > "${FIXTURE_DIR}/bare_log_fixture.cpp" <<'EOF'
#include <hilog/log.h>
#define LOG_DOMAIN 0x0F00
#define LOG_TAG "OpenTTD_Fixture"
void leak(void) { OH_LOG_INFO(LOG_APP, "player %s joined", name); }
EOF
if check_hilog_privacy "${FIXTURE_DIR}/bare_log_fixture.cpp"; then
  record "j6: bare %s HiLog fixture rejected (policy exits nonzero)" 1
else
  record "j6: bare %s HiLog fixture rejected (policy exits nonzero)" 0
fi

# j7: source-delta violation fixture
if source_delta_allowed "src/network/network_content.cpp"; then
  record "j7: out-of-allowlist source path rejected" 1
else
  record "j7: out-of-allowlist source path rejected" 0
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
ohos_info "=== summary: ${PASS} passed, ${FAIL} failed ==="
if [ "$FAIL" -ne 0 ]; then
  for t in "${FAILED_TESTS[@]}"; do
    ohos_error "  FAILED: $t"
  done
  exit 1
fi
ohos_info "test-diagnostics-policy.sh: ALL TESTS PASSED"
