#!/usr/bin/env bash
# test/e2e/phase16_concurrency_stress.sh
#
# Phase B concurrency stress — REGRESSION GUARD for the memory-ordering / lost-
# update class of bug. Two real races this campaign found (the atom non-atomic
# swap!, the STM doGet stale read) were INVISIBLE in Debug and surfaced only
# under ReleaseSafe with REPEATED runs (one was a ~6% flake). A single gate run
# of a concurrent case can miss such a rare race, so each invariant here is run
# in a tight loop INSIDE one cljw process; `every?` returns false the moment any
# iteration deviates, so a rare race reliably fails the step.
#
# The gate builds cljw ReleaseSafe (CLJW_OPT), so this runs against the optimised
# binary where the ordering bugs actually appear.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

N="${CLJW_STRESS_N:-20}" # iterations per invariant; raise locally to hunt flakes

fail() { echo "FAIL $1" >&2; exit 1; }
last_line() { tail -n 1; }
assert_true() {
    local name="$1"; local got="$2"
    [[ "$got" == "true" ]] || fail "$name: expected every iteration to hold, got '$got'"
    echo "PASS $name (x$N) -> all held"
}

# atom swap! — 4×100 concurrent increments must ALWAYS total 400 (CAS-retry; a
# non-atomic read-modify-write loses updates).
got=$("$BIN" -e "(every? (fn [_] (let [a (atom 0)] (run! deref (mapv (fn [_] (future (dotimes [_ 100] (swap! a inc)))) (range 4))) (= 400 @a))) (range $N))" 2>/dev/null | last_line)
assert_true 'stress_atom_swap' "$got"

# atom compare-and-set! user retry-loop — must also always total 400.
got=$("$BIN" -e "(every? (fn [_] (let [a (atom 0)] (run! deref (mapv (fn [_] (future (dotimes [_ 100] (loop [] (let [o @a] (when-not (compare-and-set! a o (inc o)) (recur))))))) (range 4))) (= 400 @a))) (range $N))" 2>/dev/null | last_line)
assert_true 'stress_atom_cas' "$got"

# STM dosync — 4×100 (alter c inc) on one ref must ALWAYS total 400 (read-point
# conflict + retry; the doGet stale read would lose updates ~6% of runs).
got=$("$BIN" -e "(every? (fn [_] (let [c (ref 0)] (run! deref (mapv (fn [_] (future (dotimes [_ 100] (dosync (alter c inc))))) (range 4))) (= 400 @c))) (range $N))" 2>/dev/null | last_line)
assert_true 'stress_stm_alter' "$got"

# STM multi-ref bank transfer — the sum invariant must ALWAYS hold ([-100 200]).
got=$("$BIN" -e "(every? (fn [_] (let [a (ref 100) b (ref 0)] (run! deref (mapv (fn [_] (future (dotimes [_ 50] (dosync (alter a dec) (alter b inc))))) (range 4))) (= [-100 200] [@a @b]))) (range $N))" 2>/dev/null | last_line)
assert_true 'stress_stm_transfer' "$got"

# locking — a non-atomic read-then-write under (locking a ...) must ALWAYS total
# 400 (mutual exclusion serialises the critical section).
got=$("$BIN" -e "(every? (fn [_] (let [a (atom 0)] (run! deref (mapv (fn [_] (future (dotimes [_ 100] (locking a (reset! a (inc @a)))))) (range 4))) (= 400 @a))) (range $N))" 2>/dev/null | last_line)
assert_true 'stress_locking' "$got"

# agent — concurrent sends to one agent must ALWAYS drain to 400 (single-drainer
# handoff; a stranded action would lose increments).
got=$("$BIN" -e "(every? (fn [_] (let [a (agent 0)] (run! deref (mapv (fn [_] (future (dotimes [_ 100] (send a inc)))) (range 4))) (await a) (= 400 @a))) (range $N))" 2>/dev/null | last_line)
assert_true 'stress_agent_sends' "$got"

echo
echo "Phase B concurrency stress (x$N each): all invariants held."
