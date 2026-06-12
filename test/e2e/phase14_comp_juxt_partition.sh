#!/usr/bin/env bash
# test/e2e/phase14_comp_juxt_partition.sh
#
# D-134 residuals — clojure.core multi-arity: comp (0/1/2/N-ary, right-
# to-left, any composed arity via apply), juxt (multi-fn + multi-arg),
# partition 4-arg pad. All Pattern A `.clj` over existing primitives
# (multi-arity fn* + apply + reduce + conj + concat).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# comp
assert_eq 'comp_3ary'   "$("$BIN" -e '((comp inc inc inc) 0)')"   '3'
assert_eq 'comp_0ary'   "$("$BIN" -e '((comp) 5)')"               '5'
assert_eq 'comp_1ary'   "$("$BIN" -e '((comp inc) 5)')"           '6'
assert_eq 'comp_2ary'   "$("$BIN" -e '((comp inc dec) 5)')"       '5'
assert_eq 'comp_mixed'  "$("$BIN" -e '((comp str inc) 5)')"       '"6"'
assert_eq 'comp_applyarity' "$("$BIN" -e '((comp inc +) 1 2 3)')" '7'
# juxt
assert_eq 'juxt_3fn'    "$("$BIN" -e '((juxt inc dec str) 5)')"   '[6 4 "5"]'
assert_eq 'juxt_multiarg' "$("$BIN" -e '((juxt + -) 10 3)')"      '[13 7]'
assert_eq 'juxt_1fn'    "$("$BIN" -e '((juxt inc) 5)')"           '[6]'
# partition
assert_eq 'partition_2arg' "$("$BIN" -e '(partition 2 [1 2 3 4])')"          '((1 2) (3 4))'
assert_eq 'partition_pad'  "$("$BIN" -e '(partition 2 2 [9] [1 2 3 4 5])')"  '((1 2) (3 4) (5 9))'
assert_eq 'partition_pad_short' "$("$BIN" -e '(partition 3 3 [0] [1 2 3 4])')" '((1 2 3) (4 0))'

echo "OK — phase14_comp_juxt_partition smoke (12 cases) green"
