# ClojureWasm Design Reference

> Aligned design document derived from Beta's docs/future.md,
> updated to reflect ClojureWasm production implementation status.
> All wasm_rt content is preserved for future reference.

---

## SS0. Premises and Current State

- **Zig-based full-scratch Clojure reimplementation**, no Java Interop
- Single-binary distribution for native track
- Dual backend: TreeWalk (correct) + BytecodeVM (fast), with `--compare` mode
- **Current**: 795+ vars implemented, native production track (D79)
- English-only codebase (D10): identifiers, comments, commits, docs
- **Babashka-competitive performance** — beats Babashka 19/20 benchmarks (Phase 24)
- OSS-ready from day one (EPL-1.0)
- **Wasm runtime**: zwasm external dependency (D92), 461 opcodes, Register IR + ARM64 JIT

### Key metrics

| Metric           | Value                                |
|------------------|--------------------------------------|
| Vars implemented | 795+ (593/706 core, 16 namespaces)   |
| Phases completed | 1-46 + zwasm integration             |
| GC               | MarkSweepGc (D69, D70)               |
| Benchmark suite  | 31 benchmarks (20 native + 11 wasm)  |
| Backends         | VM (bytecode) + TreeWalk              |
| Wasm engine      | zwasm v1.1.0 (external dependency)    |

---

## SS1. Wasm Positioning

### Final Judgment

Wasm serves as an **AOT-optimized fast primitive execution layer**.
Dynamic semantics are retained on the Clojure side.
Architecture: fixed fast core + dynamic control layer.

### Phased Integration Plan

1. **Phase 1: Type-safe boundary** — `wasm/fn` + signature verification + multi-value return
2. **Phase 2a: WIT parse + module objects** — generate module objects from WIT definitions, ILookup for field access
3. **Phase 2b: require-wasm macro** — ns system integration (Go/No-Go after Phase 2a UX evaluation)
4. **Phase 3: Component Model** — type-safe composition of multiple modules (after WASI 1.0 stabilizes)

### Rejected Alternatives

- **A. Wasm as Clojure library** (JVM/FFI overhead negates Wasm speed) — rejected
- **B. Full Wasm-native Clojure** (NaN boxing / persistent DS incompatible with WasmGC) — rejected

### Phase Evolution Summary

| Phase | Boilerplate      | Type Safety  | WIT Required |
|-------|------------------|--------------|--------------|
| 1     | Manual signature | At call time | No           |
| 2a    | Load only        | At load time | Yes          |
| 2b    | ns declaration   | At load time | Yes          |
| 3     | Compose decl     | At compose   | Yes          |

### Code Examples

```clojure
;; Phase 1: Manual signature
(def mod (wasm/load "math.wasm"))
(def add (wasm/fn mod "add" {:params [:i32 :i32] :results [:i32]}))
(add 1 2)  ;=> 3

;; Phase 2a: WIT auto-resolution
(def img (wasm/load-wit "resize.wasm"))
(img/resize-image buf 800 600)

;; Phase 2b: ns integration (optional)
(ns my-app.core
  (:require-wasm [my:image-lib/resize :as img]))

;; Phase 3: Component composition
(def pipeline
  (wasm/compose
    (wasm/load-wit "decoder.wasm")
    (wasm/load-wit "resize.wasm")
    (wasm/load-wit "encoder.wasm")))
```

File layout: see SS17.2 `src/wasm/`.

---

## SS2. Dynamism and Wasm

Wasm itself is not dynamically rewritten (security concern). Instead:

- Clojure functions wrapping Wasm are dynamic
- Composition, replacement, and verification happen on the REPL side

**Conclusion**: Dynamism is guaranteed outside Wasm.

### Beta Lesson

Beta used `threadlocal` callback patterns (`call_fn`, `force_fn`, etc.).
The 256-slot static table was too restrictive.
Production uses closure-based registration with no slot limit.

### ClojureWasm Status (D36)

The unified `callFnVal` dispatch (D36) eliminates the need for callback
wiring entirely. All fn_val dispatch (builtin, bytecode, treewalk) goes
through a single `bootstrap.callFnVal` function. This is the foundation
for future Wasm host function registration — Clojure closures can be
registered as Wasm host functions through the same dispatch mechanism.

---

## SS3. Type/Argument Validation and Macros

Clojure's flexibility vs Wasm's strict types creates a gap.

**Approach**:

- Language spec unchanged
- Macros generate boundary code (validation, conversion, unsafe/fast path coexistence)

### Beta Lesson

Beta's Value type had 28+ variants in a tagged union. Type checking used
switch exhaustiveness for coverage, but adding a new type required updating
5 functions simultaneously (traceValue/fixupValue/deepClone/format/eql).
Missing any one caused GC crashes.

### ClojureWasm Approach

- Value variant count controlled via NaN boxing (future, deferred — D1)
- Currently using tagged union with 20+ variants
- **comptime verification for type additions**: When adding a new Value
  variant, verify that no `else => {}` catch-all exists in critical switch
  statements. This should be institutionalized as a comptime test (planned
  for T11.2).

---

## SS4. WIT / Component Model

### Recognition

- WIT is a production IDL, not just a spec document
- Unexplored territory in the Clojure ecosystem
- Wasm library ecosystem still developing

