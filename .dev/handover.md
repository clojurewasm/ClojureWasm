# Session handover

> Read this at session start. Update at session end (1–2 lines).
> Mutable, current-state only. Authoritative plan is `.dev/ROADMAP.md`.
> The `progress.txt` shape is intentional: future-Claude reads this in
> a fresh context window and must understand the state in < 30 seconds.

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file)
2. `.dev/ROADMAP.md` — find the IN-PROGRESS phase in §9, then its
   expanded `§9.<N>` task list; pick up the first `[ ]` task.
3. The chapter file most recently added under `docs/ja/` — to recover
   the conceptual baseline for the active phase.

## Current state

- **Phase**: **Phase 3 DONE; Phase 4 IN-PROGRESS but not yet OPEN.**
  All §9.5 / 3.1–3.14 cells `[x]` with source SHAs paired through
  chapter 0020. Phase-3 boundary review chain ran (audit / simplify /
  security-review / chapter): block 0; 3 simplify apply-now landed
  in `4ad8270`; 3 security findings (H1 `@intCast` panic in analyzer
  loop*/recur; H2 trackHeap-failure leak across 4 heap allocators;
  H3 `(and ...) `/`(or ...)` deep-recursion stack overflow) **queued
  for early Phase 4** before any push. **Phase 4 §9.6 expand is
  blocked on user judgement on three items** (see "Open questions"
  below).
- **Branch**: `cw-from-scratch` (long-lived; v0.5.0-derived).
- **Last paired chapter commit**: `cc46a48` (0020 — Phase 3 の閉幕)
  covering all of `772ebcf` `28c2bc3` `c16380f` `99efd07` `a1a70aa`
  `f725f58` `22881a1` `8e63134` `399cb31` `4ad8270` (3.8–3.14 + meta
  + simplify pass, ten SHAs in one chapter to satisfy the gate's
  "every unpaired SHA since the last doc" rule).
- **Unpaired source SHAs awaiting chapter**: none.
- **Build**: `bash test/run_all.sh` all green —
  `zig build test`, `zone_check --gate`,
  `test/e2e/phase2_exit.sh` (3/3),
  `test/e2e/phase3_cli.sh` (27/27 — cases 24–27 cover loop/recur,
  try/throw/catch, finally side-effect, lexical closure).
- **End-to-end error rendering activated** (3.1–3.4):
  `cljw -e '(+ 1 :foo)'` prints `<-e>:1:0: type_error [eval]\n
  (+ 1 :foo)\n  ^\n+: expected number, got keyword`. Reader /
  Analyzer / TreeWalk + primitives all route through `setErrorFmt`.
- **Heap collection Values activated** (3.5–3.6):
  `cljw -e '"hello"'` → `"hello"`. `cljw - <<<'(quote (1 :a "b"))'`
  → `(1 :a "b")`. `(quote ())` → `nil` (deviation from JVM Clojure;
  see private/notes/phase3-3.6.md for the Phase 8+ follow-up).
- **Bootstrap macros activated (3.7)**: `let / when / cond / -> /
  ->> / and / or / if-let / when-let` expand at analyse time via
  `eval/macro_dispatch.Table` (Layer 1) populated by
  `lang/macro_transforms.registerInto` (Layer 2). **`Runtime.vtable
  .expandMacro` was removed** — macro expansion is no longer a
  backend concern (ADR 0001). `Runtime` gained
  `gensym(arena, prefix)` for hygienic auto-symbols.

## Active task — wait for user judgement, then open Phase 4 (§9.6)

Phase-3 boundary review chain ran. **Three escalations are blocking
§9.6 expand**:

1. **G1 / G2 / G4 strategic-note adoption** (audit Section F flagged
   as "deadlines passed"). User must choose per-item: `draft` (open
   the proposed design doc now) / `re-defer` (push deadline forward
   with new trigger) / `close` (reject and remove from `private/`):
   - **G1**: `private/2026-04-27_strategic_review/02_plan_review.md`
     §G1 — concurrency_design.md (atom / agent / future / promise /
     pmap design). Original deadline: "Phase 3 着手前". Phase 3 is now
     done; G1 deferred indefinitely.
   - **G2**: same file §G2 — wasm_strategy.md (Component Model +
     Pod escape hatch + WIT timeline). Original deadline: same.
   - **G4**: same file §G4 — perf_baselines.md / bench harness.
     Original deadline: "Phase 4 着手前". **Most time-sensitive: Phase
     4 is what we are about to open.** Without G4, ROADMAP §10.2
     "mid-phase quick bench (4-7)" has no harness.
2. **🔒 OrbStack x86_64 gate — PASSED 2026-04-27**. Ran
   `orb run -m my-ubuntu-amd64 bash -c 'bash test/run_all.sh'` from
   the project root inside the working directory; all 5 suites green
   on Linux ubuntu questing amd64. Phase 4.1 may proceed once items
   1 + 3 below are resolved.
