#!/usr/bin/env bash
# test/e2e/phase6_clojure_set_group_ab.sh
#
# Phase 6.16.b-1 — Group A + B `clojure.set` vars as Pattern A
# `.clj` defns (v5 §8.2 + §9.2; survey rec (b) sub-cycle 1).
#
# Group A: union / intersection / difference / subset? / superset?
# Group B: rename-keys / map-invert
#
# 2-arity surface only — variadic 3+ deferred to D-070 closure.
# Group C (select / project / index / rename / join) lands at
# 6.16.b-3 after D-061 (#{} reader) + D-059 (map-literal analyzer).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
zig build >/dev/null

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

# --- union (2-arity) ---
assert_eq 'union_basic'    "$("$BIN" -e '(clojure.set/union (hash-set 1 2) (hash-set 2 3))')" '#{1 2 3}'
assert_eq 'union_disjoint' "$("$BIN" -e '(clojure.set/union (hash-set 1) (hash-set 2))')"     '#{1 2}'
assert_eq 'union_empty_l'  "$("$BIN" -e '(clojure.set/union (hash-set) (hash-set 1 2))')"     '#{1 2}'
assert_eq 'union_empty_r'  "$("$BIN" -e '(clojure.set/union (hash-set 1 2) (hash-set))')"     '#{1 2}'

# --- intersection (2-arity) ---
assert_eq 'inter_basic'    "$("$BIN" -e '(clojure.set/intersection (hash-set 1 2 3) (hash-set 2 3 4))')" '#{2 3}'
assert_eq 'inter_empty'    "$("$BIN" -e '(clojure.set/intersection (hash-set 1 2) (hash-set 3 4))')"     '#{}'
assert_eq 'inter_id'       "$("$BIN" -e '(clojure.set/intersection (hash-set 1 2) (hash-set 1 2))')"     '#{1 2}'

# --- difference (2-arity) ---
assert_eq 'diff_basic'     "$("$BIN" -e '(clojure.set/difference (hash-set 1 2 3) (hash-set 2 3))')" '#{1}'
assert_eq 'diff_empty_r'   "$("$BIN" -e '(clojure.set/difference (hash-set 1 2) (hash-set))')"     '#{1 2}'
assert_eq 'diff_all'       "$("$BIN" -e '(clojure.set/difference (hash-set 1 2) (hash-set 1 2))')" '#{}'

# --- subset? ---
assert_eq 'subset_true'    "$("$BIN" -e '(clojure.set/subset? (hash-set 1 2) (hash-set 1 2 3))')" 'true'
assert_eq 'subset_eq'      "$("$BIN" -e '(clojure.set/subset? (hash-set 1 2) (hash-set 1 2))')"   'true'
assert_eq 'subset_empty'   "$("$BIN" -e '(clojure.set/subset? (hash-set) (hash-set 1 2))')"       'true'
assert_eq 'subset_false'   "$("$BIN" -e '(clojure.set/subset? (hash-set 1 4) (hash-set 1 2 3))')" 'false'
assert_eq 'subset_bigger'  "$("$BIN" -e '(clojure.set/subset? (hash-set 1 2 3) (hash-set 1 2))')" 'false'

# --- superset? ---
assert_eq 'super_true'     "$("$BIN" -e '(clojure.set/superset? (hash-set 1 2 3) (hash-set 1 2))')" 'true'
assert_eq 'super_eq'       "$("$BIN" -e '(clojure.set/superset? (hash-set 1 2) (hash-set 1 2))')"   'true'
assert_eq 'super_false'    "$("$BIN" -e '(clojure.set/superset? (hash-set 1 2) (hash-set 1 2 3))')" 'false'

# --- rename-keys ---
assert_eq 'rename_basic'   "$("$BIN" -e '(clojure.set/rename-keys (hash-map :a 1 :b 2) (hash-map :a :A))')" '{:b 2, :A 1}'
assert_eq 'rename_absent'  "$("$BIN" -e '(clojure.set/rename-keys (hash-map :a 1) (hash-map :missing :M))')" '{:a 1}'
assert_eq 'rename_noop'    "$("$BIN" -e '(clojure.set/rename-keys (hash-map :a 1) (hash-map))')" '{:a 1}'

# --- map-invert ---
assert_eq 'invert_basic'   "$("$BIN" -e '(clojure.set/map-invert (hash-map :a 1 :b 2))')" '{1 :a, 2 :b}'
assert_eq 'invert_empty'   "$("$BIN" -e '(clojure.set/map-invert (hash-map))')"           '{}'

# --- compositional sanity ---
assert_eq 'subset_of_union' "$("$BIN" -e '(clojure.set/subset? (hash-set 1) (clojure.set/union (hash-set 1) (hash-set 2)))')" 'true'
assert_eq 'inter_of_diff'   "$("$BIN" -e '(clojure.set/intersection (clojure.set/difference (hash-set 1 2 3) (hash-set 1)) (hash-set 2))')" '#{2}'

echo ""
echo "=== phase6_clojure_set_group_ab: all assertions passed (Group A + B as .clj defns; variadic 3+ deferred D-070) ==="
