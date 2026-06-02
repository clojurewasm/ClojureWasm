#!/usr/bin/env bash
# test/e2e/phase14_parallel_seq.sh — pmap / pcalls / pvalues + doall / dorun.
# cw v1 is single-threaded, so pmap/pcalls/pvalues run SEQUENTIALLY — the RESULT
# is identical to clj (pmap is "semantically like map"); real parallelism is
# deferred to Phase-15 threading (D-224). doall/dorun realize a lazy seq for
# side effects (the natural companion to lazy pmap results). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# pmap (result == map): 1-coll, multi-coll, empty
assert_eq 'pmap'      "$("$BIN" -e '(pmap inc [1 2 3])')"          '(2 3 4)'
assert_eq 'pmap_multi' "$("$BIN" -e '(pmap + [1 2 3] [10 20 30])')" '(11 22 33)'
assert_eq 'pmap_empty' "$("$BIN" -e '(pmap inc [])')"             '()'
# pcalls / pvalues
assert_eq 'pcalls'    "$("$BIN" -e '(pcalls (constantly 1) (constantly 2))')" '(1 2)'
assert_eq 'pvalues'   "$("$BIN" -e '(pvalues (+ 1 2) (* 3 4))')"  '(3 12)'
assert_eq 'pvalues1'  "$("$BIN" -e '(pvalues 42)')"              '(42)'
# doall / dorun realize for side effects
assert_eq 'doall'     "$("$BIN" -e '(doall (map inc [1 2 3]))')"  '(2 3 4)'
assert_eq 'doall_vec' "$("$BIN" -e '(doall [1 2 3])')"           '[1 2 3]'
assert_eq 'dorun'     "$("$BIN" -e '(dorun [1 2 3])')"           'nil'
assert_eq 'doall_eff' "$("$BIN" -e '(let [a (atom 0)] (doall (map (fn [_] (swap! a inc)) (range 5))) @a)')" '5'
assert_eq 'dorun_pmap' "$("$BIN" -e '(let [a (atom 0)] (dorun (pmap (fn [_] (swap! a inc)) (range 4))) @a)')" '4'
assert_eq 'dorun_n'   "$("$BIN" -e '(dorun 3 (range 100))')"     'nil'

echo "OK — phase14_parallel_seq (12 cases) green"
