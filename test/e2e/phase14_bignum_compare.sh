#!/usr/bin/env bash
# test/e2e/phase14_bignum_compare.sh
#
# Phase 14 §9.16 / cluster A26 (clj differential sweep, F-011) — D-167:
# `<` / `>` / `<=` / `>=` (and `neg?` / `pos?`) were WRONG for BigInt /
# Ratio / BigDecimal operands because lang/primitive/math.zig::pairwise
# routed everything through toI64→f64, zeroing the big value. Fix: when no
# operand is a float, route through compare.valueCompare (exact ordering
# across the whole numeric tower); keep the f64 fast-path when a float is
# present (IEEE NaN semantics + float contagion, where a total Order would
# map NaN to .gt).

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

# --- BigInt: the D-167 reproduction (was all false) ---
check '(neg? -5N)'                'true'  bigint_neg_small
check '(neg? Long/MIN_VALUE)'     'true'  bigint_neg_long_min
check '(pos? Long/MAX_VALUE)'     'true'  bigint_pos_long_max
check '(< -5N 0)'                 'true'  bigint_lt_zero
check '(> Long/MAX_VALUE 0)'      'true'  bigint_gt_zero
check '(<= 5N 5N)'                'true'  bigint_le_equal
check '(< 1N 2N 3N)'              'true'  bigint_lt_chain

# --- Ratio ---
check '(< 1/3 1/2)'               'true'  ratio_lt
check '(< 1/2 1/3)'               'false' ratio_lt_false
check '(>= 2/3 1/3)'              'true'  ratio_ge

# --- BigDecimal ---
check '(< 1.5M 2.5M)'             'true'  decimal_lt
check '(> 2.5M 1.5M)'             'true'  decimal_gt

# --- Regression: pure int / float / NaN must be unchanged ---
check '(< 1 2 3)'                 'true'  int_lt_chain
check '(< 3 2)'                   'false' int_lt_false
check '(< 1.5 2.5)'               'true'  float_lt
check '(>= 1.5 1.5)'              'true'  float_ge_equal
# IEEE: every NaN comparison is false (a total Order would make > true)
check '(> ##NaN 1)'              'false' nan_gt_false
check '(< ##NaN 1)'              'false' nan_lt_false
check '(>= ##NaN 1)'             'false' nan_ge_false

# --- Cross-category (toF64 now converts big numbers, not zero) ---
check '(< 1/2 1)'                'true'  ratio_vs_int
check '(< 1/2 0.5)'              'false' ratio_vs_float  # was wrong (true) — toF64 fix
check '(< 1.5M 2)'               'true'  decimal_vs_int

# --- `==` (numeric equivalence) also routed exactly for big numbers ---
check '(== 1N 1)'                'true'  equiv_bigint_int
check '(== Long/MAX_VALUE 5)'    'false' equiv_bigint_neq  # was wrong (true)

echo "ALL PASS phase14_bignum_compare"
