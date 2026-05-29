#!/usr/bin/env bash
# test/e2e/phase14_lazy_seq_cycle3.sh
#
# Phase 14 §9.16 row 14.13.5 — lazy-seq Layer-2 cycle 3 (ADR-0054 D2/D4).
# concat / mapcat / drop become lazy `.clj` (the -drop-eager leaf is
# deleted); the 0-arg `(range)` is infinite lazy; and `=` force-walks a
# `.lazy_seq` operand (equal.zig sequential arm + rt/env threading).
#
# Proof targets (ADR-0054 D6 cycle 3):
#   (first (drop 100 (range)))            -> 100   (lazy drop + infinite range)
#   (= (map inc [1 2 3]) (list 2 3 4))    -> true  (lazy `=`)
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# --- infinite 0-arg range (lazy) ---
assert_eq 'range0_first'   "$("$BIN" -e '(first (range))')"                        '0'
assert_eq 'range0_take'    "$("$BIN" -e '(into [] (take 5 (range)))')"            '[0 1 2 3 4]'

# --- lazy drop (prints as a realized seq, not a vector) ---
assert_eq 'drop_print'     "$("$BIN" -e '(drop 2 [1 2 3 4 5])')"                  '(3 4 5)'
assert_eq 'drop_into'      "$("$BIN" -e '(into [] (drop 2 [1 2 3 4 5]))')"        '[3 4 5]'
assert_eq 'drop_zero'      "$("$BIN" -e '(first (drop 0 [7 8]))')"                '7'
assert_eq 'drop_overrun'   "$("$BIN" -e '(into [] (drop 9 [1 2 3]))')"            '[]'
# laziness: drop over an infinite range must not hang
assert_eq 'drop_inf_first' "$("$BIN" -e '(first (drop 100 (range)))')"           '100'

# --- lazy concat (prints as a realized seq, not a vector) ---
assert_eq 'concat_print'   "$("$BIN" -e '(concat [1 2] [3 4])')"                  '(1 2 3 4)'
assert_eq 'concat_first'   "$("$BIN" -e '(first (concat [] [9]))')"               '9'
# laziness: concat with an infinite tail must not hang
assert_eq 'concat_inf'     "$("$BIN" -e '(into [] (take 5 (concat [1 2] (range))))')" '[1 2 0 1 2]'

# --- lazy mapcat (prints as a realized seq, not a vector) ---
assert_eq 'mapcat_print'   "$("$BIN" -e '(mapcat (fn* [x] [x x]) [1 2 3])')"      '(1 1 2 2 3 3)'
# laziness: mapcat over an infinite range must not hang
assert_eq 'mapcat_inf'     "$("$BIN" -e '(into [] (take 4 (mapcat (fn* [x] [x x]) (range))))')" '[0 0 1 1]'

# --- lazy `=` (equal.zig force-walks a .lazy_seq operand) ---
assert_eq 'eq_lazy_list'   "$("$BIN" -e '(= (map inc [1 2 3]) (list 2 3 4))')"    'true'
assert_eq 'eq_list_lazy'   "$("$BIN" -e '(= (list 2 3 4) (map inc [1 2 3]))')"    'true'
assert_eq 'eq_lazy_vec'    "$("$BIN" -e '(= (map inc [1 2]) [2 3])')"             'true'
assert_eq 'eq_lazy_lazy'   "$("$BIN" -e '(= (map inc [1 2]) (map inc [1 2]))')"   'true'
assert_eq 'eq_lazy_short'  "$("$BIN" -e '(= (map inc [1 2 3]) (list 2 3))')"      'false'
assert_eq 'eq_lazy_long'   "$("$BIN" -e '(= (map inc [1 2]) (list 2 3 4))')"      'false'
assert_eq 'eq_filter_list' "$("$BIN" -e '(= (filter odd? [1 2 3 4 5]) (list 1 3 5))')" 'true'
assert_eq 'eq_drop_list'   "$("$BIN" -e '(= (drop 2 [1 2 3 4]) (list 3 4))')"     'true'
assert_eq 'eq_concat_list' "$("$BIN" -e '(= (concat [1] [2 3]) (list 1 2 3))')"   'true'
# a lazy operand vs a non-sequential must short-circuit to false, no force
assert_eq 'eq_lazy_num'    "$("$BIN" -e '(= (map inc [1 2]) 5)')"                 'false'

echo "ALL phase14_lazy_seq_cycle3 PASS"
