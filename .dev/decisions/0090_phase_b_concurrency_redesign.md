# 0090 — Phase B concurrency architecture (real STM / agents / threads on pinned Zig 0.16)

- **Status**: Proposed → Accepted
- **Date**: 2026-06-04
- **Author**: autonomous loop (Phase B entry ceremony, D-242)
- **Tags**: concurrency, gc, stm, runtime, phase-b
- **Supersedes-in-part**: ROADMAP §7.1 (the pre-0.16 Clojure↔Zig primitive
  mapping table) + §7.2 barge wording; corrects ADR-0089 §2's "spawn-based plan
  is unbuildable" framing.

## Context

Phase B (ADR-0089 re-cut) implements the KNOWN-unimplemented concurrency CORE
that libraries depend on: STM transactions, `agent`, `locking`, real threading
(`future`/`promise`/`delay`/`pmap` run SYNCHRONOUSLY today — `future.zig`
eager-inline), `Thread` interop, GC thread-safety, and dynamic-binding
conveyance to spawned threads (D-241). The `ref`/`TVal` MVCC history ring is a
built SHELL with no transaction engine. This ADR is the Phase-B-entry
§7-redesign mandated by ADR-0089 + F-003 (Structural-imagination) with a
mandatory Devil's-advocate fork (principle.md depth ≥ 2).

**Corrected premise (the load-bearing fact this session verified).** ADR-0089 §2
and the ROADMAP §7.1 note state the `std.Thread.spawn` plan is "unbuildable" /
"APIs removed in Zig 0.16". This is **half-wrong**, and the correct half matters:

- The **pinned Zig 0.16.0** (flake.nix → `/nix/store/…-zig-0.16.0`, what cljw
  actually compiles against) **KEEPS** `std.Thread.spawn`/`join`/`getCpuCount`
  and `std.atomic.Value`; it **REMOVED** `std.Thread.{Mutex,Condition,Semaphore,
  Pool,WaitGroup,Futex}` and moved the sync primitives to **`std.Io`**
  (`std.Io.Mutex.lockUncancelable(io)`, `Io.Condition`, `futexWaitTimeout`,
  `Io.Threaded` thread pool, `io.async`/`concurrent`/`Future`).
- The add-dir clone `~/Documents/OSS/zig` is a **post-0.16 master** (Nov 2025)
  that re-added `std.Thread.Mutex` — it is the WRONG tree for 0.16 API questions
  (memory `zig016-pinned-vs-oss-checkout`).
- **cw v0 already ships** real STM (MVCC LockingTransaction), agents (action
  queue + `thread_pool.zig`), futures (`FutureResult{Io.Mutex,Io.Condition}`),
  and a global-`gc_mutex` GC against THIS exact pinned compiler — buildability is
  proven, not speculative.
- A throwaway spike this session (`private/spike_concurrency_0.16.zig`, gitignored)
  validated the three load-bearing assumptions on the current pinned compiler:
  (1) a `std.mem.Allocator.VTable` callback CAN lock a `std.Io.Mutex` via a
  process-wide `io_default` singleton (the answer to "vtable callbacks cannot
  take an `io` arg" — `arena.zig:13-17`); (2) `std.Thread.spawn` works (4 mutator
  threads × 1000 allocs serialized through one heap mutex); (3) `std.atomic.Value`
  cmpxchg works. It also surfaced two API-currency facts: `GeneralPurposeAllocator`
  was renamed (use `page_allocator`/`DebugAllocator`); `std.Io.Mutex` inits via
  `.init` (not `.{}`).

So the §7 redesign is NOT "the plan is impossible, start over" — it is "the sync
primitives moved to `std.Io`, reached via an `io_default` singleton; adopt cw
v0's proven pinned-0.16 approach, **re-derived cljw-clean** per `no_copy_from_v1`
(reference, not copy)."

