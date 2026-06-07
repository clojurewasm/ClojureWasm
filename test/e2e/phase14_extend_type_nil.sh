#!/usr/bin/env bash
# test/e2e/phase14_extend_type_nil.sh
#
# (extend-type nil P …) / (extend-protocol P nil …) — extending a protocol to
# the nil type (clj nil-punning). A common idiom: a lib gives nil a default
# protocol impl so `(m nil)` returns a sentinel instead of throwing. cljw's
# dispatch already resolves a nil receiver to the per-Tag nil descriptor
# (dispatch.zig resolveDescriptor); the gap was __extend-type! rejecting a nil
# TARGET. Found at the data.finger-tree ladder rung (extend-type nil ObjMeter…).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}
last_line() { awk 'END { print }' <<< "$1"; }

# (1) single-protocol extend-type nil → (m nil) dispatches to the nil impl
assert_eq 'extend_nil_single' "$(last_line "$("$BIN" -e '(do (defprotocol P (m [x])) (extend-type nil P (m [_] :nil-case)) (m nil))')")" ':nil-case'
# (2) other types are unaffected (nil impl does not shadow String/Long)
assert_eq 'extend_nil_with_string' "$(last_line "$("$BIN" -e '(do (defprotocol P (m [x])) (extend-type nil P (m [_] :nc)) (extend-type String P (m [_] :str)) [(m nil) (m "x")])')")" '[:nc :str]'
# (3) multi-protocol extend-type nil (the data.finger-tree shape: two protocols)
assert_eq 'extend_nil_multi_proto' "$(last_line "$("$BIN" -e '(do (defprotocol Q (a [x]) (b [x])) (extend-type nil Q (a [_] :qa) (b [_] :qb)) [(a nil) (b nil)])')")" '[:qa :qb]'
# (4) extend-protocol form also accepts nil
assert_eq 'extend_protocol_nil' "$(last_line "$("$BIN" -e '(do (defprotocol P (m [x])) (extend-protocol P nil (m [_] :nc) Long (m [_] :lc)) [(m nil) (m 5)])')")" '[:nc :lc]'
# (5) calling a protocol method on nil with NO nil impl still errors (no silent default)
if "$BIN" -e '(do (defprotocol P (m [x])) (extend-type String P (m [_] :s)) (m nil))' >/dev/null 2>&1; then
    fail "no_nil_impl_still_errors: expected non-zero exit"
fi
echo "PASS no_nil_impl_still_errors"
