# Design Decisions

Architectural decisions for ClojureWasm. Reference by searching `## D##`.
Only architectural decisions (new Value variant, subsystem design, etc.) — not bug fixes.

Pruned 2026-02-08: removed 61 historical/superseded/implementation-detail entries.
See git history for full archive.

---

## D3: Instantiated VM — No Threadlocal from Day One

**Decision**: VM is an explicit struct instance passed as parameter. No global
or threadlocal state anywhere.

**Rationale** (.dev/future.md SS15.5):

- Beta used 8 threadlocal variables in defs.zig, making embedding impossible
- Instantiated VM enables: multiple VMs in one process, library embedding mode,
  clean testing (each test gets fresh VM)

**Known exceptions**: macro_eval_env (D15), predicates.current_env (T9.5.5),
bootstrap.last_thrown_exception, keyword_intern.table,
collections._vec_gen_counter (24C.4), lifecycle.shutdown_requested/hooks (34.5),
http_server.build_mode/background_mode/bg_server (34.2)

---

## D6: Dual Backend with --compare from Phase 2

**Decision**: Implement TreeWalk evaluator alongside VM from Phase 2.
Wire --compare mode immediately.

**Rationale** (.dev/future.md SS9.2):

- Beta's --compare mode was "the most effective bug-finding tool"
- TreeWalk is simpler to implement correctly (direct Node -> Value)
- VM bugs often produce wrong values silently (not crashes)

**Development rule** (enforced from Phase 3 onward):
When adding any new feature (builtin, special form, operator), implement it
in **both** backends and add an `EvalEngine.compare()` test.

| Component  | Path                                 |
|------------|--------------------------------------|
| VM         | `src/native/vm/vm.zig`               |
| TreeWalk   | `src/native/evaluator/tree_walk.zig` |
| EvalEngine | `src/common/eval_engine.zig`         |

---

## D10: English-Only Codebase

**Decision**: All source code, comments, commit messages, PR descriptions,
and documentation are in English.

**Rationale**: OSS readiness from day one. Beta used Japanese comments/commits,
which limited accessibility. Agent response language is personal preference
(configured in ~/.claude/CLAUDE.md).

---

## D12: Division Semantics — Float Now, Ratio Later

**Decision**: The `/` operator returns Ratio for non-exact int division, matching JVM.
Ratio type implemented (F3 resolved).

**Clojure JVM**: `(/ 6 3)` → `2` (Long), `(/ 1 3)` → `1/3` (Ratio).
**ClojureWasm**: `(/ 6 3)` → `2.0` (float), `(/ 1 3)` → `0.333...` (float).

**When to implement Ratio**: When tests fail due to precision loss from float
approximation.

---

## D36: Unified fn_val dispatch via callFnVal

**Decision**: Single `callFnVal(allocator, fn_val, args)` function in bootstrap.zig.
Routes by Value tag and Fn.kind:

- `builtin_fn` → direct call
- `fn_val(.bytecode)` → bytecodeCallBridge (creates new VM instance)
- `fn_val(.treewalk)` → treewalkCallBridge (creates new TreeWalk)
- `multi_fn`, `keyword`, `map`, `set` → IFn dispatch

All call sites import `bootstrap.callFnVal` directly (no callback fields/module vars).

---

## D56: VM Closure Capture — Per-Slot Array

**Decision**: Replace contiguous `capture_base + capture_count` with
`capture_slots: []const u16` in FnProto. Each slot index is recorded
individually, allowing capture from arbitrary non-contiguous stack positions.

**Rationale**: Contiguous capture failed when locals occupied non-contiguous
stack slots (e.g., self-ref at slot 0, let binding at slot 2, nothing at slot 1).

---

## D62: Transducer Foundation

**Decision**: Transducer support via 1-arity map/filter, extended conj/deref,
and `transduce` using plain reduce (not protocol-based coll-reduce).

Key functions: `transduce`, `into` (3-arity), `cat`, `halt-when`, `dedupe`,
`preserving-reduced`, `sequence` (1-arity).

`halt-when` uses `:__halt` instead of `::halt` (auto-qualified keywords not supported).

---

## D63: Error System — Threadlocal (Supersedes D3a)

**Decision**: Threadlocal error state (same pattern as Beta). Module-level
functions `setError()`, `setErrorFmt()`, `getLastError()`, `setSourceText()`.