### Approach

- Represent WIT as **Clojure data** (vectors + keywords for order preservation)
- DSL in the hiccup/honeysql/malli lineage
- Bidirectional WIT <-> Clojure DSL conversion

### Implementation Strategy (aligned with SS1 Phases)

1. **Phase 1** (initial): `wasm/fn` manual binding. No WIT needed
2. **Phase 2a** (post-Alpha): WIT parser generates module objects from `.wasm`
3. **Phase 2b** (optional): `require-wasm` macro for ns integration
4. **Phase 3** (v1.0+): Component Model. After WASI 1.0 stabilization

### WIT Parser

Self-implemented in Zig (WIT grammar is relatively simple).
Fallback: wit-parser C FFI if implementation cost exceeds estimates
(native track only — C FFI not available on wasm_rt).

### WIT Type Mapping Table

| WIT Type        | Clojure Repr       | Notes                |
|-----------------|--------------------|----------------------|
| u32/i32         | int                | NaN boxing direct    |
| f32/f64         | float              | NaN boxing direct    |
| string          | string             | UTF-8 marshalling    |
| list\<T\>       | vector             | Persistent vector    |
| record { ... }  | map (keyword keys) | {:field-name value}  |
| enum { ... }    | keyword            | :variant-name        |
| variant { ... } | tagged map         | {:tag :some :val 42} |
| option\<T\>     | nil or value       | Clojure idiomatic    |
| result\<T, E\>  | {:ok v} / {:err e} | Or exception         |
| flags { ... }   | set of keywords    | #{:flag-a :flag-b}   |

---

## SS5. GC, Bytecode, and Optimization

### Current State (updated 2026-02-07)

- **GC**: MarkSweepGc (D69) — tracks allocations in HashMap, mark-sweep
  with free-pool recycling (24C.5). GcStrategy vtable for future swap.
  **Works on wasm32-wasi as-is** (GPA→WasmPageAllocator, PoC validated).
- **Bytecode**: 50+ opcodes, 3-byte fixed instructions (u8 + u16 operand)
- **Bootstrap**: Hybrid (D73) — core.clj via TreeWalk, hot functions
  recompiled to VM bytecode for reduce loops (~200x speedup).
  AOT (@embedFile) deferred (F7: macro serialization blocker).

### Beta GC Lessons (preserved for future real GC implementation)

1. **fixup exhaustiveness is lifeline**: One missed pointer fixup = use-after-free.
   Production must ban `else => {}` and use comptime tag/fixup verification.
2. **Safe point GC constraints** (F20): Zig builtin locals are not GC roots.
   Semi-space copy moves objects, leaving Zig stack pointers dangling.
   Design safe points as explicit yield points from the start.
3. **Deep clone proliferation**: scratch->persistent required deepClone
   everywhere. Revisit allocator strategy to structurally reduce copies.
4. **Generational GC limited at expression boundary**: Write barrier
   investment/return was low. Use function boundary or allocation threshold.

### 3-Layer Modular Design (F21 — future)

```
+-----------------------------------------------------+
| Layer 3: Optimization (OptimizationPass)            |
|   fused reduce, constant folding, inline caching    |
|   -> Pure transforms, independent of GC/exec        |
+-----------------------------------------------------+
| Layer 2: Execution (ExecutionEngine)                |
|   native VM / wasm_rt VM                            |
|   -> Delegates safe points to GC layer              |
+-----------------------------------------------------+
| Layer 1: Memory (MemoryManager)                     |
|   GcAllocator / WasmGC bridge                       |
|   -> Abstracted via allocator interface             |
+-----------------------------------------------------+
```

#### Layer 1: Memory Abstraction

```zig
// GcStrategy trait (implemented in ClojureWasm)
const GcStrategy = struct {
    allocFn: *const fn (self: *anyopaque, size: usize) ?[*]u8,
    collectFn: *const fn (self: *anyopaque, roots: RootSet) void,
    shouldCollectFn: *const fn (self: *anyopaque) bool,
    // ... vtable pattern
};

// native: Semi-space GC (future, currently arena stub)
// wasm_rt: WasmAllocator-based (GC delegated to runtime)
```

**comptime switching**: `build.zig` selects GcStrategy implementation
via `-Dbackend=native` or `-Dbackend=wasm_rt`.

#### Layer 2: Safe Point Design (F20)

Beta used recur-only GC checks. Production should use explicit yield points:

```zig
const YieldPoint = enum {
    recur,        // Loop tail
    call_return,  // After function call
    alloc_check,  // After N allocations
};
```

#### Layer 3: GC-Independent Optimization (F21)

Fused reduce expressed as OpCode-level optimization, not embedded in builtins:

```zig
const OpCode = enum {
    // ... existing opcodes ...
    fused_reduce_range,   // (reduce f init (range N))
    fused_reduce_map,     // (reduce f init (map g coll))
    fused_reduce_filter,  // (reduce f init (filter pred coll))
};
```

#### Route-Specific Differences

| Layer        | native                    | wasm_rt                          |
|--------------|---------------------------|----------------------------------|
| Memory       | Semi-space GC + Arena     | WasmAllocator + runtime GC       |
| Safe point   | VM yield point, self GC   | alloc threshold, runtime manages |
| NaN boxing   | Self-impl (f64 bit ops)   | Not used (Wasm i64/f64)          |
| Fused reduce | Dedicated opcode, VM exec | Same opcode, wasm_rt VM exec     |

