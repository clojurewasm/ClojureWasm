#!/usr/bin/env bash
# test/e2e/phase14_subvec.sh — subvec (vector slice [start,end); end defaults to
# count) + its bounds-check surface. Since D-583/O-059 this is an O(1) VIEW (the
# `.sub_vector` tag); the observable-surface pins live in test/clj/suites/subvec_view_test.clj.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_eq 'sv_mid'   "$("$BIN" -e '(subvec [1 2 3 4 5] 1 3)')" '[2 3]'
assert_eq 'sv_tail'  "$("$BIN" -e '(subvec [1 2 3 4 5] 2)')"   '[3 4 5]'
assert_eq 'sv_full'  "$("$BIN" -e '(subvec [1 2 3] 0 3)')"     '[1 2 3]'
assert_eq 'sv_empty' "$("$BIN" -e '(subvec [1 2 3] 3)')"       '[]'
assert_eq 'sv_count' "$("$BIN" -e '(count (subvec [10 20 30 40] 1))')" '3'
# clj bounds-checks (does NOT clamp like take/drop): start/end past count, end <
# start, or negative all throw IndexOutOfBounds.
"$BIN" -e '(subvec [1 2 3] 1 10)' >/dev/null 2>&1 && fail 'sv_end_oob: expected error' || true
echo 'PASS sv_end_oob -> errors'
"$BIN" -e '(subvec [1 2 3] 5)' >/dev/null 2>&1 && fail 'sv_start_oob: expected error' || true
echo 'PASS sv_start_oob -> errors'
"$BIN" -e '(subvec [1 2 3] 2 1)' >/dev/null 2>&1 && fail 'sv_end_lt_start: expected error' || true
echo 'PASS sv_end_lt_start -> errors'
"$BIN" -e '(subvec [1 2 3] -1)' >/dev/null 2>&1 && fail 'sv_neg: expected error' || true
echo 'PASS sv_neg -> errors'

# Non-integer indices are coerced via clj's Number.intValue (truncate; NaN → 0)
# BEFORE the bounds check, and MUST NOT reach __subvec's raw i64 cast (which
# would @panic — ADR-0019). Values match clj's :default subvec test.
assert_eq 'sv_float_trunc' "$("$BIN" -e '(subvec [0 1 2] 2.72 3.14)')" '[2]'
assert_eq 'sv_ratio_trunc' "$("$BIN" -e '(subvec [0 1 2] 1/2 4/3)')" '[0]'
assert_eq 'sv_nan_start'   "$("$BIN" -e '(subvec [0 1 2] ##NaN 3)')"  '[0 1 2]'
assert_eq 'sv_nan_both'    "$("$BIN" -e '(subvec [0 1 2] ##NaN ##NaN)')" '[]'
assert_eq 'sv_nan_end0'    "$("$BIN" -e '(subvec [0 1 2] 0 ##NaN)')"  '[]'
# A no-panic guard: a NaN end that collapses to start>end, and a non-number
# index, must raise a CATCHABLE error (exit non-zero, no "panic"/"unreachable").
assert_catchable() {
    # `|| true` so cljw's non-zero exit on the catchable error does not trip set -e.
    local n="$1"; local out
    out="$("$BIN" -e "$2" 2>&1 || true)"
    grep -qiE 'panic|reached unreachable' <<<"$out" && fail "$n: PANICKED -> $out"
    echo "PASS $n -> catchable (no panic)"
}
assert_catchable 'sv_nan_end_oob_no_panic' '(subvec [0 1 2] 1 ##NaN)'
assert_catchable 'sv_kw_index_no_panic'    '(subvec [0 1 2] :a 2)'
echo "OK — phase14_subvec smoke (16 cases) green"
