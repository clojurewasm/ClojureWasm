#!/usr/bin/env bash
# test/e2e/phase16_agent.sh
#
# Phase B #6 — agent (first slice): `(agent init)` + `(send a f & args)` /
# `(send-off a f & args)` + `@agent` (non-blocking atomic read) + `(await a)`.
# Actions on one agent run serially, in send order, on a worker thread; agents
# run concurrently. Engine: runtime/agent.zig (single-drainer handoff, leaf-lock
# queue); surface: lang/primitive/agent.zig + core.clj `await`. ADR-0093.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
last_line() { tail -n 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# @agent is a non-blocking read of the current state.
got=$("$BIN" -e '@(agent 5)' 2>/dev/null | last_line)
assert_eq 'agent_deref' "$got" '5'

# send dispatches an action; await blocks until it has run; @a reads the result.
got=$("$BIN" -e '(let [a (agent 0)] (send a inc) (await a) @a)' 2>/dev/null | last_line)
assert_eq 'agent_send_await' "$got" '1'

# Actions run serially in send order: 100 increments all land = 100.
got=$("$BIN" -e '(let [a (agent 0)] (dotimes [_ 100] (send a inc)) (await a) @a)' 2>/dev/null | last_line)
assert_eq 'agent_serial_order' "$got" '100'

# send with extra args, and ordering: (0 +5) then (* 3) = 15.
got=$("$BIN" -e '(let [a (agent 0)] (send a + 5) (send a * 3) (await a) @a)' 2>/dev/null | last_line)
assert_eq 'agent_send_args' "$got" '15'

# send-off (same path as send in the first slice): conj 1 then 2 onto a list.
got=$("$BIN" -e '(let [a (agent (list))] (send-off a conj 1) (send-off a conj 2) (await a) @a)' 2>/dev/null | last_line)
assert_eq 'agent_send_off' "$got" '(2 1)'

# Concurrency: 4 threads each send 100 (send a inc) to the SAME agent. The
# single-drainer handoff serialises them — every increment lands = 400. A
# stranded-action handoff race would land < 400.
got=$("$BIN" -e '(let [a (agent 0)] (run! deref (mapv (fn [_] (future (dotimes [_ 100] (send a inc)))) (range 4))) (await a) @a)' 2>/dev/null | last_line)
assert_eq 'agent_concurrent_sends' "$got" '400'

# Different agents run concurrently: 8 agents each get 50 increments = all 50.
got=$("$BIN" -e '(let [as (mapv (fn [_] (agent 0)) (range 8))] (run! (fn [a] (dotimes [_ 50] (send a inc))) as) (run! await as) (mapv deref as))' 2>/dev/null | last_line)
assert_eq 'agent_concurrent_agents' "$got" '[50 50 50 50 50 50 50 50]'

# Option kwargs (:validator / :meta / :error-handler / :error-mode) now ship
# (D-441). A passing validator lets actions through.
got=$("$BIN" -e '(let [a (agent 0 :validator number?)] (send a inc) (await a) @a)' 2>/dev/null | last_line)
assert_eq 'agent_options_validator' "$got" '1'

# :meta is readable via (meta agent).
got=$("$BIN" -e '(meta (agent 0 :meta {:a 1}))' 2>/dev/null | last_line)
assert_eq 'agent_options_meta' "$got" '{:a 1}'

# The validator validates the INITIAL value (clj ARef.setValidator) — a bad
# initial throws IllegalStateException "Invalid reference state".
diag=$("$BIN" -e '(agent -1 :validator pos?)' 2>&1 || true)
case "$diag" in
    *"Invalid reference state"*)
        echo "PASS agent_options_validator_reject -> diagnostic" ;;
    *)
        fail "agent_options_validator_reject: expected 'Invalid reference state', got '$diag'" ;;
esac

# send to a non-agent is a clean type error.
diag=$("$BIN" -e '(send 5 inc)' 2>&1 || true)
case "$diag" in
    *"expected agent"*|*"agent"*)
        echo "PASS agent_send_nonagent_error -> diagnostic" ;;
    *)
        fail "agent_send_nonagent_error: expected an agent type error, got '$diag'" ;;
esac

# --- error modes (slice 2) ---
# A poll-until-failed loop synchronises with the async drainer (no Thread/sleep).

# :fail is the default (no error-handler) — a thrown action FAILS the agent, so
# agent-error returns the error (closing the prior silent-:continue F-011 gap).
got=$("$BIN" -e '(let [a (agent 0)] (send a (fn [_] (throw (ex-info "boom" {})))) (loop [i 0] (when (and (nil? (agent-error a)) (< i 500000)) (recur (inc i)))) (some? (agent-error a)))' 2>/dev/null | last_line)
assert_eq 'agent_fail_default' "$got" 'true'

