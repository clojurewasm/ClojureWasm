# ClojureWasm Roadmap — Phase 1-3 Implementation Plan

## Overview

Phases 1-3 of the ClojureWasm production version, based on future.md SS19.
Goal: Reader + Analyzer + Native VM + core builtins, producing a system that
can evaluate basic Clojure expressions with `--compare` mode.

## References

- future.md SS1 (Wasm InterOp: wasm/fn, WIT, Component Model)
- future.md SS2 (Phase 2: Native VM)
- future.md SS3 (Phase 3: Builtin + core.clj AOT)
- future.md SS4 (WIT type mapping)
- future.md SS5 (GC modular design)
- future.md SS8 (architecture, directory structure)
- future.md SS9 (Beta lessons)
- future.md SS10 (VarKind, BuiltinDef, metadata)
- future.md SS17 (directory structure — wasm/ file layout)
- Beta docs/agent_guide_en.md (wasm/ file structure detail)
- Beta src/reader/ (tokenizer.zig 832L, reader.zig 1134L, form.zig 264L)
- Beta src/analyzer/ (analyze.zig 5355L, node.zig 605L)
- Beta src/runtime/ (value.zig 867L, var.zig 265L, namespace.zig 221L, env.zig 218L)
- Beta src/compiler/ (bytecode.zig 543L, emit.zig 897L)
- Beta src/vm/ (vm.zig 1858L)

## Phase 1: Reader + Analyzer

### Phase 1a: Value type foundation

| #   | Task                                               | Archive                   | Notes                                                                                                                                                                                        |
| --- | -------------------------------------------------- | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1.1 | Define Value tagged union in src/common/value.zig  | task_0001_value_union.md  | Start with minimal variants: nil, bool, int, float, string, symbol, keyword, list, vector, map, set. NaN boxing deferred (ADR-0001) — use tagged union first for correctness, optimize later |
| 1.2 | Implement Value.format (print representation)      | task_0002_value_format.md | "{f}" format spec (Zig 0.15). Clojure pr-str semantics. Special char names, float decimal guarantee                                                                                          |
| 1.3 | Implement Value.eql (equality)                     | task_0003_value_eql.md    | Clojure = semantics. Cross-type int/float equality. Structural comparison for all primitive types                                                                                            |
| 1.4 | Implement basic collection types (ArrayList-based) | task_0004_collections.md  | PersistentList, PersistentVector, PersistentArrayMap, PersistentHashSet — array-based like Beta initially                                                                                    |

### Phase 1b: Reader (Source -> Form)

| #   | Task                                                       | Archive                   | Notes                                                                                                                                                         |
| --- | ---------------------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1.5 | Create Tokenizer in src/common/reader/tokenizer.zig        | task_0005_tokenizer.md    | Beta: 832L. Tokens: (, ), [, ], {, }, string, number, symbol, keyword, etc. Input validation (SS14.3): max depth, max string size                             |
| 1.6 | Create Form type in src/common/reader/form.zig             | task_0006_form_type.md    | Beta: 264L. Form = tagged union wrapping Value + source location info                                                                                         |
| 1.7 | Create Reader in src/common/reader/reader.zig              | task_0007_reader.md       | Full reader with read-time macro expansion. All edge cases included (string escapes, regex, numeric literals, reader conditionals, fn literals, syntax-quote) |
| 1.8 | Reader edge cases: string escapes, regex, numeric literals | _(merged into task_0007)_ | Merged into 1.7 — all edge cases covered in single implementation pass                                                                                        |

### Phase 1c: Analyzer (Form -> Node)

| #    | Task                                             | Archive                     | Notes                                                                                                                                       |
| ---- | ------------------------------------------------ | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| 1.9  | Define Node type in src/common/analyzer/node.zig | task_0008_node_type.md      | Core 14 variants: constant, var_ref, local_ref, if, do, let, loop, recur, fn, call, def, quote, throw, try. Advanced variants deferred      |
| 1.10 | Create Analyzer with special form comptime table | task_0009_analyzer.md       | Beta: 5355L (to be redesigned). SS10: special_forms as comptime table, not if-else chain. Start with: if, do, let, fn, def, quote, defmacro |
| 1.11 | Analyzer: loop/recur, try/catch/throw            | task_0011_loop_recur_try.md | Essential control flow                                                                                                                      |
| 1.12 | Analyzer: var resolution, namespace lookup       | --                          | Requires Env/Namespace/Var from Phase 2 runtime                                                                                             |

## Phase 2: Native VM

### Phase 2a: Runtime infrastructure

| #   | Task                                            | Archive                          | Notes                                                                                                                 |
| --- | ----------------------------------------------- | -------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| 2.1 | Create Env (environment) in src/common/env.zig  | task_0012_env.md                 | SS15.5: instantiated VM, no threadlocal. Env holds namespaces, is owned by VM instance. D3a (ErrorContext) completed. |
| 2.2 | Create Namespace in src/common/namespace.zig    | task_0013_namespace.md           | intern/find/refer. Namespace owns Vars. Also created Var (var.zig) and Env integration.                               |
| 2.3 | Create Var in src/common/value/var.zig          | task_0014_var_kind_builtindef.md | SS10: VarKind enum, BuiltinDef metadata (doc, arglists, added). Root binding + thread-local binding stack             |
| 2.4 | Create GcStrategy trait + initial NativeGc stub | task_0015_gc_strategy.md         | SS5: GcStrategy vtable. Start with arena allocator, real GC deferred. Just alloc + no-op collect initially            |

