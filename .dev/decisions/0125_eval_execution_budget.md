# ADR-0125 — In-process eval execution budget (deadline + step ceiling), uncatchable on expiry

- Status: Proposed → Accepted
- Date: 2026-06-09
- Discharges (in part): D-351 (native in-process eval deadline / step budget,
  isolation dim (a)). Sibling: D-352 (heap cap, dim (b)), D-355 (playground
  drops babashka), D-354 (crash isolation — out of scope here).

## Context

cljw has NO eval timeout: an infinite loop in evaluated code hangs the
process. The `$MY/playground-v2` demo therefore wraps every eval in a
babashka supervisor that spawns a sandboxed child `cljw -e` bounded by OS
`timeout` / `ulimit`. The mission goal (drop babashka, run the playground
on cljw itself) needs an **in-process** time + step bound so untrusted code
can be evaluated without an external supervisor.

zwasm v2 is the cited template: `Module.Budget = union(enum){ unmetered,
limited: u64 }` charged in the dispatch hot loop (`src/interp/dispatch.zig`),
exhaustion surfacing as `Trap.Interrupted` / `Trap.OutOfFuel` that unwind
the interpreter past any guest handler — never a host panic.

cljw already has the cheap-poll site to ride: the VM back-edge safe point
(`vm.zig:127`, one predicted-not-taken atomic load) and the TreeWalk loop
back-edges (`tree_walk.zig:910` eval-loop, `tree_walk.zig:1280` fn-tail
recur). It also already has an **uncatchable-error** mechanism:
`host_class.kindToHostClass(kind)` returns null for `internal_error` /
`out_of_memory` / `not_implemented`, so those propagate past every `catch`
to the top-level CLI handler (`tree_walk.zig:968`).

## Decision

1. **New file** `src/runtime/concurrency/eval_budget.zig` (sibling to
   `safepoint.zig`; A2 new-feature-new-file, A6 ≤1000 lines) defining:

   ```
   EvalBudget = struct {
       step_ceiling: ?u64,     // max back-edge crossings; null = no step bound
       deadline_ns: ?i128,     // monotonic deadline (clock.nanoTime); null = no time bound
       steps: u64 = 0,         // running counter
       // tick(io) -> ClojureWasmError!void : ++steps; if past ceiling -> raise;
       //   every 1024th step read clock, if past deadline -> raise (throttled).
   }
   ```

2. **`Runtime.eval_budget: ?EvalBudget = null`** — mirrors `fs_jail_root`
   (null = unmetered; F-006 the budget reads `rt.io` for the clock, never a
   global). One optional-unwrap at each poll site → ~zero cost when unmetered
   (P3 core stable; F-013 single-binary cold-start untouched), matching the
   existing single `gc_requested` load.

3. **Two axes, both shipped** (P4 no ad-hoc patch): a wall-clock **deadline**
   (the real playground bound) AND a **step ceiling** (the deterministic,
   dual-backend-testable bound). The clock read is throttled (every 1024
   steps) so the per-step cost stays a counter increment + compare.

4. **Checks ride all three existing back-edge poll sites** — `vm.zig:127`,
   `tree_walk.zig:910`, `tree_walk.zig:1280` — so a non-allocating infinite
   loop is caught under BOTH backends (F-011 behavioural equivalence; the
   step unit is "one back-edge crossing", uniform across backends). The
   introducing commit lands all three sites + the test together (ADR-0036).

5. **Expiry is UNCATCHABLE.** A new `Kind` (`resource_exhausted`) is added
   that `kindToHostClass` does NOT map (returns null), so the budget error
   propagates past any `(try … (catch …))` to the top-level handler — exactly
   like `out_of_memory` and exactly like zwasm's trap unwinding past a guest
   handler. This is the correction to D-351's "catchable" wording: a catchable
   budget error lets untrusted code `(try <infinite> (catch Throwable _ :ok))`
   swallow the timeout, so the playground could never reliably report it.
   New Codes: `eval_deadline_exceeded`, `eval_steps_exceeded` (catalog
   templates, no Phase/ADR/path leakage per error_catalog_only).

