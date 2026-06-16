# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; may lag). **NORMAL PUSH MODE**: after each
  unit's smoke-green commit, `git push origin main` immediately (Step 6).
  `build.zig.zon` `.zwasm` is SHA-PINNED (`#412966f7…`, `lazy`). Per-commit = smoke;
  full gate batches at ceiling / boundary / pre-tag.

- **First commit on resume MUST be**: **D-086 — record `__extmap` (assoc a non-declared
  key onto a defrecord)**. The 2026-06-16 deeper-validation swept common/edge/stateful
  surfaces (8 clj-diff probes; print-table + cl-format number+iteration directives FIXED;
  low-value edges classified as D-455/D-456/D-457) and surfaced D-086 as the TOP remaining
  real gap: `(assoc (->R 1 2) :z 9)` raises "not yet supported", `(map->R {…extra…})` drops
  extra keys — clj holds them in `__extmap`. MEDIUM-HIGH value (assoc-on-record is common),
  but a STRUCTURAL unit (TypedInstance extern-struct gains an extmap slot + GC trace +
  IPersistentMap routing for seq/keys/count/dissoc over extmap + a co-issued ADR amending
  the layout). The F-003 "layout owner" deferral now resolves to the loop itself (gap-area
  model) — so it IS takeable. **READ FIRST: `private/notes/9.0-D086-record-extmap-plan.md`**
  — the full Step-0 plan + the **verified 配線・参照チェーン監査** (the COMPLETE site
  checklist: assoc/get/contains?/dissoc/keys/vals/count/seq/print/equality + struct/GC, each
  with file:line) + the meta-precedent de-risking (ADR-0112 is the exact twin, so the
  struct/GC half is low-risk) + the 3 resume primers. Then the D-086 debt row + ADR-0112.
  First step = the DA-forked layout ADR (mirror ADR-0112), then walk the checklist.
- **The gaps/bugs SWEEP is DRAINED of clean high-value items** (user-directed
  2026-06-16). DONE this session: ~~D-448~~ ~~D-374~~ ~~D-446~~ ~~D-444~~ ~~D-442~~
  (sub-step 2 = CancellationException class + Thread/sleep cooperative abort; ADR-0153)
  ~~D-224~~ (pmap/pcalls/pvalues genuinely parallel — clj's future + bounded look-ahead,
  no work-pool) + **print-table** clj-exact format (F-011) + **D-455** cl-format common
  surface COMPLETE (number/iteration/case/`~R` cardinal-ordinal-Roman-radix; only the
  ~P/~C/~&/~T/~* long-tail remains) + a user-directed clj-parity batch: **D-457(1)** symbol
  reader-`^meta` preserved, **(3b)** `.state_error` Kind (re-groups/stm/transient catch as
  IllegalStateException), **D-457(3)** read-string rejects `#?` (+`:read-cond :allow`),
  **AD-002** transient print recorded; D-457(2) `#=` confirmed accepted-by-design (AD-026).
  NEXT = D-086 (above). Other
  REMAINING appropriately DEFERRED behind their own barriers: D-266 (native Repeat,
  perf low-pri), D-319/D-320 (perf cliffs,
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

handover → **`private/notes/9.0-D086-record-extmap-plan.md`** (the next unit's full
plan + verified wiring audit) → `.dev/project_facts.md` F-015 → ADR-0142 (§9 gap-area)
→ ROADMAP §9.0 → ADR-0112 (the meta-field twin to mirror for extmap). memory
`direct-explore-fork-mechanical`. clj oracle = `clojure -J-Xmx2g -M -e` (timeout 60).

## Stopped — user requested

User instruction (2026-06-16): "クリアセッションでやるので、配線・参照チェーン監査をして
止めて" (D-086 will be done in a fresh/clear session; do the wiring & reference-chain
audit, then stop). Done: the COMPLETE D-086 site checklist + reference-chain verified
and written to `private/notes/9.0-D086-record-extmap-plan.md` (with the meta-precedent
de-risking + the 3 resume primers). Resume = D-086 per the Resume contract above. All
other work this session is committed + pushed; tree clean.
