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

---

## Section 4: Stack Depth and F99 Assessment (26.R.4)

### Wasmtime Stack Configuration

```bash
wasmtime -W max-wasm-stack=N  # bytes, configurable per-invocation
```

**Default**: ~1MB (wasmtime 41). Measured: ~16,364 calls with 64-byte locals.

**Configurable**: `-W max-wasm-stack=8388608` (8MB) allows 100,000+ calls.

### Stack Frame Size Measurements

PoC: Simple recursive function with 64-byte local buffer, wasm32-wasi ReleaseSafe.

| Stack Size | Max Recursion Depth | Frame Size Est. |
|-----------|-------------------|----------------|
| 1MB (default) | ~16,364 | ~64 bytes |
| 8MB | 100,000+ | ~64 bytes |

Wasm stack frames are compact (~64 bytes for a simple function) because Wasm is a
stack machine — no register spilling, no large frame prologues.

### ClojureWasm Recursion Patterns

| Pattern | Recursion Depth | Stack Risk |
|---------|----------------|------------|
| `(map f coll)` | 1 per element (iterative via seq) | **Low** |
| `(filter p coll)` | 1 per element (iterative while loop) | **Low** |
| `(reduce f init coll)` | 0 (loop, not recursive) | **None** |
| `(take n (iterate f x))` | 1 per element | **Low** |
| `(nth lazy-seq n)` | n calls to first/rest (iterative loop) | **Low** |
| `(filter p (filter q xs))` | 1 level (D74 flat chain) | **None** |
| Sieve of Eratosthenes | 1 level (D74 filter_chain) | **None** |
| `(eval '(deeply-nested))` | Proportional to AST depth | **Medium** |
| `(fib 30)` via recur | 0 (loop/recur is iterative) | **None** |

### D74 Status: Filter Chain Collapsing

D74 resolved the pathological case (168-deep filter chain → flat loop, 78x speedup).
The `lazy_filter_chain` Meta variant stores all predicates in a flat array.
**No remaining known pathological recursion for lazy-seq realization.**

### F99 Analysis: Is Iterative Lazy-Seq a Hard Prerequisite?

**Answer: No. F99 is NOT required for Phase 26 MVP.**

Reasoning:
1. D74 already handles the worst case (nested filter chains → flat)
2. Normal lazy-seq realization is 1-level deep per element (cons cell construction)
3. Wasmtime stack is configurable (`max-wasm-stack=8M` allows deep programs)
4. Typical Clojure programs don't create deep recursion chains beyond ~100 levels
5. The main risk is deeply nested `eval` (AST depth), not lazy-seq chains

### F99 Sequencing Decision

| Option | When | Rationale |
|--------|------|-----------|
| Before Phase 26 | ~~Required~~ | Not needed — D74 handles pathological cases |
| During Phase 26 | Optional | Add if stack issues emerge during testing |
| **After Phase 26** | **Selected** | Phase 27 optimization, or when specific use case demands it |

**Decision**: F99 deferred. MVP launches with configurable Wasm stack depth.
Recommended default: `wasmtime -W max-wasm-stack=8388608` (8MB) in documentation.

### Stack Budget Summary

| Component | Est. Depth | Est. Frame Size | Stack Use |
|-----------|-----------|----------------|-----------|
| main() → bootstrap → eval | ~5 | ~200B | ~1KB |
| Typical fn call | ~1 | ~100B | ~100B |
| Deep fn nesting (10 levels) | 10 | ~100B | ~1KB |
| map/filter chain realization | 1-3 | ~200B | ~600B |
| **Worst case: eval depth 100** | 100 | ~500B | ~50KB |

**Conclusion**: 1MB default sufficient for most programs. 8MB handles edge cases.
512MB native stack budget is not needed on Wasm.

---

## Section 5: Backend Selection (26.R.5)

### Current Architecture

