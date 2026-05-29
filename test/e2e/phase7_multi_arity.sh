#!/usr/bin/env bash
# test/e2e/phase7_multi_arity.sh
#
# Phase 7 §9.9 row 7.8 cycle 1 — multi-arity `fn*` (D-070, ADR-0041).
# Cycle 1 lands:
#   - FnNode + Function uniform `methods` slice (Option B-extracted)
#   - analyzeFnStar accepts `(fn* ([x] body1) ([x y] body2))` shape
#   - per-method `Scope.recur_target` (R1 mitigation merged in)
#   - 3 new error codes (fn_star_arity_duplicate /
#     fn_star_variadic_duplicate / arity_not_expected_multi)
#   - TreeWalk + VM dispatch via linear scan over methods
#
# OUT OF SCOPE for cycle 1:
#   - variadic + fixed coexistence (cycle 2 + JVM rule 3)
#   - `defn` macro multi-arity surface (cycle 3)
#   - PROVISIONAL discharge of clojure.set/join, comp, transducer
#     1-arg arities, multi-arg partial/complement/juxt/every? (cycle 4)

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

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

last_line() {
    awk 'END { print }' <<< "$1"
}

# --- Case 1: 2-method fn* dispatched by call-arity ---
got=$("$BIN" -e '((fn* ([x] x) ([x y] (+ x y))) 1)' 2>/dev/null) || fail "case1: non-zero exit ($got)"
assert_eq 'fn_star_two_methods_arity_1' "$got" '1'

got=$("$BIN" -e '((fn* ([x] x) ([x y] (+ x y))) 1 2)' 2>/dev/null) || fail "case1b: non-zero exit ($got)"
assert_eq 'fn_star_two_methods_arity_2' "$got" '3'

# --- Case 2: single-arity stays working (back-compat) ---
got=$("$BIN" -e '((fn* [x] (+ x 100)) 5)' 2>/dev/null) || fail "case2: non-zero exit ($got)"
assert_eq 'fn_star_single_arity_back_compat' "$got" '105'

# --- Case 3: 3 methods dispatched by call arity (no recur — runtime
# fn-body recur catch is a separate D-NNN follow-up; cycle 1's
# survey R1 mitigation is analyzer-side per-method scope creation,
# which `analyzeFnMethod` now does, but the runtime loop wrap that
# would let `recur` re-enter an fn body is pre-existing-missing).
got=$("$BIN" -e '((fn* ([] 99) ([n] n) ([a b] (+ a b))))' 2>/dev/null) || fail "case3a: non-zero exit ($got)"
assert_eq 'fn_star_three_methods_arity_0' "$got" '99'

got=$("$BIN" -e '((fn* ([] 99) ([n] n) ([a b] (+ a b))) 7)' 2>/dev/null) || fail "case3b: non-zero exit ($got)"
assert_eq 'fn_star_three_methods_arity_1' "$got" '7'

got=$("$BIN" -e '((fn* ([] 99) ([n] n) ([a b] (+ a b))) 10 20)' 2>/dev/null) || fail "case3c: non-zero exit ($got)"
assert_eq 'fn_star_three_methods_arity_2' "$got" '30'

# --- Case 4: no-matching-arity raises arity_not_expected_multi ---
diag=$("$BIN" -e '((fn* ([x] x) ([x y] y)) 1 2 3)' 2>&1 || true)
if [[ "$diag" != *"Wrong number of args"* ]] && [[ "$diag" != *"arity"* ]] && [[ "$diag" != *"expected one of"* ]]; then
    fail "case4: expected arity-not-expected diagnostic, got '$diag'"
fi
echo "PASS fn_star_no_matching_arity_diagnostic"

# --- Case 5: duplicate fixed arity raises fn_star_arity_duplicate ---
diag=$("$BIN" -e '(fn* ([x] x) ([y] y))' 2>&1 || true)
if [[ "$diag" != *"duplicate"* ]] && [[ "$diag" != *"two"* ]] && [[ "$diag" != *"same arity"* ]] && [[ "$diag" != *"more than once"* ]]; then
    fail "case5: expected fn_star_arity_duplicate diagnostic, got '$diag'"
fi
echo "PASS fn_star_arity_duplicate_diagnostic"

# --- Cycle 2: variadic + fixed coexistence ---

# --- Case 6: fixed-arity wins on exact match; variadic catches the rest ---
got=$("$BIN" -e '((fn* ([x] :one) ([x & rest] :many)) 1)' 2>/dev/null) || fail "case6a: non-zero exit ($got)"
assert_eq 'fn_star_fixed_wins_on_exact_match' "$got" ':one'

