# Phase 36: Wasm SIMD + FFI Deep (F118)

## Motivation

Phase 35W delivered a custom Wasm runtime (6376 LOC, 8 files). Phase 35.5
measured interpreter overhead: 14x-289x vs native on SIMD benchmarks.
Phase 35X confirmed cross-platform stability.

Phase 36 deepens the Wasm FFI layer with three goals:
1. **SIMD (v128)** — near-native compute for C/Rust .wasm modules
2. **Multi-module linking** — import/export across .wasm modules
3. **Bug fix F119** — WIT string return marshalling

**Value proposition**: "Clojure dynamism + C/Rust compute performance"
— unique to ClojureWasm (Babashka has no Wasm FFI path).

## Baseline

| Benchmark    | Native(ms) | CljWasm(ms) | CW/Native |
|--------------|------------|-------------|-----------|
| mandelbrot   | 9.98       | 735.75      | 73.7x     |
| vector_add   | 15.59      | 4511.14     | 289.4x    |
| dot_product  | 54.97      | 3525.11     | 64.1x     |
| matrix_mul   | 39.47      | 531.27      | 13.5x     |

SIMD target: 4-8x improvement on memory-bound benchmarks (vector_add, dot_product).

## Scope

### In scope
- **SIMD v128 opcodes** (~100 opcodes, 0xFD prefix) — full Wasm SIMD proposal
- **v128 value type** — 128-bit vector on VM value stack
- **Multi-module linking** — import functions/memories/globals across modules
- **F119 fix** — WIT string return: use (ptr, len) pair instead of offset 0
- **SIMD benchmark re-measurement** — compare before/after on bench/simd/

### Out of scope
- JIT compilation (Phase 37)
- Component Model / WASI Preview 2
- Native SIMD optimization of CW internals (F120 — separate concern)
- New Clojure-level `cljw.simd` namespace (future, after Phase 36 proves value)
- API breaking changes to `wasm/load`, `wasm/fn` (keep backward compatible)

## Architecture

### SIMD value representation

v128 is 16 bytes. Current VM value stack is `[]u64`. Options:

**Chosen: Widen value stack to u128 for SIMD frames**

Store v128 as a native `@Vector(16, u8)` (Zig SIMD type). The VM value stack
becomes `[]u128` — non-SIMD values zero-extend u64 to u128. This avoids
split-slot complexity and maps directly to Zig's `@Vector` operations.

Trade-off: 2x stack memory usage. Acceptable — Wasm call stacks are small
(typical max 1024 values) and the performance gain from direct `@Vector`
ops far outweighs the memory cost.

```zig
// vm.zig stack change
stack: []u128,  // was []u64

// Non-SIMD push/pop unchanged semantically
fn push(self: *Vm, val: u64) !void {
    self.stack[self.sp] = @as(u128, val);
    self.sp += 1;
}

// SIMD push/pop
fn pushV128(self: *Vm, val: @Vector(16, u8)) !void {
    self.stack[self.sp] = @bitCast(val);
    self.sp += 1;
}
fn popV128(self: *Vm) @Vector(16, u8) {
    self.sp -= 1;
    return @bitCast(self.stack[self.sp]);
}
```

### SIMD opcode dispatch

Follows the existing `executeMisc` pattern — `simd_prefix` reads sub-opcode
via LEB128 and dispatches in a dedicated `executeSimd` function.

```zig
// vm.zig — replace error.Trap with dispatch
.simd_prefix => try self.executeSimd(reader, instance),

fn executeSimd(self: *Vm, reader: *Reader, instance: *Instance) WasmError!void {
    const sub = try reader.readU32();
    const simd: opcode.SimdOpcode = @enumFromInt(sub);
    switch (simd) {
        .v128_load => { ... },
        .v128_const => { ... },
        .i8x16_add => { ... },
        // ~100 opcodes
        _ => return error.Trap,
    }
}
```

### Multi-module linking

Current state: each `wasm/load` creates an independent Store+Module+Instance.
Modules cannot import from each other.

Design: Add a `ModuleRegistry` that maps module names to instances. When
instantiating a new module, imports are resolved first from the registry,
then from host functions.

```clojure
;; API (Clojure level)
(def math-mod (wasm/load "math.wasm"))
(def app-mod  (wasm/load "app.wasm" {:imports {"math" math-mod}}))
;; app.wasm can import functions/memory from math-mod
```

