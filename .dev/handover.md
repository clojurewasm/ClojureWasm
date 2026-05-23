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
  Phase-4-entry scaffolding wave landed 2026-05-23: 21 new ADRs
  (0004-0024; ADR-0018 amended twice for Error catalog SSOT,
  ADR-0019 Crash policy, ADR-0020 ADR governance,
  ADR-0021 Test taxonomy, ADR-0022 Differential wiring,
  ADR-0023 Comptime stub, ADR-0024 Scan framework + run_step;
  ADR-0015 amend 1 Two-tier strategy, ADR-0016 amend 1 promoted
  to Accepted with zwasm evidence), 13 new rules
  (`error_catalog_only.md`, `test_taxonomy.md`,
  `exploration_vs_done.md`, `plan_revision_thinking.md` added),
  `.dev/principle.md` (project-wide principles + Bad Smell
  catalogue, the meta layer above ROADMAP / ADRs; SSOT for
  plan-vs-reality revision triggered from
  `continue/SKILL.md` Step 1 / Step 4 / Step 6),
  `src/runtime/error_catalog.zig` (~280 lines including tests;
  the file ships under the original 28-Code names and will be
  reshaped in task 4.26 per ADR-0018 amendment 2),
  8 new scripts + `.githooks/pre-push`,
  4 new `.dev/` files (`debt.md`, `reference_clones.md`,
  `lessons/INDEX.md`, `compat_tiers.yaml`), 4 skill modifications
  (per-task TDD loop spec moved into CLAUDE.md § Autonomous
  Workflow; continue/SKILL.md is now the thin invocation trigger;
  Step 0.5 debt sweep, audit two-tier triggers,
  big-bang regeneration policy), `.claude/settings.json` PostCompact
  + Edit\|Write hooks, ROADMAP §1.4 / §A10-A24 / §3.2 / §6.0 / §9.6
  4.0-4.26.f / §11.7 / §14 / §17.4 amendments. All §9.5 / 3.1–3.14
  cells `[x]`, paired through chapter 0020 (`cc46a48`). 🔒 OrbStack
  x86_64 gate PASSED 2026-04-27 (pre-scaffolding state). Next
  re-run after Phase 4 entry commits.
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
  (zlinter Phase A+B: `no_deprecated`, `no_orelse_unreachable`,
  `no_empty_block`, `no_unused`; ADR-0003).
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

## In-flight work

なし。ACTION_PLAN V1/V2/V3/V4/V5 consolidation は 2026-05-23 完了
(audit note `private/research-2026-05-23/REVIEW_V2_V1_LEFTOVER.md`、
subagent cross-validation で賛同、新規反映項目なし)。次セッションは
`/continue` で §9.6 / 4.0 に着手。

## Active task — §9.6 / 4.0

`bench/quick.sh` + `bench/quick.yaml` + `bench/fixtures/*.clj` — the
microbench harness ROADMAP §10.2 has so far only described in policy.
This is the first §9.6 task because Phase 4 introduces the VM and
optimisation work needs a measuring stick from day one. Wired into
`test/run_all.sh` as a non-failing observability suite (records
numbers, does not assert pass/fail until §10.1 lock at Phase 8).

**Retrievable identifiers**:
- ROADMAP §9.6 — full Phase 4 task table (4.0 → 4.26.f after the V3
  scaffolding wave + ADR-0018 amendment 2 error system split).
- ROADMAP §10.2 — quick bench policy + intent.
- ROADMAP §10.3 — v0.1.0 target numbers.
- `bench/quick.sh` — already exists from Phase 1, with `# TODO(phase4)`
  placeholders. 4.0 fills those in and wires it into
  `test/run_all.sh`.

**Phase 4 task list (4.0 - 4.26.f, expanded by ADR-0004 through 0024)**:

- 4.0-4.12: bench harness, errdefer + bound check fixes, Opcode enum,
  VM compiler / dispatch / Phase-3 special forms, backend gate,
  dual-backend run, `Evaluator.compare()` CI mandatory, phase4_cli,
  exit smoke (the original V2 task set).
- 4.13: `io_interface.zig` Zone 0 vtable (ADR-0015).
- 4.14: `.dev/debt.md` operationalize.
- 4.15: `compat_tiers.yaml` expansion (full clojure.core + 40
  host_classes).
- 4.16: Wasm FFI removal (ADR-0006).
- 4.17: `TypeDescriptor` skeleton (ADR-0007).
- 4.18: Protocol dispatch table skeleton (ADR-0008).
- 4.19: Object header `u32 gc_and_lock` packed slot (ADR-0009).
- 4.20: `src/runtime/host/` directory + `_host_api.zig` (ADR-0011).
- 4.21: `deftype` / `defrecord` / `reify` / `definterface` analyzer
  recognition with structured compile error (ADR-0007).
- 4.22: `binding_stack.zig` with `threadlocal var dval_top`
  (real impl from Phase 2-3 onward).
