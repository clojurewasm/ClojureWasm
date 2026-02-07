# Phase 26: wasm_rt — Compile Runtime to Wasm

## Section 1: Compile Probe (26.R.1)

### Build Command

```bash
zig build wasm 2>&1
```

**Result**: 1 error — `zware` module not registered for wasm_exe in build.zig.
This is the first blocker; deeper errors are masked until resolved.

### Error Catalog

Errors below are identified by source analysis (import chain tracing) plus
PoC compilation tests. Categories:

- **(a)** Conditional compile fix — `comptime` branch or trivial API swap
- **(b)** Needs abstraction — requires interface/vtable or file separation
- **(c)** Needs removal — feature not applicable to wasm_rt

#### E1: zware not registered for wasm_exe

| Field | Value |
|-------|-------|
| File | `build.zig:53` |
| Error | `no module named 'zware' available within module 'root'` |
| Chain | `wasm_exe` → `main.zig` → `registry.zig:36` → `wasm/builtins.zig` → `wasm/types.zig:8` → `@import("zware")` |
| Category | **(c)** Remove — zware is a Wasm runtime engine; wasm_rt runs *inside* Wasm, can't embed a Wasm engine |
| Fix | `comptime` gate on `builtin.os.tag != .wasi` to skip wasm/ builtins registration |

#### E2: nREPL — std.net.*, std.Thread.*

| Field | Value |
|-------|-------|
| File | `src/repl/nrepl.zig` |
| Error | `std.net.Address`, `std.net.Server`, `std.Thread.Mutex`, `std.Thread.spawn` unavailable on wasi |
| Chain | `main.zig:14` → `nrepl.zig` → `std.net.*`, `std.Thread.*` |
| Category | **(c)** Remove — no TCP/threading on WASI |
| Fix | Skip nrepl import entirely when `builtin.os.tag == .wasi` |

#### E3: std.posix.getenv — WASI @compileError

| Field | Value |
|-------|-------|
| File | `src/common/builtin/system.zig:50` |
| Error | `std.posix.getenv is unavailable for WASI` (@compileError in std) |
| Chain | `registry.zig:32` → `system.zig` → `std.posix.getenv` |
| Category | **(a)** API swap — use `std.process.getEnvMap()` or null on WASI |
| Fix | `if (builtin.os.tag == .wasi) return .nil else std.posix.getenv(...)` |

#### E4: std.posix.STDERR_FILENO / STDOUT_FILENO / STDIN_FILENO

| Field | Value |
|-------|-------|
| Files | `main.zig:99,111,127,139,140,329,337`, `file_io.zig` |
| Error | `std.posix.system` doesn't define STDERR_FILENO for wasi target |
| Chain | `main.zig` → `std.posix.STDERR_FILENO` |
| Category | **(a)** Conditional compile — `if (wasi) 0/1/2 else std.posix.XXX_FILENO` |
| Fix | Helper fn or `comptime` const; PoC verified fd 0/1/2 work on wasmtime |

#### E5: bootstrap.zig → native/ imports

| Field | Value |
|-------|-------|
| File | `src/common/bootstrap.zig:17,21` |
| Error | Imports `native/evaluator/tree_walk.zig` and `native/vm/vm.zig` |
| Chain | `main.zig` → `bootstrap.zig` → `native/{evaluator,vm}` |
| Category | **(b)** Needs abstraction — bootstrap is in common/ but depends on native/ backends |
| Fix | Backend injection pattern (fn pointer or comptime type parameter) |

#### E6: eval_engine.zig → native/ imports

| Field | Value |
|-------|-------|
| File | `src/common/eval_engine.zig:14,15` |
| Error | Imports VM and TreeWalk from native/ |
| Chain | `root.zig` → `eval_engine.zig` → `native/{vm,evaluator}` |
| Category | **(b)** Needs abstraction — same issue as E5 |
| Fix | Same backend injection pattern as E5; or exclude from wasm_rt |

#### E7: wasm/builtins.zig — std.fs.cwd() for wasm/load

| Field | Value |
|-------|-------|
| File | `src/wasm/builtins.zig:32-37` |
| Error | `wasm/load` reads .wasm files from disk |
| Chain | `registry.zig:36` → `wasm/builtins.zig` → `std.fs.cwd()` |
| Category | **(c)** Remove — wasm_rt can't run nested Wasm modules |
| Fix | Entire `wasm/` namespace excluded on wasm_rt target |

#### E8: file_io.zig — slurp/spit (std.fs.cwd)

