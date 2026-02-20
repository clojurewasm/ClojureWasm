# InterOp v2 & All-Zig Core Design

> This document captures the architectural discussion and direction for CW's next
> major evolution. Read this at session start when working on Phases 83A-83E.

## Motivation

CW has a working Java interop system (D101) that evolved incrementally. It enables
real-world library compatibility (medley, CSK, honeysql) and upstream test porting.
However, several structural issues limit extensibility, correctness, and performance:

1. **Fragmented registration**: Adding a new Java class requires edits in 5+ files
2. **Silent failures**: Unknown `.method` calls return nil instead of erroring
3. **Exception inconsistency**: `(Exception. "msg")` returns raw string, not a map
4. **Byte-level string ops**: `.charAt`, `.substring` operate on UTF-8 bytes, not codepoints
5. **Handle safety**: `:__handle` raw pointers can dangle after close or GC
6. **Rewrite invisibility**: Analyzer rewrites hide original Java syntax from error messages
7. **Core .clj overhead**: Bootstrap .clj files add startup cost, binary bloat, CLJW marker drift

Additionally, CW's core functions (defined in .clj bootstrap) go through VM interpretation.
Converting these to Zig builtins would eliminate startup deserialization, reduce binary size,
improve performance, and remove the need for CLJW/UPSTREAM-DIFF markers entirely.

## Current Architecture (D101)

```
.clj source
  → Analyzer
    → Class/method  → rewriteInteropCall()  → CW builtin name
    → .method       → __java-method rewrite  → dispatch.zig (runtime)
    → ClassName.    → __interop-new rewrite   → constructors.zig (runtime)
    → instance?     → __instance? rewrite     → predicates.zig (runtime)
    → Class/FIELD   → rewriteStaticField()   → CW var reference
```

Files involved per class:
- `src/interop/rewrites.zig` — static field + method rewrite tables
- `src/interop/constructors.zig` — constructor dispatch + class name resolution
- `src/interop/dispatch.zig` — instance method dispatch by value tag / `:__reify_type`
- `src/interop/classes/*.zig` — per-class method implementations
- `src/builtins/predicates.zig` — `instance?` + `exceptionMatchesClass`
- `src/builtins/registry.zig` — static field constant registration

Object model: class instances = PersistentArrayMap with `:__reify_type` key.
Mutable classes additionally have `:__handle` (opaque Zig pointer via smp_allocator).

### What Works Well (KEEP)

1. **Analyzer-level static rewrites**: `Math/abs` → `abs` at compile time. Zero runtime
   cost. Java concepts never reach VM/evaluator. Clean separation. No changes needed.

2. **Static field → var binding**: `Integer/MAX_VALUE` → `__integer-max-value` var.
   Constants as vars is natural in CW. Comptime registration is efficient.

3. **Map-as-object pattern**: `:__reify_type` maps are Clojure-idiomatic. Printable,
   comparable, assoc-able. More powerful than Java objects in some ways.

4. **Constructor rewrite pipeline**: `(ClassName. args)` → `(__interop-new "fqcn" args)`.
   Syntax handling in analyzer, dispatch in constructors.zig. Clean separation.

5. **Exception map representation**: Aligns with Clojure's `ex-info`/`ex-data` direction.

### Problems to Fix

#### Problem 1: `(Exception. "msg")` Returns Raw String

```clojure
(Exception. "msg")           ;; CW: "msg"          JVM: Exception object
(instance? Exception "hi")   ;; CW: false           (correct, but inconsistent)
(instance? Exception (Exception. "msg"))  ;; CW: false (WRONG — should be true)
```

**Fix**: `(Exception. "msg")` → `{:__ex_info true, :message "msg"}`.
This makes `.getMessage`, `instance?`, `ex-message` all consistent.

#### Problem 2: Unknown Method → Silent Nil

```clojure
(.typo obj)  ;; CW: nil   JVM: IllegalArgumentException
```

**Fix**: Unknown method on any type → error "No method .typo for type X".

#### Problem 3: Byte-Level String Operations

