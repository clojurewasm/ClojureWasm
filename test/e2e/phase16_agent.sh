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
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

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

# Option kwargs are a later slice — a clean error, not a silent drop.
diag=$("$BIN" -e '(agent 0 :validator pos?)' 2>&1 || true)
case "$diag" in
    *"option"*|*"not yet supported"*)
        echo "PASS agent_options_error -> diagnostic" ;;
    *)
        fail "agent_options_error: expected an options-not-yet diagnostic, got '$diag'" ;;
esac

# send to a non-agent is a clean type error.
diag=$("$BIN" -e '(send 5 inc)' 2>&1 || true)
case "$diag" in
    *"expected agent"*|*"agent"*)
        echo "PASS agent_send_nonagent_error -> diagnostic" ;;
    *)
        fail "agent_send_nonagent_error: expected an agent type error, got '$diag'" ;;
esac

echo
echo "Phase B #6 agent (first slice) e2e: all green."
