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

- **First commit on resume MUST be**: continue the **OVERNIGHT AUTONOMOUS CHAIN** (user asleep,
  2026-06-22) — driven by cron `c2b8cac9` (every 10 min) + the runbook
  `private/notes/overnight_runbook.md` + phase marker `private/.overnight_phase`. The chain
  WAITS for zwasm to push tag `v2.0.0-alpha.3`, then: rewrite `build.zig.zon` `.zwasm` to the
  tag URL+hash → full gate → `git push origin main` (NO-PUSH lifted at that point) → tag cljw
  **`v1.0.0-alpha.N`** (⚠️ PRE-RELEASE alpha, NEVER `v0.6.0`/`1.0.0` — user is NOT releasing
  1.0.0) + push → update `cw-playground` (`CLJW_REF`→the tag) + chrome-devtools e2e + push →
  `fly deploy` cw-playground + confirm → `DONE` (delete cron, stop). Read the runbook; act per
  the marker. **D-404 wasm-component epic is COMPLETE** (A–E, ADR-0135/0158/0159); only the
  user-deferred `:cljw/wasm-deps`/registry arm remains. **D-488** (`.auto` engine default) is
  now UNBLOCKED (zwasm to_cljw_07: D-489/D-494 fixed, `.auto`=JIT+interp-fallback) — left as a
  free user choice, NOT flipped tonight.
- **Background watch (NOT the active task)**: the JIT adoption experiment is CONVERGED
  (1/2-arg invoke matrix complete, e2e-locked); its only open item is **D-488's `.auto`
  default flip**, blocked by **zwasm D-489** (x86_64-only JIT miscompile, non-urgent,
  zwasm-internal). Check the dogfooding mailbox (`to_cljw_*.md` SENT) at unit boundaries;
  flip the default when zwasm signals D-489 fixed + `.auto` 3-host green.

## Overnight autonomous run (2026-06-22 — supersedes the earlier quick-win stop)

After the quick-win sweep concluded, the user gave an OVERNIGHT plan (asleep): cljw waits for
zwasm's `v2.0.0-alpha.3` tag, then runs the pin→gate→push→tag→playground→fly chain to
completion, then stops. This is NOT idle — cron `c2b8cac9` (10-min, **session-only — keep
Claude open**) re-invokes the runbook every 10 min. zwasm `to_cljw_07` already CONFIRMED the
resource semantics (4/4) + announced the `.auto`→JIT flip is landing + the alpha.3 tag is
being cut. Current marker: see `private/.overnight_phase` (started `WAIT`). The user-defined
stop is **chain complete (`DONE`)** or a genuine user-only blocker (`BLOCKED`). Full state +
the exact per-phase commands: `private/notes/overnight_runbook.md`.

  **⟵ MORNING DECISION NEEDED (2026-06-22 overnight result).** The chain is parked at `WAIT`
  on **your tag decision** — it is NOT a cljw or zwasm bug. zwasm `to_cljw_08`: the `.auto`→JIT
  **flip is DEFERRED** (it needs a multi-cycle JIT-C-API campaign — a JIT instance doesn't yet
  expose memory/table/global/get_func; 69 unit failures), so zwasm **reverted to the green
  baseline `8a4a01905`** and **STOPPED, NOT cutting `v2.0.0-alpha.3`**, because in your plan the
  tag was gated on the flip. **cljw is fully READY** — re-verified the green baseline: the entire
  wasm e2e is GREEN (FFI, WASI `wasm/run`, resource lifecycle, require-component embed/classpath).
  (My `from_cljw_06` "interp regression" was a FALSE ALARM — I `wasm/load`ed a WASI-command fixture
  that needs `wasm/run`; retracted.) **Your call**: (A) tell zwasm to **tag `v2.0.0-alpha.3` now on
  the green baseline** + defer the flip → the cron auto-runs the cljw pin→gate→`v1.0.0-alpha.N`
  tag→playground→fly chain; or (B/C) have zwasm do a scoped/full JIT-C-API flip first (longer).
  cljw will NOT unilaterally pin the bare `dbda9f873`/`8a4a01905` hash (your plan is tag-gated).
  The cron keeps polling for the tag, so if you pick (A) and zwasm tags, it resumes with no further
  input. **D-488 `.interp` default stays** (the flip that would've freed it is deferred).

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
