# ClojureWasm Roadmap — Phase 1-3 Implementation Plan

## Overview

Phases 1-3 of the ClojureWasm production version, based on .dev/future.md SS19.
Goal: Reader + Analyzer + Native VM + core builtins, producing a system that
can evaluate basic Clojure expressions with `--compare` mode.

## References

- .dev/future.md SS1 (Wasm InterOp: wasm/fn, WIT, Component Model)
- .dev/future.md SS2 (Phase 2: Native VM)
- .dev/future.md SS3 (Phase 3: Builtin + core.clj AOT)
- .dev/future.md SS4 (WIT type mapping)
- .dev/future.md SS5 (GC modular design)
- .dev/future.md SS8 (architecture, directory structure)
- .dev/future.md SS9 (Beta lessons)
- .dev/future.md SS10 (BuiltinDef, metadata — VarKind removed in D31)
- .dev/future.md SS17 (directory structure — wasm/ file layout)
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

| #   | Task                                          | Archive                            | Notes                                      |
| --- | --------------------------------------------- | ---------------------------------- | ------------------------------------------ |
| 4.1 | VM: variadic arithmetic (+, -, \*, /)         | task_0038_vm_variadic_arith.md     | Compiler-level expansion to binary opcodes |
| 4.2 | VM: type predicates + numeric predicates      | task_0039_vm_predicates.md         | Already functional; 41 compare tests added |
| 4.3 | VM: collection ops (first, rest, conj, etc.)  | task_0040_vm_collection_ops.md     | Already functional; 14 compare tests added |
| 4.4 | VM: string/IO + atom builtins                 | task_0041_vm_string_io_atom.md     | Already functional; 3 compare tests added  |
| 4.5 | VM: EvalEngine compare-mode parity validation | task_0042_vm_compare_validation.md | Deferred: needs AOT pipeline (T4.6/T4.7)   |

### Phase 4c: core.clj AOT Pipeline

| #   | Task                                                | Archive                   | Notes                                            |
| --- | --------------------------------------------------- | ------------------------- | ------------------------------------------------ |
| 4.6 | VM-based eval pipeline (evalStringVM)               | task_0043_aot_pipeline.md | VM backend for user code; TreeWalk for bootstrap |
| 4.7 | Startup: VM loads embedded bytecode, registers Vars | --                        | Fast startup, no parse/eval needed for core.clj  |

### Phase 4d: Missing Language Features

| #    | Task                             | Archive                          | Notes                                        |
| ---- | -------------------------------- | -------------------------------- | -------------------------------------------- |
| 4.8  | Multi-arity fn                   | task_0044_multi_arity_fn.md      | Fixed-arity dispatch; variadic rest deferred |
| 4.9  | Destructuring (sequential + map) | task_0045_destructuring.md       | let, fn, loop binding forms                  |
| 4.10 | for macro (list comprehension)   | task_0046_for_macro.md           | :let, :when, :while modifiers                |
| 4.11 | Protocols + defrecord            | task_0047_protocols_defrecord.md | Polymorphic dispatch                         |

### Phase 4e: REPL + Wasm

| #    | Task                      | Archive                       | Notes                                        |
| ---- | ------------------------- | ----------------------------- | -------------------------------------------- |
| 4.12 | Interactive REPL          | task_0048_interactive_repl.md | Multi-line, error recovery, TreeWalk backend |
| 4.13 | Wasm target (wasm32-wasi) | task_0049_wasm_target.md      | `zig build wasm`, 207KB ReleaseSmall         |

### Phase 4f: Directory Restructuring

| #    | Task                                 | Archive                      | Notes                                    |
| ---- | ------------------------------------ | ---------------------------- | ---------------------------------------- |
| 4.14 | Create src/repl/, src/wasm/ stubs    | task_0050_dir_restructure.md | Combined with T4.15                      |
| 4.15 | Reorganize src/wasm_rt/gc/ structure | task_0050_dir_restructure.md | gc/bridge + gc/backend under wasm_rt/gc/ |

### Phase 4 Milestone Criteria

- ~~VM passes all SCI Tier 1 tests with --compare mode~~ (Partial: VM works but compare mode needs AOT — deferred)
- ~~core.clj AOT pipeline works (build -> embed -> startup)~~ (Partial: T4.6 evalStringVM done, T4.7 AOT embed deferred — needs F7)
- ~~Multi-arity fn and destructuring supported~~ (Done: T4.8, T4.9)
- ~~Startup time < 5ms (AOT, release build)~~ (Deferred: no AOT yet)
- ~~At least one Wasm target builds and runs basic tests~~ (Done: T4.13, 207KB)

## Phase 5: Benchmark System

