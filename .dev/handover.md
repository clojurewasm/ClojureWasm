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

- **Phase**: Phase 3 IN-PROGRESS (§9.5). 3.1–3.10 done. 3.1–3.7 paired
  (chapters 0017 / 0018 / 0019); 3.8 + 3.9 + 3.10 are unpaired source
  SHAs awaiting chapter 0020 (planned: "error handling and iteration"
  block covering print-extract + try/loop/recur analyzer + ex_info,
  to land alongside or just after 3.11). Next active task is
  **3.11** (TreeWalk `evalLoop` / `evalRecur` / `evalTry` /
  `evalThrow` + closure capture for `fn*`).
- **Branch**: `cw-from-scratch` (long-lived; v0.5.0-derived).
- **Last paired chapter commit**: `ed470fe` (0019) covering 6630cbe
  (3.7 — macroexpand routing). Preceded by `a89e6fb` (0018) covering
  3a5f852..766a73a (3.5+3.6 — heap collection literals).
- **Unpaired source SHAs awaiting chapter**:
  - `772ebcf` (3.8 — runtime/print.zig extraction)
  - `28c2bc3` (3.9 — try/catch/throw/loop\*/recur Node + analyzer)
  - `c16380f` (3.10 — ex_info heap struct + builtins)
  Plan: chapter 0020 covers 3.8 + 3.9 + 3.10 + 3.11 as one phase-3
  "error handling and iteration" concept block once 3.11 closes.
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

## Active task — §9.5 / 3.11

`src/eval/backend/tree_walk.zig` — implement the four eval-time
arms 3.9 left as `not_implemented`:

- `evalLoop` — set up bindings (mirrors `evalLet`), then loop:
  evaluate body; on `pending_recur` signal, rebind slots and re-enter.
- `evalRecur` — populate threadlocal `pending_recur_args` (a fixed
  buffer per Runtime?) and bubble `error.PendingRecur` up to the
  nearest target frame. Decide buffer ownership (per-Runtime fixed
  array vs ArrayList) — favour the fixed buffer for Phase 3.
- `evalTry` — eval body; if it returns `error.ThrownValue`, walk
  catch_clauses linearly comparing `class_name` to the thrown
  Value's tag (Phase 3.10 surface: `"ExceptionInfo"` ↔
  `Value.tag() == .ex_info`); on match, bind to slot and eval body.
  Always run finally_body (even on success) before returning /
  rethrowing.
- `evalThrow` — eval expr; populate threadlocal
  `last_thrown_exception` with the result; return
  `error.ThrownValue` so the unwind can find a try frame.
- **Closure capture for `fn*`** — current `allocFunction` snapshots
  zero locals; switch to copying the `LocalRef` slots referenced by
  the body into the function struct so inner fns close over outer
  let bindings. Phase 3 exit criterion `(defn f [x] (+ x 1)) (f 2)`
  requires no closure (single-frame), but `((fn* [x] (fn* [y] (+ x
  y))) 1) 2)` does — schedule cleanly so the fix stays in scope.

**Retrievable identifiers**:
- ROADMAP §9.5 task 3.11 (table).
- `src/eval/backend/tree_walk.zig::eval` switch — 4 arms currently
  `not_implemented`. `MAX_LOCALS = 256` is the local-array length;
  recur slot rewrite stays inside that bound.
- `runtime/dispatch.zig::last_thrown_exception` (already declared
  threadlocal as `?Value`) — populated by evalThrow, drained by
  evalTry's catch dispatch.
- `runtime/collection/ex_info.zig` — Phase 3.10 surface; evalTry
  uses `Value.tag() == .ex_info` to recognise the catch class
  `"ExceptionInfo"`.
- `src/eval/analyzer.zig::Scope.recur_target` — already populated
  for fn* and loop*; Phase 3.11 doesn't change the analyser, but
  consult it when deciding whether tail-position enforcement should
  ride along.

**Exit criterion for 3.11**:
- `cljw -e '(loop* [i 0 acc 0] (if (< i 10) (recur (+ i 1) (+ acc i)) acc))'` → `45`.
- `cljw -e '(try (throw (ex-info "boom" 0)) (catch ExceptionInfo e (ex-message e)))'` → `"boom"`.
- `cljw -e '(try 1 (finally (def *side* 42)))'` → `1` and the
  `*side*` Var ends up with value `42`.
- Closure: `cljw -e '(((fn* [x] (fn* [y] (+ x y))) 3) 4)'` → `7`.
- e2e cases pinned in `test/e2e/phase3_cli.sh`.

**ADR-light decision points to settle in 3.11's Step 0 survey**:
1. **Closure capture mechanism for `fn*`**: slot-vector snapshot
   (copy referenced outer-frame slots into a Function-attached array
   at `allocFunction` time) vs free-var-list (analyser computes the
   free-var set, body-time `LocalRef` looks them up). v1 picks one of
   these — survey decides which fits CW v2's per-frame locals model.
2. **`recur` signal**: Zig `error.PendingRecur` + threadlocal
   `pending_recur_args` buffer (mirrors the existing
   `last_thrown_exception` shape) vs a non-error threadlocal flag
   that `evalLoop` polls after each body iteration. Error-based is
   simpler to unwind through nested `if` / `let*` but breaks the
   Zig invariant "errors are unusual".

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