# A send to a failed agent throws (until restart-agent).
got=$("$BIN" -e '(let [a (agent 0)] (send a (fn [_] (throw (ex-info "boom" {})))) (loop [i 0] (when (and (nil? (agent-error a)) (< i 500000)) (recur (inc i)))) (try (send a inc) :no-throw (catch Throwable e :threw)))' 2>/dev/null | last_line)
assert_eq 'agent_send_to_failed_throws' "$got" ':threw'

# restart-agent clears the error + sets state; the agent works again.
got=$("$BIN" -e '(let [a (agent 0)] (send a (fn [_] (throw (ex-info "boom" {})))) (loop [i 0] (when (and (nil? (agent-error a)) (< i 500000)) (recur (inc i)))) (restart-agent a 10) (send a inc) (await a) [@a (agent-error a)])' 2>/dev/null | last_line)
assert_eq 'agent_restart' "$got" '[11 nil]'

# :continue mode — a thrown action is dropped, the agent does NOT fail, later
# actions still run.
got=$("$BIN" -e '(let [a (agent 0)] (set-error-mode! a :continue) (send a (fn [_] (throw (ex-info "boom" {})))) (send a inc) (await a) [@a (agent-error a) (error-mode a)])' 2>/dev/null | last_line)
assert_eq 'agent_continue_mode' "$got" '[1 nil :continue]'

# error-mode default is :fail.
got=$("$BIN" -e '(error-mode (agent 0))' 2>/dev/null | last_line)
assert_eq 'agent_error_mode_default' "$got" ':fail'

# An action may send to its OWN agent (clj allows nested send), and the nested
# send is DEFERRED until the action completes (clj `releasePendingSends`; cljw
# agent.zig `nested_pending`, D-388). We assert the post-FULL-DRAIN state: outer
# sets 0→1 and enqueues inc; a SECOND `(await a)` waits for that nested inc too,
# so @a is deterministically 2 on both clj and cljw. (A single `(await a)` here is
# clj-faithfully 1 — await waits for `outer` only, not the agent-thread-dispatched
# nested inc — but cljw's eager per-agent drainer makes that single-await result
# timing-dependent vs clj's executor pool; the two-await full-drain form is the
# deterministic capability check. See D-388.)
got=$("$BIN" -e '(let [a (agent 0)] (send a (fn [s] (send a inc) (inc s))) (await a) (await a) @a)' 2>/dev/null | last_line)
assert_eq 'agent_nested_send' "$got" '2'

# agent? predicate.
got=$("$BIN" -e '[(agent? (agent 0)) (agent? 5) (agent? (atom 0))]' 2>/dev/null | last_line)
assert_eq 'agent_predicate' "$got" '[true false false]'

# add-watch on an agent (IRef generalization): the watch fires (fn key agent old
# new) after each action stores a new state. `await` guarantees every fire ran
# (incl. its own count-down action's no-op fire `[2 2]`, matching JVM ARef).
got=$("$BIN" -e '(let [log (atom []) a (agent 0)] (add-watch a :k (fn [k r o n] (swap! log conj [o n]))) (send a inc) (send a inc) (await a) @log)' 2>/dev/null | last_line)
assert_eq 'agent_add_watch' "$got" '[[0 1] [1 2] [2 2]]'
# remove-watch stops further fires (the post-add send + its await fire, then none).
got=$("$BIN" -e '(let [log (atom []) a (agent 0)] (add-watch a :k (fn [k r o n] (swap! log conj n))) (send a inc) (await a) (remove-watch a :k) (send a inc) (await a) @log)' 2>/dev/null | last_line)
assert_eq 'agent_remove_watch' "$got" '[1 1]'
# the watch callback receives the agent itself as arg 2 (deref'able mid-watch).
got=$("$BIN" -e '(let [seen (atom nil) a (agent 10)] (add-watch a :k (fn [k r o n] (reset! seen (= r a)))) (send a inc) (await a) @seen)' 2>/dev/null | last_line)
assert_eq 'agent_watch_ref_arg' "$got" 'true'

