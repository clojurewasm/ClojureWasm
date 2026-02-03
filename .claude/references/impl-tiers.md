# Implementation Tier Guidelines

When to implement in Zig builtin vs core.clj.

## Tier Summary

| Tier | Location    | Criteria                               | Examples                               |
| ---- | ----------- | -------------------------------------- | -------------------------------------- |
| 1    | Zig builtin | Low-level ops, hot path, perf-critical | `+`, `first`, `seq`, `reduce`, `assoc` |
| 2    | core.clj    | Pure Clojure, existing fn combinations | `when`, `cond`, `->`, `map`, `filter`  |
| 3    | N/A (skip)  | JVM-specific, no equivalent            | `compile`, `import`, `agent`, `future` |
| 4    | Zig stub    | Dynamic vars, config                   | `*warn-on-reflection*`                 |

## Decision Flow

```
1. Low-level operation? (Memory, Value manipulation, hot path)
   → Yes: Zig builtin (Tier 1)

2. Special form? (Evaluation order control)
   → Yes: analyzer.zig

3. IO/System? (File, network, time, env)
   → Zig builtin using std.fs, std.time, etc.
   → See roadmap.md "IO / System Namespace Strategy"

4. Pure Clojure possible?
   → Yes: core.clj (Tier 2)

5. JVM-specific?
   → Yes: skip/stub (Tier 3/4)
```

## Tier 1 Criteria (Zig builtin)

- **Low-level ops**: Direct Value manipulation, memory allocation
- **Hot path**: Called frequently in typical code (arithmetic, seq ops)
- **Performance-critical**: Where Zig speed matters (reduce, assoc, etc.)
- **Foundation**: Functions that Tier 2 builds upon

## Tier 2 Criteria (core.clj)

- **Pure combinations**: Only uses existing functions/macros
- **No low-level access**: Doesn't need Value internals
- **Macro definitions**: Most macros belong here (when, cond, ->, etc.)
- **Readable Clojure**: Benefit from standard Clojure idioms

## IO/System: Zig Implementation

JVM IO/System functions are NOT skipped — they're reimplemented in Zig:

| Clojure           | Zig equivalent           |
| ----------------- | ------------------------ |
| `slurp`/`spit`    | `std.fs`                 |
| `Thread/sleep`    | `std.time.sleep`         |
| `System/getenv`   | `std.process.getEnvMap`  |
| `System/nanoTime` | `std.time.nanoTimestamp` |

See roadmap.md "IO / System Namespace Strategy" for details.

## Promotion Path (core.clj → Zig)

During the **Optimization Phase**, functions may be promoted from core.clj
to Zig builtins if:

1. Benchmarks identify them as bottlenecks
2. Zig implementation provides measurable speedup
3. The function is called frequently enough to justify complexity

This is expected and acceptable — start simple in core.clj, optimize later.

## Current Stats

- Zig builtins: 156 functions
- core.clj: 110+ functions/macros
- Special forms: 21 (analyzer.zig)

## References

- `.dev/future.md` SS12 — Tier definitions
- `.dev/plan/roadmap.md` — IO/System strategy, Optimization Phase
- `.dev/status/vars.yaml` — Implementation status tracking
