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
(prn (get (group-by class [1 2 "a" "b"]) (class 1)))
EOF
) || fail "case4: non-zero exit ($got)"
assert_eq 'class_as_map_key_groupby' "$(last_line "$got")" '[1 2]'

# --- Case 5: (type x) = (or (:type (meta x)) (class x)) ---
assert_eq 'type_falls_to_class' "$("$BIN" -e '(type 5)' 2>/dev/null | tail -1)" 'Long'
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (type (with-meta [1 2] {:type :foo})))
EOF
) || fail "case5: non-zero exit ($got)"
assert_eq 'type_honours_meta' "$(last_line "$got")" ':foo'

# --- Case 6: user record class prints its name + equals its Var ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Point [x y])
(prn (class (->Point 1 2)))
EOF
) || fail "case6a: non-zero exit ($got)"
assert_eq 'class_user_record_name' "$(last_line "$got")" 'Point'

got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Point [x y])
(prn (= (class (->Point 1 2)) Point))
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
# (bigint "..."): arbitrary-precision via setString (D-191 string arm).
assert_eq 'bigint_str'    "$("$BIN" -e '(bigint "100")' 2>/dev/null | tail -1)" '100N'
assert_eq 'bigint_str_neg' "$("$BIN" -e '(bigint "-5")' 2>/dev/null | tail -1)" '-5N'
# 2^65 (= 36893488147419103232) — the exact value D-047 documented as
# setString-broken on Linux; the D-047-safe parseBase10 makes it correct on
# every platform, so the test no longer has to stay < 2^64.
assert_eq 'bigint_str_big' "$("$BIN" -e '(bigint "36893488147419103232")' 2>/dev/null | tail -1)" '36893488147419103232N'
# --- (bigdec x): int/BigInt→scale0, BigDecimal passthrough, float via toString ---
assert_eq 'bigdec_int'    "$("$BIN" -e '(bigdec 100)' 2>/dev/null | tail -1)" '100M'
assert_eq 'bigdec_float'  "$("$BIN" -e '(bigdec 1.5)' 2>/dev/null | tail -1)" '1.5M'
assert_eq 'bigdec_float2' "$("$BIN" -e '(bigdec 0.25)' 2>/dev/null | tail -1)" '0.25M'
assert_eq 'bigdec_whole'  "$("$BIN" -e '(bigdec 100.0)' 2>/dev/null | tail -1)" '100.0M'
assert_eq 'bigdec_bigint' "$("$BIN" -e '(bigdec (bigint 5))' 2>/dev/null | tail -1)" '5M'
assert_eq 'bigdec_pass'   "$("$BIN" -e '(bigdec 1.5M)' 2>/dev/null | tail -1)" '1.5M'
# (bigdec "..."): scale taken from the decimal point (D-191 string arm).
assert_eq 'bigdec_str_frac' "$("$BIN" -e '(bigdec "1.50")' 2>/dev/null | tail -1)" '1.50M'
assert_eq 'bigdec_str_int'  "$("$BIN" -e '(bigdec "100")' 2>/dev/null | tail -1)" '100M'
assert_eq 'bigdec_str_neg'  "$("$BIN" -e '(bigdec "-3.14")' 2>/dev/null | tail -1)" '-3.14M'
# (bigdec n/d): exact decimal when d=2^a*5^b, else ArithmeticException (D-191 ratio arm).
assert_eq 'bigdec_ratio_q'  "$("$BIN" -e '(bigdec 1/4)' 2>/dev/null | tail -1)" '0.25M'
assert_eq 'bigdec_ratio_25' "$("$BIN" -e '(bigdec 7/20)' 2>/dev/null | tail -1)" '0.35M'
assert_eq 'bigdec_ratio_neg' "$("$BIN" -e '(bigdec -1/4)' 2>/dev/null | tail -1)" '-0.25M'
# Non-terminating ratio → arithmetic error (exit non-zero).
"$BIN" -e '(bigdec 1/3)' >/dev/null 2>&1 && fail 'bigdec_ratio_nonterm: expected error' || true
# Scientific notation (JVM BigDecimal.toString): scale<0 or adjExp<-6 → E± form.
assert_eq 'bigdec_sci_float' "$("$BIN" -e '(bigdec 1e30)' 2>/dev/null | tail -1)" '1.0E+30M'
assert_eq 'bigdec_sci_str'   "$("$BIN" -e '(bigdec "1.5E2")' 2>/dev/null | tail -1)" '1.5E+2M'
assert_eq 'bigdec_sci_small' "$("$BIN" -e '(bigdec 1e-10)' 2>/dev/null | tail -1)" '1.0E-10M'
assert_eq 'bigdec_plain_sm'  "$("$BIN" -e '(bigdec 1e-5)' 2>/dev/null | tail -1)" '0.000010M'
# (bigint large-float): bigdec(d).toBigInteger() truncation (D-191, D-047-safe).
assert_eq 'bigint_lgfloat'   "$("$BIN" -e '(bigint 1e30)' 2>/dev/null | tail -1)" '1000000000000000000000000000000N'
assert_eq 'bigint_lgfloat_n' "$("$BIN" -e '(bigint -1e20)' 2>/dev/null | tail -1)" '-100000000000000000000N'
# BigDecimal contagion: bigdec ⊗ {int,bigint,ratio} → bigdec; ⊗ float → float.
assert_eq 'bd_mul_int'   "$("$BIN" -e '(* 1.5M 2)' 2>/dev/null | tail -1)" '3.0M'
assert_eq 'bd_add_int'   "$("$BIN" -e '(+ 1 0.5M)' 2>/dev/null | tail -1)" '1.5M'
assert_eq 'bd_mul_float' "$("$BIN" -e '(* 1.5M 2.0)' 2>/dev/null | tail -1)" '3.0'
assert_eq 'bd_add_ratio' "$("$BIN" -e '(+ 1.5M 1/2)' 2>/dev/null | tail -1)" '2.0M'
assert_eq 'bd_sub_bigint' "$("$BIN" -e '(* 1.5M (bigint 3))' 2>/dev/null | tail -1)" '4.5M'
# Non-terminating ratio contagion → arithmetic error.
"$BIN" -e '(+ 1.5M 1/3)' >/dev/null 2>&1 && fail 'bd_nonterm: expected error' || true
# BigDecimal division (exact or ArithmeticException) + quot/rem (D-194 Unit B).
assert_eq 'bd_div_exact' "$("$BIN" -e '(/ 1.5M 2)' 2>/dev/null | tail -1)" '0.75M'
assert_eq 'bd_div_int'   "$("$BIN" -e '(/ 6M 2)' 2>/dev/null | tail -1)" '3M'
assert_eq 'bd_quot'      "$("$BIN" -e '(quot 7.5M 2)' 2>/dev/null | tail -1)" '3.0M'
assert_eq 'bd_rem'       "$("$BIN" -e '(rem 1.50M 0.7M)' 2>/dev/null | tail -1)" '0.10M'
assert_eq 'bd_mod'       "$("$BIN" -e '(mod 7.5M 2)' 2>/dev/null | tail -1)" '1.5M'
"$BIN" -e '(/ 1M 3)' >/dev/null 2>&1 && fail 'bd_div_nonterm: expected error' || true

