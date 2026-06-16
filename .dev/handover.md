# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; may lag). **NORMAL PUSH MODE**: after each
  unit's smoke-green commit, `git push origin main` immediately (Step 6).
  `build.zig.zon` `.zwasm` is SHA-PINNED (`#412966f7…`, `lazy`). Per-commit = smoke;
  full gate batches at ceiling / boundary / pre-tag.

- **First commit on resume MUST be**: **D-448 — regex capture-in-outer-quantifier
  SILENTLY-WRONG** (the gaps/bugs sweep's first correctness item). D-386 sub-lever (b)
  was RE-CONFIRMED DEAD (debt.yaml D-386 reconciliation 2026-06-16): the per-op polls are
  near-free in production (one relaxed atomic load + two predicted-not-taken gates), and
  the every-256 experiment was already run + reverted 2026-06-15. (a) is risky UAF-class
  "not to be rushed", (c) JIT is user-fenced → the dispatch axis is exhausted, campaign
  goal already MET, so the loop pivots straight to the sweep.
- **The gaps/bugs SWEEP** (user-directed 2026-06-16: actually drain these, don't defer).
  Prioritized order (easiest/highest-value first): **D-448** regex
  capture-in-outer-quantifier SILENTLY-WRONG (correctness) → **D-435**
  dual-backend diff-oracle coverage hole (bootstrap-core Fixture so full-runtime forms are
  parity-checked) → **D-374** top-level `(do (import…) …)` unroll (eval-semantics) → **D-266**
  `(repeat n x)` non-chunked realization (perf pathology) → **D-446** arity-divergence audit
  (clj-parity big-bang) → real-lib gaps **D-319**/D-320/D-430/D-410/D-424/D-425/D-431 →
  concurrency **D-444**/D-442/D-246. Each is a normal TDD unit (diff oracle + corpus green).
- **JIT is the ONLY fence (user-directed 2026-06-16) — do NOT deep-dive D-133 JIT
  integration**: the ARM64 codegen substrate is DONE + execution-verified (commits
  c8b5ad1d..08501742 + ADR-0151), but the coupled recognizer+codegen+trigger+marshalling+
  oracle integration build is a SEPARATE large unit GATED behind an explicit user greenlight.
  Full integration plan kept ready in `private/notes/9.2.S-d133-jit-survey.md § INTEGRATION`.
  (D-386 dispatch perf is NOT the JIT — it is fair game. Only the JIT integration is fenced.)
  - regex arc DONE (ADR-0147); **D-448** nested-empty-quant capture deferred; **D-449**
    lazy-DFA reserved. **D-451** = Ratio canonical-invariant guard (ADR-0149).
  - **D-244 #4b** (eval-reentrant lazy-realization/reduce rooting under alloc-torture —
    `(into {} (map f (range N)))` → wrong count) is an OPEN follow-on (the gc_self_guard
    set/clear sites); NOT a production bug (auto-collect OFF). Independent of op_top hoist.

- **CAUTION — alloc-torture is CPU-brutal**: `CLJW_GC_TORTURE_ALLOC=1` forces a full STW
  collect on EVERY `gc.alloc`. Keep probes TINY/EAGER (≤~70 elems, no lazy-seq realization),
  ONE at a time with `timeout`, NEVER batch large ranges (froze the host 2026-06-16).

- **Forbidden**: `git push --force*`; bare `zig build test` WITHOUT `-Dwasm` (false
  fails — memory `zig_build_test_needs_dwasm`); bare `zig build` for scripted/probe
  (ADR-0133 — ReleaseSafe). Measure perf only ReleaseSafe.

## Last landed (git log = SSOT; all pushed)

This session: **2 perf wins, profiling-driven redundancy removal** (not micro-leaks).
**O-048** (`fastGet`): `contains`+`get` = two map scans/lookup → one. **O-049**
(`eqConsult`): simple-key (kw/sym/str/num/char/bool/nil) fast path skips the
`dispatch.current_env` TLV + 2 `keyInstanceEq` probes (both operands simple only, so
custom-equiv/seq-key unchanged). **destructure 55.0→45.9 ms (−16.5%, ~1.05× vs Bb);
gc_large_heap 33.5→32.0 ms.** Diff oracle ×2 + corpus 3181 + custom-equiv probe green.
Prior: **D-244 #4 fabrication no-collect region** (ADR-0150). Measured + recorded:
micro-levers (TLV/trace-push/memset/mutex) inert; auto-collect net-negative; remaining
GC-pair/sieve/json wins need the deep call-ABI / JIT lever (orientation note).

Prior (git log = SSOT): **D-452 cold-start AOT** (Part A = ADR-0034 am5
`type_descriptor` wire tag 0x10, serialized-by-name + import-blind `resolveDescriptorByKey`,
DA-fork Alt B; Part B = `buildBootstrapEnvelope` AOT-caches the whole bootstrap, cold start
8.0→6.1 ms, **string_ops CLOSED**) + **O-047** (no-clone BigInt arith result via
`wrapArithCell` move/collapse — **bigint_factorial CLOSED**, cljw 20.2 ms fastest-script).
Earlier cycle 1 = O-037…O-046 (ratio_sum + nested_update CLOSED). All diff-oracle + corpus
3181 + smoke green. **6 hypotheses refuted by measurement** (ADR-0148): GC-arch
bump-allocator, closure-call cost, call-site-cache, fusion-always-wins, bignum-compute-bound
(was the result CLONE — O-047), cold-start-Debug-ghost (was 6 ms not 0.48 s). D-453 (Alt C
op_load_class) deferred. SAFETY: `clj` → `clojure -J-Xmx2g`; measure ReleaseSafe only.

**Campaign state:** 4 of 9 fastest-script CLOSED (string_ops/bigint_factorial/ratio_sum/
nested_update). This session added O-048/O-049 → destructure 1.05× / gc_large_heap 1.08×.
Remaining open: gc_alloc_rate 1.15× / sieve 1.23× / destructure 1.05× / gc_large_heap 1.08× /
json_parse 1.14× — all dispatch/alloc-bound; the live lever is D-386 (see Resume contract).

## Cold-start reading order (resume)

handover → **`.dev/project_facts.md` F-015** → **ADR-0142** (§9 gap-area) → **ROADMAP
§9.0** → the regex unit: **ADR-0147** + ADR-0031 + the audit note + the 48-golden
corpus + `ezi-gex`. memory `perf-beat-python-every-bench` + `perf-campaign-roadmap-9-2-s`
+ `direct-explore-fork-mechanical`. clj oracle = `clojure -J-Xmx2g -M -e` (timeout 60).


## Stopped — user requested

User instruction (2026-06-16): audit the remaining debt against code facts, update
where needed, present the prioritized work order, and wire a clean cleared-session
plan — "D-386 をやったあと、JIT は深追いしない、それ以外（ギャップ・バグ）は実際に
スイープして進める" — then stop. Done: D-386 row updated (b-batch-polls = cheapest
dispatch win; JIT substrate landed; call-ABI refuted); the prioritized order delivered
in chat; this Resume contract wired (D-386 → sweep gaps/bugs backlog; JIT integration
fenced behind a user greenlight). Reference chain audited GREEN (tree clean = pushed,
perf flag SET, D-386 code refs + flat-frame/jit survey notes + ADR-0151 + substrate
commits all resolve). The next `/continue` deletes this section and resumes the loop
at D-386.
