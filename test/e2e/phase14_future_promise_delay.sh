#!/usr/bin/env bash
# test/e2e/phase14_future_promise_delay.sh
#
# Phase 14 §9.16 row 14.8 — Tier A concurrent primitives.
# - (delay expr...) — lazy memoised computation; thunk runs on first deref.
# - (future expr...) — **Phase B #4b: spawns a REAL OS thread**; (deref f)
#   BLOCKS on an Io.Mutex/Condition cell until the worker realises the Future.
#   `realized?` right after construction is async-racy (the worker may not have
#   finished), so this suite only asserts it AFTER a deref (deterministically true).
# - (promise) + (deliver p v) + (deref p) — write-once cell; (deref p) BLOCKS
#   until delivered (Phase B #4b / D-113), so a cross-thread deliver pattern
#   `(let [p (promise)] (future (deliver p v)) (deref p))` works. A
#   never-delivered deref blocks forever, exactly as JVM Clojure does.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

# The former ncpu<4 whole-suite gate (the D-548(a) roaming SIGABRT) is REMOVED
# per ADR-0176: the abort was the process-teardown vs detached-worker race
# (glibc heap corruption under rt.deinit), root-caused + fixed by the
# live-worker teardown guard. The suite runs everywhere again; the
# exit_teardown_* cases below are its standing regression canaries.

fail() { echo "FAIL $1" >&2; exit 1; }
last_line() { tail -n 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# --- Delay ---
got=$("$BIN" -e '(deref (delay (+ 1 2)))' 2>/dev/null | last_line)
assert_eq 'delay_deref_basic' "$got" '3'

got=$("$BIN" -e '(realized? (delay 99))' 2>/dev/null | last_line)
assert_eq 'delay_unrealised' "$got" 'false'

# Memoisation: a counter-style delay should produce the same value twice.
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def d (delay (+ 1 2)))
(prn [(deref d) (deref d) (realized? d)])
EOF
)
assert_eq 'delay_memoised_cached' "$got" '[3 3 true]'

# Thread-safe once-semantics (Phase B #4b): a concurrent deref from a future
# thread + the main thread runs the side-effecting thunk EXACTLY once (the
# realise lock serialises; the loser reads the cache).
got=$("$BIN" -e '(let [n (atom 0) d (delay (swap! n inc))] (future (deref d)) (deref d) @n)' 2>/dev/null | last_line)
assert_eq 'delay_once_under_concurrency' "$got" '1'

# --- Future (real OS thread, Phase B #4b) ---
got=$("$BIN" -e '(deref (future (* 7 6)))' 2>/dev/null | last_line)
assert_eq 'future_deref_blocks_for_result' "$got" '42'

# realized? is deterministically true AFTER a deref (the worker has finished).
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def f (future (+ 100 200)))
(deref f)
(prn [(realized? f) (deref f)])
EOF
)
assert_eq 'future_realized_after_deref' "$got" '[true 300]'

# Shared mutable identity across the worker thread: the future mutates the SAME
# atom the main thread reads (not a copy) — the load-bearing concurrency contract.
got=$("$BIN" -e '(let [a (atom 0)] @(future (swap! a inc)) @a)' 2>/dev/null | last_line)
assert_eq 'future_shared_atom_identity' "$got" '1'

# The worker allocates on the shared GC heap (a vector + range) and returns it.
got=$("$BIN" -e '(deref (future (vec (range 5))))' 2>/dev/null | last_line)
assert_eq 'future_worker_allocates' "$got" '[0 1 2 3 4]'

# --- Binding conveyance (clj parity, CLJW-FUTURE-BINDINGS) ---
# A future re-establishes the CREATING thread's dynamic bindings in the worker
# (clj's binding-conveyor-fn). Without it a `(binding […] (future …))` sees the
# var's root, silently dropping the caller's dynamic environment.
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def ^:dynamic *cv* :unset)
(prn (binding [*cv* :caller] @(future *cv*)))
EOF
)
assert_eq 'future_conveys_bindings' "$got" ':caller'

# A future created OUTSIDE any binding sees the var's ROOT — conveyance captures
# the frame at creation time, it does not invent one.
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def ^:dynamic *cv* :unset)
(prn @(future *cv*))
EOF
)
assert_eq 'future_no_conveyance_sees_root' "$got" ':unset'

# pmap runs each (f x) on its own future, so conveyance flows through it too.
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def ^:dynamic *cv* :unset)
(prn (binding [*cv* :caller] (doall (pmap (fn [_] *cv*) [1 2 3]))))
EOF
)
assert_eq 'pmap_conveys_bindings' "$got" '(:caller :caller :caller)'

# --- Promise ---
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def p (promise))
(deliver p 42)
(prn (deref p))
EOF
)
assert_eq 'promise_deliver_then_deref' "$got" '42'

got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def p (promise))
(prn [(realized? p) (do (deliver p :v) (realized? p))])
EOF
)
assert_eq 'promise_realized_transition' "$got" '[false true]'

# Retry-deliver returns nil per JVM semantics; original value preserved.
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def p (promise))
(deliver p :first)
(prn (let [retry (deliver p :second)]
  [retry (deref p)]))
EOF
)
assert_eq 'promise_retry_deliver_nil_preserves' "$got" '[nil :first]'

# --- Promise: deref BLOCKS until delivered from another thread (Phase B #4b) ---
got=$("$BIN" -e '(let [p (promise)] (future (deliver p 42)) (deref p))' 2>/dev/null | last_line)
assert_eq 'promise_blocks_until_delivered' "$got" '42'

