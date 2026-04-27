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
> History lives in git — see `git log -- .dev/ROADMAP.md` for diffs,
> `docs/ja/NNNN-*.md` for the story behind each change, and
> `.dev/decisions/` for load-bearing decisions.

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
│   │   ├── macro_dispatch.zig      Layer-1 macro Table + dispatch type
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

### 9.3 Phase 1 — task list (expanded; this is the active phase)

> Convention: each `[ ]` becomes one or more source commits, eventually
> followed by a `docs/ja/NNNN-<slug>.md`. Mark complete with `[x]` when
> the doc commit lands. Commit SHAs are listed alongside for traceability.
>
> When Phase 2 starts, expand it inline below in §9.4 and apply the same
> convention. Do not pre-expand future phases.

**Goal**: Read Clojure source text, produce a Form AST. NaN-boxed Value
type, error infrastructure with `SourceLocation`, and an Arena GC are all
in place from day 1.

**Exit criterion**: `cljw -e "(+ 1 2)"` reads, parses, prints back as `(+ 1 2)`.

| Task | Description                                                                | Status     |
|------|----------------------------------------------------------------------------|------------|
| 1.0  | Build skeleton + flake.nix + main.zig prints "ClojureWasm"                 | [x] (`116b874`) |
| 1.1  | `src/runtime/value.zig` — NaN boxing Value type, HeapTag (32 slots), HeapHeader | [x] (`8b487f9`) |
| 1.2  | `src/runtime/error.zig` — SourceLocation, BuiltinFn signature, expect* / checkArity helpers, threadlocal last_error / call_stack | [x] (`61ccbf8`) |
| 1.3  | `src/runtime/gc/arena.zig` — Arena GC interface, suppress_count, --gc-stress prep | [x] (`c22f900`) |
| 1.4  | `src/runtime/collection/list.zig` — PersistentList (cons cell only)        | [x] (`902e22d`) |
| 1.5  | `src/runtime/hash.zig` — Murmur3 (Clojure-compatible hash values)          | [x] (`1825f24`) |
| 1.6  | `src/runtime/keyword.zig` — Keyword interning (single-thread Phase-1 stub; rt-aware in Phase 2.0) | [x] (`b60924b`) |
| 1.7  | `src/eval/form.zig` — Form tagged union with SourceLocation                | [x] (`6a09869`) |
| 1.8  | `src/eval/tokenizer.zig` — Lexer (text → token stream); SourceLocation per token | [x] (`615fd46`) |
| 1.9  | `src/eval/reader.zig` — Parser (token stream → Form); Phase-1 reader scope (no syntax-quote yet) | [x] (`b6efa7f`) |
| 1.10 | `src/main.zig` — minimal CLI with `-e` flag; reads + prints (no eval yet)   | [x] (`eead562`) |
| 1.11 | `bench/quick.sh` — 5–6 microbenchmarks (fib, arith_loop, list_build, etc.); first sample run recorded | [x] (`04476ac`) |
| 1.12 | 🔒 x86_64 Gate — OrbStack Ubuntu x86_64; `zig build test` green             | [x] (94/94 on `my-ubuntu-amd64`) |

After 1.12 is checked, the Phase Tracker (§9 table top) flips Phase 1
from PENDING to DONE and Phase 2 IN-PROGRESS; expand Phase 2 in §9.4.

### 9.4 Phase 2 — task list (expanded; this is the active phase)

> Same convention as §9.3: each `[ ]` becomes one or more source
> commits, eventually followed by a `docs/ja/00NN-*.md`. Mark complete
> with `[x]` and the SHA when the doc lands.

**Goal**: Wire the Runtime handle, the analyzer, and the TreeWalk
backend so that the Phase-1 read–print loop becomes a real
read–analyse–eval–print loop. Bootstrap Stage 0 = primitives in `rt/`
namespace + `(refer 'rt)` into `user/` (no `.clj` source yet).

**Exit criterion** (verified end-to-end via `cljw -e`):

  `(let [x 1] (+ x 2))` → `3`
  `((fn* [x] (+ x 1)) 41)` → `42`

