#!/usr/bin/env bash
# test/e2e/phase8_d089_lookup_extend.sh
#
# §9.10 row 8.6 cycle 2 — D-089 ILookup + Indexed slow-path.

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

last_line() {
    awk 'END { print }' <<< "$1"
}

# --- Case 1: defrecord -lookup overrides get behaviour on extension ---
# Note: defrecord still has its fast-path field walk (recordGet), so
# this case uses a NON-DECLARED key (-lookup runs because :missing is
# not a declared field).
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Bag [items])
(extend-type Bag ILookup (-lookup [b k] :extended))
(get (->Bag [1 2]) :missing)
EOF
) || fail "case1: non-zero exit ($got)"
assert_eq 'defrecord_lookup_via_extend_type' "$(last_line "$got")" ':extended'

# --- Case 2: get without -lookup falls back to default ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Plain [a])
(get (->Plain 1) :missing :fallback)
EOF
) || fail "case2: non-zero exit ($got)"
assert_eq 'defrecord_get_no_extend_falls_back_to_default' "$(last_line "$got")" ':fallback'

# --- Case 3: defrecord -nth via Indexed extend-type ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Pair [x y])
(extend-type Pair Indexed (-nth [p i] (if (= i 0) (get p :x) (get p :y))))
(nth (->Pair 10 20) 1)
EOF
) || fail "case3: non-zero exit ($got)"
assert_eq 'defrecord_nth_via_extend_type' "$(last_line "$got")" '20'

# --- Case 4: native Tag (Long) -lookup via outer-else slow-path ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(def Long (rt/__native-type :integer))
(extend-type Long ILookup (-lookup [n _] (+ n 1000)))
(get 42 :anything)
EOF
) || fail "case4: non-zero exit ($got)"
assert_eq 'long_lookup_via_outer_else_slow_path' "$(last_line "$got")" '1042'

# --- Case 5: get on builtin vector still returns indexed value ---
got=$("$BIN" -e '(get [10 20 30] 1)' 2>/dev/null) || fail "case5: non-zero exit ($got)"
assert_eq 'get_on_vector_index_returns_value' "$(last_line "$got")" '20'

# --- Case 6: nth on builtin vector still works ---
got=$("$BIN" -e '(nth [10 20 30] 2)' 2>/dev/null) || fail "case6: non-zero exit ($got)"
assert_eq 'nth_on_vector_index_returns_value' "$(last_line "$got")" '30'

echo "phase8_d089_lookup_extend: 6/6 cases pass"
