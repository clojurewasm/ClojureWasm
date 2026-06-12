# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` is the SSOT; ≈ 16087139). All work on `main`;
  commit + `git push origin main` is the atomic Step 6 (`--force*` deny-listed).
  Gate cadence ADR-0107: per-commit smoke (background), batch the full gate ALONE
  at the ≤5 ceiling / boundary. **The full gate is now ~2 min (D-385 root-caused
  + fixed, ADR-0132) and builds `-Dwasm` throughout (ADR-0133)** — the prior
  multi-hour/timeout friction is gone. **Perf measured ONLY on a Release binary**
  (`bench/run_bench.sh --quick` / `scripts/perf.sh`), never `time zig-out/bin/cljw`
  (Debug) — `.claude/rules/perf_measure_release.md`.

- **First commit on resume MUST be: the clojure.lang.* deftype-marker family
  big-bang (NOT more single-lib clean-bug triage).** The 2026-06-12 triage swept
  ~50 corpus libs and CONVERGED: pure libs LOAD + FUNCTION correctly (verified
  end-to-end — math.combinatorics / priority-map / core.unify / data.json all
  clj-match), and the 8 clean single-bug wins landed (D-391 cross-ns deftype
  import, D-392 prefix-list libspecs, D-393 `extend`, D-394 IMeta, D-395
  Sequential/ISeq, D-396 `destructure`, D-397 Indexed, D-398 FQCN catch). The
  remaining frontier is UNIFORMLY host-frontier: the clojure.lang.* deftype-marker
  family (partially cleared — IMeta/Sequential/ISeq/Indexed done; remaining +
  dispatch follow-ups), `definterface` (deferred-structural, debt:1475), bare
  host-class symbols (Thread/Class/System), reflection (getConstructor/newInstance),
  and JVM internals (clojure.lang.Compiler/RT/PersistentArrayMap statics). Doing
  ONE marker per cycle is now the drip-feed smell — instead ENUMERATE the whole
  remaining marker surface (instaparse's AutoFlattenSeq alone needs IFn/applyTo +
  2-arity-nth dispatch; potemkin.collections needs IMapEntry) and drive it big-bang
  per `.claude/rules/clj_diff_sweep.md` Discipline 2. Open follow-ups: D-397
  (3-arg nth typed_instance dispatch + IFn/applyTo arity collision). SAFETY: every
  `clj` oracle batch needs `-J-Xmx2g` + bounded seqs (memory `clj_oracle_heap_cap`);
  register every new e2e in run_all.sh same-commit (memory `e2e-register-in-run-all`).

  **D-271 is NOT a mandate** (ADR-0134, value-driven re-amend): the finished form
  is full IObj/IMeta metable-ness, but a substrate joins membership ONLY when a
  real consumer PULLS it — NOT a speculative 13-substrate megaproject (the
  Progress-pressure/scope-escalation smell the user caught 2026-06-12). The first
  value-driven slice, IF taken: resolve IObj/IMeta as values + membership for the
  already-metable tags (clears the name_error); but datafy (the lone near-term
  puller) has OTHER blockers too (class/.getName, host-class extends,
  clojure.reflect), so verify the whole datafy load before committing to it.

  **State**: Phase 14 (v0.1.0 milestone) ~95% done — only 14.14 (exit-smoke + tag)
  left; user is NOT cutting the tag yet. Full gate green on Mac (317/0).

  **Paused (not abandoned)**: the §9.2.S perf campaign — cljw already WINS/parity vs
  Python on most benches; the 2 cold-losers (regex_count 1.8×, sieve 1.4×) + JIT are
  the remaining levers. Resume ONLY on explicit user direction; full state in
  `.dev/perf_v0_baseline.md` + `.dev/perf_campaign_essence.md` + `.dev/optimizations.md`.

- **Forbidden this session**: re-opening the §9.2.S perf campaign as the resume
  DEFAULT (paused — polish is the focus; resume perf only on explicit user
  direction); editing zwasm except via the F-001 finding-handling policy;
  `git push --force*`.

## Just landed — P4 lib-load triage, 8 clean fixes (2026-06-12, on `main`)

Each found via real-lib triage, verified vs the lib + clj oracle, e2e-registered,
full gate green (325/0): **D-391** cross-ns deftype `:import` (hiccup renders
clj-identical) · **D-392** prefix-list libspecs both forms (potemkin, data.xml) ·
**D-393** `clojure.core/extend` runtime fn (tools.reader) · **D-394** IMeta deftype
marker · **D-395** Sequential/ISeq deftype markers w/ real dispatch (instaparse) ·
**D-396** `clojure.core/destructure` port (kezban; 11 shapes clj-matched) · **D-397**
Indexed marker (1-arity nth, rough edges scoped out) · **D-398** FQCN exception catch
(`java.lang.AssertionError` + reflective family). Infra: the e2e-registration trap
(smoke passes an orphan, full gate's check_e2e_reach fails it) caught + fixed +
memory'd (`e2e-register-in-run-all`). Rough edges deferred not shipped half-done
(D-397 follow-ups).

## Cold-start reading order (resume)

handover → **`private/notes/polish-priority-audit.md`** (the prioritized polish
wiring P1-P5) → `.claude/rules/clj_diff_sweep.md` + `.claude/rules/accepted_divergences.md`
(the F-011 sweep + classify discipline) → `.dev/debt.yaml` (D-210 floor / D-271 /
D-273 / D-232 / D-321/322/239) → `.dev/v0_v1_feature_parity.md` (P3 ns-backfill SSOT)
→ `.dev/accepted_divergences.yaml` (AD ledger). clj oracle = `~/Documents/OSS/clojure/`
(spec) + `clj -M -e` (`timeout 20`, bound seqs); v0 ref `~/Documents/MyProducts/ClojureWasm/`.
