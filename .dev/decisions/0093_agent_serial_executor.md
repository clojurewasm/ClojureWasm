# ADR-0093 — Agent: serial async executor (single-drainer handoff, leaf-lock queue)

- Status: Proposed → Accepted (2026-06-05)
- Phase: B (concurrency), task #6 (first slice)
- Related: ADR-0090 (Phase B concurrency redesign), ADR-0091 (thread_roots GC
  walk), ADR-0092 (heap-value monitor), F-004 (NaN-box), F-006 (mark-sweep STW,
  no write barrier), F-011 (behavioural equivalence), F-012 (VM backend)

## Context

`(agent init)` holds state mutated only by ACTIONS dispatched with `(send a f &
args)` / `(send-off a f & args)`. Actions on one agent run ONE-AT-A-TIME in send
order; different agents run concurrently. `@agent` is a non-blocking state read;
`(await a)` blocks until the actions sent so far have run. JVM Clojure uses an
`AtomicReference<ActionQueue>` + two thread pools (send=fixed, send-off=cached);
the pool choice is a non-observable throughput property.

The design question under cljw's stop-the-world mark-sweep GC (F-006): how to
build the serial-execution queue + worker so the queue is GC-rooted and no thread
can deadlock the collector.

## Decision (first slice)

**Agent heap type** (tag 33, reserved): `extern { header, state: Value, rt, env,
cell: *AgentCell }`. `state` is read (`deref`) / written (drainer) atomically
(acquire/release) — the drainer is the SOLE writer (one drainer per agent at a
time), `@agent` the reader, so a single-word atomic load/store suffices (no CAS;
reuses the atom fix pattern).

**Off-heap `AgentCell` (gpa-allocated, finaliser-freed)**: `{ mutex: Io.Mutex,
draining: bool, actions: ArrayList(Value), head: usize }`. The pending-action
queue is this **off-heap gpa list**, NOT a Value PersistentQueue — see the
leaf-lock invariant below.

**Single-drainer handoff (serial execution)**: the thread that transitions the
queue empty→non-empty sets `draining=true` under `cell.mutex` and spawns the sole
drainer; the drainer pops actions until empty, then clears `draining` and exits.
`draining` is checked/set under `cell.mutex`, so a `send` either sees
`draining==true` (the live drainer picks its action up) or `draining==false` (it
spawns a fresh drainer). **Invariant: the drainer's "queue-empty test → clear
`draining` → release mutex → return" is ONE critical section** — never split it,
or an action can be stranded with no live drainer.

**`cell.mutex` is a LEAF lock (the load-bearing GC invariant)**: under the STW
collector, a thread BLOCKED on `cell.mutex` is not at a safepoint, so if a collect
armed while it blocked, `stopWorld` would wait for a park that never comes. So
`cell.mutex` is held ONLY across the gpa queue push/pop — which never allocates on
the GC heap and never parks — NEVER across `callFn`, a GC allocation, or a park.
The action vector `[f & args]` is built (GC-allocated) BEFORE the lock; the action
runs (callFn + setState) AFTER the unlock. **This is why the queue is an off-heap
gpa list and not a Value PersistentQueue: `conj` would GC-allocate under the
mutex, breaking the invariant** (a parked-mid-conj drainer holding `cell.mutex`
would hang `stopWorld` for any peer blocked on that mutex).

**GC**: `traceGc` marks `state` + every queued action in `cell.actions[head..]`, so
the queue is a root source the collector walks (mutators parked during a collect →
the list is quiescent while traced). The drainer registers a `ThreadGcContext`
like `future.worker`, so its in-flight action mid-`callFn` is rooted by its
operand stack. The fabrication window (a fresh action vector held only as a Zig
local in `send` before it is queued) rides the #4a' `gc_self_guard` hardening —
dormant while auto-collect is OFF, as today.

**`await`** (core.clj, no new primitive): sends a sentinel action that delivers a
`promise` to each agent (so agents drain concurrently), then blocks on each
promise. A promise IS cljw's cross-thread latch (clj uses a CountDownLatch), held
alive by the sentinel action in the agent's queue. The sentinel returns state
unchanged. This is clj's latch-action semantics — NOT a "wait until idle" poll,
which the DA showed can hang a program that terminates under clj.

**Spawn-per-drain-episode, no pool**: send/send-off share one path; the two-pool
starvation avoidance is non-observable (F-011). A real bounded pool / `send-via`
is a later perf tier.

