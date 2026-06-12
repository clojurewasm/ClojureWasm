#!/usr/bin/env bash
# test/e2e/phase14_hex_bigint.sh
#
# D-297 — a hex integer literal whose magnitude exceeds i64 auto-promotes to
# BigInt, matching clj (which reads the literal's unsigned magnitude:
# 0xffffffffffffffff => 18446744073709551615N, NOT -1). Decimal already
# promoted; this routes hex overflow through the same base-N mul/add BigInt path.
# Needed by hashing / RNG / crypto libs (test.check splitmix uses 0xbf58…).

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
run() { "$BIN" -e "$1" 2>/dev/null; }

# fits i64 → Long (no promotion)
assert_eq 'hex_small'      "$(run '0xff')"                 '255'
assert_eq 'hex_i64_max'    "$(run '0x7fffffffffffffff')"   '9223372036854775807'
# exceeds i64 → BigInt magnitude (clj parity)
assert_eq 'hex_splitmix'   "$(run '0xbf58476d1ce4e5b9')"   '13787848793156543929N'
assert_eq 'hex_u64_max'    "$(run '0xffffffffffffffff')"   '18446744073709551615N'
assert_eq 'hex_neg_big'    "$(run '-0xbf58476d1ce4e5b9')"  '-13787848793156543929N'
# value is a real BigInt usable in arithmetic
assert_eq 'hex_big_arith'  "$(run '(+ 0xffffffffffffffff 1)')" '18446744073709551616N'
assert_eq 'hex_big_integer?' "$(run '(integer? 0xbf58476d1ce4e5b9)')" 'true'
