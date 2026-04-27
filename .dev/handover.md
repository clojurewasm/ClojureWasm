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

- **Phase**: Phase 3 IN-PROGRESS (§9.5). 3.1–3.8 done. 3.1–3.7 paired
  (chapters 0017 / 0018 / 0019); 3.8 is the first unpaired SHA
  awaiting its chapter. Next active task is **3.9**
  (try / catch / throw / loop\* / recur special forms).
- **Branch**: `cw-from-scratch` (long-lived; v0.5.0-derived).
- **Last paired chapter commit**: `ed470fe` (0019) covering 6630cbe
  (3.7 — macroexpand routing). Preceded by `a89e6fb` (0018) covering
  3a5f852..766a73a (3.5+3.6 — heap collection literals).
- **Unpaired source SHAs awaiting chapter**:
  - `772ebcf` (3.8 — runtime/print.zig extraction)
  Will be folded into a 3.8–3.x concept chapter — exact pairing
  decided when the next batch of related tasks closes.
- **Build**: `bash test/run_all.sh` all green —
  `zig build test`, `zone_check --gate`,
  `test/e2e/phase2_exit.sh` (3/3),
  `test/e2e/phase3_cli.sh` (21/21 — cases 12–19 cover the macros).
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

## Active task — §9.5 / 3.9

`src/eval/analyzer.zig` — add `try` / `catch` / `throw` / `loop*` /
`recur` special forms. `src/eval/node.zig` gains `try_node` /
`throw_node` / `loop_node` / `recur_node` variants. Pairs with 3.10
(ex_info heap struct) and 3.11 (TreeWalk evalTry / evalThrow /
evalLoop / evalRecur impl).

**Retrievable identifiers**:
- ROADMAP §9.5 task 3.9 (table).
- `src/eval/node.zig` — current Node tagged union surface; the four
  new variants follow the existing shape (loc + payload struct).
- `src/eval/analyzer.zig::SPECIAL_FORMS` — extend with `try`,
  `throw`, `loop*`, `recur`. `try` syntax: `(try expr* (catch
  ExceptionInfo e body*) (finally body*))` — note Clojure JVM uses
  `catch <Class> <binding> <body>`; CW v2 starts with a single
  catch class `ExceptionInfo` and revisits multi-catch in Phase 5+.
- `src/eval/analyzer.zig::Scope` — `loop*` introduces a binding
  frame the same way `let*` does, but `recur` must be tail-position
  to that frame; mark the loop in the Scope chain with a flag the
  analyzer reads.
- `eval/macro_dispatch.Table` is **not** touched — `try` / `loop*`
  are special forms, not macros.

**Exit criterion for 3.9** (analyzer-only; eval impl lands at 3.11):
- `(loop* [i 0] (if (< i 3) (recur (+ i 1)) i))` analyses to a
  `loop_node` containing the recur target.
- `(try 1 (catch ExceptionInfo e 2))` analyses to a `try_node` with
  the body Node and a single catch clause.
- `(throw x)` analyses to a `throw_node` carrying `x`.
- Tail-position `recur` outside a `loop*` / `fn*` is a syntax_error
  with the call-site loc.
- Unit tests in `analyzer.zig` cover the 3 happy paths + 2 error
  paths.

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