Implementation: extend `types.zig` `loadWithImports` to accept WasmModule
values in the imports map (currently only Clojure fns). When a map value
is a WasmModule, register its exports as imports for the new module.

### F119 fix — WIT string return

Current bug: `wasm/fn` with WIT returns all linear memory from offset 0
instead of slicing by (ptr, len). Fix: after call, read the (ptr, len)
return pair and slice memory correctly.

## Task Breakdown

### 36.1: v128 value stack + SIMD opcode enum (foundation)

1. Add `SimdOpcode` enum to `opcode.zig` — all ~100 Wasm SIMD opcodes
2. Widen VM value stack from `[]u64` to `[]u128`
3. Add `pushV128`/`popV128` to vm.zig
4. Wire `simd_prefix` dispatch to `executeSimd` (initially all → error.Trap)
5. Verify all existing tests pass (non-SIMD behavior unchanged)

**LOC estimate**: ~300 (opcode enum) + ~50 (vm.zig stack changes)
**Risk**: Stack widening could affect non-SIMD performance. Benchmark before/after.

### 36.2: SIMD memory + constant ops

Implement the foundational SIMD opcodes:
- `v128.load`, `v128.store` — 16-byte aligned memory access
- `v128.const` — 128-bit immediate
- `v128.load8_lane` .. `v128.load64_lane` — partial lane loads
- `v128.store8_lane` .. `v128.store64_lane` — partial lane stores
- `v128.load8_splat` .. `v128.load64_splat` — broadcast loads
- `v128.load8x8_s/u` .. `v128.load32x2_s/u` — extending loads

**Opcodes**: ~20
**Test**: WAT conformance tests for memory SIMD ops

### 36.3: SIMD integer arithmetic

Implement integer SIMD operations across all lane widths (i8x16, i16x8, i32x4, i64x2):
- Arithmetic: `add`, `sub`, `mul` (where defined), `neg`
- Comparison: `eq`, `ne`, `lt_s/u`, `gt_s/u`, `le_s/u`, `ge_s/u`
- Bitwise: `and`, `or`, `xor`, `not`, `andnot`
- Shifts: `shl`, `shr_s`, `shr_u`
- Other: `all_true`, `bitmask`, `abs`, `min_s/u`, `max_s/u`
- Splat: `i8x16.splat`, `i16x8.splat`, `i32x4.splat`, `i64x2.splat`
- Extract/replace lane

**Opcodes**: ~50
**Implementation**: Map to Zig `@Vector` intrinsics (e.g. `@as(@Vector(16, i8), a) + b`)
**Test**: WAT conformance tests, verify against reference results

### 36.4: SIMD float arithmetic

Implement float SIMD operations (f32x4, f64x2):
- Arithmetic: `add`, `sub`, `mul`, `div`, `neg`, `abs`, `sqrt`
- Comparison: `eq`, `ne`, `lt`, `gt`, `le`, `ge`
- Conversion: `f32x4.convert_i32x4_s/u`, `i32x4.trunc_sat_f32x4_s/u`, etc.
- Other: `min`, `max`, `pmin`, `pmax`, `ceil`, `floor`, `trunc`, `nearest`

**Opcodes**: ~25
**Implementation**: Map to Zig `@Vector(4, f32)` / `@Vector(2, f64)` ops
**Test**: WAT float SIMD tests, NaN handling verification

### 36.5: SIMD shuffle + swizzle + remaining ops

- `i8x16.shuffle` — immediate byte indices
- `i8x16.swizzle` — dynamic byte indices
- `v128.any_true`
- `v128.bitselect`
- Dot product: `i32x4.dot_i16x8_s`
- Extend operations: `i16x8.extend_low_i8x16_s/u`, etc.
- Narrow operations: `i8x16.narrow_i16x8_s/u`, etc.

**Opcodes**: ~10 remaining
**Test**: Complete SIMD conformance coverage

### 36.6: SIMD benchmark + regression

1. Recompile SIMD benchmarks (`bench/simd/*.c`) with SIMD intrinsics
2. Run through CW Wasm runtime, compare before/after
3. Record baseline in `bench/history.yaml` (entry "36.6")
4. Update `bench/simd/results.md` with new measurements
5. Verify all existing Wasm benchmarks still pass (no regression)

**Gate**: vector_add/dot_product should show 4-8x improvement over Phase 35.5 baseline.

