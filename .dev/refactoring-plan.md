# Architecture Refactoring Plan (Phase 97)

> Zone-layered architecture. Incremental migration with zero regressions.
> Decision: D109. Analysis: `private/refactoring-analysis-2026-02-24.md`.

## Goal

Transform CW's flat module structure into a strict 4-zone layered architecture:

```
Layer 0: runtime/  — foundational types (no external deps)
Layer 1: engine/   — processing pipeline (depends only on runtime/)
Layer 2: lang/     — Clojure language impl (depends on runtime/ + engine/)
Layer 3: app/      — application entry points (depends on all)
```

Dependency rule: **lower layers NEVER import from higher layers.**

## Current Violations (baseline — R0)

Measured by `scripts/zone_check.sh`. Total: **134 violations**.

```
runtime(L0) -> engine(L1):   8 imports   (bootstrap from value/lifecycle/stm/thread_pool/macro/ns_loader; gc→compiler)
runtime(L0) -> lang(L2):    10 imports   (macro→builtins/interop; ns_loader→builtins; collections/value→builtins; lifecycle→builtins)
runtime(L0) -> app(L3):      6 imports   (value→wasm/types x6)
engine(L1)  -> lang(L2):   108 imports   (bootstrap→builtins x7; eval_engine→builtins x~60; tree_walk→builtins x13; vm→builtins x5; analyzer→interop x2)
lang(L2)    -> app(L3):      2 imports   (cljw_wasm→wasm/)
```

Root cause: `bootstrap.zig` (3,624 LOC) in runtime/ orchestrates all modules.
`eval_engine.zig` test functions import `builtins/registry.zig` ~60 times.

## Target Directory Structure

```
src/
  runtime/          ← Layer 0 (self-contained, no upward deps)
    value.zig           collections.zig       env.zig
    namespace.zig       var.zig               gc.zig
    error.zig           keyword_intern.zig    codepoint.zig
    lifecycle.zig       stm.zig               thread_pool.zig
    dispatch.zig        (NEW: callFnVal vtable)
    macro.zig           concurrency_test.zig

  engine/           ← Layer 1 (depends on runtime/ only)
    reader/             (reader.zig, tokenizer.zig, form.zig)
    analyzer/           (analyzer.zig, macro_transforms.zig, node.zig)
    compiler/           (compiler.zig, chunk.zig, serialize.zig, opcodes.zig)
    evaluator/          (tree_walk.zig)
    vm/                 (vm.zig, jit.zig)
    pipeline.zig        (evalString — read→analyze→eval orchestration)
    eval_engine.zig     (dual backend compare mode)
    cache.zig           (bootstrap cache restore/recompile)
    bootstrap.zig       (thin init: registerBuiltins + loadCore calls)
    embedded_sources.zig (Clojure multiline strings for VM compilation)

  lang/             ← Layer 2 (depends on runtime/ + engine/)
    builtins/           (arithmetic, collections, sequences, strings, ...)
      core/             (defs.zig — clojure.core var registration)
    interop/            (rewrites, dispatch, constructors, classes/)
    lib/                (clojure_string, clojure_test, clojure_pprint, ...)
    registry.zig        (builtin function registry)
    loader.zig          (namespace lazy loading)

  app/              ← Layer 3 (depends on all)
    main.zig            (thin entry point — parse args, dispatch)
    cli.zig             (CLI argument parsing, help text)
    runner.zig          (file execution, -e evaluation)
    test_runner.zig     (cljw test command)
    deps.zig            (deps.edn resolution)
    repl/               (nrepl.zig, line_editor.zig, bencode.zig)
    wasm/               (types.zig, builtins.zig, wit_parser.zig)

  root.zig          (public API — unchanged)
  cache_gen.zig     (build-time cache generator)
```

## Sub-Tasks

### R0: Baseline + Zone Check Script

Create `scripts/zone_check.sh` that counts cross-zone violations.
Record current baseline. Add to commit gate (informational, not blocking yet).

