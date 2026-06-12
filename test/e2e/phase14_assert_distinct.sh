#!/usr/bin/env bash
# test/e2e/phase14_assert_distinct.sh
#
# D-134 — assert (macro) + distinct? (fn). assert -> (if expr nil (throw
# (ex-info MSG {:form 'expr}))); distinct? -> true iff no two args equal
# (a set dedups by =, so distinct <=> the set keeps every element).
# distinct? is core.clj (rides the AOT blob); assert is a Zig macro.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# distinct?
assert_eq 'distinct_all'  "$("$BIN" -e '(distinct? 1 2 3)')"     'true'
assert_eq 'distinct_dup'  "$("$BIN" -e '(distinct? 1 2 2)')"     'false'
assert_eq 'distinct_kw'   "$("$BIN" -e '(distinct? :a :b :a)')"  'false'
assert_eq 'distinct_one'  "$("$BIN" -e '(distinct? 1)')"         'true'
# assert passes -> nil
assert_eq 'assert_pass'   "$("$BIN" -e '(assert (= 1 1))')"      'nil'
assert_eq 'assert_true'   "$("$BIN" -e '(assert true)')"         'nil'
# assert fails -> throws (default + custom message)
out="$("$BIN" -e '(assert false)' 2>&1 || true)"
[[ "$out" == *"Assert failed"* ]] || fail "assert_fail_default: got '$out'"
echo "PASS assert_fail_default -> Assert failed"
out="$("$BIN" -e '(assert (= 1 2) "one is not two")' 2>&1 || true)"
[[ "$out" == *"one is not two"* ]] || fail "assert_fail_msg: got '$out'"
echo "PASS assert_fail_msg -> one is not two"

# --- D-192: assert throws an AssertionError (under Error, NOT Exception) ---
assert_eq 'assert_catch_assertion_error' "$("$BIN" -e '(try (assert false "nope") (catch AssertionError e :ae))')" ':ae'
assert_eq 'assert_catch_error' "$("$BIN" -e '(try (assert false) (catch Error e :err))')" ':err'
assert_eq 'assert_catch_throwable' "$("$BIN" -e '(try (assert (= 1 2)) (catch Throwable t :thr))')" ':thr'
# AssertionError has no ex-data (unlike a real ex-info)
assert_eq 'assert_no_ex_data' "$("$BIN" -e '(ex-data (try (assert false) (catch Throwable t t)))')" 'nil'
# (catch Exception …) must NOT catch an assert failure (Error ∉ Exception);
# the error propagates → non-zero exit, "Assert failed" on stderr.
out="$("$BIN" -e '(try (assert false) (catch Exception e :wrong))' 2>&1 || true)"
[[ "$out" == *"Assert failed"* && "$out" != *":wrong"* ]] || fail "assert_not_exception: got '$out'"
echo "PASS assert_not_caught_by_exception"

echo "OK — phase14_assert_distinct smoke (13 cases) green"
