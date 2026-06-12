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

- **First commit on resume MUST be: the next P4 lib-load triage unit** — load the
  next un-tried clojure-corpus lib (`~/Documents/OSS/clojure-corpus/`) via
  `cljw -cp <src> -e "(require 'NS)"`, triage the first blocker: tractable
  clj-parity bug → fix + e2e (the proven mode — it just found+fixed D-390 defmacro
  destructuring, unblocking grammarly/perseverance); structural JVM-interop
  (bare host-class symbol resolution like `Thread`/`Agent`, or `.getStackTrace`
  frame-shape) → a tracked gap, move on. P4 detail: `private/notes/polish-priority-audit.md`
  + `private/notes/phase14-p4-validation.md` (the convergence map: small pure libs
  LOAD — qbits.ex/perseverance/medley; JVM-interop libs block on the host-class
  frontier). Both the clj-diff HAND-sweep AND bounds/numeric edges have CONVERGED
  (10+ surfaces clean, 6 corpora pinned ~330 golden); value now comes from
  real-lib load triage, NOT more hand-sweeps. SAFETY: every `clj` oracle batch now
  needs `-J-Xmx2g` + bounded seqs (the 2026-06-12 take-nth-0 OOM; memory
  `clj_oracle_heap_cap`).

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

## Just landed — daily-polish + P4 validation (2026-06-12, on `main`)

- **D-391 cross-ns deftype `:import` fix** (P4 lib-load win, unblocks hiccup.core):
  a bare imported deftype (`(:import [ns RawString])` then bare `RawString` /
  `(instance? RawString x)` / `(extend-protocol P RawString …)`) raised name_error
  — the analyzer's symbol→class-VALUE fallback rewrote the bare name to its import
  FQCN, but user deftypes are keyed by SIMPLE name in `rt.types`. Fix: fall back to
  the bare name when the FQCN misses (host surfaces stay FQCN-keyed). hiccup renders
  byte-identical to clj; e2e phase14_deftype_cross_ns_import; smoke 5/0. Prior:
  **D-390 defmacro destructuring** (lower through `fn`, unblocked perseverance).
- **OOM root-cause fixed**: the 2026-06-12 ~138GB Mac exhaustion was my unbounded
  `(take-nth 0)` in a sweep → clj realised an infinite seq with no heap cap. Fix:
  `clj_diff_sweep.sh` clj batch now `-J-Xmx2g` (memory `clj_oracle_heap_cap`).
- **6 corpora pinned** (~330 golden cljw≡clj): division_ops / format_sorted_edges /
  transducer_arities / clojure_1_11_additions / bounds_edges / numeric_tower_ops.
- **D-271 value-driven re-amend** (ADR-0134): not a speculative 13-substrate
  megaproject — a substrate joins IObj/IMeta membership only when a consumer pulls
  it (the scope-escalation smell the user caught). Parity SSOT staleness fixed (7 ns).

## Cold-start reading order (resume)

handover → **`private/notes/polish-priority-audit.md`** (the prioritized polish
wiring P1-P5) → `.claude/rules/clj_diff_sweep.md` + `.claude/rules/accepted_divergences.md`
(the F-011 sweep + classify discipline) → `.dev/debt.yaml` (D-210 floor / D-271 /
D-273 / D-232 / D-321/322/239) → `.dev/v0_v1_feature_parity.md` (P3 ns-backfill SSOT)
→ `.dev/accepted_divergences.yaml` (AD ledger). clj oracle = `~/Documents/OSS/clojure/`
(spec) + `clj -M -e` (`timeout 20`, bound seqs); v0 ref `~/Documents/MyProducts/ClojureWasm/`.
