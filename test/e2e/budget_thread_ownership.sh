#!/usr/bin/env bash
# test/e2e/budget_thread_ownership.sh
#
# The eval budget bounds the EVALUATION — including every thread it spawned.
#
# D-571: `rt.eval_budget` was one non-atomic slot on the Runtime, shared by
# every thread. Two consequences, both reachable by one expression on a public
# endpoint that evaluates caller-supplied code:
#   (a) a `Thread.` started inside a `with-budget` extent outlived it UNMETERED
#       (the slot is restored by value on extent exit, so the worker's re-deref
#       found null), and the join-at-exit barrier kept the process alive with
#       it — a 60 s sleep in a spawned thread held the process for 60 s;
#   (b) concurrent ticks on the shared counter were a data race, and whether a
#       spawned compute loop was metered at all depended on whether the extent
#       happened to still be live.
#
# The fix: the budget is a refcounted per-evaluation object; a spawner passes
# it down (Thread. / future / per agent action), so the budget's deadline and
# step ceiling follow the work wherever it runs. A worker that outlives the
# extent keeps its reference and trips on the SAME budget.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

# Portable bounded run: GNU `timeout`, else macOS coreutils `gtimeout`, else
# unbounded (the CI macOS runner ships NEITHER — a bare `timeout` exits 127
# there and fails the step at 0s, which is exactly how this file broke CI on
# 2026-08-05; scripts/check_portable_timeout.sh now guards the class). Every
# case's expressions are deadline-bounded by the feature under test, so the
# unbounded fallback cannot hang past the budget it asserts.
run_bounded() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
    else "$@"; fi
}

# --- (a) a sleeping Thread dies at the deadline; the process is not held ---
# Before: the process hung for the worker's full 60 s sleep (the join-at-exit
# barrier waited on an unmetered non-daemon thread).
SECONDS=0
got=$(run_bounded 30 "$BIN" - <<'EOF' 2>/dev/null
(println (cljw.eval/with-budget {:deadline-ms 500}
  (fn [] (.start (Thread. (fn [] (Thread/sleep 60000)))) :spawned)))
EOF
) || fail "thread_sleep_dies_at_deadline: non-zero exit"
elapsed=$SECONDS
grep -qx ':spawned' <<< "$got" || fail "thread_sleep_dies_at_deadline: got '$got'"
# Order-of-magnitude bound (test_taxonomy.md): catches "waited out the 60 s
# sleep", not scheduling noise. Bash SECONDS — no external clock needed.
[ "$elapsed" -lt 15 ] || fail "thread_sleep_dies_at_deadline: process held ${elapsed}s (worker not bounded)"
echo "PASS thread_sleep_dies_at_deadline (${elapsed}s)"

# --- (b) a compute-loop Thread trips the SHARED step ceiling and dies ---
# The worker parks on a promise the top level delivers only AFTER the extent
# exits, so the trip is guaranteed to happen on a worker that OUTLIVED the
# extent (the D-571 regression shape) without racing a large ceiling against
# the extent's own lifetime. Keeping the ceiling small matters: time-to-burn-N
# -steps scales with backend × hardware speed (30M steps: ~4 s on a mac
# tree-walk, 58 s on the CI Linux runner — the 2026-08-05 nightly red), which
# turns any elapsed bound into the ratio-bound flake test_taxonomy.md forbids.
SECONDS=0
got=$(run_bounded 60 "$BIN" - <<'EOF' 2>&1
(def unleash (promise))
(println (cljw.eval/with-budget {:max-steps 300000}
  (fn [] (.start (Thread. (fn [] @unleash (loop [i 0] (recur (inc i)))))) :done)))
(deliver unleash :go)
EOF
) || fail "thread_loop_trips_shared_steps: non-zero exit"
elapsed=$SECONDS
grep -qx ':done' <<< "$got" || fail "thread_loop_trips_shared_steps: got '$got'"
grep -q 'step budget' <<< "$got" || fail "thread_loop_trips_shared_steps: worker did not trip the shared ceiling: '$got'"
[ "$elapsed" -lt 15 ] || fail "thread_loop_trips_shared_steps: process held ${elapsed}s"
echo "PASS thread_loop_trips_shared_steps (${elapsed}s)"

# --- (c) a future spawned in the extent dies at the deadline ---
# The process does not wait on future workers at exit, so assert in-process:
# 1.5 s after a 400 ms deadline the future must be realised (dead), not still
# sleeping out its 60 s. This is the long-lived-server case (the playground).
got=$(run_bounded 30 "$BIN" - <<'EOF' 2>/dev/null
(def f (atom nil))
(cljw.eval/with-budget {:deadline-ms 400}
  (fn [] (reset! f (future (Thread/sleep 60000))) :spawned))
(Thread/sleep 1500)
(prn [:realised (realized? @f)])
EOF
) || fail "future_dies_at_deadline: non-zero exit"
grep -qx '\[:realised true\]' <<< "$got" || fail "future_dies_at_deadline: got '$got' (worker still sleeping)"
echo "PASS future_dies_at_deadline"

# --- (d) an agent action sent in the extent dies at the deadline ---
# The action sleeps 60 s; 1.5 s after the 400 ms deadline the agent must be
# failed (the budget raise is the action's error), not still parked.
got=$(run_bounded 30 "$BIN" - <<'EOF' 2>/dev/null
(def a (agent 0))
(cljw.eval/with-budget {:deadline-ms 400}
  (fn [] (send-off a (fn [_] (Thread/sleep 60000) 1)) :sent))
(Thread/sleep 1500)
(prn [:failed (some? (agent-error a))])
EOF
) || fail "agent_action_dies_at_deadline: non-zero exit"
grep -qx '\[:failed true\]' <<< "$got" || fail "agent_action_dies_at_deadline: got '$got' (action still parked)"
echo "PASS agent_action_dies_at_deadline"

# --- (e) no budget => spawned threads stay unmetered (the default is unchanged) ---
got=$(run_bounded 30 "$BIN" - <<'EOF' 2>/dev/null
(def done (promise))
(.start (Thread. (fn [] (Thread/sleep 200) (deliver done :ok))))
(prn [:joined @done])
EOF
) || fail "no_budget_unmetered: non-zero exit"
grep -qx '\[:joined :ok\]' <<< "$got" || fail "no_budget_unmetered: got '$got'"
echo "PASS no_budget_unmetered"

# --- (f) after the extent exits cleanly, NEW spawns are not metered by it ---
# The budget follows work spawned INSIDE the extent; work spawned after must
# not inherit a stale reference.
got=$(run_bounded 30 "$BIN" - <<'EOF' 2>/dev/null
(cljw.eval/with-budget {:deadline-ms 300} (fn [] :done))
(Thread/sleep 400)
(def done (promise))
(.start (Thread. (fn [] (Thread/sleep 100) (deliver done :ok))))
(prn [:joined @done])
EOF
) || fail "no_stale_inheritance: non-zero exit"
grep -qx '\[:joined :ok\]' <<< "$got" || fail "no_stale_inheritance: got '$got'"
echo "PASS no_stale_inheritance"

echo "budget_thread_ownership: 6/6 cases pass"
