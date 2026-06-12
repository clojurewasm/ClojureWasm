# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` is the SSOT; ≈ 82c22418). All work on `main`;
  commit + `git push origin main` is the atomic Step 6 (`--force*` deny-listed).
  Gate cadence ADR-0107: per-commit smoke (background), batch the full gate ALONE
  at the ≤5 ceiling / boundary. Full gate FRESH-GREEN 334/0 (2026-06-13,
  `.dev/.gate_pass`, cadence counter 0). Manual probes: `zig build -Dwasm
  -Doptimize=ReleaseSafe` (= the gate config, cache-hits; ADR-0133 Revision
  2026-06-13 unified all 310 e2e standalone fallbacks to this form — never
  bare `zig build`, it Debug-overwrites zig-out).

- **First commit on resume MUST be: implement `re-matcher` +
  java.util.regex.Matcher as a host_instance container** — the next layer of
  the instaparse campaign (gll.cljc:746 blocks on it). The FULL design is
  pre-laid in `private/notes/p14-instaparse-campaign.md`: oracle-verified JVM
  Matcher semantics table (lookingAt/group/find/start/end/empty-match
  advance), state layout (regex/input/MutState slots + host_trace per
  Iterator.zig precedent), the `.matcher`-on-.regex dispatch arm
  (clojure_lang_method.zig), core.clj re-matcher/re-groups/re-find 1-arity
  defs, and the two StringBuilder fixes Segment.toString needs (int-capacity
  ctor currently appends digits — BUG; 4-arity .append). TDD Red =
  test/e2e/phase14_re_matcher.sh from the note's oracle table (+ run_all.sh
  registration same-commit). Then: instaparse end-to-end probe →
  verified_projects/instaparse corpus; flatland.ordered verified_projects +
  corpus (probe already green, only the registration is missing); cuerdas
  stays blocked on D-410 (BreakIterator).

  SAFETY: every `clj` oracle batch needs `-J-Xmx2g` + bounded seqs (memory
  `clj_oracle_heap_cap`); register every new e2e in run_all.sh same-commit.

  **State**: Phase 14 (v0.1.0 milestone) ~95% done. Both open §9.16 rows are
  BLOCKED — 14.12 (component build, zwasm-CM-gated → D-404) + 14.14 (exit-smoke
  + tag, user-deferred); operate in §1.5/quality-loop mode, not §9 row order.
  Library-conformance ladder: 15 corpora 100% golden (`scripts/lib_conformance.sh
  --all`); instaparse is the active campaign.

  **Paused (not abandoned)**: the §9.2.S perf campaign — resume ONLY on explicit
  user direction; state in `.dev/perf_v0_baseline.md` + `.dev/perf_campaign_essence.md`.

- **Forbidden this session**: re-opening the §9.2.S perf campaign as the resume
  DEFAULT; editing zwasm except via the F-001 finding-handling policy;
  `git push --force*`; bare `zig build` for any manual probe (ADR-0133 Rev).

## Just landed (2026-06-13, on `main`)

instaparse substrate batch (d6c84985: *out*/*err* rebinding = D-238 LANDED,
IObj/IMeta membership slice, Character codePointAt/toChars; e2e
phase14_instaparse_substrate) + ADR-0133 Revision (029b058e: D-411 bench-half
debt, D-238 flip) + the 310-file e2e build-fallback unification (82c22418).
Earlier same day: D-405 harness 15 corpora / D-400 markers / D-406 boundary
ADR-0136 / D-407 proofs / D-057+D-409 Unicode / cl-format subset.

## Stopped — user requested

User instruction (2026-06-13): 「週次 rate limit が近いので、次のクリア
セッションが /continue だけで継続できるよう配線・参照チェーンを監査して
停止してください」. Wiring audited this session: Resume contract above names
the exact next TDD cycle; the design + oracle table live in
`private/notes/p14-instaparse-campaign.md` (incl. the extended-challenge
3-item set); debt rows D-238/D-410/D-411 synced; full gate fresh-green
334/0 with cadence 0. Resume = `/continue` (this section is history, not a
directive — the next session deletes it per handover_framing.md).

## Cold-start reading order (resume)

handover → **`private/notes/p14-instaparse-campaign.md`** (the pre-laid
re-matcher design + oracle table + campaign queue) →
`.claude/rules/clj_diff_sweep.md` + `.claude/rules/accepted_divergences.md`
(the F-011 sweep + classify discipline) → `.dev/debt.yaml` (D-410/D-411/D-408)
→ `.dev/accepted_divergences.yaml` (AD ledger). clj oracle =
`~/Documents/OSS/clojure/` (spec) + `clj -J-Xmx2g -M` (`timeout 60`, bound
seqs); v0 ref `~/Documents/MyProducts/ClojureWasm/`.