### Phase 2b: Compiler + VM

| #    | Task                                                             | Archive                   | Notes                                                                                                                                |
| ---- | ---------------------------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| 2.5  | Define OpCode enum in src/common/bytecode/opcodes.zig            | task_0016_opcodes.md      | Beta: bytecode.zig 543L. Fixed 3-byte instructions (u8 opcode + u16 operand). Start with ~30 essential opcodes                       |
| 2.6  | Create Compiler (Node -> Bytecode) in src/native/vm/compiler.zig | task_0017_compiler.md     | Beta: emit.zig 897L. Emit bytecode from Node AST. Compiler-VM contract expressed in types (SS9.1)                                    |
| 2.7  | Create VM execution loop in src/native/vm/vm.zig                 | task_0018_vm.md           | Beta: vm.zig 1858L. Stack-based VM. Yield points for GC (SS5). Start with: const_load, call, ret, jump, local_load/store, arithmetic |
| 2.8  | Implement closures and upvalues in VM                            | task_0019_closures.md     | capture_count/slot contract. Critical for fn/let                                                                                     |
| 2.9  | Create TreeWalk evaluator (reference impl)                       | task_0020_tree_walk.md    | SS9.2: --compare mode. Simpler, slower, correct. Node -> Value directly                                                              |
| 2.10 | Wire up --compare mode                                           | task_0021_compare_mode.md | Run both TW and VM, diff results. Key regression detection tool                                                                      |

## Phase 3: Builtins + core.clj AOT

### Phase 3a: VM parity + intrinsics + runtime functions

| #   | Task                                                                                  | Archive                                   | Notes                                                                                                  |
| --- | ------------------------------------------------------------------------------------- | ----------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| 3.1 | Arithmetic intrinsics (+, -, \*, /, mod, rem)                                         | task_0022_arithmetic_intrinsics.md        | VM opcodes for fast path. Compiler emits direct opcodes for intrinsics. Also includes =,not=,<,>,<=,>= |
| 3.2 | VM var/def opcodes (var_load, var_load_dynamic, def)                                  | task_0023_var_def_opcodes.md              | Enable Var resolution in VM. Required for non-intrinsic builtin calls                                  |
| 3.3 | VM recur + tail_call opcodes                                                          | task_0024_recur_tail_call.md              | Loop/recursion support in VM                                                                           |
| 3.4 | VM collection + exception opcodes                                                     | task_0025_collection_exception_opcodes.md | list/vec/map/set_new, try_begin..throw_ex                                                              |
| 3.5 | BuiltinDef registry with metadata                                                     | task_0026_builtin_registry.md             | SS10: VarKind, BuiltinDef, registerCore(). Moved before builtins (was T3.7). Dep: T3.2                 |
| 3.6 | Collection intrinsics (first, rest, cons, conj, assoc, get, nth, count)               | task_0027_collection_intrinsics.md        | Core sequence operations. Dep: T3.4, T3.5                                                              |
| 3.7 | Type predicates (nil?, number?, string?, keyword?, symbol?, map?, vector?, seq?, fn?) | task_0028_type_predicates.md              | Simple type checks on Value tag. Dep: T3.5                                                             |
| 3.8 | Runtime functions: str, pr-str, println, prn                                          | task_0029_str_print_fns.md                | String conversion + I/O. Dep: T3.5                                                                     |
| 3.9 | Runtime functions: atom, deref, swap!, reset!                                         | task_0030_atom.md                         | Atom state management. Dep: T3.5                                                                       |

### Phase 3b: core.clj AOT pipeline

| #    | Task                                                                | Archive                       | Notes                                                                          |
| ---- | ------------------------------------------------------------------- | ----------------------------- | ------------------------------------------------------------------------------ |
| 3.10 | Create clj/core.clj bootstrap (defmacro, defn, when, cond, ->, ->>) | task_0031_core_bootstrap.md   | SS9.6: defmacro is special form in Zig. defn and 40+ macros defined in Clojure |
| 3.11 | Build-time AOT: core.clj -> bytecode -> @embedFile                  | --                            | build.zig step: compile host tool, use it to compile core.clj, embed result    |
| 3.12 | Startup: VM loads embedded bytecode, registers Vars                 | --                            | Fast startup, no parse needed                                                  |
| 3.13 | Higher-order functions in core.clj: map, filter, reduce, take, drop | task_0032_higher_order_fns.md | Pure Clojure definitions, AOT compiled                                         |
| 3.14 | Remaining core macros: if-let, when-let, condp, case, doto, ..      | task_0033_core_macros.md      | Form->Form transformations                                                     |

### Phase 3c: Integration + validation

