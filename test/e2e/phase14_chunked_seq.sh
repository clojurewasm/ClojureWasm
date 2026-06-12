#!/usr/bin/env bash
# test/e2e/phase14_chunked_seq.sh
#
# §9.2.S D-163 / ADR-0065 — chunk-preserving map/filter/keep + chunked
# reduce/count. map/filter/keep over a chunked source (range seq) emit a
# chunked_cons (JVM chunk-cons shape) so the per-element lazy-seq
# machinery is amortised 32x; reduce/count drain a whole chunk per step.
# These cases pin the chunk-boundary count (the off-by-one an unforced
# empty lazy tail caused) + correctness vs the clj oracle.
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# count over chunked map at + around the 32-element chunk boundary
# (regression guard for the unforced-empty-lazy-tail off-by-one).
assert_eq 'cnt_map_1'    "$("$BIN" -e '(count (map inc (range 1)))')"    '1'
assert_eq 'cnt_map_32'   "$("$BIN" -e '(count (map inc (range 32)))')"   '32'
assert_eq 'cnt_map_33'   "$("$BIN" -e '(count (map inc (range 33)))')"   '33'
assert_eq 'cnt_map_65'   "$("$BIN" -e '(count (map inc (range 65)))')"   '65'
assert_eq 'cnt_map_1000' "$("$BIN" -e '(count (map inc (range 1000)))')" '1000'

# count over chunked filter / keep / remove
assert_eq 'cnt_filt_1000' "$("$BIN" -e '(count (filter even? (range 1000)))')" '500'
assert_eq 'cnt_keep'      "$("$BIN" -e '(count (keep (fn* [x] (if (even? x) x nil)) (range 64)))')" '32'
assert_eq 'cnt_remove'    "$("$BIN" -e '(count (remove even? (range 64)))')" '32'

# reduce drains chunks (value correct = elements correct)
assert_eq 'red_map'    "$("$BIN" -e '(reduce + (map inc (range 100)))')"               '5050'
assert_eq 'red_nested' "$("$BIN" -e '(reduce + 0 (map inc (filter even? (range 100))))')" '2500'

# random access + tail over the chunked output
assert_eq 'nth_map'  "$("$BIN" -e '(nth (map inc (range 100)) 50)')"  '51'
assert_eq 'last_map' "$("$BIN" -e '(last (map inc (range 100)))')"    '100'

# seq equality: chunked map output equals the eager range
assert_eq 'eq_map_range' "$("$BIN" -e '(= (map inc (range 40)) (range 1 41))')" 'true'

# laziness preserved: chunked map/filter over an unbounded range must not hang
assert_eq 'lazy_map_take'  "$("$BIN" -e '(into [] (take 5 (map inc (range 1000000))))')" '[1 2 3 4 5]'
assert_eq 'lazy_filt_take' "$("$BIN" -e '(into [] (take 5 (filter odd? (range))))')"     '[1 3 5 7 9]'

# into a vector through a chunked chain crossing a boundary
assert_eq 'into_map_33' "$("$BIN" -e '(count (into [] (map inc (range 33))))')" '33'

echo "ALL phase14_chunked_seq PASS"
