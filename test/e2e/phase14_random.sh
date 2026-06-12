#!/usr/bin/env bash
# test/e2e/phase14_random.sh
#
# ADR-0106 / D-289 — java.util.Random as a stateful native instance
# (host_instance general container). A seeded `(java.util.Random. n)` reproduces
# the JVM 48-bit-LCG sequence (F-011) so clojure.data.generators / test.check are
# deterministic. Oracle-confirmed values (seed 42, fresh generator per method).

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

# --- JVM-LCG parity (each from a FRESH seed-42 generator) ---
assert_eq 'nextInt'      "$(run '(.nextInt (java.util.Random. 42))')"      '-1170105035'
assert_eq 'nextLong'     "$(run '(.nextLong (java.util.Random. 42))')"     '-5025562857975149833'
assert_eq 'nextDouble'   "$(run '(.nextDouble (java.util.Random. 42))')"   '0.7275636800328681'
assert_eq 'nextBoolean'  "$(run '(.nextBoolean (java.util.Random. 42))')"  'true'
assert_eq 'nextInt_100'  "$(run '(.nextInt (java.util.Random. 42) 100)')"  '30'
assert_eq 'seed0_int1000' "$(run '(.nextInt (java.util.Random. 0) 1000)')" '360'

# --- nextInt sequence (in-place seed mutation across calls) ---
assert_eq 'nextInt_seq' "$(run '(let [r (java.util.Random. 42)] [(.nextInt r) (.nextInt r) (.nextInt r)])')" '[-1170105035 234785527 -1360544799]'

# --- setSeed re-seeds (re-derives the seed-42 stream) ---
assert_eq 'setSeed' "$(run '(let [r (java.util.Random. 1)] (.nextInt r) (.setSeed r 42) (.nextInt r))')" '-1170105035'

# --- nextLong is a Long (boxed; F-005 — not a lossy float) ---
assert_eq 'nextLong_is_long' "$(run '(integer? (.nextLong (java.util.Random. 42)))')" 'true'

# --- class / instance? / print (AD-020) ---
assert_eq 'class'        "$(run '(class (java.util.Random. 0))')"                 'java.util.Random'
assert_eq 'instance_pos' "$(run '(instance? java.util.Random (java.util.Random. 0))')" 'true'
assert_eq 'instance_neg' "$(run '(instance? java.util.Random 5)')"               'false'
assert_eq 'print_opaque' "$(run '(pr-str (java.util.Random. 0))')"               '"#<java.util.Random>"'

# --- 0-arg ctor produces a working (non-reproducible) generator ---
assert_eq '0arg_in_range' "$(run '(let [n (.nextInt (java.util.Random.) 10)] (and (>= n 0) (< n 10)))')" 'true'