```clojure
(.charAt "あいう" 0)      ;; CW: 0xE3 byte   JVM: \あ (codepoint)
(.substring "あいう" 0 1) ;; CW: broken bytes  JVM: "あ"
(.length "あいう")        ;; CW: 9 (bytes)    JVM: 3 (chars)
```

**Fix**: All string index operations use Unicode codepoint semantics.
Internal representation stays UTF-8. Use `std.unicode.Utf8Iterator` for indexing.
O(n) for indexed access is acceptable (rare in idiomatic Clojure).

Affected: `.charAt`, `.substring`, `.indexOf`, `.length`, `count` on strings,
`subs`, `nth` on strings.

#### Problem 4: `:__handle` Memory Safety

```clojure
(let [sb (StringBuilder.)
      sb2 sb]
  (.close sb)
  (.append sb2 "x"))  ;; dangling pointer → undefined behavior
```

**Fix**:
- Add `closed: bool` flag to handle state
- Use-after-close → clear error
- GC integration: destructor callback when map is collected
- Consider: ref-counting or weak-ref pattern for shared handles

#### Problem 5: Flat Exception Hierarchy

```clojure
(catch Exception e ...)        ;; CW: catches everything (too broad)
(catch ArithmeticException e ...) ;; CW: exact match only (too narrow)
```

**Fix**: Comptime hierarchy table. `(catch RuntimeException e ...)` catches
ArithmeticException, IllegalArgumentException, etc. via `isSubclassOf`.

#### Problem 6: Rewrite Invisibility

```clojure
(Integer/parseInt "abc")  ;; Error shows "parse-long" not "Integer/parseInt"
```

**Fix**: Preserve original form text in AST node during rewrite. Error messages
show original call syntax. Same approach as macro expansion source tracking.

## Target Architecture

### ClassDef Registry (Unified Per-Class Definition)

Replace the 5-file registration pattern with a single `ClassDef` struct:

```zig
// src/interop/class_registry.zig
pub const ClassDef = struct {
    fqcn: []const u8,                        // "java.net.URI"
    aliases: []const []const u8,              // &.{"URI", "java.net.URI"}
    constructor: ?*const ConstructorFn,       // (args) -> Value
    instance_methods: []const MethodEntry,    // .method dispatch table
    static_methods: []const StaticMethodEntry, // Class/method rewrites
    static_fields: []const StaticFieldEntry,  // Class/FIELD constants
    instance_check: ?*const InstanceCheckFn,  // instance? logic
};

pub const MethodEntry = struct {
    name: []const u8,      // "getMessage"
    impl: *const MethodFn, // fn(self: Value, args: []Value) -> Value
};

// All classes registered in one place
pub const registry = [_]ClassDef{
    uri_class,
    file_class,
    uuid_class,
    // ...
};
```

Each class definition lives in its own file (`classes/uri.zig`) and exports a
single `ClassDef`. The registry aggregates them. Analyzer, dispatcher, instance?
checker, and constructor all consult this one registry.

**Adding a new class = 1 new file + 1 line in registry.**

### Protocol-Based Method Dispatch

Integrate `.method` dispatch with CW's existing protocol system:

```
.method call
  → Protocol table lookup (ICloseable, IStringable, etc.)
    → Found → dispatch to protocol implementation
    → Not found → IMethodMissing protocol?
      → Implemented → dispatch (user extensibility)
      → Not implemented → Error: "No method .X for type Y"
```

This means:
- Java "interfaces" become CW protocols
- `deftype`/`defrecord` can implement "Java" protocols
- User types integrate with `.method` dispatch naturally
- Single dispatch mechanism for all method calls

### Exception Hierarchy Table