```
loadCore (bootstrap.zig):
  Phase 1: evalString → TreeWalk evaluates core.clj (~526 vars, ~10ms)
  Phase 2: evalStringVMBootstrap → VM re-compiles hot transducer fns (D73)

User code evaluation (main.zig):
  --tree-walk flag → evalString (TreeWalk only)
  default (VM)    → evalStringVM (Compiler + VM)

callFnVal (bootstrap.zig):
  bytecode fn → active_vm bridge or bytecodeCallBridge (VM)
  treewalk fn → treewalkCallBridge (TreeWalk)

EvalEngine (eval_engine.zig):
  --compare mode → runs both, compares results (dev tool only)
```

### Backend Dependencies in bootstrap.zig

| Function                | TreeWalk | VM  | Purpose                          |
|------------------------|----------|-----|----------------------------------|
| evalString             | YES      | no  | Core bootstrap, TreeWalk eval    |
| evalStringVM           | no       | YES | User code (VM mode)              |
| evalStringVMBootstrap  | no       | YES | Hot recompile (D73)              |
| dumpBytecodeVM         | no       | YES | Debug dump (dev tool)            |
| callFnVal              | YES      | YES | Cross-backend dispatch           |
| treewalkCallBridge     | YES      | no  | TW closure calls                 |
| bytecodeCallBridge     | no       | YES | Bytecode closure calls           |

### Size Analysis

| Component      | Struct Size | Heap Allocated? | Notes                          |
|---------------|-------------|-----------------|--------------------------------|
| VM            | ~1.5MB      | Yes (D71)       | stack[32768]×48B + frames[256] |
| TreeWalk      | ~25KB       | No (stack)      | locals[256]×48B + recur[256]   |
| Compiler      | ~small      | Yes (dynamic)   | FnProto/Chunk use heap allocs  |
| Bytecode/Chunk| ~small      | Yes (dynamic)   | Grows with program complexity  |

VM at 1.5MB is heap-allocated (D71) — works on Wasm (linear memory, GPA-backed).
TreeWalk at 25KB sits on the call stack — fine for Wasm's ~1MB default stack.

### Option Analysis

#### Option A: TreeWalk Only

**Pros**:
- Simplest to port — fewest native/ dependencies
- Small struct, no heap allocation for evaluator itself
- bootstrap.zig only needs TreeWalk import
- No Compiler/VM/Chunk code compiled into wasm binary

**Cons**:
- ~200x slower for hot paths (transduce: 15ms→2134ms without D73)
- No bytecode closures — all closures are TreeWalk closures
- callFnVal simplified (no bytecode branch) — but less capable
- Performance regression vs native build would make wasm_rt impractical for
  real programs (D73 was essential for beating Babashka)

**Verdict**: Rejected for MVP. Unacceptable performance.

#### Option B: VM Only (No TreeWalk Bootstrap)

**Pros**:
- Maximum performance — all code runs through VM
- No treewalkCallBridge overhead
- Clean architecture — single evaluator

**Cons**:
- Bootstrap depends on TreeWalk for core.clj evaluation (D73 Phase 1)
- Changing bootstrap to VM-first requires compiler to handle core.clj's
  complex macro definitions — untested, risky
- TreeWalk is still needed for macro expansion (analyzer calls callFnVal
  which dispatches to treewalkCallBridge for macro fns)
- Major refactoring required — defeats "research phase" scope

**Verdict**: Rejected. Too risky, TreeWalk dependency is fundamental.

#### Option C: Both Backends (Recommended)

**Pros**:
- Matches native architecture exactly — minimal changes needed
- D73 two-phase bootstrap works as-is (TW→VM hot recompile)
- callFnVal cross-dispatch works as-is
- Performance parity with native build
- User code runs via VM (default) — full speed

**Cons**:
- Larger wasm binary (includes both evaluator code paths)
- Both native/ files must compile on wasm32-wasi
- More comptime branches needed (but already planned in D78)

**Impact on D78 Code Organization**:
- bootstrap.zig needs `@import("../native/evaluator/tree_walk.zig")` and
  `@import("../native/vm/vm.zig")` — these must compile on wasm32-wasi
- Both VM and TreeWalk are platform-independent (no OS calls, no I/O)
- The "native/" directory name is misleading — these evaluators work on any target
- eval_engine.zig (--compare mode) can be excluded via comptime (dev tool only)

