# ClojureWasm — ROADMAP

> **Status of this document**
>
> The single authoritative plan for this project. It collapses the mission,
> principles, architecture, scope, phase plan, quality bar, and future
> decision points onto one page. The standard Claude Code rule applies:
> if anything elsewhere disagrees with this file, this file wins.
>
> Detailed implementation discussions presuppose this document. Anything
> that contradicts it must go through an ADR (`.dev/decisions/`); ad-hoc
> deviations are not allowed.
>
> Revisions are appended to §17.

---

## 0. Table of contents

1. [Mission and differentiation](#1-mission-and-differentiation)
2. [Inviolable principles](#2-inviolable-principles)
3. [Scope: what we build, what we do not](#3-scope-what-we-build-what-we-do-not)
4. [Architecture](#4-architecture)
5. [Directory layout (final form)](#5-directory-layout-final-form)
6. [Ecosystem compatibility: tier system](#6-ecosystem-compatibility-tier-system)
7. [Concurrency design](#7-concurrency-design)
8. [Wasm / edge strategy](#8-wasm--edge-strategy)
9. [Phase plan](#9-phase-plan)
10. [Performance and benchmarks](#10-performance-and-benchmarks)
11. [Test strategy](#11-test-strategy)
12. [Commit discipline and work loop](#12-commit-discipline-and-work-loop)
13. [Forbidden actions (inviolable)](#13-forbidden-actions-inviolable)
14. [Future go/no-go decision points](#14-future-gono-go-decision-points)
15. [References](#15-references)
16. [Glossary](#16-glossary)
17. [Revision history](#17-revision-history)

---

## 1. Mission and differentiation

### 1.1 Mission

**A Clojure runtime that does not depend on the JVM, with first-class edge
and Wasm support, implemented in Zig 0.16.0.**

- **No JVM**: target binary ≤ 5 MB, cold start ≤ 10 ms
- **Edge execution**: runs on Cloudflare Workers / Fastly / Fermyon Spin
  and other Wasm Component Model hosts
- **Language semantics compatible**: preserve Clojure JVM's *observable*
  behaviour. The Java interop surface (`.method`, `Class/`) is mapped onto
  v2's internal `Class` concept, not Java itself.
- **Teachable**: shrink code volume to 30–40 % of v1 (89K LOC) and document
  the design decision behind every phase.

### 1.2 Differentiation (3 axes)

| # | Axis                            | Edge over the field                                                         |
|---|---------------------------------|------------------------------------------------------------------------------|
| 1 | **Edge-native Clojure**         | Babashka is native but produces no Wasm. SCI is JS-only. v2 makes Wasm Component a first-class output. |
| 2 | **Wasm-native interop**         | `require` a Wasm module as a Clojure ns. Inversely, expose Clojure functions as WIT exports. |
| 3 | **Comprehensible runtime**      | Codebase is small enough to be read end-to-end. Each phase ships a written walkthrough. |

### 1.3 Intended users

- **Clojurians shipping to edge / serverless** who find Babashka / SCI
  short on concurrency or Wasm interop.
- **Wasm-ecosystem users** who want to call a Clojure runtime as a
  component, or distribute a Clojure DSL as a Wasm component.
- **Learners of runtime implementation** who want design decisions and
  implementation in lockstep.

---

## 2. Inviolable principles

These do not change between phases. Changing one requires an ADR.

| #  | Principle                                                                            | Effect                                                                       |
|----|--------------------------------------------------------------------------------------|------------------------------------------------------------------------------|
| P1 | **Move forward only with understanding**                                             | Interactive Claude Code use. No overnight batch commits.                     |
| P2 | **See the final shape on day 1**                                                     | Final directory layout fixed in §5. Adding a file ≠ adding a feature.        |
| P3 | **Core stays stable**                                                                | The core, once built, stops changing. Extensions go to `modules/` or pods.   |
| P4 | **No ad-hoc patches**                                                                | Solve structurally. Ad-hoc fixes are escalated to ADRs or rejected.          |
| P5 | **Modular by build**                                                                 | Only the bytes you need land in the binary (modules + comptime flags + pods). |
| P6 | **Error quality is non-negotiable**                                                  | From day 1: file/ns/line/col/source-context/colour/stack trace.              |
| P7 | **Upstream fidelity is not a constraint**                                            | Practicality first. Compatibility differences are documented via tiers.      |
| P8 | **One `cljw` binary**                                                                | Single binary serves REPL / nREPL / eval / build / wasm-component-out.       |
| P9 | **One commit = one task**                                                            | Structural change and behavioural change live in separate commits. Never commit when tests are red. |
| P10 | **Honour Zig 0.16 idioms**                                                          | `std.Io` DI, `*std.Io.Writer`, packed struct, comptime, `@branchHint`, etc.  |
| P11 | **Observable-semantics compatibility**                                               | Match what callers can observe; the inside of `.toString` is ours to choose. |
| P12 | **Dual backend from Phase 8 onward**                                                 | TreeWalk and VM agree on every test, verified by `--compare`.                |

### 2.1 Architecture principles (verifiable)

| #  | Principle                                                  | Verified by                                |
|----|------------------------------------------------------------|--------------------------------------------|
| A1 | Lower zones do not import upper zones                      | `scripts/zone_check.sh --gate` (CI)        |
| A2 | New features go via new files, not edits to existing ones  | ModuleDef + comptime flags + pods          |
| A3 | Optimisation code lives in a dedicated subtree             | `src/eval/optimize/` only                  |
| A4 | GC is an isolated subsystem                                | `runtime/gc/{arena, mark_sweep, roots}.zig` |
| A5 | Tests mirror the source layout                             | `test/` mirrors `src/`                     |
| A6 | One file ≤ 1,000 lines (soft limit)                        | Avoids the v1 `collections.zig` (6K LOC) trap |
| A7 | Concurrency and errors are designed in on day 1            | Runtime handle + threadlocal binding + SourceLocation |
| A8 | Interop is a single deep module                            | `lang/interop.zig` only; Class is a Value heap type   |
| A9 | External modules go through a single `ExternalModule` interface | comptime / .clj source / wasm pod loaded uniformly |

---

## 3. Scope: what we build, what we do not

### 3.1 In scope (will be implemented as Tier A or B)

- The bulk of `clojure.core` (~700 vars)
- `clojure.string`, `clojure.set`, `clojure.walk`, `clojure.zip`, `clojure.edn`
- `clojure.test` (deftest, is, are)
- `clojure.pprint` (basic)
- `clojure.spec.alpha` (core operators; `fdef`/`instrument` start at Tier C)
- `clojure.tools.cli`
- `clojure.java.io` equivalent (Zig-native I/O backing, same names)
- `clojure.java.shell` equivalent
- `clojure.data.json`
- Concurrency primitives: atom / agent / future / promise / delay / volatile / dynamic var
- Persistent collections: PersistentList / Vector (32-way trie + tail) / HashMap (HAMT) / HashSet
- Lazy seq + chunked seq + transducers (with fused reduce)
- Protocol / Multimethod / Record (Tier A)
- ExceptionInfo / try / catch / throw / finally
- Reader macros: `'`, `` ` ``, `~`, `~@`, `^`, `#()`, `#'`, `#"re"`, `#inst`, `#uuid`
- nREPL (CIDER-compatible, 14 ops)
- `deps.edn` resolution (basic)
- Wasm Component pod loading
- CLI (`cljw eval / repl / nrepl / build / component`)

### 3.2 Out of scope permanently (Tier D)

- **Java interop literally**: `(. obj method)` / `(.method obj)` target v2's
  internal `Class`. JVM classes such as `java.lang.String` are not provided.
- `reify`, `proxy`, `gen-class`, `definterface`, `bean`, `class?`, `supers`, `bases`
- `monitor-enter`, `monitor-exit`, `locking` (use `atom` + `Io.Mutex` instead)
- **STM (`ref` / `dosync` / `alter` / `commute`)**: atom + agent cover the
  use cases; STM implementation cost is not justified.
- AOT compilation (lein-aot equivalent)
- Dynamic Wasm generation (security and complexity)

### 3.3 Deferred (re-evaluate later)

- ClojureScript → JS compiler (v0.2.0 or later)
- RRB-Tree vector (only when vector slicing performance demands it)
- Generational GC (only after mark-sweep is stable)
- ARM64 / x86_64 JIT (gated by Phase 17 outcome)
- WasmGC backend (current line: linear memory + NaN boxing)

---

## 4. Architecture

### 4.1 Four-zone layered (absolute dependency direction)

```
Layer 3: src/app/         CLI, REPL, nREPL, deps, builder
                          ↓ may import anything below
Layer 2: src/lang/        Primitives, Interop, Bootstrap, NS Loader
                          ↓ imports runtime/ + eval/
Layer 1: src/eval/        Reader, Analyzer, Compiler, VM, TreeWalk
                          ↓ imports runtime/ only
Layer 0: src/runtime/     Value, Collections, GC, Env, Dispatch, Module
                          ↑ imports nothing above

modules/                  comptime-gated optional (math, c-ffi, wasm)
                          imports runtime/ + eval/ only
```

When a lower zone needs to call an upper zone: vtable pattern. The lower
zone declares the `VTable` type, the upper zone injects function pointers
at startup. `scripts/zone_check.sh --gate` blocks any violation in CI.

### 4.2 NaN-boxed Value representation

All values fit in `u64` (8 bytes).

| top16 band             | Kind                | Payload                              |
|-----------------------|---------------------|--------------------------------------|
| `< 0xFFF8`            | f64 raw             | —                                    |
| `0xFFF8`              | int48               | i48                                  |
| `0xFFF9`              | char21              | u21 Unicode codepoint                |
| `0xFFFA`              | const               | nil(0) / true(1) / false(2)          |
| `0xFFFB`              | builtin_fn          | 48-bit function pointer              |
| `0xFFFC` Group A      | heap (8 subtypes)   | string / symbol / keyword / list / vector / array_map / hash_map / hash_set |
| `0xFFFD` Group B      | heap                | fn_val / multi_fn / protocol / protocol_fn / var_ref / ns / delay / regex |
| `0xFFFE` Group C      | heap                | lazy_seq / cons / chunked_cons / chunk_buffer / atom / agent / ref(*) / volatile |
| `0xFFFF` Group D      | heap                | transient_vector / transient_map / transient_set / reduced / ex_info / wasm_module / wasm_fn / **class** |

(*) The `ref` slot is reserved but STM is not implemented.

Heap addresses assume 8-byte alignment, shifted right by 3 bits → fits in
48 bits.

**1:1 slot mapping** (avoiding v1's slot-sharing + discriminant): type
checks reduce to a bit comparison.

`HeapHeader` (`extern struct`):

```zig
pub const HeapHeader = extern struct {
    tag: HeapTag,    // u8
    flags: packed struct(u8) {
        marked: bool,
        frozen: bool,
        _pad: u6,
    },
};
```

### 4.3 Runtime handle + std.Io DI

**`Runtime` is a process-wide singleton**:

```zig
pub const Runtime = struct {
    io: std.Io,                  // 0.16 IO hub
    gpa: std.mem.Allocator,      // infrastructure allocator
    keywords: KeywordInterner,   // owns its mutex
    symbols: SymbolInterner,     // Phase 3+
    gc: ?*MarkSweepGc,           // Phase 5+
    interop: InterOp,            // Phase 9
    vtable: VTable,              // backend dispatch
};
```

**`VTable` is a struct (not `pub var`)** so tests can build a mock and
inject it.

**`std.Io` is DI'd through every layer** — no global variables.
`std.Io.Mutex.lock(io)` works because the caller has `rt.io` already.

**`threadlocal` is reserved for Clojure dynamic vars (`*ns*`, `*err*`,
binding frames) only**: `pub threadlocal var current_frame: ?*BindingFrame`.

### 4.4 Dual backend (TreeWalk + VM)

- **TreeWalk** (`eval/backend/tree_walk.zig`): reference implementation,
  exists from Phase 2. Simple, easy to debug.
- **VM** (`eval/backend/vm.zig`): stack machine, ~75 opcodes. From Phase 4.
- **Evaluator.compare()** (Phase 8+): runs the same expression in both and
  asserts equal results. Critical for catching silent bugs.

CLI: `cljw eval --tree-walk` switches backends; default is VM after Phase 4.

### 4.5 Interop as a single deep module + Class as Value

Interop is one deep module with a 3-entry interface:

```zig
pub const InterOp = struct {
    pub fn call(rt, target: Value, method: []const u8, args: []const Value) !Value;
    pub fn fieldGet(rt, target: Value, field: []const u8) !Value;
    pub fn isInstance(rt, class_val: Value, val: Value) bool;
};
```

**A `Class` is itself a Value** (Group D `class` slot).

- Instance method: `(.length s)` → `call(rt, "abc", "length", &.{})`
- Static: `(String/length s)` → `call(rt, classFor("String"), "length", &.{s})` (target is the Class Value)
- Field: `(.-x point)` → `fieldGet(rt, point, "x")`
- `(instance? String s)` → `isInstance(rt, classFor("String"), s)`

**Internal seams**: `ClassRegistry` maps `name → ClassDef` (methods, fields,
type_key).

**Two adapters**:
1. **PureZigClass**: methods are Zig functions (e.g. `java.io.File`,
   `clojure.lang.String` equivalents).
2. **PodClass**: method calls dispatch to a Wasm Component's `invoke`.

### 4.6 ExternalModule (one interface, three adapters)

```zig
pub const ExternalModule = struct {
    name: []const u8,
    load: *const fn(rt: *Runtime, env: *Env) anyerror!*Namespace,
    kind: enum { comptime_zig, clj_source, wasm_component_pod },
};
```

`(require '[my-lib :as l])` resolves through this single interface.

- **comptime_zig**: `modules/<name>/module.zig` (enabled by build flag)
- **clj_source**: `lang/clj/<name>.clj` via `@embedFile` + eval
- **wasm_component_pod**: `(require '[my-pod :as p :pod "my.wasm"])`
  loads a Wasm Component

### 4.7 GC subsystem

Phase 1: arena GC (bulk free).
End of Phase 5: mark-sweep GC + free-pool recycling.

```
src/runtime/gc/
├── arena.zig         Arena GC (Phase 1)
├── mark_sweep.zig    Mark-sweep + free pool (Phase 5)
└── roots.zig         Root set definition + per-type mark walk
```

- Mark bit lives in `HeapHeader.marked` (no separate hash map).
- `suppress_count: u32` blocks collection during macro expansion.
- `--gc-stress` runs collect on every allocation (test only).
- `gc.collect(rt)` takes `*Runtime` and locks via `std.Io.Mutex.lock(rt.io)`.
- Allocator vtable callbacks do NOT take the mutex (per-thread arena or
  lock-free bump).

### 4.8 Memory tiers (3 allocators)

| Tier        | Contents                                    | GC?  | Lifetime    |
|-------------|---------------------------------------------|------|-------------|
| GPA         | Env, Namespace, Var, HashMap backing        | No   | Process     |
| node_arena  | Reader Form, Analyzer Node                   | No   | Per-eval    |
| GC alloc    | Runtime Values                               | Yes  | Mark-sweep  |

Nodes are not Values, so the GC will not trace them — false-liveness is
structurally avoided.

---

## 5. Directory layout (final form)

Per **P2 (see the final shape on day 1)**, the full directory tree at the
end of all phases is fixed below. Phase 1 stubs out the directories; later
phases fill the contents without adding new directories.

```
ClojureWasm/                         (working dir on disk: ClojureWasmFromScratch/)
├── src/
│   ├── runtime/                    [Layer 0]
│   │   ├── runtime.zig             Runtime handle (io, gpa, keywords, gc, interop, vtable)
│   │   ├── value.zig               NaN-boxed Value type
│   │   ├── hash.zig                Murmur3
│   │   ├── env.zig                 Namespace, Var, dynamic binding
│   │   ├── dispatch.zig            VTable type
│   │   ├── error.zig               SourceLocation, BuiltinFn, helpers
│   │   ├── keyword.zig             KeywordInterner
│   │   ├── symbol.zig              SymbolInterner
│   │   ├── module.zig              ExternalModule interface
│   │   ├── gc/
│   │   │   ├── arena.zig
│   │   │   ├── mark_sweep.zig
│   │   │   └── roots.zig
│   │   └── collection/
│   │       ├── list.zig            PersistentList + ArrayMap
│   │       ├── hamt.zig            HAMT (HashMap, HashSet)
│   │       └── vector.zig          PersistentVector (32-way trie + tail)
│   │
│   ├── eval/                       [Layer 1]
│   │   ├── form.zig                Form + SourceLocation
│   │   ├── tokenizer.zig
│   │   ├── reader.zig
│   │   ├── node.zig                Node tagged union
│   │   ├── analyzer.zig
│   │   ├── backend/
│   │   │   ├── tree_walk.zig
│   │   │   ├── compiler.zig
│   │   │   ├── opcode.zig
│   │   │   ├── vm.zig
│   │   │   └── evaluator.zig       dual backend + compare()
│   │   ├── cache/
│   │   │   ├── serialize.zig
│   │   │   └── generate.zig        build-time cache
│   │   └── optimize/
│   │       ├── peephole.zig
│   │       ├── super_instruction.zig
│   │       ├── jit_arm64.zig       (conditional)
│   │       └── jit_x86_64.zig      (conditional)
│   │
│   ├── lang/                       [Layer 2]
│   │   ├── primitive.zig           registerAll entry
│   │   ├── primitive/              ~160 functions
│   │   │   ├── core.zig            apply, type, identical?
│   │   │   ├── seq.zig             first, rest, cons, seq, next
│   │   │   ├── coll.zig            assoc, get, count, conj
│   │   │   ├── math.zig
│   │   │   ├── string.zig
│   │   │   ├── pred.zig
│   │   │   ├── io.zig
│   │   │   ├── meta.zig
│   │   │   ├── ns.zig
│   │   │   ├── atom.zig
│   │   │   ├── protocol.zig
│   │   │   ├── error.zig
│   │   │   ├── regex.zig
│   │   │   └── lazy.zig
│   │   ├── interop.zig             InterOp deep module (§4.5)
│   │   ├── bootstrap.zig           7-stage bootstrap
│   │   ├── ns_loader.zig
│   │   ├── macro_transforms.zig    Zig-level transforms (ns, defmacro, ...)
│   │   └── clj/
│   │       ├── clojure/
│   │       │   ├── core.clj        ~600 defns (adapted from upstream)
│   │       │   ├── string.clj
│   │       │   ├── set.clj
│   │       │   ├── walk.clj
│   │       │   ├── zip.clj
│   │       │   ├── edn.clj
│   │       │   ├── test.clj
│   │       │   ├── pprint.clj
│   │       │   └── spec.clj
│   │       └── cljs/               (v0.2 onward)
│   │
│   ├── app/                        [Layer 3]
│   │   ├── cli.zig
│   │   ├── runner.zig
│   │   ├── repl/
│   │   │   ├── repl.zig
│   │   │   ├── line_editor.zig
│   │   │   ├── nrepl.zig
│   │   │   └── bencode.zig
│   │   ├── builder.zig             single binary + wasm component build
│   │   ├── deps.zig                deps.edn
│   │   └── pod.zig                 Wasm Component pod loader (Phase 14+)
│   │
│   └── main.zig                    entry point (Juicy Main)
│
├── modules/                        comptime-gated optional
│   ├── math/                       clojure.math
│   ├── c_ffi/
│   └── wasm/                       cljw.wasm namespace
│
├── test/
│   ├── run_all.sh                  unified runner
│   ├── upstream/                   upstream Clojure JVM tests (Tier A check)
│   ├── clj/                        Clojure-level tests (clojure.test)
│   └── e2e/                        CLI / error output / file exec
│
├── bench/
│   ├── bench.sh                    run / record / compare entry
│   ├── history.yaml                baseline log
│   ├── compare.yaml                cross-language snapshot
│   └── suite/NN_name/              meta.yaml + bench.clj
│
├── scripts/
│   ├── zone_check.sh
│   ├── coverage.sh                 vars.yaml coverage
│   ├── tier_check.sh               compat_tiers.yaml validation
│   └── check_learning_doc.sh       commit gate for docs/ja/
│
├── docs/
│   ├── README.md
│   └── ja/                         Japanese commit-snapshot tutorials
│       ├── README.md
│       └── NNNN-<slug>.md ...
│
├── .dev/
│   ├── README.md
│   ├── ROADMAP.md                  ← this document
│   └── decisions/                  ADRs (NNNN-<slug>.md + 0000-template.md)
│
│   (created on demand; see §15.2)
│   ├── compat_tiers.yaml           per-namespace tier (created at Phase 10)
│   ├── handover.md                 session-state memo (created when needed mid-task)
│   ├── known_issues.md             debt log (created at first issue)
│   └── status/vars.yaml            var implementation tracker (created at Phase 2.19)
│
├── .claude/
│   ├── settings.json               permissions, env, hooks
│   ├── rules/                      auto-loaded path-matched rules
│   │   ├── zone_deps.md            (loads on src/**/*.zig, build.zig)
│   │   └── zig_tips.md             (loads on src/**/*.zig, build.zig)
│   │   (compat_tiers.md is added at Phase 10 when src/lang/ starts)
│   └── skills/code-learning-doc/   skill defining the docs/ja/ workflow
│
├── build.zig
├── build.zig.zon
├── flake.nix
├── .envrc
├── .gitignore
├── README.md
└── LICENSE
```

### 5.1 File-count target

| Layer        | Target (Zig)        | Note                          |
|--------------|---------------------|-------------------------------|
| runtime/     | ~14                 |                               |
| eval/        | ~12 + 4 optimize    |                               |
| lang/        | ~21 (Zig) + ~13 .clj |                              |
| app/         | ~9                  |                               |
| modules/     | ~7 (3 module entries + bodies) |                    |
| **Zig total**| **~64**             | 47% smaller than v1 (120 files)|

---

## 6. Ecosystem compatibility: tier system

### 6.1 Tier definitions

| Tier | Meaning                                                    | Test requirement                          |
|------|------------------------------------------------------------|-------------------------------------------|
| **A** | Full semantic compatibility. Upstream tests pass as-is (or with cosmetic edits). | Upstream-ported tests **must be green**. |
| **B** | Same names and shapes; v2-native implementation. Observable behaviour matches.   | Upstream-ported tests + `;; CLJW:` annotations. |
| **C** | Best-effort with documented gaps.                                                | Limited subset only; gaps noted.                |
| **D** | Not provided. Throws `UnsupportedException`.                                     | Only the throw-message test.                    |

### 6.2 Initial tier per namespace

`.dev/compat_tiers.yaml` is the source of truth:

```yaml
clojure.core:        A   # complete by Phase 14
clojure.string:      A
clojure.set:         A
clojure.walk:        A
clojure.zip:         A
clojure.edn:         A
clojure.test:        A   # Phase 11
clojure.pprint:      B   # cosmetic differences allowed
clojure.spec.alpha:  B   # core operators only; fdef/instrument start at C
clojure.core.async:  C   # go macro becomes a thread fallback (same as Babashka)
clojure.tools.cli:   A
clojure.java.io:     B   # same names, Zig-native I/O backing
clojure.java.shell:  B
clojure.data.json:   A
java.lang.String:    D   # use Clojure string instead
java.util.Date:      B   # provided via #inst
java.io.File:        B   # via clojure.java.io
java.util.UUID:      B
java.util.regex:     A   # Tier-A-compatible custom regex engine
```

Third-party libraries live in the same yaml. Adding one requires an ADR
(see §6.3).

### 6.3 Tier-promotion / -demotion ADR rule

- **Stay at A**: upstream parity is observable, removal would hit multiple callers.
- **A → B (demotion)**: a behaviour is JVM-specific and the test needs annotation.
- **C → B (promotion)**: gap is closed. ADR with evidence.
- **D → C (promotion)**: at least one caller (test) works. ADR + partial implementation.

Each tier change is one ADR (`.dev/decisions/NNNN-promote-X.md`) recording
reason / tests / impact.

### 6.4 Ad-hoc workarounds are forbidden

**Do not write a branch in existing `.clj`/`.zig` to make a Tier-D library
work.** Instead:

1. Write an ADR to add it to the tier table (= official commitment), or
2. Implement it as a Wasm Component pod (= outside the runtime).

This prevents `if cljw then ...` branches from sprawling. Physical fence
against ad-hoc rot.

---

## 7. Concurrency design

### 7.1 Clojure reference-types ↔ Zig 0.16 std.Io mapping

| Clojure prim     | Zig 0.16 mechanism                  | File                       | Phase |
|------------------|-------------------------------------|----------------------------|-------|
| **atom**         | `std.atomic` + CAS retry            | `lang/primitive/atom.zig`  | 15    |
| **agent**        | `std.Thread.Pool` + `Io.Mutex`      | `lang/primitive/atom.zig`  | 15    |
| **future**       | `std.Io.async` + `Io.Mutex`         | `lang/primitive/atom.zig`  | 15    |
| **promise**      | `Io.Mutex` + `Io.Condition`         | `lang/primitive/atom.zig`  | 15    |
| **delay**        | `Io.Mutex` (single lock)            | `lang/primitive/lazy.zig`  | 6     |
| **volatile!**    | `@atomicLoad/Store`                  | `lang/primitive/atom.zig`  | 15    |
| **binding**      | `pub threadlocal var current_frame` | `runtime/env.zig`          | 2     |
| **core.async**   | `std.Io` fibers + channels          | `lang/primitive/async.zig` | 15 stretch |

### 7.2 No STM

`ref` / `dosync` / `alter` / `commute` are **permanently unimplemented**.
Reasons:
- LockingTransaction is expensive to get right.
- atom + agent cover ~95 % of real concurrent code.
- v1 also stopped at the skeleton.

Returns `(throw (UnsupportedException "STM not supported, use atom"))`.

### 7.3 Dynamic vars stay on threadlocal

`*ns*`, `*err*`, `*print-length*` and friends are implemented with
threadlocal binding frames. This is a Clojure-semantics requirement, not
incidental — abolishing threadlocal is not an option.

### 7.4 Backend selection

- Development / tests / default: `std.Io.Threaded` (most stable).
- Production (Linux): re-evaluate `std.Io.Evented` (io_uring) at the end of
  Phase 15 (currently experimental).
- Production (darwin): re-evaluate `std.Io.Evented` (kqueue / GCD) likewise.
- `wasm32-wasi`: dedicated backend after WASI 0.3 stabilises.

`build.zig` accepts `-Dio-backend=threaded|uring|kqueue|wasi` as a
comptime gate.

---

## 8. Wasm / edge strategy

### 8.1 Adopted: hybrid

**Two artifacts from one source tree**:
1. **Native CLI** (`cljw`): the usual binary for macOS / Linux x86_64 / aarch64.
2. **Wasm Component** (`cljw.wasm`): Component-Model conformant; exports
   `clojure.eval` and friends via WIT.

The `Runtime` struct does not depend on the backend, so both fall out of
the same `std.Io` abstraction.

### 8.2 Pod system as Wasm Component

- WIT defines: `interface clojure-pod { invoke: func(name: string, args: list<value>) -> result<value>; }`
- Load with `(require '[my-lib :as lib :pod "my.wasm"])`.
- Faster, safer, edge-compatible compared to Babashka's subprocess pods.
- Acts as the escape hatch for Tier-C/D libraries that can't be ported.

### 8.3 WIT / Component Model timeline

| Capability             | Phase       | Note                                                  |
|------------------------|-------------|--------------------------------------------------------|
| WASI 0.2 (preview2)    | Phase 14    | Component build begins. Minimal exports.               |
| Pod loader             | Phase 14-15 | `app/pod.zig`                                          |
| WIT auto-binding       | Phase 19    | adopt wit-bindgen or similar                           |
| WASI 0.3 (concurrency) | Phase 19+   | when std.Io WASI backend stabilises                    |
| WasmGC                 | v0.2+       | conflicts with NaN boxing; linear memory leads         |

---

## 9. Phase plan

Each phase has a goal and exit criteria. Phases marked 🔒 require an
**x86_64 Gate**: `zig build test` must pass on OrbStack Ubuntu x86_64
(Rosetta on Apple Silicon) before the next phase begins.

| Phase | Name                                                   | Exit criteria (summary)                                          | Gate |
|-------|--------------------------------------------------------|-------------------------------------------------------------------|------|
| 1     | Value + Reader + Error + Arena GC                      | Reads / prints `(+ 1 2)` as a Form                                | 🔒   |
| 2     | TreeWalk + Analyzer + Bootstrap Stage 0                | `(let [x 1] (+ x 2))` → 3, `((fn* [x] (+ x 1)) 41)` → 42          |      |
| 3     | defn + Bootstrap Stage 1-3 + ExceptionInfo             | `(defn f [x] (+ x 1)) (f 2)` → 3; try/catch works                 |      |
| 4     | VM + Compiler + Opcodes                                | Every TreeWalk test passes on the VM too                          | 🔒   |
| 5     | Collections (HAMT, Vector) + Mark-Sweep GC             | `(get {:a 1} :a)` → 1; large collections do not OOM               | 🔒   |
| 6     | LazySeq + concat + higher-order foundations            | `(take 5 (iterate inc 0))` → (0 1 2 3 4)                          |      |
| 7     | map / filter / reduce / range + transducers base       | Fused reduce produces zero intermediate seqs (target: v1's 391x)  |      |
| 8     | Evaluator.compare() + dual-backend verify              | Every test agrees on TreeWalk and VM. `bench/history.yaml` initialised. | 🔒 |
| 9     | Protocols + Multimethods + Interop deep module         | defprotocol / defmulti work; single Interop module complete       |      |
| 10    | Namespaces + require + standard libraries (Tier A)     | clojure.string / clojure.set etc. tests are green                 |      |
| 11    | clojure.test framework + start porting upstream tests  | deftest / is / are work; 10+ upstream tests ported                |      |
| 12    | Bytecode cache (serialize + cache_gen)                 | Cold start `< 12 ms`; cache format versioning established         |      |
| 13    | VM optimisation: peephole.zig                          | Five canonical benchmarks within 110 % of v1 24C.10               |      |
| 14    | CLI + REPL + nREPL + deps.edn + Wasm Component build + **v0.1.0** | `cljw repl`, `cljw nrepl`, `cljw component build` all work; compat_tiers.yaml complete | 🔒 |
| 15    | Concurrency (atom, agent, future, promise, pmap)       | `core.async` Tier-C stub; `(future ...)` deref works              | 🔒   |
| 16    | ClojureScript → JS compiler                            | (v0.2.0 milestone)                                                |      |
| 17    | VM optimisation: super_instruction.zig                 | Five canonical benchmarks within 100 % of v1 24C.10               |      |
| 18    | Module system + math + C FFI                           | `zig build -Dmath=true` etc. comptime-gated                       |      |
| 19    | module: Wasm FFI (zwasm import) + WIT auto-binding     | `(wasm/component "x.wasm")` → bindgen → Clojure ns                |      |
| 20    | module: JIT ARM64 / x86_64                             | **Gated by Phase 17 outcome**. Decide before starting.            |      |

### 9.1 Phase 14 = v0.1.0 milestone

Phase 14 = first publishable v0.1.0. **Minimum line for a Conj talk.**
- CLI / REPL / nREPL working
- compat_tiers.yaml has Tier A/B declarations done
- Wasm Component output supported (even if minimal)
- bench/history.yaml has a locked baseline

### 9.2 v0.2.0 onward

- Phase 15-16 (Concurrency + CLJS): v0.2.0
- Phase 17-19 (super_instruction + module + advanced Wasm): v0.3.0
- Phase 20 (JIT): v0.4.0 or skipped

---

## 10. Performance and benchmarks

### 10.1 Lock baseline at Phase 8

`bench/history.yaml` records before/after for every optimisation.
**1.2x regression on a single bench = STOP.**

### 10.2 Mid-phase quick bench (4-7)

Before the full Phase-8 harness, a `bench/quick.sh` covering 5–6 microbenchmarks
goes in just before Phase 4. Used during Phases 4-7.

### 10.3 v0.1.0 targets

| Bench                | v0.1.0 target | Stretch  |
|----------------------|---------------|----------|
| Cold start           | < 12 ms       | < 8 ms   |
| Warm start           | < 4 ms        | < 2 ms   |
| Binary size          | < 3.5 MB      | < 2 MB   |
| fib_recursive        | 24 ms         | 18 ms    |
| map_filter_reduce    | 17 ms         | 10 ms    |
| transduce            | 16 ms         | 10 ms    |
| lazy_chain           | 16 ms         | 10 ms    |
| Idle memory          | < 25 MB       | < 15 MB  |
| Wasm cold start      | < 50 ms       | < 20 ms  |

### 10.4 Fused reduce via structural metadata

Required by Phase 7. `LazySeq` carries `meta: ?*const SeqMeta`
(`.lazy_map | .lazy_filter | .lazy_take | .range`). At reduce time, the op
chain is walked and the base source (range, vector) is iterated directly,
producing zero intermediate lazy seqs. This is the mechanism that won v1's
391x on `lazy_chain`.

---

## 11. Test strategy

### 11.1 TDD (t-wada style)

1. **Red**: write one failing test first.
2. **Green**: minimal code to pass.
3. **Refactor**: improve while green.

### 11.2 Three test layers

| Layer            | Contents                              | Files                |
|------------------|---------------------------------------|----------------------|
| Zig unit         | `test "..." { ... }` blocks           | each `src/**/*.zig`  |
| Clojure deftest  | `clojure.test` (Phase 11+)            | `test/clj/**/*.clj`  |
| E2E              | CLI round-trips                       | `test/e2e/*.sh`      |
| Upstream port    | Adapted Clojure JVM tests             | `test/upstream/**`   |

`test/run_all.sh` is the unified runner. Phase 1 = Zig unit only → Phase 11+ adds the rest.

### 11.3 Dual-backend compare (Phase 8+)

From Phase 8, every deftest runs on both VM and TreeWalk and asserts
equality. **Any divergence → identify the root cause** (decide which is
correct; fix the other).

### 11.4 Upstream-test porting rules (Tier A check)

- The first line of each ported file: `;; CLJW: Tier A from <upstream path>`.
- For a Tier-B difference, mark with `;; CLJW: <reason>` per-test.
- **NEVER work around a failing test.** The choice is implement-the-feature
  or write-a-tier-demotion-ADR. Commenting out / `:skip` alone is forbidden.

### 11.5 Cross-platform gate

Phases marked 🔒 (x86_64 Gate): `zig build test` must pass on OrbStack Ubuntu
x86_64 (Rosetta on Apple Silicon) before moving on. NaN boxing, HAMT, GC,
VM dispatch, and packed-struct alignment are all arch-sensitive.

### 11.6 Quality gate timeline (active + future)

A single table of every quality gate this project will need. **Active** gates
must pass before commit / push at the listed scope. **Planned** gates have a
"prepare-by" phase: the gate file/script is added by that phase even if it
is no-op until the relevant feature exists. Listing them here prevents
forgetting them.

| # | Gate                                            | Scope (when it must pass)        | Wired as                                        | Status (this commit)              | Prepare by    |
|---|--------------------------------------------------|----------------------------------|-------------------------------------------------|------------------------------------|--------------|
| 1 | Learning-doc gate: source-commit → doc-commit pairing | the commit *after* every source-bearing commit | `scripts/check_learning_doc.sh` PreToolUse hook | **Active**                          | —            |
| 2 | Zone-dependency check (`zone_check.sh --gate`)   | every commit touching src/ or modules/ | `scripts/zone_check.sh` (runs from `test/run_all.sh` later; manual now) | **Active** (informational; 0 violations on empty src/) | Phase 2.20 wires --gate as PreToolUse |
| 3 | `zig build test` green                            | every commit                     | `test/run_all.sh` then `bash test/run_all.sh` | **Active**                          | —            |
| 4 | `zig fmt --check src/`                            | every commit touching src/       | `scripts/format_check.sh` (TODO)                | **Planned**                         | Phase 1 (when src/ grows beyond bootstrap) |
| 5 | x86_64 cross-arch test (OrbStack Ubuntu)          | end of phases marked 🔒          | manual: `orb run ... bash -lc "zig build test"` | **Planned** (no VM yet)             | Phase 1.12   |
| 6 | Dual-backend `--compare` (TreeWalk == VM)         | every test, Phase 8+             | inline in test runner                            | **Planned**                         | Phase 8      |
| 7 | Bench regression ≤ 1.2x                           | every optimisation commit        | `bench/bench.sh record` + history.yaml diff      | **Planned**                         | Phase 8 (full); Phase 4 quick harness |
| 8 | Tier-A upstream test green                        | every commit touching `src/lang/clj/` or related Zig | inline in `test/run_all.sh`     | **Planned**                         | Phase 11     |
| 9 | Tier-change ADR present                           | any change to `compat_tiers.yaml`| `scripts/tier_check.sh` (TODO)                  | **Planned**                         | Phase 9      |
|10 | `compat_tiers.yaml` complete (all listed namespaces have impl) | v0.1.0 release | `scripts/tier_check.sh` (TODO)                  | **Planned**                         | Phase 14     |
|11 | GC root coverage (every heap type traced)        | end of Phase 5                   | unit tests + `--gc-stress`                       | **Planned**                         | Phase 5      |
|12 | Bytecode cache versioning                         | every cache format change        | inline cache header + version field              | **Planned**                         | Phase 12     |
|13 | JIT go/no-go ADR                                  | end of Phase 17                  | `.dev/decisions/NNNN-jit-decision.md`            | **Planned**                         | Phase 17 end |
|14 | Wasm Component build green (`zig build -Dcomponent`) | every commit touching wasm bits | `test/run_all.sh` extension                      | **Planned**                         | Phase 14     |
|15 | WIT auto-binding correctness                      | every commit to wit bindgen path | inline test                                       | **Planned**                         | Phase 19     |
|16 | nREPL operation parity (CIDER 14 ops)             | every commit touching `app/repl/nrepl.zig` | inline test                              | **Planned**                         | Phase 14     |

Each "Planned" row will move to "Active" by its prepare-by phase. Add the
row to `test/run_all.sh` (or wire as a hook in `.claude/settings.json`)
when activating; do not leave the table out of sync with reality.

---

## 12. Commit discipline and work loop

### 12.1 One task = one commit

- Structural changes (rename / move / split) and behavioural changes go in
  separate commits.
- Never commit when tests are red.
- Never bypass the pre-commit hook with `--no-verify` — fix the issue.

### 12.2 Commit pairing: source commit → doc commit

Every source-bearing commit (`src/**/*.zig`, `build.zig`, `build.zig.zon`,
`.dev/decisions/*.md`) is **immediately followed** by a separate commit that
adds the paired `docs/ja/NNNN-<slug>.md`. The pair is the atomic unit of
progress.

```
commit N      feat(scope): ...        # source only
commit N+1    docs(ja): NNNN — ...    # docs/ja/NNNN-*.md only
```

Writing the doc as the *next* commit lets its `commit:` front-matter field
reference the source commit's actual SHA — no "TBD then patch" cycle.

- **Skill / template**: `.claude/skills/code-learning-doc/SKILL.md`
- **Gate**: `scripts/check_learning_doc.sh` (Claude Code PreToolUse hook on `Bash`)
  - Rule 1: a doc commit must not contain source.
  - Rule 2: a commit following an unpaired source commit must be the doc.

The doc is Japanese, captures a code snapshot at that commit, the why, and
takeaways — material for a future technical book and talks.

### 12.3 Message format

```
<type>(<scope>): <one-line summary>

<optional body explaining WHY (not WHAT)>
```

`<type>`: `feat | fix | refactor | docs | chore | test | bench`
`<scope>`: `runtime | eval | lang | app | build | tests | bench | dev`

Example:

```
feat(eval): add tree_walk evaluator for Phase 2

Direct AST evaluation via Node tagged-union dispatch. Special forms
(def, if, do, fn*, let*, loop*, recur) handled inline; function calls
go through rt.vtable.callFn.
```

### 12.4 Iteration loop

For every task:

1. **Orient**: read `.dev/handover.md`. Confirm phase in `.dev/ROADMAP.md`.
2. **Plan**: pick the next task. Update the handover note.
3. **Execute (TDD)**: red → green → refactor. `bash test/run_all.sh` must be green.
4. **Document**: write `docs/ja/NNNN-<slug>.md` (mandatory for source-touching commits, see §12.2).
5. **Commit**: one task, one commit. Update handover and any ADR.
6. **Push (after approval)**: pushing to the long-lived `cw-from-scratch`
   branch requires explicit user approval.

---

## 13. Forbidden actions (inviolable)

If `.claude/CLAUDE.md` and this file conflict, this file wins.

- ❌ Branching code in existing `.clj`/`.zig` for a Tier-D library (§6.4)
- ❌ Ad-hoc workarounds to make a test pass (§11.4)
- ❌ Committing with `--no-verify`
- ❌ `git push --force` to `cw-from-scratch`
- ❌ `git reset --hard` to throw away commits
- ❌ Implementing STM (§3.2 / §7.2)
- ❌ Providing JVM classes themselves (e.g. `java.lang.String`) (§3.2)
- ❌ Using `std.Thread.Mutex` (removed in 0.16; use `std.Io.Mutex`)
- ❌ Using `std.io.AnyWriter` / `std.io.fixedBufferStream` (removed in 0.16)
- ❌ Using `pub var` as a vtable (use struct `VTable` + Runtime field)
- ❌ Letting any single file drift past 1,000 lines indefinitely
- ❌ Running with only one backend after Phase 8
- ❌ Pushing to remote without user approval
- ❌ Committing source changes without the corresponding `docs/ja/NNNN-*.md` (§12.2)

---

## 14. Future go/no-go decision points

### 14.1 End of Phase 17: do we implement JIT (Phase 20)?

Criteria:
- v0.1.0 benches (Phase 14) within 110 % of v1 24C.10 → **JIT not needed**
  (transducer + super_instruction were enough).
- Otherwise → **consider JIT** (start with ARM64; x86_64 is a stretch).

Decision recorded as a go/no-go ADR in `.dev/decisions/` at end of Phase 17.

### 14.2 End of Phase 15: switch production to std.Io.Evented?

Criteria:
- The `experimental` label is gone in Zig 0.16.x.
- Real benches show a clear win over Threaded.
- Stability is acceptable.

### 14.3 During v0.2: adopt WasmGC backend?

Criteria:
- WasmGC is stable in major runtimes (wasmtime / wasmer / V8).
- Benchmarks justify it over linear memory + NaN boxing.
- Binary size benefit.

Decision recorded before starting v0.2.0.

### 14.4 During v0.2: actually do ClojureScript → JS (Phase 16)?

Porting cljs.analyzer + cljs.compiler is large. If yes, dedicate v0.2 to it.

---

## 15. References

### 15.1 Internal (committed; load-bearing)

The minimum surface that must always exist:

- `CLAUDE.md` — Claude Code project memory (short, points to this file)
- `README.md` — public-facing description
- `LICENSE` — EPL-2.0
- `.dev/ROADMAP.md` (this file) — single source of truth
- `.dev/README.md` — index / convention pointer
- `.dev/decisions/{README.md, 0000-template.md}` — ADR infrastructure
- `.claude/settings.json` — permissions / hooks
- `.claude/rules/zone_deps.md` — auto-loaded layering rules
- `.claude/rules/zig_tips.md` — auto-loaded Zig 0.16 idioms
- `.claude/skills/code-learning-doc/SKILL.md` — doc-pairing skill
- `scripts/check_learning_doc.sh` — pairing gate (PreToolUse hook)
- `scripts/zone_check.sh` — zone checker (info / --strict / --gate)
- `test/run_all.sh` — unified test runner
- `docs/ja/` + `docs/ja/README.md` + `docs/ja/NNNN-*.md` — learning docs
- `build.zig`, `build.zig.zon`, `flake.nix`, `.envrc`, `.gitignore`
- `src/main.zig` and the rest of `src/`

### 15.2 Files created on demand (do not pre-create as empty stubs)

Empty files rot. These are created the moment they have real content,
using the templates below.

#### `.dev/handover.md` — when a session ends mid-task and the next session needs context that `git log` + ROADMAP cannot convey

```markdown
# Session handover
- Phase:       <Phase N — name>
- Last commit: <SHA — title>
- In-progress: <what is half-done>
- Next step:   <single concrete next move>
- Open Qs:     <one-liners only>
```

#### `.dev/known_issues.md` — when the first long-lived issue surfaces

```markdown
# Known issues & technical debt
## P0 — User-facing bugs        (none)
## P1 — Development infrastructure  (none)
## P2 — Correctness gaps         (none)
## P3 — Design debt
- **<title>** (<file:line>) — what is wrong, why we live with it now, trigger to fix
```

#### `.dev/compat_tiers.yaml` — when the first `src/lang/clj/<ns>.clj` lands (≈ Phase 10)

```yaml
clojure.core:           { tier: A, phase: 14 }
clojure.string:         { tier: A, phase: 10 }
# ... one line per namespace; java.* default to D
```

When this file appears, also create `.claude/rules/compat_tiers.md`
(auto-loaded for `src/lang/**` and the yaml itself) — content lives in
ROADMAP §6 / §13.

#### `.dev/status/vars.yaml` — when Phase 2's var-tracking script lands (Phase 2.19)

Per-var status: `{type: function|macro|special|var, status: todo|wip|done|skip, note: ...}`.
Generator: `.dev/scripts/generate_vars_yaml.clj`.

### 15.2 Local reference clones (already present)

| Path                                                           | Purpose                                       |
|----------------------------------------------------------------|------------------------------------------------|
| `~/Documents/MyProducts/ClojureWasm/`                          | ClojureWasm v1 (89K LOC, v0.5.0). Design reference. |
| `~/Documents/MyProducts/ClojureWasmFromScratch_v1_ref/`        | Previous redesign attempt (Phase 1+2). Implementation reference for Runtime handle, NaN boxing, Reader. |
| `~/Documents/OSS/clojure/`                                     | Upstream Clojure JVM. core.clj / LispReader.java / Numbers.java. |
| `~/Documents/OSS/babashka/`                                    | Babashka (SCI-based). Pod / native / compatibility precedent. |
| `~/Documents/OSS/spec.alpha/`                                  | clojure.spec.alpha source.                     |
| `~/Documents/OSS/zig/`                                         | Zig stdlib source.                             |
| `~/Documents/OSS/wasmtime/`                                    | Wasm runtime reference.                        |
| `~/Documents/OSS/malli/`                                       | Spec alternative.                              |
| `~/Documents/OSS/mattpocock_skills/improve-codebase-architecture/` | Module/Interface/Depth vocabulary and deepening principles. |

### 15.3 Official docs (web)

- Zig 0.16.0 release notes: https://ziglang.org/download/0.16.0/release-notes.html
- Clojure: https://clojure.org/reference
- WebAssembly Component Model: https://component-model.bytecodealliance.org/
- WASI: https://wasi.dev/
- Babashka pods: https://github.com/babashka/pods

---

## 16. Glossary

Architecture vocabulary follows mattpocock's definitions:

| Term              | Meaning                                                                  |
|-------------------|--------------------------------------------------------------------------|
| **Module**        | Anything with an interface and an implementation (function / struct / package / slice). |
| **Interface**     | Everything a caller must know (types, invariants, ordering, error modes, performance). |
| **Implementation**| The body of a module.                                                    |
| **Depth**         | Leverage at the interface. **Deep** = much behaviour behind a small interface. |
| **Seam**          | Where an interface lives (place behaviour can be altered without editing in place — Michael Feathers). |
| **Adapter**       | A concrete thing satisfying an interface at a seam.                       |
| **Leverage**      | What callers get from depth.                                             |
| **Locality**      | What maintainers get from depth (changes / knowledge concentrate in one place). |

Project-specific:

| Term                | Meaning                                                                   |
|---------------------|---------------------------------------------------------------------------|
| **NaN Boxing**      | Encoding all values in 8 bytes by hiding tags inside IEEE-754 NaN space.  |
| **Tier**            | Per-namespace Clojure compatibility level (A/B/C/D).                      |
| **Pod**             | An external Clojure library implemented as a Wasm Component.              |
| **InterOp**         | The dot/static/field/instance? surface, expressed via Class-as-Value.      |
| **Dual backend**    | TreeWalk (reference) and VM (production) running side by side under `--compare`. |
| **Fused Reduce**    | Walking the structural metadata chain on LazySeq directly, avoiding intermediate seq materialisation. |
| **Bootstrap stage** | How far core.clj is evaluated by TreeWalk before the VM takes over (Stage 0–6). |
| **x86_64 Gate**     | A phase-completion gate: `zig build test` on OrbStack Ubuntu x86_64.       |
| **Juicy Main**      | `pub fn main(init: std.process.Init)` (a Zig 0.16 idiom).                 |
| **Learning doc**    | `docs/ja/NNNN-<slug>.md`, the Japanese commit snapshot required by §12.2. |

---

## 17. Revision history

| Date       | Change                                                                                           |
|------------|--------------------------------------------------------------------------------------------------|
| 2026-04-27 | Initial version. Synthesised from ClojureWasm v1, prior redesign attempt, Clojure, Babashka, Wasm 2026, mattpocock's vocabulary, and the strategic review. |
| 2026-04-27 | Translated to English. Added §12.2 (commit-snapshot learning doc gate) and added `docs/ja/` to §5 / §15. |
| 2026-04-27 | Audit pass: added §11.6 (Quality gate timeline, active + future). Added `.claude/rules/`, `.dev/{decisions,compat_tiers.yaml,handover.md,known_issues.md,concurrency_design.md,wasm_strategy.md}`, `scripts/zone_check.sh`, `test/run_all.sh` to §5 / §15. Removed `.editorconfig` (Emacs handles formatting; format gate listed as #4 in §11.6 pending). |
| 2026-04-27 | Self-review + simplification: removed 7 high-rot-risk files (`.dev/handover.md`, `.dev/known_issues.md`, `.dev/compat_tiers.yaml`, `.dev/concurrency_design.md`, `.dev/wasm_strategy.md`, `.claude/rules/compat_tiers.md`, `docs/README.md`) and listed them in new §15.2 "create on demand". Reworked §12.2 / gate (#1) to "source commit → doc commit pairing": doc is the next commit, not the same commit; gate enforces both rules; SHA in doc front matter is the actual previous-commit SHA, no TBD/patch cycle. Patched 0001/0002 SHAs accordingly. |
