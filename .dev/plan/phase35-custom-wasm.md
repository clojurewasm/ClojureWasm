# Phase 35: Custom Wasm Runtime (Replace zware)

## Motivation

zware dependency creates two problems:
1. **Cross-compile blocker**: zware VM uses `.always_tail` calling convention,
   requiring LLVM backend. Debug cross-compile fails with 184 errors.
2. **Dependency risk**: External dep with different design goals. ClojureWasm
   needs a focused subset, not a full spec-compliant runtime.

Building a custom Wasm runtime gives us:
- **Cross-compile freedom**: Switch-based dispatch works on all Zig backends
- **Full control**: Optimize for ClojureWasm's specific use cases
- **Smaller binary**: Only include what we use (~30% of zware)
- **Better integration**: Direct access to internals, no API boundary

## Scope

### In scope (Wasm MVP + ClojureWasm needs)
- Wasm binary decoder (module sections 0-11)
- Stack-based VM with switch dispatch (~200 opcodes)
- Linear memory (grow, read, write, bounds checking)
- Function calls (local + host functions)
- Tables (indirect call, funcref)
- Globals (mutable/immutable)
- WASI Preview 1 basics (19 functions — fd_write, args, environ, clock, etc.)
- Host function injection (Clojure fns callable from Wasm)
- All existing ClojureWasm Wasm tests must pass

### Out of scope
- SIMD (v128) — not used by any ClojureWasm test module
- Multi-memory proposal
- Reference types beyond funcref (externref deferred)
- Component Model / WASI Preview 2
- Wasm validation (trust input binaries, same as zware usage)
- Streaming compilation

## Architecture

### File layout

```
src/wasm/
  runtime/              -- NEW: custom Wasm runtime
    module.zig          -- Binary decoder (sections, types, imports, exports)
    vm.zig              -- Stack-based VM (switch dispatch, ~200 opcodes)
    store.zig           -- Store (functions, memories, tables, globals)
    memory.zig          -- Linear memory (pages, grow, read/write)
    instance.zig        -- Module instantiation + invoke API
    wasi.zig            -- WASI Preview 1 (19 functions)
    opcode.zig          -- Opcode enum + instruction representation
    leb128.zig          -- LEB128 variable-length integer decoding
  types.zig             -- MODIFIED: replace zware imports with runtime/ imports
  builtins.zig          -- UNCHANGED: Clojure API (wasm/load, wasm/fn, etc.)
  wit_parser.zig        -- UNCHANGED: no zware dependency
  testdata/             -- UNCHANGED: existing .wasm test files
```

### Key design decisions

#### 1. Switch-based dispatch (not `.always_tail`)

```zig
// zware approach (requires LLVM):
return @call(.always_tail, lookup[opcode], .{self, ip, code});

// Our approach (works on all backends):
while (ip < code.len) {
    switch (code[ip]) {
        .i32_const => { ... },
        .i32_add => { ... },
        .call => { ... },
        // ...
    }
}
```

Trade-off: ~10-20% slower than tail-call dispatch, but cross-compiles freely.
Acceptable — Wasm FFI is not the hot path in ClojureWasm.

#### 2. Direct bytecode execution (no IR)

zware converts Wasm bytecode to an intermediate "Refined Representation" (Rr).
We skip this step and execute Wasm bytecode directly with a pre-pass for:
- Block/loop branch target resolution
- Function local counts
- Constant expression evaluation

This simplifies the codebase (~500 fewer LOC) at minor runtime cost.

#### 3. Unified value stack (u64)

All Wasm values stored as `u64` on the operand stack, same as zware:
- i32 → zero-extended u64
- i64 → direct u64
- f32 → bit-cast u32 → zero-extended u64
- f64 → bit-cast u64

#### 4. Public API matches zware

Keep the same API surface so `types.zig` changes are minimal:

```zig
// Store
pub fn Store.init(allocator) Store
pub fn Store.exposeHostFunction(module, name, func, context, params, results) !void

// Module
pub fn Module.init(allocator, wasm_bytes) Module
pub fn Module.decode() !void

// Instance
pub fn Instance.init(allocator, *Store, Module) Instance
pub fn Instance.instantiate() !void
pub fn Instance.invoke(name, args, results) !void
pub fn Instance.getMemory(index) !*Memory

// Memory
pub fn Memory.memory() []u8
pub fn Memory.read(T, offset, address) !T
pub fn Memory.write(T, offset, address, value) !void

// Types
pub const ValType = enum(u8) { I32, I64, F32, F64, FuncRef, ExternRef };
```