6. **Arming surfaces** (complementary, both finished-form):
   - **CLI env var** (this cycle): `CLJW_EVAL_MAX_STEPS` + `CLJW_EVAL_DEADLINE_MS`,
     mirroring `CLJW_FS_ROOT`, armed in `runner.zig` next to `rt.fs_jail_root`.
     A whole-run bound; e2e-testable.
   - **Clojure programmatic** (D-355 cycle): a `cljw.eval/with-budget` scoped
     form for the playground's per-eval in-process bound. Deferred to the
     cycle that consumes it (F-003); not stubbed now.

7. **Complementary, unchanged**: the existing `MAX_CALL_DEPTH = 512` stack
   guard (`tree_walk.zig:584`) stays — it bounds non-tail deep recursion that
   a back-edge budget does not see.

## Consequences

- An embedder / the playground can bound untrusted eval in-process by time
  and steps, removing the OS-subprocess dependency for the time/step
  dimensions (D-355 unblocks; crash isolation D-354 still needs a process /
  wasm boundary).
- The hot loop gains one optional-unwrap per back-edge when unmetered
  (negligible; same shape as the GC poll).
- A new `Kind` widens the error taxonomy by one; `kindToHostClass` gains one
  null-mapped arm.

## Affected files

- `src/runtime/concurrency/eval_budget.zig` (new)
- `src/runtime/runtime.zig` (`eval_budget` field)
- `src/eval/backend/vm.zig` (poll-site check)
- `src/eval/backend/tree_walk.zig` (two poll-site checks)
- `src/runtime/error/info.zig` (`resource_exhausted` Kind)
- `src/runtime/error/catalog.zig` (two Codes + templates)
- `src/runtime/host_interface.zig` / host_class (null map for the new Kind)
- `src/app/cli.zig` + `src/app/runner.zig` (env-var arming)
- tests: e2e (env budget + infinite loop → uncatchable budget error), unit per backend.

## Main-loop decision after Devil's-advocate

The DA (verbatim below) recommends **Alt 2 (per-eval `ExecBudget` ownership)**
over the draft's ambient-`?EvalBudget`-on-`Runtime`, on the DP4 reset concern:
a long-lived playground server evaluating many snippets in one process has no
clean reset for a single mutable counter on `Runtime`.

The main loop **keeps ambient-on-`Runtime` for D-351**, for reasons the DA's
framing missed, NOT on cycle/diff grounds (that would be the Cycle-budget
defer smell):

1. **The ownership model is owned by D-355 (F-003 deferral).** Whether the
   playground evaluates in-process (many snippets, one `Runtime`) or keeps a
   **fresh `cljw` process per eval** is undecided — and D-354 explicitly argues
   the process boundary stays for *crash* isolation (a Zig panic in untrusted
   code can only be contained by a process / wasm boundary). In the
   process-per-eval shape (the likelier finished form given D-354), each eval is
   a fresh `Runtime` with a whole-run env-var budget — the draft's ambient model
   is then exactly right and per-eval threading is dead weight. Prejudging this
   in D-351 violates F-003.
2. **The DA's DP4 "manual reset" critique assumes the wrong reset mechanism.**
   The in-process case resets by **save/restore scoping**, not by per-call-site
   mutation: the deferred `cljw.eval/with-budget` form saves `rt.eval_budget`,
   installs a fresh one for its dynamic extent, and restores on exit (the same
   shape as a dynamic-var binding). Reset is scoped, not manual — so ambient-on-
   `Runtime` serves the in-process case too, on the same substrate
   `fs_jail_root` already uses (a single shared isolation knob, single-threaded
   eval).
3. **Re-pointing later is local, not a Supersedes chain.** If D-355 picks fully-
   in-process-concurrent eval, the budget reads move from `rt.eval_budget` to a
   frame field at exactly the 3 poll sites + signatures — bounded surgery, owned
   by the cycle that needs it.

The DA's **clearly-correct, architecture-independent fixes are adopted into
cycle 1**:

- **Explicit latch (DP1b)**: `EvalBudget` carries `tripped: bool`; once any axis
  trips, every subsequent `tick` re-raises immediately, so an uncatchable error
  reaching a `(catch …)` body (it cannot, but defensively) gets at most one
  back-edge-free straight-line burst, never a second loop.
- **Uncatchable from Clojure via `kindToHostClass → null`** (as drafted) is kept;
  the **host-observable graceful-report path (DP1a / Alt 2 two-frame split)** is
  recorded as a D-355 concern — when the playground's host frame exists, it can
  catch `error.BudgetExceeded` and report "timed out" without tearing down the
  server. Cycle 1's degenerate host frame is the CLI top-level.