### 36.7: Multi-module linking

1. Extend `types.zig` import handling: accept WasmModule values in imports map
2. When import source is WasmModule, resolve its exports as imports
3. Support function imports across modules (memory/global import optional)
4. Add `wasm/link` convenience function (optional — may just extend `wasm/load`)
5. Test: two-module WAT test (math.wasm exports, app.wasm imports)
6. Test: three-module chain (a → b → c)

**LOC estimate**: ~150 (types.zig) + ~50 (builtins.zig) + tests

### 36.8: F119 fix — WIT string return

1. In `types.zig` `callWasmFn`, when WIT metadata indicates string return:
   read (ptr, len) pair from return values
2. Slice linear memory `memory[ptr..ptr+len]` instead of `memory[0..ptr]`
3. Test with greet.wasm WIT function
4. Close F119 in checklist.md

**LOC estimate**: ~30

### 36.9: Documentation + cleanup

1. Update `docs/wasm-spec-support.md` — add SIMD section
2. Update `docs/wasi-support.md` if any WASI changes
3. Update `bench/simd/results.md` with final Phase 36 numbers
4. Update memo.md — Phase 36 complete, advance to Phase 37 planning
5. Close F118 in checklist.md

## Implementation Notes

### Zig @Vector mapping

Zig's `@Vector` type maps directly to SIMD hardware:
```zig
const V16x8 = @Vector(16, u8);
const V8x16 = @Vector(8, u16);
const V4x32 = @Vector(4, u32);
const V2x64 = @Vector(2, u64);
const V4xf32 = @Vector(4, f32);
const V2xf64 = @Vector(2, f64);

// Addition example
fn i32x4_add(a: @Vector(4, i32), b: @Vector(4, i32)) @Vector(4, i32) {
    return a + b;  // Zig auto-vectorizes to SIMD instruction
}
```

On Apple Silicon (NEON) and x86_64 (SSE/AVX), Zig `@Vector` compiles to
native SIMD instructions. This means our interpreter-based Wasm SIMD
will actually use hardware SIMD for the computation part — the overhead
is only the dispatch loop, not the actual SIMD operations.

### Cross-platform SIMD

Zig `@Vector` is platform-independent — same code generates NEON on
aarch64, SSE on x86_64, and scalar fallback on wasm32. No conditional
compilation needed. Phase 35X's cross-platform infrastructure carries
forward automatically.

### Memory alignment for v128

v128 loads/stores require 16-byte aligned access on some architectures.
Wasm spec says v128.load is unaligned by default (alignment hint only).
Use `@memcpy` + local `@Vector` variable for safe unaligned access.

## Risk Assessment

| Risk                            | Mitigation                                         |
|---------------------------------|----------------------------------------------------|
| Stack widening perf regression  | Benchmark non-SIMD before/after 36.1               |
| SIMD opcode correctness         | WAT conformance tests per task                     |
| Cross-compile @Vector issues    | Zig @Vector is portable; test in CI                |
| Multi-module import cycles      | Detect during instantiation, return error          |
| Binary size increase            | Comptime strip unused SIMD handlers (if needed)    |

## Success Criteria

1. All ~100 SIMD opcodes implemented and tested
2. vector_add/dot_product benchmarks show 4-8x improvement
3. Multi-module linking works (2+ module chain)
4. F119 WIT string return fixed
5. All existing tests pass (zero regression)
6. Cross-platform CI green (macOS + Linux)

## Reference

| Item                    | Location                                        |
|-------------------------|-------------------------------------------------|
| Wasm SIMD proposal      | WebAssembly/simd (spec)                         |
| Current runtime         | `src/wasm/runtime/` (6376 LOC, 8 files)         |
| SIMD opcode reservation | `src/wasm/runtime/opcode.zig:271` (simd_prefix) |
| VM extension point      | `src/wasm/runtime/vm.zig:639` (.simd_prefix)    |
| SIMD benchmarks         | `bench/simd/` (4 C programs + .wasm)            |
| Benchmark baseline      | `bench/simd/results.md`                         |
| F118 (scope)            | `.dev/checklist.md`                             |
| F119 (WIT bug)          | `.dev/checklist.md`                             |
| Phase 35W plan          | `.dev/archive/phase35-custom-wasm.md`              |
| Zig @Vector docs        | Zig language reference, @Vector section         |
