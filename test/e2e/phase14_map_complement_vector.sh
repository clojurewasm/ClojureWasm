#!/usr/bin/env bash
# test/e2e/phase14_map_complement_vector.sh
#
# D-134 residuals — `complement` multi-arg, `map` multi-coll (1/2/3-coll,
# parallel, stop-at-shortest), and the `vector` fn. All Pattern A `.clj`.
# (No diff_test: these are bootstrap `.clj` closures, which the Phase-4
# compare harness can't cover cross-backend — D-152; e2e is the coverage.)

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

assert_eq 'complement_multiarg' "$("$BIN" -e '((complement <) 3 5)')"   'false'
assert_eq 'complement_1arg'     "$("$BIN" -e '((complement nil?) 5)')"  'true'
assert_eq 'map_1coll'           "$("$BIN" -e '(map inc [1 2 3])')"      '(2 3 4)'
assert_eq 'map_2coll'           "$("$BIN" -e '(map + [1 2 3] [10 20 30])')" '(11 22 33)'
assert_eq 'map_2coll_shortest'  "$("$BIN" -e '(map + [1 2 3] [10 20])')"    '(11 22)'
assert_eq 'map_3coll'           "$("$BIN" -e '(map + [1 2] [10 20] [100 200])')" '(111 222)'
assert_eq 'map_zip'             "$("$BIN" -e '(map (fn* [a b] [a b]) [:a :b] [1 2])')" '([:a 1] [:b 2])'
assert_eq 'vector_args'         "$("$BIN" -e '(vector 1 2 3)')"         '[1 2 3]'
assert_eq 'vector_empty'        "$("$BIN" -e '(vector)')"              '[]'
assert_eq 'map_vector_idiom'    "$("$BIN" -e '(map vector [:a :b :c] [1 2 3])')" '([:a 1] [:b 2] [:c 3])'
assert_eq 'apply_vector'        "$("$BIN" -e '(apply vector [1 2 3])')" '[1 2 3]'

echo "OK — phase14_map_complement_vector smoke (11 cases) green"
