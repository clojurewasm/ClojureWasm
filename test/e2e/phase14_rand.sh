#!/usr/bin/env bash
# test/e2e/phase14_rand.sh — D-134 rand / rand-int / rand-nth. Non-
# deterministic (lazy-seeded process PRNG, runtime/random.zig), so the
# assertions are RANGE / membership properties, not exact values.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

assert_eq 'ri_range'  "$("$BIN" -e '(let [r (rand-int 10)] (and (>= r 0) (< r 10)))')" 'true'
assert_eq 'ri_zero'   "$("$BIN" -e '(rand-int 0)')"   '0'
assert_eq 'ri_one'    "$("$BIN" -e '(rand-int 1)')"   '0'
assert_eq 'r_unit'    "$("$BIN" -e '(let [r (rand)] (and (>= r 0.0) (< r 1.0)))')" 'true'
assert_eq 'r_scaled'  "$("$BIN" -e '(let [r (rand 100)] (and (>= r 0.0) (< r 100.0)))')" 'true'
assert_eq 'rn_member' "$("$BIN" -e '(contains? #{:a :b :c} (rand-nth [:a :b :c]))')" 'true'
assert_eq 'rn_range'  "$("$BIN" -e '(let [r (rand-nth (range 50))] (and (>= r 0) (< r 50)))')" 'true'
# many draws stay in range (catches an off-by-one bound bug)
assert_eq 'ri_many'   "$("$BIN" -e '(every? (fn* [_] (< (rand-int 3) 3)) (range 200))')" 'true'

echo "OK — phase14_rand smoke (8 cases) green"