**Deferred to later slices**: watches/validator on agents (+ the shared IRef
substrate extraction the DA recommends, decided WHEN that surface lands and a
second consumer is concrete — Alt 2); error modes (`:continue`/`:fail`,
`agent-error`, `restart-agent`, `set-error-handler!`, `set-error-mode!`);
`send-via`; STM `send`-deferral; `*agent*`; nested-send/`release-pending-sends`;
`shutdown-agents`; `await-for` timeout. `(agent init opts...)` and add-watch /
set-validator! on an agent raise a clear "not yet" error (transient stubs, not
silent drops).

## Alternatives considered (Devil's-advocate subagent, fresh context, verbatim)

> ### Alt 1 (smallest-diff): Lock-free MPSC action queue (AtomicReference head)
> instead of mutex-guarded queue Value — better: removes the cell.mutex from the
> enqueue/drain hot path entirely; the empty→non-empty handoff becomes a single
> CAS on the queue head (the `draining` flag is folded into a tagged head
> pointer), so send/send-off never block and there is no "drainer holds cell.mutex
> at a non-safepoint" window. The `await` cond is the only remaining mutex use.
> breaks: it abandons the draft's "queue is a traced Value field" simplicity — a
> lock-free linked list of actions is NOT a single persistent-collection Value the
> existing `traceGc` can mark in one call, so it forces a NEW GC root source (the
> off-heap node chain must be walked by the collector, or each node must itself be
> a heap Value with its own tag). That re-opens exactly the #4a' concern the draft
> closed "by construction," and an off-heap atomic node chain mutated by the
> drainer concurrently with the STW collector's read needs its own memory-ordering
> proof. Net: smaller hot-path diff, larger GC-rooting surface — a smallest-diff
> bias against F-002's finished form.
>
> ### Alt 2 (finished-form-clean): Generalized IRef/handoff substrate shared by
> atom + agent (+ future ref/STM) — better: clj implements agent, atom, ref, and
> var watches/validators over ONE `IRef`/`ARef` machinery; the draft re-implements
> watches+validator+meta as fresh Agent fields duplicating atom's. F-011
> (commonization outranks effort) + F-009 (neutral impl home) point hard at
> extracting a shared `runtime/concurrency/iref.zig` (watch-notify, validator-
> check, meta) and a shared `runtime/concurrency/handoff.zig` (the single-drainer
> empty→non-empty episode spawner) that BOTH agent and any future serial-executor
> reuse. The single-drainer handoff is the agent's distinctive logic; isolating it
> as a tested substrate means `await`, error-mode (:continue/:fail), and
> restart-agent later slices bolt onto a proven core instead of re-deriving the
> race each time. This is the cleanest finished form and I recommend it per F-002
> even though it is a bigger diff than the draft. breaks: nothing F-NNN. It
> enlarges THIS slice (extract + retrofit atom's watches/validator onto the shared
> iref), and the watch/validator extraction touches already-shipped atom code
> (ADR-0081) — a depth-2/3 surgery, not a green-field add. The risk is over-
> abstracting the handoff before the second consumer (STM `send` deferral, agent
> pools) exists to validate the shape; mitigate by extracting only what atom+agent
> demonstrably share NOW (watch/validator/meta) and leaving the handoff agent-local
> until a second serial-executor appears.
>
> ### Alt 3 (wildcard): Pool-less but drainer-reuse via a parked-worker handoff
> (no spawn-per-episode) — better: instead of `std.Thread.spawn` per drain-episode,
> keep ONE long-lived drainer thread per agent that parks on `cell.cond` when the
> queue empties (instead of exiting) and is signalled by `send`. Eliminates per-
> episode OS-thread spawn/teardown cost, and a persistently-registered
> `ThreadGcContext` means the collector's root walk shape is stable instead of
> churning register/unregister every episode (the very churn the D-244 stress test
> was added to harden). breaks: it converts the agent into a permanently-live
> thread + permanently-registered GC root context that never exits until
> `shutdown-agents` — so a program that creates many short-lived agents leaks one
> parked OS thread each (clj's pool bounds this; a per-agent permanent thread does
> not). It also makes `shutdown-agents` (a deferred slice) a CORRECTNESS
> prerequisite rather than a nicety, because without it the process cannot exit
> cleanly (parked threads block join). Higher infra cost for a throughput win that
> is non-observable (F-011) — wildcard, not recommended for the first slice.
>
> ### Handoff-race verdict: race-free, with one required ordering constraint the
> draft already states. [the stranding interleaving cannot occur because the
> drainer's `draining=false` write and a send's `draining` read are both under
> `cell.mutex`; if a send enqueues before the drainer's empty-check, the drainer
> sees non-empty and keeps draining; if after the drainer cleared draining+
> unlocked, the send reads draining==false and spawns a fresh drainer. Required
> invariant: the empty-test→clear-flag→release-mutex→return is a single critical
> section.]
>
> ### GC-queue verdict: traced-Value-field is sufficient for MARKING (STW means no
> concurrent mutator during traceGc), but the draft has a latent LIVENESS bug that
> is decisive: a worker reaches a safepoint ONLY at the alloc-prologue park or the
> VM back-edge poll. A thread BLOCKED on `cell.mutex` is NOT at a safepoint, so if
> a second thread is blocked on cell.mutex when STW arms, stopWorld hangs forever.
> The fix the main loop MUST apply: never hold `cell.mutex` across a VM call or an
> allocation — pop under the lock, UNLOCK, then run callFn+setState, re-lock for
> the next. (This is why the queue is gpa-backed, not a Value PersistentQueue whose
> conj allocates under the mutex.)
>
> ### await verdict: wait-until-idle is an observable divergence (a program that
> terminates under clj can HANG under cljw if another thread keeps sending). Ship
> the latch action (a sentinel that fires a per-await condition / promise), not
> wait-until-idle.
>
> ### Recommendation: Alt 2 (shared IRef/handoff substrate) for the surface
> (watches/validator/meta), with the draft's mutex-guarded queue + single-drainer
> handoff as the agent-local core — and ship the latch-based `await`. The single
> most important correctness risk: `cell.mutex` must be a LEAF lock, never held
> across `callFn`, an allocation, or a park.
>
> ### F-NNN check: none violated. Alt 1's lock-free off-heap node chain brushes
> against F-006 (recorded as the reason it is the rejected smallest-diff option).
> Alt 2/3 are F-NNN-clean. The latch-`await` strengthens F-011. `@agent` reusing
> atom's single-word atomic load is torn-read-free.