**Rationale**: Instance-based ErrorContext (D3a) caused error info loss — context
lived on evalString()'s stack, out of scope when errors propagated to main().
Threadlocal eliminates the scope boundary problem. Single-threaded execution
means no thread safety concerns.

---

## D65: Lazy Sequence Infrastructure

**Decision**: Core seq functions (map, filter, take, take-while, concat, range,
mapcat) use lazy-seq/cons in core.clj. `realizeValue()` in collections.zig
handles transparent lazy→eager conversion at system boundaries.

**Realize boundaries**: eqFn/neqFn, VM .eq/.neq opcodes, print/pr/println/prn,
str/pr-str, valueToForm, withMetaFn.

---

## D68: Namespace-Isolated Function Execution

**Decision**: Capture defining namespace on `Fn` objects and restore during
function calls. Unqualified symbol resolution happens in the defining namespace.

- `value.zig`: `Fn.defining_ns: ?[]const u8`
- `vm.zig`: `CallFrame.saved_ns` saves/restores `env.current_ns`
- `tree_walk.zig`: `makeClosure`/`callClosure` save/restore namespace

**Rationale**: JVM Clojure captures Var references at compile time. Our
runtime-resolved approach caused cross-namespace shadowing.

---

## D69: Mark-Sweep GC Allocator (Phase 23)

**Decision**: `MarkSweepGc` in `src/common/gc.zig` using HashMap-based
allocation tracking (keyed by pointer address).

- Provides `std.mem.Allocator` interface (alloc/resize/remap/free vtable)
- Provides `GcStrategy` interface (alloc/collect/shouldCollect/stats vtable)
- HashMap uses backing allocator (not GC allocator) to avoid circular dependency
- Allocation threshold controls `shouldCollect()` trigger

---

## D70: Three-Allocator Architecture (Phase 23.5)

**Decision**: Three allocator tiers:

- **GPA (infra_alloc)**: Env, Namespace, Var, HashMap backings — stable infrastructure
- **node_arena (GPA-backed ArenaAllocator in Env)**: Reader Forms, Analyzer Nodes —
  AST data referenced by TreeWalk closures, persists for program lifetime
- **GC allocator (gc_alloc)**: Values (Fn, collections, strings) — mark-sweep collected

**Rationale**: GC sweep frees ALL unmarked allocations. AST Nodes are not Values
and cannot be traced by the GC.

---

## D71: Heap-Allocated VM Struct

**Decision**: Always heap-allocate VM structs (via `allocator.create(VM)`).
The VM struct is ~1.5MB (NaN-boxed: ~256KB) due to fixed-size operand stack.
Stack-allocated VMs cause native stack overflow in nested calls.

---

## D73: Two-Phase Bootstrap — TreeWalk + VM Hot Recompilation

**Decision**: Two-phase bootstrap in loadCore:
1. Phase 1: Evaluate core.clj via TreeWalk (fast startup, all functions defined)
2. Phase 2: Re-evaluate hot transducer functions (map, filter, comp) via VM compiler,
   replacing TreeWalk closures with bytecode closures.

**evalStringVMBootstrap**: Compiles via Compiler+VM, does NOT deinit — FnProtos
must persist because they are stored in Vars.

**Trade-off**: transduce 2134→15ms (142x), startup +5ms.

---

## D74: Filter Chain Collapsing + Active VM Call Bridge

**Decision**: Flatten nested filter chains + reuse active VM in callFnVal.

1. **Filter chain collapsing** (value.zig): `lazy_filter_chain` Meta variant stores
   flat `[]const Value` of predicates + source. Avoids 168 levels of recursive
   realize() for sieve-like programs.

2. **Active VM call bridge** (bootstrap.zig): callFnVal checks `vm_mod.active_vm`
   before allocating a new VM. Eliminates ~500KB heap allocation per call.

**Result**: sieve 1645→21ms (78x), memory 2997→24MB (125x).

---

## D76: Wasm InterOp Value Variants — wasm_module + wasm_fn

**Decision**: Two Value variants for Wasm FFI:
- `wasm_module: *WasmModule` — heap-allocated, owns Store/Module/Instance
- `wasm_fn: *const WasmFn` — bound export name + signature, callable via callFnVal

**Namespace**: `cljw.wasm` (D82), registered in registry.zig.

**Type conversion**: integer↔i32/i64, float↔f32/f64, boolean/nil→i32(0/1).

---

## D77: Host Function Injection — Clojure→Wasm Callbacks

**Decision**: Global trampoline + context table (256 slots) for host function injection.