### Hybrid Bootstrap Architecture (D18)

Current bootstrap sequence:

1. TreeWalk evaluates core.clj (defines macros, core functions)
2. User code: Reader -> Analyzer -> Compiler -> VM
3. VM calls TreeWalk closures via `callFnVal` dispatch (D36)

Full AOT (T4.7) remains the target: compile core.clj to bytecode at
build time, embed via @embedFile. Blocked by macro serialization (F7).

---

## SS6. Wasm Execution Engine Selection

### Judgment

- **zware** (used in Beta): Zig-native, lightweight, good for learning
- **Wasmtime**: Future backend option
- **WasmBackend trait**: Interface for swappable engines

### zware Constraints (from Beta)

- Multi-value return possibly unsupported
- WASI requires manual registration
- `@ptrCast` for signature matching is fragile

Production defines WasmBackend trait from the start, enabling
zware / Wasmtime / custom engine swapping.

---

## SS7. Native vs Wasm Runtime Tracks

Two tracks that do not fully converge. GC and bytecode diverge.

### native track (ultra-fast single binary)

- GC: Self-implemented (semi-space or generational)
- Optimization: NaN boxing, inline caching, fused reduce
- Distribution: Single binary, instant startup
- Use cases: CLI tools, server functions, edge computing
- **Status**: Primary track. All development targets native first.

### wasm_rt track (Wasm runtime freeride)

- Build: Compile entire runtime to .wasm via `zig build wasm`
- GC: MarkSweepGc on linear memory (same as native, GPA→WasmPageAllocator)
- Optimization: LLVM optimizations at compile time. No runtime JIT.
- Distribution: .wasm file, run on Wasmtime/WasmEdge/browsers (via WASI)
- Use cases: Portable services, Wasm-first platforms, sandboxed execution
- **Status**: Research complete (26.R). Implementation **deferred** (D79).
  WasmGC blocked by LLVM, Wasmtime cycle GC unimplemented, WASI threads unstable.

### Key Decisions

- Do not unify the two tracks
- No runtime branching — comptime switching only
- **native is the priority** — wasm_rt development begins after native stabilizes

### Zig Wasm Support (investigated, updated 26.R.6)

| Feature         | Default (generic) | ClojureWasm Use            | Status               |
|-----------------|-------------------|----------------------------|----------------------|
| bulk_memory     | Yes               | Fast memcpy/memset         | Available            |
| multivalue      | Yes               | Multi-return functions     | Available            |
| reference_types | Yes               | externref for host objects | Zig Issue #10491     |
| tail_call       | No (opt-in)       | Potential optimization     | PoC works, LLVM bugs |
| simd128         | No (opt-in)       | String/collection speedup  | Deferred             |

**Modern Wasm spec assessment** (26.R.6, Wasm 3.0):

| Feature            | Zig Usable? | Decision                               |
|--------------------|-------------|----------------------------------------|
| WasmGC             | No (LLVM)   | Permanently deferred — LLVM can't emit |
| Tail-call          | Partial     | Defer, enable when Zig/LLVM stable     |
| SIMD 128           | Yes         | Defer, optimization phase              |
| Exception Handling | No          | Not needed (Zig error unions work)     |
| Threads            | Partial     | Single-threaded MVP (WASI unstable)    |
| WASI P2/CM         | External    | WASI P1 sufficient for MVP             |

**GC implications for wasm_rt** (updated 2026-02-07 per 26.R.3):

- MarkSweepGc works on wasm32-wasi as-is (GPA→WasmPageAllocator, PoC validated)
- Free-pool recycling ideal for Wasm (memory grows only, never shrinks)
- WasmGC not usable: Zig 0.15.2 can't emit WasmGC instructions (struct.new, i31ref)
- Dynamic languages on Wasm (Python, Ruby) all use self-managed GC in linear memory
- No comptime GC switching needed for MVP — same MarkSweepGc on both tracks

---

## SS8. Architecture

### Single Repository, comptime Switching (D78)

**Updated 2026-02-07** based on compile probe (26.R.1).

```
src/
+-- main.zig          # Native entry — REPL, nREPL, wasm-interop, full CLI
+-- main_wasm.zig     # wasm_rt entry — eval-only, stdin/embedded mode
+-- root.zig          # Library root (comptime skip nrepl/wasm on wasi)
|
+-- common/           # Shared between both tracks
|   +-- reader/       # Tokenizer, Reader, Form
|   +-- analyzer/     # Analyzer, Node, macro expansion
|   +-- bytecode/     # OpCode definitions, Compiler
|   +-- builtin/      # Builtin functions (shared semantics)
|   +-- value.zig     # Value type (tagged union, shared)
|   +-- bootstrap.zig # Core loader (comptime backend guards for wasi)
|   +-- eval_engine.zig # Dual backend runner (native-only, void on wasi)
|   +-- gc.zig        # MarkSweepGc (works on both tracks via GPA)
|
+-- native/           # Ultra-fast single binary track
|   +-- vm/           # VM execution engine
|   +-- evaluator/    # TreeWalk evaluator
|
+-- repl/             # REPL + nREPL (native-only, skipped on wasi)
+-- api/              # Public embedding API
+-- wasm/             # Wasm InterOp FFI (native-only, skipped on wasi)
+-- clj/              # Clojure source (core.clj, @embedFile)
```

