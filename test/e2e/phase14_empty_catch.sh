#!/usr/bin/env bash
# test/e2e/phase14_empty_catch.sh
#
# D-301 — clj parity for `try`/`catch`:
#  (1) an EMPTY catch body is valid: `(catch E e)` swallows the throwable and
#      returns nil (oracle-confirmed). cljw required ≥1 body form.
#  (2) java.lang.ClassNotFoundException (+ ReflectiveOperationException) are
#      recognised catch classes — libs probing for optional classes catch them
#      (e.g. clojure.math.numeric-tower).

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

# (1) empty catch body swallows + returns nil
assert_eq 'empty_catch_nil' "$(last_line "$("$BIN" -e '(try (throw (Exception. "x")) (catch Exception e))' 2>/dev/null)")" 'nil'
# normal (non-empty) catch still works
assert_eq 'catch_with_body' "$(last_line "$("$BIN" -e '(try (throw (Exception. "x")) (catch Exception e :caught))' 2>/dev/null)")" ':caught'
# no throw → try value (empty catch present)
assert_eq 'no_throw_empty_catch' "$(last_line "$("$BIN" -e '(try :ok (catch Exception e))' 2>/dev/null)")" ':ok'

# (2) ClassNotFoundException is a recognised catch class (no analyze error)
got=$("$BIN" -e '(try :ok (catch ClassNotFoundException e :caught))' 2>&1)
assert_eq 'classnotfound_recognised' "$(last_line "$got")" ':ok'
# it is an Exception subtype (catching Exception also catches it conceptually) —
# here just confirm the qualified form is unknown-or-known consistently: simple
# name resolves; a genuinely-unknown class still errors.
if "$BIN" -e '(try :ok (catch TotallyMadeUpException e))' >/dev/null 2>&1; then
    fail "unknown_catch_class_still_errors: expected non-zero exit"
fi
echo "PASS unknown_catch_class_still_errors"