- `(wasm/load "m.wasm" {:imports {"env" {"log" clj-fn}}})` registers Clojure fns
- `HostContext` stores: Clojure fn Value, param/result counts, allocator
- Single `hostTrampoline(vm, ctx_id)` handles all callbacks

**Rationale**: Context table (vs closures) because Zig closures cannot be
passed as fn pointers.

---

## D79: Strategic Pivot — Native Production Track

**Decision**: Defer wasm_rt implementation. Pivot to native production track.

**Rationale**:
- WasmGC: LLVM cannot emit WasmGC types, no timeline
- Wasmtime GC: Cycle collection unimplemented
- WASI Threads: Specification in flux
- Native track has immediate high-value opportunities

**Consequence**: wasm_rt deferred until ecosystem matures.
See `src/wasm_rt/README.md` for revival conditions.

---

## D80: nREPL Memory Model — GPA-only, no ArenaAllocator

**Decision**: nREPL uses GPA directly for all allocations — both Env (persistent)
and evalString (transient). No ArenaAllocator.

**Rationale**: ArenaAllocator.free() in Zig 0.15.2 performs "last allocation rollback"
optimization. When persistent data (Vars) and transient data share the same arena,
free/alloc cycles for transient data can overwrite persistent allocations.

---

## D81: Build System Architecture — Pre-compiled Bootstrap Cache

**Decision**: Generate bootstrap cache at Zig build time, embed as binary data.
User-facing paths: `cljw file.clj` (run) and `cljw build file.clj -o app` (single binary).

- registerBuiltins() at startup (Zig function pointers not serializable)
- restoreFromBootstrapCache (replaces loadBootstrapAll)
- Full runtime always included in built binaries

**Result**: ~6x faster startup (~12ms → ~2ms).

---

## D82: Namespace Naming Convention — clojure.* + cljw.* Split

**Decision**: Two-prefix convention (Babashka model):

1. **`clojure.*`** — JVM Clojure-compatible namespaces
2. **`cljw.*`** — ClojureWasm-unique extensions (cljw.wasm, cljw.http, cljw.build)
3. **`user`** — Default namespace