**Key change from original design**: No `wasm_rt/` directory with separate code
copies. Instead, common/ files use ~12 comptime branches total to handle wasi
target differences. The same native/vm/ and native/evaluator/ code is shared —
the wasm_rt backend selection (26.R.5) determines which is imported.

### Sharing Feasibility (updated)

| Layer        | Shareability | Status (26.R.1)                                   |
|--------------|--------------|---------------------------------------------------|
| Reader       | **Shared**   | Pure parser, no platform deps                     |
| Analyzer     | **Shared**   | No platform deps                                  |
| Bytecode     | **Shared**   | Compiler + opcodes are platform-free              |
| Value type   | **Shared**   | Same tagged union (wasm_module/fn = void on wasi) |
| GC           | **Shared**   | MarkSweepGc uses GPA → WasmPageAllocator on wasi  |
| Builtins     | **Shared**   | file_io works (WASI preopened dirs)               |
| Bootstrap    | Shared+guard | 2-3 comptime branches for backend import          |
| EvalEngine   | Native-only  | --compare mode not needed on wasm_rt              |
| VM           | **Shared**   | VM struct works on wasm (heap-alloc)              |
| TreeWalk     | **Shared**   | No platform deps                                  |
| nREPL        | Native-only  | std.net/Thread unavailable on WASI                |
| Wasm InterOp | Native-only  | Can't run zware inside Wasm                       |

---

## SS9. Lessons from Beta

### 9.1 Compiler-VM Contract Must Be Typed (Done)

Beta's most common bugs: mismatch between compiler emit values and VM
interpretation. capture_count, slot numbers, scope_exit arguments — implicit
contracts that break silently (wrong values, not crashes).

**ClojureWasm**: Contracts expressed in types. OpCode enum with D13
layout preserved from Beta. Chunk/FnProto types enforce structure.

### 9.2 Dual Backend --compare from Phase 2 (Done — D6)

Beta's `--compare` mode was the most effective bug-finding tool.
Production has TreeWalk + VM with EvalEngine.compare() tests (67+ tests).

**Current limitation** (D14): VM-TreeWalk closure incompatibility.
TreeWalk closures (fn_val wrapping FnNode) vs VM closures (Fn wrapping
FnProto). Hybrid bootstrap (D18) bridges this via `callFnVal` (D36).

**Bidirectional dispatch** (D34): VM->TreeWalk and TreeWalk->VM dispatch
both work. VM-compiled callbacks can be called from core.clj HOFs
(map, filter, reduce) via bytecodeCallBridge.

### 9.3 Fused Reduce Pattern (Not yet — F21)

Lazy-seq chain optimization (take -> map/filter -> source) collapsed
to single loop. Dramatic memory savings in Beta (27GB -> 2MB for map_filter).
Production will incorporate at VM opcode level when optimization pass is added.

### 9.4 Allocator Separation Principle (Done)

Env/Namespace/Var/HashMap under direct GPA management (not GC targets).
Only Clojure Values go through GcAllocator. "Infra vs user values"
lifetime separation incorporated from initial design.

### 9.5 Collection Implementation (Array-based — D9)

Currently using array-based collections (PersistentList, PersistentVector,
PersistentArrayMap, PersistentHashSet). Persistent data structures
(HAMT, RRB-Tree) deferred (F4) until profiling shows collection bottleneck.

### 9.6 Core Library Build-time AOT (Partial — D5, D18)

**Target**: core.clj -> bytecode -> @embedFile (ClojureScript-style).

**Current state**: Hybrid bootstrap (D18). core.clj loaded via read+eval
at startup (TreeWalk). ~40+ macros/functions defined in Clojure.
Full AOT blocked by F7 (macro body serialization).

**Bootstrap sequence** (working):

1. `defmacro` as special form in Zig Analyzer
2. core.clj Phase 1: `fn*` and `def` only (no destructuring)
3. core.clj Phase 2: define `defn` using `defmacro`
4. core.clj Phase 3: use `defn` for everything else

### 9.7 Cons Type for Laziness Preservation (Done — D27)

Added `Cons` value type (linked cell with first+rest) to preserve laziness
when `cons` is called with a lazy-seq rest. Without this, `consFn` would
realize the entire lazy chain eagerly.

---

## SS10. Compatibility and Verification

### The Challenge: Clojure Has No Formal Spec

Clojure's specification is the reference implementation itself. Verifying
"behavioral compatibility" requires mechanically referencing upstream behavior.

### Compatibility Levels

| Level | Verification                       | Priority | Method         |
|-------|------------------------------------|----------|----------------|
| L0    | Function/macro exists              | Required | vars.yaml      |
| L1    | Basic I/O matches                  | Required | Test oracle    |
| L2    | Edge cases / error cases match     | High     | Upstream port  |
| L3    | Lazy eval / side-effect observable | Medium   | Semantic tests |
| L4    | Error message / stacktrace format  | Low      | Not pursued    |

**Principle**: Guarantee I/O equivalence. Internal implementation details
(realize timing, etc.) are acceptable if observable results match.

