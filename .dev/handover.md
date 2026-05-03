# Session handover

> Read this at session start. Update at session end (1–2 lines).
> Mutable, current-state only. Authoritative plan is `.dev/ROADMAP.md`.
> The `progress.txt` shape is intentional: future-Claude reads this in
> a fresh context window and must understand the state in < 30 seconds.

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file)
2. `.dev/ROADMAP.md` — find the IN-PROGRESS phase in §9, then its
   expanded `§9.<N>` task list; pick up the first `[ ]` task.
3. The chapter file most recently added under `docs/ja/learn_clojurewasm/` — to recover
   the conceptual baseline for the active phase.

## Current state

- **Phase**: **Phase 3 DONE; Phase 4 IN-PROGRESS, §9.6 OPEN.**
  All §9.5 / 3.1–3.14 cells `[x]`, paired through chapter 0020
  (`cc46a48`). Phase-3 boundary review chain finished (audit /
  simplify / security-review / chapter); simplify apply-now landed in
  `4ad8270`. Phase-3 security findings (H1 / H2 / H3) and ROADMAP
  §10.2 bench harness (G4 physical) are now §9.6 tasks 4.0–4.3 —
  full task table lives in `.dev/ROADMAP.md` §9.6. 🔒 OrbStack
  x86_64 gate **PASSED 2026-04-27**. No blockers.
- **Branch**: `cw-from-scratch` (long-lived; v0.5.0-derived).
- **Last paired chapter commit**: `cc46a48` (0020 — Phase 3 の閉幕)
  covering all of `772ebcf` `28c2bc3` `c16380f` `99efd07` `a1a70aa`
  `f725f58` `22881a1` `8e63134` `399cb31` `4ad8270` (3.8–3.14 + meta
  + simplify pass, ten SHAs in one chapter to satisfy the gate's
  "every unpaired SHA since the last doc" rule).
- **Unpaired source SHAs awaiting chapter**: none.
- **Build**: `bash test/run_all.sh` all green on **both Mac
  (aarch64-darwin) and OrbStack Ubuntu x86_64** —
  `zig build test`, `zone_check --gate`,
  `test/e2e/phase2_exit.sh` (3/3),
  `test/e2e/phase3_cli.sh` (30/30 — cases 24–30 cover loop/recur,
  try/throw/catch, finally side-effect, lexical closure, bootstrap
  `not`, `defn` macro single+multi-body),
  `test/e2e/phase3_exit.sh` (2/2 — Phase-3 exit smoke).
  Mac runs additionally pass `zig build lint -- --max-warnings 0`
  (zlinter `no_deprecated`; ADR-0003).
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

## Active task — §9.6 / 4.0

`bench/quick.sh` + `bench/quick.yaml` + `bench/fixtures/*.clj` — the
microbench harness ROADMAP §10.2 has so far only described in policy.
This is the first §9.6 task because Phase 4 introduces the VM and
optimisation work needs a measuring stick from day one. Wired into
`test/run_all.sh` as a non-failing observability suite (records
numbers, does not assert pass/fail until §10.1 lock at Phase 8).

**Retrievable identifiers**:
- ROADMAP §9.6 — full Phase 4 task table (4.0 → 4.12).
- ROADMAP §10.2 — quick bench policy + intent.
- ROADMAP §10.3 — v0.1.0 target numbers (the harness should make
  these comparable; absolute numbers will move with the VM).
- `bench/quick.sh` — already exists from Phase 1, with `# TODO(phase4)`
  placeholders at lines 94-97. 4.0 fills those in and wires the
  script into `test/run_all.sh` (currently not wired).
- `private/notes/phase3-simplify-queue.md` — Q1–Q11 deferred items
  from the Phase-3 boundary simplify pass; some intersect 4.x work,
  consult per task. (gitignored — present on this machine only)

**Boundary-chain artefacts (just landed, this session)**:
- Chapter 0020 covers 3.8–3.14 + meta in 1075 lines (`cc46a48`).
- Simplify apply-now (`4ad8270`) shipped.
- `private/` cleaned of absorbed strategic dumps; `audit` and
  `continue` no longer treat `private/` as authoritative
  (`e3de44f`).
- §9.6 expanded inline in ROADMAP (this commit).

**Phase-3 → Phase-4 reading pause (active 2026-04-27)**:
The user is reading chapters 0001–0020 before Phase 4 opens, to
keep up with the agent's pace. Implications for the next agent
session:

- Do **not** auto-start Phase 4 / §9.6 / 4.0 work on `/continue` —
  wait for the user's explicit go signal after the reading pass.
- Chapters 0001–0020 are all prose-polished — 0001–0019 through
  commit `5711ce4`, 0020 through commit `7fcaef9`. The reader sees a
  consistent style across the full Phase-3 arc.
- No agent task is required during the pause; resume signal opens
  Phase 4 / §9.6 / 4.0.
- Resume guide: `private/READING_GUIDE.md` (gitignored, scratch).

**Post-3.11 small cleanup queued** (not blocking, picked up in §9.6
or later):
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
- Skill `code_learning_doc` is **two-cadence**: per-task notes
  (private, gitignored) and per-concept chapters (`docs/ja/learn_clojurewasm/NNNN_*.md`,
  gated). Use `TEMPLATE_TASK_NOTE.md` and `TEMPLATE_PHASE_DOC.md`. Do
  **not** revert to the old "diary per phase" shape.
- Skill `audit_scaffolding` runs at every Phase boundary or every ~10
  chapters. Section F covers per-task note volume and audit-report
  cadence only — not strategic-note adoption (that belongs in
  ROADMAP / ADR / `docs/ja/` / handover, never in gitignored
  `private/`).
- Rule `.claude/rules/textbook_survey.md` — auto-loaded on
  `src/**/*.zig`; defines the Step 0 brief and the four anti-pull
  guardrails.
- The 🔒 marker on Phase 4 (and 5 / 8 / 14 / 15) means a fresh
  OrbStack x86_64 gate is due at that phase boundary. The gate is
  **agent-runnable** via the Bash tool:
  `orb run -m my-ubuntu-amd64 bash -c 'bash test/run_all.sh'` (set
  Bash timeout ≥ 600s for cold builds). Setup, iteration loop, and
  gate integration are documented in `.dev/orbstack_setup.md`.
