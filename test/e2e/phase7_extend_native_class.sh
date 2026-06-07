#!/usr/bin/env bash
# test/e2e/phase7_extend_native_class.sh
#
# D-203 / ADR-0072 — extend a protocol to a NATIVE / java class.
# `(extend-type Long P …)` / `(extend-type String P …)` /
# `(extend-protocol P Long … String …)` register the impl on the per-Tag
# native descriptor (`rt.nativeDescriptor(tag)`) — the SAME descriptor a
# primitive receiver dispatches through — so `(q 5)` finds it.
#
# Mechanism (ADR-0072): a bare native-class symbol resolves in
# `analyzeSymbol`'s `symbol_unresolved` fallback (AFTER Var resolution, so a
# user `(def String …)`/`(deftype String …)` shadows) to its native
# TypeDescriptor via `class_name.nativeTagFor`. This also makes a bare class
# symbol a value (= `(class 5)`), a coherence requirement clj shares
# (`(= Long (class 5))` → true).
#
# Verified via e2e top-level forms, NOT the clj_diff batch sweep (which wraps
# each line in (prn …) and so cannot host top-level defprotocol/extend-type).

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

# --- Case 1: extend-type over Long (native integer Tag) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol P (q [n]))
(extend-type Long P (q [n] (* n 2)))
(q 5)
EOF
) || fail "case1: non-zero exit ($got)"
assert_eq 'extend_type_long' "$(last_line "$got")" '10'

# --- Case 2: extend-type over String ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol Greet (g [s]))
(extend-type String Greet (g [s] (str "hi " s)))
(g "bob")
EOF
) || fail "case2: non-zero exit ($got)"
assert_eq 'extend_type_string' "$(last_line "$got")" '"hi bob"'

# --- Case 3: extend-protocol dispatches across two native classes ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol Desc (d [x]))
(extend-protocol Desc
  Long (d [_] :int)
  String (d [_] :str))
[(d 7) (d "x")]
EOF
) || fail "case3: non-zero exit ($got)"
assert_eq 'extend_protocol_two' "$(last_line "$got")" '[:int :str]'

# --- Case 4: bare class symbol is a value, equal to (class x) ---
got=$("$BIN" -e '(= Long (class 5))' 2>/dev/null) || fail "case4: non-zero exit ($got)"
assert_eq 'class_as_value_eq' "$(last_line "$got")" 'true'

# --- Case 5: FQCN form java.lang.Long resolves the same Tag ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol P (q [n]))
(extend-type java.lang.Long P (q [n] (+ n 100)))
(q 5)
EOF
) || fail "case5: non-zero exit ($got)"
assert_eq 'extend_type_fqcn' "$(last_line "$got")" '105'

# --- Case 6: a user (def String …) shadows the native class (Var wins) ---
# Resolution lands AFTER Var lookup, so a user binding takes precedence.
got=$("$BIN" - <<'EOF' 2>/dev/null
(def String 42)
String
EOF
) || fail "case6: non-zero exit ($got)"
assert_eq 'user_def_shadows_class' "$(last_line "$got")" '42'

# --- Case 7: ADR-0109 — the numeric-supertype marker Number now RESOLVES as a
# class value (was the pre-ADR-0109 "interface-shaped names don't resolve"
# divergence). isa?/instance? use its narrow numeric membership.
assert_eq 'number_resolves'  "$(last_line "$("$BIN" -e '(isa? Long Number)')")" 'true'
assert_eq 'number_instance'  "$(last_line "$("$BIN" -e '(instance? Number 5)')")" 'true'
# a genuinely-unknown class symbol still raises (no silent default-shift)
if "$BIN" -e 'TotallyMadeUpClass' >/dev/null 2>&1; then
    fail "case7: bare unknown class unexpectedly resolved (should raise)"
fi
echo "PASS unknown_class_still_unresolved -> (raised as expected)"

# --- Case 8: both backends agree (dual-backend parity) ---
got=$("$BIN" --compare - <<'EOF' 2>/dev/null
(defprotocol P (q [n]))
(extend-type Long P (q [n] (* n n)))
(q 9)
EOF
) || fail "case8: non-zero exit ($got)"
assert_eq 'backend_parity' "$(last_line "$got")" 'OK 81'

# --- Case 9 (D-204): numeric-tower classes resolve too — extend-type BigInt ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol P (q [n]))
(extend-type BigInt P (q [n] (* n 2)))
(q 5N)
EOF
) || fail "case9: non-zero exit ($got)"
assert_eq 'extend_type_bigint' "$(last_line "$got")" '10N'

# --- Case 10 (D-204): instance? over the numeric tower (was "not a known class") ---
assert_eq 'instance_bigint'  "$("$BIN" -e '(instance? clojure.lang.BigInt 1N)')" 'true'
assert_eq 'instance_ratio'   "$("$BIN" -e '(instance? clojure.lang.Ratio 1/2)')" 'true'
assert_eq 'instance_bigdec'  "$("$BIN" -e '(instance? java.math.BigDecimal 1M)')" 'true'

# --- Case 11 (D-204): `(class #"x")` is Pattern, not the raw tag name ---
assert_eq 'class_regex_pattern' "$("$BIN" -e '(class #"x")')" 'Pattern'

echo "OK — phase7_extend_native_class (11 cases) green"