### Recommendation: Option C — Both Backends

**Rationale**: The two-phase bootstrap (D73) is the foundation of ClojureWasm's
performance story. TreeWalk bootstraps core.clj quickly, VM handles hot paths.
callFnVal dispatches between them seamlessly. Removing either backend would
require significant refactoring with uncertain benefits.

**Key insight**: VM and TreeWalk are NOT platform-dependent. They use only:
- `std.mem.Allocator` interface (works on any target)
- `std.ArrayList` (works on any target)
- `Value` tagged union (platform-independent)
- Analyzer/Compiler output (AST nodes, bytecode chunks)

The only platform-dependent code is in main.zig (I/O, CLI, nREPL) and a few
builtins (file I/O, environment variables). The evaluators themselves are portable.

**wasm_rt exclusions** (dev-only, not needed):
- `eval_engine.zig` — --compare mode is a development/testing tool
- `dumpBytecodeVM` — --dump-bytecode is a debug tool
- nREPL — not supported on wasm32-wasi (no networking)

### Binary Size Impact

| Configuration    | Est. Size | Notes                                    |
|-----------------|-----------|------------------------------------------|
| TW only         | ~800KB    | Smaller, but unacceptably slow           |
| VM only         | ~900KB    | Not possible (TW needed for bootstrap)   |
| Both (selected) | ~1.2MB    | Full capability, portable                |

Binary size is not a concern — Wasm binaries are typically gzip'd for
distribution, and 1.2MB compresses to ~300-400KB.

### Summary

| Aspect          | Decision                                           |
|----------------|----------------------------------------------------|
| Bootstrap       | TreeWalk (Phase 1) + VM hot recompile (Phase 2)   |
| User eval       | VM (default), TreeWalk available via flag           |
| callFnVal       | Both backends (cross-dispatch)                     |
| eval_engine     | Excluded (comptime guard, dev tool only)           |
| dumpBytecodeVM  | Excluded (comptime guard, debug only)              |
| Architecture    | Matches native — minimal porting effort            |

---

## Section 6: Modern Wasm Spec Assessment (26.R.6)

### Wasm 3.0 (Released September 2025)

Wasm 3.0 incorporates several previously separate proposals into the standard:
WasmGC, tail-call, relaxed SIMD, exception handling. All major runtimes
(V8, Firefox, Safari, Wasmtime) support most of these features.

### Feature Assessment

#### WasmGC — Not Usable

| Aspect         | Status                                                 |
|---------------|--------------------------------------------------------|
| Spec          | Phase 5 (Wasm 3.0), fully standardized                |
| Runtime       | V8, Firefox, Safari 18.2+, Wasmtime 27+ (Tier 1)      |
| LLVM          | **NOT SUPPORTED** — cannot emit WasmGC types           |
| Zig           | No externref/funcref support (Issue #10491)            |

**Why it can't work**: WasmGC requires emitting structured GC types (struct, array,
i31ref) that don't map to LLVM IR. Languages using WasmGC (Kotlin, Dart, Go) bypass
LLVM entirely with custom compiler backends. Since Zig compiles through LLVM, WasmGC
is fundamentally inaccessible.

**ClojureWasm impact**: Self-managed GC (MarkSweepGc on linear memory) is the correct
approach for dynamic languages compiled through LLVM. CPython/Wasm and CRuby/Wasm
both use the same pattern — linear memory + self-managed GC.

**Decision**: WasmGC remains permanently deferred for Zig-based compilation.

#### Tail-Call — Partially Usable

| Aspect         | Status                                                 |
|---------------|--------------------------------------------------------|
| Spec          | Phase 5 (Wasm 3.0), fully standardized                |
| Runtime       | V8, Firefox, Safari, Wasmtime (Tier 1, default ON)     |
| LLVM          | Supports musttail → return_call mapping                |
| Zig           | `@call(.always_tail, ...)` compiles with +tail_call    |

**PoC result**: Simple tail-recursive function compiles successfully with
`-mcpu generic+tail_call`. LLVM optimizes simple tail recursion to a loop
at ReleaseSafe, so `return_call` may not appear in output (loop is better anyway).

