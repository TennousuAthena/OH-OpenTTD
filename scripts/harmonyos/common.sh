#!/usr/bin/env bash
# common.sh — shared bash helpers for the OpenTTD HarmonyOS port scripts.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
#
# Provides:
#   Logging:   ohos_info, ohos_warn, ohos_error, ohos_die
#   Checks:    ohos_check_file, ohos_check_dir, ohos_check_tool
#   JSON:      ohos_json_escape, ohos_json_string_field,
#              ohos_json_number_field, ohos_json_string_array
#
# All helpers are safe under `set -euo pipefail`:
#   - no unbound variable expansion (all expansions use :- defaults)
#   - check helpers RETURN nonzero instead of exiting, so callers can
#     collect multiple failures before deciding to abort
#   - ohos_die is the only helper that exits
#
# No user-specific absolute paths appear in this file.

# Double-source guard.
if [ -n "${OHOS_COMMON_SH_LOADED:-}" ]; then
  return 0
fi
OHOS_COMMON_SH_LOADED=1

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

# ohos_log <level> <message...>
# Prints "[HH:MM:SS] [level] message" to stdout (stderr for ERROR).
ohos_log() {
  local level="$1"
  shift
  local line
  line=$(printf '[%s] [%s] %s' "$(date '+%H:%M:%S')" "$level" "$*")
  if [ "$level" = "ERROR" ]; then
    printf '%s\n' "$line" >&2
  else
    printf '%s\n' "$line"
  fi
}

ohos_info()  { ohos_log "INFO"  "$@"; }
ohos_warn()  { ohos_log "WARN"  "$@"; }
ohos_error() { ohos_log "ERROR" "$@"; }

# ohos_die <message...> [exit-code]
# Prints an ERROR line and exits (default code 1).
ohos_die() {
  local code=1
  if [ $# -gt 0 ] && [[ "${!#}" =~ ^[0-9]+$ ]]; then
    code="${!#}"
    # Drop the trailing numeric argument from the message.
    set -- "${@:1:$#-1}"
  fi
  ohos_error "$@"
  exit "$code"
}

# ---------------------------------------------------------------------------
# Validation helpers (return nonzero, never exit — safe for error collection)
# ---------------------------------------------------------------------------

# ohos_check_file <path> <description>
# Succeeds if <path> is a regular file; otherwise prints a precise ERROR.
ohos_check_file() {
  local path="$1"
  local what="$2"
  if [ -f "$path" ]; then
    return 0
  fi
  ohos_error "missing required ${what}: ${path}"
  return 1
}

# ohos_check_dir <path> <description>
# Succeeds if <path> is a directory; otherwise prints a precise ERROR.
ohos_check_dir() {
  local path="$1"
  local what="$2"
  if [ -d "$path" ]; then
    return 0
  fi
  ohos_error "missing required ${what}: ${path}"
  return 1
}

# ohos_check_tool <path-or-name> <description>
# Succeeds if the tool is an executable file or resolvable via PATH.
ohos_check_tool() {
  local tool="$1"
  local what="$2"
  if [ -x "$tool" ] || command -v "$tool" >/dev/null 2>&1; then
    return 0
  fi
  ohos_error "missing required ${what}: ${tool} (not executable and not on PATH)"
  return 1
}

# ---------------------------------------------------------------------------
# JSON emission helpers
# ---------------------------------------------------------------------------

# ohos_json_escape <string>
# Prints the string escaped for embedding inside a JSON double-quoted value.
ohos_json_escape() {
  local s="$1"
  s=${s//\\/\\\\}   # backslash first
  s=${s//\"/\\\"}   # double quote
  s=${s//$'\t'/\\t} # tab
  s=${s//$'\r'/\\r} # carriage return
  s=${s//$'\n'/\\n} # newline
  printf '%s' "$s"
}

# ohos_json_string_field <key> <value>
# Prints: "key": "value"
ohos_json_string_field() {
  printf '"%s": "%s"' "$(ohos_json_escape "$1")" "$(ohos_json_escape "$2")"
}

# ohos_json_number_field <key> <number>
# Prints: "key": 123   (no validation; caller must pass a numeric literal)
ohos_json_number_field() {
  printf '"%s": %s' "$(ohos_json_escape "$1")" "$2"
}

# ohos_json_string_array <element...>
# Prints: ["a", "b", "c"]   (empty arg list -> [])
ohos_json_string_array() {
  local out="["
  local first=1
  local elem
  for elem in "$@"; do
    if [ "$first" -eq 1 ]; then
      first=0
    else
      out+=", "
    fi
    out+="\"$(ohos_json_escape "$elem")\""
  done
  out+="]"
  printf '%s' "$out"
}