| Task | Description                                                                                                                                                                                                                                                                                                                                                  | Status          |
|------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------|
| 2.1  | `runtime/dispatch.zig` + `runtime/runtime.zig` + `runtime/env.zig` skeletons — all three files land together because `dispatch.VTable` references `*Runtime` and `*Env`, so the import graph only compiles when all three exist. Phase 2.1 leaves Env at the minimum needed for dispatch tests to compile; namespaces / vars / binding frames arrive in 2.3. | [x] (`91feef0`) |
| 2.2  | `src/runtime/keyword.zig` — promote to rt-aware (`*Runtime` API + `std.Io.Mutex`)                                                                                                                                                                                                                                                                            | [x] (`07d5c34`) |
| 2.3  | `src/runtime/env.zig` — flesh out `Namespace`, `Var`, threadlocal `current_frame` binding stack                                                                                                                                                                                                                                                              | [x] (`e20acaa`) |
| 2.4  | `src/eval/node.zig` — `Node` tagged union (analysed AST: const / local-ref / var-ref / if / do / let / fn / invoke / quote)                                                                                                                                                                                                                                  | [x] (`e04c290`) |
| 2.5  | `src/eval/analyzer.zig` — `Form → Node` + Phase-2 special forms (`quote`, `if`, `do`, `let*`, `fn*`, `def`)                                                                                                                                                                                                                                                  | [x] (`bb1459c`) |
| 2.6  | `src/eval/backend/tree_walk.zig` — `Node → Value` tree-walk interpreter; `installVTable`                                                                                                                                                                                                                                                                     | [x] (`de2cb64`) |
| 2.7  | `src/lang/primitive.zig` — `registerAll(env)` into the `rt/` namespace; `(refer 'rt)` into `user/`                                                                                                                                                                                                                                                           | [x] (`04e84bf`) |
| 2.8  | `src/lang/primitive/math.zig` — `+`, `-`, `*`, `=`, `<`, `>`, `<=`, `>=`                                                                                                                                                                                                                                                                                     | [x] (`f81f97a`) |
| 2.9  | `src/lang/primitive/core.zig` — `nil?`, `true?`, `false?`, `identical?`                                                                                                                                                                                                                                                                                      | [x] (`8d0c677`) |
| 2.10 | `src/main.zig` — wire CLI through analyser + TreeWalk; `cljw -e "(+ 1 2)"` → `3`                                                                                                                                                                                                                                                                             | [x] (`8d32c83`) |
| 2.11 | Phase-2 exit smoke: `(let [x 1] (+ x 2))` → `3` and `((fn* [x] (+ x 1)) 41)` → `42`                                                                                                                                                                                                                                                                          | [x] (`7d9fe5f`) |

After 2.11 lands as a `[x]`, the §9 phase tracker flips Phase 2 from
PENDING to DONE and Phase 3 IN-PROGRESS; expand Phase 3 inline in §9.5.

### 9.5 Phase 3 — task list (expanded; this is the active phase)

> Same convention as §9.3 / §9.4: each `[ ]` becomes one or more
> source commits, eventually followed by a `docs/ja/00NN-*.md`.

**Goal**: turn the Phase-2 minimum interpreter into a Clojure that
can `(defn ...)` and `(try ... (catch ...))`. Bootstrap Stage 1
loads a Clojure-level prologue (basic macros / helpers) so users
can write `(let [x 1] ...)` and `(when c ...)` directly instead of
the special-form-only Phase-2 surface.

**Exit criterion** (verified end-to-end via `cljw -e`):

  `(defn f [x] (+ x 1)) (f 2)` → `3`
  `(try (throw (ex-info "boom" {})) (catch ExceptionInfo e (ex-message e)))` → `"boom"`

> Tasks 3.1–3.4 land **first** because they activate principle P6
> ("Error quality is non-negotiable"): the runtime/error.zig
> infrastructure (SourceLocation / Kind / Phase / threadlocal
> last_error / setErrorFmt) was put in place at Phase 1.2 but the
> Reader / Analyzer / TreeWalk error sites still discard the
> location and the CLI just prints `@errorName(err)`. Wiring P6
> end-to-end before stacking `defn` / `try` / `catch` on top means
> debugging Phase 3 itself becomes tractable. CLI ergonomics
> (file / stdin execution) ride alongside 3.1 because `-e` strings
> hit zsh history expansion (`!`), `$`, backticks etc., and
> heredoc / file invocation is the safer path for tests and skills.

