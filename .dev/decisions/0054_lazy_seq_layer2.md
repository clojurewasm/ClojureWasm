# 0054 — lazy-seq Layer-2: wire the producer + convert the eager seq surface to true laziness

**Status**: Accepted (Devil's-advocate fork landed 2026-05-29)
**Date**: 2026-05-29
**Author**: Shota Kudo (drafted with Claude autonomous loop)
**Tags**: structural, lazy-seq, seq-protocol, F-002, F-006, F-009, D-133, phase-6-gap

## Context

cw v1's clojure.core seq surface (`map`/`filter`/`take`/`drop`/`keep`/
`remove` + `concat`/`mapcat`/`range`/`map-indexed`/`keep-indexed`) is
EAGER (returns vectors via `-*-eager` Zig leaves / Pattern-A `.clj`),
diverging from JVM lazy seqs. This is the **last unmet Phase-6
exit criterion** (ROADMAP §9 row 6: `(take 5 (iterate inc 0))` →
`(0 1 2 3 4)`) and the D-133 coverage-floor item "seqs eager not lazy".

Survey (`private/notes/lazy-seq-layer2-survey.md`): the lazy_seq
**CONSUMER** half is complete + unit-tested (`runtime/lazy_seq.zig`
force/first/rest/next/seq + GC trace + root category; the seq-protocol
`.lazy_seq` arms in `sequence.zig` are already wired), but the
**PRODUCER** half has **zero callers** — no `lazy-seq` macro, no
`__lazy-seq-create` primitive, and `iterate` does not exist.
`delay`/`future` are the proven producer triad (macro →
`(__X-create (fn* [] body))` → primitive → `mod.alloc(rt, thunk)`).

DA fork surfaced a load-bearing constraint the survey under-weighted:
**`print.zig::printForm` takes `(w, v)` — NO `rt`/`env`** — so it cannot
`force` a lazy seq; `.lazy_seq` currently falls to `else => "#<lazy_seq>"`.
Rendering a lazy seq requires threading `rt + env` into the print path
(rippling to REPL / `pr-str` / error rendering). This is in-scope for
**cycle 1**, because cycle 1's exit criterion is a *print* of a lazy seq.

## Decision (Alt B — finished-form-clean)

### D1: producer triad (mirror delay/future)

`lazy-seq` macro (reuse the `expandThunkWrapper("__lazy-seq-create", …)`
shape) → `__lazy-seq-create` primitive (`checkArity(1)` →
`lazy_seq.alloc(rt, thunk)`, env discarded like `delayCreateFn`) →
the existing `lazy_seq.alloc`. ~13 LOC total.

### D2: convert the eager surface to lazy `.clj`; delete the `-*-eager` leaves

`map`/`filter`/`take`/`drop`/`keep`/`remove`/`concat`/`mapcat`/
`map-indexed`/`keep-indexed` become recursive lazy-cons `.clj`
(`(def map (fn* [f coll] (lazy-seq (when-let [s (seq coll)] (cons (f (first s)) (map f (rest s)))))))`).
Each `-*-eager` Zig leaf is **deleted in the same cycle that removes its
last caller** (no dead code across cycles; no `PROVISIONAL:` marker —
deletion is atomic with the rewrite). JVM-idiomatic, F-009-thin.

### D3: print path gains `rt`/`env` (cycle 1, load-bearing)

Thread `rt + env` into `printForm` (overload or signature change); add a
`.lazy_seq` arm that forces + walks like `printList`, **bounded** (honour
`*print-length*` / a finite default) so an infinite seq does not hang the
printer. Ripples to REPL / `pr-str` / error rendering — done once, here.

### D4: lazy `=` (cycle 3)

`equal.zig`'s sequential arm (`isSequential` = vector|list today) extends
to force-and-walk `.lazy_seq` (symmetric `rt/env` threading), landing
with the first `(= <lazy> <literal>)` assertion. Genuine dependency at
first-use, not deferrable polish.

### D5: chunking DEFERRED (separation of concern, not cycle-budget)

