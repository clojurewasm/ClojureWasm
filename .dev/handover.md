# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `0a20028c` (clean tree, all pushed). Row 14.13 closed +
  row 14.14 (a)/ROADMAP-sync landed 2026-05-29 — see `git log`.
- **First commit on resume MUST be**: **D-144** (authoritative next
  task — use THIS, not a §9 first-`[ ]` scan; see Forbidden). User
  `(throw (ex-info …))` renders a degraded EDN event (`:kind :unknown`,
  `:message "ThrownValue"`, NO `*error-context*`) because it bypasses
  `setErrorFmt`. Extend `renderError` (`src/app/error_render.zig`): when
  `Info` is null but `dispatch.last_thrown_exception` is set, build an
  Info from the ex-info (kind from `:type`, message from `ex-message`,
  data from `ex-data`) + snapshot `*error-context*` (frame is live at
  throw time, before `evalThrow` unwind). Completes the with-context
  read-side for user throws (the area cw v1 already leads cw v0). Has a
  design dimension (ex-info→Info mapping) — survey skippable (extends
  this session's error subsystem), but pick the mapping deliberately.
- **v0.1.0 release is HELD** (user decision 2026-05-29: "Hold v0.1.0;
  continue other work"): row 14.14 (b) flip `phase_at_least_14` + (c)
  tag v0.1.0 are deferred (outward publish + ubuntunote-gate
  prerequisite). Row 14.14 (a) exit-smoke DONE
  (`test/e2e/phase14_exit_smoke.sh`); ROADMAP §9.16 synced to ADR-0015
  a5 (the flip is an inert milestone marker — `io/stub.zig` never
  existed; F142/F143/F144 landed ungated).
- **Forbidden this session**: re-opening row 14.13 (DONE). Flipping
  `phase_at_least_14` / tagging v0.1.0 (release HELD by user). Treating
  §9.16 `[ ]` rows **14.12** (deferred — zwasm-v2 gate, F-010) or
  **14.14** (release, held) as the next task — the next task is D-144
  (MUST-be above), NOT the §9 first-`[ ]` scan.

## Current state

Phase 14 v0.1.0 substantive work DONE; release HELD. Mac gate **106/106**
green (`/tmp/gate_smoke.log` @babe3efd). Rows 14.1-14.13 + 14.13.5 `[x]`;
14.12 (`cljw component build`) deferred (zwasm-v2 gate, F-010); 14.14
(release) held. cw v1 ≈ 60-70% of cw v0's surface in ~half the LOC; see
the 2026-05-29 coverage/parity analysis (this session's chat) — error UX
+ `--compare`/`render-error` exceed v0; JIT / nREPL-richness / line-editor
/ Wasm-Component / deps-test toolchain are the intentional F-010-ordered
gaps.

## Larger next milestone (toward F-010 M = Phase 15 + cw-v0-level JIT)

**Phase 15** (concurrency: atom+watch, STM transaction engine, agent
pools, future/promise multi-thread, locking/volatile, pmap, concurrent
test layer) is the next PENDING phase. It also unblocks nREPL richness
(D-117 multi-session/CIDER ops, D-118 stdout/stderr capture — both
Phase-15-gated). After Phase 15: the narrow ARM64 JIT (D-133 coverage-
floor ordering) → M → the quality-elevation loop (`docs/works/`).

## Open debts (named; full rows in `.dev/debt.md`)

- **D-144** user-throw EDN context (next task). **D-143** apply
  multi-arity spread vs fixed-method. **D-141** bench multi-lock anchor.
  **D-142** Env-scope `*error-context*` slot (multi-Env nREPL). **D-105/
  D-106** time/net+crypto backing. **D-116** REPL line-editor. **D-117/
  D-118** nREPL richness. **D-075** metadata system. **D-133** JIT
  coverage-floor ordering. **D-119/D-139/D-140** opportunistic.

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow + § The
only stop) → `.dev/project_facts.md` (esp. F-010) → `.dev/principle.md`
→ `.dev/debt.md` D-144 → `src/app/error_render.zig` + `src/runtime/error/
{info,context}.zig` (the with-context read-side) → ROADMAP §9.16 (row
14.14 held) / §9.17 (Phase 15 placeholder).
