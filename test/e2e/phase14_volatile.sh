#!/usr/bin/env bash
# test/e2e/phase14_volatile.sh — volatile! / vreset! / vswap! / volatile?
# (unsynchronized mutable box; atom minus CAS/watch). Corpus gap sweep P0.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_eq 'deref_at'  "$("$BIN" -e '@(volatile! 7)')"                      '7'
assert_eq 'deref_fn'  "$("$BIN" -e '(deref (volatile! 5))')"               '5'
assert_eq 'vreset'    "$("$BIN" -e '(let [v (volatile! 0)] (vreset! v 9) @v)')" '9'
assert_eq 'vreset_r'  "$("$BIN" -e '(vreset! (volatile! 0) 3)')"           '3'
assert_eq 'vswap'     "$("$BIN" -e '(let [v (volatile! 0)] (vswap! v inc) @v)')" '1'
assert_eq 'vswap_arg' "$("$BIN" -e '(vswap! (volatile! 1) + 10 100)')"     '111'
assert_eq 'volQ_t'    "$("$BIN" -e '(volatile? (volatile! 0))')"           'true'
assert_eq 'volQ_atom' "$("$BIN" -e '(volatile? (atom 0))')"               'false'
assert_eq 'volQ_n'    "$("$BIN" -e '(volatile? 5)')"                       'false'
echo "OK — phase14_volatile smoke (9 cases) green"