- 4.23: `numeric/big_int.zig` struct (no arithmetic yet).
- 4.24: `lazy_seq.zig` struct (no `force()` yet).
- 4.25: `dispatch/method_table.zig` structs (no `dispatch()` yet).
- 4.0a: `build.zig` `build_options.phase_at_least_N` bool group
  (Phase 5 / 7 / 11 / 14 / 15 / 17). Scaffolding for ADR-0023
  comptime conditional imports. Tasks 4.17 / 4.19 / 4.22-4.25
  depend on it.
- 4.26.a-f: Error system migration, now six independent task rows
  (a) 28 Code rename / (b) Tier D 5 per-form Codes / (c)
  `Error` → `ClojureWasmError` rename / (d) ~116 setErrorFmt
  migration by region / (e) @panic / unreachable audit / (f)
  main() top-level catch + exit codes 0 / 1 / 70 / 130.

## Next Phase Queue (Phase 5 entry)

When Phase 4 closes, promote these to §9.7 task table per
CLAUDE.md § Autonomous Workflow "When the current phase's task
queue empties":

- HAMT persistent vector (per ADR-0007 / JVM_TO_ZIG §10)
- HAMT persistent hashmap + hashset
- Mark-sweep GC `GcHeap.collect` + roots + threshold trigger (per
  ADR-0017 / JVM_TO_ZIG §3)
- Object header bit helpers `cmpxchgLockBits` etc. (per
  ADR-0009 + D-020)
- `LazySeq.force()` + trampoline + thread-safe realisation (per
  JVM_TO_ZIG §9; uses ADR-0009 object-header bit helpers for
  thread-safe init; activates task 4.24 skeleton)
- BigInt arithmetic + promotion (per ADR-0012 + JVM_TO_ZIG §12,
  activates task 4.23 skeleton)
- `TypeDescriptor.lookupMethod` + `register` + `new`; deftype /
  defrecord / reify activation (per ADR-0007 + task 4.17 / 4.21)
- `flip build_options.phase_at_least_5 = true` (per ADR-0023 +
  task 4.0a)

## Future ADR shopping list (recall trigger via debt.md D-021)

| Future ADR | Title                                       | Trigger Phase         | Reference                                                    |
|------------|---------------------------------------------|-----------------------|--------------------------------------------------------------|
| ADR-0025   | Upstream skip taxonomy                      | Phase 11 entry        | ADR-0021 deferred-layer table; `test/clj/skip_taxonomy.yaml` |
| ADR-0026   | Golden snapshot framework                   | Phase 7+              | ADR-0021 deferred-layer table                                |
| ADR-0027   | bench/history.yaml schema                   | Phase 8 lock baseline | ROADMAP §10.1                                               |
| ADR-0028   | State machine domain (REPL / nREPL / build) | Phase 14+             | Pollaroid INSIGHTS §2                                       |

**Boundary-chain artefacts (just landed, this session)**:
- Chapter 0020 covers 3.8–3.14 + meta in 1075 lines (`cc46a48`).
- Simplify apply-now (`4ad8270`) shipped.
- `private/` cleaned of absorbed strategic dumps; `audit` and
  `continue` no longer treat `private/` as authoritative
  (`e3de44f`).
- §9.6 expanded inline in ROADMAP (this commit).

**Phase 4 entry scaffolding (just landed, this commit batch)**:

- 14 new ADRs (`.dev/decisions/0004` through `0017`) + retroactive
  Revision history added to ADR-0001/2/3 to satisfy
  `scripts/check_adr_history.sh`.
- 9 new `.claude/rules/` files in the entry batch; subsequent
  amendments brought the total to 19 rules.
- 8 new `scripts/` files + `.githooks/pre-push` zone gate.
- 4 new `.dev/` files: `debt.md`, `reference_clones.md`,
  `lessons/INDEX.md`, plus `compat_tiers.yaml` at repo root.
- 4 skill modifications: continue skill now delegates loop spec
  to CLAUDE.md § Autonomous Workflow (Step 0-8 + Stop ONLY /
  Do NOT stop / When in doubt). SKILL.md is the thin trigger.
  Step 0.5 debt sweep,
  Step 0.5 + Step 1a, `audit_scaffolding/SKILL.md` two-tier
  triggers, `code_learning_doc/SKILL.md` big-bang regeneration
  policy.
- `.claude/settings.json` PostCompact + Edit\|Write hooks.
- ROADMAP amendments (§1.4 / §A10-A24 / §3.2 / §6.0 / §9.6
  4.0-4.26.f / §11.7 / §14 per-row predicate / §17.4).

**Open questions / deferred (from DECISIONS_V2)**:

- v0.1.0 deliverable specification (minimum success criterion within
  Tier A) — finalized in Phase 11+; the SemVer rule (§1.4) holds
  independently.
- ValueTag enum slot design — ADR-0012 selected Option A (3 slot).
  Open for revisit during Phase 5 implementation if Option B
  measurements emerge.
- D02-D30 follow-up propagation (numeric tower BigDecimal Tier B,
  exception `:type` keyword, multimethod + TypeDescriptor, protocol
  + TypeDescriptor) — Phase 5-7 individual ADR amendments.

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
