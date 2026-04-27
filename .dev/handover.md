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

## Active task — open Phase 4 (§9.6)

Phase 3 closed. Phase-3 boundary review chain ran (audit / simplify /
security-review / chapter 0020); 🔒 OrbStack x86_64 gate **PASSED
2026-04-27**. Phase 4 (`VM + Compiler + Opcodes`, ROADMAP §9 line
644) now opens.

**§9.6 expand draft** (mirror §9.5 shape):

| Task | Description                                                                                                                          | Status |
|------|--------------------------------------------------------------------------------------------------------------------------------------|--------|
| 4.0  | `bench/quick.sh` + `bench/quick.yaml` + 5–6 microbench fixtures (fib / arith_loop / list_build / map_filter). ROADMAP §10.2 physical | [ ]    |
| 4.1  | analyzer `@intCast` to u16 in `analyzeLoopStar` / `analyzeRecur` — guard against >u16 bindings/args before the cast                   | [ ]    |
| 4.2  | `trackHeap`-failure leaks: add `errdefer rt.gpa.destroy(s)` after `create` in `string.alloc` / `ex_info.alloc` / `list.consHeap` / `tree_walk.allocFunction` | [ ]    |
| 4.3  | `expandAnd` / `expandOr` non-recursive fold — long `(and …)` chains must not blow the stack                                          | [ ]    |
| 4.4+ | VM scaffolding (ROADMAP §4.4 dual-backend foundation) — opcodes / compiler / VM dispatch / `Evaluator.compare()` plumbing             | [ ]    |

The first task is **4.0 bench harness**. Without this, ROADMAP §10.2
"mid-phase quick bench (4-7)" has no physical artefact and Phase 4
optimisation work can't be measured.

**Retrievable identifiers**:
- `private/notes/phase3-simplify-queue.md` — Q1–Q11 deferred items
  (some intersect 4.x work; consult per task).
- ROADMAP §10.2 / §10.3 — bench targets + v0.1.0 numbers.
- ROADMAP §4.4 — dual-backend (TreeWalk reference + VM production).
- `private/audit-2026-04-27.md` — last audit (block 0 / warn 4 / info
  13); next audit due ~Phase 5 boundary.

**3.14 + boundary chain (just landed)**:
- `test/e2e/phase3_exit.sh` exists; `bash test/run_all.sh` green at
  5/5 suites both Mac + Ubuntu x86_64.
- Chapter 0020 covers 3.8–3.14 + meta in 1075 lines.
- Simplify apply-now (`4ad8270`) + chapter (`cc46a48`) shipped.
- `private/` cleaned of absorbed strategic dumps; `audit` and
  `continue` no longer treat `private/` as authoritative.

**Post-3.11 small cleanup queued** (not blocking):
- Split `test/e2e/phase3_cli.sh` into `cli_entry.sh` (CLI plumbing
  only — 6 cases: -e / file / stdin / unknown flag / missing file /
  error label) and `lang_smoke.sh` (language semantics — macros /
  ex_info / try-catch / loop). Phase 11 will then mechanically
  migrate `lang_smoke.sh` cases to `test/clj/lang_smoke_test.clj`
  (`clojure.test` deftest) without touching `cli_entry.sh`. Wire
  both into `run_all.sh` to keep the single-entry rule intact.

## Open questions / blockers

(none — §9.6 task list is the next concrete work)

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
  chapters. Section F covers per-task note volume and audit-report
  cadence only — not strategic-note adoption (that belongs in
  ROADMAP / ADR / `docs/ja/` / handover, never in gitignored
  `private/`).
- Rule `.claude/rules/textbook-survey.md` — auto-loaded on
  `src/**/*.zig`; defines the Step 0 brief and the four anti-pull
  guardrails.
- The 🔒 marker on Phase 4 (and 5 / 8 / 14 / 15) means a fresh
  OrbStack x86_64 gate is due at that phase boundary. The gate is
  **agent-runnable** via the Bash tool:
  `orb run -m my-ubuntu-amd64 bash -c 'bash test/run_all.sh'` (set
  Bash timeout ≥ 600s for cold builds). Setup, iteration loop, and
  gate integration are documented in `.dev/orbstack-setup.md`.