| #    | Task                                               | Archive                | Notes                                                         |
| ---- | -------------------------------------------------- | ---------------------- | ------------------------------------------------------------- |
| 3.15 | CLI entry point: -e, file.clj, REPL stub           | task_0034_cli.md       | src/main.zig. TreeWalk eval pipeline: read -> analyze -> eval |
| 3.16 | Import SCI Tier 1 tests (5 files)                  | task_0035_sci_tests.md | 17 SCI-style tests + numeric predicates + variadic arith/cmp  |
| 3.17 | Benchmark: startup time, fib(30), basic operations | task_0036_benchmark.md | Startup 2.6ms, fib(30) 3.2s (TreeWalk, Debug)                 |

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

## Phase 4: Production Readiness

### Phase 4a: Infrastructure

| #   | Task                                                       | Archive                      | Notes                                         |
| --- | ---------------------------------------------------------- | ---------------------------- | --------------------------------------------- |
| 4.0 | Phase 4 planning + document update + status tracking setup | task_0037_phase4_planning.md | YAML status, roadmap update, CLAUDE.md update |

### Phase 4b: VM Parity

| #   | Task                                          | Archive                        | Notes                                                 |
| --- | --------------------------------------------- | ------------------------------ | ----------------------------------------------------- |
| 4.1 | VM: variadic arithmetic (+, -, \*, /)         | task_0038_vm_variadic_arith.md | Compiler-level expansion to binary opcodes            |
| 4.2 | VM: type predicates + numeric predicates      | task_0039_vm_predicates.md     | Already functional; 41 compare tests added            |
| 4.3 | VM: collection ops (first, rest, conj, etc.)  | task_0040_vm_collection_ops.md | Already functional; 14 compare tests added            |
| 4.4 | VM: string/IO + atom builtins                 | --                             | str, pr-str, println, prn, atom, deref, swap!, reset! |
| 4.5 | VM: EvalEngine compare-mode parity validation | --                             | Run all SCI tests with --compare                      |

### Phase 4c: core.clj AOT Pipeline

| #   | Task                                                | Archive | Notes                                           |
| --- | --------------------------------------------------- | ------- | ----------------------------------------------- |
| 4.6 | Build-time AOT: core.clj -> bytecode -> @embedFile  | --      | build.zig custom step, host compile tool        |
| 4.7 | Startup: VM loads embedded bytecode, registers Vars | --      | Fast startup, no parse/eval needed for core.clj |

### Phase 4d: Missing Language Features

| #    | Task                             | Archive | Notes                         |
| ---- | -------------------------------- | ------- | ----------------------------- |
| 4.8  | Multi-arity fn                   | --      | (fn ([x] x) ([x y] (+ x y)))  |
| 4.9  | Destructuring (sequential + map) | --      | let, fn, loop binding forms   |
| 4.10 | for macro (list comprehension)   | --      | :let, :when, :while modifiers |
| 4.11 | Protocols + defrecord            | --      | Polymorphic dispatch          |

### Phase 4e: REPL + Wasm

| #    | Task                      | Archive | Notes                             |
| ---- | ------------------------- | ------- | --------------------------------- |
| 4.12 | Interactive REPL          | --      | Line editing, history, completion |
| 4.13 | Wasm target (wasm32-wasi) | --      | Build + test on wasmtime          |

### Phase 4f: Directory Restructuring

| #    | Task                                 | Archive | Notes                                      |
| ---- | ------------------------------------ | ------- | ------------------------------------------ |
| 4.14 | Create src/repl/, src/wasm/ stubs    | --      | Physical directories matching README       |
| 4.15 | Reorganize src/wasm_rt/gc/ structure | --      | Unify gc bridge + backend under wasm_rt/gc |

### Phase 4 Milestone Criteria

- VM passes all SCI Tier 1 tests with --compare mode
- core.clj AOT pipeline works (build -> embed -> startup)
- Multi-arity fn and destructuring supported
- Startup time < 5ms (AOT, release build)
- At least one Wasm target builds and runs basic tests

## Risk Mitigations

| Risk                          | Mitigation                                                       |
| ----------------------------- | ---------------------------------------------------------------- |
| NaN boxing complexity         | Start with tagged union, optimize to NaN boxing later (ADR-0001) |
| GC safe point design          | Start with arena + no-op GC, add real GC when needed             |
| core.clj AOT build complexity | Can fall back to all-Zig builtins (Beta style) initially         |
| Analyzer redesign scope       | Start with minimal special forms (7), add incrementally          |
| Compiler-VM contract bugs     | --compare mode catches mismatches early                          |

## Task Count Summary

| Phase     | Tasks  | Scope                  |
| --------- | ------ | ---------------------- |
| 1a        | 4      | Value type foundation  |
| 1b        | 4      | Reader                 |
| 1c        | 4      | Analyzer               |
| 2a        | 4      | Runtime infrastructure |
| 2b        | 6      | Compiler + VM          |
| 3a        | 9      | VM parity + builtins   |
| 3b        | 5      | core.clj AOT           |
| 3c        | 3      | Integration            |
| **Total** | **39** |                        |
