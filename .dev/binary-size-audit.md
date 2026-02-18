# Binary Size Audit — v0.2.0

Date: 2026-02-14
zwasm: v1.1.0 (GitHub URL dependency)
Platform: macOS ARM64 (Apple Silicon)

## Binary Size Summary

| Build mode   | Size  |
|-------------|-------|
| ReleaseSafe | 3.9MB |
| Debug       | 12MB  |

## ReleaseSafe Segment Breakdown

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

Total on-disk: ~3.9MB (3,923KB segments)

## Bootstrap Cache

Size: 466KB (serialized Clojure runtime state)
Embedded at compile time via `@embedFile`.

## Comparison with Previous

| Metric           | v0.11.0 (memo) | Current (main) | Delta   |
|-----------------|----------------|----------------|---------|
| ReleaseSafe Mac | 2.9MB          | 3.7MB          | +800KB  |
| Debug Mac       | ~10MB          | 12MB           | +2MB    |
| Bootstrap cache | ~400KB         | 466KB          | +66KB   |

Growth is expected: zwasm gained GC (+3500 LOC), function_references,
relaxed SIMD, multi-memory, and x86_64 JIT backend since v0.11.0.

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

## Optimization Candidates

### Quick Wins (no code changes)

1. **ReleaseSmall**: Would reduce to ~2.5MB (strips safety checks + debug info).
   Not recommended for production (loses stack traces).

2. **Strip debug symbols**: `zig build -Doptimize=ReleaseSafe -Dstrip=true`
   would save ~492KB (__LINKEDIT). Trade-off: no debug symbols in crash dumps.

### Medium Effort

3. **eh_frame reduction**: 164KB of exception handling frames. Zig's
   `-fno-unwind-tables` could eliminate this but breaks stack traces.

4. **Compile-time feature flags**: Already have `-Dwat=false` for WAT parser.
   Could add `-Djit=false`, `-Dsimd=false`, `-Dgc=false` for embedded use.
   Estimated savings: JIT ~400KB, SIMD ~200KB.

### Not Recommended

5. **LTO/link-time optimization**: Zig 0.15.2 doesn't support cross-module LTO
   well. Risk of miscompilation.

6. **Compressing bootstrap.cache**: 466KB → ~200KB with zstd. But adds
   decompression time to startup. Current 5.3ms startup is already excellent.

## Conclusion

3.7MB ReleaseSafe is reasonable for a runtime with:
- Full Wasm 3.0 support (9 proposals, 523 opcodes)
- Dual-arch JIT (ARM64 + x86_64)
- GC with struct/array/i31
- SIMD (256 + 20 relaxed)
- WAT parser
- WASI P1

No immediate action needed. Feature flags (-Djit, -Dsimd) are the best
path for size-constrained deployment if needed in future.
