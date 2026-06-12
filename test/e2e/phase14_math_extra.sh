#!/usr/bin/env bash
# test/e2e/phase14_math_extra.sh
#
# Phase 14 §9.16 / cluster A26 (clj differential sweep, F-011) —
# java.lang.Math static FIELDS (PI / E, via ADR-0061 static-field
# resolution) + floorDiv / floorMod methods. Extends runtime/java/lang/
# Math.zig.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

check() { # check <expr> <expected> <label>
    local out
    set +e
    out=$("$BIN" -e "$1" 2>&1 | tail -n 1)
    set -e
    [[ "$out" == "$2" ]] || fail "$3: expected '$2', got '$out'"
    echo "PASS $3 -> $2"
}

# --- static fields (PI / E) — float, normal magnitude, exact print ---
check 'Math/PI'  '3.141592653589793'  math_pi
check 'Math/E'   '2.718281828459045'  math_e
check '(< 3 Math/PI 4)' 'true'  math_pi_in_expr

# --- floorDiv / floorMod (round toward -inf; result sign of divisor) ---
check '(Math/floorDiv 7 2)'   '3'   math_floorDiv_pos
check '(Math/floorDiv -7 2)'  '-4'  math_floorDiv_neg
check '(Math/floorMod -7 3)'  '2'   math_floorMod_neg
check '(Math/floorMod 7 3)'   '1'   math_floorMod_pos

echo "ALL PASS phase14_math_extra"
