# ADR-0133: The default full gate builds `-Dwasm` throughout + runs the wasm e2e

- Status: Proposed → Accepted (2026-06-12)
- Governing fact: **F-001** Revision history 2026-06-12 (user-directed
  amendment — zwasm v2 is provisionally complete, so wasm joins the default
  gate). Supersedes the D-387 / ADR-0132-era "wasm is a SEPARATE opt-in
  runner" shape. Builds on ADR-0132 (the shared-binary-stays-optimised
  invariant) — this is its `-Dwasm` sibling.

## Context

D-387 (2026-06-12, earlier same day) wired the wasm-FFI execution e2e into a
SEPARATE opt-in runner (`scripts/run_wasm_gate.sh`) specifically because F-001
then forbade the default gate from resolving zwasm. Hours later the user
amended F-001: zwasm v2 is now complete, so the Wasm-FFI path (the headline
feature) MUST be in the default full gate (Mac AND ubuntunote). Verbatim
intent: 「デフォルトゲートフルゲート（Ubuntu含む）に含むべき … 冒頭から -Dwasm
でビルドする … 単品でビルドするものもすべて sh に -Dwasm 必要」.

## Decision

**Every `zig build` that actually executes in the gate carries `-Dwasm`**, and
the wasm e2e are ordinary gate steps:

- `build_cljw`, the dual-backend diff oracle (`zig build test` ×2), and
  `zlinter` → `-Dwasm`.
- `run_tier_a.sh` + the `[ -x "$BIN" ] || zig build` conditional builders
  (`clj_diff_sweep`, `check_corpus_regression`) → `-Dwasm`.
- **`phase4_{cli,exit,exit_codes}.sh` → `-Dwasm`** on every `zig build`
  (the `-Dbackend` rebuilds AND the default-restore). This was the live bug:
  phase4 rebuilds the shared binary for backend-difference testing and ran
  *non-wasm* `zig build -Doptimize=ReleaseSafe`, **reverting the binary to
  non-wasm mid-gate**, so the wasm e2e (which run later in the parallel pool)
  saw `(ReleaseSafe)` not `(ReleaseSafe, wasm)` and failed their wasm-enabled
  assertion. This is the ADR-0132 shared-binary-reversion class, `-Dwasm`
  variant — found by the wasm e2e failing in the default gate.
- `phase16_wasm_{ffi,run}.sh` are `run_step` e2e; they reuse the shared
  `-Dwasm` binary (`CLJW_SKIP_BUILD`), drop the stale
  `[ ! -d ../zwasm_from_scratch ]` skip (it false-skipped on tag-pin hosts
  like ubuntunote), and assert `cljw --version | grep wasm`.

**zwasm is resolved via the `build.zig.zon` tag-pin** (`v2.0.0-alpha.2` +
`.hash`, `lazy`), so no `../zwasm_from_scratch` sibling is needed — the gate
runs on ubuntunote (which has only the cljw clone). If `-Dwasm` cannot resolve
zwasm, `build_cljw` fails first: wasm is a **gate prerequisite** now, not a
graceful skip.

**The "every gate `zig build`" scope is the EXECUTING ones only.** The ~291
`test/e2e/*.sh` `[ -n "$CLJW_SKIP_BUILD" ] || zig build` lines are
`CLJW_SKIP_BUILD`-skipped in the gate (dead there) — they do NOT need `-Dwasm`.
An initial bulk edit added `-Dwasm` to all 291; it was reverted as the wrong
target (the user's "単品でビルドするもの" = the *unconditional* in-gate builders,
i.e. phase4, not the skipped e2e lines).

## Consequences

- The default full gate covers the Wasm-FFI execution path (add→42, no-leak,
  catchability, wasm/run WASI). A `(wasm/call)` regression now fails the gate.
- `cljw --version` shows `(ReleaseSafe, wasm)` for the gate binary (the
  `build_options.wasm` flag, ADR-0132 build-mode work) — the semantic signal
  the wasm e2e + the gate guard read.
- Gate wall grows (~113s non-wasm → ~250s) from the `-Dwasm` test/build
  compiles + the wasm e2e; acceptable for full coverage of the headline
  feature. zwasm is cached after first fetch.
- `scripts/run_wasm_gate.sh` (D-387) becomes a convenience quick-runner
  (wasm-only, no full gate) rather than the primary coverage.
- **ubuntunote verification is the remaining step** — `zig build -Dwasm`
  must fetch the zwasm tag + build on Linux there (the user flagged the
  Ubuntu build-differentiation as unchecked).

## Alternatives considered

- **Keep wasm as a separate opt-in runner** (D-387 / pre-amendment). Rejected:
  F-001 was amended to require default-gate coverage; an opt-in runner that
  nobody auto-invokes lets regressions ship green.
- **Only build_cljw `-Dwasm`, leave phase4 non-wasm.** Insufficient — phase4
  reverts the shared binary mid-gate (the live failure). Every executing
  in-gate `zig build` must carry `-Dwasm`.
- **`-Dwasm` on all 291 e2e standalone build lines.** Wrong target — they skip
  in-gate; pure churn (298-file diff). Reverted to the executing builders only.
- **Make the shared binary `-Dwasm` only via a dedicated wasm-binary path.**
  Cleaner isolation but needs `build.zig` to emit a second artifact name;
  deferred — the "all gate builds carry `-Dwasm`" rule keeps one binary.

## Revision history

- **2026-06-13 (user-directed)**: the "all 291 e2e standalone build lines"
  alternative is UN-rejected and landed (310 files by now). The original
  rejection reasoned only about in-gate behaviour (the lines are
  `CLJW_SKIP_BUILD`-skipped there — still true). What it missed is the
  **standalone path**: a bare `zig build` fallback (a) builds **Debug**,
  overwriting the gate's ReleaseSafe `zig-out/bin/cljw` so subsequent manual
  probes run the ~10-100× Debug cliff, and (b) uses a third build config
  (non-wasm Debug) so alternating standalone e2e ↔ gate builds thrashes the
  zig cache (the "zig build is slow" report, 2026-06-13). Every
  `test/e2e/*.sh` fallback now reads
  `zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}"` — identical to
  `build_cljw`, so a standalone run is a cache hit (~0.6s measured) and never
  degrades the shared binary. In-gate behaviour is unchanged (lines stay
  dead). Manual-probe guidance follows the same form; remaining non-unified
  builders (`bench/*.sh`, `scripts/perf.sh` — measurement-continuity
  question) are tracked as a debt row, not silently flipped.