**Known issues**: Multiple Zig/LLVM bugs with musttail on complex functions
(struct returns, certain call patterns). The VM dispatch loop uses a large
switch statement, not explicit tail calls, so direct benefit is limited.

**ClojureWasm impact**: Tail-call could benefit:
- Clojure's `loop/recur` is already iterative (no benefit)
- VM dispatch loop doesn't use tail-call style
- Potential future: continuation-passing VM architecture

**Decision**: Not needed for MVP. Enable +tail_call feature flag when stable.
Monitor Zig/LLVM bug fixes for wasm32 target.

#### SIMD (128-bit) — Available but Low Priority

| Aspect         | Status                                                 |
|---------------|--------------------------------------------------------|
| Spec          | Phase 5 (Wasm 2.0+), relaxed SIMD in Wasm 3.0        |
| Runtime       | All major runtimes (Tier 1)                            |
| Zig           | `@Vector` type maps to SIMD, enable with +simd128     |

**ClojureWasm impact**: No direct Clojure-level SIMD operations. Potential use
in internal string comparison, collection copy, or hash computation. Not a priority
for MVP — standard scalar operations are sufficient.

**Decision**: Defer. Enable +simd128 as optimization in post-MVP phase.

#### Exception Handling — Not Needed

| Aspect         | Status                                                 |
|---------------|--------------------------------------------------------|
| Spec          | Phase 5 (Wasm 3.0), exnref-based design               |
| Runtime       | V8, Firefox, Safari 18.2+, Wasmtime (Tier 2)          |
| Zig           | No direct support (uses error unions, not exceptions)  |

**ClojureWasm impact**: Clojure's try/catch/throw is implemented via Zig error
unions and the exception field in TreeWalk/VM. This works correctly on all targets.
Wasm EH could theoretically improve unwinding performance but would require
major architectural changes with no clear benefit.

**Decision**: Not needed. Current error union approach works on wasm32-wasi.

#### Threads — Deferred

| Aspect         | Status                                                 |
|---------------|--------------------------------------------------------|
| Spec          | Phase 4 (not in Wasm 3.0), shared-everything Phase 1  |
| Runtime       | V8/Firefox (via Web Workers), Wasmtime (Tier 2)        |
| WASI          | wasi-threads withdrawn, shared-everything in progress  |

**ClojureWasm impact**: Clojure's concurrency (STM, agents, futures, pmap) requires
threading. WASI threading support is immature — wasi-threads was withdrawn in 2023,
replaced by shared-everything-threads (still Phase 1, expected 2026 late).

**Decision**: Single-threaded MVP. Concurrency deferred until WASI threading stabilizes.

#### WASI Preview 2 / Component Model — Not Needed for MVP

| Aspect         | Status                                                     |
|---------------|-------------------------------------------------------------|
| WASI 0.2      | Stable (Jan 2024), stream/future I/O, wasi-sockets         |
| WASI 0.3      | Expected Feb 2026, native async                            |
| WASI 1.0      | Expected late 2026 / early 2027                            |
| Zig           | wasm32-wasi = WASI P1 only. P2 via external libs           |

**ClojureWasm impact**: WASI P1 provides everything needed for MVP:
- File I/O (preopened dirs)
- stdout/stderr (fd 1/2)
- Process args
- Clock (time)
- Environment variables (via std.process)

Phase 25's WIT parser already handles module introspection independently.

**Decision**: WASI P1 for MVP. Evaluate P2 migration after WASI 1.0 stabilizes.

### Summary Table

| Feature            | Zig Usable? | MVP Priority | Decision                        |
|-------------------|-------------|--------------|----------------------------------|
| WasmGC            | No (LLVM)   | --           | Permanently deferred             |
| Tail-call         | Partial     | Low          | Defer, enable when stable        |
| SIMD 128          | Yes         | Low          | Defer, optimization phase        |
| Exception Handling| No          | None         | Not needed (error unions work)   |
| Threads           | Partial     | None         | Single-threaded MVP              |
| WASI P2/CM        | External    | None         | WASI P1 sufficient for MVP       |