| Task | Description                                                                                                                                                                                                                                                                       | Status |
|------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------|
| 3.1  | `src/runtime/error_print.zig` — `formatErrorWithContext(info, source, w)` renders `<file>:<line>:<col>: <kind> [<phase>]\n  <source line>\n  <caret>\n  <message>` with optional ANSI; **also extends `src/main.zig` with `cljw <file.clj>` and `cljw -` (stdin / heredoc)** — `-e` is preserved but no longer the only safe path; `main.zig` switches its catch sites to `formatErrorWithContext` | [x] (`37f0c8f`) |
| 3.2  | `src/eval/reader.zig` — replace direct `error.SyntaxError` / `error.NumberError` / `error.StringError` returns with `setErrorFmt(.parse, kind, tok-derived loc, fmt, args)`; existing tests still pass because the public error tags are unchanged                                | [x] (`8c750b5`) |
| 3.3  | `src/eval/analyzer.zig` — replace `AnalyzeError.SyntaxError` / `NameError` / `NotImplemented` returns with `setErrorFmt(.analysis, kind, form.location, ...)`; symbol resolution failures cite the offending symbol's location                                                    | [x] (`5eb3fc7`) |
| 3.4  | `src/eval/backend/tree_walk.zig` — replace `EvalError.NotCallable` / `ArityMismatch` / `SlotOutOfRange` returns with `setErrorFmt(.eval, kind, node.loc(), ...)`; primitives in `lang/primitive/{math,core}.zig` already match the `BuiltinFn` shape, so route their errors too   | [x] (`6777c42`) |
| 3.5  | `src/runtime/collection/string.zig` — String heap type (`HeapTag.string`); analyzer lifts string Form atoms into Value via `runtime.string.alloc(rt, bytes)`; `printValue` renders quoted                                                                                          | [x] (`3a5f852`) |
| 3.6  | `src/runtime/collection/list.zig` — list literal as a Value: `(quote (1 2 3))` returns a heap List; analyzer's `formToValue` walks Form `.list` recursively                                                                                                                       | [x] (`766a73a`) |
| 3.7  | `src/lang/macro_transforms.zig` (impl) + `src/eval/macro_dispatch.zig` (Layer-1 dispatch type) — Zig-level Form→Form expansions for the bootstrap macros (`let` → `let*`, `when` → `(if c (do ...) nil)`, `if-let` / `when-let` / `and` / `or` / `cond` / `->` / `->>`). `analyze` gains a `macro_table: *const macro_dispatch.Table` parameter; `analyzeList` consults it when the head resolves to a `^:macro` Var. **`runtime/dispatch.zig::VTable.expandMacro` is removed**; macro expansion is no longer a backend concern (ADR [0001](decisions/0001-macroexpand-routing.md)) | [x] (`6630cbe`) |
| 3.8  | `src/runtime/print.zig` — extract `printValue` from main.zig; add list / string / fn / keyword / symbol pr-str renderers; main.zig switches to `print.printValue`                                                                                                                  | [x] (`772ebcf`) |
| 3.9  | `src/eval/analyzer.zig` — add `try` / `catch` / `throw` / `loop*` / `recur` special forms; `eval/node.zig` gains `try_node` / `throw_node` / `loop_node` / `recur_node` variants                                                                                                  | [x] (`28c2bc3`) |
| 3.10 | `src/runtime/collection/ex_info.zig` (new) — `ExInfo` heap struct `{message, data, cause}`; `lang/primitive/error.zig` exposes `ex-info` / `ex-message` / `ex-data` builtins; `runtime/print.zig` renders `#error{...}`                                                          | [x] (`c16380f`) |
| 3.11 | `src/eval/backend/tree_walk.zig` — implement `evalLoop` / `evalRecur` (threadlocal pending_recur signal), `evalTry` / `evalThrow` (`error.ThrownValue` + threadlocal `last_thrown`); closure capture for `fn*` (slot-vector style)                                                | [x] (`99efd07`) |
| 3.12 | `src/lang/bootstrap.zig` + `src/lang/clj/clojure/core.clj` (Stage 1) — Read + Analyse + Eval `core.clj` after `primitive.registerAll`; Stage-1 content: `defn`, `defmacro`, `let`, `when`, `cond`, `if-let`, `when-let`, `not`, `and`, `or`, `->`, `->>`                          | [ ]    |
| 3.13 | `src/main.zig` — wire bootstrap into startup; `cljw -e "(defn f [x] (+ x 1)) (f 2)"` → `3`                                                                                                                                                                                       | [ ]    |
| 3.14 | Phase-3 exit smoke: `(defn f [x] (+ x 1)) (f 2)` → `3` and `(try (throw (ex-info "boom" {})) (catch ExceptionInfo e (ex-message e)))` → `"boom"`. e2e script in `test/e2e/phase3_exit.sh` wired into `run_all.sh`                                                                  | [ ]    |

