# ADR-0120 — Cross-thread error fidelity (uniform worker-error marshalling)

- **Status**: Proposed → Accepted (2026-06-08)
- **Resolves**: D-335 (user-directed: uniform cross-thread error discipline,
  not just the trace) + D-330 (future trace lost at the boundary). Composes with
  ADR-0119 / AD-024 (the user-frame trace discipline).
- **Feeds**: D-115 (the Value-carried exception channel) — this is its resolution.

## Context — a real, verified gap (user-flagged 2026-06-08)

cljw spawns REAL OS threads: `future` (future.zig:103 `std.Thread.spawn`),
`agent` drainers (agent.zig:153/304), Phase-B `pmap`/workers. When a worker runs
user code that throws, the worker catches the Zig error and the FULL error —
kind / message / location / trace / ex-data — lives in THREADLOCAL state
(`info.zig` `last_error` + `msg_buf` + `trace_snapshot`) that DIES with the
thread. The consuming thread gets a degraded placeholder:

- **future**: `stm.zig:58` raises a generic `future_thunk_failed` — loses
  everything, even the message. `@(future (/ 1 0))` shows `future_thunk_failed`,
  not `Arithmetic error: Divide by zero at <file>:<line>` + `Trace:`.
- **agent**: `agent.zig:247 captureThrown` converts to an `ex_info` Value — but
  hardcodes the class `"clojure.lang.ExceptionInfo"` (a WRONG-CLASS bug: a
  marshalled `(/ 1 0)` reports `ExceptionInfo`, not `ArithmeticException`, so
  `(catch ArithmeticException …)` around the read fails to match) AND loses
  location + trace.

The user directive: full error FIDELITY across the boundary (not just the
trace), via ONE uniform discipline for future/agent/pmap — not ad-hoc per
construct.

### The fidelity ceiling is in the RENDERER, not the marshal

`error_render.zig:86 buildThrownInfo` is the only path that turns a thrown Value
back into an `Info`, and it recovers ONLY `message` + `data` — `location` stays
`.{}` (→ "unknown"), `trace` stays `null`. So ANY approach routed through the
thrown-Value channel inherits this ceiling unless `ExInfo` is widened. (This is
also a LATENT in-thread gap: `(throw (ex-info "x" {}))` already renders with
`location = "unknown"` today.)

## Decision

Adopt the Devil's-advocate's finished-form synthesis: **the cross-thread carrier
IS a location+trace-extended `ExInfo`, not a parallel type.** One exception
representation that is simultaneously user-catchable (ex-data intact),
GC-rooted/traced (rides the existing `Future.cached` / `Agent.error_val` / pmap
slot), and fully renderable (location + trace).

1. **Widen `ExInfo`** (ex_info.zig) with `origin_loc: SourceLocation` (file bytes
   GC-owned like `message`) and `trace: ?[]StackFrame` (frames deep-copied,
   frame strings GC-owned). Populate at synthesis: `allocException` /
   `op_throw` / `evalThrow` capture the live `info.location` + `getCallStack()`.
2. **Teach `buildThrownInfo`** (error_render.zig) to read `origin_loc` + `trace`
   into the synthesised `Info` — closing the renderer ceiling for ALL thrown
   values (cross-thread AND the latent in-thread `(throw (ex-info …))` gap).
3. **A neutral `runtime/concurrency/worker_error.zig`** with the uniform pair:
   `capture(rt) Value` (worker-side, at the catch — produces the widened ex_info
   on the worker thread, BEFORE it exits, while `msg_buf`/`trace_snapshot` are
   still valid; the kind-derived class flows through `allocException`, fixing the
   wrong-class bug) and `reraise(v) ClojureWasmError` (consumer-side —
   republishes `dispatch.last_thrown_exception = v` + returns `error.ThrownValue`,
   rendering byte-identically to an in-thread throw).
4. **Wire all three constructs** to the one helper: `future` (the missing one,
   stm.zig deref + future.zig worker), `agent` (replace `captureThrown`, fixing
   its class bug), and pmap when it lands. The carrier rides each construct's
   existing GC-traced slot (no new GC tag).

### Staging (each: lightweight local verify → full gate at the commit)