- **Cross-backend step-count divergence (DP2) — documented here, NOT a clj-AD.**
  On reflection the DA's "add an AD-NNN" is the wrong SSOT: `accepted_divergences.yaml`
  classifies **cljw-vs-JVM-clj** divergences, not VM-vs-TreeWalk internal ones. The
  dual-backend differential oracle asserts *equal Value*, and the budget-exceeded
  **outcome is equal** under both backends (both raise `error.ResourceExhausted` /
  Kind `resource_exhausted`) — only the never-asserted internal step count differs,
  so nothing floats in either the clj sweep or the diff oracle. The intent is locked
  by `evaluator.zig`'s `test "ADR-0125: a step budget kills an infinite loop under
  BOTH backends"` (fresh budget per backend → each counts independently to the same
  ceiling and trips), and the rule that budget-expiry is never diff-tested on the
  exact count lives in this ADR. No `AD-NNN` row is minted.

Deferred to follow-ups (noted on D-351's debt row, not stubbed): the **call-
boundary poll site (DP5)** that would close the time-overshoot hole in non-
allocating straight-line bursts, and the **shared-IR deterministic step unit
(Alt 3)** that would make budget-expiry itself diff-testable. Cycle 1 ships the
back-edge sites the debt row scoped; steps is the deterministic unit for unit
tests, the deadline is gate-asserted only via an e2e "killed within a generous
ceiling".

## Alternatives considered

(Devil's-advocate subagent, fresh context, verbatim.)

### Alt 1 — Smallest-diff: steps-only, single uncatchable ceiling on `rt`

Drop the deadline axis from cycle 1 entirely. Ship only `step_ceiling: ?u64` on
`Runtime`, checked at the three back-edges, raising the uncatchable
`resource_exhausted`. No clock read, no `i128`, no 1024-throttle, no `rt.io`
dependency in `tick`. The wall-clock deadline lands in the D-355 cycle that
actually consumes it (the playground), co-located with `with-budget`.

- **Better than the draft:** removes the one axis that is *inherently untestable
  in the gate* (wall-clock firing is load-dependent — see DP3). `tick` becomes a
  pure counter compare with zero F-006 surface. Smallest possible widening of the
  error taxonomy that still kills an infinite loop under both backends.
- **Breaks/costs:** the playground's *real* bound is wall-clock ("your code ran
  > 2 s"), not step count. Steps-only means the operator must hand-pick a step
  number that correlates poorly with time. Defers the feature D-355 was filed for.
  Per F-002 this is the smaller-diff option and is recorded but not recommended.

### Alt 2 — Finished-form-clean: per-eval `*ExecBudget` on the eval/call boundary, host-observable / Clojure-uncatchable trap

Stop modelling the budget as a mutable field on the long-lived `Runtime`. The
playground is a long-lived server evaluating *many* snippets — a single `steps`
counter on `Runtime` is a category error (accumulates across snippets, or every
call site must reset it). Instead: `ExecBudget` is a value owned by ONE eval
invocation, passed as `?*ExecBudget` on `eval(rt, env, locals, expr)` and the VM
frame; `rt` holds only the ambient default (CLI env-var path). Reset = construction.
Keep expiry uncatchable *from Clojure* but make the trap a distinct unwind the
**Zig embedder boundary** catches as a normal `error.BudgetExceeded` return — the
playground's host frame reports "timed out" in-process without tearing down the
server, exactly as zwasm's host gets `Trap.Interrupted` while the guest cannot
catch it. The cljw analogue of zwasm's "host" is the Zig/`with-budget` frame, not
the Clojure `try`.

- **Better than the draft:** solves the reset-semantics hole (DP4); gives the
  embedder the graceful "timed out" path without making it catchable by untrusted
  Clojure; matches the cited zwasm semantics precisely.
- **Breaks/costs:** threads a parameter through the eval/VM dispatch signature;
  the VM carries it on its frame struct; the host-frame catch needs a boundary
  primitive (outermost metered frame converts trap → normal return). Larger diff;
  recommended anyway per F-002, not downgraded on size grounds.

### Alt 3 — Wildcard: deterministic logical-step budget as the only tested bound; wall-clock demoted to explicit AD

Define the step unit as something both backends increment identically — not
"back-edge crossing" (which diverges) but **evaluated analyzer nodes** (shared
IR). Then the step ceiling is contract-tested (a diff_test asserts equal expiry
because the unit is on the shared analyzer IR), and the wall-clock deadline is
shipped but documented as an AD accepted divergence (operational kill-switch,
e2e-only). Additionally ride the alloc prologue / call boundary so straight-line
blow-ups are bounded (DP5).

- **Better than the draft:** repairs the cross-backend step divergence (DP2) and
  the back-edge-only granularity gap (DP5); the only option where a budget
  diff_test is meaningful.
- **Breaks/costs:** requires an op→node charge model the VM lacks today; per-op
  increment is a heavier hot-path touch (F-013 inert-when-unmetered must be
  re-verified across far more sites). Largest diff.

### Per-decision-point analysis

**DP1 — Catchable vs uncatchable.** Uncatchable-*from-Clojure* is correct (a
latched budget lets a `(catch)` body run at most one back-edge-free burst, not an
unbounded second loop — the draft must state the latch explicitly, it currently
doesn't). But "uncatchable" should not mean "propagate to the CLI top-level and
tear down the run". The right analogue of zwasm's host is the Zig/`with-budget`
embedder frame, not the Clojure `try` — zwasm's guest can't catch the trap *and
the host still gets it as a return value*. The draft collapses these, losing the
embedder's graceful-report path. So: both tiers, split by **frame**, not by
soft/hard severity (a soft/hard severity tier reintroduces the swallow-the-timeout
hole for the "soft" tier).

**DP2 — Step non-determinism across backends.** This *does* dent F-011 and the
draft under-states it. A budget-exceeded eval under VM vs TreeWalk produces the
same Kind but at a different step count; the diff harness can cover only
non-expiry. Promote "exact count may differ" to an explicit AD-NNN (it currently
floats, which clj_diff_sweep.md forbids). "Back-edge crossing" is not the right
unit if you want expiry itself diff-tested; a shared-IR unit (Alt 3) is. If you
keep back-edge units, budget tests are necessarily per-backend + e2e only — state
that in the ADR.

**DP3 — Deadline determinism.** A wall-clock deadline is non-reproducible by
design — a property, not a bug, but a gate liability if any test asserts *when* it
fires. Resolution: ship it but never gate on its timing (e2e asserts "infinite
loop dies within a generous ceiling"; unit tests cover only steps). Steps is the
testable proxy; deadline is the operational truth.

**DP4 — Where the budget lives.** The draft's biggest unforced error. `?EvalBudget`
inline on the long-lived `Runtime` has no answer to "how does it reset between the
playground's many snippets". Either every snippet mutates `rt.eval_budget.?.steps
= 0` (reset-discipline bug, racy if concurrent) or the counter accumulates. The
finished-form answer is per-eval ownership (Alt 2): budget constructed per eval,
carried on the frame; `rt` holds only the ambient default. Reset = construction.

**DP5 — Granularity gap.** Back-edge-only polling misses straight-line blow-ups
(giant `(str …)`, large literal build, non-looping realization with no recur).
Leaning entirely on D-352 is fine for *memory* runaway, false for *time* runaway
in non-allocating straight-line code: a burst with no back-edge can overshoot the
deadline arbitrarily. The step check should also ride the **call boundary** (every
fn invocation — cheap, frequent, backend-shared) to close most of the gap without
full alloc-prologue coupling.

### DA recommendation

Alt 2 (per-eval budget + host-observable/Clojure-uncatchable trap), amended with
Alt 3's two correctness fixes (call-boundary poll site; AD-NNN for the step
divergence). Keep both axes (steps deterministic-tested, deadline operational-only).
Do not adopt Alt 1 (dropping the deadline defeats the mission need). The draft as
written is shippable for the whole-run CLI env-var case but has a latent DP4 reset
bug the D-355 playground cycle hits on its second eval.

*(Main-loop disposition of this recommendation is in the "Main-loop decision"
section above: ambient-on-`Runtime` is retained for D-351 because the ownership
model is D-355's F-003-owned structural choice and save/restore scoping serves the
in-process case; the latch + AD-NNN fixes are adopted now; call-boundary + shared-
IR unit are deferred follow-ups noted on D-351.)*