| Field | Value |
|-------|-------|
| File | `src/common/builtin/file_io.zig:27,74-82` |
| Error | `std.fs.cwd()`, `openFile`, `createFile` |
| Chain | `registry.zig:31` → `file_io.zig` → `std.fs.cwd()` |
| Category | **(a)** Works on WASI with preopened directories |
| Fix | **No change needed** — `std.fs.cwd()` returns preopened fd=3 on WASI. slurp/spit work if Wasmtime is invoked with `--dir=.` |

#### E9: ns_ops.zig — (load ...) file loading

| Field | Value |
|-------|-------|
| File | `src/common/builtin/ns_ops.zig:85-88` |
| Error | `std.fs.cwd()`, `openFile`, `readToEndAlloc` |
| Chain | `registry.zig:27` → `ns_ops.zig` → `std.fs.cwd()` |
| Category | **(a)** Works on WASI with preopened directories |
| Fix | Same as E8 — works with `--dir=.` |

#### E10: root.zig — nrepl + wasm_types exports

| Field | Value |
|-------|-------|
| File | `src/root.zig:36-39` |
| Error | Exports nrepl and wasm_types which pull in std.net/zware |
| Chain | `root.zig` → `nrepl` / `wasm_types` |
| Category | **(a/c)** Conditional compile to skip these on wasi |
| Fix | `comptime` skip for wasm_types and nrepl on wasi target |

### PoC Validation

Minimal wasm32-wasi binary compiled and ran on wasmtime 41.0.0:
- `std.heap.GeneralPurposeAllocator` — **works** (backed by WasmPageAllocator)
- `std.fs.cwd()` — **works** (returns preopened fd=3)
- `std.fs.File` with fd 1/2 — **works** (stdout/stderr)
- `std.time.milliTimestamp()` — **works** (WASI clock_time_get)
- `std.process.argsAlloc()` — **works** (WASI args_get)
- Binary size: 14KB (ReleaseSmall, minimal program)

### Summary by Category

| Category | Count | Files |
|----------|-------|-------|
| (a) Conditional compile | 4 | system.zig, main.zig (FILENO), root.zig, file_io.zig (already works) |
| (b) Needs abstraction | 2 | bootstrap.zig, eval_engine.zig |
| (c) Needs removal | 3 | wasm/\*, nrepl |

**Total files needing changes**: 7 (out of ~40 source files)
**Critical blockers**: E5 (bootstrap→native) and E6 (eval_engine→native)
**Easy wins**: E1 (zware), E2 (nrepl), E3 (getenv), E4 (FILENO)

---

## Section 2: Code Organization Strategy (26.R.2)

### Decision: D78 — Separate Entry + Comptime Guards

See `.dev/notes/decisions.md` D78 for full rationale.

**Summary**: No wasm_rt/ directory with code copies. Instead:
1. New `src/main_wasm.zig` entry point (eval-only, no nREPL/wasm-interop)
2. ~12 comptime branches across 5 shared files
3. `build.zig` wasm step points to `main_wasm.zig`

### Options Evaluated

| Option | Approach | Pros | Cons | Verdict |
|--------|----------|------|------|---------|
| A | Single main.zig + comptime | Minimal files | Clutters native path | Rejected |
| B | Generic bootstrap<TW,VM> | Clean abstraction | 3374-line refactor | Deferred to P27 |
| **C** | **Separate main + comptime guards** | **Clean separation, minimal changes** | **Two entry points** | **Selected** |
| D | Full wasm_rt/ directory | Maximum isolation | Code duplication | Rejected |

### Per-File Change Plan

| File | Change Type | Comptime Branches | Description |
|------|------------|-------------------|-------------|
| `build.zig` | Modify | 0 | wasm_exe uses main_wasm.zig; no zware dep for wasm |
| `main_wasm.zig` | **New** | 0 | Minimal wasm_rt entry: GC init → bootstrap → eval |
| `root.zig` | Modify | 3 | Skip nrepl, wasm_types, wasm_builtins on wasi |
| `bootstrap.zig` | Modify | 2-3 | TreeWalk/VM import guards; skip evalStringVM on wasi |
| `eval_engine.zig` | Modify | 2-3 | Skip entirely on wasi (not needed for MVP) |
| `registry.zig` | Modify | 1 | Skip wasm_builtins_mod import on wasi |
| `system.zig` | Modify | 1 | getenv: use std.process API on wasi |

**Total new files**: 1 (`main_wasm.zig`)
**Total modified files**: 6
**Total comptime branches**: ~12

### E5/E6 Resolution Detail

**bootstrap.zig** (E5):
```zig
const builtin = @import("builtin");
const is_wasm = builtin.os.tag == .wasi;
const TreeWalk = if (!is_wasm) @import("../native/evaluator/tree_walk.zig").TreeWalk else void;
const VM = if (!is_wasm) @import("../native/vm/vm.zig").VM else void;
```

