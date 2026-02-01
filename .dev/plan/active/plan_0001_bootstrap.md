# plan_0001_bootstrap — Phase 1-3 Implementation Plan

## Overview

Phases 1-3 of the ClojureWasm production version, based on future.md SS19.
Goal: Reader + Analyzer + Native VM + core builtins, producing a system that
can evaluate basic Clojure expressions with `--compare` mode.

## References

- future.md SS1 (Phase 1: Reader + Analyzer)
- future.md SS2 (Phase 2: Native VM)
- future.md SS3 (Phase 3: Builtin + core.clj AOT)
- future.md SS5 (GC modular design)
- future.md SS8 (architecture, directory structure)
- future.md SS9 (Beta lessons)
- future.md SS10 (VarKind, BuiltinDef, metadata)
- future.md SS17 (directory structure)
- Beta src/reader/ (tokenizer.zig 832L, reader.zig 1134L, form.zig 264L)
- Beta src/analyzer/ (analyze.zig 5355L, node.zig 605L)
- Beta src/runtime/ (value.zig 867L, var.zig 265L, namespace.zig 221L, env.zig 218L)
- Beta src/compiler/ (bytecode.zig 543L, emit.zig 897L)
- Beta src/vm/ (vm.zig 1858L)

## Phase 1: Reader + Analyzer

### Phase 1a: Value type foundation

Before reader/analyzer, we need the Value type that Form will reference.

| #   | Task                                               | Status  | Notes                                                                                                                                                                                        |
|-----|----------------------------------------------------|---------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1.1 | Define Value tagged union in src/common/value.zig  | pending | Start with minimal variants: nil, bool, int, float, string, symbol, keyword, list, vector, map, set. NaN boxing deferred (ADR-0001) — use tagged union first for correctness, optimize later |
| 1.2 | Implement Value.format (print representation)      | pending | "{}", Clojure pr-str semantics. Required for test assertions                                                                                                                                 |
| 1.3 | Implement Value.eql (equality)                     | pending | Clojure = semantics (structural equality). Required for test assertions                                                                                                                      |
| 1.4 | Implement basic collection types (ArrayList-based) | pending | PersistentList, PersistentVector, PersistentArrayMap, PersistentHashSet — array-based like Beta initially                                                                                    |

### Phase 1b: Reader (Source -> Form)

| #   | Task                                                       | Status  | Notes                                                                                                                             |
|-----|------------------------------------------------------------|---------|-----------------------------------------------------------------------------------------------------------------------------------|
| 1.5 | Create Tokenizer in src/common/reader/tokenizer.zig        | pending | Beta: 832L. Tokens: (, ), [, ], {, }, string, number, symbol, keyword, etc. Input validation (SS14.3): max depth, max string size |
| 1.6 | Create Form type in src/common/reader/form.zig             | pending | Beta: 264L. Form = tagged union wrapping Value + source location info                                                             |
| 1.7 | Create Reader in src/common/reader/reader.zig              | pending | Beta: 1134L. Tokenizer -> Form. S-expression parsing, quote/deref/meta reader macros                                              |
| 1.8 | Reader edge cases: string escapes, regex, numeric literals | pending | Unicode escapes, ratios, BigInt (skip), hex/octal literals                                                                        |

### Phase 1c: Analyzer (Form -> Node)

| #    | Task                                             | Status  | Notes                                                                                                                                       |
|------|--------------------------------------------------|---------|---------------------------------------------------------------------------------------------------------------------------------------------|
| 1.9  | Define Node type in src/common/analyzer/node.zig | pending | Beta: 605L. AST node types for each special form + generic call/literal                                                                     |
| 1.10 | Create Analyzer with special form comptime table | pending | Beta: 5355L (to be redesigned). SS10: special_forms as comptime table, not if-else chain. Start with: if, do, let, fn, def, quote, defmacro |
| 1.11 | Analyzer: loop/recur, try/catch/throw            | pending | Essential control flow                                                                                                                      |
| 1.12 | Analyzer: var resolution, namespace lookup       | pending | Requires Env/Namespace/Var from Phase 2 runtime                                                                                             |

## Phase 2: Native VM

### Phase 2a: Runtime infrastructure

| #   | Task                                                 | Status  | Notes                                                                                                      |
|-----|------------------------------------------------------|---------|------------------------------------------------------------------------------------------------------------|
| 2.1 | Create Env (environment) in src/common/value/env.zig | pending | SS15.5: instantiated VM, no threadlocal. Env holds namespaces, is owned by VM instance                     |
| 2.2 | Create Namespace in src/common/value/namespace.zig   | pending | intern/find/refer. Namespace owns Vars                                                                     |
| 2.3 | Create Var in src/common/value/var.zig               | pending | SS10: VarKind enum, BuiltinDef metadata (doc, arglists, added). Root binding + thread-local binding stack  |
| 2.4 | Create GcStrategy trait + initial NativeGc stub      | pending | SS5: GcStrategy vtable. Start with arena allocator, real GC deferred. Just alloc + no-op collect initially |

### Phase 2b: Compiler + VM