`clojure.java.*` names kept for compatibility (matches Babashka's approach).

---

## D83: HTTP Server Architecture — Blocking + Background Mode

**Decision**: `cljw.http` namespace with Ring-compatible handler model.

1. **Blocking mode** (default): `run-server` runs accept loop in calling thread
2. **Background mode** (with `--nrepl`): spawns background thread, returns immediately
3. **Build mode**: returns nil during `cljw build` to prevent blocking
4. **Threading**: Thread per connection with mutex on handler call

---

## D84: Custom Wasm Runtime — Replace zware Dependency

**Decision**: Custom Wasm runtime in `src/wasm/runtime/` replacing zware.

1. **Switch-based dispatch** — works on all Zig backends (cross-compilation)
2. **Direct bytecode execution** — no intermediate representation
3. **Wasm MVP + WASI Preview 1** — ~200 opcodes + SIMD (236 opcodes), 19 WASI functions

**Scope**: ~5300 LOC, 8 files. Zero external dependencies.

---

## D85: NaN Boxing 4-Heap-Tag — 48-Bit Address Support

**Decision**: 4-heap-tag NaN boxing scheme for Value representation (8 bytes).

**Encoding** (top 16 bits of u64):
- `< 0xFFF9`: float (raw f64 bits)
- `0xFFF9`: integer (48-bit signed)
- `0xFFFB`: constant (nil, true, false)
- `0xFFFC`: char (u21 codepoint)
- `0xFFFD`: builtin function pointer
- `0xFFF8/0xFFFA/0xFFFE/0xFFFF`: heap pointers (3-bit sub-type + 45-bit shifted address)

**28 heap types** across 4 tags. 8-byte alignment shift (addr >> 3) gives 48-bit
effective address range. Negative NaN canonicalized to positive NaN.

**Supersedes**: D72 (original NaN boxing with 40-bit address, deferred).

---

## D86: Wasm Interpreter Optimization Strategy (Non-JIT)

**Decision**: Three targeted optimizations for switch-based Wasm interpreter:

1. **VM reuse** (36.7A): Cache `Vm` in `WasmModule`, `reset()` per invoke
2. **Branch target precomputation** (36.7B): Lazy sidetable in `WasmFunction.branch_table`
3. **Memory/local optimization** (36.7C): Abandoned — ROI too low

**Results** (hyperfine, ReleaseSafe):

| Benchmark   | Before  | After  | Speedup |
|-------------|---------|--------|---------|
| wasm_call   | 931ms   | 118ms  | 7.9x    |
| wasm_fib    | 11046ms | 7663ms | 1.44x   |
| wasm_memory | 192ms   | 26ms   | 7.4x    |
| wasm_sieve  | 822ms   | 792ms  | 1.04x   |

**Resolved**: Register IR implemented in zwasm. LEB128 predecode and bytecode fusion done (Phase 37/45).

---

## D87: ARM64 JIT PoC — Hot Loop Native Code Generation

**Decision**: Compile hot integer arithmetic loops to native ARM64 machine code at
runtime. Interpreter-integrated, single-loop cache, automatic deopt.

**Architecture**:

- **Detection**: Back-edge counter in `vmRecurLoop`. Threshold = 64 iterations.
- **Compilation**: `jit.zig` — `analyzeLoop` extracts loop ops, `compileLoop` emits ARM64.
  Supported ops: branch_ne/ge/gt (locals/const), add/sub (locals/const), recur_loop.
- **NaN-box integration**: SBFX unbox at entry, AND+ORR re-box at exit.
  `used_slots` bitset: only loads/checks slots referenced by loop body (skips closure self-ref).
- **THEN path skip**: `analyzeLoop` uses `exit_offset` from data word to jump past
  exit code, only analyzing the ELSE path (loop body).
- **Execution**: W^X transition (mmap WRITE → mprotect READ|EXEC), `sys_icache_invalidate`.
- **JitState per VM**: Single cached loop. `maxInt(u32)` sentinel prevents retry after deopt.
- **Platform**: ARM64 only (`comptime` check on `builtin.cpu.arch == .aarch64`).
  No-op on other architectures.

**Results** (hyperfine, ReleaseSafe, Apple M4 Pro):

| Benchmark     | Before (37.3) | After (37.4) | Speedup |
|---------------|---------------|--------------|---------|
| arith_loop    | 31ms          | 3ms          | 10.3x   |
| fib_recursive | 16ms          | 16ms         | 1.0x    |
| (cumulative)  | 53ms (base)   | 3ms          | 17.7x   |

**Scope limitation**: PoC targets simple integer loops only. Not compiled: function calls,
heap allocation, string ops, collection ops. fib_recursive uses recursion (not loop),
so JIT does not apply.

## D88: Cross-Boundary Exception Handling — call_target_frame Scope Isolation

**Decision**: Add `call_target_frame` field to VM to prevent exception handlers from
dispatching across VM/TreeWalk bridge boundaries.

**Problem**: When execution crosses VM→TW→VM boundaries (e.g. `run-tests` → `do-testing`
→ TW closure → `derive` throws), `throw_ex` dispatches to the nearest handler regardless
of call boundary. This causes an outer scope's `try/finally` handler (from `binding` in
`do-testing`) to intercept exceptions meant for inner scope's `try/catch` (from TW's
`thrown?`).

**Architecture**:

- `call_target_frame: usize` on VM — set by `callFunction` to current `frame_count`
- `throw_ex`: only dispatch to handler if `handler.saved_frame_count > call_target_frame`
- `executeUntil`: same scope check before error handler dispatch
- `callFunction`: `errdefer` restores `sp`, `frame_count`, and `current_ns` on error
  propagation, preventing stale frames from corrupting subsequent calls