```zig
// src/interop/exception_hierarchy.zig
const Entry = struct { name: []const u8, parent: ?[]const u8 };

pub const hierarchy = [_]Entry{
    .{ .name = "Throwable",                   .parent = null },
    .{ .name = "Error",                       .parent = "Throwable" },
    .{ .name = "AssertionError",              .parent = "Error" },
    .{ .name = "StackOverflowError",          .parent = "Error" },
    .{ .name = "OutOfMemoryError",            .parent = "Error" },
    .{ .name = "Exception",                   .parent = "Throwable" },
    .{ .name = "RuntimeException",            .parent = "Exception" },
    .{ .name = "ArithmeticException",         .parent = "RuntimeException" },
    .{ .name = "IllegalArgumentException",    .parent = "RuntimeException" },
    .{ .name = "IllegalStateException",       .parent = "RuntimeException" },
    .{ .name = "IndexOutOfBoundsException",   .parent = "RuntimeException" },
    .{ .name = "NumberFormatException",       .parent = "RuntimeException" },
    .{ .name = "UnsupportedOperationException", .parent = "RuntimeException" },
    .{ .name = "ClassCastException",          .parent = "RuntimeException" },
    .{ .name = "NullPointerException",        .parent = "RuntimeException" },
    .{ .name = "IOException",                .parent = "Exception" },
    .{ .name = "FileNotFoundException",       .parent = "IOException" },
    .{ .name = "EOFException",               .parent = "IOException" },
    // ExceptionInfo: special case (ex-info only)
};

/// Returns true if child == parent or child inherits from parent.
pub fn isSubclassOf(child: []const u8, parent: []const u8) bool { ... }
```

~25 lines. CW only needs exceptions it actually throws. Adding new ones = 1 line.
3rd-party libraries using `ex-info` work via `catch ExceptionInfo` (Clojure idiom).

### Core All-Zig Migration

Current: `core functions = Zig builtins + .clj bootstrap (bytecode in binary)`

Target: `core functions = ALL Zig builtins. .clj loading = user code + libraries only.`

#### Why Now

- .clj phase was the exploration phase: learned WHAT to implement, edge cases,
  upstream behavior. This knowledge is captured in tests, CLJW markers, and code.
- All-Zig eliminates: bytecode deserialization at startup, CLJW/UPSTREAM-DIFF markers,
  VM interpretation overhead for core functions, bytecode blob in binary.
- CW's differentiators (speed, small binary, fast startup) all improve.
- Agent-assisted development makes the volume tractable.

#### Migration Strategy

**Invariant**: All existing tests pass after every sub-task. Run zig build test +
e2e + deps_e2e + upstream tests at each step. Record benchmarks at milestones.

Tier 1 (Highest impact — hot-path functions):
- Sequence: `map`, `filter`, `reduce`, `remove`, `take`, `drop`, `take-while`,
  `drop-while`, `partition`, `partition-by`, `group-by`, `frequencies`, `distinct`
- Collection: `assoc`, `dissoc`, `get`, `get-in`, `update`, `update-in`, `merge`,
  `merge-with`, `select-keys`, `into`, `conj`, `contains?`
- These are the most-called functions. VM→native = biggest perf win.

Tier 2 (Macros → Analyzer transforms):
- Control flow: `when`, `when-not`, `when-let`, `when-first`, `when-some`,
  `if-let`, `if-some`, `cond`, `condp`, `case`
- Threading: `->`, `->>`, `as->`, `some->`, `some->>`
- Others: `and`, `or`, `doto`, `..`, `assert`
- These expand at analysis time. Moving from .clj macro to Zig analyzer transform
  eliminates the need to load and register macros at startup.

Tier 3 (Standard library namespaces):
- `clojure.set`, `clojure.string`, `clojure.walk`, `clojure.template`
- `clojure.edn`, `clojure.data`
- Smaller namespaces, straightforward translation.

Tier 4 (Complex functions/macros):
- `defmulti`/`defmethod`, `ns`, `for`, `doseq`, `letfn`
- `defprotocol`, `deftype`, `defrecord`, `reify`
- Complex but understood from .clj phase. Implement last.

Tier 5 (Cleanup):
- Remove .clj bootstrap files for migrated functions
- Remove bytecode cache entries for fully-migrated namespaces
- Remove lazy bootstrap (D104) when no longer needed
- Final measurement: startup, binary size, RSS, benchmarks

#### Lazy Bootstrap After All-Zig

Question: Is lazy init still needed after all-Zig?
Answer: Almost certainly NO.

