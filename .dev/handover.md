# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; may lag). **NORMAL PUSH MODE**: after each
  unit's smoke-green commit, `git push origin main` immediately (Step 6).
  `build.zig.zon` `.zwasm` is SHA-PINNED (`#412966f7…`, `lazy`). Per-commit = smoke;
  full gate batches at ceiling / boundary / pre-tag.

- **First commit on resume**: self-select. The high/moderate-value UNBLOCKED work
  was largely drained this session (see Last landed). Remaining is either
  marginal-completionism or barriered. Best least-marginal candidates, in rough
  value order: (1) a genuine gap found mid-session — `(keys java-map)` / `(vals
  java-map)` ERROR on cljw (HashMap/TreeMap host_instances don't implement the
  IPersistentMap protocol; clj allows it) — a real interop-parity fix, but needs a
  protocol impl on the host_instance, deeper than a method add; (2) NavigableSet/
  NavigableMap methods (floor/ceiling/headSet/tailSet/subSet/descendingSet/
  floorKey/…) to round out TreeSet/TreeMap + `.containsValue` for TreeMap — rare
  in interop; (3) other low-freq interop classes (ArrayDeque, LinkedHashMap). All
  barriered clusters (security/perf/concurrency/niche clj-parity) are unchanged —
  do NOT force them (F-001/F-003). The loop self-selects; the user may redirect.

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

**This session (7 units, all clj-oracle-verified, full gate green):**
- **D-442 part 2 / ADR-0155**: agent legacy/executor surface 8/8 (`*agent*` /
  `release-pending-sends` / `shutdown-agents`). PREMISE CORRECTION (2nd DA fork):
  post-shutdown send DROPS, not throws (clj-faithful) → new **AD-046**.
- **D-458**: cl-format `V`/`#` runtime-valued directive params (cl-dir sentinels +
  cl-resolve-params; `~n[`/`~#[` clause-select).
- **D-465**: cl-format `~F` natural precision when d omitted (plain fixed, never
  scientific; new cl-float-natural / cl-expand-exp helpers).
- **D-431 java.util container family — NOW COMPLETE**: File path-normalize fix +
  File.txt corpus; then IMPLEMENTED **HashSet / TreeSet / TreeMap** (were absent) —
  host_instances over cljw persistent set / sorted-set / sorted-map. HashMap/
  ArrayList/HashSet/TreeSet/TreeMap all done. AD-032 extended to TreeMap (entry-seq
  / keySet / values are cljw collections, not Java views). Side-fix: phase15_ns_import
  used HashSet as its "unsupported class" example → swapped to ArrayDeque (full-gate
  miss-window caught it).

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

