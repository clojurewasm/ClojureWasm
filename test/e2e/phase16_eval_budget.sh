#!/usr/bin/env bash
# test/e2e/phase16_eval_budget.sh — in-process eval execution budget (ADR-0125,
# D-351). CLJW_EVAL_MAX_STEPS / CLJW_EVAL_DEADLINE_MS bound an untrusted eval by
# back-edge steps / wall-clock ms; expiry is an UNCATCHABLE resource_exhausted
# error so evaluated code cannot swallow its own timeout. Default-backend
# (tree_walk) end-to-end; the VM poll site is covered by the in-source
# dual-backend test under the gate's zig_build_test_vm step.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }

# 1. A step budget kills an infinite loop (exit 1 + the budget message).
out="$(CLJW_EVAL_MAX_STEPS=100000 "$BIN" -e '(loop [] (recur))' 2>&1)" && fail "step budget: expected non-zero exit, got 0:
$out"
echo "$out" | grep -qi "step budget" || fail "step budget message missing:
$out"
echo "PASS eval-budget-steps-kills-loop"

# 2. The budget is UNCATCHABLE — a catch-all must NOT swallow it (no :swallowed,
#    non-zero exit).
out="$(CLJW_EVAL_MAX_STEPS=100000 "$BIN" -e '(try (loop [] (recur)) (catch Throwable _ :swallowed))' 2>&1)" && fail "uncatchable: expected non-zero exit:
$out"
echo "$out" | grep -q ":swallowed" && fail "uncatchable: a (catch Throwable …) swallowed the budget error:
$out"
echo "PASS eval-budget-uncatchable"

# 3. A wall-clock deadline kills an infinite loop within a GENEROUS ceiling
#    (the deadline firing time is load-dependent; we only assert it DOES fire,
#    not when — DP3). 200ms budget; 20s outer timeout proves termination.
out="$(CLJW_EVAL_DEADLINE_MS=200 timeout 20 "$BIN" -e '(loop [] (recur))' 2>&1)" && fail "deadline: expected non-zero exit:
$out"
echo "$out" | grep -qi "time budget" || fail "deadline message missing:
$out"
echo "PASS eval-budget-deadline-kills-loop"

# 4. A normal bounded program is UNAFFECTED by a generous budget (exit 0).
got="$(CLJW_EVAL_MAX_STEPS=100000 CLJW_EVAL_DEADLINE_MS=10000 "$BIN" -e '(reduce + (range 1000))')" || fail "metered normal run errored:
$got"
[[ "$got" == "499500" ]] || fail "metered normal run wrong result: got '$got'"
echo "PASS eval-budget-normal-unaffected"

# 5. NO budget env = unmetered: a bounded loop completes (regression guard that
#    the poll is inert when unarmed).
got="$("$BIN" -e '(loop [i 0] (if (< i 1000) (recur (inc i)) i))')" || fail "unmetered loop errored:
$got"
[[ "$got" == "1000" ]] || fail "unmetered loop wrong result: got '$got'"
echo "PASS eval-budget-unmetered-default"

# 6. D-352: a live-heap ceiling refuses a runaway allocation (exit 1 + heap msg),
#    even though the realization happens inside a primitive (no back-edge poll).
out="$(CLJW_EVAL_MAX_HEAP_MB=16 timeout 20 "$BIN" -e '(vec (range 100000000))' 2>&1)" && fail "heap budget: expected non-zero exit:
$out"
echo "$out" | grep -qi "heap budget" || fail "heap budget message missing:
$out"
echo "PASS eval-budget-heap-refuses-runaway"

# 7. The heap cap is UNCATCHABLE too (a catch-all must NOT swallow it).
out="$(CLJW_EVAL_MAX_HEAP_MB=16 timeout 20 "$BIN" -e '(try (vec (range 100000000)) (catch Throwable _ :swallowed))' 2>&1)" && fail "heap uncatchable: expected non-zero exit:
$out"
echo "$out" | grep -q ":swallowed" && fail "heap uncatchable: a (catch …) swallowed the heap-budget error:
$out"
echo "PASS eval-budget-heap-uncatchable"

# 8. A small allocation is UNAFFECTED by a generous heap budget (exit 0).
got="$(CLJW_EVAL_MAX_HEAP_MB=256 "$BIN" -e '(count (vec (range 1000)))')" || fail "metered small alloc errored:
$got"
[[ "$got" == "1000" ]] || fail "metered small alloc wrong result: got '$got'"
echo "PASS eval-budget-heap-normal-unaffected"

# 9. cljw.eval/with-budget (D-355 Path A): an in-process scoped budget whose
#    breach is RECOVERED as a value (not an uncatchable kill), so a long-lived
#    server survives a runaway eval. Success returns the thunk value.
got="$("$BIN" -e '(cljw.eval/with-budget {:max-steps 1000000} (fn [] (+ 1 2)))')" || fail "with-budget success errored:
$got"
[[ "$got" == "3" ]] || fail "with-budget success wrong: got '$got'"
echo "PASS with-budget-success"

# A step / deadline / heap breach inside with-budget returns the exhausted marker
# AND the process exits 0 (survives) — the whole point vs the uncatchable kill.
for probe in \
  ':max-steps 100000} (fn [] (loop [] (recur)))' \
  ':max-heap-mb 16} (fn [] (vec (range 100000000)))'; do
  out="$(timeout 20 "$BIN" -e "(let [r (cljw.eval/with-budget {$probe)] (println :exhausted (:cljw.eval/exhausted r) :alive (+ 40 2)))" 2>&1)" \
    || fail "with-budget recovery: process did NOT survive (non-zero exit):
$out"
  echo "$out" | grep -q ":alive 42" || fail "with-budget recovery: server did not continue after breach:
$out"
done
echo "PASS with-budget-recovers-and-survives"

echo "OK — phase16_eval_budget (steps/deadline/heap kill + uncatchable + unmetered + with-budget recovery) green"