Current lazy bootstrap (D104) defers bytecode deserialization. With all-Zig,
registration is just: allocate Var, set value = builtin fn pointer, insert in ns map.
For 700+ vars, this is ~hundreds of microseconds. No deserialization needed.

The single-binary model is preserved and simplified. No components, no splitting.

## Phase Plan

### Phase 83A: Exception System Unification

Goal: Consistent exception creation, catching, and method dispatch.

| Sub | Task |
|-----|------|
| 83A.1 | `(Exception. "msg")` → returns `{:__ex_info true, :message "msg"}` instead of raw string. Update constructors.zig. |
| 83A.2 | Exception hierarchy table (`src/interop/exception_hierarchy.zig`). Comptime `isSubclassOf`. |
| 83A.3 | `catch` dispatch uses hierarchy — `(catch RuntimeException e)` catches ArithmeticException etc. Update predicates.zig `exceptionMatchesClass`. |
| 83A.4 | `.getMessage` support — dispatch on `:__ex_info` maps, return `:message` value. |
| 83A.5 | Unknown `.method` → error "No method .X for type Y" instead of nil. |
| 83A.6 | Verify all existing tests pass. Update compilation.clj port. Run e2e + deps_e2e. |

Exit: `(instance? Exception (Exception. "msg"))` → true. Exception hierarchy works.
Unknown methods error. All tests green.

### Phase 83B: InterOp Architecture v2 (ClassDef Registry)

Goal: Unified per-class definition. One file per class, one registry for all.

| Sub | Task |
|-----|------|
| 83B.1 | Design `ClassDef` struct and `class_registry.zig`. |
| 83B.2 | Migrate URI class to ClassDef format (proof of concept). |
| 83B.3 | Migrate remaining classes (File, UUID, PushbackReader, StringBuilder, StringWriter, BufferedWriter). |
| 83B.4 | Migrate String methods into a "virtual" ClassDef for strings. |
| 83B.5 | Unify `instance?` to use ClassDef registry. Remove scattered checks in predicates.zig. |
| 83B.6 | Protocol integration: `.method` dispatch via protocol-like mechanism. |
| 83B.7 | Method Missing → error as protocol fallback. |
| 83B.8 | Source location preservation: Analyzer stores original form text during interop rewrites. Error messages show original Java syntax. |
| 83B.9 | Verify all existing tests + e2e + deps_e2e. |

Exit: New class = 1 file + 1 registry line. dispatch.zig simplified.
Error messages show original Java call syntax.

### Phase 83C: UTF-8 Codepoint Correctness

Goal: String index operations use Unicode codepoints, not bytes.

| Sub | Task |
|-----|------|
| 83C.1 | Implement codepoint utilities: `codepointCount`, `codepointAt`, `codepointSlice` in a shared module. |
| 83C.2 | `.length` on String → codepoint count (not byte count). |
| 83C.3 | `.charAt` → codepoint at index (returns char). |
| 83C.4 | `.substring` → codepoint-based slicing. |
| 83C.5 | `.indexOf` → codepoint-aware search (return codepoint index). |
| 83C.6 | `count` on string → codepoint count. `subs` → codepoint-based. `nth` on string → codepoint. |
| 83C.7 | Multilingual test suite: Japanese, emoji, mixed scripts. |
| 83C.8 | Performance check: ensure ASCII-dominated workloads have no measurable regression. Benchmark. |

Exit: `(.charAt "あいう" 0)` → `\あ`. `(.length "あいう")` → 3. All tests green.

### Phase 83D: Handle Memory Safety

Goal: No dangling pointers, no use-after-close, no handle leaks.

| Sub | Task |
|-----|------|
| 83D.1 | Add `closed` flag to handle state struct. |
| 83D.2 | All handle operations check closed flag → error if closed. |
| 83D.3 | GC finalization: register destructor for handle-bearing maps. |
| 83D.4 | Audit: ensure copy semantics of maps don't create aliased handles (or document shared ownership). |
| 83D.5 | Test: close-then-use, GC-collected handle, concurrent access patterns. |