Functions guarded by `if (!is_wasm)`:
- `evalStringVM()` — VM-only evaluation (wasm_rt uses evalString/TreeWalk or single backend)
- `dumpBytecodeVM()` — debugging tool, native-only
- `callFnVal()` VM dispatch branch — if wasm_rt uses TreeWalk-only

`loadCore()`, `evalString()` — shared, no guards needed (uses TreeWalk).

**eval_engine.zig** (E6):
- `--compare` mode is a native dev tool, not needed on wasm_rt
- Entire file can be guarded: `if (is_wasm) { ... empty stubs ... }`
- Or simply not imported by main_wasm.zig (it's only used by root.zig tests)

### Impact on Build Configuration

```zig
// build.zig wasm step (updated):
const wasm_exe = b.addExecutable(.{
    .name = "cljw",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main_wasm.zig"),  // ← changed
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .wasi,
        }),
        .optimize = optimize,
    }),
});
// No zware dep for wasm_exe (wasm/ namespace excluded)
```

---

## Section 3: Allocator and GC Strategy (26.R.3)

### Question: Does MarkSweepGc work on wasm32-wasi?

**Answer: Yes, as-is. No changes needed.**

### Analysis

#### GPA (GeneralPurposeAllocator) on WASI

PoC validated in 26.R.1:
```zig
var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
```
GPA on wasm32-wasi is backed by `WasmPageAllocator` (via `std.heap.page_allocator`).
WasmPageAllocator calls `memory.grow` for new pages. Tested and working on wasmtime 41.

#### MarkSweepGc Architecture

MarkSweepGc (gc.zig, D69) wraps a backing allocator:
- `init(backing: std.mem.Allocator)` — takes any allocator
- Allocation tracking: `AutoArrayHashMapUnmanaged(usize, AllocInfo)`
- Mark: `markPtr()`, `markAndCheck()`, `markSlice()` via address lookup
- Sweep: iterate tracked allocations, free unmarked
- Free-pool recycling (24C.5): dead allocations cached for O(1) reuse

**All platform-independent** — uses only `std.mem.Allocator` interface.

#### Wasm Memory Grows Only

Wasm linear memory can only grow (via `memory.grow`), never shrink. Impact:

| GC Operation | Wasm Behavior | Acceptable? |
|-------------|--------------|-------------|
| Allocate | memory.grow if needed | Yes |
| Free (to GPA) | GPA marks page as available | Yes (reused internally) |
| Free (pool) | Recycled in-process | Yes (no OS interaction) |
| Shrink memory | **Not possible** | N/A — MarkSweepGc doesn't shrink |

Mark-sweep + free-pool recycling is actually ideal for Wasm:
freed blocks go back to free pools → reused on next allocation.
Memory watermark grows but usable memory stays bounded.

#### WasmGC Feasibility

**Can Zig 0.15.2 emit WasmGC instructions?** No.
- Zig emits linear-memory Wasm only (via LLVM wasm32 backend)
- WasmGC requires `struct.new`, `array.new`, `i31ref` etc. — not in LLVM's wasm backend
- Languages that use WasmGC (Kotlin/Wasm, Dart/Wasm, Go via go-wasm) all have custom compilers
- Dynamic languages on Wasm (Python/Wasm = CPython, Ruby/Wasm = CRuby) compile to
  linear memory with self-managed GC — same approach as ClojureWasm

**Decision: MarkSweepGc as-is for MVP. WasmGC = future phase (requires custom Wasm codegen).**

#### Memory Budget Estimate

| Component | Native (typical) | WASI (estimated) |
|-----------|-----------------|------------------|
| GPA overhead | ~few KB | Same |
| MarkSweepGc HashMap | ~200KB for 10K allocations | Same |
| Free pools | up to 16 pools × 4096 entries | Same |
| core.clj bootstrap | ~2-5MB live values | Same |
| User program | Varies | Same |

Total expected: **5-20MB** for typical programs. Well within Wasm defaults
(wasmtime default max memory = 4GB).

### Decision Summary

| Aspect | Decision | Rationale |
|--------|----------|-----------|
| Backing allocator | GPA → WasmPageAllocator | Works as-is (PoC validated) |
| GC strategy | MarkSweepGc unchanged | Platform-independent code |
| Memory shrink | Not needed | Free-pool recycling handles reuse |
| WasmGC | Deferred (no Zig support) | Requires custom Wasm codegen |
| Threshold tuning | May need lower initial (256KB?) | Wasm programs typically smaller |