## Task breakdown

### 35W.1: Foundation — opcode.zig + leb128.zig (~150 LOC)

Opcode enum (Wasm spec opcodes), LEB128 decoder (u32, i32, u64, i64, s33).
Pure data definitions, no dependencies. Test with known byte sequences.

### 35W.2: Memory — memory.zig (~200 LOC)

Linear memory: page-based allocation, grow, read/write with bounds checking.
`PAGE_SIZE = 65536`. Direct `[]u8` backing with typed read/write helpers.

Tests: allocate, grow, read/write round-trip, bounds check.

### 35W.3: Store — store.zig (~250 LOC)

Function registry (Wasm functions + host functions), memory instances,
table instances, global variables. `exposeHostFunction` for host callbacks.

```zig
pub const Function = union(enum) {
    wasm: struct { type_idx: u32, code: []const u8, locals: []LocalType, instance: *Instance },
    host: struct { func: HostFn, context: usize, params: []const ValType, results: []const ValType },
};
pub const HostFn = *const fn (*Vm, usize) WasmError!void;
```

### 35W.4: Module decoder — module.zig (~800 LOC)

Binary decoder for Wasm MVP sections:

| Section    | ID | Content                        |
|------------|---:|--------------------------------|
| Custom     |  0 | Skip (name section ignored)    |
| Type       |  1 | Function signatures            |
| Import     |  2 | Module/name/type imports       |
| Function   |  3 | Type indices for code section  |
| Table      |  4 | Table types                    |
| Memory     |  5 | Memory limits                  |
| Global     |  6 | Global types + init exprs      |
| Export     |  7 | Name/type/index exports        |
| Start      |  8 | Start function index           |
| Element    |  9 | Table initialization           |
| Code       | 10 | Function bodies                |
| Data       | 11 | Memory initialization          |
| DataCount  | 12 | Data segment count (post-MVP)  |

LEB128 throughout. Parse into structured data, keep raw code bytes
for VM to interpret directly.

Tests: decode 01_add.wasm, verify exports/types/function count.

### 35W.5: Instance — instance.zig (~400 LOC)

Module instantiation: resolve imports from Store, allocate memories/tables/globals,
apply data/element initializers, run start function.

`invoke(name, args, results)` — lookup export, set up call frame, run VM.
`getMemory(index)` — return memory instance.

Tests: instantiate 01_add.wasm, invoke "add", verify result.

### 35W.6: VM — vm.zig (~1500 LOC)

Switch-based interpreter for ~200 Wasm opcodes.

Stacks:
- Operand stack: `[4096]u64`
- Frame stack: `[256]Frame` (locals, return arity, stack markers)
- Label stack: `[256]Label` (branch targets, stack markers)

Opcode groups:
- Control: block, loop, if/else, br, br_if, br_table, call, call_indirect, return
- Parametric: drop, select
- Variable: local.get/set/tee, global.get/set
- Memory: i32.load/store (all variants), memory.size, memory.grow
- Numeric: i32/i64/f32/f64 arithmetic, comparison, conversion (~120 opcodes)
- Misc (0xFC prefix): memory.copy, memory.fill, table ops, sat truncations

Branch target resolution: pre-pass on function entry to compute branch
targets for block/loop/if structures. Store in side table indexed by IP.

