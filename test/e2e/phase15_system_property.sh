#!/usr/bin/env bash
# test/e2e/phase15_system_property.sh — `(System/getProperty k [default])`.
# Returns OS-truthful values for the well-known properties cljw can answer
# (separators / os.name / os.arch / file.encoding / user.dir), nil for an
# unknown key (JVM-compatible), or the supplied default for the 2-arg form.
# POSIX-stable props are asserted by value; os.name/os.arch/user.dir vary by
# host so only their shape is asserted. Validation-campaign: test-helper opens
# with `(System/getProperty "line.separator")` at LOAD time. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# POSIX-stable, value-asserted
assert_eq 'line-sep'  "$("$BIN" -e '(System/getProperty "line.separator")' 2>&1 | tail -1)" '"\n"'
assert_eq 'path-sep'  "$("$BIN" -e '(System/getProperty "path.separator")' 2>&1 | tail -1)" '":"'
assert_eq 'file-sep'  "$("$BIN" -e '(System/getProperty "file.separator")' 2>&1 | tail -1)" '"/"'
assert_eq 'encoding'  "$("$BIN" -e '(System/getProperty "file.encoding")' 2>&1 | tail -1)" '"UTF-8"'
# host-varying, shape-asserted
assert_eq 'os-name'   "$("$BIN" -e '(string? (System/getProperty "os.name"))' 2>&1 | tail -1)" 'true'
assert_eq 'os-arch'   "$("$BIN" -e '(string? (System/getProperty "os.arch"))' 2>&1 | tail -1)" 'true'
assert_eq 'user-dir'  "$("$BIN" -e '(string? (System/getProperty "user.dir"))' 2>&1 | tail -1)" 'true'
# unknown key -> nil (JVM-compatible); 2-arg default form
assert_eq 'unknown'   "$("$BIN" -e '(System/getProperty "no.such.prop.xyz")' 2>&1 | tail -1)" 'nil'
assert_eq 'default'   "$("$BIN" -e '(System/getProperty "no.such.prop.xyz" "fallback")' 2>&1 | tail -1)" '"fallback"'
# FQCN form parity
assert_eq 'fqcn'      "$("$BIN" -e '(java.lang.System/getProperty "file.separator")' 2>&1 | tail -1)" '"/"'

# System/getenv (D-355 enabler): reads the process environment. Set inline so the
# child sees it. Present -> value, unset -> nil, FQCN parity, realistic default.
assert_eq 'getenv'         "$(CLJW_GETENV_PROBE=hi "$BIN" -e '(System/getenv "CLJW_GETENV_PROBE")' 2>&1 | tail -1)" '"hi"'
assert_eq 'getenv-missing' "$("$BIN" -e '(System/getenv "CLJW_DEFINITELY_UNSET_XYZ")' 2>&1 | tail -1)" 'nil'
assert_eq 'getenv-fqcn'    "$(CLJW_GETENV_PROBE=hi "$BIN" -e '(java.lang.System/getenv "CLJW_GETENV_PROBE")' 2>&1 | tail -1)" '"hi"'
assert_eq 'getenv-default' "$(PG_PORT=9999 "$BIN" -e '(or (System/getenv "PG_PORT") "8080")' 2>&1 | tail -1)" '"9999"'

echo "OK — phase15_system_property (14 cases) green"
