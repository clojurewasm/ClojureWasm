#!/usr/bin/env bash
# test/e2e/phase14_map_entry.sh
#
# D-209 / clj-parity C4: a distinct MapEntry value (activates the reserved
# F-004 Group-A `.map_entry` slot, ADR-0078). A MapEntry IS-A 2-vector in
# every observable way (vector?/=/nth/count/seq/print/destructure) yet
# `map-entry?`→true distinguishes it from a literal `[1 2]`; conj DROPS the
# nature (→ plain vector). `class` prints the simple name "MapEntry" (AD-003).
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# map-entry? distinguishes a MapEntry from a literal 2-vector.
assert_eq 'me_q'       "$("$BIN" -e '(map-entry? (first {:a 1}))')"  'true'
assert_eq 'me_q_vec'   "$("$BIN" -e '(map-entry? [1 2])')"           'false'

# IS-A vector in every observable way.
assert_eq 'me_vecq'    "$("$BIN" -e '(vector? (first {:a 1}))')"     'true'
assert_eq 'me_seqq'    "$("$BIN" -e '(sequential? (first {:a 1}))')" 'true'
assert_eq 'me_count'   "$("$BIN" -e '(count (first {:a 1}))')"       '2'
assert_eq 'me_nth0'    "$("$BIN" -e '(nth (first {:a 1}) 0)')"       ':a'
assert_eq 'me_nth1'    "$("$BIN" -e '(nth (first {:a 1}) 1)')"       '1'
assert_eq 'me_key'     "$("$BIN" -e '(key (first {:a 1}))')"         ':a'
assert_eq 'me_val'     "$("$BIN" -e '(val (first {:a 1}))')"         '1'
assert_eq 'me_get0'    "$("$BIN" -e '(get (first {:a 1}) 0)')"       ':a'
assert_eq 'me_pr'      "$("$BIN" -e '(pr-str (first {:a 1}))')"      '"[:a 1]"'
assert_eq 'me_destr'   "$("$BIN" -e '(let [[k v] (first {:a 1})] [k v])')" '[:a 1]'

# Equal to the literal 2-vector, both directions (a MapEntry IS-A vector).
assert_eq 'me_eq_fwd'  "$("$BIN" -e '(= (first {:a 1}) [:a 1])')"    'true'
assert_eq 'me_eq_rev'  "$("$BIN" -e '(= [:a 1] (first {:a 1}))')"    'true'

# conj DROPS the map-entry nature → a plain vector (JVM asVector()).
assert_eq 'me_conj'    "$("$BIN" -e '(conj (first {:a 1}) 99)')"     '[:a 1 99]'
assert_eq 'me_conj_q'  "$("$BIN" -e '(map-entry? (conj (first {:a 1}) 99))')" 'false'

# Entries round-trip back into a map; class prints the simple name.
assert_eq 'me_into'    "$("$BIN" -e '(into {} (seq {:a 1 :b 2}))')"  '{:a 1, :b 2}'
assert_eq 'me_class'   "$("$BIN" -e '(str (class (first {:a 1})))')" '"MapEntry"'

echo "ALL phase14_map_entry PASS"
