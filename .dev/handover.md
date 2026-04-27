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

- **Phase**: Phase 3 IN-PROGRESS (§9.5). **3.1–3.14 source done.**
  3.1–3.7 paired (chapters 0017 / 0018 / 0019); 3.8 + 3.9 + 3.10 +
  3.11 + 3.12 + 3.13 + 3.14 are unpaired source SHAs awaiting
  chapter(s) 0020 (error handling + iteration: 3.8–3.11) and 0021
  (bootstrap mechanism + Phase-3 exit: 3.12–3.14). Phase-3 boundary
  review chain (audit / simplify / security-review / chapter writing)
  is the next move; after chapters land and §9.5 task table flips
  to all `[x]`, Phase 3 → DONE / Phase 4 → IN-PROGRESS (🔒 OrbStack
  x86_64 gate due before Phase 4.1).
- **Branch**: `cw-from-scratch` (long-lived; v0.5.0-derived).
- **Last paired chapter commit**: `ed470fe` (0019) covering 6630cbe
  (3.7 — macroexpand routing). Preceded by `a89e6fb` (0018) covering
  3a5f852..766a73a (3.5+3.6 — heap collection literals).
- **Unpaired source SHAs awaiting chapter**:
  - `772ebcf` (3.8 — runtime/print.zig extraction)
  - `28c2bc3` (3.9 — try/catch/throw/loop\*/recur Node + analyzer)
  - `c16380f` (3.10 — ex_info heap struct + builtins)
  - `99efd07` (3.11 — treeWalk evalLoop/evalRecur/evalTry/evalThrow
    + fn closure capture)
  - `a1a70aa` (3.12 — Stage-1 bootstrap module + minimal core.clj)
  - `f725f58` (3.13a — wire bootstrap.loadCore into main.zig startup)
  - `22881a1` (3.13b — `defn` Zig macro transform)
  - `8e63134` (meta — §17 amendment policy + ADR 0002; **not** a
    source SHA, but mention in chapter 0021 since it explains why
    §9.5/3.14 uses `0` instead of `{}`)
  - `399cb31` (3.14 — `test/e2e/phase3_exit.sh` + run_all.sh wiring)
  Plan: chapter 0020 covers 3.8 + 3.9 + 3.10 + 3.11 as one phase-3
  "error handling and iteration" concept block; chapter 0021 covers
  3.12 + 3.13 + 3.14 as "bootstrap mechanism + Phase-3 exit", with a
  short callout to ADR 0002 / §17 amendment policy.
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

## Active task — Phase-3 boundary review chain

All Phase-3 source has landed (3.1–3.14). Next move is the §`continue`
Phase-boundary review chain:

1. `audit-scaffolding` slash command on the project as a whole; only
   `block`-severity findings stop the loop.
2. **Multi-agent fan-out** (parallel):
   - Subagent A: `simplify` on `git diff <phase-start>..HEAD -- src/`.
   - Subagent B: `security-review` on unpushed commits.
   - Subagent C: write outstanding chapters 0020 + 0021 from the
     `private/notes/phase3-3.{8..14}.md` task notes.
3. After chapters commit, flip the §9.5 task table cells `[ ]` → `[x]`
   for 3.8–3.14 with their source SHAs, and flip the §9 phase table
   row Phase 3 → DONE / Phase 4 → IN-PROGRESS, then expand §9.6
   inline.
4. Re-run the OrbStack x86_64 gate (🔒) before opening Phase 4.1:
   `orb run -m my-ubuntu-amd64 bash -c 'cd <project> &&
   bash test/run_all.sh'`.
5. Surface any unadopted strategic notes from `private/` and
   escalate to the user before starting §9.6 / 4.1.

**Retrievable identifiers**:
- `private/notes/phase3-3.8.md` … `phase3-3.14.md` — chapter source.
- `.claude/skills/code-learning-doc/TEMPLATE_PHASE_DOC.md` — template.
- `scripts/check_learning_doc.sh` — pairing gate; chapter `commits:`
  frontmatter must list every unpaired Phase-3 source SHA.
- `.claude/skills/audit-scaffolding/CHECKS.md` — audit checks A1–F.

**3.14 (just landed)**:
- `test/e2e/phase3_exit.sh` exists; both exit assertions pass.
- `bash test/run_all.sh` green at 5/5 suites.

**Post-3.11 small cleanup queued** (not blocking):
- Split `test/e2e/phase3_cli.sh` into `cli_entry.sh` (CLI plumbing
  only — 6 cases: -e / file / stdin / unknown flag / missing file /
  error label) and `lang_smoke.sh` (language semantics — macros /
  ex_info / try-catch / loop). Phase 11 will then mechanically
  migrate `lang_smoke.sh` cases to `test/clj/lang_smoke_test.clj`
  (`clojure.test` deftest) without touching `cli_entry.sh`. Wire
  both into `run_all.sh` to keep the single-entry rule intact.

## Open questions / blockers

(none)

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
- The 🔒 marker on Phase 4 means a fresh OrbStack x86_64 gate is due
  at the Phase-3 → Phase-4 boundary (re-run the same `orb run -m
  my-ubuntu-amd64 bash -c 'bash test/run_all.sh'` invocation).