Unchunked per-element lazy-cons is the correct **semantic** finished
form. JVM's 32-element chunking is an orthogonal **perf** axis (the
`chunked_cons` module exists, dormant). Chunking is a clean follow-up
perf cycle (Phase-15+/JIT era; D-row) once unchunked lazy is the proven
baseline. Chunking now would couple perf into a correctness ADR + change
the laziness contract (over-realization past a consumer's stop point).

### D6: phasing — one ADR, ~4 cycles, inside the v0.1.0 window

Per D-133/D-134 lazy seqs are the v0.1.0 coverage floor; eager map/filter
is a JVM-divergence lie (F-002). Phase 6 left a known structural gap;
honour it inside the v0.1.0 window (a §9.16 row). Cycles:

1. producer triad + `iterate` + lazy `take` + **print `rt/env` threading**
   → prove `(take 5 (iterate inc 0))` prints `(0 1 2 3 4)`.
2. lazy `map`/`filter`/`keep`/`remove` + delete those 4 leaves + laziness
   oracle `(first (map inc (range))) → 1` (must not hang).
3. lazy `concat`/`mapcat`/`drop` + infinite `range` + **lazy `=`** +
   `(= (take 3 (range)) '(0 1 2))`.
4. `repeat`/`repeatedly`/`cycle`/`take-while`/`drop-while`/`partition`.

### D7: realization-timing de-risk

(i) cycle-2 grep audit for `(map <side-effecting>`-style call sites +
confirm/land `doall`/`dorun`; (ii) the laziness oracle as the eager→lazy
regression gate; (iii) an F-006 GC-pressure stress test (`force` mid
minor-GC) — verification only, the trace is complete (no GC redesign).

## Alternatives considered

Devil's-advocate fork (general-purpose, fresh context, 2026-05-29,
F-002/F-006/F-009/F-004 envelope) output verbatim:

> Critical finding: `print.zig`'s switch falls to `else => |t| w.print("#<{s}>", .{@tagName(t)})` for `.lazy_seq` — so a lazy seq today would print `#<lazy_seq>`, not `(0 1 2 3 4)`. And crucially, **`print` takes only `(w, v)` — no `rt`, no `env`** — so it cannot call `force`/`seqFn` (which require `rt, env`). This is a load-bearing signature problem, not just a missing arm.

### Leading finding: no F-NNN block, but one cross-cutting signature constraint

There is **no** finished-form-clean option that requires violating an F-NNN. The producer triad + lazy `.clj` rewrite is fully expressible within F-002/F-006/F-009/F-004. **However**, code reading surfaced a constraint the survey under-weighted that reshapes the phasing of all three alternatives:

- **`print.zig::printForm` takes `(w: *Writer, v)` — NO `rt`, NO `env`.** Its switch routes `.list => printList`; `.lazy_seq` falls into `else => w.print("#<{s}>", .{@tagName(t)})`. So the first lazy value ever produced prints `#<lazy_seq>`. Forcing a lazy seq for printing **requires threading `rt + env` into the print path** (to call `force`/`seqFn`, which are `(rt, env, v)`). This is not a one-arm addition — it is a print-API signature change rippling to every `printForm` caller (REPL, `pr-str`, error rendering). The survey called lazy-print "a probable hidden sub-task"; reading confirms it is **load-bearing and must land in the same cycle as the producer**, because `(take 5 (iterate inc 0))` at the REPL is exactly a print-of-lazy. This is a **genuine dependency**, not a cycle-budget defer.
- Symmetric but lower-severity: `equal.zig` explicitly defers `.lazy_seq` from `isSequential` (vector or list only). It likewise would need `rt + env` to force-and-walk. But `=` on a lazy result is not on cycle-1's critical path, so this is a real defer to the cycle that introduces the first `(= <lazy> <literal>)` assertion.

### Alternative A — Smallest-diff: lazy producers only, keep eager surface