Exit: Use-after-close → clear error. GC cleans up leaked handles.

### Phase 83E: Core All-Zig Migration

Goal: All standard-library functions implemented as Zig builtins.
.clj loading reserved for user code and libraries.

This is the largest phase. Each tier is independently committable and testable.

| Sub | Task |
|-----|------|
| 83E.1 | Audit: inventory all .clj-defined functions. Categorize by tier (hot-path / macro / stdlib / complex). Count per namespace. |
| 83E.2 | Infrastructure: ensure Zig builtin registration can handle the volume. Namespace auto-creation for new builtins. |
| 83E.3 | Tier 1: Hot-path sequence/collection functions → Zig builtins. Benchmark before/after. |
| 83E.4 | Tier 2: Macros → Zig analyzer transforms. Remove macro loading from bootstrap. |
| 83E.5 | Tier 3: Standard library NS (set, string, walk, etc.) → Zig. |
| 83E.6 | Tier 4: Complex macros/functions (ns, defmulti, for, doseq, etc.) → Zig. |
| 83E.7 | Remove .clj bootstrap files for fully-migrated namespaces. |
| 83E.8 | Remove bytecode cache + lazy bootstrap (D104) when all NS are Zig. |
| 83E.9 | Final measurement: startup, binary size, RSS, full benchmark suite. Record to history. |

Exit: Zero .clj bootstrap for standard library. All core = Zig builtins.
Startup near-instant. Binary size stable or reduced. All tests green.

**Key invariant for 83E**: After each sub-task within a tier, ALL tests must pass.
The migration is function-by-function within each tier. At any point, the system is
a hybrid of Zig builtins and .clj-defined functions — both work together.

## Dependencies

```
83A (Exception) ──► 83B (InterOp v2) ──► 83C (UTF-8)
                                    └──► 83D (Handle Safety)
83A + 83B + 83C + 83D ──► 83E (All-Zig)
83E ──► 84 (Testing Expansion, was previously next)
```

83E depends on 83A-83D because:
- The .clj→Zig migration benefits from the unified ClassDef registry (83B)
- Exception handling in Zig builtins uses the new hierarchy (83A)
- String functions in Zig use codepoint semantics (83C)
- Handle-bearing operations use the safe pattern (83D)

## Testing Strategy (ALL PHASES)

Every sub-task must:
1. `zig build test` — all unit tests pass
2. `bash test/e2e/run_e2e.sh` — 6/6 e2e tests
3. `bash test/e2e/deps/run_deps_e2e.sh` — 14/14 deps e2e tests
4. Run affected upstream test files

Benchmark recording at phase boundaries:
- `bash bench/run_bench.sh --quick` — no regression
- `bash bench/record.sh --id="83X.Y" --reason="description"` — at milestones

Non-functional gates (per CLAUDE.md Commit Gate #8):
- Binary size ≤ 4.5MB (may decrease during 83E)
- Startup ≤ 5ms (should improve during 83E)
- RSS ≤ 12MB

## Open Questions (Resolve During Implementation)

1. **Protocol dispatch granularity**: Should every Java method name map to a distinct
   protocol, or group by interface (ICloseable = {close}, IReadable = {read, readLine})?
   → Decide in 83B.1 design phase.

2. **String .length semantics**: Java returns UTF-16 code unit count, not codepoint count.
   For BMP characters these are the same. For supplementary characters (emoji), they differ.
   CW should probably return codepoint count (more correct than UTF-16 units).
   → Decide in 83C.1.

3. **Handle GC integration**: Zig's GC doesn't have finalizers. Options: weak ref table,
   explicit destructor registry, or ref-counting. → Research in 83D.3.

4. **All-Zig macro representation**: Currently macros are .clj functions with `:macro true`
   metadata. In all-Zig, macros become analyzer transforms. Need to ensure `macroexpand`
   still works for user introspection. → Design in 83E.4.

5. **Lazy bootstrap removal timing**: Remove D104 only after ALL namespaces are Zig.
   If some NS stay .clj (e.g., pprint is very complex), keep lazy bootstrap for those.
   → Assess in 83E.7.