| #   | Task                            | Archive              | Notes                               |
| --- | ------------------------------- | -------------------- | ----------------------------------- |
| 5.1 | Add python314, ruby_4_0, jdk25  | (done, no task file) | flake.nix language upgrades         |
| 5.2 | Benchmark framework + meta.yaml | (done, no task file) | bench/ directory structure          |
| 5.3 | Implement 11 benchmarks         | (done, no task file) | 5 categories, hyperfine integration |
| 5.4 | Multi-language runners          | (done, no task file) | C, Zig, Java, Python, Ruby, Clj, BB |
| 5.5 | bench.yaml 2-gen rotation       | (done, no task file) | --record with delta display         |
| 5.6 | Record Phase 5 baseline         | (done, no task file) | TreeWalk, Debug build results       |

## Phase 6: Core Library Expansion

### Phase 6a: Essential Missing Builtins (Zig-level)

| #   | Task                                                     | Archive                    | Notes                          |
| --- | -------------------------------------------------------- | -------------------------- | ------------------------------ |
| 6.1 | Sequence utilities: range, repeat, iterate               | task_0052_seq_utilities.md | Merged with T6.2; eager impl   |
| 6.2 | Collection queries: empty?, contains?, keys, vals        | task_0052_seq_utilities.md | Merged into T6.1               |
| 6.3 | Collection builders: hash-set, sorted-map, zipmap        | --                         | New collection construction    |
| 6.4 | Numeric functions: abs, max, min, quot, rand, rand-int   | task_0053_numeric_fns.md   | Math operations                |
| 6.5 | String functions: subs, name, namespace, keyword, symbol | (in strings.zig)           | String manipulation + coercion |

### Phase 6b: Core Library Expansion (core.clj)

| #    | Task                                                                                   | Archive    | Notes                           |
| ---- | -------------------------------------------------------------------------------------- | ---------- | ------------------------------- |
| 6.6  | Assoc/update family: assoc-in, update, update-in, get-in, select-keys                  | (core.clj) | Deep nested ops                 |
| 6.7  | Predicate/search: some, every?, not-every?, not-any?, distinct, frequencies            | (core.clj) | All done                        |
| 6.8  | Sequence transforms: partition, partition-by, group-by, flatten, interleave, interpose | (core.clj) | All done                        |
| 6.9  | Function combinators: partial, comp, juxt, memoize, trampoline                         | (core.clj) | Partial (no memoize/trampoline) |
| 6.10 | Utility macros: doto, as->, cond->, cond->>, if-let, when-let, some->, some->>         | (core.clj) | Partial (if-let, when-let)      |

### Phase 6c: Validation

| #    | Task                         | Archive | Notes                                  |
| ---- | ---------------------------- | ------- | -------------------------------------- |
| 6.11 | SCI Tier 2 test expansion    | --      | 30+ test cases for new functions       |
| 6.12 | Benchmark re-run + recording | --      | Regression check + new function impact |

## Phase 7: Robustness + nREPL

### Phase 7a: Robustness Fixes

| #   | Task                           | Archive                         | Notes                                        |
| --- | ------------------------------ | ------------------------------- | -------------------------------------------- |
| 7.1 | TreeWalk stack depth fix (F11) | task_0055_stack_depth.md        | MAX_CALL_DEPTH=512 + heap-alloc saved locals |
| 7.2 | str dynamic buffer (F12)       | task_0056_str_dynamic_buffer.md | Writer.Allocating replaces fixed 4KB buffer  |

### Phase 7b: Core Library Expansion II

| #   | Task                                            | Archive                         | Notes                                                  |
| --- | ----------------------------------------------- | ------------------------------- | ------------------------------------------------------ |
| 7.3 | Missing core macros: doto, as->, cond->, some-> | task_0057_threading_macros.md   | 6 threading variants added to core.clj                 |
| 7.4 | Multimethod: defmulti, defmethod                | task_0058_multimethod.md        | Dynamic dispatch without protocols                     |
| 7.5 | Exception handling: try/catch/throw + ex-info   | task_0059_exception_handling.md | Already implemented; added ex-info/ex-data/ex-message  |
| 7.6 | Lazy sequences: lazy-seq, lazy-cat              | task_0060_lazy_seq.md           | LazySeq+Cons types; iterate, repeat, repeatedly, cycle |

### Phase 7c: nREPL Server

