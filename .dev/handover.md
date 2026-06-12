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

- **First commit on resume MUST be: a P4 validation unit** — load a real library
  (clojure-corpus) or run an upstream `clojure.test` fragment through cljw, triage
  each failure → a small clj-parity fix + corpus line, or a tracked debt gap.
  Detail: **`private/notes/polish-priority-audit.md`** (P4 = D-232). The
  daily-polish clj-diff HAND-sweep has CONVERGED (9 surfaces → 0 new bugs; all
  remaining divergences tracked or AD-classified), so value now comes from
  real-lib validation surfacing what hand-sweeps miss — not more hand-sweeps.

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

## Just landed — daily-polish loop (2026-06-12, on `main`)

- **D-389 Throwable->map** partial landed (`.clj` defn, core :cause/:via/:data;
  :trace/:at OMITTED as honest-degraded PROVISIONAL pending D-232 frame-shape;
  DA-fork Alt 1; e2e phase14_throwable_map). **D-267 → AD-030** (`%c` int-reject,
  F-005-derived; e2e phase14_format_char_int).
- **4 corpora pinned** (145 golden cljw≡clj): division_ops, format_sorted_edges,
  transducer_arities, clojure_1_11_additions — the bug-prone edges the sweeps
  proved clean.
- **Parity SSOT staleness fixed**: 7 backfilled namespaces (java.io / core.protocols
  / instant / stacktrace / template / test.tap / uuid) MISSING→present.
- **D-271 value-raised**: its IObj/IMeta activation blocks clojure.datafy (the
  next-resume task above), so no longer NICHE — but still an F-003 structural cycle.

## Cold-start reading order (resume)

handover → **`private/notes/polish-priority-audit.md`** (the prioritized polish
wiring P1-P5) → `.claude/rules/clj_diff_sweep.md` + `.claude/rules/accepted_divergences.md`
(the F-011 sweep + classify discipline) → `.dev/debt.yaml` (D-210 floor / D-271 /
D-273 / D-232 / D-321/322/239) → `.dev/v0_v1_feature_parity.md` (P3 ns-backfill SSOT)
→ `.dev/accepted_divergences.yaml` (AD ledger). clj oracle = `~/Documents/OSS/clojure/`
(spec) + `clj -M -e` (`timeout 20`, bound seqs); v0 ref `~/Documents/MyProducts/ClojureWasm/`.
