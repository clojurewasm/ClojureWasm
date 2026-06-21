# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Stopped — user requested

User instruction (2026-06-21): "ではこっちは一旦停止でOK" — after the JIT adoption
experiment reached consolidation (7 local un-pushed commits `18c71c22`…`f82d8dd5`).
The look-ahead full gate was stopped + reaped mid-run (the committed units are each
smoke-green; the full-gate stamp is a nicety, not a blocker). The next session resumes
the loop normally per the Resume contract below (delete this section on resume).
3-item resume bridge (alt / next experiment / blocker) in
`private/notes/9.0-jit-adoption-unit.md` § Stopped.

## Resume contract

- **HEAD**: `main` (`git log` = SSOT). **NO-PUSH EXPERIMENT MODE** (user-directed
  2026-06-21): the JIT adoption experiment rides a **relative-path** zwasm dep
  (`build.zig.zon` `.zwasm` = `.path = "../zwasm_from_scratch"`, NOT a SHA pin), so
  others cannot reproduce it — commits **accumulate LOCAL, un-pushed** (5 so far:
  `18c71c22`…`7fe725ec`). Do NOT `git push` until the experiment settles + zwasm cuts a
  pinnable SHA (then revert `.zwasm` to the SHA-pin form preserved in build.zig.zon's
  comment + git history). Per-commit = smoke; commit, never push.

- **First commit on resume MUST be**: continue the **JIT adoption experiment** (ROADMAP
  §9.0 gap II×III; `.dev/zwasm_capabilities.md` = the live ledger). At the unit boundary
  check the dogfooding mailbox (`zwasm_from_scratch/private/dogfooding_handover/to_cljw_*.md`
  with `Status: SENT`) + zwasm HEAD. Live watch item = **D-488's unblock**: zwasm fixing the
  **f64-on-JIT trap** (`from_cljw_03`, awaiting reply) AND confirming its **`.auto`→JIT
  cross-host verdict**. Once BOTH clear, flip cljw's `engine.LoadOpts.engine` default
  `.interp`→`.auto` (remove the PROVISIONAL triad: marker + `feature_deps#engine_default` +
  D-488), and extend the e2e to assert the no-opts default rides the JIT + f64 jit==interp.
  Adopted so far: `{:engine :jit/:interp/:auto}`, a dual-engine oracle (GPR / multi-value /
  SIMD-on-jit / f64-on-interp), the JIT-vs-interp perf demo (~44× on a 1e8 loop). If zwasm
  has no new signal, self-select the next-highest-value quality unit (per § The only stop).

- **Forbidden this session**: `git push` (no-push experiment — relative-path dep).
  Flipping the cljw default to `.auto` before D-488 clears (f64 modules trap under JIT).
  Bare `zig build test` WITHOUT `-Dwasm` (false fails — memory `zig_build_test_needs_dwasm`).
  Bare `zig build` for a probe (ADR-0133 — ReleaseSafe). A reader-macro / syntax-quote
  NS-qualification MUST stay `rt/`, not `clojure.core/` (AD-038/AD-049).

## Last landed (git log = SSOT; LOCAL, un-pushed — relative-path experiment)

**JIT adoption experiment (2026-06-21, user-directed): zwasm's JIT-backed embedding
API adopted via a relative-path dep; 5 local commits `18c71c22`…`7fe725ec`.**
- **Engine knob**: `(wasm/load p {:engine :jit/:interp/:auto})` threaded through
  engine.zig (`EngineKind` + `LoadOpts.engine`) + surface.zig. Default pinned `.interp`
  (PROVISIONAL triad + D-488) — zwasm reverted+re-landed `.auto`→JIT mid-session.
- **Dual-engine oracle** (F-012 applied to engine choice): engine.zig unit test +
  surface e2e `phase16_wasm_engine_select.sh` — GPR `add` jit==interp; multi-value
  `divmod` jit==interp `[3 2]`; SIMD `lane0`→42 + `simd_dot` (i32x4.mul)→70 JIT-only
  (interp traps); f64 `addf` interp=3.75 / jit=TRAP (locked).
- **Perf demo**: `bench/wasm_jit_vs_interp.sh` — sumto 1e8 loop = ~0.078s jit vs ~3.4s
  interp = **~44× end-to-end** (the JIT north-star value, gap III).
- **Co-dev (3 round-trips)**: `from_cljw_02` → zwasm shipped the exportFuncSig JIT arm
  (@5b6449779), so explicit `:jit` `wasm/call` works end-to-end · `from_cljw_03` (SENT,
  awaiting reply): the **f64-on-JIT trap** (matrix says supported, but it traps).
- **D-488** (open): the two sub-blockers for the `.interp`→`.auto` default flip — the
  f64-on-JIT trap + zwasm's pending `.auto` cross-host (ubuntu x86_64) verdict.

## North star (now ACTIVE, not distal)

cljw's differentiator = **Wasm/edge-native (gap II) × VM-perf fusion→JIT (gap III)**.
The embedded **zwasm** JIT-backed embedding API (ADR-0200) is now **adopted** (relative-
path experiment); the perf demo proves the ~44× win. Remaining: D-488's default flip
(zwasm-gated). Live ledger + the read-at-boundaries convention: `.dev/zwasm_capabilities.md`.

## Cold-start reading order (resume)

handover → `.dev/zwasm_capabilities.md` (the live JIT-adoption ledger + capability table +
the dogfooding mailbox convention) → `zwasm_from_scratch/private/dogfooding_handover/`
(to_cljw_*/from_cljw_* mailbox; check for a `to_cljw_04` reply to `from_cljw_03`) →
`.dev/debt.yaml` D-488 (the default-flip blockers) → `private/notes/9.0-jit-adoption-unit.md`
(the full experiment log). memory `verify_actual_pattern_not_proxy`.
