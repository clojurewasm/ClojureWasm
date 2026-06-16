# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; may lag). **NORMAL PUSH MODE**: after each
  unit's smoke-green commit, `git push origin main` immediately (Step 6).
  `build.zig.zon` `.zwasm` is SHA-PINNED (`#412966f7…`, `lazy`). Per-commit = smoke;
  full gate batches at ceiling / boundary / pre-tag.

- **First commit on resume MUST be**: a **deeper validation unit** — the common
  surface is verified mature (3 broad clj-diff probes 2026-06-16 came back clean bar
  one accepted error-class divergence; curated bug-debt is drained/deferred). Run a
  LESS-common real surface through the clj oracle — `clojure.data` / `clojure.zip` /
  `clojure.pprint` edge cases, or a small real library — find the first genuine DIFF,
  fix it as a TDD unit + leave a corpus line (clj_diff_sweep Discipline 1). This is
  the highest-leverage next step now that guessing-at-niche-rows has low yield.
- **The gaps/bugs SWEEP is DRAINED of clean high-value items** (user-directed
  2026-06-16). DONE this session: ~~D-448~~ ~~D-374~~ ~~D-446~~ ~~D-444~~ ~~D-442~~
  (sub-step 2 = CancellationException class + Thread/sleep cooperative abort; ADR-0153)
  ~~D-224~~ (pmap/pcalls/pvalues now genuinely parallel — clj's future + bounded
  look-ahead, no work-pool needed). REMAINING are appropriately DEFERRED behind their
  own barriers: D-266 (native Repeat, perf low-pri), D-319/D-320 (perf cliffs,
  deferred-opt envelope), D-410/D-424/D-425/D-431 (niche/need-a-consumer or
  campaign-CLOSED), D-245 (locking Option-C, recall-trigger not fired), D-246 b/c
  (atom Var-root atomicity, tied to D-386 perf), D-433/D-437 (rare tails). D-435 is
  epic-sized (D-436 大整理). → so the next high-value work is VALIDATION (above), not
  forcing a gated row.
- **JIT is the ONLY fence (user-directed 2026-06-16) — do NOT deep-dive D-133 JIT
  integration**: the ARM64 codegen substrate is DONE + execution-verified (commits
  c8b5ad1d..08501742 + ADR-0151), but the coupled recognizer+codegen+trigger+marshalling+
  oracle integration build is a SEPARATE large unit GATED behind an explicit user greenlight.
  Full integration plan kept ready in `private/notes/9.2.S-d133-jit-survey.md § INTEGRATION`.
  (D-386 dispatch perf is NOT the JIT — it is fair game. Only the JIT integration is fenced.)
  - regex arc DONE (ADR-0147); **D-448** nested-empty-quant capture DONE (2026-06-16);
    **D-449** lazy-DFA reserved; **D-454** = regex O(n²) leftmost find-scan (new, perf).
    **D-451** = Ratio canonical-invariant guard (ADR-0149).
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

This session: **two gap-area-I concurrency units + a 101G zig-cache cleanup**.
**D-442 sub-step 2** (ADR-0153): deref of a cancelled future throws the precise
`java.util.concurrent.CancellationException` (new catchable Kind `.cancellation_error`),
and `Thread/sleep` cooperatively ABORTS a cancelled worker via a threadlocal
`future.current_future` + the uncatchable `.cancellation_abort` signal (releases
thread+pin promptly; un-swallowable past the thunk's own catch). **D-224**:
`pmap`/`pcalls`/`pvalues` now run f genuinely in PARALLEL — clj's future-per-element +
bounded look-ahead ported into core.clj (NO work-pool needed; cljw futures are real OS
threads). Both: e2e + corpus + smoke green. Deleted both repos' `.zig-cache` (71G + 30G)
at the user's request — they regenerate on first build.

**Perf campaign** (ROADMAP §9.2.S, separate from the sweep): fastest-script bar met on
19/30; remaining open targets + the D-386 dispatch lever live in git log + ADR-0148 +
`private/notes/9.2.S-flat-frame-survey.md`. SAFETY: `clj` → `clojure -J-Xmx2g`; measure
ReleaseSafe only.

## Cold-start reading order (resume)

handover → **`.dev/project_facts.md` F-015** → **ADR-0142** (§9 gap-area) → **ROADMAP
§9.0** → the regex unit: **ADR-0147** + ADR-0031 + the audit note + the 48-golden
corpus + `ezi-gex`. memory `perf-beat-python-every-bench` + `perf-campaign-roadmap-9-2-s`
+ `direct-explore-fork-mechanical`. clj oracle = `clojure -J-Xmx2g -M -e` (timeout 60).
