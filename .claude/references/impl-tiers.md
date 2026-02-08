# Implementation Tier Guidelines

When to implement in Zig builtin vs Clojure (.clj files).

## Function Implementation Tiers

| Tier | Location    | Criteria                               | Examples                               |
| ---- | ----------- | -------------------------------------- | -------------------------------------- |
| 1    | Zig builtin | Low-level ops, hot path, perf-critical | `+`, `first`, `seq`, `reduce`, `assoc` |
| 2    | .clj files  | Pure Clojure, existing fn combinations | `when`, `->`, `walk`, `union`, `split` |
| 3    | N/A (skip)  | JVM-specific, no equivalent            | `compile`, `gen-class`, `proxy`        |
| 4    | Zig stub    | Dynamic vars, config                   | `*warn-on-reflection*`                 |

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
```

**Important**: Do NOT skip features just because they look JVM-specific.
Check `.claude/rules/java-interop.md` (auto-loads on .clj/analyzer/builtin edits).

## Namespace → File Mapping

| Namespace        | Tier | File / Mechanism                |
| ---------------- | ---- | ------------------------------- |
| clojure.core     | 1+2  | `src/clj/clojure/core.clj` + Zig builtins |
| clojure.string   | 1    | Zig builtin                     |
| clojure.set      | 2    | `src/clj/clojure/set.clj`      |
| clojure.walk     | 2    | `src/clj/clojure/walk.clj`     |
| clojure.template | 2    | `src/clj/clojure/template.clj` |
| clojure.test     | 2    | `src/clj/clojure/test.clj`     |
| clojure.data     | 2    | `src/clj/clojure/data.clj`     |
| clojure.repl     | 2    | `src/clj/clojure/repl.clj`     |
| clojure.math     | 1    | Zig builtin (`std.math`)        |
| clojure.java.io  | 1    | Zig builtin (`std.fs`)          |
| cljw.wasm        | 1    | Zig builtin (Wasm FFI)          |
| cljw.http        | 1    | Zig builtin (HTTP server)       |

## IO/System: Zig Equivalents

| Clojure namespace  | Zig equivalent          |
| ------------------ | ----------------------- |
| clojure.java.io    | `std.fs`                |
| clojure.java.shell | `std.process`           |
| clojure.math       | `std.math`              |
| (core) sleep       | `std.time.sleep`        |
| (core) getenv      | `std.process.getEnvMap` |