After 3.14 lands as a `[x]`, the §9 phase tracker flips Phase 3 from
PENDING to DONE and Phase 4 IN-PROGRESS (🔒 x86_64 gate); expand
Phase 4 inline in §9.6.

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

### 11.6 Quality gate timeline

Every quality gate this project will need, listed here so they cannot be
forgotten when their phase arrives. Move rows from Planned → Active as
they are wired.

#### Active

| # | Gate                                       | Wired as                                                  |
|---|--------------------------------------------|-----------------------------------------------------------|
| 1 | Source-commit → doc-commit pairing          | `scripts/check_learning_doc.sh` (PreToolUse hook on Bash). Defined by skill `code-learning-doc`. |
| 2 | Zone-dependency check                       | `scripts/zone_check.sh --gate` invoked from `test/run_all.sh`. |
| 3 | `zig build test` green                      | `test/run_all.sh`.                                         |

#### Planned

| #  | Gate                                                            | Owner / wiring (planned)                       | Prepare by    |
|----|------------------------------------------------------------------|------------------------------------------------|---------------|
| 4  | `zig fmt --check src/`                                          | `scripts/format_check.sh`, called from `test/run_all.sh` | Phase 1 (when src/ grows past bootstrap) |
| 5  | x86_64 cross-arch test (OrbStack Ubuntu)                        | manual `orb run ... zig build test`            | Phase 1.12    |
| 6  | Dual-backend `--compare` (TreeWalk == VM)                       | inline in test runner                          | Phase 8       |
| 7  | Bench regression ≤ 1.2x                                          | `bench/bench.sh record` + `bench/history.yaml` diff | Phase 8 (full); Phase 4 quick harness |
| 8  | Tier-A upstream test green                                      | inline in `test/run_all.sh`                    | Phase 11      |
| 9  | Tier-change ADR present                                         | `scripts/tier_check.sh`                        | Phase 9       |
| 10 | `compat_tiers.yaml` complete (every listed namespace has impl)  | `scripts/tier_check.sh`                        | Phase 14      |
| 11 | GC root coverage (every heap type traced)                       | unit tests + `--gc-stress`                     | Phase 5       |
| 12 | Bytecode cache versioning                                        | cache header version field                     | Phase 12      |
| 13 | JIT go/no-go ADR                                                | `.dev/decisions/NNNN-jit-decision.md`          | Phase 17 end  |
| 14 | Wasm Component build green                                      | `test/run_all.sh` extension                    | Phase 14      |
| 15 | WIT auto-binding correctness                                     | inline test                                    | Phase 19      |
| 16 | nREPL operation parity (CIDER 14 ops)                           | inline test                                    | Phase 14      |

### 11.7 Periodic scaffolding audit