| #   | Task                                     | Archive                       | Notes                                       |
| --- | ---------------------------------------- | ----------------------------- | ------------------------------------------- |
| 7.7 | bencode encoder/decoder                  | task_0061_bencode.md          | nREPL wire protocol; 9 tests                |
| 7.8 | nREPL server (TCP socket)                | task_0062_nrepl_server.md     | eval, load-file, describe, completions ops  |
| 7.9 | nREPL middleware: completion, stacktrace | task_0063_nrepl_middleware.md | CIDER compat: stdin, interrupt, *1/*2/*3/*e |

## Phase 8: Refactoring

| #    | Task                                            | Archive                          | Notes                         |
| ---- | ----------------------------------------------- | -------------------------------- | ----------------------------- |
| 8.R1 | Remove TreeWalk D26 sentinel dispatch dead code | task_0064_treewalk_dead_code.md  | ~180 lines removed            |
| 8.R2 | Extract shared helpers in bootstrap.zig         | task_0065_bootstrap_dedup.md     | evalString/evalStringVM dedup |
| 8.R3 | Unify arithmetic/comparison in arithmetic.zig   | task_0066_arith_consolidation.md | Wrapping op bug fixed         |

## Phase 9: Core Library Expansion III

### Phase 9a: Essential Collection Operations (Zig builtins)

| #   | Task                                    | Archive                    | Notes                                          |
| --- | --------------------------------------- | -------------------------- | ---------------------------------------------- |
| 9.1 | merge, merge-with, zipmap               | task_0068_merge_zipmap.md  | Map merging — very high frequency              |
| 9.2 | sort, sort-by, compare                  | task_0069_sort_compare.md  | Sorting — needs Zig-level comparator           |
| 9.3 | vec, set, into (improved), list\*       | task_0070_type_coercion.md | Type coercion — used everywhere                |
| 9.4 | meta, with-meta, vary-meta, alter-meta! | --                         | Metadata system — prerequisite for many things |

### Phase 9b: Core Library Expansion (core.clj)

| #   | Task                                    | Archive                            | Notes                                 |
| --- | --------------------------------------- | ---------------------------------- | ------------------------------------- |
| 9.5 | map-indexed, keep, keep-indexed, remove | task_0071_hof_expansion.md         | High-frequency HOFs                   |
| 9.6 | mapv, filterv, reduce-kv                | task_0072_mapv_filterv_reducekv.md | Vector-returning variants + kv reduce |
| 9.7 | partition-all, take-while, drop-while   | task_0073_seq_slicing.md           | Sequence slicing                      |
| 9.8 | butlast, last, second, nfirst, fnext    | task_0074_convenience_accessors.md | Convenience accessors                 |
| 9.9 | not-empty, every-pred, some-fn, fnil    | task_0075_pred_fn_utils.md         | Predicate/function utilities          |

### Phase 9c: Control Flow + Utility Macros

| #    | Task                          | Archive                           | Notes                                     |
| ---- | ----------------------------- | --------------------------------- | ----------------------------------------- |
| 9.10 | while, doseq, doall, dorun    | task_0076_imperative_iteration.md | Imperative iteration                      |
| 9.11 | case, condp, declare, defonce | task_0077_control_macros.md       | Missing control macros (defonce deferred) |
| 9.12 | delay, force, realized?       | task_0078_delay.md                | Delayed evaluation                        |

### Phase 9d: Misc Builtins

| #    | Task                                            | Archive                         | Notes                             |
| ---- | ----------------------------------------------- | ------------------------------- | --------------------------------- |
| 9.13 | boolean, true?, false?, some?, any?             | task_0079_basic_predicates.md   | Basic predicates (core.clj)       |
| 9.14 | bit-and, bit-or, bit-xor, bit-not, bit-shift-\* | task_0080_bitwise.md            | Bitwise operations (Zig builtins) |
| 9.15 | type, class, instance?, isa?                    | task_0081_type_introspection.md | Type introspection                |

## Risk Mitigations

| Risk                          | Mitigation                                                       |
| ----------------------------- | ---------------------------------------------------------------- |
| NaN boxing complexity         | Start with tagged union, optimize to NaN boxing later (ADR-0001) |
| GC safe point design          | Start with arena + no-op GC, add real GC when needed             |
| core.clj AOT build complexity | Can fall back to all-Zig builtins (Beta style) initially         |
| Analyzer redesign scope       | Start with minimal special forms (7), add incrementally          |
| Compiler-VM contract bugs     | --compare mode catches mismatches early                          |

## Phase 9.5: Infrastructure Fixes

Short stabilization phase before continuing var expansion.
Fix VM lifetime bugs, unblock deferred items, and establish VM benchmark baseline.

### Phase 9.5a: VM Fixes

| #     | Task                                 | Archive                     | Notes                                                                       |
| ----- | ------------------------------------ | --------------------------- | --------------------------------------------------------------------------- |
| 9.5.1 | VM evalStringVM fn_val lifetime fix  | task_0082_vm_fn_lifetime.md | compiler.deinit() frees fn objects still referenced by Env (use-after-free) |
| 9.5.2 | swap! with fn_val (closure dispatch) | task_0083_swap_fn_val.md    | F5: swap! only accepts builtin_fn, not user closures                        |

### Phase 9.5b: Data Model

| #     | Task                     | Archive                    | Notes                                          |
| ----- | ------------------------ | -------------------------- | ---------------------------------------------- |
| 9.5.3 | seq on map (MapEntry)    | task_0084_seq_on_map.md    | (seq {:a 1}) -> ([:a 1]) — needed for map HOFs |
| 9.5.5 | bound? builtin + defonce | task_0085_bound_defonce.md | Unblocks T9.11 deferred defonce                |

### Phase 9.5c: Validation

| #     | Task                  | Archive                        | Notes                                                    |
| ----- | --------------------- | ------------------------------ | -------------------------------------------------------- |
| 9.5.4 | VM benchmark baseline | task_0086_vm_bench_baseline.md | Run all 11 benchmarks with --backend=vm, record baseline |

## Phase 10: VM Correctness + VM-CoreClj Interop

Fix VM loop/recur bug (F17), then unify fn_val proto so VM can call core.clj
higher-order functions. This unblocks 8/11 VM benchmarks.

### Phase 10a: VM Bug Fix

| #    | Task                                  | Archive                        | Notes                                                             |
| ---- | ------------------------------------- | ------------------------------ | ----------------------------------------------------------------- |
| 10.1 | Fix VM loop/recur wrong results (F17) | task_0087_vm_loop_recur_fix.md | emitLoop used pop instead of pop_under; body result was discarded |

### Phase 10b: VM-CoreClj Interop

| #    | Task                            | Archive                             | Notes                                                                                                                       |
| ---- | ------------------------------- | ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| 10.2 | Unified fn_val proto (F8)       | task_0088_tw_vm_reverse_dispatch.md | TreeWalk→VM reverse dispatch via bytecode_dispatcher callback. Fixes segfault when core.clj HOFs call VM-compiled callbacks |
| 10.3 | VM benchmark re-run + recording | task_0089_vm_bench_rerun.md         | Re-run all 11 benchmarks after fixes, record in bench.yaml. Fixed nested fn use-after-free (D35/F18)                        |

### Phase 10c: fn_val Dispatch Unification (Refactoring)

Consolidate 5 scattered fn_val dispatch mechanisms into a single `callFnVal`.
Motivation: T10.2 added yet another dispatcher callback, making 5 total.
Each caller must independently handle kind check + dispatcher wiring,
which is error-prone (T10.2 itself exposed a latent kind-default bug).

| #    | Task                                        | Archive                            | Notes                                                              |
| ---- | ------------------------------------------- | ---------------------------------- | ------------------------------------------------------------------ |
| 10.4 | Unify fn_val dispatch into single callFnVal | task_0090_unify_fn_val_dispatch.md | Replace 5 dispatch mechanisms with one callFnVal entry point (D36) |

Current dispatch points (all doing the same thing differently):

- `vm.zig:performCall` — kind==.treewalk → fn_val_dispatcher
- `tree_walk.zig:callValue/runCall` — kind==.bytecode → bytecode_dispatcher
- `atom.zig:swapBangFn` — call_fn module var (no kind check)
- `value.zig:LazySeq.realize` — realize_fn module var (no kind check)
- `analyzer.zig` — macroEvalBridge passed directly

Target: one `callFnVal(allocator, env, fn_val, args)` in bootstrap.zig,
exposed via a single module-level var. Eliminates Fn.kind default footgun
and 4 redundant module vars.

## Phase 11: Metadata System + Core Library IV

Metadata is a prerequisite for many Clojure idioms (protocols, defrecord,
docstrings on user fns). This phase adds the metadata system and fills
high-priority gaps in the core library.

### Phase 11a: Metadata System

| #     | Task                                        | Archive                              | Notes                                                        |
| ----- | ------------------------------------------- | ------------------------------------ | ------------------------------------------------------------ |
| 11.1  | meta, with-meta, vary-meta, alter-meta!     | task_0091_metadata_builtins.md       | Attach/read metadata on collections, Vars, symbols, fns      |
| 11.1b | Reader input validation (depth/size limits) | task_0092_reader_input_validation.md | SS14: Prevent OOM/stack overflow with nREPL publicly exposed |
| 11.2  | Var as Value variant + Var metadata support | task_0093_var_as_value.md            | Var in Value union; alter-meta!/reset-meta! on Vars          |

### Phase 11b: Function Combinators + Utility

| #    | Task                       | Archive                              | Notes                                           |
| ---- | -------------------------- | ------------------------------------ | ----------------------------------------------- |
| 11.3 | memoize, trampoline        | task_0094_memoize_trampoline.md      | core.clj: function combinators (Phase 6.9 残り) |
| 11.4 | if-some, when-some, vswap! | task_0095_if_some_when_some_vswap.md | core.clj: nil-safe macros + volatile swap       |

### Phase 11c: Regex Support

| #    | Task                                    | Archive                    | Notes                                 |
| ---- | --------------------------------------- | -------------------------- | ------------------------------------- |
| 11.5 | re-pattern, re-find, re-matches, re-seq | task_0096_regex_support.md | Ported Beta regex engine + 4 builtins |

### Phase 11d: Validation

| #    | Task                        | Archive                                | Notes                                       |
| ---- | --------------------------- | -------------------------------------- | ------------------------------------------- |
| 11.6 | Metadata + regex test suite | task_0097_metadata_regex_test_suite.md | Compare-mode tests, SCI compatibility tests |

## Phase 12: Zig Foundation Completion + SCI Test Port

### Phase 12a: Tier 1 Zig Builtins

| #    | Task                                                  | Archive                                        | Notes                                                                                    |
| ---- | ----------------------------------------------------- | ---------------------------------------------- | ---------------------------------------------------------------------------------------- |
| 12.1 | Collection gaps: dissoc, disj, find, peek, pop, empty | task_0098_collection_gaps.md                   | Map/set removal, stack ops, empty collection constructor                                 |
| 12.2 | subvec, array-map, hash-set, sorted-map               | task_0099_subvec_arraymap_hashset_sortedmap.md | Vector slice + collection constructors (D45: sorted-map not tree-based)                  |
| 12.3 | Hash & identity: hash, identical?, ==                 | task_0100_hash_identity.md                     | hash-combine deferred; == is numeric cross-type equality                                 |
| 12.4 | Reduced: reduced, reduced?, unreduced, ensure-reduced | task_0101_reduced.md                           | Reduced Value variant (D46). F23 resolved: Zig exhaustive switch = comptime verification |
| 12.5 | eval, macroexpand, macroexpand-1, read-string         | task_0102_eval_macroexpand_readstring.md       | Runtime eval pipeline; load-string deferred                                              |
| 12.6 | Namespace ops I: all-ns, find-ns, ns-name, create-ns  | task_0103_namespace_ops_1.md                   | Namespace introspection basics (D47: ns as symbol)                                       |
| 12.7 | Namespace ops II: ns-map, ns-publics, ns-interns      | task_0104_namespace_ops_2.md                   | Namespace Var mapping (D47: ns as symbol)                                                |
| 12.8 | gensym, compare-and-set!, format                      | task_0105_gensym_cas_format.md                 | Misc Tier 1 utilities                                                                    |

### Phase 12b: SCI Test Port

| #    | Task                   | Archive | Notes                                                                                                                         |
| ---- | ---------------------- | ------- | ----------------------------------------------------------------------------------------------------------------------------- |
| 12.9 | SCI test port + triage | --      | Run SCI tests, categorize failures. **F22 trigger**: introduce compat_test.yaml. **F24 trigger**: vars.yaml status refinement |

### Phase 12c: Tier 2 core.clj Expansion

| #     | Task                                                 | Archive | Notes                          |
| ----- | ---------------------------------------------------- | ------- | ------------------------------ |
| 12.10 | Core.clj batch 1: key, val, keys, vals, MapEntry ops | --      | Unlocks map iteration patterns |
| 12.11 | Core.clj batch 2: every?, not-every?, some, not-any? | --      | Predicate sequence ops         |
| 12.12 | Core.clj batch 3: map-indexed, keep, keep-indexed    | --      | Advanced sequence transforms   |

## Phase 13: SCI Fix-ups + clojure.string + Core Expansion

Fix remaining SCI test failures, add clojure.string namespace, and expand
core.clj with missing functions. Subsumes Phase 12c (T12.10-12.12).

### Phase 13a: SCI Fix-ups (Zig builtins)

| #    | Task                                            | Archive                         | Notes                                                                 |
| ---- | ----------------------------------------------- | ------------------------------- | --------------------------------------------------------------------- |
| 13.1 | list?, int?, reduce/2, set-as-fn, deref-delay   | task_0107_sci_fixups.md         | Fix 4 skipped SCI tests + 15 skipped assertions. Zig-level fixes      |
| 13.2 | Named fn self-reference + fn param shadow fixes | task_0108_fn_self_ref_shadow.md | Behavioral fixes: self-ref-test + variable-can-shadow-test assertions |

### Phase 13b: clojure.string namespace

| #    | Task                                                         | Archive                                | Notes                                          |
| ---- | ------------------------------------------------------------ | -------------------------------------- | ---------------------------------------------- |
| 13.3 | clojure.string: join, split, upper-case, lower-case, trim    | task_0109_clojure_string.md            | Core string ops. Zig builtins in new namespace |
| 13.4 | clojure.string: includes?, starts-with?, ends-with?, replace | archive/task_0110_clj_string_search.md | Search/replace ops                             |
| 13.5 | clojure.string: blank?, reverse, trim-newline, triml, trimr  | archive/task_0111_clj_string_misc.md   | Remaining commonly-used string functions       |

### Phase 13c: Core.clj Expansion (from Phase 12c)

| #    | Task                                    | Archive                      | Notes                                                |
| ---- | --------------------------------------- | ---------------------------- | ---------------------------------------------------- |
| 13.6 | key, val, keys, vals, MapEntry ops      | archive/task_0112_key_val.md | key/val as vector pair ops; keys/vals already done   |
| 13.7 | map-indexed, keep, keep-indexed, remove | (already done in core.clj)   | All 4 functions already implemented + vars.yaml done |
| 13.8 | {:keys [:a]} keyword destructuring      | archive/task_0113_keys_kw.md | Analyzer accepts keywords in :keys vector            |

### Phase 13d: Validation + Upstream Alignment

| #     | Task                                       | Archive                             | Notes                                                        |
| ----- | ------------------------------------------ | ----------------------------------- | ------------------------------------------------------------ |
| 13.9  | SCI test validation: 72/72 pass            | archive/task_0114_sci_validation.md | 72/72 tests, 267 assertions. 1 skip remains (var :name meta) |
| 13.10 | Upstream alignment (UPSTREAM-DIFF cleanup) | archive/task_0115_upstream_align.md | memoize → if-let/find/val, trampoline → let+recur            |

---

## Phase 14: Clojure本家テスト基盤

**Goal**: Clojure JVM本家のテストスイート (test/clojure/test_clojure/) を参考に、
等価なテストを手書きで作成する基盤を整備する。互換性担保の重要な柱。

**Background (調査結果)**:

- 本家テストは67個の.cljファイル (test/clojure/test_clojure/)
- ほぼ全てが clojure.test フレームワークを使用
- Java interop依存度が高い — そのままコピーは不可
- Javaテスト (test/java/) はテストフィクスチャのみ — Zig移植不要
- **方針**: 等価テストを手書きで作成 (Java部分除外)

**Java依存度によるファイル分類**:

| 依存度 | ファイル例                           | 移植難易度 |
| ------ | ------------------------------------ | ---------- |
| 低     | for.clj, control.clj                 | 容易       |
| 中     | logic.clj, predicates.clj, atoms.clj | 中程度     |
| 高     | numbers.clj, sequences.clj           | 要選別     |

### Phase 14a: clojure.test フレームワーク

| #    | Task                                   | Archive                         | Notes                                  |
| ---- | -------------------------------------- | ------------------------------- | -------------------------------------- |
| 14.1 | clojure.test/deftest, is, testing 移植 | task_0116_clojure_test_basic.md | 最小限のテストフレームワーク           |
| 14.2 | clojure.test/are, run-tests 移植       | task_0117_clojure_test_are.md   | テンプレート展開 (are)、テスト実行統合 |
| 14.3 | test-ns-hook / fixtures (optional)     | --                              | 必要に応じて後回し                     |

### Phase 14b: 等価テスト作成 (Java依存度: 低)

| #    | Task                       | Archive                      | Notes                                          |
| ---- | -------------------------- | ---------------------------- | ---------------------------------------------- |
| 14.4 | for.clj 等価テスト作成     | task_0118_for_equiv_tests.md | 4 tests, 12 assertions (:while/combo excluded) |
| 14.5 | control.clj 等価テスト作成 | --                           | if, when, cond, case, do, let 等               |

### Phase 14c: 等価テスト作成 (Java依存度: 中)

| #    | Task                          | Archive                        | Notes                                 |
| ---- | ----------------------------- | ------------------------------ | ------------------------------------- |
| 14.6 | logic.clj 等価テスト作成      | --                             | and, or, not, boolean論理             |
| 14.7 | predicates.clj 等価テスト作成 | --                             | 型述語テスト (Java型除外)             |
| 14.8 | atoms.clj 等価テスト作成      | task_0119_atoms_equiv_tests.md | atom, swap!, reset!, compare-and-set! |

### Phase 14d: 等価テスト作成 (Java依存度: 高 — 選別)

| #     | Task                           | Archive                            | Notes                               |
| ----- | ------------------------------ | ---------------------------------- | ----------------------------------- |
| 14.9  | sequences.clj 等価テスト作成   | task_0120_sequences_equiv_tests.md | 33 tests, 188 assertions            |
| 14.10 | data_structures.clj 等価テスト | --                                 | transient除外、persistent構造テスト |

### Phase 14e: テストトラッキング拡張

| #     | Task                         | Archive | Notes                                      |
| ----- | ---------------------------- | ------- | ------------------------------------------ |
| 14.11 | compat_test.yaml 拡張        | --      | clojure/test_clojure/\* 追跡セクション追加 |
| 14.12 | 優先度付きファイルリスト作成 | --      | 残りテストファイルの移植優先度決定         |

---

**継続的拡充** (Phase 15+):

Phase 14以降、機能実装と並行してテストを追加していく:

- 新機能追加時 → 対応する本家テストから等価テスト作成
- 残りのファイル (numbers.clj, string.clj, macros.clj 等) を順次移植
- vars.yaml の done 比率向上に合わせてテストカバレッジ拡大

## Future Considerations

### Phase 12 Strategy (Reference)

**Background** (discussed during Phase 11 planning):

Remaining 488 unimplemented vars fall into 4 tiers:

| Tier | Description                 | Count    | Impl Language |
| ---- | --------------------------- | -------- | ------------- |
| 1    | Zig-required runtime fundns | ~30-40   | Zig           |
| 2    | Pure Clojure combinators    | ~100-150 | core.clj      |
| 3    | JVM-specific (skip/stub)    | ~150-200 | N/A           |
| 4    | Dynamic vars / config       | ~50      | Zig stubs     |

**Key insight**: Tier 1 (Zig-required) blocks Tier 2 (core.clj). Once Tier 1
is complete, remaining var expansion becomes simple iteration: write test,
write defn in core.clj, verify. SCI test porting acts as the gate between
the two phases.

**Tier 1 candidates** (Zig builtins needed before core.clj can take over):

- **Var as Value**: var?, var-get, var-set, find-var, alter-var-root
- **Namespace ops**: all-ns, find-ns, ns-name, ns-map, ns-publics, create-ns, the-ns, ns-interns, ns-refers, ns-aliases, ns-unmap, ns-resolve, resolve, refer
- **Collection gaps**: dissoc, disj, find, subvec, peek, pop, empty, array-map, hash-set, sorted-map
- **Hash**: hash, hash-combine, identical?
- **IO basics**: slurp, spit, read-line, flush, newline, \*in\*, \*out\*, \*err\*
- **eval / load**: eval, macroexpand, macroexpand-1, load-string, read-string
- **Transient**: transient, persistent!, conj!, assoc!, dissoc!, pop!
- **Regex**: re-pattern, re-find, re-matches, re-seq (Zig has no regex — needs PCRE or hand-rolled)
- **Misc**: gensym, format, compare-and-set!, reduced, reduced?, unreduced

**Tier 3 (JVM-specific) — skip or minimal stub**:

- Java array ops: aset-\*, aget, alength, \*-array, make-array (~40)
- agent/ref/STM: agent, send, ref, dosync, alter, commute (~30)
- proxy/reify/gen: proxy, reify, gen-class, gen-interface (~15)
- Java type coercion: byte, short, long, float, double, int, char (~15)
- unchecked-\* : unchecked-add, unchecked-multiply, etc. (~20)
- Class loader: compile, load, import, require (~10)
- future/promise: future, promise, deliver (thread-dependent)

**Recommended Phase 12 structure**:

1. Phase 12a: Tier 1 Zig builtins (3-5 tasks covering the groups above)
2. Phase 12b: SCI test port — run, triage failures into "missing Tier 1"
   vs "missing Tier 2" vs "JVM-specific skip"
3. Phase 12c: Tier 2 core.clj mass expansion — test-driven, simple iteration
4. Phase 12c.5: **Upstream alignment** — replace simplified core.clj definitions
   with verbatim upstream Clojure definitions (see below)
5. Phase 12d: Tier 3 triage — mark JVM-specific as "not-applicable" in
   vars.yaml, add stubs where useful

#### Phase 12c.5: Upstream Alignment

**Goal**: Replace all `UPSTREAM-DIFF` tagged definitions in core.clj with
the verbatim upstream Clojure definitions (from `src/clj/clojure/core.clj`).

**Why here**: By Phase 12c, all Tier 1 Zig builtins and most Tier 2
core.clj functions will be implemented. The missing deps that forced
simplified definitions (if-let, find, val, @ reader macro, #() reader
macro) should all be available by this point.

**Current UPSTREAM-DIFF items** (query: `grep UPSTREAM-DIFF .dev/status/vars.yaml`):

| Var        | Missing Deps                         | Impl Phase |
| ---------- | ------------------------------------ | ---------- |
| memoize    | if-let, find, val, @ reader macro    | 12a-12c    |
| trampoline | #() reader macro (fn-level recur OK) | 12a        |

**Procedure**:

1. Query all UPSTREAM-DIFF entries: `grep UPSTREAM-DIFF .dev/status/vars.yaml`
2. For each entry, verify all listed missing deps are now implemented
3. Read the upstream definition from `src/clj/clojure/core.clj`
4. Replace the simplified definition in `src/clj/core.clj` with the
   upstream version (including docstring and metadata)
5. Run tests to verify behavioral equivalence
6. Update vars.yaml: remove UPSTREAM-DIFF note (or replace with "upstream-aligned")
7. Single commit per batch of aligned definitions

**Expected scope**: Small (currently 2 items, may grow to ~5-10 as more
core.clj functions are added in earlier phases). This is a cleanup task,
not a feature implementation phase.

**When to plan**: After Phase 11 completes, set memo.md to
"phase planning needed" and reference this section.

#### Dual Test Strategy (SCI + Clojure Upstream)

Both-side testing provides stronger bug discovery than either alone:

| Source         | Characteristics                 | Conversion Method                      |
| -------------- | ------------------------------- | -------------------------------------- |
| SCI            | Low Java contamination, ~4K LOC | Tier 1 auto-convert (eval\* -> direct) |
| Clojure native | Heavy Java InterOp, ~14.3K LOC  | Read test intent, hand-port sans Java  |

- SCI: Apply automatic conversion rules -> triage non-working tests
- Clojure upstream: Read tests, create equivalent Java-free tests by hand
- Test tracking: introduce `compat_test.yaml` at Phase 12b

```yaml
# .dev/status/compat_test.yaml (Phase 12b)
tests:
  sci/core_test:
    test-eval:
      status: pass | fail | skip | pending
      source: sci
  clojure/core_test:
    test-assoc:
      status: pass | fail | skip | manual-port
      source: clojure
      note: "Java HashMap removed, uses PersistentArrayMap"
```

### IO / System Namespace Strategy

When implementing IO and system functionality, decide on namespace design:

- **Java interop exclusion**: `proxy`/`reify`/`gen-class` are JVM-specific — skip
- **Native aliases**: `slurp`/`spit` via Zig `std.fs`, `Thread/sleep` via `std.time.sleep`
- **`clojure.java.io`**: Provide equivalent as `clojure.java.io` (compatible) or `clojure.io` (clean).
  Both approaches work — `clojure.java.io` keeps existing code running, `clojure.io` is cleaner.
  Could also support both (alias one to the other). Decide when implementing.
- **System**: `System/getenv`, `System/nanoTime` etc. can work via `tryJavaInterop` routing
  or a `clojure.system` namespace. Decide when implementing.
- **Reference**: .dev/future.md SS11 (Java Interop exclusion and compatibility aliases)

Details deferred — decide architecture when the IO/system phase is planned.

## Task Count Summary

| Phase     | Tasks   | Status           | Scope                      |
| --------- | ------- | ---------------- | -------------------------- |
| 1 (a-c)   | 12      | Complete         | Value + Reader + Analyzer  |
| 2 (a-b)   | 10      | Complete         | Runtime + Compiler + VM    |
| 3 (a-c)   | 17      | Complete         | Builtins + core.clj + CLI  |
| 4 (a-f)   | 16      | Complete         | VM parity + lang features  |
| 5         | 6       | Complete         | Benchmark system           |
| 6 (a-c)   | 12      | Partial          | Core library expansion     |
| 7 (a-c)   | 9       | Complete         | Robustness + nREPL         |
| 8         | 3       | Complete         | Refactoring                |
| 9 (a-d)   | 15      | Complete         | Core library expansion III |
| 9.5 (a-c) | 5       | Complete         | VM fixes + data model      |
| 10 (a-c)  | 4       | Complete         | VM correctness + interop   |
| 11 (a-d)  | 7       | Complete         | Metadata + core lib IV     |
| 12 (a-b)  | 9       | Complete         | Zig foundation + SCI port  |
| 13 (a-d)  | 10      | Complete         | SCI fix-ups + clj.string   |
| 14 (a-e)  | 12      | Planned          | Clojure本家テスト基盤      |
| **Total** | **138** | **113 archived** |                            |