- **Stage A — widen ExInfo with `origin_loc` (LOCATION) + in-thread fidelity.**
  ex_info gains `origin_file_ptr/len` (GC-owned, duped like `message`) +
  `origin_line`/`origin_column` + GC finalise frees the file; `allocException`
  populates from the live loc; `buildThrownInfo` reads them. Observable in-thread:
  `(throw (ex-info "x" {}))` renders with a real location (closes the latent
  "unknown" gap). **Trace-on-ExInfo is split OUT to a follow-on (D-336):** a
  single `origin_file` string is a bounded extern-struct widening, but a full
  trace is an ARRAY of `StackFrame` each with 3 GC-owned strings on the
  most-allocated heap type — meaningfully heavier than the DA's "same machinery"
  framing implied. Location-first is the finished-form CORE (the user's primary
  ask is kind/message/location fidelity, "not just the trace"); the trace is an
  ADDITIVE enhancement that does not rework the location fields. (Step-0.6
  refinement found at implementation.)
- **Stage B — uniform cross-thread helper.** `worker_error.{capture,reraise}` +
  wire future (deref re-raises the marshalled ex_info instead of
  `future_thunk_failed`) + agent (replace captureThrown, fix the class) + pmap.
  Observable: `@(future (/ 1 0))` and an agent error surface the REAL error +
  trace on the consuming thread. Tests pin the kind (catchable) + message +
  location + trace.

### Landed (2026-06-08)

- **Stage A** (a8b88c35): ExInfo `origin_loc` + `buildThrownInfo` reads it →
  thrown exceptions render their location (closes the latent in-thread gap).
- **Stage B**: neutral `runtime/concurrency/worker_error.{capture,reraise}` +
  wired into `future` (stm.zig deref re-raises the marshalled error;
  future.zig worker captures) and `agent` (captureThrown delegated → the
  hardcoded-ExceptionInfo class bug is fixed). `@(future (/ 1 0))` now renders
  "Divide by zero" + `<stdin>:1:14` + caret and is catchable as
  `ArithmeticException`. `pmap` is sequential (core.clj:415) → no wiring.
  REMAINING: the trace across the boundary (D-336, needs trace-on-ExInfo).

### Scope / deferrals

- **Trace rides v1** (per the user "not just the trace"): the deep-copy machinery
  for location is the same as for trace frames; splitting is the larger total
  diff. The `max_call_depth=64` cap applies as in-thread (best-effort).
- **Perf**: GC-owned trace deep-copy lands on the throw path (hot). Acceptable
  per `optimization_deferred_until_15_libs`; the Phase-15 perf pass may make the
  trace deep-copy LAZY (capture frame pointers + a generation guard, materialise
  on render) — a perf refinement of the SAME shape, not a redesign. PERF/O-NNN
  marker at land.
- **D-329** (per-thread isolation) becomes testable once Stage B makes worker
  errors observable on the consumer.

## Alternatives considered (Devil's-advocate, fresh-context fork — verbatim)

> Three facts the DA surfaced first: (1) the **agent path already does the
> smallest-diff** (`agent.zig:244 captureThrown` → ex_info in `Agent.error_val`)
> — so futures are strictly worse (no message even), and "choose a marshal" understates
> the asymmetry. (2) The **Value channel's fidelity ceiling is in the renderer**
> (`buildThrownInfo` recovers only message+data; location/trace structural) — not
> fixable by careful marshalling, only by widening ExInfo. (3) The **lifetime trap**:
> `setErrorFmt` already snapshots message→`msg_buf` + trace→`trace_snapshot`
> (threadlocal, dies with the worker); the throw path's Value lives on the GC heap
> (survives if rooted) — the two channels have different lifetime stories.

**Alt 1 — smallest-diff: lift `captureThrown` into a shared helper, store an
ex_info in `Future.cached`, re-throw at deref.** Better: minimal surface, reuses
the agent precedent so future+agent become identical; `cached` already GC-traced
+ published under the cell mutex (no new GC/happens-before); the `(throw v)` path
is fully faithful. Breaks: BAKES IN the fidelity ceiling — `@(future (/ 1 0))`
gets the message but location stays "unknown", trace null; AND a WRONG-CLASS bug
(captureThrown hardcodes `"clojure.lang.ExceptionInfo"`, but `(/ 1 0)` synthesises
`"ArithmeticException"` → `(catch ArithmeticException …)` around a deref fails to
match — a real correctness regression, not cosmetic).