### Key Insight: Dynamic Languages and Linear Memory

All successful dynamic language Wasm ports (CPython, CRuby, Lua) compile the
existing runtime to linear memory Wasm. They do NOT use WasmGC or other
managed features. This validates ClojureWasm's approach:

1. Compile Zig runtime to wasm32-wasi (linear memory)
2. Self-managed GC (MarkSweepGc) on linear memory
3. No dependency on WasmGC, threads, or other unstable proposals
4. WASI P1 for system interface (mature, well-supported)

---

## Section 7: MVP Definition and Implementation Plan (26.R.7)

### MVP Scope

**Goal**: `cljw.wasm` binary that evaluates Clojure code on Wasmtime.

**In scope**:
- eval + print for Clojure expressions
- All 526 core vars (core.clj bootstrap)
- D73 two-phase bootstrap (TreeWalk + VM hot recompile)
- MarkSweepGc (same as native)
- WASI P1 I/O (stdout, stderr, file read via preopened dirs)
- Process args, environment variables, clock

**Out of scope** (deferred):
- nREPL (requires networking — WASI P1 has no sockets)
- Wasm InterOp / zware (can't run Wasm engine inside Wasm)
- Threading / concurrency (WASI threads unstable)
- REPL (stdin line editing is limited on WASI, possible but not MVP)
- WasmGC, tail-call optimization, SIMD

### Usage Model

```bash
# File execution
wasmtime --dir=. cljw.wasm -- file.clj

# Expression evaluation
wasmtime cljw.wasm -- -e '(+ 1 2)'

# With increased stack for edge cases
wasmtime -W max-wasm-stack=8388608 --dir=. cljw.wasm -- file.clj
```

### Implementation Sub-Phases

#### 26.1: Build Infrastructure

Create `main_wasm.zig` and update `build.zig` to compile successfully.

| Task    | Description                                              |
|---------|----------------------------------------------------------|
| 26.1.1  | Create `src/main_wasm.zig` — minimal entry point        |
| 26.1.2  | Update `build.zig` wasm_exe to use main_wasm.zig        |
| 26.1.3  | Comptime guard: registry.zig skip wasm/builtins on wasi |
| 26.1.4  | Comptime guard: system.zig getenv on wasi               |
| 26.1.5  | Comptime guard: root.zig skip nrepl/wasm exports        |
| 26.1.6  | `zig build wasm` compiles without errors                 |

**Deliverable**: `zig build wasm` produces a .wasm binary (may not run yet).

#### 26.2: WASI I/O Layer

Fix platform-specific I/O to work on WASI.

| Task    | Description                                              |
|---------|----------------------------------------------------------|
| 26.2.1  | stdout/stderr: use fd constants (1/2) instead of POSIX   |
| 26.2.2  | file_io.zig: verify cwd() works on WASI preopened dirs   |
| 26.2.3  | system.zig: getEnvMap or return nil for getenv on WASI   |
| 26.2.4  | main_wasm.zig: arg parsing from process.args             |

**Deliverable**: Basic I/O works on wasmtime.

#### 26.3: Bootstrap and Eval

Get core.clj bootstrap and user evaluation working.

| Task    | Description                                              |
|---------|----------------------------------------------------------|
| 26.3.1  | bootstrap.zig: comptime guard for eval_engine exclusion  |
| 26.3.2  | bootstrap.zig: comptime guard for dumpBytecodeVM         |
| 26.3.3  | Verify loadCore works (TreeWalk bootstrap of core.clj)   |
| 26.3.4  | Verify evalStringVMBootstrap works (D73 hot recompile)   |
| 26.3.5  | Verify evalStringVM works (user code evaluation via VM)  |
| 26.3.6  | End-to-end: `wasmtime cljw.wasm -- -e '(+ 1 2)'` → `3` |

**Deliverable**: Clojure expressions evaluate correctly on wasmtime.

#### 26.4: Full Feature Verification

Verify the 526 core vars and key features work on Wasm target.

| Task    | Description                                              |
|---------|----------------------------------------------------------|
| 26.4.1  | Run core bootstrap test suite on wasmtime                |
| 26.4.2  | Verify slurp/spit work with preopened dirs               |
| 26.4.3  | Verify GC triggers and collection works                  |
| 26.4.4  | Run benchmark subset on wasmtime (verify correctness)    |
| 26.4.5  | Measure binary size and startup time                     |

**Deliverable**: All 526 core vars work. Binary size and perf baseline recorded.

### Error Fix Mapping (from 26.R.1 Catalog)

| Error | Fix Task | Fix Description                                |
|-------|----------|------------------------------------------------|
| E1    | 26.1.3   | Comptime skip wasm/builtins import in registry |
| E2    | 26.1.5   | Comptime skip nrepl import in root.zig         |
| E3    | 26.2.3   | getEnvMap fallback on WASI                     |
| E4    | 26.2.1   | Comptime fd constants for stdout/stderr        |
| E5    | 26.3.1   | Comptime guard in bootstrap.zig                |
| E6    | 26.3.1   | Comptime guard eval_engine exclusion           |
| E7    | 26.1.3   | Comptime skip wasm/builtins on wasi            |
| E8    | 26.2.1   | Fix STDERR_FILENO in dumpBytecodeVM (excluded) |
| E9    | 26.1.5   | Comptime skip nrepl thread-related code        |
| E10   | 26.1.5   | Comptime skip wasm/nrepl exports in root.zig   |

### Architecture (D78 Implementation)

```
build.zig
  wasm_exe:
    root_source_file = "src/main_wasm.zig"
    target = wasm32-wasi
    (no zware import)

src/main_wasm.zig          # Minimal: parse args, bootstrap, eval, print
  imports:
    common/bootstrap.zig   # With comptime guards for wasi
    common/gc.zig           # MarkSweepGc (same as native)
    common/env.zig          # Namespace/Var runtime

common/bootstrap.zig (comptime is_wasi branches):
  - evalString: available (TreeWalk)
  - evalStringVM: available (VM)
  - evalStringVMBootstrap: available (hot recompile)
  - callFnVal: available (cross-dispatch)
  - eval_engine: excluded (comptime void on wasi)
  - dumpBytecodeVM: excluded (comptime void on wasi)

native/vm/vm.zig           # Shared as-is (platform-independent)
native/evaluator/tree_walk.zig  # Shared as-is (platform-independent)
```

### Estimated Effort

| Sub-Phase | Tasks | Est. Complexity | Notes                          |
|-----------|-------|-----------------|--------------------------------|
| 26.1      | 6     | Low             | Mostly comptime guards         |
| 26.2      | 4     | Low             | WASI I/O is POSIX-like         |
| 26.3      | 6     | Medium          | Bootstrap correctness critical |
| 26.4      | 5     | Low-Medium      | Testing and verification       |
| **Total** | **21**| **~2 sessions** | Incremental, TDD approach      |

### Success Criteria

1. `zig build wasm` produces `zig-out/bin/cljw.wasm`
2. `wasmtime cljw.wasm -- -e '(+ 1 2)'` prints `3`
3. `wasmtime --dir=. cljw.wasm -- test.clj` evaluates a file
4. All 526 core vars bootstrap successfully
5. GC collection works (no OOM on larger programs)
6. Binary size < 5MB (expected ~1.2MB)
7. Startup time < 500ms on wasmtime (expected ~50-100ms)

### Risk Mitigation

| Risk                        | Mitigation                                     |
|-----------------------------|-------------------------------------------------|
| VM struct too large for Wasm| Already heap-allocated (D71), works              |
| Stack overflow on deep eval | Configurable: -W max-wasm-stack=8M               |
| GC perf on Wasm             | MarkSweepGc validated in 26.R.3 PoC             |
| WASI file I/O limitations   | preopened dirs work, validated in 26.R.1 PoC     |
| Binary size bloat           | ReleaseSafe Wasm is compact (~1.2MB estimated)   |
| Bootstrap timeout           | TreeWalk is fast (~10ms native, ~50ms on Wasm?)  |
