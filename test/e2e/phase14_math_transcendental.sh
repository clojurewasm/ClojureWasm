#!/usr/bin/env bash
# test/e2e/phase14_math_transcendental.sh — java.lang.Math transcendentals
# (log/log10/exp/cbrt/sin/cos/tan/asin/acos/atan/atan2/sinh/cosh/tanh/
# signum/toRadians/toDegrees/hypot). std.math + builtins; always Double (F-005).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_eq 'log_1'    "$("$BIN" -e '(Math/log 1.0)')"      '0.0'
assert_eq 'exp_0'    "$("$BIN" -e '(Math/exp 0.0)')"      '1.0'
assert_eq 'log10_1k' "$("$BIN" -e '(Math/log10 1000.0)')" '3.0'
assert_eq 'cbrt_27'  "$("$BIN" -e '(Math/cbrt 27.0)')"    '3.0'
assert_eq 'sin_0'    "$("$BIN" -e '(Math/sin 0.0)')"      '0.0'
assert_eq 'cos_0'    "$("$BIN" -e '(Math/cos 0.0)')"      '1.0'
assert_eq 'tan_0'    "$("$BIN" -e '(Math/tan 0.0)')"      '0.0'
assert_eq 'atan_0'   "$("$BIN" -e '(Math/atan 0.0)')"     '0.0'
assert_eq 'atan2'    "$("$BIN" -e '(Math/atan2 0.0 1.0)')" '0.0'
assert_eq 'hypot'    "$("$BIN" -e '(Math/hypot 3.0 4.0)')" '5.0'
assert_eq 'signum_n' "$("$BIN" -e '(Math/signum -3.5)')"  '-1.0'
assert_eq 'signum_z' "$("$BIN" -e '(Math/signum 0.0)')"   '0.0'
assert_eq 'toRad'    "$("$BIN" -e '(Math/toRadians 180.0)')" '3.141592653589793'
assert_eq 'toDeg'    "$("$BIN" -e '(Math/toDegrees 3.141592653589793)')" '180.0'
# composition: sin²+cos² ≈ 1
assert_eq 'pythag'   "$("$BIN" -e '(let [x 0.7] (< (Math/abs (- 1.0 (+ (Math/pow (Math/sin x) 2) (Math/pow (Math/cos x) 2)))) 1e-9))')" 'true'
echo "OK — phase14_math_transcendental smoke (15 cases) green"
