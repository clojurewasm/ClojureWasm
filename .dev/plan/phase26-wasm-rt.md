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
| (c) Needs removal | 3 | wasm/*, nrepl |

**Total files needing changes**: 7 (out of ~40 source files)
**Critical blockers**: E5 (bootstrap→native) and E6 (eval_engine→native)
**Easy wins**: E1 (zware), E2 (nrepl), E3 (getenv), E4 (FILENO)
