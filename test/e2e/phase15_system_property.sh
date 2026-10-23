#!/usr/bin/env bash
# test/e2e/phase15_system_property.sh — the environment half of
# System/getProperty + System/getenv. Each case sets or unsets a variable in
# the CHILD's environment (TMPDIR, CLJW_GETENV_PROBE, PG_PORT), which a suite
# running in an already-started process cannot do. Everything that reads the
# fixed property table lives in test/clj/suites/concurrency_host_test.clj
# (p15-system-property) and test/clj/suites/system_properties_test.clj.
# e2e-process-boundary: the cases set the child process environment (TMPDIR / getenv probes)
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# java.io.tmpdir is JVM-faithful: /tmp regardless of $TMPDIR
assert_eq 'tmpdir-default'     "$(env -u TMPDIR "$BIN" -e '(System/getProperty "java.io.tmpdir")' 2>&1 | tail -1)" '"/tmp"'
assert_eq 'tmpdir-ignores-env' "$(TMPDIR=/custom/tmp "$BIN" -e '(System/getProperty "java.io.tmpdir")' 2>&1 | tail -1)" '"/tmp"'
# System/getenv reads the process environment (present -> value; FQCN parity; realistic default)
assert_eq 'getenv'         "$(CLJW_GETENV_PROBE=hi "$BIN" -e '(System/getenv "CLJW_GETENV_PROBE")' 2>&1 | tail -1)" '"hi"'
assert_eq 'getenv-fqcn'    "$(CLJW_GETENV_PROBE=hi "$BIN" -e '(java.lang.System/getenv "CLJW_GETENV_PROBE")' 2>&1 | tail -1)" '"hi"'
assert_eq 'getenv-default' "$(PG_PORT=9999 "$BIN" -e '(or (System/getenv "PG_PORT") "8080")' 2>&1 | tail -1)" '"9999"'

echo "OK — phase15_system_property (5 environment cases) green"
