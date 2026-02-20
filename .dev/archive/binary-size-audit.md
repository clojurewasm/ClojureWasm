# Binary Size Audit — v0.2.0

Date: 2026-02-19 (post-Phase 79A)
zwasm: v1.1.0 (GitHub URL dependency)
Platform: macOS ARM64 (Apple Silicon), Zig 0.15.2

## Binary Size Summary

| Build mode   | wasm=true (default) | wasm=false |
|-------------|---------------------|------------|
| ReleaseSafe | 4.25MB              | 3.68MB     |
| Debug       | ~12MB               | ~11MB      |

## Profile Comparison

| Metric       | wasm=true | wasm=false | Delta  |
|-------------|-----------|------------|--------|
| Binary size | 4.25MB    | 3.68MB     | -570KB (-13%) |
| Startup     | 4.6ms     | 4.3ms      | -0.3ms |
| RSS (light) | 7.4MB     | 7.4MB      | same   |

## ReleaseSafe Segment Breakdown (wasm=true)

| Segment       | Size      | Notes                         |
|--------------|-----------|-------------------------------|
| __TEXT        | 3,240KB   | Code + constants              |
|   __text      | 2,277KB   | Machine code (70%)            |
|   __const     | 594KB     | Read-only data (18%)          |
|   __cstring   | 180KB     | String literals (6%)          |
|   __eh_frame  | 164KB     | Exception handling frames     |
|   __unwind    | 21KB      | Unwind info                   |
|   __stubs     | 3KB       | Dynamic linking stubs         |
| __DATA        | 192KB     | Mutable data                  |
|   __thread_bss | 75KB     | Thread-local BSS              |
|   __const     | 68KB      | Mutable constants             |
|   __bss       | 47KB      | Zero-initialized globals      |
| __DATA_CONST  | <1KB      | GOT entries                   |
| __LINKEDIT    | 492KB     | Symbol tables, relocations    |

## Bootstrap Cache

Size: 466KB (serialized Clojure runtime state)
Embedded at compile time via `@embedFile`.

Lazy bootstrap (D104): Only core + core.protocols + user restored at startup.
Remaining 12 NSes deferred to require time.

## Size Attribution (estimated)

| Component        | Estimated __text | Notes                           |
|-----------------|------------------|---------------------------------|
| Wasm interpreter | ~800KB           | vm.zig dispatch + opcodes       |
| JIT backends     | ~400KB           | ARM64 + x86_64 codegen          |
| GC module        | ~100KB           | gc.zig (new)                    |
| Module decoder   | ~200KB           | module.zig + validation         |
| Clojure runtime  | ~500KB           | compiler, reader, core fns      |
| SIMD (256 ops)   | ~200KB           | Vector instruction handlers     |
| Other            | ~77KB            | CLI, WASI, WAT parser, etc.     |

wasm=false removes: Wasm interpreter + JIT + GC module + SIMD + module decoder
= ~1,700KB estimated, actual saving ~570KB (DCE is conservative with dispatch tables).

## Optimization Candidates

### Quick Wins (no code changes)

1. **ReleaseSmall**: Would reduce to ~2.5MB (strips safety checks + debug info).
   Not recommended for production (loses stack traces).

2. **Strip debug symbols**: `zig build -Doptimize=ReleaseSafe -Dstrip=true`
   would save ~492KB (__LINKEDIT). Trade-off: no debug symbols in crash dumps.

### Medium Effort

3. **eh_frame reduction**: 164KB of exception handling frames. Zig's
   `-fno-unwind-tables` could eliminate this but breaks stack traces.

4. **Compile-time feature flags**: Already have `-Dwasm=false` (D103).
   Could add `-Djit=false`, `-Dsimd=false`, `-Dgc=false` for embedded use.
   Estimated savings: JIT ~400KB, SIMD ~200KB.

### Not Recommended

5. **LTO/link-time optimization**: Zig 0.15.2 doesn't support cross-module LTO
   well. Risk of miscompilation.

6. **Compressing bootstrap.cache**: 466KB → ~200KB with zstd. But adds
   decompression time to startup. Current 4.6ms startup is already excellent.

## Conclusion

4.25MB ReleaseSafe (default) / 3.68MB (wasm=false) is reasonable for a runtime with:
- Full Wasm 3.0 support (9 proposals, 523 opcodes) [wasm=true only]
- Dual-arch JIT (ARM64 + x86_64) [wasm=true only]
- GC with struct/array/i31 [wasm=true only]
- SIMD (256 + 20 relaxed) [wasm=true only]
- WAT parser
- WASI P1
- Lazy bootstrap with deferred NS loading

Feature flag `-Dwasm=false` is the primary path for size-constrained deployment.
