# All-Zig Migration Plan

> Zero .clj in CW's processing pipeline. Upstream test .clj files are OK.

## Current State

- 25 .clj files, 9,848 lines, 23 @embedFile in bootstrap.zig
- 410 Zig builtins registered, 186 core.clj defn (only 6 overlap)
- 2 defmacros remain: `ns`, `case`
- Bootstrap pipeline: cache_gen → serialize → @embedFile → deserialize

## Phases

### Phase A: Core functions → Zig builtins (core.clj 2,109 lines → 0)

180 defn/defn- need new Zig builtins. 35 def need Zig registration.
2 defmacro (ns, case) need Zig transforms.

Strategy: batch by dependency order (bottom-up from core.clj).

| Batch | Scope | Est. functions |
|-------|-------|----------------|
| A.1 | Simple predicates & type utils (boolean, true?, false?, some?, any?, ident?, etc.) | ~20 |
| A.2 | Arithmetic & comparison wrappers (inc', dec', quot, rem, mod, abs, etc.) | ~15 |
| A.3 | Collection constructors & accessors (get-in, assoc-in, update-in, select-keys, etc.) | ~20 |
| A.4 | Sequence functions (dorun, doall, flatten, group-by, frequencies, etc.) | ~25 |
| A.5 | Higher-order (memoize, trampoline, juxt, fnil, comp overloads, etc.) | ~15 |
| A.6 | String/print utilities (format, printf, pr-str overloads, etc.) | ~10 |
| A.7 | Transducer/reduce compositions (transduce, into, sequence, eduction, etc.) | ~15 |
| A.8 | Hierarchy & multimethod helpers (isa?, derive, underive, prefer-method, etc.) | ~15 |
| A.9 | Concurrency (future-call, pmap, pcalls, agent wrappers, promise, etc.) | ~15 |
| A.10 | Destructure, ex-info, special vars, remaining defs | ~30 |
| A.11 | `ns` macro → Zig transform | 1 |
| A.12 | `case` macro → Zig transform (needs hash computation in Zig) | 1 |

### Phase B: Library namespaces → Zig builtins (7,739 lines → 0)

24 non-core .clj files. Ordered by size (small → large).

| Batch | File(s) | Lines | Functions |
|-------|---------|-------|-----------|
| B.1 | uuid, template | 46 | 3 |
| B.2 | java/shell, java/browse | 74 | 5 |
| B.3 | repl/deps, datafy, core/protocols | 120 | 8 |
| B.4 | walk, stacktrace | 150 | 16 |
| B.5 | core/server, data | 161 | 12 |
| B.6 | set | 126 | 13 |
| B.7 | java/io, java/process | 302 | 12 |
| B.8 | instant | 189 | 11 |
| B.9 | zip | 279 | 28 |
| B.10 | repl | 245 | 14 |
| B.11 | xml | 251 | 17 |
| B.12 | main | 294 | 17 |
| B.13 | core/reducers | 316 | 17 |
| B.14 | test, test/tap | 565 | 39 |
| B.15 | spec/alpha, spec/gen/alpha, core/specs/alpha | 2,365 | ~140 |
| B.16 | pprint | 2,732 | ~180 |

### Phase C: Bootstrap pipeline elimination

| Step | Task |
|------|------|
| C.1 | Remove all @embedFile for .clj sources from bootstrap.zig |
| C.2 | Remove loadBootstrapAll(), vmRecompileAll(), hot_core_defs |
| C.3 | Remove cache_gen.zig, build.zig cache step |
| C.4 | Simplify serialize.zig (keep bytecode serialization for user code) |
| C.5 | Simplify main.zig startup: registerBuiltins → ready |

### Phase D: Directory & module refactoring

Reorganize `src/builtins/` from category-based to namespace-mapped.

```
src/builtins/
  core/                    # clojure.core (split by category, same as now)
    arithmetic.zig
    collections.zig
    predicates.zig
    sequences.zig
    strings.zig
    io.zig
    atom.zig
    metadata.zig
    misc.zig
    multimethods.zig
    array.zig
    transient.zig
    eval.zig
    chunk.zig
    system.zig
    concurrency.zig       # new: future, agent, promise
    hierarchy.zig         # new: isa?, derive, etc.
    destructure.zig       # new: destructure fn
    special_vars.zig      # new: *print-length* etc.
  string.zig              # clojure.string (exists: clj_string_builtins)
  set.zig                 # clojure.set (new)
  walk.zig                # clojure.walk (new)
  data.zig                # clojure.data (new)
  zip.zig                 # clojure.zip (new)
  xml.zig                 # clojure.xml (new)
  test.zig                # clojure.test (new)
  pprint.zig              # clojure.pprint (extends existing)
  repl.zig                # clojure.repl (new)
  spec/                   # clojure.spec.alpha (new)
    alpha.zig
    gen.zig
  java/                   # clojure.java.* (extends existing)
    io.zig
    shell.zig
    browse.zig
    process.zig
  main.zig                # clojure.main (new)
  instant.zig             # clojure.instant (new)
  stacktrace.zig          # clojure.stacktrace (new)
  template.zig            # clojure.template (new)
  uuid.zig                # clojure.uuid (new)
  datafy.zig              # clojure.datafy (new)
  reducers.zig            # clojure.core.reducers (new)
  math.zig                # clojure.math (exists)
  registry.zig            # master registry (exists)
```

Each file exports `pub const builtins: []const BuiltinEntry` registered via registry.

### Phase E: Optimization

Re-apply performance constraints incrementally:

| Step | Target | Approach |
|------|--------|----------|
| E.1 | Binary < 4.5MB | comptime string dedup, shared patterns |
| E.2 | Startup < 5ms | lazy namespace registration |
| E.3 | Benchmarks ≤ 1.2x | profile hot paths, optimize critical builtins |
| E.4 | Restore baselines.md thresholds | final verification |

## Constraints (temporary relaxation)

During Phases A-D, the following baselines.md thresholds are SUSPENDED:
- Binary size (may grow to ~6MB)
- Startup time (may grow to ~10ms)

Benchmarks MUST NOT regress > 2x (safety net only).
All tests MUST pass after every sub-task.

## Verification (every batch)

1. `zig build test` — all unit + upstream tests pass
2. `bash test/e2e/run_e2e.sh` — 6/6
3. `bash test/e2e/deps/run_deps_e2e.sh` — 14/14
4. Both VM + TreeWalk verified