The main loop adopted: the draft core (mutex-guarded queue + single-drainer
handoff) **with the off-heap gpa queue** (the leaf-lock invariant the DA proved
load-bearing forces gpa-backed over a Value PersistentQueue, since conj would
alloc under the mutex — this is a refinement of the draft, not a rejection), the
**latch-based `await`** (DA's correction over wait-until-idle), and **defers
watches/validator + the Alt 2 IRef extraction to the watches/validator slice**
(per the DA's own caution against over-abstracting before the second consumer is
concrete). Deferring watches/validator (a separate surface) is feature slicing,
not a cycle-budget defer — the iref extraction lands WITH that surface.

## Consequences

- `(agent init)` + send/send-off + `@agent` + await work, serial-per-agent +
  concurrent-across-agents, clj-result-equivalent: send 100 → 100; (+5 then *3)
  → 15; send-off conj → (2 1); 4×100 concurrent sends to one agent → 400 (handoff
  race-free, 30/30 ReleaseSafe); 8 agents each +50 → all 50.
- An action that throws leaves state unchanged and draining continues (clj
  `:continue` mode). clj's default (no handler) is `:fail`; the configurable
  error-mode + `agent-error`/`restart-agent` is a later slice — recorded so the
  default-mode divergence is not a silent drop.
- A fire-and-forget agent is `gc.pin`ned while its drainer runs (unpinned on
  drainer exit), so it is not swept mid-drain.
- Process exit with a still-running drainer is an orphan (same limitation as a
  still-running future worker); `shutdown-agents` is a later slice.

## Affected files

- `src/runtime/agent.zig` (new) — the Agent type + cell + single-drainer engine.
- `src/lang/primitive/agent.zig` (new) — `agent` / `send` / `send-off`.
- `src/lang/clj/clojure/core.clj` — `await` (latch over send + promise).
- `src/lang/primitive/stm.zig` — `deref` dispatch for `.agent`.
- `src/runtime/runtime.zig` — register the agent GC hooks.
- `src/runtime/error/catalog.zig` — `agent_options_unsupported`.
- `src/main.zig` — test-aggregator import for `agent.zig`.
- `test/e2e/phase16_agent.sh` (new) + `test/run_all.sh` registration.