**Files**: `scripts/zone_check.sh` (new)
**Gate**: Script runs, baseline recorded in this plan

### R1: callFnVal Dependency Inversion (CRITICAL PATH)

Extract `callFnVal` from `bootstrap.zig` into `runtime/dispatch.zig` using
vtable pattern. This breaks the core circular dependency.

**Before** (bootstrap.zig imports TreeWalk + VM):
```zig
pub fn callFnVal(alloc, fn_val, args) !Value {
    switch (fn_val.kind) {
        .treewalk => TreeWalk.callBridge(...),  // imports evaluator/
        .bytecode => VM.callBridge(...),         // imports vm/
    }
}
```

**After** (dispatch.zig uses function pointers):
```zig
// runtime/dispatch.zig — Layer 0, no upward imports
pub const FnDispatch = struct {
    treewalkCall: *const fn(...) anyerror!Value,
    bytecodeCall: *const fn(...) anyerror!Value,
};
pub var table: FnDispatch = undefined;

pub fn callFnVal(alloc, fn_val, args) !Value {
    switch (fn_val.kind) {
        .treewalk => table.treewalkCall(...),
        .bytecode => table.bytecodeCall(...),
    }
}
```

```zig
// Initialization (in engine/ or app/ init):
dispatch.table = .{
    .treewalkCall = TreeWalk.callBridge,
    .bytecodeCall = VM.callBridge,
};
```

**Files**: `src/runtime/dispatch.zig` (new), `src/runtime/bootstrap.zig` (extract),
all callers of `bootstrap.callFnVal` → `dispatch.callFnVal`
**Gate**: All tests pass. `bench/run_bench.sh --quick` — no regression.
**Risk**: High. Hot path. Benchmark carefully.

### R2: Extract evalString Pipeline

Move `evalString*`, `readForms*`, `readFormsWithNs` from bootstrap.zig
to a new file (initially `src/runtime/pipeline.zig`, moves to `engine/` in R8).

**Files**: `src/runtime/pipeline.zig` (new), `src/runtime/bootstrap.zig` (shrink)
**Gate**: All tests pass.

### R3: Extract Builtin Registration

Move `registerBuiltins` and related registration code from bootstrap.zig
to `src/builtins/registry.zig` (already exists — merge into it).

**Files**: `src/builtins/registry.zig` (extend), `src/runtime/bootstrap.zig` (shrink)
**Gate**: All tests pass.

### R4: Extract Namespace Loading

Move `loadCore`, `loadTest`, `loadRepl`, `loadPprint`, `loadReducers`,
`loadEmbeddedLib` from bootstrap.zig to a new loader file.

**Files**: `src/builtins/loader.zig` (new), `src/runtime/bootstrap.zig` (shrink)
**Gate**: All tests pass.

### R5: Extract Cache System

Move `restoreFromBootstrapCache`, `vmRecompileAll`, cache-related functions
from bootstrap.zig to a cache module.

**Files**: `src/runtime/cache.zig` (new), `src/runtime/bootstrap.zig` (shrink)
**Gate**: All tests pass.

### R6: Slim Down bootstrap.zig

After R1-R5, bootstrap.zig should contain only:
- `bootstrapInit()` — top-level init that calls other modules
- `syncNsVar()` — may move to namespace.zig
- Small helpers

Target: < 200 LOC (down from 3,624).

**Gate**: All tests pass. bootstrap.zig < 200 LOC.

### R7: Fix value.zig Upward Dependency

`value.zig:726` imports `builtins/collections.zig`. Extract the needed
function to `runtime/collections.zig` or use a callback pattern.

**Files**: `src/runtime/value.zig`, possibly `src/runtime/collections.zig`
**Gate**: All tests pass.

### R8: Directory Rename (Big Move)

Rename directories to final zone structure. This is a single large commit
with ONLY `@import` path changes — zero logic changes.