**The GC-safety hole the DA-fork caught (the most important finding).** The
naive "ONE global heap mutex, mark-sweep takes it stop-the-world" wording is a
*latent lie inherited from v0*: v0's `gc_mutex` serializes *allocation*, but v0
does NOT actually suspend running mutators (its `ThreadRegistry` is a vestigial
counter that scans no thread's stack). A mutator between allocations — holding a
freshly-`msAlloc`'d untraced `[*]u8` on its native stack, or running
non-allocating code — keeps running while the sweep reclaims its allocation →
**use-after-free under real parallelism**. This is masked today only because
`future`/`pmap` run synchronously (D-242). Real `Thread.spawn` opens the hole.
Shipping it would violate F-011 (observable correctness). The redesign must
confront this, not paper over it.

Grounding read: `.dev/project_facts.md` F-002 / F-004 / F-005 / **F-006** (GC =
single-generation mark-sweep + 3-layer allocator; generational/concurrent GC
explicitly deferred to ROADMAP §89.2) / **F-011 §2** (behavioural equivalence is
the target; internals free) / **F-012** (production backend = VM, tree_walk =
oracle; dual-backend parity); `private/notes/phaseB-entry-concurrency-survey.md`
(the Zig-0.16 availability matrix + v0's proven pattern + per-primitive
observable contracts); `.dev/debt.yaml` D-242 / D-241; `no_jvm_specific_assumption.md`;
`no_copy_from_v1.md`.

## Decision

cljw's Phase B concurrency is **OS-threads + a global-allocation-lock GC with a
root-publication handshake + MVCC STM**, re-derived cljw-clean from cw v0. The
north star is **user-observable parity, internals free** (F-011 §2): the
internals below need NOT mirror the JVM, only the observable input→output
(including error cases) must match real Clojure.

1. **Threading substrate** — real OS threads via `std.Thread.spawn`.
   `future`/`promise`/`pmap`/`pcalls` run on spawned threads; `delay` stays
   lazy-once. A `runtime/concurrency/thread_pool.zig` (re-derived from v0) backs
   `agent` send/send-off + bounded `pmap` fan-out. Sync primitives are
   `std.Io.Mutex`/`Io.Condition` reached through a process-wide **`io_default`
   singleton** (`runtime/io_default.zig`, re-derived) so call sites and
   `Allocator.VTable` callbacks that have no `io` in hand can still lock.
   `future`/`promise` block on deref via an `Io.Mutex`+`Io.Condition` result
   cell; a thunk that throws is caught and re-raised at deref (the Value-carried
   exception channel, D-115).

2. **GC thread-safety — global allocation lock + root-publication handshake
   (the mandatory DA-fork correction; Alternative 2 below).** Allocation
   serializes on one global heap `Io.Mutex` via `io_default` (F-006-clean,
   single-gen mark-sweep unchanged). Collection-safety is a first-class
   **root-publication protocol**, NOT v0's vestigial counter: every thread that
   can hold cw Values owns a `ThreadGcContext` (registered at `Thread.spawn`,
   deregistered at join) publishing a pointer to its current `RootSet` (operand
   stack + binding-frame chain head). Collection takes the global lock, then
   walks the **union of all live `ThreadGcContext`s** to build the root set,
   marks, sweeps. Correctness invariant (stated, not assumed): *a raw `[*]u8`
   from the allocator is not a root until installed into a traced location; the
   install window is collection-free because allocation and collection share the
   lock.* Hence collection only happens at allocation points (lock held, roots
   quiescent), and every other thread is either blocked in the allocator (its
   published roots current + traced) or running non-allocating code (holding only
   already-installed, hence-marked, Values). Mutation-under-sweep (transient
   conj, atom CAS) is safe because the mutated structure is reachable from a
   published root and was marked — **no write barrier, no generational machinery,
   no per-step safepoint poll** (zero hot-loop tax; JIT-friendly since leaf
   integer loops don't allocate and so never reach a collection point). This
   stays strictly inside the F-006 envelope and answers the survey's open
   question #4.

3. **STM — MVCC `LockingTransaction`, retry-only.** `dosync`/`alter`/`commute`/
   `ensure`/`ref-set` over the existing per-ref `Io.Mutex` + `Ref`/`TVal` history
   ring: read-point, in-transaction value cache, ordered lock acquisition by ref
   identity (deadlock-free), commit-point stamping, bounded retry. **MVCC is
   chosen for observable snapshot-semantics fidelity** under the F-010
   real-library quality loop (a Clojure programmer's "reads see a consistent
   snapshot; writers retry" mental model, and library code that observes a
   long-running read transaction proceeding against a snapshot), **NOT because
   the ring already exists** (treating the built ring as the reason would be the
   Reservation-as-bias smell, F-002 §4). The global-transaction-lock STM
   (wildcard alternative below) is observably equivalent for the *guaranteed*
   contract and is recorded as a rejected alternative.

4. **Divergence — no barge (AD-013).** cljw STM is **retry-only**; it drops JVM's
   "barge" (younger-transaction preemption for starvation control). Result
   equivalence holds; only contention fairness/throughput differ. Recorded as
   accepted divergence **AD-013** (not a bug). The global-lock STM would have
   neither barge nor retry; MVCC-retry is the closer observable match.

5. **agent / locking / atom / ref CAS / volatile** — `agent`: action queue +
   the thread pool, send (fixed pool) vs send-off (unbounded), error-mode +
   handler, `await` via a condition. `locking`: a heap-value lock via `Io.Mutex`
   (ADR-0009 header `lock_state`), not a JVM monitor. `atom`/`ref` CAS:
   `std.atomic.Value` cmpxchg with validators + watches (already half-landed,
   D-157). `volatile!`: unsynchronized `@atomicLoad`/`@atomicStore`.

6. **Dynamic-binding conveyance** — clone the threadlocal binding frame
   (`env.zig current_frame`, the `binding-conveyor-fn` shape) at `Thread.spawn`
   so `(future (binding [...] ...))` and `bound-fn` (D-241) convey to the worker.
   `*out*`/`*err*`/`*in*` per-thread routing folds in here (D-238).

7. **Dual-backend (F-012)** — every primitive works identically on tree_walk
   (oracle) and VM (production). The `ThreadGcContext` publishes a backend-agnostic
   root set (operand-stack-equivalent + binding-frame head), so the GC handshake
   needs no per-backend hot-loop edit. STM/agent/future bodies just call `eval`,
   which dispatches per backend.

**File layout** (Structural-imagination, F-003): a new `src/runtime/concurrency/`
subtree — `io_default.zig`, `thread_pool.zig`, `lock_tx.zig` (the
LockingTransaction engine over the existing `stm/{ref,tval}.zig`), `gc_thread.zig`
(the `ThreadGcContext` registry + union root walk, co-owned with `gc/`). The
existing `runtime/{future,promise,delay,atom,volatile}.zig` gain real bodies;
`runtime/agent.zig` + `runtime/locking.zig` are new. This is rework-OK with test
guards (F-002): the synchronous shells are replaced, not patched.

## Alternatives considered (Devil's-advocate fork, fresh context, 2026-06-04, verbatim)

Briefed with F-002 / F-006 / F-011 §2 / F-012 / F-004 / F-005 as hard
constraints. Grounded in the Phase-B concurrency survey, `.dev/debt.yaml`
D-242/D-241, and a direct read of cw v0's `io_default.zig` / `gc.zig`
(msAlloc/gcCollect/collectIfNeeded/ThreadRegistry) / `stm.zig` / `thread_pool.zig`.

### Leading finding: the proposed Candidate A contains a load-bearing mis-statement about the GC

The proposed ADR §2 said "ONE global heap mutex … mark-sweep collection takes
the lock stop-the-world." This is **false against the very v0 design it claims to
re-derive**. v0's `gcCollect`/`collectIfNeeded` take `gc_mutex` for the duration
of `traceRoots + sweep`, which blocks *other threads trying to allocate* — but a
mutator thread NOT currently inside an allocator call keeps running concurrently
with the sweep. v0's `ThreadRegistry` (gc.zig:1228) is documented "for
stop-the-world GC" but only does `fetchAdd/Sub` on a counter; nothing suspends a
running mutator, nothing scans a running thread's native stack/registers. The
`RootSet` is supplied by whichever thread triggered collection — a *second*
mutator thread's in-flight Values (a freshly-`msAlloc`'d `[*]u8` in a Zig local,
an interpreter temporary on thread 2's stack) are invisible to `traceRoots`. The
sweep reclaims them → **use-after-free under real parallelism.** Masked today
only because `future`/`pmap` run synchronously (D-242). "Global heap mutex" makes
*allocation* thread-safe; it does NOT make *collection* safe with other running
mutators. The ADR MUST pick a real answer; inheriting v0's latent hole verbatim
is a Reservation-as-bias / Progress-pressure smell.

### Alternative 1 — Smallest-diff: cooperative safepoint over v0's machinery

Keep Candidate A verbatim but make the GC honest with a cooperative safepoint:
each worker polls a `gc_requested: atomic.Value(bool)` between eval steps and
parks on a condition; the collector sets the flag, waits until all others park
(v0's `ThreadRegistry` counter, now load-bearing), collects with each parked
thread's `RootSet` registered, clears + broadcasts.
- **Better**: closes the use-after-free hole with the least new code; reuses v0's
  vestigial counter + condition idiom; fastest convergence to a correct green.
- **Breaks/costs**: requires a safepoint poll in EVERY unbounded non-allocating
  loop (tree_walk loop AND VM dispatch AND long native primitives — F-012
  two-edit surface); a missed site = collection-hang (worse to debug than a
  crash); a permanent per-step branch in the hottest loop (perf tax the future
  JIT must fight). Smallest-diff answer to a structural question — F-002 says it
  loses when finished forms differ.
- **F-NNN**: F-006 ✓ (still single-gen, safepoint is coordination not a new
  algorithm); F-011 ✓ (correct); F-012 ⚠ (two in-sync hot-loop edits).

### Alternative 2 — Finished-form-clean: root-publication handshake decoupled from the allocator lock (RECOMMENDED)

Separate the two concerns v0 conflated. (1) Allocation stays behind the
`gc_mutex` global lock via `io_default` — fine, F-006-clean. (2) Collection
safety becomes a first-class root-publication handshake: each thread owns a
`ThreadGcContext` (registered at spawn, deregistered at join) carrying a pointer
to its current `RootSet` (operand-stack slice + binding-frame chain head + a
small pinned-across-collection guard list). Collection acquires the global lock,
walks the registry of ALL live contexts to build the union root set, marks,
sweeps. The airtight invariant: *a raw `[*]u8` from the allocator is not a root
until installed into a traced location; the window between `msAlloc` returning
and that install must not contain a collection point.* Because allocation and
collection share `gc_mutex`, that window is automatically collection-free for the
allocating thread — `msAlloc` returns under the lock, the caller installs, and
only a subsequent allocation (re-taking the lock) can trigger collection. So the
invariant holds with NO per-step safepoint poll: collection only happens at an
allocation point (lock held, roots quiescent), and other threads are either (i)
blocked in `msAlloc` (last-published root context current + traced) or (ii)
running pure non-allocating code (holding only already-installed/traced Values).
Subtle case: a thread in (ii) mutating a traced structure (transient conj, atom
CAS) while another sweeps — safe because the structure is reachable from the
published root and was marked (no write barrier needed; not generational —
F-006 ✓). The one unsafe pattern (fabricating a new Value on the native stack and
not installing it while another collects) cannot occur, because fabricating a
Value IS an allocation, which takes the lock, which excludes concurrent
collection. **That is the load-bearing argument; it is why this is correct
without safepoints.**
- **Better than A & Alt 1**: correct by construction with ZERO hot-loop tax (no
  per-step poll, no missed-poll hang); states the GC-safety invariant explicitly
  (survey open-question #4); cleanest base for the future JIT (leaf integer loops
  don't allocate → no collection point → no safepoint instrumentation, which Alt
  1 would have to thread through JIT'd code).
- **Breaks/costs**: forces a `ThreadGcContext` registration discipline at every
  `Thread.spawn`; `RootSet` becomes per-thread-published rather than
  passed-by-the-triggering-thread (a real change to v0's `traceRoots(self,
  roots)` → `traceRoots(self, registry)`); more upfront design than Alt 1. The
  "mutation under sweep is safe because the object was marked" argument depends
  on collection fully under the lock (no concurrent mark) — fine here, and it
  closes the door on concurrent/incremental mark as a later optimization unless a
  write barrier is added then. Acceptable: F-006 defers generational/concurrent
  GC to §89.2, so the finished form FOR THE F-006 ENVELOPE is exactly this
  stop-collection-at-the-lock design. Per F-002 the larger upfront design is the
  right call — different (correct, tax-free) finished form than Alt 1.
- **F-NNN**: F-006 ✓✓ (single-gen, 3-layer alloc, no write barrier, no
  generational machinery — handshake is coordination, fully in-envelope; cw-heap
  separate from zwasm); F-011 ✓✓ (correct under real parallelism; invariant
  stated); F-012 ✓✓ (root-publication context is backend-agnostic; no per-step
  poll → no per-backend hot-loop edit, unlike Alt 1).

This is the shape the DA picks: satisfies F-006 MORE cleanly than the proposed
"stop-the-world" wording (which is neither true nor needed), answers survey
open-question #4, and per F-002 its larger design cost is the right trade. The
per-ref MVCC STM, `io_default` singleton, and `FutureResult` machinery from
Candidate A are retained unchanged — Alt 2 differs from Candidate A ONLY in the
GC-collection-safety mechanism (§2), the one part of Candidate A that was a lie.

### Alternative 3 — Wildcard: `std.Io` structured-concurrency executor + single global-transaction-lock STM

(1) Concurrency substrate = `Io.Threaded` executor + `io.async`/`io.concurrent`
+ `Future.await` (survey Candidate B), not raw `Thread.spawn`; `future`/`pmap`
become `io.concurrent` tasks whose results land in a GC-heap `FutureResult` cell;
`future-cancel` maps to `Future.cancel` (which raw spawn can't offer cleanly).
(2) STM = drop per-ref MVCC; `dosync` takes one process-wide `Io.Mutex`, runs the
body, commits, unlocks — no read-point, no history ring, no retry.
- **Better**: dramatically less STM machinery (~30 lines vs the MVCC ring +
  read/commit-point + retry + commute-replay); per F-011 §2 a global-lock STM is
  observably equivalent for Clojure's *guaranteed* contract (atomic + isolated
  bodies; commute reorderable; side effects may repeat) — a global lock trivially
  gives atomicity+isolation, commute runs in-order, "side effects may repeat" is
  vacuously satisfiable (never retries — even more predictable). Kills the
  no-barge AD entirely (no barge AND no retry). `Future.cancel` gives real
  `future-cancel`; the executor is swappable (`Io.Threaded`↔`Io.Evented`) which
  matters for the F-001 zwasm-v2 async-I/O future.
- **Breaks/costs**: the global txn lock serializes ALL `dosync` program-wide — a
  throughput cliff under heavy STM contention vs MVCC's per-ref concurrency (fine
  for a runtime whose differentiator is not STM throughput, but a real
  latency-under-contention difference — record AD if chosen). `Io.Future(R)` is
  typed/scoped around a call while a Clojure `future` is an unbounded-lifetime GC
  heap object deref'able arbitrarily later → bridging needs `io.concurrent` + a
  manual GC-heap cell anyway, so part of the "use the blessed model" cleanliness
  evaporates. And `Io.Threaded` workers still allocate cw Values → still need Alt
  2's handshake, so the wildcard does NOT dodge the leading GC finding.
- **F-NNN**: F-006 needs Alt 2's handshake regardless; F-011 ✓ (global-lock STM
  observably equivalent — fewer divergences than MVCC's no-barge); F-012 ⚠ (the
  async model must be backend-agnostic — holds since both call `eval`).
- **Verdict**: the global-transaction-lock STM is the strongest under-considered
  idea (less code, more predictable, fewer divergences). The loop's attraction to
  MVCC is *partly* Reservation-as-bias (the ring is already built). But the honest
  tie-breaker is observable fidelity: MVCC reproduces JVM's read-point snapshot
  model, and real library code under F-010 may observe MVCC-specific interleaving
  (a long-running read transaction proceeding against a snapshot that a global
  lock would serialize). So MVCC is the safer finished-form bet for observable
  fidelity, and the built ring is a legitimate secondary bonus, not the reason.
  The `Io.async` executor half is a reasonable later/scoped option for `pmap`
  fan-out (survey Candidate C) but not for unbounded-lifetime `future`/`agent`.

### DA synthesis / recommendation

1. Adopt Candidate A's spine (proven on the pinned compiler, F-NNN-clean).
2. **Replace §2's "stop-the-world global heap mutex" with Alt 2's
   root-publication handshake** — the one mandatory correction (the proposed
   wording is false against v0 and would ship a use-after-free; F-011 violation).
   Alt 2 stays fully in F-006, adds zero hot-loop tax, answers survey #4.
3. Keep MVCC STM (reject the global-lock wildcard) but for the right reason:
   observable snapshot fidelity under F-010, NOT "the ring already exists"
   (Reservation-as-bias). Record the global-lock STM as observably-equivalent for
   the guaranteed contract but possibly divergent on interleaving.
4. Defer the `Io.async` executor to a later scoped use (pmap fan-out / Phase-16
   async I/O), not the Phase-B `future`/`agent` spine.

The single highest-value finding: **the GC §2 "stop-the-world" claim is a latent
lie inherited from v0's vestigial `ThreadRegistry`; the ADR must not stamp it as
written.** The main loop adopted this correction (Decision §2).

## Consequences

- **ROADMAP §7.1** mapping table is superseded by Decision §1-7 (Mutex/Condition
  → `std.Io` via `io_default`; `binding_stack.zig` → `env.zig`; phases → Phase B).
  §7.1 + §7.2 edited to align (§17).
- **ADR-0089 §2** "spawn-based plan is unbuildable" is corrected: `std.Thread.spawn`
  is KEPT in pinned 0.16; sync moved to `std.Io`; v0 + the spike prove buildability.
- **GC root-publication handshake** is the load-bearing new invariant; the GC
  Phase-5 work gains a `ThreadGcContext` registry. Still single-gen mark-sweep
  (F-006); concurrent/incremental mark stays deferred to §89.2.
- **AD-013** is RESERVED for the STM retry-only / no-barge divergence; the
  `accepted_divergences.yaml` entry + its `pin` land **with the Phase B concurrent
  STM test**, not now — `check_accepted_divergences.sh --gate` enforces that every
  `pin` test path exists, so an AD cannot be pre-added before its locking test
  does. (Reserving the number is a memo, not a contract — F-002.) The no-barge
  decision itself is recorded here + in ROADMAP §7.2.
- **D-242** Phase-B scope is refined by this ADR's §1-7 sequencing; the GC-safety
  handshake is a prerequisite for ANY real-threading primitive (it lands first).
- **Dual-backend (F-012)** preserved: backend-agnostic root publication, eval-based
  bodies.
- The synchronous `future`/`promise`/`delay`/`pmap` shells are replaced (rework-OK
  with test guards, F-002), not patched.

## Affected files

- `.dev/ROADMAP.md` §7.1 / §7.2 (align to this ADR).
- `.dev/accepted_divergences.yaml` (AD-013 STM no-barge — added WITH the Phase B
  concurrent STM test that pins it, per the gate's pin-existence rule; not now).
- `.dev/debt.yaml` D-242 (reference this ADR as the Phase-B §7 design).
- Phase-B implementation (future commits, rework-OK + per-commit gate):
  `src/runtime/concurrency/{io_default,thread_pool,lock_tx,gc_thread}.zig` (new),
  `src/runtime/gc/*` (`ThreadGcContext` registry + union root walk),
  `src/runtime/{future,promise,delay,atom,volatile}.zig` (real bodies),
  `src/runtime/{agent,locking}.zig` (new), `src/runtime/stm/*` (transaction
  engine), `src/runtime/env.zig` (binding-frame conveyance).

## Revision history

- **2026-06-04 — GC-safety gap surfaced at #3 implementation (D-244).** While
  designing increment #3 (the `ThreadGcContext` root-publication handshake), the
  root-set walker (`runtime/gc/root_set.zig`) was found to enumerate only
  `ns_vars` / `current_frame` (dynamic-binding) / `macro_root_slot` /
  `permanent_roots` — it does **NOT** root the **VM operand stack**
  (`vm.zig` `stack: [OPERAND_STACK_MAX]Value`, a Zig local array in the run loop)
  nor tree_walk's native-Zig-stack intermediates. This is safe TODAY only because
  `collect()` runs exclusively at **quiescent explicit call points** (no
  auto-collect; `alloc` never calls `collect`), where no operand stack is live.
  **For Phase B real threads (#4), this breaks**: a worker thread mid-`eval`
  holds live Values on its VM operand stack / native stack that are NOT a root
  source, so a `collect()` triggered on another thread would sweep them →
  use-after-free. Additionally, a non-allocating worker mutating its
  dynamic-binding frame chain (`pushFrame`/`popFrame`) DURING another thread's
  root walk is a read-during-write race on the chain.
  **Consequence for the Decision**: Alternative 2's "no safepoint needed"
  argument (install-window collection-free) covers *allocation* but is
  **insufficient for a mid-`eval` worker** — its un-rooted operand/native-stack
  Values are the gap. The GC-safety mechanism must be re-analysed: a **safepoint
  (Alternative 1)** where collection runs only when every thread is quiescent
  (operand stacks empty/saved), OR making the **VM operand stack a published
  root** (per-`ThreadGcContext`) plus a rule that tree_walk workers (native-stack
  intermediates, un-enumerable) do not run during collect. This re-analysis +
  its own **DA-fork** is the FIRST step of increment #3, **before** the handshake
  code lands (tracked: **D-244**). The §1-2 / §5-7 spine (threads, alloc-lock,
  STM, agent, conveyance) is unaffected; only §2's collection-safety mechanism
  (the Alt-1-vs-Alt-2 choice) is re-opened. Increments #1 (io_default) + #2
  (global alloc lock) are correct and land regardless (the alloc lock is needed
  by every candidate mechanism). **DECIDED 2026-06-04 — see the D-244 decision
  section below.**

- **2026-06-04 — D-244 DECIDED: Alternative B (alloc-boundary safepoint).** A
  Step-0 survey (`private/notes/D244-gc-safety-survey.md`) + a mandatory DA-fork
  resolved the GC-safety mechanism. Survey verdict: **cw v0 has the same latent
  bug** (its `ThreadRegistry` is a vestigial counter; "safepoint comes in 48.3"
  never landed) — no working mechanism to re-derive; the global alloc lock
  (increment #2) is the one correct, necessary-not-sufficient piece. **Decision =
  Alternative B** (the DA's recommendation, correcting the originally-proposed
  C2a on three points):
  1. **Worker eval runs on the VM backend only** (F-012; `build.zig` already
     defaults to `.vm` since D-196's in-place discharge). `future`/`pmap`/`agent`
     thunks are **force-compiled to a chunk and run via the VM `evalChunkErased`
     vtable slot** regardless of the build's `-Dbackend` (so the tree_walk oracle
     build can still exercise them single-threaded; tree_walk's un-enumerable
     native intermediates never run on a worker). This decouples D-244 from any
     backend-default question — Q2's "tree_walk-default fork" does NOT fire.
  2. **The safe point is the ALLOCATION BOUNDARY, not the bytecode back-edge.**
     Q1 is real and non-empty: `op_vector_literal`/`op_map_literal`/`op_set_literal`
     + `callMethodImpl`'s rest-list cons-wrap loop hold a fresh accumulator in a
     Zig local *across the next allocation*, un-installed on any operand slot — a
     back-edge poll (C2a) does NOT cover this intra-`stepOnce` window. A thread
     parks at *its own* `alloc` entry (where its live Values are installed on
     published frames); the collecting thread **self-guards its own in-flight
     allocation partial** (a single, enumerable, self-scoped spot — NOT a
     guard-list discipline at every fabrication site, which would be an F-011
     hazard). A **liveness-only** back-edge poll survives (re-scoped from
     correctness to: park a non-allocating loop + quiesce the binding-frame chain
     for Q3), costing the same single branch C2a would.
  3. **Publication is a per-thread CHAIN of operand-stack frames, not one stack.**
     `vm.eval` recurses (`op_call → callFn → callMethodImpl → eval`), each
     invocation a fresh `stack`/`locals` Zig-local array; a `ThreadGcContext` must
     register each `eval` frame on entry / pop on return, plus the thread's
     binding-frame head. `collect()` walks the union of all threads' frame chains
     + binding-frame heads + ns_vars + macro_root_slot + permanent_roots.
  Q3 (the `pushFrame`/`popFrame` race) is closed by the STW-at-safepoint: parked
  workers don't mutate the chain during the walk; the collector reads each
  thread's `current_frame` head with the park/broadcast as the acquire fence.
  **No F-NNN amendment needed** — the F-006 envelope (coordination-point STW,
  precise roots by owning the operand-stack representation, no write barrier) is
  exactly expressive enough; B forecloses concurrent/incremental mark without a
  write barrier, which F-006 already defers to §89.2. **Alternative C**
  (arena-isolated data-parallel workers with copy-out) is REJECTED for the spine
  (shared-mutable `atom`/`agent`/`ref` identity → F-011 divergence on
  `(let [a (atom 0)] @(future (swap! a inc)) @a)`) but retained as a future
  detected-pure `pmap` fan-out optimization (Phase 15+/zwasm async). The #3
  implementation (the safepoint machinery + per-frame `ThreadGcContext` chain +
  force-VM worker thunks + the collecting-thread self-guard) now proceeds from
  this decision; D-244's barrier is the implementation checklist.

### Alternatives considered (D-244 decision, DA-fork fresh-context, verbatim)

Briefed with F-006 (single-gen mark-sweep, no write barrier, generational/
concurrent GC OUT → §89.2), F-011 §2, F-012 (VM = production since D-196 discharge;
tree_walk = single-threaded oracle). Grounded in `vm.zig` (`eval`/`stepOnce`),
`tree_walk.zig` `callMethodImpl`, `gc_heap.zig` (alloc lock landed), `root_set.zig`,
D-244/D-196.

**Leading finding:** C2a's published-root model is structurally under-specified —
a worker holds a CHAIN of operand-stack frames (`vm.eval` recurses via
`op_call → callFn → callMethodImpl → eval`, each a fresh Zig-local `stack`/`locals`),
not one; every C2 variant must publish a per-thread *stack of frames*. No
finished-form-clean option requires violating an F-NNN.

**Alternative A — smallest-diff: alloc-point-only collection, no poll (C2b), per-frame publication.** Collection fires only inside `alloc` (lock held); each `eval` frame registers on a per-thread list; no `gc_requested` flag/poll/parking.
- Better: zero hot-loop tax; reuses the landed lock; cleanest for non-allocating leaf loops; closest to ADR-0090 §2's original intent.
- Breaks: **Q1 is fatal.** `op_vector_literal`/`op_map_literal`/`op_set_literal` build via a `conj`/`assoc` loop holding the partial accumulator in a Zig local across the next alloc; `callMethodImpl`'s rest-list cons-wrap loop likewise. A collect triggered by the next iteration's alloc sweeps the un-published partial → UAF. Only fixable by a guard-list discipline at every fabrication site — uncheckable, an F-011 hazard. Q3's `op_pop_binding_frame` (non-allocating chain edit) also races a concurrent walk with no coordination point.
- F-NNN: F-006 ✓; F-011 ⚠ (correct only if guard discipline complete — silent UAF otherwise); F-012 ✓✓.

**Alternative B — finished-form-clean: alloc-boundary safepoint + per-frame publication (RECOMMENDED).** The collection point is the allocation slow path made a true safe point: a thread crossing the threshold sets `gc_requested`, waits for every other thread to reach a safe point (alloc entry, or a liveness back-edge poll), walks the union of frame chains + binding heads, marks, sweeps, broadcasts. The safe point is *before* the fabricating allocation, so at it every live Value is installed on a published frame — Q1's window closed by construction; the collecting thread self-guards its own current partial.
- Better than C2a/A: closes Q1 correctly (C2a's back-edge poll misses the intra-`stepOnce` accumulator window — a worker 50 iterations into `(into [] (range 1e7))` holds an un-published partial between back-edges); no fragile per-site guard discipline (the obligation moves to "every unbounded non-allocating loop must poll" — a small enumerable set: VM dispatch + `recur`).
- Costs: **liveness** — a non-allocating loop never hits the alloc poll, so ONE back-edge liveness poll is still needed (rare-taken relaxed-atomic load + predicted-not-taken branch); a long native primitive bounds time-to-safepoint (HotSpot-like, acceptable). More upfront design (frame registry + handshake).
- F-NNN: F-006 ✓✓ (safepoint+publication is coordination; single-gen; no write barrier — mutation-under-sweep safe because fully STW-at-safepoint, never concurrent mark); F-011 ✓✓ (correct by construction); F-012 ✓✓ (one back-edge poll is VM-only; tree_walk never runs on a worker).

**Alternative C — wildcard: single-threaded heap + arena-isolated data-parallel workers with copy-out.** Workers run against a per-worker arena (no shared-heap alloc, no lock, no collection); result copied/realized back on the owning thread. Shared GC heap stays literally single-threaded → `collect()` unchanged, zero GC changes.
- Better: GC byte-identical to single-threaded; real parallelism for pure computation; sidesteps tree_walk-native-stack entirely; friendly to zwasm-v2 linear-memory instances.
- Breaks (disqualifying for the spine): Clojure `future`/`agent` bodies share mutable references — `(let [a (atom 0)] @(future (swap! a inc)) @a)` must observe `1`, but an arena worker swaps its *copy*; deep-copy breaks `identical?`. Preserving these means reaching into the shared heap = back to needing B's safepoint. So C only works for a pure subset → F-011 violation for the general contract. Conflicts with §6 binding conveyance (conveyed frame references shared Vars).
- F-NNN: F-006 ✓✓✓ (GC unchanged); F-011 ✗ for the general contract (disqualifying); F-012 ✓.
- Verdict: rejected for the Phase-B spine; retained as a future detected-pure `pmap` fan-out optimization (Phase 15+/zwasm async).

**Q1 (fresh-uninstalled-local window):** YES, real, non-empty — vector/map/set-literal accumulator loops + the rest-list cons-wrap loop hold a fresh partial in a Zig local across the next alloc, NOT on any `stack[0..sp]` slot. The back-edge poll does NOT close it (the window is between back-edges, inside `stepOnce`); the **allocation boundary** is the safe point; the collecting thread self-guards its own current partial (a single self-scoped spot, not a per-site discipline).

**Q2 (enforce VM-only workers):** the survey's "tree_walk-default" premise is **STALE** — D-196 is discharged and `build.zig` already reads `orelse .vm` (line 37). Force-compile worker thunks to a chunk and run via the VM `evalChunkErased` slot (already wired) regardless of `-Dbackend`, so the invariant is runtime-enforced independent of the build flag; the oracle build can still exercise `future` single-threaded. The "tree_walk workers → C1/C3 fork" never fires.

**Q3 (pushFrame/popFrame race):** closed under B's STW-at-safepoint (parked workers don't mutate the chain during the walk; `op_pop_binding_frame`'s unlink+destroy is the thread's own, post-resume, on a frame the collector already saw as unreachable). The collector reads each thread's `current_frame` head with the park/broadcast as the acquire fence. NOT closed under a pollless model (mid-`popFrame` torn read) — confirming D-244's "this alone may force a coordination point."

**Recommendation: Alternative B**, force-VM workers (Q2), per-frame chain publication, alloc-boundary safe point + liveness-only back-edge poll, collecting-thread self-guard. C2a corrected on the three points above. No F-NNN amendment required.
