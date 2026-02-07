# Phase 29: Codebase Restructuring

## Goal

Improve code organization for maintainability. Split large files,
resolve D3 violations, normalize naming. Prerequisite for Phase 30
(nREPL/cider-nrepl integration needs modular codebase).

## Scope Decisions

### In scope (high impact, manageable risk)

1. **D3 violation resolution** — move module-level state into structs

### Dropped (analysis showed impractical)

2. **File splitting** — DROPPED. All 6 candidate files (collections.zig,
   bootstrap.zig, analyzer.zig, eval_engine.zig, vm.zig, value.zig) use
   Zig struct methods (must be in same file as struct definition). Tests
   account for 50-78% of file sizes (Zig convention: bottom of same file).
   Forcing extraction changes call convention with no real benefit.

### Deferred (low ROI vs risk)

3. **Directory restructure** (common/native/ → core/eval/cli/) — deferred.
   Changes 200+ import paths, high regression risk, moderate benefit.
   Do this when there's a stronger reason (e.g., extracting a library).
4. **Import path cleanup** — follows directory restructure, deferred together.

## Status: SKIPPED

Both sub-phases found impractical after analysis:
- 29.1 (file splitting): Zig struct methods must be in same file as struct.
  Tests account for 50-78% of large file sizes (Zig convention). No clean
  extraction boundaries exist.
- 29.2 (D3 violations): Requires changing BuiltinFn signature from
  `fn(Allocator, []const Value)` to `fn(Allocator, *Env, []const Value)`,
  affecting 500+ function signatures. Massive effort, low immediate value.

Both items deferred until there's a stronger trigger (embedding mode, multi-thread).

## Original Task Queue (dropped)

### Phase 29.1: File Splitting (DROPPED)

Split 6 files over 2000 lines. Strategy: extract logical units, keep
the existing file as the "main" module that re-exports from sub-modules.

| Task   | File (lines)             | Split strategy                              |
| ------ | ------------------------ | ------------------------------------------- |
| 29.1a  | builtin/collections.zig (3737L) | Extract transient ops → transient.zig  |
| 29.1b  | bootstrap.zig (3381L)    | Extract hot_core_defs + callFnVal → bootstrap_hot.zig |
| 29.1c  | analyzer/analyzer.zig (2804L) | Extract special forms → special_forms.zig |
| 29.1d  | eval_engine.zig (2415L)  | Extract tests → eval_engine_test.zig        |
| 29.1e  | native/vm/vm.zig (2342L) | Extract performCall → vm_dispatch.zig       |
| 29.1f  | value.zig (2163L)        | Extract formatPrStr → value_format.zig      |

### Phase 29.2: D3 Violation Resolution

Move runtime state from module-level vars into structs. Priority:
items that affect embedding/multi-instance scenarios.

| Task   | State                    | Resolution                                  |
| ------ | ------------------------ | ------------------------------------------- |
| 29.2a  | io.zig capture_*         | Move into RuntimeContext                    |
| 29.2b  | ns_ops.zig load_paths/*  | Move into Env                               |
| 29.2c  | numeric.zig prng         | Move into Env or pass explicitly            |
| 29.2d  | misc.zig gensym_counter  | Move into Env                               |

## File Split Details

### 29.1a: builtin/collections.zig → +transient.zig

Extract transient collection implementations (TransientVector, TransientMap,
TransientSet builtins). ~800L → new file. collections.zig remains ~2900L.

### 29.1b: bootstrap.zig → +bootstrap_hot.zig

Extract:
- `hot_core_defs` string constant (~100L)
- `loadHotDefs()` function
- `callFnVal()` dispatch bridge (~300L)
- `printValue()` and pr-str formatting (~200L)
bootstrap.zig remains ~2700L. Still large but core bootstrap logic stays.

### 29.1c: analyzer/analyzer.zig → +special_forms.zig

Extract special form handlers (if, do, let*, fn*, loop*, etc.).
Each handler is ~50-100L. ~1200L → new file. analyzer.zig remains ~1600L.

### 29.1d: eval_engine.zig → tests extracted

eval_engine.zig is ~70% tests. Tests at file bottom can remain (Zig
convention). No split needed — tests ARE the test file. Skip this task.

### 29.1e: native/vm/vm.zig → +vm_dispatch.zig

Extract `performCall()` and related dispatch helpers (~600L).
vm.zig remains ~1700L.

### 29.1f: value.zig → +value_format.zig

Extract `formatPrStr()` and string representation logic (~400L).
value.zig remains ~1700L.

## Success Criteria

- [ ] No file over 3000L after Phase 29.1
- [ ] All tests pass after each split
- [ ] No module-level mutable state in io.zig, ns_ops.zig
- [ ] Clean `zig build test` after every commit

## References

- .dev/notes/file-size-audit.md — Phase 24.5 audit
- .dev/notes/mutable-state-audit.md — D3 catalog
- .dev/future.md SS8 — Architecture