| #    | Task                                                             | Status  | Notes                                                                                                                                |
|------|------------------------------------------------------------------|---------|--------------------------------------------------------------------------------------------------------------------------------------|
| 2.5  | Define OpCode enum in src/common/bytecode/opcodes.zig            | pending | Beta: bytecode.zig 543L. Fixed 3-byte instructions (u8 opcode + u16 operand). Start with ~30 essential opcodes                       |
| 2.6  | Create Compiler (Node -> Bytecode) in src/native/vm/compiler.zig | pending | Beta: emit.zig 897L. Emit bytecode from Node AST. Compiler-VM contract expressed in types (SS9.1)                                    |
| 2.7  | Create VM execution loop in src/native/vm/vm.zig                 | pending | Beta: vm.zig 1858L. Stack-based VM. Yield points for GC (SS5). Start with: const_load, call, ret, jump, local_load/store, arithmetic |
| 2.8  | Implement closures and upvalues in VM                            | pending | capture_count/slot contract. Critical for fn/let                                                                                     |
| 2.9  | Create TreeWalk evaluator (reference impl)                       | pending | SS9.2: --compare mode. Simpler, slower, correct. Node -> Value directly                                                              |
| 2.10 | Wire up --compare mode                                           | pending | Run both TW and VM, diff results. Key regression detection tool                                                                      |

## Phase 3: Builtins + core.clj AOT

### Phase 3a: VM intrinsics + runtime functions

| #   | Task                                                                                  | Status  | Notes                                                                                    |
|-----|---------------------------------------------------------------------------------------|---------|------------------------------------------------------------------------------------------|
| 3.1 | Arithmetic intrinsics (+, -, *, /, mod, rem)                                          | pending | VM opcodes for fast path                                                                 |
| 3.2 | Comparison intrinsics (=, <, >, <=, >=, not=)                                         | pending | Value.eql for =, numeric comparison for rest                                             |
| 3.3 | Collection intrinsics (first, rest, cons, conj, assoc, get, nth, count)               | pending | Core sequence operations                                                                 |
| 3.4 | Type predicates (nil?, number?, string?, keyword?, symbol?, map?, vector?, seq?, fn?) | pending | Simple type checks on Value tag                                                          |
| 3.5 | Runtime functions: str, pr-str, println, prn                                          | pending | String conversion + I/O                                                                  |
| 3.6 | Runtime functions: atom, deref, swap!, reset!                                         | pending | Atom state management                                                                    |
| 3.7 | BuiltinDef registry with metadata                                                     | pending | SS10: doc, arglists, added, kind, since-cw. comptime table. registerCore() populates Env |

### Phase 3b: core.clj AOT pipeline

| #    | Task                                                                | Status  | Notes                                                                          |
|------|---------------------------------------------------------------------|---------|--------------------------------------------------------------------------------|
| 3.8  | Create clj/core.clj bootstrap (defmacro, defn, when, cond, ->, ->>) | pending | SS9.6: defmacro is special form in Zig. defn and 40+ macros defined in Clojure |
| 3.9  | Build-time AOT: core.clj -> bytecode -> @embedFile                  | pending | build.zig step: compile host tool, use it to compile core.clj, embed result    |
| 3.10 | Startup: VM loads embedded bytecode, registers Vars                 | pending | Fast startup, no parse needed                                                  |
| 3.11 | Higher-order functions in core.clj: map, filter, reduce, take, drop | pending | Pure Clojure definitions, AOT compiled                                         |
| 3.12 | Remaining core macros: if-let, when-let, condp, case, doto, ..      | pending | Form->Form transformations                                                     |

### Phase 3c: Integration + validation

| #    | Task                                               | Status  | Notes                                                                          |
|------|----------------------------------------------------|---------|--------------------------------------------------------------------------------|
| 3.13 | CLI entry point: -e, file.clj, REPL stub           | pending | src/native/main.zig. Basic eval pipeline: read -> analyze -> compile -> vm.run |
| 3.14 | Import SCI Tier 1 tests (5 files)                  | pending | SS10: deterministic rule transformation                                        |
| 3.15 | Benchmark: startup time, fib(30), basic operations | pending | Establish baseline numbers                                                     |

## Milestone Criteria

### Phase 1 complete when:
- Reader can parse all standard Clojure literals and data structures
- Analyzer produces correct AST for special forms + function calls
- `zig build test` passes all reader/analyzer tests

### Phase 2 complete when:
- `(+ 1 2)` evaluates to `3` via both TW and VM
- `(defn f [x] (+ x 1)) (f 10)` returns `11`
- `(let [x 1 y 2] (+ x y))` returns `3`
- `--compare` mode detects intentionally wrong VM output
- Closures work: `((fn [x] (fn [y] (+ x y))) 1 2)` returns `3`

### Phase 3 complete when:
- core.clj AOT pipeline works: build -> embed -> startup -> eval
- `(map inc [1 2 3])` returns `(2 3 4)` (map defined in core.clj)
- ~200 core functions available (matching Beta's primary set)
- SCI Tier 1 tests pass (5 files, ~4000 lines)
- Startup time < 10ms

## Risk Mitigations

| Risk                          | Mitigation                                                       |
|-------------------------------|------------------------------------------------------------------|
| NaN boxing complexity         | Start with tagged union, optimize to NaN boxing later (ADR-0001) |
| GC safe point design          | Start with arena + no-op GC, add real GC when needed             |
| core.clj AOT build complexity | Can fall back to all-Zig builtins (Beta style) initially         |
| Analyzer redesign scope       | Start with minimal special forms (7), add incrementally          |
| Compiler-VM contract bugs     | --compare mode catches mismatches early                          |

## Task Count Summary

| Phase     | Tasks  | Scope                  |
|-----------|--------|------------------------|
| 1a        | 4      | Value type foundation  |
| 1b        | 4      | Reader                 |
| 1c        | 4      | Analyzer               |
| 2a        | 4      | Runtime infrastructure |
| 2b        | 6      | Compiler + VM          |
| 3a        | 7      | Builtins               |
| 3b        | 5      | core.clj AOT           |
| 3c        | 3      | Integration            |
| **Total** | **37** |                        |
