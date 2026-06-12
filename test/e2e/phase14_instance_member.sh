#!/usr/bin/env bash
# test/e2e/phase14_instance_member.sh
#
# Phase 14 §9.17 — ADR-0050 amendment 1: unified instance-member dispatch.
# `InteropCallNode.Kind` collapsed `.instance_field` + `.instance_method`
# into one `.instance_member`; member-vs-field is resolved at eval from the
# receiver's descriptor shape (field-first, keyed on field_layout presence).
#
# Validates:
#   - (.method "str") on a native receiver routes to the .string native
#     descriptor's method_table (Q2 fix: previously mis-routed to a field
#     read that hard-required a typed_instance)
#   - (.field rec) on a deftype still field-reads (field-first, no regression)
#   - (.-field rec) reads a field via the field-only path
#   - (.-method "str") field-only on a native type (no field) raises
#   - method/field not found raises

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    if [[ "$got" != "$want" ]]; then
        fail "$name: got '$got', want '$want'"
    fi
    echo "PASS $name -> $want"
}

last_line() { awk 'END { print }' <<< "$1"; }

# --- Case 1: native String instance method (the Q2 fix) ---
got="$("$BIN" -e '(.toUpperCase "hi")')" || fail "case1: non-zero exit"
assert_eq 'native_method_toUpperCase' "$got" '"HI"'

# --- Case 2: native String method, mixed-case lower ---
got="$("$BIN" -e '(.toLowerCase "HeLLo")')" || fail "case2: non-zero exit"
assert_eq 'native_method_toLowerCase' "$got" '"hello"'

# --- Case 3: native String trim ---
got="$("$BIN" -e '(.trim "  hi  ")')" || fail "case3: non-zero exit"
assert_eq 'native_method_trim' "$got" '"hi"'

# --- Case 3b: native String length / substring / indexOf (clj-verified) ---
assert_eq 'native_method_length'    "$("$BIN" -e '(.length "hello")')"       '5'
assert_eq 'native_method_substring' "$("$BIN" -e '(.substring "hello" 1 3)')" '"el"'
assert_eq 'native_method_substr2'   "$("$BIN" -e '(.substring "hello" 2)')"   '"llo"'
assert_eq 'native_method_indexOf'   "$("$BIN" -e '(.indexOf "hello" "ll")')"  '2'
assert_eq 'native_method_indexOf_miss' "$("$BIN" -e '(.indexOf "hi" "z")')"   '-1'

# --- Case 3c: charAt / contains / startsWith / endsWith / isEmpty / concat /
#     repeat — clj-verified scalar & predicate String methods ---
assert_eq 'native_method_charAt'      "$("$BIN" -e '(.charAt "abc" 1)')"        '\b'
assert_eq 'native_method_contains'    "$("$BIN" -e '(.contains "abcdef" "cd")')" 'true'
assert_eq 'native_method_contains_no' "$("$BIN" -e '(.contains "abc" "xy")')"    'false'
assert_eq 'native_method_startsWith'  "$("$BIN" -e '(.startsWith "abcdef" "abc")')" 'true'
assert_eq 'native_method_endsWith'    "$("$BIN" -e '(.endsWith "abcdef" "def")')"   'true'
assert_eq 'native_method_isEmpty'     "$("$BIN" -e '(.isEmpty "")')"            'true'
assert_eq 'native_method_isEmpty_no'  "$("$BIN" -e '(.isEmpty "x")')"           'false'
assert_eq 'native_method_concat'      "$("$BIN" -e '(.concat "abc" "def")')"    '"abcdef"'
assert_eq 'native_method_repeat'      "$("$BIN" -e '(.repeat "ab" 3)')"         '"ababab"'
assert_eq 'native_method_replace_ss'  "$("$BIN" -e '(.replace "abcabc" "bc" "XY")')" '"aXYaXY"'
# char/char overload. Use (char N) not \a literals — shell mangles the
# backslash in -e (same reason phase14_int_char.sh round-trips via (char N)).
# clj-verified: (.replace "abcabc" \a \X) => "XbcXbc".
assert_eq 'native_method_replace_cc'  "$("$BIN" -e '(.replace "abcabc" (char 97) (char 88))')" '"XbcXbc"'

# --- Case 4: deftype field read still works (field-first, no regression) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype Point [x y])
(prn (.x (Point. 7 9)))
EOF
) || fail "case4: non-zero exit ($got)"
assert_eq 'deftype_field_read' "$(last_line "$got")" '7'

# --- Case 5: (.-field rec) field-only read on deftype ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(deftype Pair [a b])
(prn (.-b (Pair. 1 33)))
EOF
) || fail "case5: non-zero exit ($got)"
assert_eq 'deftype_dash_field_read' "$(last_line "$got")" '33'

# --- Case 6: (.-method "str") field-only on native type raises ---
diag=$("$BIN" -e '(.-toUpperCase "hi")' 2>&1 || true)
if [[ "$diag" != *"toUpperCase"* ]]; then
    fail "case6: expected field-only-no-such-field diagnostic, got '$diag'"
fi
echo "PASS native_dash_field_only_raises"

# --- Case 7: unknown method on native receiver raises ---
diag=$("$BIN" -e '(.noSuchMethod "hi")' 2>&1 || true)
if [[ "$diag" != *"noSuchMethod"* ]] && [[ "$diag" != *"satisfies"* ]]; then
    fail "case7: expected method-not-found diagnostic, got '$diag'"
fi
echo "PASS native_unknown_method_raises"

echo "OK — phase14_instance_member smoke (7 cases) green"
