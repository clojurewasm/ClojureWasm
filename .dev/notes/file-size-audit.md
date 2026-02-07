# File Size Audit (Phase 24.5.4)

Total: 41,572 lines across 49 Zig files. Phase 27 target: split files > 2000L.

## Files by Size

### Split candidates (> 2000L) — Phase 27

| Lines | File                         | Split strategy                                          |
|------:|------------------------------|---------------------------------------------------------|
| 3,696 | builtin/collections.zig      | Extract HAMT to collections_hamt.zig, fused reduce to reduce.zig |
| 3,353 | bootstrap.zig                | Extract hot_core_defs, callFnVal dispatch, clj evaluation |
| 2,800 | analyzer/analyzer.zig        | Extract special form handlers, destructuring             |
| 2,335 | eval_engine.zig              | Tests are ~70% of file; extract to eval_engine_test.zig  |
| 2,290 | native/vm/vm.zig             | Extract performCall dispatch, arithmetic helpers         |

### Monitor (1000-2000L) — no action needed

| Lines | File                         | Notes                             |
|------:|------------------------------|-----------------------------------|
| 1,713 | native/evaluator/tree_walk.zig | Manageable, single-responsibility |
| 1,601 | common/value.zig             | Type definitions + formatValue    |
| 1,592 | common/gc.zig                | MarkSweepGc + tracing             |
| 1,196 | repl/nrepl.zig               | nREPL server                      |
| 1,174 | bytecode/compiler.zig        | Compiler + emit methods           |
| 1,167 | reader/reader.zig            | Reader                            |
| 1,132 | builtin/ns_ops.zig           | Namespace operations              |
| 1,081 | builtin/sequences.zig        | Fused reduce + seq ops            |
| 1,050 | common/collections.zig       | PersistentList/Vector/HashMap     |

### Small (< 1000L) — 35 files, no action needed

Range: 65L (keyword_intern.zig) to 931L (builtin/clj_string.zig).

## Summary

- 5 files over 2,000 lines (split in Phase 27)
- 10 files in 1,000-2,000 range (monitor)
- 34 files under 1,000 lines (healthy)
- Average: 848 lines/file
- Median: ~500 lines/file