(a) Land only the producer triad + the inherently-infinite cluster (`iterate`/`repeat`/`repeatedly`/`cycle`/infinite `range`) as new lazy `.clj`. **Leave `map`/`filter`/`take`/`drop`/`keep`/`remove`/`concat`/`mapcat` eager.** Thread `rt/env` into print only enough to render the new lazy values. `take`/`take-while`/etc. get lazy `.clj` defns so they compose with infinite producers; eager `map`/`filter` stay.

(b) Better. Smallest diff; zero `-*-eager` deletion; no project-wide side-effect-timing change. Honours the never-met Phase-6 exit criterion immediately. Lowest GC-pressure surface.

(c) Breaks/risks. **Ships the divergence-lie F-002 names as the thing to fix.** `(map inc coll)` stays eager → `(first (map inc (range)))` **HANGS** (eager `-map-eager` walks the infinite range forever). A runtime that *looks* lazy but whose most-used seq fns silently aren't. Two-headed seq surface (`map` eager, `take-while` lazy) the finished-form owner unifies later anyway → eager leaves become dead code on a known schedule. Per F-002 the finished form is lazy; A is the smallest-diff-bias path. Reject unless an F-NNN blocked the rewrite — none does.

### Alternative B — Finished-form-clean: producer triad + full eager-surface rewrite, unchunked, print/equal rt-env threaded (recommended)

(a) Producer triad (reuse `expandThunkWrapper` ~5 LOC + `__lazy-seq-create` mirroring `delayCreateFn` ~8 LOC). Print path: thread `rt + env` into `printForm`, add `.lazy_seq` force+walk arm, **bound infinite print** via `*print-length*`. Eager→lazy `.clj` rewrite of map/filter/take/drop/keep/remove/concat/mapcat/map-indexed/keep-indexed; **delete the `-*-eager` leaves + LEAF_ENTRIES** with their last caller. Infinite/lazy cluster (`iterate`/`repeat`/`repeatedly`/`cycle`/infinite `range`/`take-while`/`drop-while`/`partition`) as lazy `.clj`; re-unify finite `range` lazy, retiring eager `-range-acc`. Equal path: extend `isSequential` + cursor to force-walk `.lazy_seq` when the first lazy-to-literal comparison lands. Chunking deferred (D-row). Side-effect-timing audit + `doall`/`dorun`. Phasing: one ADR ~4 cycles, print-`rt/env` folded into cycle 1.

(b) Better. Eliminates the divergence-lie (F-002): every seq fn matches JVM laziness; `(first (map inc (range)))` → `1`. No two-headed surface, no scheduled dead code. Producer JVM-idiomatic `.clj`, Zig surface thin (F-009). Reuses the proven delay/future triad (low mechanism risk). Print/equal threading done once, correctly. Matches the survey depth-3 reading + D-134's "dedicated cycle".

(c) Breaks/risks. Largest diff (print-API signature ripple to every `printForm` caller — but per F-002 diff size is not a constraint). Side-effect-timing flips project-wide: any `.clj`/test relying on eager `map` side-effects breaks (a *correctness fix*, mitigated by the cycle-2 grep audit + `doall`/`dorun`). GC-pressure under `force`-mid-minor-GC is the F-006 watch item — prudent stress test, **not** a redesign (trace complete). Recursive lazy `map` self-ref `fn*` confirmed working (D-070 discharged).

### Alternative C — Wildcard: jump straight to chunked lazy seqs

(a) Skip the unchunked intermediate; `range`/vector-seq/`map`/`filter` produce 32-element `.chunked_cons` batches from day one (the tags + module exist, self-tested only). chunk-first/chunk-rest/chunk-cons protocol arms land alongside.

(b) Better. Matches JVM's *actual* finished form (chunked); avoids a later unchunked→chunked migration; exercises the dormant `.chunked_cons` machinery; best throughput.