Tests: all existing testdata/*.wasm files must pass.

### 35W.7: WASI — wasi.zig (~500 LOC)

19 WASI Preview 1 functions (same set as current zware usage):

| Function           | Implementation                              |
|--------------------|---------------------------------------------|
| args_get           | Copy from Instance.wasi_args                |
| args_sizes_get     | Count + total byte size                     |
| environ_get        | Copy from Instance.wasi_env                 |
| environ_sizes_get  | Count + total byte size                     |
| clock_time_get     | std.time.nanoTimestamp()                     |
| fd_close           | Close tracked fd                            |
| fd_fdstat_get      | Return fd stat struct                       |
| fd_filestat_get    | std.fs stat call                            |
| fd_prestat_get     | Pre-opened directory info                   |
| fd_prestat_dir_name| Pre-opened directory name                   |
| fd_read            | std.fs read, scatter (iovec)                |
| fd_seek            | std.fs seekTo/seekBy                        |
| fd_write           | std.fs write, gather (ciovec) — stdout/err  |
| fd_tell            | std.fs getPos                               |
| fd_readdir         | std.fs.Dir iteration                        |
| path_filestat_get  | std.fs statFile                             |
| path_open          | std.fs openFile with WASI rights            |
| proc_exit          | std.process.exit                            |
| random_get         | std.crypto.random                           |

### 35W.8: Integration — update types.zig + build.zig (~200 LOC change)

1. **types.zig**: Replace `@import("zware")` with `@import("runtime/...")`.
   All zware type references → our types. Minimal API change since we
   matched the public interface.

2. **build.zig**: Remove zware dependency from `build.zig.zon`.
   Remove all `addImport("zware", ...)` lines.

3. **Verification**: All existing Wasm tests pass (`zig build test`).
   All 12 testdata .wasm files work. builtins.zig unchanged.

### 35W.9: Cleanup + commit

Remove zware from build.zig.zon. Verify full test suite.
Update memo.md, roadmap.md, checklist.md.
Decision entry: D84 (Custom Wasm Runtime).

## LOC estimate

| File          | Estimated LOC | zware equivalent LOC |
|---------------|:------------:|:--------------------:|
| opcode.zig    |    150       |  207 (opcode.zig)    |
| leb128.zig    |    100       |  (inline in parser)  |
| memory.zig    |    200       |  187 (store/memory)  |
| store.zig     |    250       |  249 (store.zig)     |
| module.zig    |    800       |  2390 (module+parser)|
| instance.zig  |    400       |  665 (instance.zig)  |
| vm.zig        |   1500       |  2732 (vm.zig)       |
| wasi.zig      |    500       |  697 (wasi.zig)      |
| **Total**     | **~3900**    |  **~7127**           |

~55% of zware LOC. Savings from:
- No Rr intermediate representation (~500 LOC)
- No validation pass (~765 LOC)
- No multi-memory/SIMD (~500 LOC)
- Simpler dispatch (switch vs tail-call table) (~400 LOC)

## Verification plan

1. All existing `zig build test` passes (no regression)
2. All 12 testdata/*.wasm files work:
   - 01_add.wasm (basic arithmetic)
   - 02_fibonacci.wasm (recursion, control flow)
   - 03_memory.wasm (linear memory read/write)
   - 04_imports.wasm (host function injection)
   - 05_table_indirect_call.wasm (tables, call_indirect)
   - 06_globals.wasm (global variables)
   - 07_wasi_hello.wasm (WASI fd_write)
   - 08_multi_value.wasm (multiple return values)
   - 09_go_math.wasm (TinyGo WASI module)
   - 10_greet.wasm (WIT string marshalling)
3. `builtins.zig` tests pass (wasm/load, wasm/fn Clojure API)
4. No zware references remain in codebase
5. Cross-compile check: `zig build -Dtarget=x86_64-linux-gnu` succeeds
   in both Debug and ReleaseSafe (the original blocker)

## Relationship to Phase 35 (cross-platform)

The saved cross-platform plan is at `.claude/plans/phase35-cross-platform-saved.md`.
After this custom Wasm runtime is complete:
- The `.always_tail` cross-compile blocker is eliminated
- Phase 35 cross-platform tasks (Linux verification, CI, LICENSE) can proceed
- The two phases can be numbered 35W (Wasm) and 35X (cross-platform)

## Risk assessment

| Risk                              | Mitigation                                    |
|-----------------------------------|-----------------------------------------------|
| Opcode coverage gaps              | Test all 12 existing .wasm files exhaustively |
| Performance regression            | Benchmark wasm/fn calls before/after          |
| WASI compatibility issues         | Test with TinyGo + Rust-compiled modules      |
| Decoder edge cases                | Use existing .wasm test corpus, add fuzz later|
| Module size (binary bloat)        | Comptime strip of unused opcode handlers      |
