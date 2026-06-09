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

echo "OK — phase16_eval_budget (steps/deadline kill + uncatchable + unmetered) green"
