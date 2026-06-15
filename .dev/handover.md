# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; may lag). **NORMAL PUSH MODE**: after each
  unit's smoke-green commit, `git push origin main` immediately (Step 6).
  `build.zig.zon` `.zwasm` is SHA-PINNED (`#412966f7…`, `lazy`). Per-commit = smoke;
  full gate batches at ceiling / boundary / pre-tag.

- **First commit on resume MUST be**: **ADR-0148 fastest-script perf campaign**
  (user-directed 2026-06-16) — make cljw the FASTEST script interpreter (among
  `{cljw, Python, Ruby, Node.js, Babashka}` cold-start) on the **9 top-gap benches**,
  highest-ROI first: **ratio_sum 3.15× · gc_alloc_rate 2.81× · gc_large_heap 2.22× ·
  destructure 1.72× · json_parse 1.59× · bigint_factorial 1.49× · nested_update 1.37× ·
  string_ops 1.35× · sieve 1.23×** (ratios = cljw ÷ fastest-script, `bench/cross-lang-
  latest.yaml` 2026-06-16). nqueens/regex_count (1.04×) EXCLUDED = cold-start/noise.
  **Method (v0 mostly exhausted)**: other-language internal-impl study (JVM Ratio/
  HashMap/BigInteger, GraalVM/Babashka GC, CPython C-json) + web search + cljw deep-
  dive + measurement-driven experiments + recombining DEFERRED levers. **Experiment
  aggressively, revert freely — a reverted experiment's commit MAY stay in the log**
  (tests are the backstop; never leave `main` red); no regressions (diff oracle + corpus
  3157 stay green); short benches carry noise (≥10 runs, cold-vs-compute). Themes/ROI +
  per-target opt directions: **ADR-0148**. After the 9 (or provably cold-start-floor +
  D-140 cache landed) → resume the original front (VM-perf **D-386** dispatch→
  superinstructions→JIT; §9.0 gap areas). `.dev/.perf_campaign_active` is SET.
  - **GC architecture** (F-006) is DE-PRIORITISED for gc_alloc_rate/gc_large_heap:
    cycle-1 `sample` profiling proved both are dispatch/construction-bound, ~0.5% malloc
    (ADR-0148 Measurement update). Bump/generational GC would not move them. **D-140
    startup cache** still lifts the cold-start-floor targets (sieve, partly nested_update).
  - regex arc DONE (ADR-0147: S1+S2 wired+winning, S3 DFA reserved/D-449, leftmost-first
    fixed, reluctant quantifiers landed); **D-448** nested-empty-quant capture deferred.
  - **bigint** = a target now (was deferred): the BigInt-reduce-accumulator lever, likely
    combined with the alloc work; `private/notes/9.2.S-bigint-factorial-lookahead.md`.
  - **JIT (D-133)** re-sequenced LAST (ADR-0145). **D-244 #4** capstone below.

- **Validation infra / D-244 #4 gap**: `CLJW_GC_TORTURE_ALLOC=N` validates MID-ALLOC
  rooting; the O-032/O-033 producers are SAFEPOINT-torture-validated (the primary
  hazard) but ALLOC-torture is BLOCKED on a pre-existing fabrication-rooting bug
  (op_vector_literal/set/map folds + the `vector` builtin build a partial collection
  in an unrooted Zig local → mid-alloc collect sweeps it). `fromSlice` does NOT
  sidestep it (tried+reverted). FIX = wire `gc_self_guard` (GcHeap.pin/unpin exist;
  per-site set/clear unwired) — an own-session GC-infra capstone;
  `private/notes/9.2.S-d244-4-alloc-torture-finding.md`. LESSON: diff oracle is
  necessary but NOT sufficient; clj corpus + torture + direct probe are the backstops.

- **Forbidden**: `git push --force*`; bare `zig build test` WITHOUT `-Dwasm` (false
  fails — memory `zig_build_test_needs_dwasm`); bare `zig build` for scripted/probe
  (ADR-0133 — ReleaseSafe). Measure perf only ReleaseSafe.

## Last landed (git log = SSOT; all pushed)

ADR-0148 fastest-script campaign, **cycle 1 = 9 wins (O-037…O-045)**. Standing vs
fastest-script (Babashka/Python): nested_update 0.95× CLOSED · string_ops 1.08× ·
json_parse 1.14× · gc_alloc_rate 1.15× · gc_large_heap 1.18× · sieve 1.18× (cold-start
floor, D-140) · destructure 1.22× · bigint_factorial 1.30× · **ratio_sum 2.34× (lone
deep holdout)**. 8/9 ≤1.30×. Levers: O-037/38 ratio zero-copy+arena · O-039 alias BigInt
operands · O-040 op_vector_literal fromSlice · O-041 json bulk-build · O-042 str int
fast-path · O-043 op_get/op_nth collection intrinsics · O-044 op_nth2 · O-045 fusion gate
(gc_large_heap 1.99→1.18×). All diff-oracle + corpus 3157 + smoke green.
**4 hypotheses refuted by measurement** (recorded ADR-0148): GC-arch bump-allocator,
closure-call cost (~3ns), call-site-cache, fusion-always-wins (O-023 was a 2.5×
regression for chunked sources). SAFETY: `clj` → `clojure -J-Xmx2g` + bounded seqs;
measure ReleaseSafe only.

**Next (self-select):** **ratio_sum** is the lone far target — needs DEEP numeric work
(small-ratio inline-i64 repr, OR fused rational accumulator in reduce, OR faster bignum;
all F-004/F-005, need ADR + DA fork). Detail + lever analysis:
`private/notes/9.2.S-ratio-bigint-alloc-levers.md`. Secondary: nudge bigint_factorial
1.30× / sieve 1.18× (D-140 startup cache). Then D-386 dispatch / D-133 JIT.

## Cold-start reading order (resume)

handover → **`.dev/project_facts.md` F-015** → **ADR-0142** (§9 gap-area) → **ROADMAP
§9.0** → the regex unit: **ADR-0147** + ADR-0031 + the audit note + the 48-golden
corpus + `ezi-gex`. memory `perf-beat-python-every-bench` + `perf-campaign-roadmap-9-2-s`
+ `direct-explore-fork-mechanical`. clj oracle = `clojure -J-Xmx2g -M -e` (timeout 60).
