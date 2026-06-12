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

echo "OK — phase14_biginteger (4 cases) green"
