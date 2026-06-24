#!/usr/bin/env bash
# test/e2e/phase14_biginteger.sh
#
# D-265 + AD-016: clojure.core/biginteger. cljw has no separate
# java.math.BigInteger type — F-005 collapses clj's BigInt vs BigInteger into
# one `.big_int`, so `(biginteger x)` yields the same BigInt `(bigint x)` does.
# This locks the ACCEPTED divergence from JVM clj: cljw prints `5N` (clj `5`)
# and `(class (biginteger 5))` is `BigInt` (clj `java.math.BigInteger`). If a
# future change makes cljw match clj here (or diverge differently), this pin
# fails and forces a conscious decision.

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

# --- Divergence pins (cljw's intentional value, NOT clj's) ---
# clj `(biginteger 5)` prints `5`; cljw prints `5N` (it is a BigInt).
assert_eq 'biginteger_prints_N' "$("$BIN" -e '(biginteger 5)' 2>/dev/null | tail -1)" '5N'
# clj `(class (biginteger 5))` is java.math.BigInteger; cljw is BigInt.
assert_eq 'biginteger_class_bigint' "$("$BIN" -e '(class (biginteger 5))' 2>/dev/null | tail -1)" 'BigInt'
# A genuinely-large value (past i64) also collapses to a `…N` BigInt.
assert_eq 'biginteger_large_prints_N' \
    "$("$BIN" -e '(biginteger "999999999999999999999")' 2>/dev/null | tail -1)" '999999999999999999999N'
# Truncates toward zero like bigint (float / ratio), still printing `N`.
assert_eq 'biginteger_truncates_float' "$("$BIN" -e '(biginteger 3.9)' 2>/dev/null | tail -1)" '3N'

# --- BigInteger instance methods (D-514): abs/negate/signum/gcd/pow/mod/sqrt.
# clj-grounded; results stay BigInteger (cljw prints `…N`).
bm() { "$BIN" -e "$1" 2>&1 | tail -1; }
assert_eq 'bi_abs'    "$(bm '(.abs (biginteger -7))')"                  '7N'
assert_eq 'bi_negate' "$(bm '(.negate (biginteger 7))')"               '-7N'
assert_eq 'bi_signum' "$(bm '(.signum (biginteger -3))')"              '-1'
assert_eq 'bi_gcd'    "$(bm '(.gcd (biginteger 12) (biginteger 8))')"  '4N'
assert_eq 'bi_pow'    "$(bm '(.pow (biginteger 2) 10)')"               '1024N'
assert_eq 'bi_mod'    "$(bm '(.mod (biginteger 17) (biginteger 5))')"  '2N'
assert_eq 'bi_mod_neg' "$(bm '(.mod (biginteger -17) (biginteger 5))')" '3N'
assert_eq 'bi_sqrt'   "$(bm '(.sqrt (biginteger 17))')"                '4N'
# a negative sqrt raises (JVM ArithmeticException)
if "$BIN" -e '(.sqrt (biginteger -1))' >/dev/null 2>&1; then fail "bi_sqrt_neg: expected raise"; fi
echo "PASS bi_sqrt_neg -> raised"
# modPow (square-and-multiply) + bitLength
assert_eq 'bi_modpow'   "$(bm '(.modPow (biginteger 3) (biginteger 4) (biginteger 5))')"   '1N'
assert_eq 'bi_modpow2'  "$(bm '(.modPow (biginteger 2) (biginteger 10) (biginteger 1000))')" '24N'
assert_eq 'bi_modpow_neg' "$(bm '(.modPow (biginteger -3) (biginteger 3) (biginteger 7))')"  '1N'
assert_eq 'bi_modpow_big' "$(bm '(.modPow (biginteger 123456789) (biginteger 987654321) (biginteger 1000000007))')" '652541198N'
assert_eq 'bi_bitlen'   "$(bm '(.bitLength (biginteger 255))')"   '8'
assert_eq 'bi_bitlen2'  "$(bm '(.bitLength (biginteger 256))')"   '9'
assert_eq 'bi_bitlen0'  "$(bm '(.bitLength (biginteger 0))')"     '0'
assert_eq 'bi_bitlen_neg' "$(bm '(.bitLength (biginteger -256))')" '8'

echo "OK — phase14_biginteger (21 cases) green"
