#!/usr/bin/env bash
# test/e2e/phase14_accessors.sh
#
# Phase 14 §9.16 row 14.13 — D-134 cluster 6. second / ffirst / not-empty
# / take-last / drop-last. Trivial Pattern A over first/rest/empty?/take/
# reverse/butlast (no compare dependency). (sort/sort-by deferred behind
# D-137 — compare is numeric-only.)
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

assert_eq 'second'        "$("$BIN" -e '(second [1 2 3])')"                 '2'
assert_eq 'second_short'  "$("$BIN" -e '(second [1])')"                     'nil'
assert_eq 'ffirst'        "$("$BIN" -e '(ffirst [[1 2] [3]])')"            '1'
assert_eq 'not_empty_e'   "$("$BIN" -e '(not-empty [])')"                   'nil'
assert_eq 'not_empty_ne'  "$("$BIN" -e '(not-empty [1])')"                  '[1]'
assert_eq 'take_last'     "$("$BIN" -e '(into [] (take-last 2 [1 2 3]))')"  '[2 3]'
assert_eq 'drop_last'     "$("$BIN" -e '(into [] (drop-last [1 2 3]))')"    '[1 2]'

echo "ALL phase14_accessors PASS"
