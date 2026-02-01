# log_0000_kickoff

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
