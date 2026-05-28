#!/usr/bin/env bash
# test/e2e/phase14_reduce_helpers.sh
#
# Phase 14 §9.16 row 14.13 — D-134 cluster 5. max-key / min-key /
# flatten / reductions. Pattern A over reduce / conj / last / into /
# sequential? / >= / <=. (sort/sort-by deferred — need a compare op +
# sort algorithm.) reductions is the 3-arg [f init coll] form.
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

assert_eq 'max_key'      "$("$BIN" -e '(max-key count [1] [1 2 3] [1 2])')"   '[1 2 3]'
assert_eq 'min_key'      "$("$BIN" -e '(min-key count [1 2 3] [1] [1 2])')"   '[1]'
assert_eq 'flatten'      "$("$BIN" -e '(into [] (flatten [1 [2 [3 4]] 5]))')" '[1 2 3 4 5]'
assert_eq 'flatten_flat' "$("$BIN" -e '(into [] (flatten [1 2 3]))')"         '[1 2 3]'
assert_eq 'reductions'   "$("$BIN" -e '(into [] (reductions + 0 [1 2 3]))')"  '[0 1 3 6]'

echo "ALL phase14_reduce_helpers PASS"
