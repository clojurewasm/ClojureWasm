# WebAssembly Specification Support

ClojureWasm includes a custom WebAssembly runtime for executing `.wasm` modules
from Clojure code via the `cljw.wasm` namespace.

## Supported Spec Version

**WebAssembly 2.0** (partial) — all MVP opcodes plus select post-MVP extensions.

## Feature Matrix

| Feature | Wasm Version | Status | Notes |
|---------|-------------|--------|-------|
| Core numeric (i32/i64/f32/f64) | 1.0 (MVP) | Done | All arithmetic, comparison, conversion |
| Control flow (block/loop/if/br) | 1.0 (MVP) | Done | Including br_table |
| Memory operations | 1.0 (MVP) | Done | load/store for all types |
| Table operations (call_indirect) | 1.0 (MVP) | Done | |
| Global variables | 1.0 (MVP) | Done | Mutable and immutable |
| Sign-extension operators | 2.0 | Done | 5 opcodes (i32.extend8_s, etc.) |
| Saturating float-to-int | 2.0 | Done | 8 opcodes (i32.trunc_sat_f32_s, etc.) |
| Multi-value | 2.0 | Done | Multiple return values |
| Bulk memory operations | 2.0 | Done | memory.copy, memory.fill, table.copy, etc. |
| Reference types | 2.0 | Done | ref.null, ref.is_null, ref.func |
| Multi-table | 2.0 | Done | table.get, table.set, table.grow, table.size |
| SIMD (128-bit) | 2.0 | Not yet | Planned for Phase 36 |
| Tail calls | 3.0 | Not yet | |
| Exception handling | 3.0 | Not yet | |
| Multi-memory | 3.0 | Not yet | |
| GC | 3.0 | Not yet | |
| Relaxed SIMD | 3.0 | Not yet | |
| Memory64 | 3.0 | Not yet | |

## Opcode Count

- **MVP opcodes**: 172 implemented
- **Post-MVP opcodes**: 53 implemented
  - Sign-extension: 5
  - Saturating float-to-int: 8
  - Bulk memory: 8
  - Reference types: 3
  - Multi-table: 5
  - Numeric extensions: 24
- **Total**: 225 opcodes

## Conformance Tests

The runtime includes Wasm 2.0 conformance tests covering key specification areas:

| Test File | Category | Functions Tested |
|-----------|----------|------------------|
| `block.wasm` | Control flow | block, nested br, loop, if/else |
| `i32_arith.wasm` | i32 arithmetic | add, sub, mul, div_s/u, rem_s, clz, ctz, popcnt, rotl, rotr |
| `i64_arith.wasm` | i64 arithmetic | add, sub, mul, div_s, clz, popcnt, eqz |
| `f64_arith.wasm` | f64 arithmetic | add, mul, sqrt, min, max, floor, ceil, abs, neg |
| `conversions.wasm` | Type conversions | extend, wrap, convert, trunc, promote, demote, reinterpret |
| `sign_extension.wasm` | Sign-ext (2.0) | i32.extend8_s, i32.extend16_s, i64.extend8/16/32_s |
| `memory_ops.wasm` | Memory | i32/i64 store+load, store8+load8_s/u, size, grow |
| `bulk_memory.wasm` | Bulk memory (2.0) | memory.fill, memory.copy |

Source files: `src/wasm/testdata/conformance/` (WAT + compiled Wasm)

## Limitations

- No validation pass (modules are trusted)
- No streaming compilation
- No JIT compilation (interpreter only)
- Memory limited to 32-bit address space (wasm32)

## WASI Support

See [wasi-support.md](wasi-support.md) for WASI Preview 1 function coverage.

## Architecture

The runtime uses switch-based dispatch (no tail calls) for cross-platform
compatibility. Direct bytecode execution without IR transformation.

Source: `src/wasm/runtime/` (8 files, ~5300 LOC)
