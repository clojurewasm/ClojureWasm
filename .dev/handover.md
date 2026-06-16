# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; may lag). **NORMAL PUSH MODE**: after each
  unit's smoke-green commit, `git push origin main` immediately (Step 6).
  `build.zig.zon` `.zwasm` is SHA-PINNED (`#412966f7…`, `lazy`). Per-commit = smoke;
  full gate batches at ceiling / boundary / pre-tag.

- **First commit on resume MUST be**: continue the **ADR-0148 fastest-script campaign**
  (`.dev/.perf_campaign_active` SET). **4 of 9 targets CLOSED** (cljw fastest-script):
  string_ops + bigint_factorial + ratio_sum + nested_update. **NEXT = D-386 (VM dispatch
  → superinstructions → JIT)** — per ADR-0148 §"Measurement update" the GC pair
  (gc_alloc_rate ~1.33× + gc_large_heap ~1.25×) + sieve + destructure ALL converge on
  dispatch (NOT a generational GC — de-prioritised; the construction half is mined via
  O-040). Extend the superinstruction set (O-029..O-031 added arith + local_const/locals)
  to more hot sequences; D-133 ARM64 JIT is re-sequenced LAST (ADR-0145). A tractable
  measured sub-lever: the map-`:keys` destructure emits `(if (seq? mm) (apply hash-map mm)
  mm)` per iter (~5.5 ms/100k) — a `seq?`/predicate intrinsic would trim it, but it is LOW
  ROI (full new-opcode machinery for ~2-3 ms on a 1.13× bench) so do it only as part of a
  broader predicate-intrinsic batch. json_parse ~1.20× is vs CPython C-json (near floor).
  Method: measure-first (ReleaseSafe only; trust ADR-0148 %-profiles over crude `sample`);
  experiment-and-revert (reverted commits MAY stay in log; never leave `main` red; diff
  oracle + corpus 3181 stay green; ≥10 runs). D-453 (Alt C op_load_class) deferred.
  - regex arc DONE (ADR-0147); **D-448** nested-empty-quant capture deferred; **D-449**
    lazy-DFA reserved. **D-451** = Ratio canonical-invariant guard (ADR-0149).
  - **JIT (D-133)** re-sequenced LAST (ADR-0145). **D-244 #4** capstone below.

- **D-244 #4 (GC fabrication-rooting) — DESIGN RESOLVED this session; gates D-386 substep 2
  (op_top hoist).** `CLJW_GC_TORTURE_ALLOC=1` corrupts ANY multi-alloc collection BUILDER —
  a single `(conj [1 2 3] 4)` → `[1 nil…]`/panic (NOT just the literal ops): conj allocs
  `*TailNode`/`*HamtNode` in an unrooted Zig local across the next alloc. **FIX = ADR-0090's
  already-DECIDED Alt B** ("publish a precise root, do NOT disable the collector") extended
  to a **NODE-LEVEL precise-root guard** for in-flight non-Value nodes — op-level
  `gc_self_guard` (the partial Value) is INSUFFICIENT (does not root conj's internal
  TailNode). The no-collect-region / `suppressCollection` approach was EXPLORED + **REJECTED
  (ADR-0150)** — contradicts ADR-0090; do NOT re-propose it. Open sub-decision: fromSlice's
  `level_nodes` tower needs an array guard OR revert O-040 to conj-fold (one node-window at a
  time). High-stakes GC-infra capstone; the alloc-torture is the self-validating gate. Full
  spec: **ADR-0150 § Correct path** + `private/notes/9.2.S-d244-4-design.md` (supersedes the
  older `9.2.S-d244-4-alloc-torture-finding.md`). LESSON: diff oracle is necessary but NOT
  sufficient — clj corpus + torture + direct probe are the backstops; cross-check any DA
  recommendation against DECIDED ADRs (the Alt-A miss).

- **Forbidden**: `git push --force*`; bare `zig build test` WITHOUT `-Dwasm` (false
  fails — memory `zig_build_test_needs_dwasm`); bare `zig build` for scripted/probe
  (ADR-0133 — ReleaseSafe). Measure perf only ReleaseSafe.

## Last landed (git log = SSOT; all pushed)

This session (git log = SSOT): **D-452 cold-start AOT** (Part A = ADR-0034 am5
`type_descriptor` wire tag 0x10, serialized-by-name + import-blind `resolveDescriptorByKey`,
DA-fork Alt B; Part B = `buildBootstrapEnvelope` AOT-caches the whole bootstrap, cold start
8.0→6.1 ms, **string_ops CLOSED**) + **O-047** (no-clone BigInt arith result via
`wrapArithCell` move/collapse — **bigint_factorial CLOSED**, cljw 20.2 ms fastest-script).
Earlier cycle 1 = O-037…O-046 (ratio_sum + nested_update CLOSED). All diff-oracle + corpus
3181 + smoke green. **6 hypotheses refuted by measurement** (ADR-0148): GC-arch
bump-allocator, closure-call cost, call-site-cache, fusion-always-wins, bignum-compute-bound
(was the result CLONE — O-047), cold-start-Debug-ghost (was 6 ms not 0.48 s). D-453 (Alt C
op_load_class) deferred. SAFETY: `clj` → `clojure -J-Xmx2g`; measure ReleaseSafe only.

**Next (self-select):** post-D-452 + O-047 re-measure DONE (ReleaseSafe, this session).
**4 of 9 CLOSED** (cljw fastest-script): string_ops (cold-start AOT), bigint_factorial
(O-047), ratio_sum (O-046), nested_update (O-033). Remaining: gc_alloc_rate ~1.33× +
gc_large_heap ~1.25× + sieve ~1.23× + destructure ~1.13× (ALL dispatch/construction-bound
→ D-386, per ADR-0148 §"Measurement update": the GC pair is ~0.5% malloc, NOT generational
— de-prioritised; gc_large_heap residual = ~200k closure calls) · json_parse ~1.20× (vs
CPython C-json, near floor — low priority). See the first-commit bullet for the D-386 path
+ the seq?-guard sub-lever. Lever analysis: `private/notes/9.2.S-ratio-bigint-alloc-levers.md`.

## Cold-start reading order (resume)

handover → **`.dev/project_facts.md` F-015** → **ADR-0142** (§9 gap-area) → **ROADMAP
§9.0** → the regex unit: **ADR-0147** + ADR-0031 + the audit note + the 48-golden
corpus + `ezi-gex`. memory `perf-beat-python-every-bench` + `perf-campaign-roadmap-9-2-s`
+ `direct-explore-fork-mechanical`. clj oracle = `clojure -J-Xmx2g -M -e` (timeout 60).

## Stopped — user requested

User instruction (2026-06-16): "clearしてcontinueしたときにうまくワークする配線、参照
チェーン監査して止めてください". Audited the resume reference-chain: all D-NNN / ADR /
private-note targets RESOLVE (`check_debt_id_refs` clean; notes survive `/clear` on disk);
the campaign flag is SET; HEAD is green + pushed. Corrected the STALE D-244 #4 section
(it predated this session's ADR-0150 finding) to point at the right artifacts. Resume per
the first-commit bullet: the fully-designed **D-244 #4** GC capstone (ADR-0090 Alt B
node-level guard — see ADR-0150 § Correct path + `private/notes/9.2.S-d244-4-design.md`),
which gates D-386 substep 2; OR the non-blocked **D-386 superinstruction** path. The next
`/continue` deletes this section and resumes the loop.
