#!/usr/bin/env bash
# test/e2e/phase14_deftype_method_lowering.sh
#
# deftype / reify / extend-type method-lowering clj-parity, two gaps found at
# the data.finger-tree ladder rung (its `defdigit` macro emits deftype methods
# via syntax-quote):
#  (1) a syntax-quote-qualified param symbol (`user/_` from a bare `_` inside a
#      backtick) — clj's deftype/reify strip the ns for method params; cljw now
#      strips too (a raw fn* still rejects a qualified param — parity preserved).
#  (2) an EMPTY method body `(m [_])` — clj returns nil; cljw required a body.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}
last_line() { awk 'END { print }' <<< "$1"; }

# (1) deftype method with a namespace-qualified receiver param (the syntax-quote shape)
assert_eq 'deftype_qualified_param' "$(last_line "$("$BIN" -e '(do (defprotocol P (mm [x])) (deftype Foo [a] P (mm [user/_] :ok)) (mm (->Foo 1)))')")" ':ok'
# (2) deftype method with an EMPTY body → nil
assert_eq 'deftype_empty_body' "$(last_line "$("$BIN" -e '(do (defprotocol P (mm [x])) (deftype Foo [a] P (mm [_])) (mm (->Foo 1)))')")" 'nil'
# (3) reify method with an empty body → nil
assert_eq 'reify_empty_body' "$(last_line "$("$BIN" -e '(do (defprotocol P (mm [x])) (mm (reify P (mm [_]))))')")" 'nil'
# (4) extend-type method with an empty body → nil
assert_eq 'extend_type_empty_body' "$(last_line "$("$BIN" -e '(do (defprotocol P (mm [x])) (extend-type String P (mm [_])) (mm "x"))')")" 'nil'
# (5) a qualified param that the body actually uses (via the implicit field) still resolves
assert_eq 'deftype_qualified_field_access' "$(last_line "$("$BIN" -e '(do (defprotocol P (val2 [x])) (deftype Box [v] P (val2 [user/_] (* 2 v))) (val2 (->Box 21)))')")" '42'
# (6) a raw fn* with a qualified param STILL errors (clj parity — only deftype/reify strip)
if "$BIN" -e '((fn* [user/x] user/x) 1)' >/dev/null 2>&1; then
    fail "raw_fn_qualified_param_still_errors: expected non-zero exit"
fi
echo "PASS raw_fn_qualified_param_still_errors"