### Dual Test Strategy (SCI + Clojure Upstream)

| Source         | Characteristics                 | Conversion Method                      |
|----------------|---------------------------------|----------------------------------------|
| SCI            | Low Java contamination, ~4K LOC | Tier 1 auto-convert (eval\* -> direct) |
| Clojure native | Heavy Java InterOp, ~14.3K LOC  | Read test intent, hand-port sans Java  |

- SCI: Apply automatic conversion rules -> triage non-working tests
- Clojure upstream: Read tests, create equivalent Java-free tests by hand
- Both-side testing provides bug discovery rate / coverage evidence
- Test tracking: `compat_test.yaml` (introduce at Phase 12b)

```yaml
# .dev/status/compat_test.yaml (Phase 12b)
tests:
  sci/core_test:
    test-eval:
      status: pass | fail | skip | pending
      source: sci
  clojure/core_test:
    test-assoc:
      status: pass | fail | skip | manual-port
      source: clojure
      note: "Java HashMap removed, uses PersistentArrayMap"
```

### Var Metadata Design

ClojureWasm adopts upstream Clojure metadata conventions from the start:

| Key         | Example             | Status      |
|-------------|---------------------|-------------|
| `:doc`      | "Returns a lazy..." | Implemented |
| `:arglists` | '([f coll])         | Implemented |
| `:added`    | "1.0"               | Implemented |
| `:macro`    | true                | Implemented |
| `:dynamic`  | true                | Implemented |
| `:private`  | true                | Implemented |
| `:ns`       | #<Namespace ...>    | Auto-set    |
| `:name`     | map                 | Auto-set    |

ClojureWasm-specific:

| Key         | Example | Purpose                   |
|-------------|---------|---------------------------|
| `:since-cw` | "0.1.0" | ClojureWasm version added |

**VarKind removed** (D31): The 7-value VarKind enum was only used in tests.
Layer tracking moved to `note` field in vars.yaml (free text). Upstream
Clojure classifies vars with only `:macro`, `:special-form`, and `:dynamic`.

### Protocol Dispatch (D23)

Protocols use PersistentArrayMap for dispatch. `Protocol.impls` maps
type-key strings to method maps. Keyword-as-function dispatch added
for defrecord field access.

### Metadata System (D37)

Metadata stored as `?*const Value` pointer on collections, Fn, and Atom.
Zero cost when null. `meta`, `with-meta`, `vary-meta`, `alter-meta!`,
`reset-meta!` all implemented. Var metadata deferred to T11.2
(Var as Value variant needed).

### vars.yaml Status System Review

Current status values: `todo | wip | partial | done | skip`

**Proposed refinement** (implement during Phase 12 planning):

| Status  | Meaning                                    | Use Case                          |
|---------|--------------------------------------------|-----------------------------------|
| todo    | Not implemented                            | Default                           |
| done    | Fully implemented                          | Has tests                         |
| partial | Basic behavior works, some cases missing   | e.g. reduce without fused         |
| skip    | JVM-specific, not applicable               | proxy, reify, agent, etc.         |
| stub    | Exists but minimal (error or fixed return) | e.g. _warn-on-reflection_         |
| defer   | Planned but waiting on prerequisites       | e.g. transient (needs persist DS) |

Actual vars.yaml data update deferred to Phase 12 planning.

---

## SS12. OSS and Naming

### License

EPL-1.0 (same as upstream Clojure). Initial development accepts
breaking changes (SemVer 0.x).

### Naming

Repository: **ClojureWasm**, CLI command: **`cljw`**

- Follows `cljs` (ClojureScript), `cljd` (ClojureDart) pattern
- Rename possible if community objects (redirect-capable structure)

---

## SS13. Summary

ClojureWasm aims to first perfect "Clojure as an ultra-fast single binary",
then build a structure that can **selectively leverage Wasm runtime power**.

Tracks switch via comptime, managed in a single repository.
Beta lessons ("silent bugs", "GC exhaustiveness", "implicit contracts")
are prevented at the design level in production.

---

## SS21. Deployment and Developer Experience

Discussion notes (2026-02-07). Not yet committed to roadmap.

### 21.1 Two Deployment Paths

**wasm_rt (primary differentiator)**:
Bundle user .clj + core.clj + runtime into a single .wasm file.
Deploy to Wasm edge runtimes (Cloudflare Workers, Fastly Compute, Deno Deploy, etc.).
No other Clojure implementation can target this. Unique positioning.

- Phase A: Embed .clj source in Wasm data section, read+eval at startup
- Phase B: AOT bytecode serialization (F7), embed bytecode instead (faster startup)
- Phase C: (far future) Direct Clojure→Wasm compilation

