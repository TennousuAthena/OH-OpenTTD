#!/usr/bin/env bash
# check-dependency-manifest.sh — validates the OpenTTD HarmonyOS native
# dependency graph and verifies cached archives against pinned SHA-256.
#
# Modes:
#   default           validate manifest schema + semantics (no network)
#   --offline         default + require EVERY archive to be present in the
#                     HARMONY_DEPS_CACHE with a matching SHA-256. A cache miss
#                     FAILS PRECISELY; there is NO network fallback in offline
#                     mode, ever.
#   --fetch-missing   default + download cache misses (curl) into
#                     HARMONY_DEPS_CACHE, verifying SHA-256 before accepting.
#   --verify-cache    default + verify SHA-256 of every archive present in the
#                     cache (altered-byte detection). Does not download.
#
# Offline behavior is also forced by the HARMONY_DEPS_OFFLINE=1 environment
# variable. In offline mode a missing cached archive is a hard failure:
# "cache miss for <id>: <archive> not in HARMONY_DEPS_CACHE; no network
# fallback in offline mode".
#
# An archive whose bytes were altered after caching is rejected BEFORE any
# extraction: the expected SHA-256 is compared to the on-disk file and the
# mismatch aborts with "SHA-256 mismatch for <id>".
#
# Usage:
#   scripts/harmonyos/check-dependency-manifest.sh [--offline|--fetch-missing|--verify-cache]
#
# Environment:
#   HARMONY_DEPS_CACHE    directory holding fetched archives (required unless
#                         --check-only semantics apply: default mode validates
#                         the manifest without touching archives)
#   HARMONY_DEPS_OFFLINE  =1 forces offline mode (no network fallback)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MANIFEST="${REPO_ROOT}/harmonyos/dependencies/manifest.json"
SCHEMA="${REPO_ROOT}/harmonyos/dependencies/manifest.schema.json"

MODE="default"
FETCH_MISSING=0
VERIFY_CACHE=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --offline) MODE="offline"; shift ;;
    --fetch-missing) MODE="fetch"; shift ;;
    --verify-cache) MODE="verify"; shift ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    --schema) SCHEMA="$2"; shift 2 ;;
    *)
      echo "ERROR: unknown argument: ${1} (see -h)" >&2
      exit 2
      ;;
  esac
done

if [ "${HARMONY_DEPS_OFFLINE:-0}" = "1" ]; then
  MODE="offline"
fi

failures=0
warnings=0

err()  { printf 'ERROR: %s\n' "$*" >&2; failures=$((failures + 1)); }
warn() { printf 'WARN:  %s\n' "$*" >&2; warnings=$((warnings + 1)); }

# ---------------------------------------------------------------------------
# 1. JSON parse + schema validation
# ---------------------------------------------------------------------------
if [ ! -f "$MANIFEST" ]; then
  err "manifest not found: ${MANIFEST}"
  echo "MANIFEST_CHECK=FAIL" >&2
  exit 1
fi

if ! python3 - "$MANIFEST" <<'PYEOF' 2>/dev/null; then
import json, sys
json.load(open(sys.argv[1]))
PYEOF
  err "manifest is not valid JSON"
fi

# Full schema validation via python3+jsonschema when available.
python3 - "$MANIFEST" "$SCHEMA" <<'PYEOF'
import json, sys
try:
    import jsonschema
except ImportError:
    sys.exit(0)  # skip structural schema validation; semantic checks below still run
manifest = json.load(open(sys.argv[1]))
schema = json.load(open(sys.argv[2]))
jsonschema.validate(manifest, schema)
PYEOF
schema_rc=$?
if [ "$schema_rc" -ne 0 ]; then
  err "manifest failed JSON schema validation (schema: ${SCHEMA})"
fi

# ---------------------------------------------------------------------------
# 2. Semantic validation (bash + python3 for the heavy lifting)
# ---------------------------------------------------------------------------
python3 - "$MANIFEST" <<'PYEOF' > /tmp/ohos-deps-semantic.txt || true
import json, re, sys
manifest = json.load(open(sys.argv[1]))
issues = []

URL_IMMUTABLE_BAD = re.compile(r'(refs/heads/|/tree/(main|master)|/tree/dev|/archive/refs/heads/|@(main|master|dev)\b|\blatest\b)', re.I)
SHA_RE = re.compile(r'^[0-9a-f]{64}$')

