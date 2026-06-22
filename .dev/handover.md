# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT). **PUSH RESTORED** — the no-push
  relative-path experiment is OVER: `build.zig.zon` `.zwasm` is now a **tag pin**
  (`v2.0.0-alpha.3`, `fc7ff0b3b`), pushed to `origin/main`. Per-commit = smoke;
  commit **and** push (CLAUDE.md § atomic Step 6).
- **First commit on resume MUST be**: **D-501** — implement `clojure.core/time`
  (currently UNRESOLVED: `(time expr)` → Name error; `(resolve 'time)` → nil). A
  small clj-parity macro (`.dev/debt.yaml` D-501 has clj's form + the clock-primitive
  note). One TDD cycle: red e2e `(time 42)` → 42 + an "Elapsed time:" line, then
  implement in bootstrap core, smoke, push. After it, self-select the next
  clj-parity/quality floor row (easiest-first).
- **Forbidden this session**: bare `zig build test` WITHOUT `-Dwasm` (false fails —
  memory `zig_build_test_needs_dwasm`); bare `zig build` for a probe (ADR-0133 —
  ReleaseSafe). A reader-macro / syntax-quote NS-qualification stays `rt/`, not
  `clojure.core/` (AD-038/AD-049).

## Last landed (git log = SSOT)

**JIT default + zwasm v2.0.0-alpha.3 pin — D-488 discharged (`c4e263e9`, pushed;
tag `v1.0.0-alpha.1`).** zwasm cut `v2.0.0-alpha.3` (3-host green) which re-lands
`.auto`→JIT (its D-478) + fixes the gating x86_64 LSRA miscompile (D-489/D-494) —
`to_cljw_09` CONSUMED. So cljw:
- flipped `engine.LoadOpts.engine` default `.interp`→`.auto` (PROVISIONAL marker
  removed; D-488 + feature_deps#engine_default discharged, same commit): a no-opts
  `(wasm/load path)` now rides zwasm's JIT-first engine.
- e2e `phase16_wasm_engine_select.sh` extended — the no-opts default runs a SIMD
  body only the JIT can execute (`default-simd: 42`), proving the flip.
- Components stay interp-pinned on the zwasm side (D-500); F-012 diff oracle uses
  explicit `.interp`/`.jit` — both unaffected. Full gate + all wasm e2e GREEN.
- **cw-playground** (separate repo, pushed `557ed17`): `CLJW_REF`→`v1.0.0-alpha.1`,
  new `jit-speed` + `engine-select` examples, output pane shows the REPL value
  (`=> …`), docs note JIT-by-default is a runtime engine (build options unchanged).
  Verified in a real browser (playwright, console 0 errors). `fly deploy` to
  `cw-playground` (cw-playground.fly.dev) — confirm `fly status` healthy on resume
  if not already done.

## North star (ACTIVE)

cljw's differentiator = **Wasm/edge-native (gap II) × VM-perf fusion→JIT (gap III)**.
The embedded **zwasm** JIT engine (ADR-0200) is now the cljw DEFAULT (`.auto`). The
remaining north-star step is **components-through-the-JIT** — zwasm-side (components
are interp-pinned there, D-500; Win64 wrapper-thunk gap). Live ledger + the
read-at-boundaries convention: `.dev/zwasm_capabilities.md`.

## Cold-start reading order (resume)

handover → `.dev/debt.yaml` D-501 (the `time` macro — first task) →
`.dev/zwasm_capabilities.md` (JIT-adoption ledger + capability table + the dogfooding
mailbox convention) → `zwasm_from_scratch/private/dogfooding_handover/` (mailbox; all
`to_cljw_*` CONSUMED, no open items). memory `verify_actual_pattern_not_proxy`.