**Companion fix**: Deferred var_ref resolution in bootstrap cache. `var_ref` constants
(e.g. `(var *testing-contexts*)`) are serialized with ns/var names but cannot be resolved
during `readFnProtoTable` (vars don't exist yet). Deferred fixup list resolves them after
`restoreEnvState`.

**Files**: `src/native/vm/jit.zig` (new, ~700 lines), `src/native/vm/vm.zig` (JitState integration).

## D89: Four New Value Types — Array, BigInt, Ratio, BigDecimal (Phase 43)

**Decision**: Reserve NanHeapTag slots 29 (big_int), 30 (ratio+big_decimal), 31 (array)
in Group D for four Value types needed by Phase 43 (Numeric Types + Arrays).

**Types**:

- **ZigArray**: Mutable typed container (`items: []Value`, `element_type: ElementType`).
  ElementType enum: object, int, long, float, double, boolean, byte, short, char.
  Equivalent to JVM's `Object[]` / `int[]` etc. Identity equality (mutable).
- **BigInt**: Arbitrary precision integer backed by `std.math.big.int.Managed`.
  Structural equality via `Const.eql()`. Printed as `<digits>N`.
- **Ratio**: Exact rational as numerator/denominator BigInt pair.
  Structural equality. Printed as `<num>/<den>`.
- **BigDecimal**: Scaled BigInt (unscaled × 10^(-scale)). Shares NanHeapTag slot 30
  with Ratio via `NumericExtKind` discriminator enum(u8) as first field of both
  `extern struct`s. Printed as `<digits>M`.

**GC**: Array traces all items. BigInt marks struct only (limbs managed by allocator).
Ratio marks struct + numerator/denominator BigInt pointers.
BigDecimal marks struct + unscaled BigInt pointer.

**Files**: `src/common/value.zig`, `src/common/collections.zig`, `src/common/gc.zig`,
`src/common/builtin/array.zig` (new).

## D90: Wasm Interpreter Optimization Strategy (Phase 44.5 Research)

**Decision**: Defer full Wasm interpreter optimization to post-alpha. The recommended
approach for future work is predecoded IR + tail-call threaded dispatch.

**Research findings** (Phase 44.5):
- Current: switch-based dispatch, inline LEB128 decode, lazy HashMap branch table
- Baseline: wasm_fib 7539ms, wasm_sieve 782ms, wasm_call 121ms
- Zig 0.15.2 supports `@call(.always_tail, handler, ...)` — verified working
- Recommended approach: predecode bytecode → fixed-width IR (8 bytes/instr),
  then threaded dispatch via function pointer table + tail calls
- Expected impact: 40-60% improvement (2-3x for fib)
- Effort: HIGH (3177-line vm.zig, 200+ opcodes, control flow complexity)

**Why defer**: Alpha release priorities are correctness and documentation.
The Clojure execution speed is already competitive (19/20 wins vs Babashka).
Wasm speed is aspirational — users care about Clojure code speed first.

**Post-alpha plan**: Predecoded IR (eliminates LEB128 + bounds checks) → tail-call
dispatch (eliminates branch misprediction) → superinstructions (fuse common patterns).

## D91: Directory Restructure — Pipeline-Based Layout

**Decision**: Restructure src/ from legacy common/native/ two-tier layout to
pipeline-oriented structure where each compilation stage is a top-level directory.

**Before**: `src/common/` (Reader, Analyzer, Compiler, Builtins, Value all mixed),
`src/native/` (just VM + TreeWalk). Pipeline structure invisible from outside.

**After**:
```
src/
  reader/      → Stage 1: Source → Form
  analyzer/    → Stage 2: Form → Node
  compiler/    → Stage 3: Node → Bytecode (was bytecode/)
  vm/          → Stage 4a: Bytecode → Value
  evaluator/   → Stage 4b: Node → Value (TreeWalk)
  runtime/     → Core types + lifecycle (was common/ loose files)
  builtins/    → Built-in functions (was common/builtin/)
  regex/       → Regex engine
  repl/        → nREPL + REPL (unchanged)
  wasm/        → WebAssembly runtime (flattened from wasm/runtime/)
```

**Merges**: strings+clj_string → strings, io+file_io+java_io → io,
arithmetic+numeric → arithmetic. 70 → 66 files.

**Rationale**: OSS release visibility. New contributors can see the compilation
pipeline from the directory listing. The common/native split was a wasm_rt-era
artifact with no current meaning.

## D92: zwasm Integration — External Wasm Runtime Dependency

**Decision**: Replace CW's internal wasm engine (9 files, ~9300 LOC) with zwasm
as a GitHub URL dependency (v0.1.0, https://github.com/clojurewasm/zwasm).
CW keeps a thin bridge file (`src/wasm/types.zig`) that wraps zwasm's public API
into CW's Value system.

**Before**: CW had a frozen copy of the wasm runtime (vm, store, module, instance,
opcode, predecode, memory, leb128, wasi) in `src/wasm/`. This was the Phase 35W
engine, missing Register IR, ARM64 JIT, and post-Phase 45 optimizations.

**After**:
```
src/wasm/
  types.zig      → Bridge: delegates to zwasm.WasmModule, keeps Value↔u64 marshalling
  builtins.zig   → Unchanged (imports from types.zig)
  wit_parser.zig → Unchanged (CW-specific WIT handling)
```

**Bridge design**: `WasmModule.inner: *zwasm.WasmModule` delegation pattern.
Host function trampoline uses `zwasm.Vm` for stack access, `zwasm.inspectImportFunctions`
for import type resolution. The bridge handles Value↔u64 conversion, HostContext,
and Clojure imports map → `[]zwasm.ImportEntry` translation.

**Build**: `build.zig.zon` GitHub URL dependency (v0.1.0 tag tarball).
`zig build` auto-fetches zwasm. Native targets only (wasm32-wasi does not link zwasm).

**Benefits**:
- -9300 LOC in CW (maintenance burden eliminated)
- CW automatically inherits zwasm improvements (Register IR, JIT, spec compliance)
- zwasm remains fully independent (no CW-specific code)

**zwasm API additions** (generic, not CW-specific):
- `pub const Vm` — re-export for embedder host function access
- `inspectImportFunctions()` — pre-analysis utility for import type metadata

## D93: case* Special Form — Hash-Based Constant Dispatch

**Decision**: Implement `case*` as a proper special form across the full pipeline
(Analyzer → Node → Compiler + TreeWalk), replacing the previous cond-based `case`
macro with the upstream case*/hash-dispatch design.

**Node type**: `CaseNode` (expr, shift, mask, default, clauses, test_type, skip_check).
Three test types: `:int` (integer identity), `:hash-equiv` (hash + equality),
`:hash-identity` (hash + identity for interned types like keywords).

**Compiler**: Equality-check chain — for each clause: dup expr, load constant,
eq, conditional jump. O(n) but correct. Future: switch to table jump for `:compact`.

**TreeWalk**: Hash-based dispatch — compute shift-masked hash, scan clauses for match,
optional skip-check for hash collision buckets.

**case macro**: Ported from upstream. Uses `prep-ints`/`prep-hashes` to compute
optimal shift/mask parameters. Helper functions: `shift-mask`, `maybe-min-hash`,
`case-map`, `fits-table?`, `prep-ints`, `merge-hash-collisions`, `prep-hashes`.

**Also fixed**: Vector destructuring (`makeNthCall`) now uses 3-arity `nth` with
nil default, matching Clojure's behavior of returning nil for missing positions
instead of throwing.

## D94: GC Thread Safety — Mutex + Stop-the-World Architecture

**Decision**: Make MarkSweepGc thread-safe via a single `gc_mutex` that serializes
all allocation (msAlloc/msFree/msResize/msRemap) and collection (collectIfNeeded,
gcCollect = traceRoots + sweep) paths.

**Design**: Global GC lock approach — simplest correct implementation. The mutex
is held for the entire mark+sweep cycle, preventing allocation during collection
(stop-the-world). Multiple threads serialize on the mutex for allocation.

**Thread registry**: `ThreadRegistry` tracks active mutator thread count via
atomic counter. Infrastructure for future safe-point integration — when a thread
triggers collection, it will signal others to pause at safe points, wait for
all to reach safe points, then collect with combined root sets.

**Scope**: Phase 48.2 adds the mutex + registry. Thread spawning (48.3) will
integrate safe-point coordination. Future optimization: concurrent marking,
thread-local allocation buffers (TLABs), generational collection.

## D95: Protocol/ProtocolFn Serialization — Eliminating Startup Re-evaluation

**Problem**: After D81 (bootstrap cache), Protocol and ProtocolFn values were not
serializable. `restoreFromBootstrapCache` called `reloadProtocolNamespaces` to
re-evaluate protocols.clj + reducers.clj (~440 lines) via TreeWalk at every startup,
causing 23.3ms startup time and 226MB memory usage.

**Decision**: Serialize Protocol and ProtocolFn values in the bootstrap cache.
Protocol stores name + method_sigs + impls (nested map of type_key → method_map).
ProtocolFn stores method_name + protocol var reference (ns + name), resolved via
deferred fixup after env restore. Fn closure_bindings also serialized.

**Cache invalidation**: Protocol gains a `generation` counter, incremented on every
`extend_type_method` / `extend-type` call. ProtocolFn inline cache checks
`cached_generation == protocol.generation` to detect stale entries. This fixes a
latent bug where VM-compiled reify forms share compile-time type keys, causing the
monomorphic cache to return stale methods when the same type key gets new impls.
Also fixed `extend_type_method` to replace existing methods (same name) in the
method map instead of always appending.

**Result**: Startup 23.3ms → 5.3ms (4.4x), memory 226MB → 8.1MB (28x reduction).
All upstream tests pass, no regression.
