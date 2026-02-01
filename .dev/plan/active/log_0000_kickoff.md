# log_0000_kickoff

## Task 4: Set up flake.nix + flake.lock — DONE

Created flake.nix pinning Zig 0.15.2 + toolchain (wasmtime, hyperfine, yq, jq,
clojure, jdk21, babashka). English comments/messages. Verified: `nix develop`
gives Zig 0.15.2 and wasmtime 41.0.0.

## Task 3: Create .dev/notes/decisions.md — DONE

Created 10 design decisions (D1-D10) documenting key choices:
- D1: Tagged union first, NaN boxing later
- D2: Arena stub GC, real GC deferred
- D3: Instantiated VM, no threadlocal
- D4: Special forms as comptime table
- D5: core.clj AOT deferred to Phase 3, Zig-only builtins first
- D6: Dual backend with --compare from Phase 2
- D7: Directory structure per SS17
- D8: VarKind classification (7 kinds)
- D9: Array-based collections initially
- D10: English-only codebase

## Task 2: Create plan_0001_bootstrap.md — DONE

Created .dev/plan/active/plan_0001_bootstrap.md with 37 tasks across 3 phases:

- **Phase 1** (12 tasks): Value type foundation + Reader + Analyzer
  - 1a: Value tagged union (defer NaN boxing), format, eql, collections
  - 1b: Tokenizer, Form, Reader, edge cases
  - 1c: Node type, Analyzer with comptime special form table, var resolution
- **Phase 2** (10 tasks): Native VM
  - 2a: Env (instantiated, no threadlocal), Namespace, Var (VarKind), GcStrategy stub
  - 2b: OpCode enum, Compiler, VM loop, closures, TreeWalk evaluator, --compare
- **Phase 3** (15 tasks): Builtins + core.clj AOT
  - 3a: Arithmetic/comparison/collection intrinsics, type predicates, I/O, atoms, registry
  - 3b: core.clj bootstrap, AOT pipeline, startup, HOFs, macros
  - 3c: CLI, SCI tests, benchmarks

Key decisions in the plan:
- Start with tagged union, NaN boxing later (correctness first)
- Start with arena + no-op GC, real GC when needed
- Minimal special forms first (7), add incrementally
- --compare mode from Phase 2 for regression detection

## Task 1: Read future.md and architecture.md — DONE

Read both documents in full:

- **architecture.md**: Beta directory structure (reader/ analyzer/ compiler/ vm/ runtime/ lib/ wasm/ gc/ regex/ nrepl/ repl/), dual-backend strategy (TreeWalk + BytecodeVM with --compare), VM design (stack-based, 3-byte fixed instruction), OpCode categories (0x00-0xCF).

- **future.md (SS0-19)**: Comprehensive production design covering:
  - SS0: Zig-based Clojure reimplementation, 1036 tests, 545 functions, ~38K lines in Beta
  - SS1-4: Wasm as AOT-optimized fast primitive layer (4 phases), WIT/Component Model strategy
  - SS5: GC modular design (GcStrategy trait, 3-layer separation: Memory/Execution/Optimization), NaN boxing for native, tagged union for wasm_rt
  - SS6: Wasm engine selection (zware, WasmBackend trait for swappability)
  - SS7: Dual track — native (fast binary) vs wasm_rt (Wasm runtime freeride), comptime switching
  - SS8: Single repo, comptime world-line switching, src/common+native+wasm_rt structure
  - SS9: Beta lessons — compiler-VM contract, --compare, fused reduce, allocator separation, collection redesign, core.clj AOT compilation
  - SS10: Compatibility verification (L0-L4), test catalog from SCI/CLJS/Clojure, VarKind enum, BuiltinDef with metadata, namespace guarantee
  - SS14: Security design (ReleaseSafe, sandbox, reader input validation)
  - SS15: FFI strategy (Wasm modules, Zig plugins, C ABI, embeddable library mode with instantiated VM)
  - SS16: Repo management (trunk-based dev, CI/CD, SemVer)
  - SS17: Directory structure (api/ common/ native/ wasm_rt/ wasm/ + clj/ test/ docs/)
  - SS18: Documentation strategy (4-layer, ADR, CHANGELOG)
  - SS19: Migration roadmap (Phase 0-11)

Key design decisions for production version:
1. Instantiated VM (no threadlocal) — SS15.5
2. GcStrategy trait for GC abstraction — SS5
3. BuiltinDef with metadata (doc, arglists, added) — SS10
4. core.clj AOT compilation via @embedFile — SS9.6
5. NaN boxing for native, tagged union for wasm_rt — SS5/SS7
6. comptime world-line switching — SS8
7. VarKind enum for dependency-layer classification — SS10
