#!/usr/bin/env bash
# test/e2e/phase8_d089_assoc_extend.sh
#
# §9.10 row 8.6 cycle 3 — D-089 Associative + IPersistentMap slow-path.

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

# --- Case 1: native Tag (Long) -assoc via outer-else slow-path ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(def Long (rt/__native-type :integer))
(extend-type Long Associative (-assoc [n k v] :assoc-on-int))
(assoc 42 :a 1)
EOF
) || fail "case1: non-zero exit ($got)"
assert_eq 'long_assoc_via_extend_type' "$(last_line "$got")" ':assoc-on-int'

# --- Case 2: native Tag (Long) -without via outer-else slow-path ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(def Long (rt/__native-type :integer))
(extend-type Long IPersistentMap (-without [n k] :without-on-int))
(dissoc 42 :a)
EOF
) || fail "case2: non-zero exit ($got)"
assert_eq 'long_dissoc_via_extend_type' "$(last_line "$got")" ':without-on-int'

# --- Case 3: native Tag (Long) -keys via outer-else slow-path ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(def Long (rt/__native-type :integer))
(extend-type Long IPersistentMap (-keys [n] '(:a :b)))
(keys 42)
EOF
) || fail "case3: non-zero exit ($got)"
assert_eq 'long_keys_via_extend_type' "$(last_line "$got")" '(:a :b)'

# --- Case 4: native Tag (Long) -vals via outer-else slow-path ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(def Long (rt/__native-type :integer))
(extend-type Long IPersistentMap (-vals [n] '(1 2)))
(vals 42)
EOF
) || fail "case4: non-zero exit ($got)"
assert_eq 'long_vals_via_extend_type' "$(last_line "$got")" '(1 2)'

# --- Case 5: native Tag (Long) -contains-key? via outer-else slow-path ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(def Long (rt/__native-type :integer))
(extend-type Long Associative (-contains-key? [n k] true))
(contains? 42 :anything)
EOF
) || fail "case5: non-zero exit ($got)"
assert_eq 'long_contains_via_extend_type' "$(last_line "$got")" 'true'

# --- Case 6: builtin map assoc still works ---
got=$("$BIN" -e '(assoc {:a 1} :b 2)' 2>/dev/null) || fail "case6: non-zero exit ($got)"
assert_eq 'builtin_map_assoc_preserved' "$(last_line "$got")" '{:a 1, :b 2}'

# --- Case 7: builtin map dissoc still works ---
got=$("$BIN" -e '(dissoc {:a 1 :b 2} :a)' 2>/dev/null) || fail "case7: non-zero exit ($got)"
assert_eq 'builtin_map_dissoc_preserved' "$(last_line "$got")" '{:b 2}'

# --- Case 8: builtin set contains? still works ---
got=$("$BIN" -e '(contains? #{:a :b} :a)' 2>/dev/null) || fail "case8: non-zero exit ($got)"
assert_eq 'builtin_set_contains_preserved' "$(last_line "$got")" 'true'

echo "phase8_d089_assoc_extend: 8/8 cases pass"