3. **Three security findings (H1/H2/H3)** queued from boundary
   security-review — should land as the first source commits in
   §9.6 / 4.0 (or 4.1 prelude) before any external behaviour change:
   - H1: analyzer `@intCast` to u16 in `analyzeLoopStar` (line 678)
     and `analyzeRecur` (line 737) panics on >65k bindings/args.
   - H2: `trackHeap`-failure leaks across `string.alloc`,
     `ex_info.alloc`, `list.consHeap`, `tree_walk.allocFunction` —
     uniform fix is `errdefer rt.gpa.destroy(s)` after the `create`.
   - H3: `expandAnd` / `expandOr` re-recursive expansion blows the
     stack on long `(and …)` chains — rewrite as a single
     non-recursive expansion or gate analyze depth.

After all three are resolved, expand §9.6 inline (mirror §9.5
shape) starting from the security fixes as 4.0.x or 4.1, then move
into VM scaffolding (§4.4 dual-backend foundation).

**Retrievable identifiers**:
- `private/audit-2026-04-27.md` — full audit report (block 0 / warn 4
  / info 13).
- `private/notes/phase3-simplify-queue.md` — Q1–Q11 deferred items.
- ROADMAP §10.2, §11.5 — bench harness + cross-platform gate context.

**3.14 + boundary chain (just landed)**:
- `test/e2e/phase3_exit.sh` exists; `bash test/run_all.sh` green at
  5/5 suites.
- Chapter 0020 covers 3.8–3.14 + meta in 1075 lines.
- Simplify apply-now (`4ad8270`) + chapter (`cc46a48`) shipped.

**Post-3.11 small cleanup queued** (not blocking):
- Split `test/e2e/phase3_cli.sh` into `cli_entry.sh` (CLI plumbing
  only — 6 cases: -e / file / stdin / unknown flag / missing file /
  error label) and `lang_smoke.sh` (language semantics — macros /
  ex_info / try-catch / loop). Phase 11 will then mechanically
  migrate `lang_smoke.sh` cases to `test/clj/lang_smoke_test.clj`
  (`clojure.test` deftest) without touching `cli_entry.sh`. Wire
  both into `run_all.sh` to keep the single-entry rule intact.

## Open questions / blockers

- G1 / G2 / G4 strategic-note adoption (see Active task §1).
- ~~🔒 OrbStack x86_64 gate run~~ (passed 2026-04-27).
- H1 / H2 / H3 security findings — queued for §9.6 / 4.0 prelude
  (see Active task §3).

## Strategic notes in `private/` to consider for future phases

The `/continue` resume procedure surfaces these; not all need action
right now, but they should not be lost. Each is one line — read the
file for detail.

- `private/2026-04-27_strategic_review/01_design_insights.md` — v1
  retrospective + Clojure semantics + Wasm/Edge 2026 + Zig 0.16.
- `private/2026-04-27_strategic_review/02_plan_review.md` — five
  strategic gaps (G1: concurrency design doc; G2: Wasm strategy
  decision; G3: decisions.md D1-D20 retroactive entries; G4: Phase 4-7
  bench harness; G5: fused-reduce design doc).
- `private/2026-04-27_strategic_review/03_ecosystem_and_architecture.md`
  — Tier system, InterOp deep module (3-entry interface; case 1+3
  hybrid), Wasm Component pod escape hatch.
- `private/2026-04-27_strategic_review/04_phase2_audit_and_meta_review.md`
  — meta review: educational-doc taste, autonomous-loop best practices,
  the backlog B1–B12 that produced the 2026-04-27 framework rewrite.

Adoption decisions for any of these = ADR-level → escalate to user
before proceeding.

## Notes for the next session

- Skill `continue` (`.claude/skills/continue/SKILL.md`) handles
  "続けて" / "/continue" / "resume". It auto-triggers on those phrases
  and now drives a Step 0 (Survey) → Step 7 (per-task note) →
  Step 8 (60% compact gate) loop with multi-agent fan-out at phase
  boundaries.
- Skill `code-learning-doc` is **two-cadence**: per-task notes
  (private, gitignored) and per-concept chapters (`docs/ja/NNNN-*.md`,
  gated). Use `TEMPLATE_TASK_NOTE.md` and `TEMPLATE_PHASE_DOC.md`. Do
  **not** revert to the old "diary per phase" shape.
- Skill `audit-scaffolding` runs at every Phase boundary or every ~10
  chapters. Section F now checks unadopted strategic notes in
  `private/`.
- Rule `.claude/rules/textbook-survey.md` — auto-loaded on
  `src/**/*.zig`; defines the Step 0 brief and the four anti-pull
  guardrails.
- The 🔒 marker on Phase 4 (and 5 / 8 / 14 / 15) means a fresh
  OrbStack x86_64 gate is due at that phase boundary. The gate is
  **agent-runnable** via the Bash tool:
  `orb run -m my-ubuntu-amd64 bash -c 'bash test/run_all.sh'` (set
  Bash timeout ≥ 600s for cold builds). Setup, iteration loop, and
  gate integration are documented in `.dev/orbstack-setup.md`.
