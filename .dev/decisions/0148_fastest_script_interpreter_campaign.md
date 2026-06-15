# ADR-0148 — Perf campaign goal raised: fastest script interpreter on the 9 top-gap benches (ratio_sum…sieve), via beyond-v0 exploration + experiment-and-revert

- **Status**: **Accepted** (2026-06-16, user-directed). Extends the §9.2.S perf
  campaign: the goal rises from "beat Python on every bench" to **"be the FASTEST
  script-language interpreter"** — fastest among `{cljw, Python, Ruby, Node.js,
  Babashka}` cold-start — on the 9 benches where cljw is currently *not* fastest
  AND the gap is above noise. This is a campaign-direction ADR (the per-optimization
  design choices it surfaces each get their own ADR + Devil's-advocate fork per the
  standing rule); user-directed, so the campaign *definition* itself needs no DA pass.
- **Relates to**: §9.2.S (the perf campaign), `.dev/perf_campaign_essence.md` (the
  reminder SSOT, updated alongside), F-002 (finished-form), F-011 (equivalence vs
  clj), F-015, memory `perf-beat-python-every-bench` (updated). Supersedes the
  "beat Python" framing of the campaign goal.

## Context (the 2026-06-16 cross-lang re-measurement)

The refreshed `bench/cross-lang-latest.yaml` (all 8 toolchains, 2026-06-16, hyperfine
5 warmup + 10 runs) shows cljw is the **fastest script interpreter in 19/30** benches.
The user directed: make cljw fastest-script on the top-gap benches **down to `sieve`**
(the near-ties below — nqueens 1.04× and regex_count 1.04× — are excluded: they are
cold-start-floor / measurement noise, not a real compute gap; regex_count already beats
Python). cljw being slower than a *compiled* language (Java/Go/C) is expected and NOT a
target — the bar is the script-interpreter peer set only.

## The 9 targets (cold-start µs, 2026-06-16; ratio = cljw ÷ fastest-script)

| Bench            | cljw   | fastest-script | ratio  | what it measures                                         | optimization direction (hypothesis — the experiments decide)                                                                                               |
|------------------|--------|----------------|--------|----------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|
| ratio_sum        | 110380 | Babashka 35042 | 3.15× | exact-rational (Ratio) harmonic sum ×1000               | per-op BigInt alloc + GCD re-normalisation each step; a fused rational accumulator / lazy reduction; mine JVM `clojure.lang.Ratio` + `BigInteger` internals |
| gc_alloc_rate    | 99354  | Babashka 35324 | 2.81× | 200K short-lived vectors — raw GC alloc throughput      | mark-sweep alloc path vs a bump/generational allocator; nursery / free-list tuning (F-006 GC strategy) — biggest-impact, largest                           |
| gc_large_heap    | 66075  | Babashka 29705 | 2.22× | GC cycle with 100K live maps — mark-sweep trace cost    | full-live re-trace every cycle vs generational; incremental / generational marking (F-006)                                                                  |
| destructure      | 75656  | Babashka 43867 | 1.72× | map+vector destructuring ×100K — binding-form overhead | destructuring expands to intermediate get/nth; compile to direct slot access; cache the binding structure                                                   |
| json_parse       | 54295  | Python 34109   | 1.59× | parse ~25KB JSON ×100 (read-str = Zig std.json)         | std.json→persistent-coll conversion allocates heavily; direct construction, fewer intermediate allocs (Python's C json is the floor — 1.6× is closeable) |
| bigint_factorial | 26396  | Babashka 17715 | 1.49× | 100! via auto-promoting `*` ×1000 — numeric tower      | inherent `std.math.big` mul + per-step alloc; a fused BigInt accumulator (reuse limbs) — the deferred lever, likely needs combination with the alloc work  |
| nested_update    | 20243  | Babashka 14786 | 1.37× | assoc-in/update-in/get-in 3-level ×10K                  | O-033 already made compute beat Python; residual = per-level HAMT node alloc + cold-start floor                                                             |
| string_ops       | 28649  | Babashka 21259 | 1.35× | str-convert + count ×100K — string overhead            | value→string allocates per call; fast int→string, str fast-path for common types                                                                          |
| sieve            | 20605  | Python 16784   | 1.23× | prime sieve via filter — HOF + list ops                 | O-031/O-032 made compute CLOSED (~0.96×); residual is the **cold-start floor** (AOT-core load, D-140), not compute                                         |

**Theme grouping** (campaign ordering follows ROI = gap × tractability):
1. **GC architecture** (gc_alloc_rate 2.81× · gc_large_heap 2.22×; also drags ratio/bigint/nested via alloc) — generational/nursery (F-006). Largest impact, largest effort.
2. **Numeric-tower alloc** (ratio_sum 3.15× · bigint_factorial 1.49×) — fused accumulators that kill per-op alloc; independent of GC arch.
3. **Conversion / binding alloc** (destructure 1.72× · json_parse 1.59× · string_ops 1.35×) — cut intermediate allocation in the prim→Value / value→string / binding-form paths.
4. **Cold-start-floor-bound** (nested_update 1.37× · sieve 1.23×) — compute is competitive/won; the residual is the ~AOT-core-load startup → the **D-140 startup bootstrap cache** lifts both at once (highest cross-target leverage for this group).

## Methodology (beyond v0 — v0 references are mostly exhausted)

The cw-v0 precedent (`.dev/perf_v0_baseline.md`, the superinstruction/fused-reduce/
JIT levers) is **largely mined**. The campaign now sources levers from:

1. **Other-language internal-implementation study** — read how the *winner* does it:
   JVM `clojure.lang.{Ratio,PersistentHashMap,BigInteger}`, Babashka/GraalVM
   native-image GC + SCI, CPython `Objects/` (the C alloc + json), Node/V8. The
   winner's data structure / alloc strategy is the lever to re-derive cljw-clean (F-004).
2. **Web search** — published techniques (generational GC for managed runtimes,
   rational-arithmetic fast paths, bignum limb reuse, persistent-structure alloc).
3. **cljw v1 deep-dive + measurement-driven experiments** — profile the hot path
   directly (the actual alloc/trace cost), form a hypothesis, MEASURE before/after.
   The hypotheses in the table above are starting points, not commitments.
4. **Recombining deferred items** — a single deferred lever (e.g. the BigInt-reduce
   accumulator, the lazy-DFA, a startup cache) may be ineffective alone but pay off
   **in combination**; revisit `.dev/debt.yaml` deferred rows for compounding wins.

## Experiment-and-revert discipline (user-directed, 2026-06-16)

The solid test suite (F-012 diff oracle ×2 + 3157-golden corpus + `CLJW_GC_TORTURE`)
+ the commit log make bold experimentation safe:

- **Experiment aggressively; revert freely.** Try a lever; if it does not pay (or
  regresses), revert the *code*. **A failed-experiment commit MAY stay in the log** —
  the log is the record, and a reverted-but-recorded experiment is a learning, not
  debt. (This relaxes the usual "no broken commits"; the gate still guards `main`'s
  green-ness — never leave `main` red, only leave *recorded reverted* experiments.)
- **No regressions.** Every landed change keeps the diff oracle + corpus green; a perf
  win that breaks equivalence is not a win.
- **Short benches carry noise.** A 1.0–1.2× "gap" can be cold-start-floor or
  measurement noise (~3 ms ± 10% spawn floor). Confirm a real gap with enough runs
  (hyperfine ≥10) + the compute-vs-cold distinction before chasing it; don't optimize
  noise (this is why nqueens/regex_count are excluded).

## Success criterion

For each of the 9: cljw is the **minimum cold-start** among `{cljw, Python, Ruby,
Node.js, Babashka}` in a fresh `bench/compare_langs.sh` run (≥10 runs), robust to
re-measurement. Refresh `bench/README.md` (generated) when targets close. A target whose
residual is provably cold-start-floor (sieve, partly nested_update) closes via the D-140
startup cache rather than per-bench tuning.

## Flow (the autonomous chain — a clear `/continue` runs this)

`/continue` → handover Resume contract → **this ADR** → the 9 targets, highest-ROI
first. When the 9 are fastest-script (or provably cold-start-floor + D-140 landed), the
campaign's original remaining front resumes: **VM-perf D-386** (per-instruction
dispatch → superinstructions → JIT, the "close on v0's numbers" goal) and the §9.0
gap areas. The `.dev/.perf_campaign_active` flag stays set; the
`perf_campaign_essence.md` reminder reflects this goal.

## Consequences

- The campaign goal is now peer-relative (fastest-script), not Python-absolute —
  Babashka (GraalVM native-image, JVM-grade GC/BigInteger/regex-JIT) is the bar on 8
  of the 9, which pushes cljw's GC + numeric-tower + alloc paths hardest.
- GC-architecture work (generational/nursery) is now on the critical path (it gates
  gc_alloc_rate/gc_large_heap directly + drags ratio/bigint/nested) — an F-006-level
  decision that will get its own ADR + DA fork when its design is chosen.
- D-140 (startup bootstrap cache) rises in priority: it lifts every cold-start-floor
  target at once + is the highest dev-velocity ROI.

## Measurement update (2026-06-16) — the GC-pair hypothesis is refuted; the lever is dispatch/construction

First campaign cycle landed O-037..O-040 and `sample`-profiled the top targets. Two
table hypotheses were **empirically corrected** (measure-first, F-002):

- **gc_alloc_rate / gc_large_heap are NOT malloc-bound.** Both show ~0.5% of leaf
  self-time in malloc/free (18/3729 and 14/2806) — the free_pool already recycles
  short-lived objects. The table's "mark-sweep alloc path vs bump/generational
  allocator" hypothesis does not hold for these benches; a nursery/bump allocator
  would not move them. **The GC-arch (F-006 generational) work is therefore
  de-prioritised for these two targets** (it may still matter for genuinely
  alloc-bound future workloads, but not the campaign's GC pair). gc_large_heap's
  residual is ~200K closure invocations (map + reduce) → call dispatch.
- **The universal lever across ratio_sum-residual + the GC pair is dispatch /
  construction, i.e. D-386** (sequenced "phase 2" originally). Re-sequence: D-386 is
  the primary front once the localized construction/alloc levers are mined.

Landed (all pushed, diff oracle + corpus 3157 green):
- **O-037** ratio operand zero-copy refs · **O-038** ratio stack-arena scratch →
  ratio_sum 108.1→85.8 ms (3.15×→2.45×).
- **O-039** alias BigInt operands → bigint_factorial 26.4→22.8 ms (1.49×→1.29×).
- **O-040** `op_vector_literal` `fromSlice` (was empty+N×conj; mirrors O-026 map
  fast path) → **gc_alloc_rate 108.4→48.1 ms (2.81×→1.36×)**, the cycle's biggest win
  — construction-bound, not malloc-bound.

None of the four are CLOSED to fastest-script yet; the residuals are dispatch (D-386).
Next: mine the conversion group (destructure / json_parse / string_ops) for localized
O-040-style levers, then D-386 dispatch.

## Affected files

- `.dev/perf_campaign_essence.md` (goal + exploration modes + experiment-revert
  discipline), `.dev/handover.md` (resume contract), `.dev/debt.yaml` (D-450 campaign
  row + the 9 targets), memory `perf-beat-python-every-bench`. `bench/README.md` is the
  measured scoreboard (regenerated as targets close).