# Predicates (Phase B): future? / future-done? (the latter after a deref so it is
# deterministically realised).
got=$("$BIN" -e '[(future? (future 1)) (future? 5)]' 2>/dev/null | last_line)
assert_eq 'future_predicate' "$got" '[true false]'
got=$("$BIN" -e '(let [f (future 1)] @f (future-done? f))' 2>/dev/null | last_line)
assert_eq 'future_done_after_deref' "$got" 'true'

# --- future-cancel / future-cancelled? (D-442 / ADR-0153, state-machine half) ---
# A future blocked on an undelivered promise is reliably PENDING → future-cancel
# wins (returns true), future-cancelled? true. Deliver afterwards so the worker
# unblocks + exits cleanly (its result discarded by the .pending-guarded store).
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def p (promise))
(def f (future (deref p)))
(let [c (future-cancel f) q (future-cancelled? f)] (deliver p 1) (prn [c q]))
EOF
)
assert_eq 'future_cancel_pending' "$got" '[true true]'

# deref of a cancelled future throws a (catchable) cancellation error.
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def p (promise))
(def f (future (deref p)))
(future-cancel f)
(deliver p 1)
(prn (try (deref f) :no-throw (catch Throwable e :threw)))
EOF
)
assert_eq 'future_cancel_deref_throws' "$got" ':threw'

# D-442 sub-step 2: the precise class is java.util.concurrent.CancellationException
# (a RuntimeException via IllegalStateException), NOT IllegalArgumentException.
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def p (promise))
(def f (future (deref p)))
(future-cancel f)
(deliver p 1)
(prn (try (deref f) :no-throw (catch java.util.concurrent.CancellationException e :cancel)))
EOF
)
assert_eq 'future_cancel_deref_cancellation_class' "$got" ':cancel'

# A CancellationException is NOT an IllegalArgumentException (sibling under
# RuntimeException) — so an IAE catch must NOT match; Throwable catches it.
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def p (promise))
(def f (future (deref p)))
(future-cancel f)
(deliver p 1)
(prn (try (deref f) (catch IllegalArgumentException e :iae) (catch Throwable e :other)))
EOF
)
assert_eq 'future_cancel_deref_not_iae' "$got" ':other'

# CancellationException is catchable by its simple name + its supertypes
# (IllegalStateException / RuntimeException).
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def p (promise))
(def f (future (deref p)))
(future-cancel f)
(deliver p 1)
(prn (try (deref f) (catch IllegalStateException e :ise)))
EOF
)
assert_eq 'future_cancel_deref_ise_supertype' "$got" ':ise'

# D-442 sub-step 2a: a future blocked in (Thread/sleep) aborts COOPERATIVELY on
# future-cancel. The sleep raises an UNCATCHABLE signal (past the thunk's own
# catch), so neither the post-sleep body (:slept) nor the catch (:caught) runs.
# Main waits 900ms (> the thunk's 500ms sleep): without abort @a would be :slept
# by 500ms; an un-swallowable abort leaves @a at :init.
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def a (atom :init))
(def f (future (try (Thread/sleep 500) (reset! a :slept) (catch Throwable e (reset! a :caught)))))
(future-cancel f)
(Thread/sleep 900)
(prn @a)
EOF
)
assert_eq 'future_cancel_sleep_cooperative_abort' "$got" ':init'

# future-cancel on an already-realised future → false (clj parity).
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def g (future 42))
(deref g)
(prn [(future-cancel g) (future-cancelled? g)])
EOF
)
assert_eq 'future_cancel_done_false' "$got" '[false false]'

# --- ADR-0176 / D-548(a) — exit-teardown discipline -------------------------
# Portable bounded run (timeout → gtimeout → unbounded), mirroring
# phase16_gc_torture.sh: a guard regression here would HANG or abort, so bound.
run_bounded() { local s="$1"; shift; if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$s" "$@"; else "$@"; fi; }

# AD-056 pin: a RUNNING fire-and-forget future at main-exit does NOT keep the
# process alive (JVM would wait / hang) — cljw hard-exits promptly + safely.
got=$(run_bounded 15 "$BIN" -e '(do (future (Thread/sleep 60000)) :ok)' | last_line)
assert_eq 'exit_pending_future' "$got" ':ok'

# Teardown-window fault injection (CLJW_TORTURE_TEARDOWN_DELAY_MS widens the
# deinit-vs-worker window AFTER the guard): a still-RUNNING allocating worker
# must trigger the hard-exit branch (never a teardown under its feet — the
# pre-ADR-0176 roaming glibc malloc abort) …
got=$(CLJW_TORTURE_TEARDOWN_DELAY_MS=80 run_bounded 15 "$BIN" -e '(do (future (loop [] (str "x" "y") (recur))) :ok)' | last_line)
assert_eq 'exit_teardown_injected_running' "$got" ':ok'
# … and a COMPLETED worker's epilogue must fully quiesce BEFORE the widened
# teardown frees (catches a counter-decremented-too-early regression).
got=$(CLJW_TORTURE_TEARDOWN_DELAY_MS=80 run_bounded 15 "$BIN" -e '(do (future 1) :ok)' | last_line)
assert_eq 'exit_teardown_fireforget_epilogue' "$got" ':ok'

echo
echo "Phase 14 row 14.8 future/promise/delay e2e: all green."
