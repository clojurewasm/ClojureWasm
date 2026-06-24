#!/usr/bin/env bash
# test/e2e/phase6_set_map_literal.sh
#
# Phase 6.16.b-2 — `#{...}` set literal reader (D-061) +
# `{...}` map literal as expression value (D-059). Generic
# reader/analyzer infra independent of clojure.set; the
# Group C `.clj` defns in 6.16.b-3 sit on top of this.

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

# --- set literal ---
assert_eq 'set_three_ints'   "$("$BIN" -e '#{1 2 3}')"               '#{1 2 3}'
assert_eq 'set_empty'        "$("$BIN" -e '#{}')"                    '#{}'
assert_eq 'set_count'        "$("$BIN" -e '(count #{:a :b :c})')"    '3'
assert_eq 'set_contains'     "$("$BIN" -e '(contains? #{:a :b} :a)')" 'true'
assert_eq 'set_duplicates'   "$("$BIN" -e '(count #{1 1 2 2 3})')"    '3'
assert_eq 'set_subset'       "$("$BIN" -e '(do (require (quote [clojure.set])) (clojure.set/subset? #{1 2} #{1 2 3}))')" 'true'

# --- map literal ---
assert_eq 'map_one_entry'    "$("$BIN" -e '{:a 1}')"                  '{:a 1}'
assert_eq 'map_empty'        "$("$BIN" -e '{}')"                      '{}'
assert_eq 'map_count'        "$("$BIN" -e '(count {:a 1 :b 2 :c 3})')" '3'
assert_eq 'map_get'          "$("$BIN" -e '(get {:a 1 :b 2} :a)')"   '1'
assert_eq 'map_keys'         "$("$BIN" -e '(count (keys {:a 1 :b 2}))')" '2'

# --- nested literals ---
assert_eq 'set_in_map'       "$("$BIN" -e '(count (get {:s #{1 2 3}} :s))')" '3'
assert_eq 'map_in_set'       "$("$BIN" -e '(count #{{:a 1} {:b 2}})')" '2'
assert_eq 'vector_in_map'    "$("$BIN" -e '(count (get {:v [1 2 3]} :v))')" '3'

# --- composition with clojure.set ---
assert_eq 'union_literals'   "$("$BIN" -e '(do (require (quote [clojure.set])) (clojure.set/union #{1 2} #{2 3}))')" '#{1 2 3}'
assert_eq 'rename_literal'   "$("$BIN" -e '(do (require (quote [clojure.set])) (clojure.set/rename-keys {:a 1 :b 2} {:a :A}))')" '{:b 2, :A 1}'
assert_eq 'invert_literal'   "$("$BIN" -e '(do (require (quote [clojure.set])) (clojure.set/map-invert {:a 1 :b 2}))')" '{1 :a, 2 :b}'

# --- evaluation order (expressions inside literals) ---
assert_eq 'set_evals_inside' "$("$BIN" -e '(count #{(+ 1 1) (+ 2 0) 3})')" '2'
assert_eq 'map_evals_inside' "$("$BIN" -e '(get {(+ 0 1) (+ 10 10)} 1)')" '20'

# --- map odd-arity rejection ---
got=$("$BIN" -e '{:a}' 2>&1 || true)
case "$got" in
    *"Syntax error"*|*"unexpected"*|*"odd"*|*"arity"*)
        echo "PASS map_odd_rejected" ;;
    *)
        fail "map_odd_rejected: expected error, got '$got'" ;;
esac

echo ""
echo "=== phase6_set_map_literal: all assertions passed (D-061 + D-059 closed) ==="