**Alt 2 — finished-form: a marshalled-`Info` carrier re-installed EXACTLY on the
consumer.** A GC-managed `MarshalledError` deep-copies the whole `Info`
(message/location.file/every trace frame's strings) out of the threadlocals into
GC storage before the worker exits; consumer `setErrorInfo(info)` re-installs it +
returns `kindToError(info.kind)` → renders byte-identical to an in-thread error,
correct Kind (fixes Alt 1's class bug). Better: the ONLY option meeting the user
requirement (full location + trace + correct kind), genuinely uniform. Breaks:
largest diff (new GC tag + trace/finalise + `setErrorInfo`); and `agent-error`
returns the ex_info Value to USER code, so a `MarshalledError` carrier must ALSO
degrade to a catchable ex_info Value with ex-data — that dual role (faithful-render
carrier AND user-catchable Value) collapses Alt 2 toward "widen ex_info" (Alt 3).

**Alt 3 — wildcard: widen `ExInfo` itself with optional location + trace, so the
ONE exception type carries full fidelity and the thrown-Value channel stops being
lossy.** Add `origin_loc` + `trace` (GC-owned) to ExInfo; populate in
`allocException`/`op_throw`; `buildThrownInfo` reads them → closes the renderer
hole for ALL thrown values. Cross-thread then needs NO special carrier (the
ex_info already carries everything). Better: eliminates the fork — one exception
representation, GC-managed/catchable/renderable; cross-thread becomes trivially
uniform; also fixes the latent in-thread `(throw (ex-info …))` location gap.
Breaks: puts GC-owned trace deep-copy on the HOT throw path (perf, deferred-opt
territory, lazy-materialisation fallback later); enlarges every ex_info (~48→80B
heap, not Value slots, F-004 unaffected); touches the most-allocated heap type
(blast radius beyond future/agent/pmap — a regression regresses all error
rendering); two trace-snapshot sites (allocException + setErrorFmt) to keep in
lockstep.

**Recommendation (non-binding): Alt 2's `capture`/`reraise` helper + home, backed
by Alt 3's widened ExInfo as the carrier** — the carrier IS a location+trace-
extended ExInfo, not a parallel `MarshalledError`. Fixes Alt 1's wrong-class +
missing-location/trace; avoids Alt 2's dual-role awkwardness; one exception type
that is user-catchable + GC-rooted (rides existing slots, no new tag) + fully
renderable, with future/agent/pmap on one helper. NOT downgrading to Alt 1
despite it being the agent precedent — that precedent is the low-fidelity floor
this ADR exists to raise (Cycle-budget-defer smell avoided). Leading F-NNN entry:
the recommendation adds GC-owned trace deep-copy on the hot throw path — no F-NNN
forbids it (F-006 accommodates; F-004 unaffected), but the Phase-15 perf pass must
measure it; lazy-materialisation is the clean fallback (same shape). **Trace rides
v1** (the deep-copy machinery for location is the same as for trace; splitting is
larger total diff + re-opens the lifetime trap twice).

## Consequences

- `@(future (boom))` / agent errors / pmap errors render the REAL error
  (correct kind/message/location/trace) on the consuming thread — closing the
  cross-thread fidelity gap uniformly.
- The latent in-thread `(throw (ex-info …))` location/trace gap closes too.
- `ExInfo` grows two fields + GC trace/finalise for the trace; the throw path
  gains a trace deep-copy (perf-deferred, lazy fallback noted).
- The agent wrong-class bug is fixed (kind-derived class via `allocException`).
- D-330 (future trace) + D-335 (uniform cross-thread) resolved; D-329 (isolation)
  becomes testable.

## Affected files

ex_info.zig (widen + trace/finalise), error_render.zig (buildThrownInfo reads
origin_loc/trace), catalog.zig/info.zig (allocException + the throw path populate),
vm.zig/tree_walk.zig (op_throw/evalThrow stamp), runtime/concurrency/worker_error.zig
(new — capture/reraise), future.zig + stm.zig (future wiring), agent.zig (replace
captureThrown), diff_test.zig + e2e (tests).