# ADR-0155 / AD-045 (D-442): the executor-shaped fns RAISE — cljw has no
# configurable executor (silently accepting the user's executor would be a lie).
out=$("$BIN" -e '(send-via :ex (agent 0) inc)' 2>&1 || true)
case "$out" in *"no configurable executor"*) echo "PASS agent_send_via_raises" ;; *) fail "send_via: expected executor error, got '$out'" ;; esac
out=$("$BIN" -e '(set-agent-send-executor! :ex)' 2>&1 || true)
case "$out" in *"no configurable executor"*) echo "PASS agent_set_executor_raises" ;; *) fail "set_executor: expected executor error, got '$out'" ;; esac
out=$("$BIN" -e '(set-agent-send-off-executor! :ex)' 2>&1 || true)
case "$out" in *"no configurable executor"*) echo "PASS agent_set_off_executor_raises" ;; *) fail "set_off_executor: expected executor error, got '$out'" ;; esac
# agent-errors (clj-deprecated) over the live agent-error: nil for a non-failed agent.
got=$("$BIN" -e '(prn (agent-errors (agent 0)))' 2>/dev/null | last_line)
assert_eq 'agent_errors_nil' "$got" 'nil'
# clear-agent-errors on a FAILED agent clears it (= clj restart-agent a @a).
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def a (agent 0 :error-mode :fail))
(send a (fn [_] (throw (ex-info "boom" {}))))
(loop [n 0] (when (and (nil? (agent-error a)) (< n 200)) (Thread/sleep 5) (recur (inc n))))
(clear-agent-errors a)
(prn [(agent-error a) @a])
EOF
)
assert_eq 'clear_agent_errors_failed' "$got" '[nil 0]'

# --- ADR-0155 / D-442 part 2: *agent* / release-pending-sends / shutdown-agents ---

# *agent* derefs to the running agent INSIDE its own action (clj `binding
# [*agent* a]` conveyed to the worker). The action stores `(= *agent* a)`.
got=$("$BIN" -e '(let [a (agent nil)] (send a (fn [_] *agent*)) (await a) (= @a a))' 2>/dev/null | last_line)
assert_eq 'agent_star_in_action' "$got" 'true'

# *agent* is nil OUTSIDE any action (the root binding).
got=$("$BIN" -e '(prn *agent*)' 2>/dev/null | last_line)
assert_eq 'agent_star_outside_nil' "$got" 'nil'

# *agent* is also visible to a watch fn (the binding spans the whole action).
got=$("$BIN" -e '(let [seen (atom nil) a (agent 0)] (add-watch a :k (fn [k r o n] (reset! seen (= r *agent*)))) (send a inc) (await a) @seen)' 2>/dev/null | last_line)
assert_eq 'agent_star_in_watch' "$got" 'true'

# release-pending-sends flushes the sends held during the action NOW and returns
# the count dispatched; the released send actually runs (b gets incremented).
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def cnt (atom nil))
(def b (agent 0))
(def a (agent 0))
(send a (fn [s] (send b inc) (reset! cnt (release-pending-sends)) s))
(await a) (await b)
(prn [@cnt @b])
EOF
)
assert_eq 'release_pending_sends_in_action' "$got" '[1 1]'

# release-pending-sends OUTSIDE an action does nothing and returns 0.
got=$("$BIN" -e '(release-pending-sends)' 2>/dev/null | last_line)
assert_eq 'release_pending_sends_outside' "$got" '0'

# shutdown-agents returns nil and is process-global (each -e is a fresh process).
got=$("$BIN" -e '(shutdown-agents)' 2>/dev/null | last_line)
assert_eq 'shutdown_agents_returns_nil' "$got" 'nil'

# After shutdown-agents a send is DROPPED (clj-faithful): send still RETURNS the
# agent (no throw), and the action never runs (state unchanged). clj swallows the
# executor RejectedExecutionException, so `send` does not throw to the caller.
got=$("$BIN" -e '(do (shutdown-agents) (let [a (agent 0)] (identical? a (send a inc))))' 2>/dev/null | last_line)
assert_eq 'shutdown_agents_send_returns_agent' "$got" 'true'
got=$("$BIN" -e '(do (shutdown-agents) (let [a (agent 0)] (send a inc) (Thread/sleep 100) @a))' 2>/dev/null | last_line)
assert_eq 'shutdown_agents_action_dropped' "$got" '0'

# AD-046 divergence pin: clj routes the swallowed rejection to an agent's
# :error-handler; cljw has no RejectedExecutionException to synthesize, so the
# dropped send does NOT fire the handler (log stays empty). State still unchanged.
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(def log (atom []))
(def a (agent 0 :error-handler (fn [ag ex] (swap! log conj :fired))))
(shutdown-agents)
(send a inc)
(Thread/sleep 100)
(prn [@log @a])
EOF
)
assert_eq 'shutdown_agents_no_handler_fire' "$got" '[[] 0]'

echo
echo "Phase B #6 agent (first slice + error modes) e2e: all green."