Every Phase boundary (or every ~10 ja docs, or before a release tag),
invoke skill `audit-scaffolding`. It detects four rot patterns across
CLAUDE.md / .dev/ / .claude/ / docs/ / scripts/: **staleness** (refs
that don't match reality), **bloat** (files past their soft limit,
duplicated facts drifting), **lies** (absolute claims overtaken by
reality), **false positives** (gate / rule triggers firing when they
shouldn't). The audit produces a report; the user decides what to fix.

---

## 12. Commit discipline and work loop

### 12.1 Commit at the natural granularity of code changes

- One source commit per logical step — red, green, refactor each get their
  own commit if that maps to the work.
- Structural changes (rename / move / split) and behavioural changes go in
  separate commits.
- Never commit when tests are red.
- Never bypass the pre-commit hook with `--no-verify` — fix the issue.

### 12.2 Commit pairing (skill `code-learning-doc` is canonical)

Source-bearing commits accumulate freely; when a unit of work is ready
to be told as one story, write `docs/ja/NNNN-<slug>.md` in a separate
commit whose `commits:` front-matter cites every source SHA it covers.

The full definition (source-bearing file set, the two gate rules, the
template, the workflow) lives in
[`.claude/skills/code-learning-doc/SKILL.md`](../.claude/skills/code-learning-doc/SKILL.md).
Do not duplicate it here — point to the skill instead. The gate
(`scripts/check_learning_doc.sh`) is the executable specification.

### 12.3 Message format

```
<type>(<scope>): <one-line summary>

<optional body explaining WHY (not WHAT)>
```

`<type>`: `feat | fix | refactor | docs | chore | test | bench`
`<scope>`: `runtime | eval | lang | app | build | tests | bench | dev`

Doc commits use:

```
docs(ja): NNNN — <title> (#<first-sha>..<last-sha>)
```

### 12.4 Iteration loop (skill `continue` is canonical)

The full resume procedure + per-task TDD loop lives in
[`.claude/skills/continue/SKILL.md`](../.claude/skills/continue/SKILL.md).
The user invokes it with "続けて" / "/continue" / "resume"; the skill
reads handover, finds the next task, runs tests, prints a brief
summary, then **immediately enters the TDD loop and runs autonomously
until the user intervenes** (no "go" gate, no per-Phase confirmation).

The TDD loop has eight steps per task:

| # | Step               | Where                                        |
|---|--------------------|----------------------------------------------|
| 0 | Survey             | Subagent (Explore)                           |
| 1 | Plan               | Main                                         |
| 2 | Red                | Main                                         |
| 3 | Green              | Main                                         |
| 4 | Refactor           | Main                                         |
| 5 | Test gate          | Main or Subagent (Bash) if log > 200 lines   |
| 6 | Source commit      | Main                                         |
| 7 | Per-task note      | Main → `private/notes/<phase>-<task>.md`     |
| 8 | Context-budget gate| Main; `/compact` if > 60% fill               |

Chapters (`docs/ja/NNNN-*.md`) are written **per concept** (every 3–5
source commits or at phase boundary), not per task. The chapter pulls
from per-task notes; that's why per-task notes exist.

Phase-boundary review chain runs as a **multi-agent fan-out**:
audit-scaffolding, `simplify` on the phase diff, `security-review` on
unpushed commits, and outstanding chapter writing — all in parallel
subagents. Long-context audit / chapter-write subagents may use
Opus 4.6 (better long-context retrieval) instead of Opus 4.7.

It only stops for: a `git push`, an ambiguous test failure, an
audit-scaffolding `block` finding, an ADR-level decision, or
unadopted strategic notes in `private/`.

Pushing to `cw-from-scratch` always requires explicit user approval.

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
- ❌ Writing a doc commit that omits any unpaired source SHA from `commits:` (§12.2 Rule 2)
- ❌ Mixing source and a `docs/ja/NNNN-*.md` in the same commit (§12.2 Rule 1)

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
- `.claude/rules/textbook-survey.md` — Step-0 survey policy + anti-pull
  guardrails (auto-loaded on `src/**/*.zig`)
- `.claude/rules/cljw-invocation.md` — `cljw` invocation safety
  (auto-loaded on test/e2e and bench scripts)
- `.claude/skills/code-learning-doc/{SKILL,TEMPLATE_TASK_NOTE,
  TEMPLATE_PHASE_DOC}.md` — two-cadence learning material skill
- `.claude/skills/continue/SKILL.md` — autonomous resume + 8-step TDD
  loop + multi-agent phase-boundary chain
- `.claude/skills/audit-scaffolding/{SKILL,CHECKS}.md` — periodic
  scaffolding audit (incl. Section F: unadopted strategic notes)
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
| **Learning doc**    | `docs/ja/NNNN-<slug>.md`, the Japanese learning narrative required by §12.2. |

---

> **Note on history**: this document is a "now" snapshot, not a changelog.
> What changed and why lives in `git log -- .dev/ROADMAP.md` (mechanical
> diff), the corresponding `docs/ja/NNNN-<slug>.md` learning docs (the
> story behind the change), and `.dev/decisions/NNNN-<slug>.md` ADRs
> (load-bearing rationale). Keeping a §17 revision history here was found
> to be redundant and to drift; it has been removed deliberately.
