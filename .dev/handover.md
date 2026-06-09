# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (the host-interface convergence substrate below; per-commit
  smoke gate, full gate batched per the user's cadence — run `bash test/run_all.sh`
  before the next handover if 5 smoke commits have accrued).
- **First on resume MUST be (autonomous, F-010 quality loop)**: **D-373** — the
  ordered.map next blocker, root-caused: `instance?` is a cljw MACRO (auto-quotes its
  class symbol), so it CANNOT be passed as a higher-order fn — `(condp instance? obj
  Map$Entry …)` (ordered.map cons) evaluates `instance?` to nil → "Cannot call value of
  type nil". ALL direct `(instance? Class x)` work; the gap is HIGHER-ORDER instance?
  (condp/map/apply). A class/instance? VALUE-system unit (depth-2, survey + DA-fork):
  (a) make instance? a real fn taking a class VALUE — needs every class/interface
  symbol to evaluate to a class value (String does, IPersistentVector/Map$Entry do
  NOT) — vs (b) keep the macro + bind the var to a fn fallback. SECONDARY sub-gap:
  java.util.Map$Entry → map_entry instance? membership (class_name.zig). Verify the
  FULL ordered.map chain after (further blockers may follow). Then the standing
  quality-loop floor drain (`quality_floor:` rows, correctness-first).
- **Forbidden**: pushing to `main`. The fly demos (D-362) are DONE + live.

## Just landed — host-interface convergence substrate complete (flatland.ordered SET works)

The F-010/F-013 substrate that unblocks the deftype-load path for the **196 corpus
libs declaring clojure.lang.* supertypes** (the dominant gap class) — built by chaining
flatland.ordered's gaps, each closed definition-derived (not per-lib):

- **D-365 residual** — bytecode-serializer CHUNK completeness gate (compile-time
  std.meta.FieldEnum exhaustiveness over side-tables + fields).
- **D-286 / ADR-0102 am1** — editable/transient interface family + D-286b dispatch
  (sectionNeedsRemap self-targeting recursion guard).
- **ADR-0127 / D-370** — `print-method` user-extensible multimethod (A2 host_instance
  writer + B2 per-element consult).
- **D-371** — clojure.lang read/op methods (`.valAt`/`.cons`/…) on NATIVE collections
  delegate to the clojure.core equivalent (both backends).
- **D-372 / ADR-0102 am2** — map-side bare aliases + valAt; java.util methods grouped
  under a clojure.lang section accept-and-dropped (AD-027, ADR-0103 rule at method
  granularity).
- **Result**: `(ordered-set 3 1 2 1)` → `#ordered/set (3 1 2)` (full); ordered.map now
  parses past the ENTIRE host-interface surface to D-373 (a class/instance? gap, a
  DIFFERENT subsystem). The substrate unlocks the 15+ data-structure libs grouping
  java methods under clojure.lang sections (finger-tree/core.cache/rrb-vector/avl/
  priority-map/int-map/gvec).
- Follow-ups tracked: D-369 (transient dispatch, off critical path), D-238 (bindable
  `*out*`), D-292 (extend-type multi-protocol sections — the next substrate gap).

## Process discipline (SSOT)

- Gate cadence (user-confirmed 2026-06-10): per-commit **smoke** (`bash test/run_all.sh
  --smoke <step>`, satisfies the cadence hook for shared-code); **batch the full gate**
  after commits accrue. Verify manual probes against a **ReleaseSafe** binary (`zig
  build -Doptimize=ReleaseSafe -Dcpu=baseline`), not the Debug default.

## Cold-start reading order

handover → `.dev/debt.yaml` (**D-373** = NEXT instance?-higher-order; D-369/D-238/D-292
follow-ups; `quality_floor:` rows = the floor drain) →
`private/notes/D372-map-tail-prep.md` (the substrate landscape + the 196-lib leverage)
→ CLAUDE.md § Autonomous Workflow + F-010 quality loop.
