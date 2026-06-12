#!/usr/bin/env bash
# test/e2e/phase6_clojure_set_cycle1.sh
#
# Phase 6.10 cycle 1 EXIT smoke — clojure.set Group A (5 vars) +
# the supporting `rt/hash-set` constructor + set pr-str.
#
# Per survey §6 (cycles 2-3 conditional on map-primitives) — cycle 1
# stops at Group A. Group B (rename-keys / map-invert) lands in a
# later cycle alongside map-related primitive registration; Group C
# (relational ops) waits for set-literal #{...} Reader support (D-061).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() {
    echo "FAIL $1" >&2
    exit 1
}

assert_eq() {
    local name="$1"
    local got="$2"
    local want="$3"
    if [[ "$got" != "$want" ]]; then
        fail "$name: got '$got', want '$want'"
    fi
    echo "PASS $name -> $want"
}

# --- hash-set constructor + pr-str of sets ---

got="$("$BIN" -e '(hash-set 1 2 3)')"
# Set element order is hash-determined (ArrayMap insertion order at <= 8).
# Just check it round-trips with all three elements present in pr-str.
case "$got" in
    "#{1 2 3}"|"#{1 3 2}"|"#{2 1 3}"|"#{2 3 1}"|"#{3 1 2}"|"#{3 2 1}")
        echo "PASS hash_set_three_ints -> $got" ;;
    *)
        fail "hash_set_three_ints: unexpected '$got'" ;;
esac

got="$("$BIN" -e '(hash-set)')"
assert_eq 'hash_set_empty' "$got" '#{}'

# --- subset? / superset? ---

got="$("$BIN" -e '(clojure.set/subset? (hash-set 1 2) (hash-set 1 2 3))')"
assert_eq 'subset_true' "$got" 'true'

got="$("$BIN" -e '(clojure.set/subset? (hash-set 1 4) (hash-set 1 2 3))')"
assert_eq 'subset_false' "$got" 'false'

got="$("$BIN" -e '(clojure.set/subset? (hash-set) (hash-set 1 2))')"
assert_eq 'subset_empty' "$got" 'true'

got="$("$BIN" -e '(clojure.set/superset? (hash-set 1 2 3) (hash-set 1 2))')"
assert_eq 'superset_true' "$got" 'true'

got="$("$BIN" -e '(clojure.set/superset? (hash-set 1) (hash-set 1 2))')"
assert_eq 'superset_false' "$got" 'false'

# --- union ---

# Element order is hash-determined; use count as the stable check.
got="$("$BIN" -e '(clojure.set/subset? (hash-set 1 2 3) (clojure.set/union (hash-set 1 2) (hash-set 2 3)))')"
assert_eq 'union_via_subset' "$got" 'true'

got="$("$BIN" -e '(clojure.set/subset? (clojure.set/union (hash-set 1 2) (hash-set 2 3)) (hash-set 1 2 3))')"
assert_eq 'union_no_extras' "$got" 'true'

got="$("$BIN" -e '(clojure.set/union (hash-set))')"
assert_eq 'union_single_empty' "$got" '#{}'

got="$("$BIN" -e '(clojure.set/union (hash-set 7))')"
assert_eq 'union_single_one' "$got" '#{7}'

# --- intersection ---

got="$("$BIN" -e '(clojure.set/intersection (hash-set 1 2 3) (hash-set 2 3 4))')"
# Result must be #{2 3} in some order — convert to subset check.
got2="$("$BIN" -e '(clojure.set/subset? (clojure.set/intersection (hash-set 1 2 3) (hash-set 2 3 4)) (hash-set 2 3))')"
got3="$("$BIN" -e '(clojure.set/subset? (hash-set 2 3) (clojure.set/intersection (hash-set 1 2 3) (hash-set 2 3 4)))')"
assert_eq 'intersection_subset_of_expected' "$got2" 'true'
assert_eq 'intersection_superset_of_expected' "$got3" 'true'

got="$("$BIN" -e '(clojure.set/intersection (hash-set 1) (hash-set 9))')"
assert_eq 'intersection_disjoint' "$got" '#{}'

# --- difference ---

got2="$("$BIN" -e '(clojure.set/subset? (clojure.set/difference (hash-set 1 2 3) (hash-set 2)) (hash-set 1 3))')"
got3="$("$BIN" -e '(clojure.set/subset? (hash-set 1 3) (clojure.set/difference (hash-set 1 2 3) (hash-set 2)))')"
assert_eq 'difference_subset_of_expected' "$got2" 'true'
assert_eq 'difference_superset_of_expected' "$got3" 'true'

got="$("$BIN" -e '(clojure.set/difference (hash-set 1 2) (hash-set 1 2 3))')"
assert_eq 'difference_to_empty' "$got" '#{}'

echo "phase6_clojure_set_cycle1: all 16 cases passed"
