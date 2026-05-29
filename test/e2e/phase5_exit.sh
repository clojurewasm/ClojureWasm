#!/usr/bin/env bash
# test/e2e/phase5_exit.sh
#
# ROADMAP §9.7 / 5.16 — Phase 5 exit smoke. Runs a small set of
# Phase-5-feature cases against the cljw CLI and asserts that the
# evaluator prints the expected Clojure surface text.
#
# Scope adjustments (per Phase 5 actual landings):
# - `(get {:a 1} :a)` and `(reduce + (range 1e6))` from the
#   ROADMAP §9.7 5.16 text depend on clojure.core collection ops
#   that Phase 6+ will ship; they are not part of Phase 5 surface.
# - The `9223372036854775807` Long/MAX_VALUE form requires Phase 7
#   Java interop (`Long/MAX_VALUE` static-field access); the
#   equivalent reachable in Phase 5 is the `9223372036854775807N`
#   BigInt-literal form (per 5.10.d).
# - VM backend currently raises NotImplemented for deftype / ctor /
#   field-access nodes (per ADR-0030's Phase 5 narrowing); the
#   Evaluator.compare line in ROADMAP §9.7 5.16 is satisfied only
#   for the non-deftype cases.

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

# 1. Ratio from integer division.
got="$("$BIN" -e '(/ 1 3)')"
assert_eq 'ratio_from_int_div' "$got" '1/3'

# 2. BigInt auto-promotion via the multiply path on Long/MAX_VALUE.
got="$("$BIN" -e '(* 9223372036854775807N 2)')"
assert_eq 'bigint_mul_promote' "$got" '18446744073709551614N'

# 3. BigDecimal addition with scale alignment. Phase 14 row 14.4
# gap (c) discharged: printBigDecimal now places the decimal point
# per JVM toPlainString. (1.50M scale 2 unscaled 150) + (0.5M scale
# 1 unscaled 5) → align to scale 2: unscaled 150 + 50 = 200, scale 2
# → "2.00M". Pre-fix the printer dropped the dot and rendered "200M".
got="$("$BIN" -e '(+ 1.50M 0.5M)')"
assert_eq 'bigdecimal_add' "$got" '2.00M'

# 4. deftype + ctor + field access (the ROADMAP test target).
got="$("$BIN" - <<'EOF'
(deftype Point [x y])
(.x (Point. 1 2))
EOF
)"
assert_eq 'deftype_ctor_field' "$got" $'nil\n1'

echo
echo "Phase 5 exit smoke: all cases passed."
