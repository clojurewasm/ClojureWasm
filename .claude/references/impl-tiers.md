# Implementation Tier Guidelines

When to implement in Zig builtin vs Clojure (.clj files).

## Function Implementation Tiers

| Tier | Location    | Criteria                               | Examples                               |
| ---- | ----------- | -------------------------------------- | -------------------------------------- |
| 1    | Zig builtin | Low-level ops, hot path, perf-critical | `+`, `first`, `seq`, `reduce`, `assoc` |
| 2    | .clj files  | Pure Clojure, existing fn combinations | `when`, `->`, `walk`, `union`, `split` |
| 3    | N/A (skip)  | JVM-specific, no equivalent            | `compile`, `import`, `agent`, `future` |
| 4    | Zig stub    | Dynamic vars, config                   | `*warn-on-reflection*`                 |

## Namespace Priority Tiers

Prioritized list of namespaces to implement. Source: `.dev/status/vars.yaml`

### Tier A (High Priority)

Core functionality, high demand, Zig/Clojure implementable.

| Namespace        | Done | Total | Implementation     | File                           |
| ---------------- | ---- | ----- | ------------------ | ------------------------------ |
| clojure.core     | 270  | 705   | Zig builtin + .clj | `src/clj/clojure/core.clj`     |
| clojure.string   | 14   | 21    | Zig builtin        | (builtin)                      |
| clojure.walk     | 5    | 10    | Pure Clojure       | `src/clj/clojure/walk.clj`     |
| clojure.template | 2    | 2     | Pure Clojure       | `src/clj/clojure/template.clj` |
| clojure.set      | 0    | 12    | Pure Clojure       | `src/clj/clojure/set.clj`      |
| clojure.java.io  | 0    | 19    | Zig std.fs         | (builtin)                      |
| clojure.math     | 0    | 45    | Zig std.math       | (builtin)                      |
| clojure.edn      | 0    | 2     | Existing reader    | `src/clj/clojure/edn.clj`      |

### Tier B (Medium Priority)

Useful utilities, pure Clojure implementable.

| Namespace          | Done | Total | Implementation         | File                             |
| ------------------ | ---- | ----- | ---------------------- | -------------------------------- |
| clojure.test       | 5    | 39    | Pure Clojure           | `src/clj/clojure/test.clj`       |
| clojure.repl       | 0    | 13    | Pure Clojure + builtin | `src/clj/clojure/repl.clj`       |
| clojure.pprint     | 0    | 26    | Pure Clojure           | `src/clj/clojure/pprint.clj`     |
| clojure.zip        | 0    | 28    | Pure Clojure           | `src/clj/clojure/zip.clj`        |
| clojure.data       | 0    | 5     | Pure Clojure           | `src/clj/clojure/data.clj`       |
| clojure.stacktrace | 0    | 6     | Pure Clojure + builtin | `src/clj/clojure/stacktrace.clj` |
| clojure.java.shell | 0    | 5     | Zig std.process        | (builtin)                        |

### Tier C (Skip - JVM Specific)

True JVM dependencies, no portable equivalent.

| Namespace                | Reason                |
| ------------------------ | --------------------- |
| clojure.java.browse      | Opens system browser  |
| clojure.java.javadoc     | Javadoc lookup        |
| clojure.reflect          | JVM reflection API    |
| clojure.inspector        | Swing GUI             |
| clojure.spec.alpha       | Complex, low priority |
| clojure.spec.gen.alpha   | Depends on spec       |
| clojure.core.specs.alpha | Depends on spec       |
| clojure.core.server      | Socket REPL server    |
| clojure.core.reducers    | Fork/Join parallelism |
| clojure.core.protocols   | Internal protocols    |
| clojure.datafy           | Java class navigation |
| clojure.instant          | Java Date/Timestamp   |
| clojure.main             | JVM entry point       |
| (clojure.template)       | Moved to Tier A       |
| clojure.uuid             | Empty namespace       |

## Decision Flow

```
1. Low-level operation? (Memory, Value manipulation, hot path)
   → Yes: Zig builtin (Tier 1)

2. Special form? (Evaluation order control)
   → Yes: analyzer.zig

3. IO/System? (File, network, time, env)
   → Zig builtin using std.fs, std.time, etc.

4. Appears JVM-specific? (Java interop, .method calls, etc.)
   → First: Can Zig implement equivalent behavior?
     → Yes: Zig builtin (see ClojureWasmBeta for reference)
   → Then: Can pure Clojure implement it?
     → Yes: .clj file
   → Only if truly impossible: skip/stub (Tier 3/4)

5. Pure Clojure possible?
   → Yes: appropriate .clj file (Tier 2)
   → Place in correct namespace (see Namespace Priority above)
```

**Important**: Do NOT skip features just because they look JVM-specific.
Many features (defrecord, sorted-set-by, etc.) can be implemented in Zig.
Check ClojureWasmBeta for proven implementations before deciding to skip.

## Tier 1 Criteria (Zig builtin)

- **Low-level ops**: Direct Value manipulation, memory allocation
- **Hot path**: Called frequently in typical code (arithmetic, seq ops)
- **Performance-critical**: Where Zig speed matters (reduce, assoc, etc.)
- **Foundation**: Functions that Tier 2 builds upon

## Tier 2 Criteria (.clj files)

- **Pure combinations**: Only uses existing functions/macros
- **No low-level access**: Doesn't need Value internals
- **Macro definitions**: Most macros belong here (when, cond, ->, etc.)
- **Readable Clojure**: Benefit from standard Clojure idioms
- **Namespace compatibility**: Place in proper namespace per upstream Clojure

## IO/System: Zig Implementation

JVM IO/System functions are NOT skipped — they're reimplemented in Zig:

| Clojure namespace  | Zig equivalent          |
| ------------------ | ----------------------- |
| clojure.java.io    | `std.fs`                |
| clojure.java.shell | `std.process`           |
| clojure.math       | `std.math`              |
| (core) sleep       | `std.time.sleep`        |
| (core) getenv      | `std.process.getEnvMap` |

## Promotion Path (.clj → Zig)

During the **Optimization Phase**, functions may be promoted from .clj files
to Zig builtins if:

1. Benchmarks identify them as bottlenecks
2. Zig implementation provides measurable speedup
3. The function is called frequently enough to justify complexity

This is expected and acceptable — start simple in .clj, optimize later.

## Current Stats

From `.dev/status/vars.yaml`:

- **Tier A**: 289/814 done (35%)
- **Tier B**: 5/122 done (4%)
- **Tier C**: skipped

Total tracked: 936 vars across 29 namespaces

## References

- `.dev/future.md` SS12 — Tier definitions
- `.dev/plan/roadmap.md` — IO/System strategy, Optimization Phase
- `.dev/status/vars.yaml` — Implementation status tracking
