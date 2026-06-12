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

- **First commit on resume MUST be: grow the D-405 conformance harness to the
  next verified_projects batch (hiccup / honeysql / integrant / core.cache /
  data.zip / qbits.ex corpora via `scripts/lib_conformance.sh <lib> --oracle`),
  fixing root-causes the authoring surfaces — then the D-400 marker remainder
  (IKVReduce/IBlockingDeref dispatch + D-397 follow-ups) and the D-406 boundary
  doc.** D-405 is DISCHARGED (2026-06-13): 9 seed corpora 100% golden
  (test/conformance/ + generated COVERAGE.md; replay = `lib_conformance.sh
  --all`, fixable-DIFF promotion = `--promote`); bouncer dropped (clj-time/joda
  = Java-library dep, the first D-406 boundary example). Track 2 next: **D-407**
  standing proofs (fast-Zig-primitive bench / Wasm-FFI demo / startup+size).
  **Wasm-component-as-namespace (D-404 / ADR-0135) stays the north star,
  BLOCKED-BY zwasm's CM embedding-API freeze** — re-check each Phase boundary.
  SAFETY: every `clj` oracle batch needs `-J-Xmx2g` + bounded seqs (memory
  `clj_oracle_heap_cap`); register every new e2e in run_all.sh same-commit
  (memory `e2e-register-in-run-all`).

  **D-271 is NOT a mandate** (ADR-0134, value-driven re-amend): the finished form
  is full IObj/IMeta metable-ness, but a substrate joins membership ONLY when a
  real consumer PULLS it — NOT a speculative 13-substrate megaproject (the
  Progress-pressure/scope-escalation smell the user caught 2026-06-12). The first
  value-driven slice, IF taken: resolve IObj/IMeta as values + membership for the
  already-metable tags (clears the name_error); but datafy (the lone near-term
  puller) has OTHER blockers too (class/.getName, host-class extends,
  clojure.reflect), so verify the whole datafy load before committing to it.

  **State**: Phase 14 (v0.1.0 milestone) ~95% done. Both open §9.16 rows are
  BLOCKED — 14.12 (component build, zwasm-CM-gated → D-404) + 14.14 (exit-smoke +
  tag, user-deferred); operate in §1.5/quality-loop mode, not §9 row order (see the
  §9.16 Resume-wiring note). Full gate green on Mac (328/0; `.dev/.gate_pass`).

  **Paused (not abandoned)**: the §9.2.S perf campaign — cljw already WINS/parity vs
  Python on most benches; the 2 cold-losers (regex_count 1.8×, sieve 1.4×) + JIT are
  the remaining levers. Resume ONLY on explicit user direction; full state in
  `.dev/perf_v0_baseline.md` + `.dev/perf_campaign_essence.md` + `.dev/optimizations.md`.

- **Forbidden this session**: re-opening the §9.2.S perf campaign as the resume
  DEFAULT (paused — polish is the focus; resume perf only on explicit user
  direction); editing zwasm except via the F-001 finding-handling policy;
  `git push --force*`.

## Just landed — D-405 conformance harness + facet fixes (2026-06-13, on `main`)

scripts/lib_conformance.sh (verified_projects deps.edn as the dual-runtime
classpath SSOT; eval-quote clj batches; golden-pair + ;;DIFF[tag] corpus) and
9 corpora at 100%. The authoring drove root-cause fixes, each oracle-verified:
java.util.List value-search trio (.indexOf/.lastIndexOf/.contains semantics)
· nested-lazy print in map/set values · deftype ILookup 3-arity get ·
declared-interface class facet (instance? on remapped interfaces + zero-method
declarations) · IPersistentMap deftype map-style print (realize-ctx) ·
clojure.lang.Sorted deftype subseq/rsubseq + native Sorted/Comparator surface
· java.io.StringWriter host class · data.csv JVM shapes (seq return,
writer-first write-csv, :separator/:quote/:newline) · data.json escape
defaults (unicode/slash/js-separators, surrogate pairs) + Ratio · tools.cli
pure-clj parse-opts rewrite (Zig MVP retired). data.priority-map 60%→100%.

## Cold-start reading order (resume)

handover → **`private/notes/polish-priority-audit.md`** (the prioritized polish
wiring P1-P5) → `.claude/rules/clj_diff_sweep.md` + `.claude/rules/accepted_divergences.md`
(the F-011 sweep + classify discipline) → `.dev/debt.yaml` (D-210 floor / D-271 /
D-273 / D-232 / D-321/322/239) → `.dev/v0_v1_feature_parity.md` (P3 ns-backfill SSOT)
→ `.dev/accepted_divergences.yaml` (AD ledger). clj oracle = `~/Documents/OSS/clojure/`
(spec) + `clj -M -e` (`timeout 20`, bound seqs); v0 ref `~/Documents/MyProducts/ClojureWasm/`.
