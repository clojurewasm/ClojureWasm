# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` is the SSOT; ≈ 9e802816+). All work on `main`;
  commit + `git push origin main` is the atomic Step 6 (`--force*` deny-listed)
  — EXCEPT the component experiment below, which is push-suppressed by user
  directive. Full gate green 334/0 (2026-06-13). Build config is UNIFIED
  (ADR-0133 Rev 1+2): every e2e/bench/perf builder + manual probe uses
  `zig build -Dwasm -Doptimize=ReleaseSafe` (bare `zig build` = hand
  experiments only; it Debug-overwrites zig-out). Bench re-baselined under the
  unified config (bench/cross-lang-latest.yaml, 39 benches; D-411 discharged).

- **zwasm-watch mode (user directive 2026-06-13, supersedes the earlier
  "experiment first" contract)**: zwasm's Component-Model surface is NOT yet
  complete for CWFS — the D-404 experiment (ADR-0135 component-as-namespace)
  starts only when it is. **At every task boundary (Step 0) + session resume,
  peek `git -C ~/Documents/MyProducts/zwasm_from_scratch log --oneline -15`.**
  Readiness predicate (both must be landed): (a) zwasm ADR-0184 step 4
  (C-API preopen smoke; Status: Implemented), AND (b) the
  `TypeInfo.exportedFuncs` interface-nested function ENUMERATION chunk
  (queued right after ADR-0184; zwasm commit 2789899f names it). When BOTH
  land → next task = the D-404 experiment per
  **`private/notes/p14-wasm-component-experiment.md`** (EXPLORATION mode:
  local relative-path zon flip, uncommitted, push-suppressed). Until then →
  normal development continues on the queue below. Checked 2026-06-13: step 4
  pending, enumeration not started → NOT ready.

- **First task on resume MUST be: re-matcher + java.util.regex.Matcher
  host_instance** — design + oracle table pre-laid in
  `private/notes/p14-instaparse-campaign.md` (incl. the StringBuilder
  int-capacity-ctor bug Segment.toString hits); then instaparse end-to-end →
  verified_projects corpus; flatland.ordered corpus registration; cuerdas
  blocked on D-410.

  SAFETY: every `clj` oracle batch needs `-J-Xmx2g` + bounded seqs (memory
  `clj_oracle_heap_cap`); register every new e2e in run_all.sh same-commit.

  **State**: Phase 14 (v0.1.0 milestone) ~95% done. Both open §9.16 rows
  BLOCKED — 14.12 (component build, zwasm-CM-gated → D-404, now the active
  experiment) + 14.14 (exit-smoke + tag, user-deferred); operate in
  §1.5/quality-loop mode. Conformance ladder: 15 corpora 100% golden.

  **Paused (not abandoned)**: the §9.2.S perf campaign — resume ONLY on
  explicit user direction; state in `.dev/perf_v0_baseline.md` +
  `.dev/perf_campaign_essence.md`. NOTE for it: edn_roundtrip drifted
  ~23→~31ms between 2026-06-11 and 06-13 in BOTH build configs (real
  post-06-11 code change, not -Dwasm) — a lead worth tracing when perf resumes.

- **Forbidden this session**: pushing the component-experiment artifacts or a
  relative-path build.zig.zon (user-directed: experiment locally first);
  re-opening the §9.2.S perf campaign as the resume DEFAULT; editing zwasm
  except via the F-001 finding-handling policy; `git push --force*`; bare
  `zig build` for any scripted/probe path (ADR-0133 Rev).

## Just landed (2026-06-13, on `main`)

Build-config unification (ADR-0133 Rev 1+2): 310 e2e fallbacks + 9 bench/perf
builders → `-Dwasm -Doptimize=ReleaseSafe`; bench cw column re-baselined
(A/B: -Dwasm ~cost-free). instaparse substrate batch (d6c84985: *out*/*err*
D-238 LANDED, IObj/IMeta, Character statics). Earlier same day: D-405 harness
15 corpora, ADR-0136 boundary, D-407 proofs, Unicode D-057/D-409.

## Cold-start reading order (resume)

handover → **`private/notes/p14-instaparse-campaign.md`** (the active task:
re-matcher design + oracle table) → (when zwasm-watch fires)
`private/notes/p14-wasm-component-experiment.md` + `.dev/decisions/0135_*.md`
(WIT↔clj mapping, FROZEN) + `.dev/debt.yaml` D-404.
clj oracle = `~/Documents/OSS/clojure/` + `clj -J-Xmx2g -M` (`timeout 60`,
bound seqs); zwasm repo = `~/Documents/MyProducts/zwasm_from_scratch/`
(read-only here; readiness check via its git log per the watch predicate).