# --- class? predicate (D-215): true only for a class object ---
assert_eq 'classp_cls'   "$("$BIN" -e '(class? (class 5))' 2>/dev/null | tail -1)" 'true'
assert_eq 'classp_sym'   "$("$BIN" -e '(class? String)' 2>/dev/null | tail -1)" 'true'
assert_eq 'classp_int'   "$("$BIN" -e '(class? 5)' 2>/dev/null | tail -1)" 'false'
assert_eq 'classp_nil'   "$("$BIN" -e '(class? nil)' 2>/dev/null | tail -1)" 'false'
assert_eq 'classp_str'   "$("$BIN" -e '(class? "x")' 2>/dev/null | tail -1)" 'false'

# --- D-337 / AD-044: (class x) of a callable / seq / ref returns a stable
# clj-faithful simple class name, never the internal heap-tag name (was
# `fn_val` / `lazy_seq` / `atom`). clj returns a generated/reify class for
# fns / future / promise that cljw cannot mirror (AD-044); cljw is stable.
assert_eq 'class_fn_anon'  "$("$BIN" -e '(class (fn [x] x))' 2>/dev/null | tail -1)" 'Fn'
assert_eq 'class_fn_builtin' "$("$BIN" -e '(class +)' 2>/dev/null | tail -1)" 'Fn'
assert_eq 'class_multifn'  "$("$BIN" - <<'EOF' 2>/dev/null | tail -1
(defmulti mm identity)
(prn (.getName (class mm)))
EOF
)" '"MultiFn"'
assert_eq 'class_lazyseq'  "$("$BIN" -e '(class (map inc [1]))' 2>/dev/null | tail -1)" 'LazySeq'
assert_eq 'class_range'    "$("$BIN" -e '(class (range 3))' 2>/dev/null | tail -1)" 'LongRange'
assert_eq 'class_chunkseq' "$("$BIN" -e '(class (rest (cons 1 (range 3))))' 2>/dev/null | tail -1)" 'ChunkedSeq'
assert_eq 'class_future'   "$("$BIN" -e '(class (future 1))' 2>/dev/null | tail -1)" 'Future'
assert_eq 'class_agent'    "$("$BIN" -e '(class (agent 0))' 2>/dev/null | tail -1)" 'Agent'
assert_eq 'class_atom'     "$("$BIN" -e '(class (atom 0))' 2>/dev/null | tail -1)" 'Atom'
assert_eq 'class_ref'      "$("$BIN" -e '(class (ref 0))' 2>/dev/null | tail -1)" 'Ref'
assert_eq 'class_volatile' "$("$BIN" -e '(class (volatile! 0))' 2>/dev/null | tail -1)" 'Volatile'
assert_eq 'class_delay'    "$("$BIN" -e '(class (delay 1))' 2>/dev/null | tail -1)" 'Delay'
assert_eq 'class_reduced'  "$("$BIN" -e '(class (reduced 1))' 2>/dev/null | tail -1)" 'Reduced'
assert_eq 'class_tvec'     "$("$BIN" -e '(class (transient []))' 2>/dev/null | tail -1)" 'TransientVector'
# class-level (isa? (class +) IFn) still holds after the rename (isCallableClassName).
assert_eq 'class_fn_isa_ifn' "$("$BIN" -e '(isa? (class +) clojure.lang.IFn)' 2>/dev/null | tail -1)" 'true'

echo "OK — phase14_class_type (70 cases) green"
