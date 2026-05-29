# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (≈ `0c133274`). The **interop-coverage cluster is
  CLOSED**: `.instance_member` (129309be, ADR-0050 am1) + `java.lang.Math`
  static + `java.lang.*` auto-import (c1ebe0c5, §A26 q1) + `.static_method` VM
  lowering (b4f8cdf7, ADR-0050 am2 / D-130 discharged). Also landed the
  overnight self-perpetuation hook (`scripts/gate_continue_remind.sh`, 0c133274).
  Mac gate 111/111.
- **First commit on resume MUST be**: **D-076 destructuring — cycle 1
  (sequential, `let` only)**. Today cljw's `let*`/`fn*`/`loop*` bind plain
  symbols only (`bindings.zig analyzeLetStar` raises `.binding_name_not_symbol`
  on a vector pattern). Lower in **Layer 1** by extending `expandLet`
  (`src/lang/macro_transforms.zig` ~119, today a trivial `let`→`let*` rename)
  to rewrite sequential patterns into plain-symbol `let*` bindings + `nth`/
  `nthnext` — the JVM `clojure.core/destructure` shape, but as a Zig Form
  transform (NOT `.clj`: `let`/`fn` are already Zig macros, so a `.clj`
  `destructure` would hit bootstrap-order fragility). Cycle 1 covers `[a b]`,
  `[a b & rest]`, `[a b :as all]`, nested `[[a b] c]`; keep the all-symbols
  fast path untouched (zero regression). **Prerequisite**: add `nthnext`/
  `nthrest` to `core.clj` (absent today; one-liners over `drop`+`seq`).
  Smallest red test: `(let [[a b] [1 2]] (+ a b))` → 3. Survey +
  Step 0.6 done: `private/notes/phaseA26-d076-destructure-survey.md`.
- **Forbidden this session**: re-opening interop (instance_member/Math/static
  all DONE — cluster closed). Putting destructure in a `.clj` macro or in
  analyzer binding logic (Layer 1 `expandLet` Form-transform is the single
  home — cw v0's dual analyzer+`.clj` impl drifted; do not repeat). Scoping
  cycle 1 beyond sequential `let` (associative `{:keys}` / fn-param / `loop*`
  are deferred follow-up debt rows). Flipping `phase_at_least_14` / tagging
  v0.1.0 (release HELD). Opening Phase 15 (concurrency/STM) at session-tail —
  it deserves a fresh-context entry; coverage-floor (D-076) is the JIT
  prerequisite (D-133) and the right interim work.

## Current state

Phase 14 v0.1.0 substantive work DONE; release HELD. Mac gate 111/111.
Interop coverage cluster CLOSED across both backends (instance member +
field, native String methods, Java static methods + `java.lang.*` auto-
import, `.static_method` VM lowering). Now advancing the coverage floor
(D-133, the JIT prerequisite): destructuring (D-076) is the next gap.
F-010-ordered gaps (JIT / nREPL / line-editor / Wasm-Component / deps)
deferred. Overnight loop self-perpetuates via the commit + gate reminder
hooks (`scripts/{post_commit_remind,gate_continue_remind}.sh`).

## Next milestone (F-010 M = Phase 15 完遂 + cw-v0-level JIT)

Coverage floor (D-133 prereq for the JIT): D-076 destructuring (next) +
core-cluster residuals → **Phase 15** (concurrency; STM/agents/locking,
ADRs 0009/0010; unblocks D-117/D-118 nREPL — a fresh-context entry) →
superinstruction/fusion → narrow ARM64 JIT (D-133) → **M** →
quality-elevation loop (`docs/works/`). cw-v0 gap plan in
`.dev/cw_v0_parity_and_gap_plan.md` (§A26).

## Open debts (named; full rows in `.dev/debt.md`)

- **D-076** destructuring (cycle 1 = sequential `let`; assoc/fn-param/loop*
  deferred). **D-150** VM `op_ctor_call` cljw-prefix parity gap. **D-148**
  `Math/PI`/`Math/E` static-field read. **D-149** whole-float `.0` print.
  **D-147** `fn*` self-name slot. **D-134** clojure.core (`partition` 4-arg
  pad + comp/juxt multi-arity). **D-143** apply multi-arity spread.
  **D-142** Env-scope `*error-context*`. **D-141** bench multi-lock.
  **D-105/D-106** time/net+crypto. **D-116** line-editor. **D-117/D-118**
  nREPL (Phase-15-gated). **D-075** metadata. **D-133** JIT floor.

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow + § The
only stop) → `.dev/project_facts.md` (esp. F-010) → `.dev/principle.md`
→ `private/notes/phaseA26-d076-destructure-survey.md` (the active task's
survey + Step 0.6) → `src/lang/macro_transforms.zig` (`expandLet` ~119,
the lowering site) + `src/eval/analyzer/bindings.zig` (`analyzeLetStar`,
the plain-symbol target) → ROADMAP §A26 + `.dev/cw_v0_parity_and_gap_plan.md`.
