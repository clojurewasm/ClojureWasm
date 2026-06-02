#!/usr/bin/env bash
# test/e2e/phase14_inst_literal.sh
#
# D-200 / clj-parity C6: `#inst "…"` reader literal → a no-slot cljw-native
# java.util.Date (typed_instance, ADR-0079). Round-trips through the
# canonical UTC ISO form; inst?/inst-ms/= by epoch-ms. `class`→"Date"
# (AD-003 simple name).
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# Reader literal round-trips to the canonical UTC ISO form.
assert_eq 'inst_date'   "$("$BIN" -e '#inst "2024-01-01"')"          '#inst "2024-01-01T00:00:00.000-00:00"'
assert_eq 'inst_full'   "$("$BIN" -e '#inst "2024-06-15T10:30:45.123Z"')" '#inst "2024-06-15T10:30:45.123-00:00"'
# +09:00 offset normalises to UTC.
assert_eq 'inst_tz'     "$("$BIN" -e '#inst "1970-01-01T09:00:00+09:00"')" '#inst "1970-01-01T00:00:00.000-00:00"'

# inst? / inst-ms.
assert_eq 'inst_q'      "$("$BIN" -e '(inst? #inst "2024-01-01")')"  'true'
assert_eq 'inst_q_str'  "$("$BIN" -e '(inst? "2024")')"              'false'
assert_eq 'inst_q_nil'  "$("$BIN" -e '(inst? nil)')"                 'false'
assert_eq 'inst_ms0'    "$("$BIN" -e '(inst-ms #inst "1970-01-01T00:00:00.000Z")')" '0'
assert_eq 'inst_ms1500' "$("$BIN" -e '(inst-ms #inst "1970-01-01T00:00:01.500Z")')" '1500'

# = by epoch-ms (different scale/tz spellings of the same instant).
assert_eq 'inst_eq'     "$("$BIN" -e '(= #inst "2024-01-01" #inst "2024-01-01T00:00:00Z")')" 'true'
assert_eq 'inst_ne'     "$("$BIN" -e '(= #inst "2024-01-01" #inst "2024-01-02")')" 'false'
assert_eq 'inst_ne_str' "$("$BIN" -e '(= #inst "2024-01-01" "2024-01-01")')"  'false'

# class prints the simple name (AD-003 no-JVM); read-string round-trips.
assert_eq 'inst_class'  "$("$BIN" -e '(str (class #inst "2024-01-01"))')" '"Date"'
assert_eq 'inst_rdstr'  "$("$BIN" -e '(inst? (read-string "#inst \"2024-01-01\""))')" 'true'

# Malformed instant raises.
if "$BIN" -e '#inst "not-a-date"' >/dev/null 2>&1; then
  fail 'inst_bad: malformed #inst should error'
fi
echo 'PASS inst_bad -> errors'

echo "ALL phase14_inst_literal PASS"
