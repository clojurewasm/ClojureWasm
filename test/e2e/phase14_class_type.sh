#!/usr/bin/env bash
# test/e2e/phase14_class_type.sh
#
# ADR-0059 — (class x) / (type x) return an interned .type_descriptor.
# Validates: native class names print as simple names (Long / String /
# PersistentVector), (class nil) → nil, interning makes (= (class 5)
# (class 6)) true + class usable as a map key (group-by class), type
# honours :type metadata, and user records' class equals their name Var.

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

# --- Case 1: (class integer) prints the simple class name ---
assert_eq 'class_integer' "$("$BIN" -e '(class 5)' 2>/dev/null | tail -1)" 'Long'
assert_eq 'class_string'  "$("$BIN" -e '(class "x")' 2>/dev/null | tail -1)" 'String'
assert_eq 'class_vector'  "$("$BIN" -e '(class [])' 2>/dev/null | tail -1)" 'PersistentVector'
assert_eq 'class_keyword' "$("$BIN" -e '(class :a)' 2>/dev/null | tail -1)" 'Keyword'

# --- Case 2: (class nil) → nil (JVM semantics) ---
assert_eq 'class_nil' "$("$BIN" -e '(class nil)' 2>/dev/null | tail -1)" 'nil'

# --- Case 3: interning — same class is = and identity-equal ---
assert_eq 'class_eq_same_native' "$("$BIN" -e '(= (class 5) (class 6))' 2>/dev/null | tail -1)" 'true'
assert_eq 'class_neq_cross_native' "$("$BIN" -e '(= (class 5) (class "x"))' 2>/dev/null | tail -1)" 'false'

# --- Case 4: class is a valid map key (group-by class) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(get (group-by class [1 2 "a" "b"]) (class 1))
EOF
) || fail "case4: non-zero exit ($got)"
assert_eq 'class_as_map_key_groupby' "$(last_line "$got")" '[1 2]'

# --- Case 5: (type x) = (or (:type (meta x)) (class x)) ---
assert_eq 'type_falls_to_class' "$("$BIN" -e '(type 5)' 2>/dev/null | tail -1)" 'Long'
got=$("$BIN" - <<'EOF' 2>/dev/null
(type (with-meta [1 2] {:type :foo}))
EOF
) || fail "case5: non-zero exit ($got)"
assert_eq 'type_honours_meta' "$(last_line "$got")" ':foo'

# --- Case 6: user record class prints its name + equals its Var ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Point [x y])
(class (->Point 1 2))
EOF
) || fail "case6a: non-zero exit ($got)"
assert_eq 'class_user_record_name' "$(last_line "$got")" 'Point'

got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Point [x y])
(= (class (->Point 1 2)) Point)
EOF
) || fail "case6b: non-zero exit ($got)"
assert_eq 'class_user_record_eq_var' "$(last_line "$got")" 'true'

# --- Numeric-tower class simple names (clj sweep) ---
assert_eq 'class_bigint'  "$("$BIN" -e '(class (bigint 5))' 2>/dev/null | tail -1)" 'BigInt'
assert_eq 'class_ratio'   "$("$BIN" -e '(class 1/2)' 2>/dev/null | tail -1)" 'Ratio'
assert_eq 'class_bigdec'  "$("$BIN" -e '(class 1.5M)' 2>/dev/null | tail -1)" 'BigDecimal'
# --- (bigint x) constructor: BigInt passthrough, else truncate toward zero ---
assert_eq 'bigint_int'    "$("$BIN" -e '(bigint 100)' 2>/dev/null | tail -1)" '100N'
assert_eq 'bigint_trunc'  "$("$BIN" -e '(bigint 3.9)' 2>/dev/null | tail -1)" '3N'
assert_eq 'bigint_negtrunc' "$("$BIN" -e '(bigint -3.9)' 2>/dev/null | tail -1)" '-3N'
assert_eq 'bigint_ratio'  "$("$BIN" -e '(bigint 1/2)' 2>/dev/null | tail -1)" '0N'
# --- (bigdec x): int/BigInt→scale0, BigDecimal passthrough, float via toString ---
assert_eq 'bigdec_int'    "$("$BIN" -e '(bigdec 100)' 2>/dev/null | tail -1)" '100M'
assert_eq 'bigdec_float'  "$("$BIN" -e '(bigdec 1.5)' 2>/dev/null | tail -1)" '1.5M'
assert_eq 'bigdec_float2' "$("$BIN" -e '(bigdec 0.25)' 2>/dev/null | tail -1)" '0.25M'
assert_eq 'bigdec_whole'  "$("$BIN" -e '(bigdec 100.0)' 2>/dev/null | tail -1)" '100.0M'
assert_eq 'bigdec_bigint' "$("$BIN" -e '(bigdec (bigint 5))' 2>/dev/null | tail -1)" '5M'
assert_eq 'bigdec_pass'   "$("$BIN" -e '(bigdec 1.5M)' 2>/dev/null | tail -1)" '1.5M'

echo "OK — phase14_class_type (23 cases) green"
