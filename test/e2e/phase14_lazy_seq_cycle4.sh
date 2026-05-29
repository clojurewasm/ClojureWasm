#!/usr/bin/env bash
# test/e2e/phase14_lazy_seq_cycle4.sh
#
# Phase 14 §9.16 row 14.13.5 — lazy-seq Layer-2 cycle 4 (ADR-0054 D6).
# The LAST lazy-cluster cycle: repeat / repeatedly / cycle / take-while /
# drop-while / partition become lazy `.clj`, mirroring the cycle-2/3
# lazy-cons shape. With this, row 14.13.5 flips [ ] -> [x].
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

# --- repeat (infinite 1-arg + finite 2-arg) ---
assert_eq 'repeat_inf'   "$("$BIN" -e '(into [] (take 4 (repeat 9)))')"           '[9 9 9 9]'
assert_eq 'repeat_n'     "$("$BIN" -e '(repeat 3 :x)')"                           '(:x :x :x)'
assert_eq 'repeat_zero'  "$("$BIN" -e '(into [] (repeat 0 :x))')"                 '[]'

# --- repeatedly (infinite 1-arg + finite 2-arg) ---
assert_eq 'repeatedly_inf' "$("$BIN" -e '(into [] (take 3 (repeatedly (fn* [] 7))))')" '[7 7 7]'
assert_eq 'repeatedly_n'   "$("$BIN" -e '(repeatedly 2 (fn* [] 1))')"             '(1 1)'

# --- cycle (infinite repetition; empty -> empty) ---
assert_eq 'cycle_take'   "$("$BIN" -e '(into [] (take 7 (cycle [1 2 3])))')"      '[1 2 3 1 2 3 1]'
assert_eq 'cycle_first'  "$("$BIN" -e '(first (cycle [5 6]))')"                   '5'
assert_eq 'cycle_empty'  "$("$BIN" -e '(into [] (cycle []))')"                    '[]'

# --- take-while ---
assert_eq 'takewhile'    "$("$BIN" -e '(take-while (fn* [x] (< x 3)) [1 2 3 4 1])')" '(1 2)'
assert_eq 'takewhile_v'  "$("$BIN" -e '(into [] (take-while odd? [1 3 5 2 7]))')" '[1 3 5]'
# laziness: take-while over an infinite range must not hang
assert_eq 'takewhile_inf' "$("$BIN" -e '(into [] (take 3 (take-while (fn* [x] (< x 100)) (range))))')" '[0 1 2]'

# --- drop-while ---
assert_eq 'dropwhile'    "$("$BIN" -e '(drop-while (fn* [x] (< x 3)) [1 2 3 4 1])')" '(3 4 1)'
assert_eq 'dropwhile_v'  "$("$BIN" -e '(into [] (drop-while odd? [1 3 4 5]))')"   '[4 5]'
# laziness: drop-while leading run over an infinite range, then take
assert_eq 'dropwhile_inf' "$("$BIN" -e '(first (drop-while (fn* [x] (< x 50)) (range)))')" '50'

# --- partition (2-arity + 3-arity step; incomplete tail dropped) ---
assert_eq 'partition_2'  "$("$BIN" -e '(partition 2 [1 2 3 4 5])')"               '((1 2) (3 4))'
assert_eq 'partition_v'  "$("$BIN" -e '(into [] (partition 2 [1 2 3 4]))')"       '[(1 2) (3 4)]'
assert_eq 'partition_step' "$("$BIN" -e '(partition 2 1 [1 2 3 4])')"             '((1 2) (2 3) (3 4))'
# laziness: partition over an infinite range, then take
assert_eq 'partition_inf' "$("$BIN" -e '(into [] (take 2 (partition 2 (range))))')" '[(0 1) (2 3)]'

echo "ALL phase14_lazy_seq_cycle4 PASS"