**Moves**:
```
src/reader/       → src/engine/reader/
src/analyzer/     → src/engine/analyzer/
src/compiler/     → src/engine/compiler/
src/evaluator/    → src/engine/evaluator/
src/vm/           → src/engine/vm/
src/runtime/pipeline.zig  → src/engine/pipeline.zig
src/runtime/eval_engine.zig → src/engine/eval_engine.zig
src/runtime/cache.zig → src/engine/cache.zig
src/runtime/bootstrap.zig → src/engine/bootstrap.zig
src/runtime/embedded_sources.zig → src/engine/embedded_sources.zig

src/builtins/     → src/lang/builtins/
src/interop/      → src/lang/interop/
src/builtins/lib/ → src/lang/lib/
src/builtins/registry.zig → src/lang/registry.zig
src/builtins/loader.zig → src/lang/loader.zig

src/main.zig      → src/app/main.zig
src/deps.zig      → src/app/deps.zig
src/repl/         → src/app/repl/
src/wasm/         → src/app/wasm/
```

**Gate**: `zig build test` compiles and passes. All e2e pass.
No logic changes in this commit — import paths only.

**Note**: `build.zig` root source path may need updating.

### R9: Split main.zig

After R8, split `src/app/main.zig` (2,343 LOC) into:
- `main.zig` — entry point, arg dispatch (< 200 LOC)
- `cli.zig` — argument parsing, help text
- `runner.zig` — file execution, -e evaluation
- `test_runner.zig` — `cljw test` command

**Gate**: All tests pass.

### R10: Zone Enforcement in CI

Make zone check a **hard block** in commit gate.
Update CLAUDE.md commit gate checklist.
Create `.claude/rules/zone-deps.md` for auto-load enforcement.

**Files**: `scripts/zone_check.sh` (update to fail on violations),
`.claude/CLAUDE.md`, `.claude/rules/zone-deps.md`
**Gate**: `scripts/zone_check.sh` exits 0 (zero violations).

### R11: Structural Integrity Audit

1. **Semantic aliasing scan**: Check all builtin registrations for
   name/semantics mismatches (e.g., sorted-set aliased to hash-set)
2. **Evaluator special-case scan**: Check tree_walk.zig and vm.zig for
   library-specific symbol checks (should be in analyzer/macros, not evaluator)
3. Fix any issues found.

**Gate**: Audit report committed. Issues fixed.

### R12: Known Issues Resolution

Fix issues that naturally arise during refactoring or are now easy to fix:

| Issue | Fix | Related Sub-task |
|-------|-----|------------------|
| I-011 | finally exception propagation | Standalone |
| I-012 | Watch/validator error propagation | Standalone |
| I-013 | Bootstrap refer catch {} → log warning | R6 (bootstrap slim) |
| I-023 | @intCast → @bitCast for pointers | R7 or standalone |
| I-024 | Wasm bridge range check | Standalone |

**Gate**: Each fix = separate commit. All tests pass.

## Success Metrics

| Metric | Before | After |
|--------|--------|-------|
| Total zone violations | 134 | 0 |
| bootstrap.zig LOC | 3,624 | < 200 |
| main.zig LOC | 2,343 | < 200 |
| Zone check | N/A | CI hard block, 0 violations |
| Silent `catch {}` | 5+ | 0 |
| Tests | 68/68 upstream, 6/6 e2e, 14/14 deps e2e | Same (no regression) |
| Benchmarks | baseline | Within 1.2x (no regression) |
| Binary size | 4.52MB | ≤ 4.8MB |
| Startup | 4.2ms | ≤ 6.0ms |

## Execution Rules

1. **One sub-task = one commit.** Never combine R1+R2 in a single commit.
2. **Structure changes only.** No logic changes in refactoring commits.
   If a bug is found, fix it in a SEPARATE commit before/after the move.
3. **Full test suite every commit.** `bash test/run_all.sh` must pass.
4. **Benchmark on R1, R8.** These are the highest-risk steps.
   `bash bench/run_bench.sh --quick` for quick check.
5. **Import paths = the only code change in R8.** Verify with
   `git diff --stat` that only `@import` strings changed.
