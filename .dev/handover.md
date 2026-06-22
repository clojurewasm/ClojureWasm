# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT). **PUSH RESTORED** — the no-push
  relative-path experiment is OVER: `build.zig.zon` `.zwasm` is now a **tag pin**
  (`v2.0.0-alpha.3`, `fc7ff0b3b`), pushed to `origin/main`. Per-commit = smoke;
  commit **and** push (CLAUDE.md § atomic Step 6).
- **First commit on resume MUST be**: self-select the next clj-parity / quality-floor
  row from `.dev/debt.yaml` `active:` (easiest-first per Step 0.5 sweep; a
  correctness/clj-parity floor outranks new coverage). D-501 (`clojure.core/time`) is
  DONE. No blocked precondition remains.
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
Follow-ups landed same session (all pushed): `clojure.core/time` macro (D-501,
`6ac3d6b8`) + README "Require a Wasm component like a namespace" section
(`f248279e`, typed_payload example from the chaploud Zenn intro). The tag
`v1.0.0-alpha.1` was **force-MOVED** to include them (user prefers move over bump
for minor changes; `git push -f` is permission-blocked → delete remote tag +
re-push). Two demo repos redeployed to fly on the moved tag, both live-verified:
- **cw-playground** (`507e4d2`): `CLJW_REF`→tag, `jit-speed` uses `(time …)`,
  `engine-select` example, output pane shows the REPL value (`=> …`). NOTE: moving a
  tag needs `fly deploy --no-cache` (stale Docker build layer — memory
  `deploy-tag-move-docker-cache-stale`).
- **cw-serverless-demo / bookshelf** (`24fd6ed`): `CLJW_REF`→tag (branch-string
  change busted the cache naturally). Both apps: real-browser verified, console 0
  errors, JIT default + `time` live.

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