(c) Breaks/risks. **Chunking is a perf optimisation orthogonal to the correctness/laziness semantics this ADR is about.** Massively enlarges cycle-1 surface (chunk buffer protocol, partial-chunk realization, chunk-boundary first/rest); interaction with infinite seqs where a 32-chunk *over-realizes* past a consumer's stop — a subtle semantic hazard (`(first (map inc (range)))` realizes 32, fine for pure fns but **wrong for side-effecting** ones, changing the laziness contract). Couples a perf decision into a correctness ADR; "each skeleton must shrink the final-form rewrite" — building chunking before unchunked semantics are proven is premature. Survey §5d + D-134 defer chunking to a Phase-15+/perf cycle. Reject for this ADR; chunking is a clean follow-up once unchunked is the proven baseline.

### Non-binding recommendation — Alt B

F-002 decides A vs B: eager map/filter is the divergence-lie; "keep eager, rewrite later" is the Cycle-budget defer smell, and no F-NNN forces A. Take the surgery: B. B vs C is finished-form-vs-premature-optimization: C is more finished-form in perf but couples an orthogonal perf concern + changes the laziness contract (over-realization); the semantic finished form is unchunked lazy-cons, chunking a separable perf cycle → defer C (genuine separation-of-concern defer, not budget). Axes: (1) lazy `.clj` + delete leaves; (2) chunking deferred; (3) one ADR ~4 cycles, print-`rt/env` in cycle 1, Phase-14/v0.1.0 window; (3b) delete each leaf with its last caller, no `PROVISIONAL:`; (4) lazy print cycle-1 (signature change, bound via `*print-length*`), lazy `=` cycle-3; (5) de-risk via grep audit + `doall`/`dorun` + laziness oracle + F-006 GC stress (verification, not redesign).

## Selection rationale

Alt B. The producer half is the only missing piece (consumer + GC +
seq-protocol arms already complete from Phase 6), so wiring it + the
lazy `.clj` rewrite reaches the JVM-laziness finished form F-002 demands
without an F-NNN block. The print-`rt/env` threading is a genuine cycle-1
dependency (cycle-1 exit is a print-of-lazy), not budget. Chunking (D5)
and lazy-`=` (D4, cycle 3) are separation-of-concern / first-use
dependencies, not cycle-budget defers. A ships the divergence-lie; C
prematurely couples perf chunking into a correctness ADR.

## Consequences

- New: `lazy-seq` macro + `__lazy-seq-create` primitive; `iterate` +
  the lazy cluster as lazy `.clj`; lazy `map`/`filter`/… replace the
  eager surface; `-*-eager` leaves deleted.
- `print.zig` gains `rt`/`env` (signature ripple to REPL/`pr-str`/error
  render); `.lazy_seq` arm bounded by `*print-length*`.
- `equal.zig` sequential arm extends to `.lazy_seq` (cycle 3).
- Deferred: chunking (perf cycle, D-row); `doall`/`dorun` if absent
  (cycle 2 prerequisite).
- Watch: F-006 GC-pressure under realization (stress test, not redesign);
  side-effect-timing flip (cycle-2 audit).
- Unblocks D-134 lazy cluster (infinite range/iterate/repeat/cycle/
  take-while/drop-while/partition).
- v0.1.0-window §9.16 row opened for this (multi-cycle).

## Affected files

- `src/lang/macro_transforms.zig` (`lazy-seq`) · `src/lang/primitive/*`
  (`__lazy-seq-create`; delete `-*-eager` leaves) ·
  `src/lang/clj/clojure/core.clj` (lazy rewrites + cluster) ·
  `src/runtime/print.zig` (rt/env + `.lazy_seq` arm) ·
  `src/runtime/equal.zig` (cycle 3) · `test/e2e/phase14_lazy_seq*.sh` ·
  `.dev/ROADMAP.md` §9.16 (new row) · `.dev/debt.md` (chunking D-row).

## Revision history

- 2026-05-29 issued + accepted with Devil's-advocate fork
  (general-purpose, fresh context, F-002/F-006/F-009/F-004 envelope, 3
  alternatives verbatim, Alt B selected). Wires the Phase-6 lazy_seq
  producer gap; converts the eager seq surface to true laziness across
  ~4 cycles inside the v0.1.0 window. Print-`rt/env` threading identified
  as a load-bearing cycle-1 dependency.