**native (secondary, Babashka-adjacent)**:
Single native binary with user code embedded via Zig `@embedFile`.
Cross-compile to any platform from any host (Zig's strength).
Speed advantage over Babashka (19/20 benchmarks), but not a frontal competitor.

- Babashka is respected — avoid positioning as a replacement
- Marketing emphasis on wasm_rt as the distinctive feature
- Native path valuable for building knowledge before wasm_rt

### 21.2 Developer Experience Gap

Current state: high-performance runtime, but no packaging or project tooling.

Missing layers (to be addressed in future phases):
- Project structure — deps.edn-like manifest (but Java libs unavailable)
- Dependency management — Wasm binary libs? Pure-clj libs from Clojars?
  Babashka and shadow-cljs both define custom EDN formats; same approach likely needed
- Build tool — `cljw build` producing .wasm or native binary
- REPL polish — nREPL foundation exists, CIDER compat needs work

### 21.3 Dependency Strategy (open questions)

- Java libraries are not usable — need alternative dependency story
- Possible: load Wasm binary libraries (compiled from Rust/Go/Zig)
  via wasm/load, exposed as Clojure namespaces
- Possible: pure Clojure libraries from Clojars (subset that avoids Java interop)
- Possible: custom registry for cljw-compatible packages
- Reference: Babashka's bb.edn, shadow-cljs's shadow-cljs.edn

### 21.4 Build Pipeline Vision

```
;; cljw.edn (future)
{:paths ["src"]
 :main my-app.core
 :target :wasm}       ;; or :native

;; cljw build → my-app.wasm (or my-app binary)
```

Packaging layer design deferred until wasm_rt (Phase 26) reveals constraints.

---

## SS14. Security Design

### 14.1 Memory Safety

Zig's ReleaseSafe mode enables bounds checking and alignment verification.

**Policy**: Release builds default to `ReleaseSafe`.
`ReleaseFast` only for explicit benchmark use.

### 14.2 Sandbox Model

**native track**: Allowlist approach (Babashka-style `--allow-*` flags)

```
cljw --allow-read=/data --allow-write=/tmp script.clj
cljw --allow-net=api.example.com script.clj
```

**wasm_rt track**: WASI capabilities (runtime manages via --dir, --env)

### 14.3 Reader Input Validation (**IMMEDIATE PRIORITY** — F19, T11.1b)

Beta had no Reader input limits. Malicious input (deep nesting, huge
literals) can cause OOM or stack overflow. With nREPL publicly accessible
(implemented in Phase 7c), this is a security-relevant concern.

| Limit                    | Default | Config Flag           |
|--------------------------|---------|-----------------------|
| Nesting depth limit      | 1024    | `--max-depth`         |
| String literal size      | 1MB     | `--max-string-size`   |
| Collection literal count | 100,000 | `--max-literal-count` |
| Source file size         | 10MB    | `--max-file-size`     |

- Limit exceeded -> clear error message (not panic)
- REPL mode uses more lenient defaults

### 14.4 Dependency Management

**Principle**: Vendor third-party libraries (source copy).
Zig's `build.zig.zon` for dependency management.
No git submodules (reproducibility).

### 14.5 SECURITY.md Policy

For OSS publication: vulnerability reporting channel, response SLA,
supported versions, security ADRs.

---

## SS15. C/Zig ABI and FFI Strategy

Three-tier extension architecture:

### 15.1 Extension Tiers

| Tier        | Target Track   | Safety | Portability | Use Case             |
|-------------|----------------|--------|-------------|----------------------|
| Wasm module | native+wasm_rt | High   | High        | Portable plugins     |
| Zig plugin  | native only    | Medium | Low         | High-perf native ext |
| C ABI       | native only    | Low    | Medium      | Existing C lib integ |

### 15.2 Wasm Module Extension

Extension of SS1's Wasm integration. Users load `.wasm` files and call
functions. API provided incrementally matching SS1 Phases 1-2b.

### 15.3 Zig Plugin Mechanism (native track)

#### 15.3.1 Build-time Integration (recommended)

```zig
// User's build.zig
const cljw = b.dependency("clojurewasm", .{});
const exe = b.addExecutable(.{
    .name = "my-clojure-app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{
            .{ .name = "clojurewasm", .module = cljw.module("api") },
        },
    }),
});
```

Benefits: Zero-cost integration (shared Value type), comptime verification,
automatic GC tracking, single binary.

#### 15.3.2 Dynamic Library (advanced)

For post-build plugin distribution. Plugin.Value is a C ABI-compatible
wrapper (conversion cost vs internal Value). Native track only.

### 15.4 C ABI Integration

Via Zig's `@cImport`: SQLite, libcurl, libpcre2, etc.

### 15.5 ClojureWasm as Library (Embedding Mode)

Embed Clojure runtime in other applications (like Lua, mruby, Wren).

**Key requirement**: VM must be instantiated (D3 — no threadlocal).
ClojureWasm was designed with this from day one. All global state has
been systematically eliminated (D36 removed 3 of 5 known exceptions).

**Remaining D3 exceptions**: `macro_eval_env`, `predicates.current_env`
(module-level, single-thread only).

```zig
// Embedding API (conceptual)
var vm = try cljw.VM.init(gpa.allocator(), .{});
defer vm.deinit();
const result = try vm.run("(+ 1 2 3)");
```

### 15.6 Extension Comparison

| Criterion   | Wasm Module    | Zig Build-time  | Zig Dynamic | C ABI       |
|-------------|----------------|-----------------|-------------|-------------|
| Portability | High           | Medium          | Low         | Low         |
| Performance | Medium         | Highest         | High        | High        |
| Safety      | High (sandbox) | High (comptime) | Medium      | Low         |
| GC integr.  | Not needed     | Automatic       | Manual      | Manual      |
| Recommended | User plugins   | Custom builds   | Late dist   | C lib reuse |

### 15.7 Staged Extension Roadmap

1. Phase 1 (initial): Wasm module loading improvements (SS1 Phase 1-3)
2. Phase 2 (~v0.3): Zig build-time integration API stabilization
3. Phase 3 (~v0.5): C ABI layer, major library bindings
4. Phase 4 (~v0.7): Embedding mode (after global state removal complete)
5. Phase 5 (~v1.0): Dynamic plugins (after stable API)

---

## SS16. Repository and Project Management

### 16.1 GitHub Organization

```
clojurewasm/
+-- clojurewasm          # Main repo (runtime + docs + examples)
+-- homebrew-tap         # macOS Homebrew Formula
```

Main repo consolidation: src, docs/, bench/ in one repo.

### 16.2 Branch Strategy: Trunk-based Development

`main` branch always releasable. Short-lived feature branches.
Releases via tags from main. SemVer for breaking changes.

### 16.3 CI/CD Pipeline (planned)

- Test matrix: ubuntu + macOS, native + wasm_rt targets
- Compat test run + status YAML diff
- Benchmark on main push
- Release: build for multiple targets on tag push

### 16.4 Release Strategy

| Phase         | Version        | Meaning                 |
|---------------|----------------|-------------------------|
| Early dev     | v0.1.0-alpha.N | API unstable            |
| Feature-round | v0.1.0-beta.N  | Stabilizing, feedback   |
| RC            | v0.1.0-rc.N    | Bug fixes only          |
| Stable        | v1.0.0         | API stable, compat guar |

---

## SS17. Directory Structure

### 17.1 Adopted from Reference Projects

| Source        | Adopted                       | Not adopted (reason)             |
|---------------|-------------------------------|----------------------------------|
| jank          | `third-party/` vendoring      | src/include split (Zig unneeded) |
| Babashka      | `docs/adr/` (ADR)             | feature-\* submodules (monorepo) |
| SCI           | `api/` and `impl/` separation | --                               |
| ClojureScript | Phase-based module separation | --                               |

### 17.2 Current Directory Tree

```
clojurewasm/
+-- .claude/                     # Claude Code
+-- .dev/                        # Development internal (git tracked)
|   +-- plan/                    # Session plans, logs, archive
|   +-- status/                  # Progress tracking (vars.yaml, bench.yaml)
|   +-- notes/                   # Technical notes, decisions
|   +-- future.md                # This file
|   +-- checklist.md             # Deferred work
|
+-- src/
|   +-- api/                     # Public embedding API
|   +-- common/                  # Shared between both tracks
|   |   +-- reader/              # Tokenizer, Reader, Form
|   |   +-- analyzer/            # Analyzer, Node, macro expansion
|   |   +-- bytecode/            # OpCode, Chunk, Compiler
|   |   +-- builtin/             # Builtin functions
|   |   +-- value.zig            # Value type
|   |   +-- eval_engine.zig      # Dual backend runner
|   |
|   +-- native/                  # Ultra-fast single binary track
|   |   +-- vm/                  # VM execution engine
|   |   +-- evaluator/           # TreeWalk evaluator
|   |   +-- gc/                  # Self GC (arena stub)
|   |   +-- optimizer/           # (stub)
|   |
|   +-- wasm_rt/                 # Wasm runtime freeride track
|   |   +-- gc/                  # GC bridge + backend
|   |   +-- vm/                  # (stub)
|   |
|   +-- repl/                    # REPL + nREPL subsystem
|   +-- wasm/                    # Wasm InterOp (both tracks)
|   +-- clj/                     # Clojure source (core.clj)
|
+-- bench/                       # Benchmark suite (11 benchmarks)
+-- docs/                        # External documentation
|   +-- adr/                     # Architecture Decision Records
+-- scripts/                     # CI, quality gate scripts
+-- build.zig                    # comptime native/wasm_rt selection
+-- flake.nix / flake.lock       # Nix toolchain
```

---

## SS18. Documentation Strategy

### 18.1 Four-Layer Structure

| Layer           | Audience     | Content                    | Format    |
|-----------------|--------------|----------------------------|-----------|
| Getting Started | New users    | Install, Hello World, REPL | README.md |
| Language Ref    | Clojure devs | Compat tables, differences | docs/     |
| Developer Guide | Contributors | Build, test, PR guide      | docs/dev/ |
| Internals       | Core devs    | VM, GC, compiler design    | docs/dev/ |

### 18.2 Markdown Documents (no mdBook)

Direct Markdown files in docs/. No build step needed.
GitHub renders directly. Migration to mdBook possible later.

### 18.3 ADR (Architecture Decision Records)

Production uses `.dev/decisions.md` for D## entries during development.
These promote to formal `docs/adr/` at release time.

### 18.4 Compatibility Status Auto-Generation (planned)

From `compat_test.yaml` -> `docs/compatibility.md`, README badges,
GitHub Pages dashboard.

---

## SS19. Roadmap

### Completed Phases (1-10)

| Phase     | Scope                      | Tasks | Status   |
|-----------|----------------------------|-------|----------|
| 1 (a-c)   | Value + Reader + Analyzer  | 12    | Complete |
| 2 (a-b)   | Runtime + Compiler + VM    | 10    | Complete |
| 3 (a-c)   | Builtins + core.clj + CLI  | 17    | Complete |
| 4 (a-f)   | VM parity + lang features  | 16    | Complete |
| 5         | Benchmark system           | 6     | Complete |
| 6 (a-c)   | Core library expansion     | 12    | Partial  |
| 7 (a-c)   | Robustness + nREPL         | 9     | Complete |
| 8         | Refactoring                | 3     | Complete |
| 9 (a-d)   | Core library expansion III | 15    | Complete |
| 9.5 (a-c) | VM fixes + data model      | 5     | Complete |
| 10 (a-c)  | VM correctness + interop   | 4     | Complete |

### Current Phase (11)

Metadata System + Core Library IV. 6 tasks planned.

### Future Phases

**Phase 12**: Zig Foundation Completion + SCI Test Port

Remaining 488 unimplemented vars fall into 4 tiers:

| Tier | Description              | Count    | Impl Language |
|------|--------------------------|----------|---------------|
| 1    | Zig-required runtime fns | ~30-40   | Zig           |
| 2    | Pure Clojure combinators | ~100-150 | core.clj      |
| 3    | JVM-specific (skip/stub) | ~150-200 | N/A           |
| 4    | Dynamic vars / config    | ~50      | Zig stubs     |

**Phase 12 structure**:

1. 12a: Tier 1 Zig builtins
2. 12b: SCI test port — run, triage failures
3. 12c: Tier 2 core.clj mass expansion
4. 12d: Tier 3 triage — mark JVM-specific in vars.yaml

**Benchmark system** (Phase 5): 11 benchmarks across 5 categories
(computation, collections, HOF, state). Compares against C, Zig, Java,
Python, Ruby, Clojure JVM, Babashka.

**nREPL** (Phase 7c): Brought forward from original Phase 7 plan.
TCP socket server with eval, load-file, describe, completions.
CIDER-compatible middleware: stdin, interrupt, *1/*2/*3/*e.

**Wasm integration** (future SS1 Phases): After native track stabilizes.

**Optimization** (future): Fused reduce (F21), NaN boxing (F1),
persistent data structures (F4), inline caching.

**OSS Release** (future): Alpha after Phase 12, stable v1.0 after
comprehensive compat testing and community feedback.

---

## SS20. Error Classification (D3b)

ClojureWasm uses Python-style error categories with two orthogonal axes:

1. **Phase** — when the error occurred (parse, analysis, macroexpand, eval)
2. **Kind** — what went wrong (12 categories)

```zig
pub const Kind = enum {
    // Parse phase
    syntax_error,     // Structural: unexpected EOF, unmatched delimiters
    number_error,     // Number literal parse failure
    string_error,     // String/char/regex literal issues

    // Analysis phase
    name_error,       // Undefined symbol, unresolved var
    arity_error,      // Wrong number of arguments
    value_error,      // Invalid binding form, duplicate key

    // Eval phase
    type_error,       // Wrong type for operation
    arithmetic_error, // Division by zero, overflow
    index_error,      // nth/get out of bounds

    // IO
    io_error,

    // System
    internal_error,   // Implementation bug
    out_of_memory,    // Allocator failure
};
```

**Rationale**: Familiar to most developers. Categories coarse enough to
stay stable, fine enough for programmatic handling (`catch SyntaxError`).

---

## Design Decisions Index

Key decisions recorded in `.dev/decisions.md`:

| ID  | Topic                           | Section |
|-----|---------------------------------|---------|
| D1  | Tagged union first, NaN later   | SS3,SS5 |
| D2  | Arena stub GC                   | SS5     |
| D3  | Instantiated VM, no threadlocal | SS15    |
| D3b | Error classification            | SS20    |
| D5  | core.clj AOT (hybrid for now)   | SS9     |
| D6  | Dual backend --compare          | SS9     |
| D9  | Array-based collections         | SS9     |
| D10 | English-only codebase           | SS0     |
| D13 | OpCode Beta-compatible layout   | SS5     |
| D18 | Hybrid bootstrap architecture   | SS5,SS9 |
| D23 | Protocol dispatch               | SS10    |
| D27 | Cons type for laziness          | SS9     |
| D31 | VarKind removal                 | SS10    |
| D34 | Bidirectional VM-TW dispatch    | SS9     |
| D36 | Unified callFnVal dispatch      | SS2,SS5 |
| D37 | Metadata system design          | SS10    |

---

## Deferred Items Quick Reference

See `.dev/checklist.md` for the canonical list. Key items:

| ID  | Item                      | Trigger                    |
|-----|---------------------------|----------------------------|
| F1  | NaN boxing                | fib(30) < 500ms target     |
| F2  | Real GC                   | Long-running REPL / memory |
| F3  | Ratio type                | SCI float precision fail   |
| F4  | Persistent data structs   | Collection benchmark       |
| F7  | Macro serialization (AOT) | T4.7 AOT bytecode startup  |
| F13 | VM opcodes for defmulti   | VM-only mode               |
| F14 | VM opcodes for lazy-seq   | VM-only mode               |
| F19 | Reader input validation   | nREPL public / ext input   |
| F20 | Safe point GC design      | Real GC (F2) start         |
| F21 | 3-layer separation        | Optimization pass intro    |
| F22 | compat_test.yaml          | SCI/upstream mass port     |