for dep in manifest["dependencies"]:
    ident = dep["id"]
    if dep["source"] == "archive":
        url = dep.get("url")
        if not url:
            issues.append(f"{ident}: archive-source dependency requires an immutable url")
        else:
            if not url.startswith("https://"):
                issues.append(f"{ident}: url must be https, got {url!r}")
            if URL_IMMUTABLE_BAD.search(url):
                issues.append(f"{ident}: url references a mutable branch/ref: {url}")
            # Immutable release URLs must embed an explicit version in the path
            if not re.search(r'/(v?\d[\w.-]*|release-\d[\w.-]*)/|[\w.-]*\.(tar\.(gz|xz|bz2)|tgz|zip)$', url):
                issues.append(f"{ident}: url does not look like an immutable versioned release URL: {url}")
        sha = dep.get("sha256")
        if not sha:
            issues.append(f"{ident}: archive-source dependency requires sha256")
        elif not SHA_RE.match(sha):
            issues.append(f"{ident}: sha256 is not 64 lowercase hex chars: {sha!r}")
        if not dep.get("archive"):
            issues.append(f"{ident}: archive-source dependency requires archive filename")
    elif dep["source"] == "ndk":
        if dep.get("url") is not None or dep.get("sha256") is not None:
            issues.append(f"{ident}: ndk-source dependency must have null url and sha256")
    elif dep["source"] == "bundled-upstream":
        pass  # in-tree; nothing to fetch

    lic = dep.get("license", {})
    if not lic.get("spdx"):
        issues.append(f"{ident}: missing license.spdx")
    if not lic.get("licenseFile"):
        issues.append(f"{ident}: missing license.licenseFile")
    if dep.get("linkage") not in ("static", "shared", "system", "static+shared"):
        issues.append(f"{ident}: invalid linkage {dep.get('linkage')!r}")
    abis = dep.get("abis") or []
    if not abis or not set(abis).issubset({"arm64-v8a", "x86_64"}):
        issues.append(f"{ident}: invalid/empty abis {abis!r}")
    if not dep.get("updateOwner"):
        issues.append(f"{ident}: missing updateOwner")
    if not dep.get("buildRole"):
        issues.append(f"{ident}: missing buildRole")

if issues:
    print("\n".join(issues))
    sys.exit(1)
PYEOF
if [ -s /tmp/ohos-deps-semantic.txt ]; then
  while IFS= read -r line; do err "$line"; done < /tmp/ohos-deps-semantic.txt
fi
rm -f /tmp/ohos-deps-semantic.txt

# ---------------------------------------------------------------------------
# 3. Cache + SHA verification
# ---------------------------------------------------------------------------
CACHE="${HARMONY_DEPS_CACHE:-}"
if [ "$MODE" != "default" ]; then
  if [ -z "$CACHE" ]; then
    err "HARMONY_DEPS_CACHE is not set but required for mode '${MODE}'"
  elif [ ! -d "$CACHE" ]; then
    err "HARMONY_DEPS_CACHE is not a directory: ${CACHE}"
  fi
fi

# Generate a deterministic cache report for every archive-source dependency.
generate_cache_report() {
  python3 - "$MANIFEST" "$CACHE" <<'PYEOF'
import hashlib, json, os, sys
manifest = json.load(open(sys.argv[1]))
cache = sys.argv[2]
missing, mismatch, ok = [], [], []
for dep in manifest["dependencies"]:
    if dep.get("source") != "archive":
        continue
    archive = dep["archive"]
    path = os.path.join(cache, archive)
    if not os.path.isfile(path):
        missing.append((dep["id"], archive)); continue
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    if h.hexdigest() == dep["sha256"]:
        ok.append((dep["id"], archive))
    else:
        mismatch.append((dep["id"], archive, dep["sha256"], h.hexdigest()))
print("CACHE_MISS_COUNT=%d" % len(missing))
for ident, archive in missing:
    print("MISS %s %s" % (ident, archive))
print("CACHE_MISMATCH_COUNT=%d" % len(mismatch))
for ident, archive, expect, got in mismatch:
    print("MISMATCH %s %s %s %s" % (ident, archive, expect, got))
print("CACHE_OK_COUNT=%d" % len(ok))
for ident, archive in ok:
    print("OK %s %s" % (ident, archive))
PYEOF
}

