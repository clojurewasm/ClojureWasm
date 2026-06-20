# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; may lag). **NORMAL PUSH MODE**: after each
  unit's smoke-green commit, `git push origin main` immediately (Step 6).
  `build.zig.zon` `.zwasm` is SHA-PINNED (`#412966f7…`, `lazy`). Per-commit = smoke;
  full gate batches at ceiling / boundary / pre-tag.

- **First commit on resume**: self-select. The BOUNDED high/moderate-value
  unblocked work is drained (see Last landed — java.util container family + its full
  Clojure-protocol surface are complete; a clj-diff sweep fixed bigint-of-float +
  String char-array ctor). The two genuinely-valuable remaining units are
  SUBSTANTIAL FEATURES, deferred this session with COMPLETE implementation plans in
  their debt rows (start there): **D-467 `with-precision`** (a standard clojure.core
  macro — needs `*math-context*` dynamic var + a sig-fig-rounded BigDecimal division
  algorithm in big_decimal.zig + the macro; the rounded-division is the crux; a
  fresh focused unit, NOT a context-tail add — that's why it's deferred not done);
  **D-466 `(instance? java.util.Map hm)`** (host-supertype hierarchy — needs a
  DEDICATED TypeDescriptor supertype field consulted only by matchUserType, NOT
  protocol_impls, which CRASHES the AOT bootstrap; plus registering the Sorted/
  Navigable interface class symbols). Both have full plans + clj-verified target
  hierarchies in `.dev/debt.yaml`. Everything else is barriered (below) or near-zero
  completionism (NavigableSet nav methods confirmed absent from the frequent-interop
  corpus). The loop self-selects; the user may redirect to a barriered area by
  relaxing the relevant F-NNN/pause.

- **Remaining clusters (all BARRIERED or niche — the high-value unblocked work is
  drained)**:
  - **Security (gap II, ~10 rows)**: ALL barriered — D-339 slowloris (Phase-15
    cancellable Io, F-003); D-347/349 wasm/run fuel+capture (zwasm-side, F-001);
    D-338 host-import allowlist (reservation); D-346/353 (no live threat / use case).
    Don't force (F-001/F-003).
  - **Perf (gap III, D-450, ADR-0148, PAUSED)**: only fenced levers — D-386(a)
    inline stepOnce (UAF-class), JIT D-133 user-fenced.
  - **clj-parity residuals (niche)**: D-446 multidim aget (deep — make-array
    multidim + Long/TYPE unsupported), D-462 ZonedDateTime (tz-DB), D-463 per-var
    events (take-up-when-needed), D-410 java.text, D-431 Throwable.
  - **Concurrency (gap I)**: D-258 agent-race flake (deep multi-thread STW race,
    D-244 #4), D-239/245/255 PARTIAL.

- **Forbidden this session**: JIT integration (D-133 — user-fenced 2026-06-16; plan
  in `private/notes/9.2.S-d133-jit-survey.md § INTEGRATION`). `git push --force*`.
  Bare `zig build test` WITHOUT `-Dwasm` (false fails — memory
  `zig_build_test_needs_dwasm`). Bare `zig build` for scripted/probe (ADR-0133 —
  ReleaseSafe). A reader-macro NS-qualification MUST use `rt/` (the only core ns
  resolvable in the core.clj-less diff fixture), NOT `clojure.core/` (AD-038 lesson).

## Last landed (git log = SSOT; all pushed)

**This session (~14 units, all clj-oracle-verified, full gate green throughout):**
- **D-442 part 2 / ADR-0155**: agent surface 8/8 (`*agent*`/`release-pending-sends`/
  `shutdown-agents`); 2nd DA fork corrected the premise → post-shutdown send DROPS,
  not throws → new **AD-046**.
- **D-458 / D-465**: cl-format `V`/`#` runtime params + `~F` natural precision.
- **D-431 java.util container family — COMPLETE**: File path-normalize fix +
  implemented **HashSet / TreeSet / TreeMap** (host_instances over cljw set/sorted-
  set/sorted-map). Then the full **Clojure-protocol surface** on all java.util maps/
  sets: `get`/`contains?`/`keys`/`vals`/`:kw`/`seq`/`count`/`empty` now match clj —
  closing a `(get hm k)`→silent-nil CORRECTNESS bug + several errors (added ILookup
  `-lookup` / Associative `-contains-key?` / IPersistentMap `-keys`/`-vals`
  MethodEntries + a lookup.invoke keyword-arm generalization + an emptyFn host-
  fallback). AD-032 extended to TreeMap. Side-fix: phase15_ns_import unsupported-
  example → ArrayDeque.
- **clj-diff sweep** (~150 exprs, F-011 quality-loop after named work drained):
  fixed **bigint-of-float** (route through bigdec, not exact trunc) + **(String.
  char[])** (chars' codepoints). Deferred 2 substantial features with plans (D-466
  instance?-hierarchy, D-467 with-precision). ~15 DIFFs classified as accepted
  divergences (AD-001/003/007/044, F-005). Note in private/notes/clj-diff-sweep-*.md.

## Perf campaign (PAUSED behind the active flag; not the current task)

`.dev/.perf_campaign_active` is SET but the loop is in the quality sweep, not perf.
If the user re-opens perf: the only remaining accessible lever is D-386(a) (inline
`stepOnce` SP-marshalling, a risky UAF-class cycle — fresh focus + the
`CLJW_GC_TORTURE_ALLOC` safety net); JIT D-133 is user-fenced. Full perf state:
ADR-0148 + `private/notes/9.2.S-perf-remeasure-2026-06-17.md`.

## Cold-start reading order (resume)

handover → `.dev/project_facts.md` (F-002 / F-010 / F-011) → ROADMAP §9.0 (gap
areas I/II/III) → `.dev/accepted_divergences.yaml` (AD-001…046) → `.dev/debt.yaml`
(D-431 java.util family DONE; remaining residuals barriered/niche per the cluster
list above). memory `direct-explore-fork-mechanical` + `clj_diff_sweep_methodology`.

