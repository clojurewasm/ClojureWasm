# Zig 0.15.2 → 0.16.0 Migration — Working Document

**Status**: In progress (branch `develop/zig-016-migration`)
**Baseline**: commit `8bfbf5b` (`pre-zig-016` in `bench/history.yaml`)
**Target zwasm**: v1.11.0 (released)

This is a **temporary** working doc. Delete after Phase 7 completion (or
move learnings into `.dev/decisions.md` D## entry and `.dev/zig-tips.md`).

## Phase -1: zwasm Dependency Audit

### Existing -Dwasm Infrastructure (already in place)

`build.zig` already supports `-Dwasm=true|false` (default true) with full
conditional gating. Zig source files using zwasm are already wrapped in
`if (enable_wasm) ...` patterns. **No new build-side gating needed**.

- `build.zig:10` — `-Dwasm` flag definition
- `build.zig:17` — propagated to `build_options.enable_wasm`
- `build.zig:22-37` — `zwasm_mod` / `zwasm_native_mod` conditional dep
- `build.zig:44,59,84` — conditional `addImport("zwasm", ...)`
- `build.zig:115` — `wasm32-wasi` target does NOT depend on zwasm (correct)

Source-side gates already present:

- `src/runtime/wasm_types.zig:20` — `const zwasm = if (enable_wasm) @import("zwasm") else struct {};`
- `src/lang/lib/cljw_wasm.zig:16` — `.enabled = wasm_types.enable_wasm`
  (NamespaceDef level — `cljw.wasm` namespace is unregistered when disabled)

### Verified working under `-Dwasm=false` on Zig 0.15.2

- `zig build -Dwasm=false` → exit 0 ✓
- `zig build test -Dwasm=false` → exit 0 ✓ (Zig unit tests auto-skip)
- `zig build -Doptimize=ReleaseSafe -Dwasm=false` → exit 0 ✓

### What FAILS under `-Dwasm=false` (needs Phase 0 work)

#### 1. E2E Wasm tests (test/e2e/wasm/, 6 files)

```
test/e2e/wasm/01_basic_test.clj
test/e2e/wasm/02_tinygo_test.clj
test/e2e/wasm/03_host_functions_test.clj
test/e2e/wasm/04_module_objects_test.clj
test/e2e/wasm/05_wit_test.clj
test/e2e/wasm/06_multi_module_test.clj
```

All start with `(require '[cljw.wasm :as wasm])` → fail with "Could not
locate cljw.wasm on load path" because the namespace is not registered.

#### 2. Test runners that unconditionally invoke wasm tests/benchmarks

| Runner | What breaks |
|---|---|
| `test/run_all.sh` | step "e2e tests (wasm)" calls `bash test/e2e/run_e2e.sh` (no dir filter) → all e2e dirs incl. wasm |
| `test/e2e/run_e2e.sh` | no `--no-wasm` flag; finds all `*_test.clj` recursively |
| `bench/wasm_bench.sh` | runs wasm benchmarks via TinyGo .wasm modules — needs cljw.wasm |
| `bench/run_bench.sh` | runs benchmarks 21-25, 28-31 (9 wasm benchmarks) under `bench/benchmarks/` |

#### 3. Wasm benchmarks (bench/benchmarks/)

```
21_wasm_load     22_wasm_call    23_wasm_memory  24_wasm_fib     25_wasm_sieve
28_wasm_tgo_fib  29_wasm_tgo_tak 30_wasm_tgo_arith 31_wasm_tgo_sieve
```

### Source files referencing WasmModule type (for migration awareness)

Already-gated, but require io threading in Phase 2:

- `src/runtime/wasm_types.zig` — main bridge
- `src/runtime/wasm_wit_parser.zig` — WIT parser, uses @embedFile (no io)
- `src/runtime/value.zig` — `.wasm_module` variant
- `src/runtime/dispatch.zig` — invokeWasmFn dispatch
- `src/runtime/gc.zig` — WasmModule finalizer registry
- `src/lang/lib/cljw_wasm.zig` — NamespaceDef
- `src/lang/lib/cljw_wasm_builtins.zig` — wasm/load, wasm/fn impl
- `src/engine/vm/vm.zig`, `src/engine/evaluator/tree_walk.zig` — call sites
- `src/app/repl/nrepl.zig:1427` — `#<WasmModule>` formatter
- `src/app/deps.zig` — `cljw/wasm-deps` config parsing (test data only)

## Phase 0: Plan

Reduced scope thanks to existing infrastructure:

1. **Add `--no-wasm` flag to test runners**:
   - `test/run_all.sh` — skip "e2e tests (wasm)" step when `--no-wasm`
   - `test/e2e/run_e2e.sh` — skip `wasm/` directory when `--no-wasm` (or `WASM_DISABLED=1` env)
   - `bench/wasm_bench.sh` — early exit with friendly message when `--no-wasm`
   - `bench/run_bench.sh` — filter out wasm_* benchmarks when `--no-wasm`

2. **Update build.zig.zon**: `minimum_zig_version = "0.16.0"` (will be done as
   part of Phase 0 commit, even though we still build with 0.15.2 during the
   actual code migration phases — `.zon` is just metadata until we actually
   bump zig).

   Actually: defer this to first 0.16-only commit so we can keep building
   with 0.15.2 during preparatory commits.

3. **Update zwasm dep tag**: defer to Phase 6 (currently v1.9.1, target v1.11.0).
   Until Phase 6, build with `-Dwasm=false` so the v1.9.1 zwasm dep is never resolved.

4. **Update `.dev/baselines.md`**: relax binary size cap (≤5.0MB → provisional
   ≤5.5MB during migration, finalize in Phase 7).

5. **Doc/CI sweep**: grep "0.15.2", "Zig 0.15", update to "Zig 0.16.0":
   - `.claude/CLAUDE.md`
   - `.dev/baselines.md`, `.dev/decisions.md`, `.dev/references/*.md`
   - `README.md`
   - `flake.nix`, `flake.lock` (if present)
   - `.github/workflows/*.yml` (if present)
   - `scripts/*.sh`

## Decision: Gating mechanism for test runners

Use **`--no-wasm` flag** on each runner (matches existing `--quick`,
`--tree-walk` patterns). Avoid env vars to keep behavior explicit.

`test/run_all.sh` will pass `--no-wasm` down to `run_e2e.sh` when invoked
with `--no-wasm`, and skip `wasm_bench.sh` entirely.

## Open questions for Phase 6 (deferred)

- Does zwasm v1.11.0 export the same module interface as v1.9.1?
  (`zwasm.WasmModule`, `zwasm.Capabilities`, `zwasm.ImportEntry`, etc.)
- Are there breaking API changes in zwasm v1.10.0 → v1.11.0 we'd need
  to absorb at the `wasm_types.zig` bridge?
- Action: read `~/Documents/MyProducts/zwasm/CHANGELOG.md` v1.10.0 + v1.11.0
  notes when entering Phase 6.

## Phase 7: Atomic Toolchain Flip (deferred)

Once code migration is complete and tests are green on Zig 0.16.0,
flip all toolchain pins and version-mention strings in a single commit.
Doing this earlier creates a window where neither 0.15.2 nor 0.16.0 builds
cleanly.

Files to update:

| File | Lines | Change |
|---|---|---|
| `build.zig.zon` | 11 | `.minimum_zig_version = "0.16.0"` |
| `flake.nix` | 9, 20, 23, 27, 31, 35, 46, 58 | URLs and comments → 0.16.0 |
| `flake.lock` | 71 | regenerate via `nix flake update zig-overlay` |
| `.github/workflows/ci.yml` | 16, 74, 117 | `version: 0.16.0` |
| `.github/workflows/nightly.yml` | 15, 59 | `version: 0.16.0` |
| `.github/workflows/release.yml` | 32 | `version: 0.16.0` |
| `README.md` | 5, 34 | badge + install link |
| `.claude/CLAUDE.md` | 3, 290, 293 | intro + "Pitfalls" section header + path hint |
| `.claude/references/zig-tips.md` | 1, 34 | title + body content |
| `.dev/baselines.md` | 4 | "Zig 0.15.2" → "Zig 0.16.0" platform line |
| `.dev/CONTRIBUTING.md` | 33 | install requirement |
| `.dev/references/setup-orbstack.md` | 19, 30 | install + version check |
| `.dev/references/ubuntu-testing-guide.md` | 56 | describe 0.16-specific behavior if changed |
| `docs/differences.md` | 10 | runtime row |
| `.dev/future.md` | 365 | check if still relevant |

DO NOT touch:
- `.dev/archive/**` — historical phase notes
- `.dev/decisions.md` D## entries that reference 0.15.2 — these are immutable history
  (D## about ArenaAllocator.free, @call always_tail, etc. — those decisions remain valid context)

After flip:
- Re-run `bash test/run_all.sh` (no --no-wasm) on Zig 0.16.0
- OrbStack Ubuntu validation: `--seed 0` still required? Re-test
- Update binary size baseline to actual measured value
- Add D## entry in `.dev/decisions.md` for the migration
- Add F## in `.dev/checklist.md` for the libc strip follow-up (zwasm W46 equivalent)
- Delete this file (`.dev/zig-016-migration.md`)
