# ADR-0153 — `future-cancel` via cooperative cancellation at the worker safepoint

- **Status**: Proposed → Accepted (2026-06-16)
- **Context drivers**: D-442 (gap area I — Concurrency, F-015) — `future-cancel` /
  `future-cancelled?` are NOT-YET-IMPLEMENTED.

## Context

cljw futures run a thunk on a DETACHED `std.Thread` (future.zig `worker`), with
no interrupt/cancel mechanism. clj's `(future-cancel f)` = `Future.cancel(true)`:
returns true if cancelled (task pending/running — interrupts the thread), false
if already done; `(future-cancelled? f)` → cancelled?; `(deref <cancelled>)` →
`CancellationException`. cljw cannot OS-interrupt a detached thread.

Key fact (from the DA fork): **JVM interruption is itself best-effort** — a tight
CPU-loop thunk (`(future (loop [] (recur)))`) is NOT interrupted on the JVM
either (interrupt fires only at blocking points — `sleep`/`wait`/`park`/
interruptible I/O — or explicit `Thread.interrupted()` checks). So faithful
parity does NOT require aborting arbitrary running code — only cooperatively
aborting at blocking points, exactly as the JVM does.

## Decision

Implement cooperative cancellation reusing the existing worker substrate (the
`ThreadGcContext` + GC safepoint each worker already registers/parks at):

1. **Per-Future `cancel_requested: atomic bool`.** `future-cancel`: under
   `cell.mutex`, if state is `.pending` → set `cancel_requested` + (for a not-yet-
   started/blocked worker) the cooperative check aborts it; return **true**; else
   (`.realised_*`/`.cancelled`) return **false**. (`.pending` covers "running"
   since cljw stays `.pending` until the worker stores — so a running future
   correctly returns true, matching clj.)
2. **Cooperative check at BLOCKING PRIMITIVES ONLY** (`Thread/sleep`, a nested
   future `deref`, promise wait) — **NOT** the per-op GC safepoint (vm.zig:277).
   *(Amended 2026-06-16, pre-implementation: the original draft said "at the GC
   safepoint + blocking primitives, not every back-edge" — but the GC safepoint
   IS the per-op back-edge poll, so checking the cancel flag there WOULD be every
   back-edge and would over-interrupt a tight CPU loop. To match the JVM's
   best-effort semantics — a blocking thunk aborts; a tight CPU loop runs on, as
   on the JVM where interrupt only fires at blocking points — the check lives at
   the blocking primitives, leaving the per-op eval loop untouched. This also
   keeps the change OFF the load-bearing eval loop.)* A worker in a tight CPU loop
   is marked `.cancelled` (future-cancel returns true, future-cancelled? true) but
   runs to completion — exactly as a JVM `cancel(true)` on a non-interruptible loop
   (interrupt flag set, loop runs on).
3. The cooperative check raises a **distinct cancellation signal** up the
   worker's eval stack; the worker's existing catch (future.zig:131-141) marshals
   it via `worker_error.capture`. deref re-raises it through the existing
   `worker_error.reraise` channel as a **`CancellationException`-classed** value
   (add the class to host_class.zig under RuntimeException/Exception) — NOT the
   stale `future_thunk_failed` placeholder. The signal must be distinctly typed /
   uncatchable so a `(try … (catch Throwable …))` in the thunk does not swallow it.
4. **`FutureState += .cancelled`** for the terminal state + `future-cancelled?`.
   The worker's store (future.zig:144-148) is **guarded `if (state == .pending)`**
   so a canceller that won the mutex first is not clobbered (the mark-cancelled-
   wins ordering; both serialize on `cell.mutex`).

No AD is needed: cljw's cancellation now matches clj's best-effort semantics
(blocking thunks abort, CPU loops do not), and the thread + GC pin release
promptly on a blocking-point cancel.

## Defects in the naive "mark-only" design this ADR fixes (DA fork)

- **Worker-store race**: the current unconditional worker store would clobber a
  `.cancelled` set by a canceller — must guard on `state == .pending` (point 4).
- **Pin/thread persistence**: a naive mark-only (no cooperative abort) leaves the
  worker thread + GC pin alive until the thunk completes (a 10s `sleep` stays
  pinned 10s). Cooperative abort at blocking points releases promptly.

## Alternatives considered (Devil's-advocate fork, fresh context — digest)

- **Alt 1 — smallest-diff: mark-only (no cooperative abort) + a single AD.**
  `future-cancel` marks `.cancelled`; the thunk runs to completion, result
  discarded; deref raises. REQUIRES the worker-store guard (defect 1) + an AD for
  the residual (thread+pin persist; blocking thunks not aborted = a real
  divergence since clj WOULD abort a sleeping thunk). Acceptable as a fallback,
  but per F-002 "B is more work" is not a reason to prefer it.
- **Alt 2 — finished-form (CHOSEN): cooperative cancel at the worker's existing
  safepoint + blocking points only.** Real cancellation of blocking thunks,
  prompt pin/thread release, best-effort semantics matching the JVM (tight loop
  not interrupted) → **no AD**. Reuses the existing safepoint/ThreadGcContext/
  worker_error substrate. Risk: touches the worker eval path + an atomic flag the
  safepoint reads; the cancellation signal must be un-swallowable.
- **Alt 3 — wildcard: model cancellation as a delivered CancellationException via
  the existing `realised_error` path** (+ a `cancelled` bool for
  `future-cancelled?`), reusing the ADR-0120 marshalled-exception channel with
  zero new deref branch. A representation optimization on Alt 1 (still no abort →
  still needs the AD); its plus is a real `CancellationException` class for free
  and `future-done?` → true for a cancelled task (matches clj `isDone`). Folded
  into Alt 2's error-class choice (point 3).

The DA's recommendation was **Alt 2** (finished-form, no AD); cycle size is not a
project constraint (F-002). Alt 1 is the fallback only on a real F-NNN block
(none found).

## Consequences

- `future-cancel`/`future-cancelled?` land; deref of a cancelled future throws a
  `CancellationException`-classed error (catchable, distinct from
  `future_thunk_failed`).
- The stale `future_thunk_failed` placeholder Kind is NOT reused for cancellation.
- Testability: semi-non-deterministic — a `Thread/sleep`-bearing future gives a
  deterministic cancel window (spawn slow future → future-cancel → assert
  future-cancelled? + deref throws + the thread/pin released). No tight-race
  (no-sleep) test in the gate.

## Affected files (implementation plan)

- `src/runtime/future.zig` — `cancel_requested` flag + `.cancelled` state +
  guarded worker store (`if state == .pending`) + `cancel` fn.
- the BLOCKING primitives (`Thread/sleep`'s sleep loop; nested-future `deref` /
  promise wait cond loops) — read the worker's `cancel_requested` + raise the
  cancellation signal. (NOT the per-op GC safepoint — see Decision point 2 amend.)
- `src/lang/primitive/stm.zig` — `future-cancel`/`future-cancelled?` primitives +
  deref's cancellation re-raise.
- `src/runtime/error/host_class.zig` + `error/catalog.zig` — `CancellationException`
  class + the cancellation Code/Kind.
- tests — a `Thread/sleep`-based e2e (cancel a slow future).