# ---------------------------------------------------------------------------
# 4. Mode-specific archive handling
# ---------------------------------------------------------------------------
if [ -n "$CACHE" ] && [ -d "$CACHE" ]; then
  report="$(generate_cache_report)"
  miss_count="$(printf '%s\n' "$report" | sed -n 's/^CACHE_MISS_COUNT=//p')"
  mismatch_count="$(printf '%s\n' "$report" | sed -n 's/^CACHE_MISMATCH_COUNT=//p')"
  ok_count="$(printf '%s\n' "$report" | sed -n 's/^CACHE_OK_COUNT=//p')"

  # Reject altered bytes in ANY mode that touches the cache (offline, verify).
  if [ "$MODE" = "offline" ] || [ "$MODE" = "verify" ]; then
    while IFS= read -r line; do
      case "$line" in
        MISMATCH\ *)
          set -- $line
          ident="$2"; archive="$3"; expect="$4"; got="$5"
          err "SHA-256 mismatch for ${ident}: ${archive} in cache does not match pinned ${expect} (got ${got}); refusing to use the altered archive"
          ;;
      esac
    done <<< "$report"
  fi

  if [ "$MODE" = "offline" ]; then
    # Cache miss in offline mode = precise hard failure, no network fallback.
    if [ "${miss_count:-0}" -gt 0 ]; then
      while IFS= read -r line; do
        case "$line" in
          MISS\ *)
            set -- $line
            err "cache miss for ${2}: ${3} not found in HARMONY_DEPS_CACHE (${CACHE}); no network fallback in offline mode — fetch once with --fetch-missing"
            ;;
        esac
      done <<< "$report"
    else
      printf 'offline cache check: %s archive(s) present and SHA-256 verified (no network used)\n' "$ok_count"
    fi
  elif [ "$MODE" = "verify" ]; then
    printf 'cache verify: %s archive(s) verified against pinned SHA-256\n' "$ok_count"
    if [ "${miss_count:-0}" -gt 0 ]; then
      while IFS= read -r line; do
        case "$line" in
          MISS\ *)
            set -- $line
            warn "cache miss (verify mode does not download): ${2} (${3})"
            ;;
        esac
      done <<< "$report"
    fi
  fi

  if [ "$MODE" = "fetch" ]; then
    # Download cache misses; verify SHA-256 before accepting.
    if [ "${miss_count:-0}" -gt 0 ]; then
      while IFS= read -r line; do
        case "$line" in
          MISS\ *)
            set -- $line
            ident="$2"; archive="$3"
            url="$(python3 - "$MANIFEST" "$ident" <<'PYEOF'
import json, sys
manifest = json.load(open(sys.argv[1]))
for dep in manifest["dependencies"]:
    if dep["id"] == sys.argv[2]:
        print(dep["url"]); break
PYEOF
)"
            dest="${CACHE}/${archive}"
            tmp="${dest}.part"
            printf 'fetching %s -> %s\n' "$url" "$dest"
            if ! curl -fsSL --retry 2 --max-time 600 -o "$tmp" "$url"; then
              rm -f "$tmp"
              err "download failed for ${ident}: ${url}"
              continue
            fi
            got="$(shasum -a 256 "$tmp" | awk '{print $1}')"
            expect="$(python3 - "$MANIFEST" "$ident" <<'PYEOF'
import json, sys
manifest = json.load(open(sys.argv[1]))
for dep in manifest["dependencies"]:
    if dep["id"] == sys.argv[2]:
        print(dep["sha256"]); break
PYEOF
)"
            if [ "$got" != "$expect" ]; then
              rm -f "$tmp"
              err "SHA-256 mismatch after download for ${ident}: got ${got}, expected ${expect}; refusing to cache"
            else
              mv "$tmp" "$dest"
              printf 'cached %s (sha256 %s verified)\n' "$archive" "$got"
            fi
            ;;
        esac
      done <<< "$report"
    else
      printf 'fetch: nothing to download; all %s archive(s) already cached\n' "$ok_count"
    fi
  fi
elif [ "$MODE" != "default" ]; then
  # cache dir missing / unset — already reported above
  :
else
  printf 'default mode: manifest validated; HARMONY_DEPS_CACHE not set, no archive verification performed (use --offline/--verify-cache/--fetch-missing)\n'
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf 'manifest check: %d error(s), %d warning(s)\n' "$failures" "$warnings"
if [ "$failures" -ne 0 ]; then
  echo "DEPENDENCY_MANIFEST_CHECK=FAIL" >&2
  exit 1
fi
echo "DEPENDENCY_MANIFEST_CHECK=PASS"
exit 0