got=$("$BIN" -e '((fn* ([x] :one) ([x & rest] :many)) 1 2 3)' 2>/dev/null) || fail "case6b: non-zero exit ($got)"
assert_eq 'fn_star_variadic_catches_extra' "$got" ':many'

# --- Case 7: variadic body receives the rest as a seq-shaped collection ---
got=$("$BIN" -e '((fn* ([& xs] xs)) 1 2 3)' 2>/dev/null) || fail "case7: non-zero exit ($got)"
assert_eq 'fn_star_variadic_only_binds_rest' "$got" '(1 2 3)'

# --- Case 8: JVM rule 3 — fixed arity > variadic req raises ---
diag=$("$BIN" -e '(fn* ([x & rest] :v) ([a b c] :three))' 2>&1 || true)
if [[ "$diag" != *"exceeds"* ]] && [[ "$diag" != *"more params"* ]] && [[ "$diag" != *"variadic"* ]]; then
    fail "case8: expected fn_star_fixed_exceeds_variadic diagnostic, got '$diag'"
fi
echo "PASS fn_star_fixed_exceeds_variadic_diagnostic"

# --- Case 9: JVM rule 1 — two variadics rejected ---
diag=$("$BIN" -e '(fn* ([& a] :a) ([& b] :b))' 2>&1 || true)
if [[ "$diag" != *"more than 1 variadic"* ]] && [[ "$diag" != *"duplicate"* ]] && [[ "$diag" != *"variadic"* ]]; then
    fail "case9: expected fn_star_variadic_duplicate diagnostic, got '$diag'"
fi
echo "PASS fn_star_variadic_duplicate_diagnostic"

# --- Cycle 3: defn macro multi-arity ---

# --- Case 10: defn with multi-arity body ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defn greet
  ([] (greet "world"))
  ([name] (str "hello, " name)))
(greet)
EOF
) || fail "case10: non-zero exit ($got)"
assert_eq 'defn_multi_arity_calls_other_arity' "$(last_line "$got")" '"hello, world"'

# --- Case 11: defn multi-arity arity-2 dispatch ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defn add
  ([] 0)
  ([x] x)
  ([x y] (+ x y)))
(add 10 20)
EOF
) || fail "case11: non-zero exit ($got)"
assert_eq 'defn_multi_arity_three_methods' "$(last_line "$got")" '30'

# --- Case 12: single-arity defn (back-compat — no behaviour change) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defn square [x] (* x x))
(square 7)
EOF
) || fail "case12: non-zero exit ($got)"
assert_eq 'defn_single_arity_back_compat' "$(last_line "$got")" '49'

# --- Cycle 4: PROVISIONAL discharge ---

# --- Case 13: clojure.set/join 3-arity is dispatchable (no arity error) ---
# The 3-arity body lands at row 7.8 cycle 4 per ADR-0041. Full
# correctness of the keymap-driven join requires map-as-map-key
# equality (a separate cw v1 limitation — see follow-up debt row);
# this case asserts only that the multi-arity dispatch reaches the
# 3-arity body and returns a set Value (= no arity_not_expected raise).
got=$("$BIN" - <<'EOF' 2>/dev/null
(require '[clojure.set :as cset])
(cset/join #{{:a 1 :b 2}} #{{:c 1 :d 99}} {:a :c})
EOF
) || fail "case13: non-zero exit ($got)"
last=$(last_line "$got")
if [[ "$last" != "#{}"* ]] && [[ "$last" != "#{{"* ]]; then
    fail "case13: expected a set Value (3-arity dispatched), got '$last'"
fi
echo "PASS clojure_set_join_three_arity_dispatched"

# --- Case 14: clojure.set/join 2-arity still works (back-compat) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(require '[clojure.set :as cset])
(cset/join #{{:a 1 :k :x}} #{{:a 1 :v :y}})
EOF
) || fail "case14: non-zero exit ($got)"
last=$(last_line "$got")
# Same map-as-key-equality limitation; verify the call dispatches +
# returns a set Value (multi-arity preserved the 2-arity surface).
if [[ "$last" != "#{}"* ]] && [[ "$last" != "#{{"* ]]; then
    fail "case14: expected a set Value (2-arity dispatched), got '$last'"
fi
echo "PASS clojure_set_join_two_arity_back_compat"
