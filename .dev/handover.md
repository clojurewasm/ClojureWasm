# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT). **NO-PUSH EXPERIMENT MODE** (user-directed
  2026-06-21): the JIT adoption experiment rides a **relative-path** zwasm dep
  (`build.zig.zon` `.zwasm` = `.path = "../zwasm_from_scratch"`, NOT a SHA pin), so
  others cannot reproduce it — commits **accumulate LOCAL, un-pushed** (10 so far:
  `18c71c22`…`59eed0d7`). Do NOT `git push` until the experiment settles + zwasm cuts a
  pinnable SHA (then revert `.zwasm` to the SHA-pin form preserved in build.zig.zon's
  comment + git history). Per-commit = smoke; commit, never push.

- **First commit on resume MUST be**: gated on a **user decision** (see § Stopped). When the
  user picks a path for the zwasm `v2.0.0-alpha.3` tag (A: tag on the green baseline + defer the
  JIT flip / B/C: flip first) AND zwasm pushes the tag, run the chain in
  `private/notes/overnight_runbook.md`: rewrite `build.zig.zon` `.zwasm` to the tag URL+hash →
  full gate → `git push origin main` (NO-PUSH lifted only then) → tag cljw **`v1.0.0-alpha.N`**
  (⚠️ PRE-RELEASE alpha, NEVER `v0.6.0`/`1.0.0` — user is NOT releasing 1.0.0) + push → update
  `cw-playground` (`CLJW_REF`→the tag) + chrome-devtools e2e + push → `fly deploy` + confirm. If
  the user instead wants other work, self-select (the quick-win seam is drained; medium rows
  D-466/D-468). **D-404 wasm-component epic is COMPLETE** (A–E, ADR-0135/0158/0159; all local,
  un-pushed); only the user-deferred `:cljw/wasm-deps`/registry arm remains.
- **Background watch (NOT the active task)**: the JIT adoption experiment is CONVERGED
  (1/2-arg invoke matrix complete, e2e-locked); its only open item is **D-488's `.auto`
  default flip**, blocked by **zwasm D-489** (x86_64-only JIT miscompile, non-urgent,
  zwasm-internal). Check the dogfooding mailbox (`to_cljw_*.md` SENT) at unit boundaries;
  flip the default when zwasm signals D-489 fixed + `.auto` 3-host green.

## Stopped — user requested

User instruction (2026-06-22 morning): "選択肢がでて止まっていたので停止で" — the overnight chain
parked on a decision, so STOP. The overnight cron (`c2b8cac9`) is DELETED; marker
`private/.overnight_phase` = STOPPED. **Nothing is broken — the chain never started because zwasm
deferred the precondition.**

State at stop:
- **zwasm** (`to_cljw_08`): the `.auto`→JIT flip is DEFERRED (a multi-cycle JIT-C-API campaign — a
  JIT instance doesn't yet expose memory/table/global/get_func; 69 unit failures), so zwasm
  **reverted to green baseline `8a4a01905`** and **did NOT cut `v2.0.0-alpha.3`** (the tag was gated
  on the flip in the plan). zwasm is waiting on a USER DECISION: (A) tag alpha.3 on the green
  baseline + defer the flip, or (B/C) flip first.
- **cljw**: fully READY. Green baseline re-verified — full wasm e2e GREEN (FFI, WASI `wasm/run`,
  resource lifecycle, require-component embed/classpath). D-404 epic A–E complete (all LOCAL,
  un-pushed — NO-PUSH relative-path mode still in effect). `from_cljw_06` "interp regression" was a
  FALSE ALARM (I `wasm/load`ed a WASI-command fixture; retracted, CONSUMED). D-488 `.interp` default
  stays (the flip that would free it is deferred). One small resource fix (to_cljw_07 pt-4
  `NoResourceTable`→no-op) is documented in the runbook to re-apply during the chain, currently
  reverted (tree clean).
- **Mailbox**: all `to_cljw_*` CONSUMED; `from_cljw_06` retracted-CONSUMED. No open items either way.

Resume: when the user decides A/B/C and zwasm pushes `v2.0.0-alpha.3`, run
`private/notes/overnight_runbook.md` (pin→gate→push→tag `v1.0.0-alpha.N`→cw-playground→fly). The
next `/continue` resumes the loop normally.

- **Forbidden this session**: `git push` (no-push experiment — relative-path dep).
  Flipping the cljw default to `.auto` before D-488 clears (x86_64 JIT miscompile, D-489).
  Bare `zig build test` WITHOUT `-Dwasm` (false fails — memory `zig_build_test_needs_dwasm`).
  Bare `zig build` for a probe (ADR-0133 — ReleaseSafe). A reader-macro / syntax-quote
  NS-qualification MUST stay `rt/`, not `clojure.core/` (AD-038/AD-049).

## Last landed (git log = SSOT; LOCAL, un-pushed — relative-path experiment)

**JIT adoption experiment (2026-06-21, user-directed): zwasm's JIT-backed embedding
API adopted via a relative-path dep; 10 local commits `18c71c22`…`59eed0d7`.**
- **Engine knob**: `(wasm/load p {:engine :jit/:interp/:auto})` threaded through
  engine.zig (`EngineKind` + `LoadOpts.engine`) + surface.zig. Default pinned `.interp`
  (PROVISIONAL triad + D-488).
- **Dual-engine oracle** (F-012 applied to engine choice): engine.zig unit test +
  surface e2e `phase16_wasm_engine_select.sh` — GPR `add`, multi-value `divmod` `[3 2]`,
  same-type-2-arg f64 `addf` 3.75, MIXED-2-arg `(i32,f64)→f64` 5.5 all jit==interp; SIMD
  `lane0`→42 + `simd_dot` (i32x4.mul)→70 JIT-only (interp traps).
- **Perf demo**: `bench/wasm_jit_vs_interp.sh` — sumto 1e8 loop ≈ **~44× jit vs interp**.
- **Co-dev (6 round-trips, from_cljw_02-04 / to_cljw_02-05)**: each precise report drove a
  zwasm fix within minutes — exportFuncSig JIT arm (@5b6449779), 2-arg×FP dispatch
  (@d7da97e04), mixed-2-arg general fall-through (@3cf40a573). **1/2-arg JIT invoke matrix
  now COMPLETE**.
- **D-488** (open): the `.interp`→`.auto` default flip, now blocked by **zwasm D-489** (an
  x86_64-only JIT realworld miscompile) + the x86_64 `.auto` 3-host verdict — zwasm-internal.

## North star (now ACTIVE, not distal)

cljw's differentiator = **Wasm/edge-native (gap II) × VM-perf fusion→JIT (gap III)**.
The embedded **zwasm** JIT-backed embedding API (ADR-0200) is now **adopted** (relative-
path experiment); the perf demo proves the ~44× win. Remaining: D-488's default flip
(zwasm-gated). Live ledger + the read-at-boundaries convention: `.dev/zwasm_capabilities.md`.

## Cold-start reading order (resume)

handover → `.dev/zwasm_capabilities.md` (the live JIT-adoption ledger + capability table +
the dogfooding mailbox convention) → `zwasm_from_scratch/private/dogfooding_handover/`
(to_cljw_*/from_cljw_* mailbox; check for a `to_cljw_06`+ signal that zwasm D-489 is
fixed / `.auto` is 3-host green) → `.dev/debt.yaml` D-488 (the default-flip blocker) →
`private/notes/9.0-jit-adoption-unit.md` (the full experiment log). memory
`verify_actual_pattern_not_proxy` + `local_accumulation_sweep_phase` (the no-push mode).
