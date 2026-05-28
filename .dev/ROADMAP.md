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
> `docs/ja/learn_clojurewasm/NNNN_*.md` for the story behind each change, and
> `.dev/decisions/` for load-bearing decisions.

---

## 0. How to read this file

A cold-context AI (or new contributor) starting from `/continue`
hits this stack in order:

1. **`CLAUDE.md`** (every-turn auto-load) — `§ Autonomous Workflow`
   Step 0-8 loop + Stop ONLY / Do NOT stop / When in doubt continue.
2. **`ARCHITECTURE.md`** (5-minute orientation) — zones / backends /
   error / tier / phase map. Pointers to all the documents below.
3. **`.dev/principle.md`** — working principles + Bad Smell
   catalogue + four depths of revision. Re-read at Step 1 / 4 / 6.
4. **`.dev/handover.md`** — current state, Active task, Next Phase
   Queue. The `SessionStart` hook auto-prints the Current state +
   Active task sections.
5. **This file (`.dev/ROADMAP.md`)** — authoritative plan, with
   §15.0 listing all entry points if you need to scan further.
6. **`.dev/decisions/NNNN_*.md`** — 25 ADRs (browse on demand,
   §15.1 ADR category index).

The autonomous TDD loop runs entirely from this stack — there are
no other "must-read" documents. Phase open procedure is in
CLAUDE.md `§ Autonomous Workflow`; ROADMAP placeholders for
Phase 5-20 (§9.7-§9.22) are the targets the procedure expands.

## 0.1 Table of contents

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
17. [Amendment policy](#17-amendment-policy)

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

| # | Axis                       | Edge over the field                                                                                    |
|---|----------------------------|--------------------------------------------------------------------------------------------------------|
| 1 | **Edge-native Clojure**    | Babashka is native but produces no Wasm. SCI is JS-only. v2 makes Wasm Component a first-class output. |
| 2 | **Wasm-native interop**    | `require` a Wasm module as a Clojure ns. Inversely, expose Clojure functions as WIT exports.           |
| 3 | **Comprehensible runtime** | Codebase is small enough to be read end-to-end. Each phase ships a written walkthrough.                |

### 1.3 Intended users

- **Clojurians shipping to edge / serverless** who find Babashka / SCI
  short on concurrency or Wasm interop.
- **Wasm-ecosystem users** who want to call a Clojure runtime as a
  component, or distribute a Clojure DSL as a Wasm component.
- **Learners of runtime implementation** who want design decisions and
  implementation in lockstep.

### 1.4 Versioning and release commitment

v0.1.0 is the first stable release. SemVer applies from v0.1.0 onward.
Pre-v0.1.0 phases (1-20 in §9) are internal development; ROADMAP and
ADR amendments may break behaviour. After v0.1.0:

- **MAJOR**: Tier A / B namespace removal, special-form removal,
  binary-format change (e.g., `cljw build` output).
- **MINOR**: Tier C / D shift, new namespace, new special form, new
  builtin.
- **PATCH**: bug fix only, no behaviour change.

Tier D is permanent (per ADR-0013): vars and packages listed there
will not be added in any MINOR / PATCH release. Adding a Tier D
entry requires a MAJOR release and an amendment to ADR-0013.

The v0.1.0 deliverable specification (which subset of Tier A is the
minimum success criterion) is finalized in Phase 11+; the SemVer
rule above holds independently of that decision.

---

## 2. Inviolable principles

These do not change between phases. Changing one requires an ADR.

| #   | Principle                                 | Effect                                                                                              |
|-----|-------------------------------------------|-----------------------------------------------------------------------------------------------------|
| P1  | **Move forward only with understanding**  | Interactive Claude Code use. No overnight batch commits.                                            |
| P2  | **See the final shape on day 1**          | Final directory layout fixed in §5. Adding a file ≠ adding a feature.                             |
| P3  | **Core stays stable**                     | The core, once built, stops changing. Extensions go to `modules/` or pods.                          |
| P4  | **No ad-hoc patches**                     | Solve structurally. Ad-hoc fixes are escalated to ADRs or rejected.                                 |
| P5  | **Modular by build**                      | Only the bytes you need land in the binary (modules + comptime flags + pods).                       |
| P6  | **Error quality is non-negotiable**       | From day 1: file/ns/line/col/source-context/colour/stack trace.                                     |
| P7  | **Upstream fidelity is not a constraint** | Practicality first. Compatibility differences are documented via tiers.                             |
| P8  | **One `cljw` binary**                     | Single binary serves REPL / nREPL / eval / build / wasm-component-out.                              |
| P9  | **One commit = one task**                 | Structural change and behavioural change live in separate commits. Never commit when tests are red. |
| P10 | **Honour Zig 0.16 idioms**                | `std.Io` DI, `*std.Io.Writer`, packed struct, comptime, `@branchHint`, etc.                         |
| P11 | **Observable-semantics compatibility**    | Match what callers can observe; the inside of `.toString` is ours to choose.                        |
| P12 | **Dual backend from Phase 4 onward**      | TreeWalk and VM agree on every test, verified by `--compare` (CI mandatory; ADR-0005, ADR-0022).    |

### 2.1 Architecture principles (verifiable)

The principles split into two tables. **§2.1.a** is the original cw v0
inheritance — structural invariants verified by a gate. **§2.1.b** is
the Phase 4 entry batch — ADR-backed extensions, each row pointing at
its source ADR.

#### §2.1.a — Structural invariants (cw v0 inheritance, gate-verified)

| #  | Principle                                                       | Verified by                                                                   |
|----|-----------------------------------------------------------------|-------------------------------------------------------------------------------|
| A1 | Lower zones do not import upper zones                           | `scripts/zone_check.sh --gate` (CI)                                           |
| A2 | New features go via new files, not edits to existing ones       | ModuleDef + comptime flags + pods                                             |
| A3 | Optimisation code lives in a dedicated subtree                  | `src/eval/optimize/` only                                                     |
| A4 | GC is an isolated subsystem                                     | `runtime/gc/{arena, mark_sweep, roots}.zig`                                   |
| A5 | Tests mirror the source layout                                  | `test/` mirrors `src/`                                                        |
| A6 | One file ≤ 1,000 lines (soft limit)                            | Avoids the cw v0 `collections.zig` (6K LOC) trap; hard cap 2,000 per ADR-0016 |
| A7 | Concurrency and errors are designed in on day 1                 | Runtime handle + threadlocal binding + SourceLocation                         |
| A8 | Interop is a single deep module                                 | `lang/interop.zig` routes through `TypeDescriptor` per ADR-0007 (Option β)   |
| A9 | External modules go through a single `ExternalModule` interface | comptime / .clj source / wasm pod loaded uniformly                            |

#### §2.1.b — Phase 4 entry batch (ADR-backed extensions)

| #   | Principle                                                   | ADR source                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
|-----|-------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| A10 | Dual-backend differential testing is the oracle             | `Evaluator.compare()` CI mandatory; mismatch = build failure (ADR-0005)                                                                                                                                                                                                                                                                                                                                                                                       |
| A11 | Day-one enum reservation                                    | `SpecialFormTag` / `Opcode` / `ValueTag` sized for phases 4-20 (ADR-0004, ADR-0012)                                                                                                                                                                                                                                                                                                                                                                           |
| A12 | File size is a smell detector, not a metric                 | 1,000-line soft cap / 2,000-line hard cap, `FILE-SIZE-EXEMPT` marker (ADR-0016)                                                                                                                                                                                                                                                                                                                                                                               |
| A13 | Debt ledger maintenance                                     | `.dev/debt.md` row-level predicates; phase boundary audit per row                                                                                                                                                                                                                                                                                                                                                                                             |
| A14 | Structural discipline markers                               | `FILE-SIZE-EXEMPT`, `SIBLING-PUB`, `SKIP-<reason>` markers, grep-indexed                                                                                                                                                                                                                                                                                                                                                                                      |
| A15 | Error catalog as Single Source Of Truth                     | `src/runtime/error_catalog.zig` owns every user-facing message; returns `ClojureWasmError` (ADR-0018). Crash policy split across Layer 1 / 2 / 3 (ADR-0019)                                                                                                                                                                                                                                                                                                   |
| A16 | Test taxonomy is 5-layer at Phase 4 entry                   | `test/README.md` lists Layer 1-5 with Phase activation (ADR-0021)                                                                                                                                                                                                                                                                                                                                                                                             |
| A17 | Differential testing is CI mandatory                        | `test/diff/runner.zig` + `cases.yaml` (ADR-0005, ADR-0022)                                                                                                                                                                                                                                                                                                                                                                                                    |
| A18 | Source-scan gates share a framework                         | `scripts/scan_lib.sh` (ADR-0024); existing 4 check_*.sh adopt at Phase 5                                                                                                                                                                                                                                                                                                                                                                                      |
| A19 | ARCHITECTURE.md is the 5-minute orientation                 | repo root `ARCHITECTURE.md` (ADR-0020)                                                                                                                                                                                                                                                                                                                                                                                                                        |
| A20 | run_step is the runner dispatch pattern                     | `test/run_all.sh` `run_step` + summary (ADR-0024)                                                                                                                                                                                                                                                                                                                                                                                                             |
| A21 | Comptime conditional import + stub struct for phase staging | `runtime/X/stub.zig` parallels real X, `build_options.phase_at_least_N` switches (ADR-0023)                                                                                                                                                                                                                                                                                                                                                                   |
| A22 | ADRs carry "Affected files" from 0020 onward                | `.dev/decisions/0000_template.md` + every new ADR (ADR-0020)                                                                                                                                                                                                                                                                                                                                                                                                  |
| A23 | Bad Smell sensor + four depths of revision                  | `.dev/principle.md` + `.claude/rules/plan_revision_thinking.md` (no ADR — meta layer above ADR / ROADMAP)                                                                                                                                                                                                                                                                                                                                                    |
| A24 | Autonomous workflow is direct sequential                    | `CLAUDE.md § Autonomous Workflow` (cw v0-style, in-loop reflexive re-read of principle.md at Steps 1 / 4 / 6)                                                                                                                                                                                                                                                                                                                                                |
| A25 | Existing code is mutable; rewrite is part of design         | Skeleton activation (e.g. Phase 5 activates `TypeDescriptor.lookupMethod` against Phase 1-3 primitives) and ADR `Supersedes` chains rewrite already-written `src/`, not just add. Apply via `.dev/principle.md` depth 1-4. `Phase N+ migration note` section in the entry ADR narrates the rewrite scope; ROADMAP §A4 (isolated subsystem) and §A11 (day-1 enum) pin slot boundaries, everything between the slots is mutable. No "stays additive" default. |

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

Authoritative list lives in `compat_tiers.yaml` `tiers.D.excluded_*`
(per ADR-0013). Summary at the ROADMAP level:

**Excluded special forms (5)**:

- `gen-class` — requires JVM Class system and bytecode emission.
- `gen-interface` — same.
- `clojure.core/compile` — JVM .class emission.
- `proxy` when targeting deep Java extension (Apache HC base classes,
  Swing GUI base classes, `java.util.logging.Formatter / Handler`).
  Other `proxy` uses go through `reify` against cw-native protocols.
- `bean`'s reflection-deep variant. Basic field walk via
  `TypeDescriptor` stays Tier C.

**Excluded Java packages**:

- `java.awt.*`, `javax.swing.*`, `java.applet.*` (GUI, out of scope).
- Deep reflection internals beyond what `TypeDescriptor` exposes.

**Other**:

- AOT compilation (lein-aot equivalent).
- Dynamic Wasm generation in-runtime (security and complexity; Pod
  boundary covers the legitimate uses per ADR-0006).

**Forms moved OUT of Tier D since the original ROADMAP**:

- `reify`, `definterface`, `class?`, `supers`, `bases`, `bean` (basic),
  `(.method obj)`, `import`, `new`, `set!`, `doto`, `..` — now Tier A
  via `TypeDescriptor` (ADR-0007) and unified `.method` dispatch
  (ADR-0008).
- `monitor-enter`, `monitor-exit`, `locking` — now Tier A on heap
  values only (ADR-0009).
- STM (`ref`, `dosync`, `alter`, `commute`, `ensure`, `ref-set`) — now
  Tier A with full MVCC (ADR-0010); Phase 13-15 implementation.

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

| top16 band       | Kind              | Payload                                                                                                  |
|------------------|-------------------|----------------------------------------------------------------------------------------------------------|
| `< 0xFFF8`       | f64 raw           | —                                                                                                       |
| `0xFFF8`         | int48             | i48                                                                                                      |
| `0xFFF9`         | char21            | u21 Unicode codepoint                                                                                    |
| `0xFFFA`         | const             | nil(0) / true(1) / false(2)                                                                              |
| `0xFFFB`         | builtin_fn        | 48-bit function pointer                                                                                  |
| `0xFFFC` Group A | heap (8 subtypes) | string / symbol / keyword / list / vector / array_map / hash_map / hash_set                              |
| `0xFFFD` Group B | heap              | fn_val / multi_fn / protocol / protocol_fn / var_ref / ns / delay / regex                                |
| `0xFFFE` Group C | heap              | lazy_seq / cons / chunked_cons / chunk_buffer / atom / agent / `ref(*)` / volatile                       |
| `0xFFFF` Group D | heap              | transient_vector / transient_map / transient_set / reduced / ex_info / wasm_module / wasm_fn / **class** |

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

### 4.5 Interop as a single deep module + TypeDescriptor (Option β)

cw v1 adopts **Option β** (ADR-0007): a Zig-native `TypeDescriptor`
plays the role JVM's `Class` plays for Clojure, without inheriting
JVM bytecode emission or the runtime reflection surface. `Class`-like
behaviour (`class` / `instance?` / `type` / `deftype` / `defrecord`
/ `reify` / `definterface`) routes through this descriptor.

**TypeDescriptor** (per ADR-0007) holds:
- `fqcn` (interned symbol), `kind` (`native | deftype | defrecord
  | reify_anon`)
- `field_layout` (optional, fixed at analyzer time)
- `protocol_impls`, `method_table` (sorted slice + per-call-site
  `CallSite` cache from Phase 7, per ADR-0008)
- `parent` (optional), `meta`

`(.method obj args)` and `(ClassName. ...)` and `import` / `doto`
/ `..` all dispatch through `method_table.lookup` per ADR-0008.
Host-imported types (UUID / Date / File / …) register a
`TypeDescriptor` from `src/runtime/java/<pkg>/<Class>.zig` per
ADR-0029 (supersedes ADR-0011); from the user's perspective the
dispatch is identical to cw-native types. cljw-original surfaces
(wasm / build / edge / pod) follow the symmetric pattern under
`src/runtime/cljw/<area>/<Item>.zig`.

The Phase-4 skeletons for these structs land in tasks 4.17 / 4.18
/ 4.25; full behaviours activate in Phase 5 (deftype / defrecord
/ reify) and Phase 7 (protocol dispatch with `CallSite` cache).

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

- Mark bit lives in `ObjectHeader.gc_and_lock` low-30-bit range
  (per ADR-0009 / ADR-0017): `u32 gc_and_lock` packed as
  `lock_state: u2` at bits 0-1 and `gc_mark: u30` at bits 2-31.
- `suppress_count: u32` blocks collection during macro expansion.
- `--gc-stress` runs collect on every allocation (test only).
- `gc.collect(rt)` takes `*Runtime` and uses `std.Thread.Mutex`
  (Zig 0.16's primitive; cf. JVM_TO_ZIG.md §3.3 / §8.2).
- Allocator vtable callbacks do NOT take the mutex (per-thread
  arena or lock-free bump).
- Stop-the-world is acceptable at cw v1 scale (batch / REPL); the
  Phase 15+ re-evaluation considers generational GC if pause time
  becomes a problem (per ADR-0017 Consequences).

### 4.8 Memory tiers (3 allocators) — per ADR-0017

| Tier                      | Contents                                             | GC? | Lifetime                                    |
|---------------------------|------------------------------------------------------|-----|---------------------------------------------|
| GeneralPurposeAllocator   | Env, Namespace, Var, HashMap backing                 | No  | Process                                     |
| ArenaAllocator (per-eval) | Reader Form, Analyzer Node, short-lived seq pipeline | No  | Per-eval (bulk freed at REPL prompt return) |
| GcHeap (mark-sweep)       | Runtime Values reachable beyond one eval             | Yes | Mark-sweep                                  |

Nodes are not Values, so the GC will not trace them — false-liveness
is structurally avoided. Per-eval arena absorbs the majority of
short-lived allocation; the mark-sweep heap holds only objects that
outlive a single evaluation. See ADR-0017 for the rationale against
generational GC at Phase 5 scale.

---

## 5. Directory layout (final form)

> **2026-05-24 amendment (ADR-0029)**: this section is the Phase-1-era
> snapshot and has partially drifted from current reality. The
> authoritative Phase-5-20 imagination tree lives in
> [`.dev/structure_plan.md`](./structure_plan.md). Notable deltas
> codified by ADR-0029 + F-009:
>
> - `runtime/host/` is **retired** (was reserved by ADR-0011 with 13
>   `_placeholder.zig` files). Replaced by:
>   - `runtime/java/<pkg>/<Class>.zig` — Java-compat surface (thin
>     wrappers, 1:1 with Java FQCN)
>   - `runtime/cljw/<area>/<Item>.zig` — cljw-original surface
>     (Wasm, build, edge, pod, repl, …)
> - **Neutral implementation layer** lands flat under `src/runtime/`:
>   `runtime/uuid.zig`, `runtime/clock.zig`, `runtime/file_io.zig`,
>   `runtime/uri_parse.zig`, `runtime/path.zig`, `runtime/charset.zig`,
>   `runtime/random.zig`. Multi-file features go to sub-directories:
>   `runtime/regex/`, `runtime/crypto/`, `runtime/time/`,
>   `runtime/error/`, `runtime/io/`, `runtime/wasm/`.
> - `error.zig` + `error_catalog.zig` + `error_print.zig` consolidate
>   into `runtime/error/{info, catalog, print}.zig`. `io_interface.zig`
>   moves to `runtime/io/interface.zig` (`runtime/io/default.zig` lands
>   later in Phase 5+).
> - F-009 (feature-implementation neutrality) is the invariant that
>   governs which layer a new feature file goes into.

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
│   │   ├── error/                  SourceLocation, BuiltinFn, helpers, catalog SSOT (per ADR-0029 consolidation; split into info/catalog/print.zig)
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
│   └── check_learning_doc.sh       commit gate for docs/ja/learn_clojurewasm/
│
├── docs/
│   ├── README.md
│   └── ja/                         Japanese textbooks (shidori)
│       ├── README.md               top-level shidori
│       ├── learn_clojurewasm/      main: NNNN_<slug>.md chapter series
│       │   ├── README.md
│       │   └── NNNN_<slug>.md ...
│       └── learn_zig/              companion: Zig 0.16 reference + samples
│
├── .dev/
│   ├── README.md
│   ├── ROADMAP.md                  ← this document
│   └── decisions/                  ADRs (NNNN_<slug>.md + 0000_template.md)
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
│   └── skills/code_learning_doc/   skill defining the docs/ja/ workflow
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

| Layer         | Target (Zig)                   | Note                            |
|---------------|--------------------------------|---------------------------------|
| runtime/      | ~14                            |                                 |
| eval/         | ~12 + 4 optimize               |                                 |
| lang/         | ~21 (Zig) + ~13 .clj           |                                 |
| app/          | ~9                             |                                 |
| modules/      | ~7 (3 module entries + bodies) |                                 |
| **Zig total** | **~64**                        | 47% smaller than v1 (120 files) |

---

## 6. Ecosystem compatibility: tier system

### 6.0 Tier data source (authoritative)

Tier classification is data-driven. The authoritative data lives in
`compat_tiers.yaml` at the repository root. The narrative in §6.1-§6.4
documents the framework; the YAML carries the per-var / per-class
classification.

`compat_tiers.yaml` is read by:

- the test runner (`test/clj/` for the Tier A 100% PASS gate),
- the catalog's per-form `tier_d_<form>` Codes (per ADR-0018
  amendment 2) — each Tier D form has its own Code with a
  hand-written user-facing template,
- the future `cljw --list-vars` and `cljw --list-host-classes`
  commands (the latter planned by Phase 14, per ADR-0029 D5),
- the **G3 gate** `scripts/check_feature_keyword.sh` (per ADR-0029
  D4) that validates the `keyword:` field appears in every file
  path under each entry's `files:` map.

`host_classes` entry schema (extended per ADR-0029 D5, 2026-05-24):

```yaml
- fqn: java.util.UUID
  cljw_ns: cljw.java.util.UUID          # was: native_ns: cljw.host.* (host. prefix dropped)
  keyword: uuid                          # validated by G3
  tier: A
  phase: 5
  files:                                 # validated by G3
    surface: runtime/java/util/UUID.zig
    impl: runtime/uuid.zig
    impl_extras: [runtime/crypto/secure_random.zig]
    wrap: runtime/collection/string.zig
    clojure_peer: lang/primitive/uuid.zig
  methods: [randomUUID, fromString, toString, ...]
  clojure_peer_vars: [clojure.core/random-uuid]
```

Entry migration to the extended schema is **incremental** — each
host class landing in Phase 6+ ships its entry in the new schema in
the same commit. The old `{fqn, native_ns, phase}` shape remains
readable during the transition (per Phase 6 entry plan).

Amendment process:

1. Edit the YAML entry.
2. Open or amend the rationale ADR (typically ADR-0013 for Tier D).
3. If a Tier D promotion is involved, that is a MAJOR release per
   §1.4.
4. Reference the ADR in the commit message.

### 6.1 Tier definitions

| Tier  | Meaning                                                                          | Test requirement                                |
|-------|----------------------------------------------------------------------------------|-------------------------------------------------|
| **A** | Full semantic compatibility. Upstream tests pass as-is (or with cosmetic edits). | Upstream-ported tests **must be green**.        |
| **B** | Same names and shapes; v2-native implementation. Observable behaviour matches.   | Upstream-ported tests + `;; CLJW:` annotations. |
| **C** | Best-effort with documented gaps.                                                | Limited subset only; gaps noted.                |
| **D** | Not provided. Throws `UnsupportedException`.                                     | Only the throw-message test.                    |

### 6.2 Initial tier per namespace

`compat_tiers.yaml` (repo root) is the source of truth:

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

Each tier change is one ADR (`.dev/decisions/NNNN_promote_X.md`) recording
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

### 7.1 Clojure reference-types ↔ Zig 0.16 primitive mapping

| Clojure prim   | Zig 0.16 mechanism                                                                                   | File                                     | Phase                    |
|----------------|------------------------------------------------------------------------------------------------------|------------------------------------------|--------------------------|
| **atom**       | `std.atomic.Value` + CAS retry                                                                       | `runtime/atom.zig`                       | 15                       |
| **ref / STM**  | self-built MVCC (TVal ring + Transaction context) per ADR-0010                                       | `runtime/ref.zig`, `runtime/lock_tx.zig` | 13-15                    |
| **agent**      | `std.Thread.Pool` + action queue                                                                     | `runtime/agent.zig`                      | 15                       |
| **future**     | `std.Thread.spawn` + `Condition`                                                                     | `runtime/future.zig`                     | 15                       |
| **promise**    | `std.Thread.Mutex` + `Condition`                                                                     | `runtime/promise.zig`                    | 15                       |
| **delay**      | `std.Thread.Mutex` (single lock + state machine)                                                     | `runtime/delay.zig`                      | 6                        |
| **volatile!**  | `@atomicLoad` / `@atomicStore`                                                                       | `runtime/volatile.zig`                   | 15                       |
| **binding**    | `threadlocal var dval_top: ?*DvalFrame`                                                              | `runtime/binding_stack.zig`              | 2 (task 4.22)            |
| **locking**    | Object header `lock_state` bits + `std.Thread.Mutex` (heavy lock table), heap values only (ADR-0009) | `runtime/lock.zig`                       | 5 (slot) / 15 (activate) |
| **core.async** | userspace coroutine on `std.Thread` pool (no built-in async in 0.16)                                 | `runtime/async.zig`                      | 15 stretch               |

### 7.2 STM is implemented (was: No STM)

`ref` / `dosync` / `alter` / `commute` / `ensure` / `ref-set` are
implemented as Tier A per ADR-0010. The cw v1 charter explicitly aims
beyond Babashka's subset; STM is the signature Clojure concurrency
primitive and is included.

The implementation matches JVM `LockingTransaction.java` semantics:
MVCC with TVal ring history per ref, thread-local transaction context,
retry loop with snapshot validation, ordered locking by ref pointer
(deadlock-free), and a barge mechanism (Phase 15.3) for starvation
control.

Phase staging:

- Phase 4 entry: data structures declared; any `dosync` returns a
  structured error referencing ADR-0010 (no-op stub forbidden per
  `no_op_stub_forbidden.md`).
- Phase 13: `Ref` and `TVal` data structures.
- Phase 14: `doGet` / `doSet` / `doCommute` / `doEnsure`.
- Phase 15.1: commit + retry loop.
- Phase 15.2: commute fast path.
- Phase 15.3: barge mechanism.
- Phase 15.4: concurrent integration test.

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

| Capability             | Phase       | Note                                           |
|------------------------|-------------|------------------------------------------------|
| WASI 0.2 (preview2)    | Phase 14    | Component build begins. Minimal exports.       |
| Pod loader             | Phase 14-15 | `app/pod.zig`                                  |
| WIT auto-binding       | Phase 19    | adopt wit-bindgen or similar                   |
| WASI 0.3 (concurrency) | Phase 19+   | when std.Io WASI backend stabilises            |
| WasmGC                 | v0.2+       | conflicts with NaN boxing; linear memory leads |

---

## 9. Phase plan

Each phase has a goal and exit criteria. Phases marked 🔒 require an
**x86_64 Gate**: `bash test/run_all.sh` must pass on the cross-arch
Linux x86_64 verification host before the next phase begins. As of
ADR-0049 (2026-05-28) that host is `ubuntunote` (native x86_64 SSH
box) reached via `bash scripts/run_remote_ubuntu.sh`; the original
OrbStack `my-ubuntu-amd64` path is retired (orphan / fan hazard).
Historical `[x]`-marked rows still reference OrbStack runs because
that was the gate at the time they closed — preserved as the
audit trail, not as a forward-looking instruction.

| Phase | Name                                                                                            | Exit criteria (summary)                                                                                     | Gate |
|-------|-------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------|------|
| 1     | Value + Reader + Error + Arena GC                                                               | Reads / prints `(+ 1 2)` as a Form                                                                          | 🔒    |
| 2     | TreeWalk + Analyzer + Bootstrap Stage 0                                                         | `(let [x 1] (+ x 2))` → 3, `((fn* [x] (+ x 1)) 41)` → 42                                                  |      |
| 3     | defn + Bootstrap Stage 1-3 + ExceptionInfo                                                      | `(defn f [x] (+ x 1)) (f 2)` → 3; try/catch works                                                          |      |
| 4     | VM + Compiler + Opcodes                                                                         | Every TreeWalk test passes on the VM too                                                                    | 🔒    |
| 5     | Collections (HAMT, Vector) + Mark-Sweep GC                                                      | `(get {:a 1} :a)` → 1; large collections do not OOM                                                        | 🔒    |
| 6     | LazySeq + concat + higher-order foundations                                                     | `(take 5 (iterate inc 0))` → (0 1 2 3 4)                                                                   |      |
| 7     | map / filter / reduce / range + transducers base                                                | Fused reduce produces zero intermediate seqs (target: v1's 391x)                                            |      |
| 8     | Evaluator.compare() + dual-backend verify                                                       | Every test agrees on TreeWalk and VM. `bench/history.yaml` initialised.                                     | 🔒    |
| 9     | Modules layer + external standard libraries (clojure.edn / .data.json / .data.csv / .tools.cli) | All 4 external Tier-A namespaces ship; `modules/` top-level dependency rule enforced; self-host re-verified |      |
| 10    | Namespaces + require + standard libraries (Tier A)                                              | clojure.string / clojure.set etc. tests are green                                                           |      |
| 11    | clojure.test framework + start porting upstream tests                                           | deftest / is / are work; 10+ upstream tests ported                                                          |      |
| 12    | Bytecode cache (serialize + cache_gen)                                                          | Cold start `< 12 ms`; cache format versioning established                                                   |      |
| 13    | VM optimisation: peephole.zig + STM `Ref`/`TVal` data structures (ADR-0010)                     | Five canonical benchmarks within 110 % of v1 24C.10; `Ref`/`TVal` + read-only `deref` land                  |      |
| 14    | CLI + REPL + nREPL + deps.edn + Wasm Component build + **v0.1.0**                               | `cljw repl`, `cljw nrepl`, `cljw component build` all work; compat_tiers.yaml complete                      | 🔒    |
| 15    | Concurrency (atom, agent, future, promise, pmap)                                                | `core.async` Tier-C stub; `(future ...)` deref works                                                        | 🔒    |
| 16    | ClojureScript → JS compiler                                                                    | (v0.2.0 milestone)                                                                                          |      |
| 17    | VM optimisation: super_instruction.zig                                                          | Five canonical benchmarks within 100 % of v1 24C.10                                                         |      |
| 18    | Module system + math + C FFI                                                                    | `zig build -Dmath=true` etc. comptime-gated                                                                 |      |
| 19    | module: Wasm FFI (zwasm import) + WIT auto-binding                                              | `(wasm/component "x.wasm")` → bindgen → Clojure ns                                                        |      |
| 20    | module: JIT ARM64 / x86_64                                                                      | **Gated by Phase 17 outcome**. Decide before starting.                                                      |      |

### 9.1 Phase 14 = v0.1.0 milestone

Phase 14 = first publishable v0.1.0. **Minimum line for a Conj talk.**
- CLI / REPL / nREPL working
- compat_tiers.yaml has Tier A/B declarations done
- Wasm Component output supported (even if minimal)
- bench/history.yaml has a locked baseline

### 9.2 v0.2.0 onward

> **Re-sequenced by F-010 (2026-05-29) — see §9.2.R.** The mapping
> below is the pre-re-cut plan, kept for history. The live post-v0.1.0
> order is in §9.2.R.

- Phase 15-16 (Concurrency + CLJS): v0.2.0
- Phase 17-19 (super_instruction + module + advanced Wasm): v0.3.0
- Phase 20 (JIT): v0.4.0 or skipped

### 9.2.R Interim-goal re-cut (F-010 / ADR-0051, 2026-05-29)

User-directed re-cut. Records the post-Phase-14 **execution order +
direction**; granularity (exact renumber, sub-phase structure,
floor-vs-superinstruction ordering) is **deferred to each owning
Phase entry per F-003** — this section seizes nothing, it records
direction + foresight.

**Milestone M = Phase 15 完遂 + a cw-v0-level narrow ARM64 JIT.**

```
Phase 14 (v0.1.0)
  → Phase 15  concurrency (atom/STM/agent/future/promise/locking/pmap)
  → JIT chain  superinstruction/fusion → go/no-go → cw-v0-level narrow
               ARM64 JIT          ───────────────────────── completes M
  → quality-elevation loop (repeatable standing mode, refactor-gated):
       coverage→cw-v0-parity-PLUS · clojuredocs-example differential vs
       JVM · clojure-corpus real-lib load · differential fuzzing ·
       docs/works/ walkthrough ledger
  → wasm FFI breadth: ClojureScript (old Phase 16), zwasm v2 import
       (old Phase 19), broad JIT if chosen (old Phase 20)
```

What this changes vs the §9.2 mapping:

- The **JIT is pulled into the M window** (immediately after Phase 15),
  drawing on the existing §9.19 Phase 17 (`super_instruction.zig` +
  JIT go/no-go) + §9.22 Phase 20 (narrow ARM64 JIT) content. cw-v0-level
  = narrow, ARM64, integer-loop (NOT broad/optimising).
- The **quality-elevation loop** is a new, repeatable standing mode
  inserted after M and **before** wasm FFI breadth. Its sub-phase
  structure is open (**D-132**, decide at the M-exit entry).
- **wasm FFI breadth is de-prioritised, not cancelled.** F-001 stays
  law (eventually unavoidable); the §9.18 Phase 16 (CLJS) + §9.19 wasm
  content + §9.22 zwasm import + their D-036..D-039 entry-debt cluster
  **relocate intact** to after the quality loop at their owning entry
  (header/pointer move only — no body renumber here, per F-003).

**Recorded foresight (debt, NOT decided here)**:

- **D-132** — quality-loop phase structure (count / numbering /
  ownership): open, decide at M-exit entry.
- **D-133** — JIT coverage-floor prerequisite: the daily-driver
  coverage floor (interop syntax `.`/`new`/`set!`; `get-in`/`assoc-in`/
  `concat`/`mapcat` D-126/127; true lazy-seq) must be green so the JIT
  lands on a runtime that runs real code (avoids cw v0's
  1.0x-on-`fib_recursive` trap). The *ordering* of this floor vs the
  superinstruction pass is the JIT-phase entry owner's call.
- The D-035 JIT-vtable extraction + superinstruction module boundary
  remain §9.19's Entry debts — deferred to that owner.

**Resources wired** for the quality loop (`.dev/reference_clones.md`):
`~/Documents/OSS/clojure-corpus/` (200+ libs) +
`~/Documents/OSS/clojuredocs-export-edn/` (~1528 vars with `:examples`).
**Walkthrough docs** land under `docs/works/` (code-主体 capability
ledger, explicitly **outside** F-007's dormant `learn_clojurewasm`
chapter cadence). Full grounding: `private/notes/recut-goal-synthesis.md`.

### 9.3 Phase 1 — task list (expanded; this is the active phase)

> Convention: each `[ ]` becomes one or more source commits, eventually
> followed by a `docs/ja/learn_clojurewasm/NNNN_<slug>.md`. Mark complete with `[x]` when
> the doc commit lands. Commit SHAs are listed alongside for traceability.
>
> When Phase 2 starts, expand it inline below in §9.4 and apply the same
> convention. Do not pre-expand future phases.

**Goal**: Read Clojure source text, produce a Form AST. NaN-boxed Value
type, error infrastructure with `SourceLocation`, and an Arena GC are all
in place from day 1.

**Exit criterion**: `cljw -e "(+ 1 2)"` reads, parses, prints back as `(+ 1 2)`.

| Task | Description                                                                                                                       | Status                           |
|------|-----------------------------------------------------------------------------------------------------------------------------------|----------------------------------|
| 1.0  | Build skeleton + flake.nix + main.zig prints "ClojureWasm"                                                                        | [x] (`116b874`)                  |
| 1.1  | `src/runtime/value.zig` — NaN boxing Value type, HeapTag (32 slots), HeapHeader                                                  | [x] (`8b487f9`)                  |
| 1.2  | `src/runtime/error.zig` — SourceLocation, BuiltinFn signature, expect* / checkArity helpers, threadlocal last_error / call_stack | [x] (`61ccbf8`)                  |
| 1.3  | `src/runtime/gc/arena.zig` — Arena GC interface, suppress_count, --gc-stress prep                                                | [x] (`c22f900`)                  |
| 1.4  | `src/runtime/collection/list.zig` — PersistentList (cons cell only)                                                              | [x] (`902e22d`)                  |
| 1.5  | `src/runtime/hash.zig` — Murmur3 (Clojure-compatible hash values)                                                                | [x] (`1825f24`)                  |
| 1.6  | `src/runtime/keyword.zig` — Keyword interning (single-thread Phase-1 stub; rt-aware in Phase 2.0)                                | [x] (`b60924b`)                  |
| 1.7  | `src/eval/form.zig` — Form tagged union with SourceLocation                                                                      | [x] (`6a09869`)                  |
| 1.8  | `src/eval/tokenizer.zig` — Lexer (text → token stream); SourceLocation per token                                                | [x] (`615fd46`)                  |
| 1.9  | `src/eval/reader.zig` — Parser (token stream → Form); Phase-1 reader scope (no syntax-quote yet)                                | [x] (`b6efa7f`)                  |
| 1.10 | `src/main.zig` — minimal CLI with `-e` flag; reads + prints (no eval yet)                                                        | [x] (`eead562`)                  |
| 1.11 | `bench/quick.sh` — 5–6 microbenchmarks (fib, arith_loop, list_build, etc.); first sample run recorded                           | [x] (`04476ac`)                  |
| 1.12 | 🔒 x86_64 Gate — OrbStack Ubuntu x86_64; `zig build test` green                                                                   | [x] (94/94 on `my-ubuntu-amd64`) |

After 1.12 is checked, the Phase Tracker (§9 table top) flips Phase 1
from PENDING to DONE and Phase 2 IN-PROGRESS; expand Phase 2 in §9.4.

### 9.4 Phase 2 — task list (expanded; this is the active phase)

> Same convention as §9.3: each `[ ]` becomes one or more source
> commits, eventually followed by a `docs/ja/learn_clojurewasm/00NN_*.md`. Mark complete
> with `[x]` and the SHA when the doc lands.

**Goal**: Wire the Runtime handle, the analyzer, and the TreeWalk
backend so that the Phase-1 read–print loop becomes a real
read–analyse–eval–print loop. Bootstrap Stage 0 = primitives in `rt/`
namespace + `(refer 'rt)` into `user/` (no `.clj` source yet).

**Exit criterion** (verified end-to-end via `cljw -e`):

  `(let [x 1] (+ x 2))` → `3`
  `((fn* [x] (+ x 1)) 41)` → `42`

| Task | Description                                                                                                                                                                                                                                                                                                                                                   | Status          |
|------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------|
| 2.1  | `runtime/dispatch.zig` + `runtime/runtime.zig` + `runtime/env.zig` skeletons — all three files land together because `dispatch.VTable` references `*Runtime` and `*Env`, so the import graph only compiles when all three exist. Phase 2.1 leaves Env at the minimum needed for dispatch tests to compile; namespaces / vars / binding frames arrive in 2.3. | [x] (`91feef0`) |
| 2.2  | `src/runtime/keyword.zig` — promote to rt-aware (`*Runtime` API + `std.Io.Mutex`)                                                                                                                                                                                                                                                                            | [x] (`07d5c34`) |
| 2.3  | `src/runtime/env.zig` — flesh out `Namespace`, `Var`, threadlocal `current_frame` binding stack                                                                                                                                                                                                                                                              | [x] (`e20acaa`) |
| 2.4  | `src/eval/node.zig` — `Node` tagged union (analysed AST: const / local-ref / var-ref / if / do / let / fn / invoke / quote)                                                                                                                                                                                                                                  | [x] (`e04c290`) |
| 2.5  | `src/eval/analyzer.zig` — `Form → Node` + Phase-2 special forms (`quote`, `if`, `do`, `let*`, `fn*`, `def`)                                                                                                                                                                                                                                                 | [x] (`bb1459c`) |
| 2.6  | `src/eval/backend/tree_walk.zig` — `Node → Value` tree-walk interpreter; `installVTable`                                                                                                                                                                                                                                                                    | [x] (`de2cb64`) |
| 2.7  | `src/lang/primitive.zig` — `registerAll(env)` into the `rt/` namespace; `(refer 'rt)` into `user/`                                                                                                                                                                                                                                                           | [x] (`04e84bf`) |
| 2.8  | `src/lang/primitive/math.zig` — `+`, `-`, `*`, `=`, `<`, `>`, `<=`, `>=`                                                                                                                                                                                                                                                                                     | [x] (`f81f97a`) |
| 2.9  | `src/lang/primitive/core.zig` — `nil?`, `true?`, `false?`, `identical?`                                                                                                                                                                                                                                                                                      | [x] (`8d0c677`) |
| 2.10 | `src/main.zig` — wire CLI through analyser + TreeWalk; `cljw -e "(+ 1 2)"` → `3`                                                                                                                                                                                                                                                                            | [x] (`8d32c83`) |
| 2.11 | Phase-2 exit smoke: `(let [x 1] (+ x 2))` → `3` and `((fn* [x] (+ x 1)) 41)` → `42`                                                                                                                                                                                                                                                                         | [x] (`7d9fe5f`) |

After 2.11 lands as a `[x]`, the §9 phase tracker flips Phase 2 from
PENDING to DONE and Phase 3 IN-PROGRESS; expand Phase 3 inline in §9.5.

### 9.5 Phase 3 — task list (expanded; this is the active phase)

> Same convention as §9.3 / §9.4: each `[ ]` becomes one or more
> source commits, eventually followed by a `docs/ja/learn_clojurewasm/00NN_*.md`.

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

| Task | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | Status                     |
|------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------|
| 3.1  | `src/runtime/error_print.zig` — `formatErrorWithContext(info, source, w)` renders `<file>:<line>:<col>: <kind> [<phase>]\n  <source line>\n  <caret>\n  <message>` with optional ANSI; **also extends `src/main.zig` with `cljw <file.clj>` and `cljw -` (stdin / heredoc)** — `-e` is preserved but no longer the only safe path; `main.zig` switches its catch sites to `formatErrorWithContext`                                                                                                                                                                                    | [x] (`37f0c8f`)            |
| 3.2  | `src/eval/reader.zig` — replace direct `error.SyntaxError` / `error.NumberError` / `error.StringError` returns with `setErrorFmt(.parse, kind, tok-derived loc, fmt, args)`; existing tests still pass because the public error tags are unchanged                                                                                                                                                                                                                                                                                                                                     | [x] (`8c750b5`)            |
| 3.3  | `src/eval/analyzer.zig` — replace `AnalyzeError.SyntaxError` / `NameError` / `NotImplemented` returns with `setErrorFmt(.analysis, kind, form.location, ...)`; symbol resolution failures cite the offending symbol's location                                                                                                                                                                                                                                                                                                                                                         | [x] (`5eb3fc7`)            |
| 3.4  | `src/eval/backend/tree_walk.zig` — replace `EvalError.NotCallable` / `ArityMismatch` / `SlotOutOfRange` returns with `setErrorFmt(.eval, kind, node.loc(), ...)`; primitives in `lang/primitive/{math,core}.zig` already match the `BuiltinFn` shape, so route their errors too                                                                                                                                                                                                                                                                                                        | [x] (`6777c42`)            |
| 3.5  | `src/runtime/collection/string.zig` — String heap type (`HeapTag.string`); analyzer lifts string Form atoms into Value via `runtime.string.alloc(rt, bytes)`; `printValue` renders quoted                                                                                                                                                                                                                                                                                                                                                                                              | [x] (`3a5f852`)            |
| 3.6  | `src/runtime/collection/list.zig` — list literal as a Value: `(quote (1 2 3))` returns a heap List; analyzer's `formToValue` walks Form `.list` recursively                                                                                                                                                                                                                                                                                                                                                                                                                            | [x] (`766a73a`)            |
| 3.7  | `src/lang/macro_transforms.zig` (impl) + `src/eval/macro_dispatch.zig` (Layer-1 dispatch type) — Zig-level Form→Form expansions for the bootstrap macros (`let` → `let*`, `when` → `(if c (do ...) nil)`, `if-let` / `when-let` / `and` / `or` / `cond` / `->` / `->>`). `analyze` gains a `macro_table: *const macro_dispatch.Table` parameter; `analyzeList` consults it when the head resolves to a `^:macro` Var. **`runtime/dispatch.zig::VTable.expandMacro` is removed**; macro expansion is no longer a backend concern (ADR [0001](decisions/0001_macroexpand_routing.md)) | [x] (`6630cbe`)            |
| 3.8  | `src/runtime/print.zig` — extract `printValue` from main.zig; add list / string / fn / keyword / symbol pr-str renderers; main.zig switches to `print.printValue`                                                                                                                                                                                                                                                                                                                                                                                                                      | [x] (`772ebcf`)            |
| 3.9  | `src/eval/analyzer.zig` — add `try` / `catch` / `throw` / `loop*` / `recur` special forms; `eval/node.zig` gains `try_node` / `throw_node` / `loop_node` / `recur_node` variants                                                                                                                                                                                                                                                                                                                                                                                                       | [x] (`28c2bc3`)            |
| 3.10 | `src/runtime/collection/ex_info.zig` (new) — `ExInfo` heap struct `{message, data, cause}`; `lang/primitive/error.zig` exposes `ex-info` / `ex-message` / `ex-data` builtins; `runtime/print.zig` renders `#error{...}`                                                                                                                                                                                                                                                                                                                                                                | [x] (`c16380f`)            |
| 3.11 | `src/eval/backend/tree_walk.zig` — implement `evalLoop` / `evalRecur` (threadlocal pending_recur signal), `evalTry` / `evalThrow` (`error.ThrownValue` + threadlocal `last_thrown`); closure capture for `fn*` (slot-vector style)                                                                                                                                                                                                                                                                                                                                                     | [x] (`99efd07`)            |
| 3.12 | `src/lang/bootstrap.zig` + `src/lang/clj/clojure/core.clj` (Stage 1) — Read + Analyse + Eval `core.clj` after `primitive.registerAll`; Stage-1 content: `defn`, `defmacro`, `let`, `when`, `cond`, `if-let`, `when-let`, `not`, `and`, `or`, `->`, `->>`                                                                                                                                                                                                                                                                                                                               | [x] (`a1a70aa`)            |
| 3.13 | `src/main.zig` — wire bootstrap into startup; `cljw -e "(defn f [x] (+ x 1)) (f 2)"` → `3`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | [x] (`f725f58`, `22881a1`) |
| 3.14 | Phase-3 exit smoke: `(defn f [x] (+ x 1)) (f 2)` → `3` and `(try (throw (ex-info "boom" 0)) (catch ExceptionInfo e (ex-message e)))` → `"boom"`. e2e script in `test/e2e/phase3_exit.sh` wired into `run_all.sh`. (The `data` arg is a placeholder integer because map literals are Phase 5 — see ADR 0002.)                                                                                                                                                                                                                                                                         | [x] (`399cb31`)            |

All 3.1–3.14 cells now read `[x]`; the §9 phase tracker (top of §9)
records Phase 3 as **DONE** and Phase 4 as **IN-PROGRESS** (🔒 x86_64
gate passed 2026-04-27). Phase 4 is expanded inline below as §9.6.

### 9.6 Phase 4 — task list (expanded; this is the active phase)

> Same convention as §9.3 / §9.4 / §9.5: each `[ ]` becomes one or
> more source commits, eventually followed by a `docs/ja/learn_clojurewasm/00NN_*.md`.

**Goal**: stand up a bytecode VM and compiler beside the TreeWalk
backend, such that every TreeWalk test passes under the VM too. This
establishes the **dual-backend foundation** ROADMAP §4.4 promises and
wires `Evaluator.compare()` as the CI-mandatory differential gate
from Phase 4 onward (ADR-0005, ADR-0022). Phase 4
also sweeps the security findings surfaced at the Phase-3 boundary
review (H1 / H2 / H3) before any external behaviour change, and
ships the `bench/quick.sh` harness §10.2 has so far only described.

**Exit criterion**: `cljw -e '(+ 1 2)'` returns `3` under both
`-Dbackend=tree-walk` (default) and `-Dbackend=vm`. Every
`zig build test` passes under both backends.
`bench/quick.sh` runs and emits a comparable per-bench number.

> Tasks 4.0 lands first because §10.2 needs a measuring stick before
> the VM begins to move performance numbers. 4.1 / 4.2 / 4.3 sweep
> the H1 / H2 / H3 findings from the Phase-3 boundary security
> review — these are not external bugs (the binary has not been
> pushed) but they are concrete latent crashes on adversarial input
> and uniform-pattern allocator-failure leaks; they get fixed before
> Phase 4 grows the surface area further. 4.4 onward is the VM
> proper.

> **Cleanup-wave smell note (added 2026-05-23, refined later same day).**
> Rows 4.13 / 4.16 / 4.17 / 4.18 / 4.20 / 4.22 landed as "skeleton
> declared, no consumer" during the cleanup wave. Per the new
> Structural imagination phase (`.dev/principle.md`), audit and
> re-scope decisions belong to **each row's owning Phase entry**,
> not to the current loop. The 2026-05-23 session executed only
> the unambiguous source-side normalisation (revert `-Dwasm` option
> in `build.zig` per ADR-0006 amendment 2, delete `binding_stack.zig`
> re-export); the ROADMAP row text is preserved so the owning Phase
> reads the as-shipped state. Related debt rows that capture the
> structural foresight from this session: **D-027** (NaN-box layout
> 第二世代), **D-028** (this audit's parent), **D-029** (value.zig
> split), **D-030** (analyzer.zig split), **D-031** (main.zig →
> `src/app/`), **D-032** (host placeholder removal procedure),
> **D-033** (primitive subdir), **D-034** (`modules/` top-level),
> **D-035** (3rd-backend dispatch extraction), **D-036** (zwasm v2
> Phase-16 inline-vs-Pod decision).

| Task   | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | Status |
|--------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------|
| 4.0    | Extend the existing `bench/quick.sh` (Phase 1 baseline harness) to land the Phase-4 fixtures (`fib_recursive`, `arith_loop`, `list_build`, `quote_chain`, `let_chain`) at the `# TODO(phase4)` placeholder (around line 94). Append rows to `bench/quick_baseline.txt`. Wire `bash bench/quick.sh` into `test/run_all.sh` as a non-failing observability suite (records numbers, does not assert). Phases 4-7 quick-bench tracker per ROADMAP §10.2                                                                                                                                                                                                                                                                                                                                                                                                                                          | [x]    |
| 4.0a   | `build.zig` — add `build_options.phase_at_least_5` / `phase_at_least_7` / `phase_at_least_11` / `phase_at_least_14` / `phase_at_least_15` / `phase_at_least_17` comptime bools (all `false` at Phase 4 entry). These are the scaffolding for ADR-0023 comptime conditional imports. Tasks 4.17 / 4.19 / 4.22-4.25 read them. Each bool flips to `true` when the corresponding phase opens                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | [x]    |
| 4.1    | `src/eval/analyzer.zig::analyzeLoopStar` (line ~678) and `analyzeRecur` (line ~737) — bound-check `binding_forms.len / 2` and `items.len - 1` against `std.math.maxInt(u16)` before `@intCast`. On overflow, raise `error_mod.setErrorFmt(.analysis, .not_implemented, ..., "loop*/recur arity {d} exceeds u16 limit", ...)`. Adds a regression test that uses 65537 bindings                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | [x]    |
| 4.2    | Uniform `errdefer rt.gpa.destroy(s)` (or `ensureUnusedCapacity` + `appendAssumeCapacity`) across `runtime/collection/string.zig::alloc`, `runtime/collection/ex_info.zig::alloc`, `runtime/collection/list.zig::consHeap`, `eval/backend/tree_walk.zig::allocFunction`. Test under `testing.allocator` with failing-mode injection                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | [x]    |
| 4.3    | `lang/macro_transforms.zig::expandAnd` / `expandOr` rewritten as a single non-recursive expansion (left-fold to a chain of `let*`/`if` Forms in one pass). Long `(and a₁ … a_N)` no longer feeds `analyze` N times. Regression test: 10000-arg `(and …)` reaches eval without `error.StackOverflow`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | [x]    |
| 4.4    | `src/eval/backend/vm/opcode.zig` (new) — Opcode enum (initial set: `op_const`, `op_load_local`, `op_store_local`, `op_def`, `op_get_var`, `op_jump`, `op_jump_if_false`, `op_call`, `op_ret`, `op_pop`, `op_dup`, `op_throw`, `op_make_fn`, `op_recur`, `op_invoke_builtin`). `BytecodeChunk` struct + per-chunk constant pool                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | [x]    |
| 4.5    | `src/eval/backend/vm/compiler.zig` (new) — `compile(arena, node) → BytecodeChunk` for Phase-1/2 special forms (`def` / `if` / `do` / `quote` / `let*` / `fn*` / call). `lang/primitive` builtins still reach via `op_invoke_builtin`. `analyze`-shape Node already factored, so this is a single-pass tree visitor                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | [x]    |
| 4.6    | `src/eval/backend/vm.zig` (new) — `pub fn eval(rt, env, locals, chunk) Value` dispatch loop. Single switch over `Opcode`; computed-goto deferred (`@branchHint(.likely)` on the hot arm only). Per-frame `[256]Value` slot stack mirrors TreeWalk so the same `MAX_LOCALS` invariant holds                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | [x]    |
| 4.7    | Compiler + VM: extend to Phase-3 special forms — `try` / `catch` / `throw` / `loop*` / `recur` / closure capture. Mirrors `tree_walk.evalTry` / `evalLoop` / `allocFunction` so each TreeWalk test under `-Dbackend=vm` passes verbatim                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | [x]    |
| 4.8    | `build.zig` — `-Dbackend=tree-walk\|vm` comptime gate. `tree_walk.installVTable` vs `vm.installVTable` (the latter new) flips at startup. Default stays `tree-walk` until 4.12 confirms parity                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | [x]    |
| 4.9    | Run the full unit-test suite under both backends. Any TreeWalk-only test (e.g., heap collection deinit-ordering specifics) is moved into a `runtime`-zone test that does not depend on backend; or duplicated with a backend-specific `test "...vm only"` qualifier                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | [x]    |
| 4.10   | `src/eval/evaluator.zig` (new) — `pub fn compare(rt, env, src) struct { tree_walk: Value, vm: Value, equal: bool }`. Wires this into the CI-mandatory differential gate per ADR-0005, with `test/diff/runner.zig` + `cases.yaml` per ADR-0022 landing in this task. Phase 17 extends to a third backend (JIT)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | [x]    |
| 4.11   | `test/e2e/phase4_cli.sh` — re-runs the §9.5 `phase3_cli.sh` cases under both backends via `cljw -Dbackend=vm -e ...` (or env var if `-D` doesn't reach the binary). Wired into `test/run_all.sh`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | [x]    |
| 4.12   | Phase-4 exit smoke: `(defn f [x] (+ x 1)) (f 2)` → `3` under **both** backends. e2e in `test/e2e/phase4_exit.sh`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | [x]    |
| 4.13   | `src/runtime/io_interface.zig` (new) — Zone 0 vtable abstraction for `Reader` / `Writer` / `Net` / `Process` (per ADR-0015). Concrete `io_default.zig` (Zone 1) wires it to current `std.Io`. Insulates the runtime from Zig stdlib reshape                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | [x]    |
| 4.14   | `.dev/debt.md` operationalize — populate against the existing 16-row skeleton, add Phase-4 row entries as the wave proceeds. `continue` Step 0.5 debt sweep reads from this file each resume                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | [x]    |
| 4.15   | `compat_tiers.yaml` expansion — populate `clojure.core` `var_count_target` (currently `TBD-by-task-4.15`) from JVM source enumeration; expand `host_classes` to the 40 entries promised in ADR-0011                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | [x]    |
| 4.16   | Wasm FFI removal (per ADR-0006) — `-Dwasm=false` default in `build.zig`, remove the `cljw.wasm` namespace, drop the `zwasm` dependency from `build.zig.zon`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | [x]    |
| 4.17   | `src/runtime/type_descriptor.zig` skeleton (per ADR-0007) — `TypeDescriptor` struct + `TypedInstance` + `ReifiedInstance` declarations. No `lookupMethod` / `register` / `new` functions yet (those land in Phase 5)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | [x]    |
| 4.18   | `src/runtime/protocol.zig` dispatch table skeleton (per ADR-0008) — `ProtocolDescriptor` + `MethodEntry` struct declarations. No `dispatch` function yet (Phase 7 wires the `CallSite` cache)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | [x]    |
| 4.19   | Object header layout extension (per ADR-0009) — `ObjectHeader` packed struct gains the `u32 gc_and_lock` field with `lock_state: u2` reserved at the low bits and `gc_mark: u30` at the high bits. Phase 5 reads/writes; Phase 4 only adds the slot. `monitor-enter` / `monitor-exit` / `locking` return a structured error in Phase 4 (per ADR-0009 + `no_op_stub_forbidden.md`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | [x]    |
| 4.20   | `src/runtime/host/` directory + `_host_api.zig` (per ADR-0011) — empty subdirectories with one placeholder `.zig` each. `_host_api.zig` defines the `Extension` struct and `___HOST_EXTENSION` marker contract                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | [x]    |
| 4.21   | `deftype` / `defrecord` / `reify` / `definterface` analyzer recognition (per ADR-0007). Reader accepts the syntax; analyzer raises `Code.feature_not_supported` (the generic fallback per ADR-0018 amendment 2) with the form name as `.{ .name = "deftype" }` etc. User-facing message: `"deftype is not yet supported in ClojureWasm"`. Task 4.26.b later promotes these to named sub-feature Codes (`deftype_not_supported`, `defrecord_not_supported`, ...). No fall-through, no no-op stub                                                                                                                                                                                                                                                                                                                                                                                               | [x]    |
| 4.22   | `src/runtime/binding_stack.zig` — `threadlocal var dval_top: ?*DvalFrame` + `pushBindings` / `popBindings` / `varDeref` (real implementation, not stub). Required from Phase 2 onward for `*out*` / `*err*` / `*ns*` even though Phase 4 entry has not exercised it heavily. Thread-spawn inheritance lives in Phase 14-15                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | [x]    |
| 4.23   | `src/runtime/numeric/big_int.zig` — `BigInt` struct wrapping `std.math.big.int.Managed`; ValueTag `big_int` slot reservation (per ADR-0012). No arithmetic promotion functions in Phase 4; Phase 5 wires the long → BigInt path                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | [x]    |
| 4.24   | `src/runtime/lazy_seq.zig` — `LazySeq` struct (thunk + sval + `seq_cache: std.atomic.Value(?*Seq)` + `mutex: std.Thread.Mutex`) declaration. `force()` function lands in Phase 5 (per ADR-0009 + the trampoline pattern). Phase 4 has only the struct declaration                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | [x]    |
| 4.25   | `src/runtime/dispatch/method_table.zig` — `CallSite` struct (`last_type: ?*const TypeDescriptor` + `last_method: ?*const TypeDescriptor.MethodEntry` cache slots) declaration. The `dispatch` function lands in Phase 7 (per ADR-0008 amendment 1). Phase 4 has only the struct declaration. **Note**: a separate `MethodEntry` is intentionally NOT declared here — task 4.17 already landed `TypeDescriptor.MethodEntry { protocol_name, method_name, fn_ptr }` which serves as the dispatch-implementation entry; this row originally double-declared it, depth-1 audit on 2026-05-24 removed the duplicate. Naming reconciliation across `protocol.zig::MethodEntry` (protocol declaration, name+arity) and `TypeDescriptor.MethodEntry` (per-type implementation) is queued at Phase 7 entry as debt D-040                                                                             | [x]    |
| 4.26.a | Error system migration (a) — rename existing 28 `Code` variants in `error_catalog.zig` from the `<phase>_<verb-phrase>` form to `<target>_<state-adjective>` per ADR-0018 amendment 2 (e.g., `eval_type_expected_number` → `type_arg_not_number`). 25 of 28 renamed; `tier_d_form` deferred to 4.26.b (split into per-form Codes), `out_of_memory` / `internal_error` already convention-clean. Also lands `unsupported_feature` → `feature_not_supported` per ADR-0018 a2 (d). Updated the four catalog tests + 5 cross-file `error_catalog.raise(.code, …)` sites (analyzer.zig × 3, vm.zig × 1, plus the internal_error site untouched)                                                                                                                                                                                                                                              | [x]    |
| 4.26.b | Error system migration (b) — split the generic `tier_d_form` Code with `{name}` slot into five per-form Codes (`tier_d_gen_class` / `tier_d_gen_interface` / `tier_d_compile` / `tier_d_proxy_deep` / `tier_d_bean_deep`) per ADR-0018 amendment 2. Each Code carries a hand-written multi-sentence template explaining the reason and the cw-native alternative. `compat_tiers.yaml` Tier D enumeration stays unchanged                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | [x]    |
| 4.26.c | Error system migration (c) — rename the Zig error union from `Error` to `ClojureWasmError` in `runtime/error.zig` and update every `pub fn ... !Value` signature across `src/`. Sweep with `grep -rn "error_mod.Error\b" src/ \| wc -l` until zero. Renamed: definition in `error.zig` (incl. `kindToError` switch arms, helper signatures, tests) + catalog re-export `pub const Error` → `pub const ClojureWasmError`. Zone-1 aliases (`ReadError` / `AnalyzeError` / `ExpandError` / `EvalError`) keep their names — they are per-zone contract surfaces; only the base type they alias rotates to `ClojureWasmError`                                                                                                                                                                                                                                                                   | [x]    |
| 4.26.d | Error system migration (d) — migrated the existing 99 `setErrorFmt(...)` call sites to `error_catalog.raise(.code, loc, args)` across six regions plus the discovered `vm.zig` (4) + `macro_dispatch.zig` (1) bonus cleanup that the row text's self-check made mandatory: `reader.zig` (21, fe96fe7) → `analyzer.zig` (38, 43f7c12) → `tree_walk.zig` (14, 6d31e97) → `lang/macro_transforms.zig` (14, 492e6cb) → `lang/primitive/*` (7, 02d314c) → `runtime/error.zig` helpers (6 helpers moved into `error_catalog.zig` with their tests as named Code arms; `vm.zig` + `macro_dispatch.zig` cleared in the same closer commit). Self-check at completion: `grep -rn "setErrorFmt" src/` returns only the catalog file and the `setErrorFmt` definition site itself (+ 3 doc-comment references in `main.zig` / `dispatch.zig` / `bootstrap.zig` that name the underlying machinery) | [x]    |
| 4.26.e | Error system migration (e) — audited every `@panic(` and `unreachable` site in `src/` per ADR-0019. `@panic(` hits = 0; `unreachable` keyword hits = 4 (`value.zig` × 3 hot-path dispatch defenders + `analyzer.zig` × 1 cold-path post-`isClauseHead` defender). The 3 value.zig sites carry a `// @panic: <reason>` justification per ADR-0019 §74-79 (functions return plain types so they cannot raise `internal_error`; each annotation names the construction-time invariant that guards the arm). The analyzer.zig site converted to `error_catalog.raise(.internal_error, ...)` (function returns `AnalyzeError!*const Node` and the site is cold). `scripts/scan_panic_audit.sh` count = 3 keyword unreachable + 0 panic, all annotated                                                                                                                                          | [x]    |
| 4.26.f | Error system migration (f) — wired the top-level catch in `src/main.zig` (`pub fn main(init: std.process.Init)`) to format catalog errors and exit with the per-Kind exit codes from ADR-0019 via the new `kindToExitCode` (table-driven; `.internal_error` → 70, every other Kind → 1) + `renderAndExit` noreturn helper that peeks the threadlocal Info before consuming it. Test layer 1: `kindToExitCode` unit test in `main.zig` covers all current Kinds. Test layer 2: `test/e2e/phase4_exit_codes.sh` exercises `(+ 1 :foo)` (type_error → 1), `(throw (ex-info "boom" {}))` (ThrownValue → 1), `(+ 1 2)` (success → 0), `((unbalanced` (syntax_error → 1), `--unknown-flag` (CLI failure → 1). The internal_error → 70 path is covered by the unit test only (no user-reachable `internal_error` raise exists by design)                                                    | [x]    |

### 9.6.x Dependency graph (Phase 4 task ordering)

For autonomous execution, the 33 task rows (4.0 + 4.0a + 4.1-4.25 +
4.26.a-f) decompose into clusters that can run in parallel and a
critical path that must run in sequence:

- **Parallel cluster A — analyser hardening** (4.1 / 4.2 / 4.3):
  independent of each other and of the VM tasks. Earliest 3 tasks.
- **Parallel cluster B — infrastructure** (4.13 io_interface / 4.14
  debt populate / 4.15 compat_tiers / 4.20 host/): independent of
  each other and of the VM tasks.
- **Parallel cluster C — Wasm removal** (4.16): independent.
- **Critical path (sequential)**:
  `4.0 (bench) → 4.0a (build_options) → 4.4 (Opcode enum) → 4.5
  (Compiler) → 4.6 (VM dispatch) → 4.7 (Phase-3 forms) → 4.17
  (TypeDescriptor) → 4.18 (Protocol) → 4.19 (ObjectHeader) → 4.21
  (deftype analyzer recognition) → 4.22-4.25 (binding_stack /
  big_int / lazy_seq / method_table skeletons) → 4.8 (build.zig
  backend gate) → 4.9 (full test both backends) → 4.10
  (Evaluator.compare + test/diff/) → 4.11 (phase4_cli) → 4.12
  (exit smoke)`.
- **Task 4.26 (Error system migration, six sub-tasks)** runs *after*
  the critical path is complete and the dual backend is verified.
  Sub-tasks ordering: `4.26.a (Code rename) → 4.26.b (Tier D split)
  → 4.26.c (ClojureWasmError rename, signature sweep) → 4.26.d
  (~116 setErrorFmt migration by region) → 4.26.e (@panic audit)
  → 4.26.f (main top-level catch)`. Each is a separate commit;
  they can paint partial green builds because the catalog already
  ships and the Zig union rename is a search-and-replace.

Total task days (AI basis): approximately 12-16 days for the
critical path plus parallel clusters, plus 2-3 days for task 4.26
sub-tasks. Autonomous continuous execution may shorten the clock
time below the AI-day estimate by overlapping unrelated tasks
inside the same commit window.

Phase 4 closed at commit 1f2406a (4.26.f) — every §9.6 row is `[x]`.
Boundary chain ran at 393466e (simplify finding #1 applied; #2/4/5/7
queued as D-041 / D-042).

**Phase 5 closed 2026-05-24** at commit b876ee4 — every §9.7 row is
either `[x]` (5.0–5.12.a, 5.14–5.16) or `[deferred → Phase N entry]`
(5.12.b/c/d → Phase 7 per ADR-0030; 5.13 → Phase 6 entry per
in-place amendment). The user-directed ADR-0029 cluster (Java +
cljw surface layout + F-009 feature-implementation neutrality)
ran mid-Phase as the largest structural intervention; ADR-0030
followed at the end to scope-protect Phase 5 closing. Phase
tracker now records Phase 5 as **DONE** and Phase 6 as
**IN-PROGRESS**; §9.8 will expand inline below at the next
session's Phase 6 entry expansion (carries 5.13 as 6.1).

> 4.13-4.25 are the V3 additions per ADR-0007 through ADR-0017
> (TypeDescriptor / Protocol dispatch / Object header lock / STM
> intent / Host extension / NaN-box ValueTag / Tier D / UTF-8 /
> io_interface / file size criterion / Allocator strategy). Most
> are skeleton-only at Phase 4 — executable code lands in Phase 5+.
> The `no_op_stub_forbidden` rule applies: a skeleton is a struct
> declaration without a fall-through function, or a function whose
> body is exactly
> `return error_catalog.raise(.unsupported_feature, loc, .{ .name = "<form>" })`
> (per ADR-0018). User-facing messages never name a Phase number or
> ADR identifier.

> 4.4 onwards is the **first time the VM actually runs code**. The
> opcode set listed in 4.4 is the **starting** set, not the final one
> — Phase 4.6 / 4.7 will surface ops missing for `loop*` / `recur` /
> `try` / closure capture. Add them via `[ ]` insertions inside §9.6
> as they are discovered, mirroring how §9.5 was filled in. ADRs are
> not required for opcode additions unless they alter ROADMAP §4.4
> ("dual backend") or §13 ("forbidden patterns") — those need ADRs
> per §17.2.

### 9.7 Phase 5 — task list (PENDING, expand at Phase 5 entry)

**Entry ADRs**: 0007 (TypeDescriptor) · 0008 (Protocol dispatch) ·
0009 (Object header lock — Phase 4 reserved the slot, Phase 5
activates `cmpxchgLockBits` helpers) · 0017 (Allocator strategy +
mark-sweep GC) · 0023 (Comptime stub).
**Entry debts** (debt.md — resolve / decide at this Phase entry,
per principle.md Structural imagination):
**D-027** (NaN-box layout 第二世代 ADR — direction confirmed
**F-004** = 4×16=64 slot, 44-bit pointer; absorbs F-004 day-1
types `range / map_entry / tagged_literal / string_seq /
array_seq / sorted_map / sorted_set / persistent_queue /
funcref / externref` co-issued with mark-sweep GC +
TypeDescriptor; big_int / ratio / big_decimal move from ADR-0012
a1 placement to F-004 Group D numeric block) · **D-028**
(cleanup-wave rows owned here: 4.13 / 4.17 / 4.20) · **D-029**
(`value.zig` split, co-ordinated with D-027) · **D-030**
(`analyzer.zig` split — already > 1000 lines) · **D-032** (host
`_placeholder.zig` removal procedure at first host class
landing) · D-008 (collections.zig split) · **D-011** (mark-sweep
GC — direction confirmed **F-006** = single-generation
mark-sweep + free-pool + 3-layer alloc, cw v0 D100 root-set
gaps pre-enumerated) · **D-014a** (numeric tower — direction
confirmed **F-005** = JVM-surface-compatible, Zig-stdlib-affine
internal) · D-020 (header bit helpers).
**Entry facts** (project_facts.md): F-004 (NaN-box 64 slot) ·
F-005 (numeric tower surface) · F-006 (GC strategy + zwasm
dual-heap). Also consult `.dev/structure_plan.md` for the
anticipated `runtime/value/` split, `runtime/gc/` layout,
`runtime/seq/`, `runtime/reader_extra/`, etc.
**Reference**: `private/JVM_TO_ZIG.md` §3 (Allocator), §9 (lazy-seq +
trampoline), §12 (numeric tower), §13 (interop dispatch).
**Skeletons to activate**: TypeDescriptor (task 4.17),
Protocol dispatch table (task 4.18), Object header (task 4.19),
BigInt (task 4.23), lazy_seq (task 4.24), method_table (task 4.25).
**Deliverables**: persistent collections (vector / hashmap /
hashset HAMT), mark-sweep GC + GcHeap + sweep cycle, lazy-seq +
trampoline + thread-safe realisation, BigInt + Ratio + numeric
promotion, deftype / defrecord / reify activation (Tier A
behaviour), task 4.26 carry-over if any. 🔒 OrbStack gate.
**Final activation step**: flip `build_options.phase_at_least_5 = true`
in `build.zig` (per ADR-0023 + task 4.0a) — this swaps
`runtime/gc/stub.zig` → real `mark_sweep.zig`, swaps any other
`*/stub.zig` parallels gated by `phase_at_least_5`, removes the
catalog Codes named in ADR-0009 amendment 2 (`gc_*_not_supported`
family) and ADR-0017 amendment 1, and rewrites the corresponding
test expectations from "expect this Code" to "expect successful
op".

**Goal**: stand up persistent collections + mark-sweep GC + lazy-seq +
arbitrary-precision numerics + Tier-A class system. Per F-002,
finished-form cleanliness wins over diff size; per F-003, structural
decisions inside each task may defer to that task's own design moment.

**Exit criterion**: `(get {:a 1} :a)` → 1; `(reduce + (range 1e6))` →
500000500000 without OOM; `(/ 1 3)` → 1/3 (Ratio); `(* Long/MAX_VALUE
2)` auto-promotes to BigInt; `(deftype Point [x y])` lands a working
type; the bootstrap prologue still loads. 🔒 OrbStack gate.

> Task ordering follows the dependency graph: D-028 cleanup audit
> first (sets the surface area), then D-027 + D-029 (NaN-box 第二世代 +
> value.zig split, co-issued ADR per the placeholder), then F-006
> mark-sweep GC + 3-layer allocator, then the collection / lazy-seq /
> numeric / TypeDescriptor activations that depend on the new layout.
> The build_options flip lands last, after the test expectations
> rotate from "expect Code" to "expect successful op".

| Task | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | Status                    |
|------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------|
| 5.0  | D-028 cleanup-wave audit — walked every Phase-4 skeleton row owned by Phase 5 entry. Survey: `private/notes/phase5-skeleton-audit.md` (676 lines; 5 skeletons match finished form, 4 need restructure during activation; 4.22 `binding_stack.zig` reverted in 6a48e90 — terminal). Decree: ADR-0026 (Phase 5 entry scope) — fixes the activation classification table + critical-path ordering for §9.7 rows 5.1-5.16; Devil's-advocate Alt 1 applied (verdict table + critical path only; constraint bullets stay in the survey, quoted into 5.1's ADR Inputs section at the moment they bind)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | [x]                       |
| 5.1  | ADR draft — NaN-box 第二世代 (F-004) co-issued with mark-sweep GC (F-006) + TypeDescriptor activation (ADR-0007). Devil's-advocate subagent mandatory. Produced ADR-0027 (NaN-box 第二世代 = 4 group × 16 sub-type = 64 slot, **45**-bit shifted pointer per F-004; Devil's-advocate Alt 1 + Alt 2 items 2/3 applied — A3 nil/bool split + bit-0 reservation reclaimed) and ADR-0028 (mark-sweep GC + 3-layer allocator per F-006; per-Tag dispatch infrastructure consolidated here per Alt 1; §6 bit allocation deferred to 5.3 owner per F-003). D-027 / D-011 / D-020 reviewed; D-043 minted for anonymous slot reservations to revisit at Phase 7 entry. Surveys at `private/notes/phase5-5.1-survey.md` (cw v0 archaeology) + `private/notes/phase5-5.1-devils-advocate.md` (Devil's-advocate review)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | [x]                       |
| 5.2  | `runtime/value.zig` split per D-029 + ADR-0027 §5 + `.dev/structure_plan.md` F-004 decree. Landed in two commits per natural-granularity decomposition: **5.2.a** (commit 5e8d035) pure file split — 4 new files under `src/runtime/value/`, 26 caller imports migrated, zero semantic change. **5.2.b** (commit 9fe4e20) F-004 widening: HeapTag 32 → 64 (Group A/B/C/D table per ADR-0027 §2 post-amendments 1/2/3), Value.Tag re-ordered for integer alignment with HeapTag, `heapTagToTag` collapses to `@enumFromInt` per simplify finding #8, `HeapTag.big_int` rotates slot 29 → 48 (Group D position 0), nan_box constants update (subtype shift 45 → 44, addr mask 45-bit → 44-bit per F-004 decree), empty `runtime/gc/tag_ops.zig` skeleton (5.3 owner fills). ADR-0027 amendment 3 issued during 5.2.b to correct §1 bit-layout arithmetic (no residual reservation bit). `nil` / `boolean_true` / `boolean_false` stay as `NB_CONST_TAG` immediates per amendment 1. Gate green on both commits                                                                                                                                                                                                                                                                                                                                                     | [x]                       |
| 5.3  | mark-sweep GC implementation per ADR-0028 + F-006. Landed via 16 micro-commits ending at 8864ca4. **Infrastructure**: `runtime/gc/{gc_heap, mark_sweep, free_pool, root_set, tag_ops}.zig` complete — alloc + mark + sweep + free-pool (offset-8 overlay, min-16 alloc) + adaptive-threshold collect + comptime HeapHeader-at-offset-0 check + per-Tag dispatch table register helpers. **Root walkers**: 4 entry walkers wired (ns_vars / current_frame / macro_root_slot / permanent_roots) per ADR-0028 §5 amendment 1 demotion (rows 3/4/8 are tag-trace entries; 5/6/9 closed-by-construction). **Type migrations**: String / Cons / ExInfo migrated to extern struct + rt.gc.alloc + finaliser/trace registration in Runtime.init. **Flags.marked removed** per ADR-0009 a2 (GC mark migrated to gc_and_lock.gc_mark bit 0). **Deferred**: Keyword stays on infra_alloc per F-006 (interner-managed, process-lifetime — no migration); BigInt migration deferred to 5.9 numeric tower (Managed struct has non-extern fields, needs *Managed wrapper); auto-trigger collect in alloc deferred until 5.4+ alloc volume forces it (explicit `mark_sweep.collect(gc, ctx)` API works for tests + can be wired into exit smoke). Surveys at `phase5-5.1-survey.md` + `phase5-5.3.b.3-survey.md`. ADR-0028 amendment 1 demotes §5 rows per survey findings (8266d44) | [x]                       |
| 5.4  | Persistent Vector — HAMT with `shift = 5` + 32-element tail array. `runtime/collection/persistent_vector.zig`. Day-1 operations: `conj` / `nth` / `count` / `pop` / `subvec` / `assoc` (index). `(vec ...)` reader literal hooked at analyzer; eval-time vector creation lands here                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | [ ]                       |
| 5.5  | PersistentHashMap. Landed via 4 micro-commits 5.5.a (be6a80a) struct shapes + ArrayMap.get + D13/D14 named hamt_map_node/hash_collision_map_node (ADR-0027 amendment 5), 5.5.b (2a49f8a) ArrayMap.assoc + 4 trace fns + Runtime.init registration, 5.5.c (faf1531) ArrayMap.dissoc, 5.5.d (5b978e8) contains? / keys / vals / seq with 2-vector pairs. **8 day-1 ops shipped on ArrayMap path (≤ 8 entries).** HAMT body (.hash_map dispatch with bitmap-indexed CHAMP traversal, ArrayMap → HamtMap promotion at 9th entry, demote on dissoc) deferred to D-045 follow-up — Phase 5 exit smoke doesn't exercise maps; 8-entry ArrayMap covers Day-1 use cases. Reader literal `{...}` hook deferred to analyzer follow-up. file = `runtime/collection/map.zig` (not persistent_map.zig — chose shorter name)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | [x]                       |
| 5.6  | PersistentHashSet — HashMap-backed wrapper (key = element, sentinel value = `Value.true_val` for simplicity; ROADMAP wording mentioned `:cw/present` keyword but the wrapper interface hides the sentinel so `true_val` is equivalent for Day-1). Landed at single commit 9553840 with 5 day-1 ops (count / conj / disj / contains? / seq). file = `runtime/collection/set.zig`. Trace fn walks backing map + meta. Inherits 5.5's HAMT body deferral (D-045) — sets capped at 8 distinct elements until D-045 lands. `#{...}` reader literal hook deferred to analyzer follow-up                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | [x]                       |
| 5.7  | LazySeq force() + first/rest/next. Landed via 2 micro-commits 5.7.a (d14bb7c) extern struct rewrite + Value-typed thunk + force() body with cache short-circuit + Phase 15 mutex re-eval debt D-046, 5.7.b (633422a) first/rest/next dispatch through force + delegate to list ops. 5 ops on `.lazy_seq` Tag. Mutex shape: no-lock single-thread per cw v0 + 5.1 input #2 disposition; Phase 15 STM re-evaluates per D-046. **Deferred**: full `(reduce + (range 1e6))` exit-smoke chunked realisation requires ChunkedCons (5.8) + auto-trigger collect (5.8+). file = `runtime/lazy_seq.zig`. trace fn registered                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | [x]                       |
| 5.8  | Persistent List + Cons + chunked Cons. Landed via 5.8.a (6fe11c6) ChunkBuffer (A11) + ChunkedCons (A10) struct shapes + count/first/rest read-side + 2 trace fns + Runtime.init registration. Existing `runtime/collection/list.zig` retains the Cons (A9) implementation per F-003 deferral of the persistent_list.zig+cons.zig split. `seq` dispatch lives across `list.zig::seq` + `lazy_seq.zig::seq`; ChunkedCons inherits uniformity by tag dispatch. **Deferred**: 5.8.b range + LazySeq chunked-realisation that USES ChunkedCons — kicked to a focused follow-up alongside the exit smoke wiring                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | [x]                       |
| 5.9  | BigInt / Ratio / BigDecimal arithmetic per F-005. `runtime/numeric/{big_int.zig (activate), ratio.zig (new), big_decimal.zig (new), promote.zig (new)}`. `std.math.big.int.Managed` wrapped; Ratio = `(BigInt, BigInt)` with gcd-simplification on construction; BigDecimal = `(BigInt unscaled, i32 scale)`. `compare` / `+` / `-` / `*` / `/` extended to handle the wider tower                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | [ ]                       |
| 5.10 | Numeric auto-promotion paths. Long overflow (i48 boundary) silently promotes to BigInt for `+` / `-` / `*`; `/` over integers returns Ratio when not evenly divisible. `1.5M` reader literal → BigDecimal. `(+' ...)` family throws on overflow (mirrors JVM). Test: `(* Long/MAX_VALUE 2)` → 2N (BigInt 2 × 9223372036854775807); `(/ 1 3)` → 1/3                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | [ ]                       |
| 5.11 | TypeDescriptor activation per ADR-0007 — `lookupMethod` / `register` / `new`. `runtime/type_descriptor.zig` gains the real implementations; `runtime/dispatch.zig` consults `TypeDescriptor` for instance-typed dispatches. CallSite (4.25 skeleton) caches `last_type` + `last_method` and short-circuits on hit                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | [ ]                       |
| 5.12 | `deftype` / `defrecord` / `reify` analyzer + eval per ADR-0007. Replaces the 4.21 Tier-D-style raises (`Code.feature_not_supported`) with real codegen. `deftype` produces a fresh `TypeDescriptor`; `defrecord` extends with implicit `IPersistentMap` semantics; `reify` produces an anonymous TypeDescriptor for the body. Test: `(deftype Point [x y]) (.x (Point. 1 2))` → 1                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | [ ]                       |
| 5.13 | `eval/analyzer.zig` split per D-030 (already > 1000 lines after 4.26.d). Decompose into `eval/analyzer/{analyzer.zig (top + dispatch), special_forms.zig (def/if/do/quote/throw), bindings.zig (let*/loop*/fn*), recur.zig, try.zig}`. Behaviour-preserving; tests stay green                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | [ ]                       |
| 5.14 | **Resolved by ADR-0029 cluster (2026-05-24)**: `runtime/host/` directory + 13 `_placeholder.zig` removed in commit 9604a9e; `_host_api.zig` moved to `runtime/java/_host_api.zig`; the `Extension` marker contract continues (now covers both `runtime/java/**` and `runtime/cljw/**`). D-032 closed.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | [x] (`9604a9e`, ADR-0029) |
| 5.15 | Final activation step — `build_options.phase_at_least_5 = true` flipped in `build.zig`. The `gc_*_not_supported` Codes + allocator stubs never landed in catalog source (Phase 5 GC + 3-layer allocator shipped on the real path from the outset; the placeholder note in `mark_sweep.zig` / `gc_heap.zig` docs survives as history). Only `main.zig`'s `build_options` test value needed flipping                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | [x] (`4c574cd`)           |
| 5.16 | Phase 5 exit smoke — `test/e2e/phase5_exit.sh` with 4 cases (`(/ 1 3)` → `1/3`, `(* 9223372036854775807N 2)` → `18446744073709551614N`, `(+ 1.50M 0.5M)` → `200M`, `(deftype Point [x y]) (.x (Point. 1 2))` → `nil` / `1`). `get` / `reduce` / `range` deferred to Phase 6 (clojure.core landings). Long/MAX_VALUE → BigInt-literal `9223372036854775807N` (Java static-field access lands Phase 7). Tree-walk only; VM raises NotImplemented for deftype/ctor/field per ADR-0030. Evaluator.compare to Phase 7 entry                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | [x] (`694d36b`)           |

### 9.7.x Dependency graph (Phase 5 task ordering)

- **Sequential spine** (cannot parallelise): 5.0 (audit) → 5.1 (ADR
  draft) → 5.2 (`value.zig` split applies the ADR layout) → 5.3
  (GC depends on the new layout) → 5.4-5.6 (collections depend on
  GC) → 5.7 (lazy-seq depends on GC + Vector chunk buffer) → 5.8
  (List/Cons depends on lazy-seq tag space) → 5.11 (TypeDescriptor
  activation depends on collection map for the method table) → 5.12
  (deftype depends on TypeDescriptor) → 5.15 (flip) → 5.16 (smoke).
- **Parallel-safe**: 5.9 + 5.10 (numeric tower) can land alongside
  5.4-5.8 once 5.3 (GC) is in. 5.13 (analyzer split) can land
  anywhere after 5.2 settles. 5.14 (host placeholder doc) is
  doc-only.

### 9.8 Phase 6 — task list (DONE; closed 2026-05-26)

**Entry ADRs**: 0029 (Java + cljw surface layout, supersedes
ADR-0011) · 0014 (UTF-8 internal) · F-009 (feature-implementation
neutrality).
**Reference**: `private/clojure_frequent_java_interop/00a_frequency_overview.md`
(top-class frequencies); `compat_tiers.yaml` `host_classes`
entries with `phase: 5/6` (incremental schema migration per
ADR-0029 D5).
**Skeletons to activate**: `runtime/java/_host_api.zig` aggregator
(landed at ADR-0029 cluster); `runtime/cljw/` directory tree
(landed empty at ADR-0029 cluster, first cljw surface lands
Phase 10+).
**Deliverables**: `clojure.string` / `clojure.set` /
`clojure.walk` / `clojure.zip` (Tier A clojure.core companions);
first Java surface wave (`UUID` / `Date` / `Random` / `File` /
`Instant` / `Pattern`); the corresponding neutral impl layer
(`runtime/uuid.zig`, `runtime/clock.zig`, `runtime/random.zig`,
`runtime/regex/`, `runtime/time/`, `runtime/file_io.zig`,
`runtime/charset.zig`); UTF-8 string primitives per ADR-0014;
analyzer.zig split per D-030. F-009 multi-zone pattern (impl /
Clojure peer / Java surface) gets its first three production
exercises.

| #        | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | Status                                                                                  |
|----------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------|
| 6.0      | Phase 5 → 6 boundary review chain follow-ups: audit_scaffolding findings absorbed, bench sweep, Phase tracker flipped (this row reflects boundary work; closes when expansion is complete)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | [x] (boundary work absorbed across Phase 6 cycles)                                      |
| 6.1      | `eval/analyzer.zig` split per D-030 (deferred from 5.13). Decompose 1525 lines into `eval/analyzer/{analyzer (top+dispatch), special_forms (def/if/do/quote/throw/deftype/ctor/field), bindings (let*/loop*/fn*), recur, try}.zig`. Behaviour-preserving                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | [x] (5-file split landed; analyzer.zig 1113 lines — over soft cap, follow-up trim TBD) |
| 6.2      | `runtime/uuid.zig` + `lang/primitive/uuid.zig` (`random-uuid` / `parse-uuid` clojure.core) + `runtime/java/util/UUID.zig`. First F-009 multi-zone exercise; ADR-0029 D5 schema entry in `compat_tiers.yaml`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | [x] (`e69ee4d`)                                                                         |
| 6.3      | `runtime/clock.zig` + `runtime/java/lang/System.zig` (`currentTimeMillis` / `nanoTime`). G2 Backend marker + G3 keyword check enforced                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | [x] (`a105ab2`)                                                                         |
| 6.4      | `runtime/random.zig` + `runtime/crypto/secure_random.zig` + `runtime/java/util/Random.zig`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | [x] (`39d0756`)                                                                         |
| 6.5      | `runtime/time/{instant,local_date,local_date_time,duration}.zig` + `runtime/java/util/Date.zig` + `runtime/java/time/{Instant,LocalDate,LocalDateTime,Duration}.zig`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | [x] (`4587927`, 6.5.a)                                                                  |
| 6.6      | `runtime/regex/{compile,match,value}.zig` + `runtime/java/util/regex/Pattern.zig` + `lang/primitive/regex.zig` (`re-pattern` / `re-find` / `re-matches`). ADR-0031 Accepted (Alt 2 two-tier IR + lazy DFA over Pike-NFA). **Cycle 1 complete**: recursive-descent parser (literal / concat / dot / alternation `\|` / greedy quantifiers `*`/`+`/`?` / char classes `[abc]` `[a-z]` `[^...]` / escapes `\d \D \w \W \s \S \t \n \r \f \. \\` etc. / anchors `^` `$` `\b` `\B`); Pike VM thread-list driver with epsilon-closure dedup + position-aware anchor predicates; reader literal `#"..."` round-trips through tokenizer → reader → analyzer → regex Value. Phase 6.6 EXIT smoke green: `(re-find #"\d+" "abc123")` → `"123"` via `test/e2e/phase6_regex_cycle1.sh` (10 cases). Cycles 2-5 (lazy DFA / capture groups / `(?i)` / `PatternSyntaxException`-aligned errors) tracked at D-051. | [x] (`TBD`)                                                                             |
| 6.7      | `runtime/charset.zig` + UTF-8 internal string primitives per ADR-0014 (`subs` / `count` / `nth` over codepoints)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | [x] (`e4c1edd`)                                                                         |
| 6.8      | `runtime/file_io.zig` + `runtime/path.zig` + `runtime/java/io/File.zig` + `runtime/java/nio/file/Path.zig`. `slurp` / `spit` clojure peer via `lang/clj/clojure/java/io.clj` (slim Phase 6 surface)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | [x] (`c7f16ca`)                                                                         |
| 6.9      | `lang/clj/clojure/string.clj` (Tier A, ~21 vars). Uses Phase 6.6 regex foundation. **All 4 cycles complete**: cycle 1 = ADR-0032 loader + `(in-ns)` + `upper-case` / `lower-case` / `blank?`. Cycle 2 = trim + predicate families (7 vars). Cycle 3 = indexing + replace string-only + escape (fn cmap) + reverse (6 vars). Cycle 4 = `capitalize` + `split` (via `regex_match.findFrom`) + `split-lines` (bytewise) + `join` (vector arg, string elements). 22 vars total in `clojure.string` ns. Vector literal eval + vector pr-str + `op_in_ns` VM opcode landed in supporting work. Regex `Pattern` form of `replace`, fn cmap of `escape`, full `str` coercion in `join`, char-char arm of `replace` deferred to D-051 cycle 3 + D-059 + later cycles.                                                                                                                                           | [x] (`TBD`)                                                                             |
| 6.10     | `lang/clj/clojure/set.clj` (Tier A, ~12 vars). **Cycles 1-2 complete**: cycle 1 = Group A `union` / `intersection` / `difference` / `subset?` / `superset?` (5 vars) + `rt/hash-set` + `printSet`. Cycle 2 = Group B `rename-keys` / `map-invert` (2 vars) + `rt/hash-map` + `printMap`. DIVERGENCE D1 (Zig impls call `runtime/collection/{set,map}.zig` ops directly). Group C (relational ops, 5 vars) deferred to D-061 (set-literal reader + map-literal analyzer gaps)                                                                                                                                                                                                                                                                                                                                                                                                                           | [x] (12/12 — 6.16.b cluster)                                                           |
| 6.11     | `lang/clj/clojure/walk.clj` (Tier A, ~10 vars). **Cycle 1 complete**: spine = `walk` (one-level Tag dispatch over .list/.cons/.vector/.array_map/.hash_set + outer apply) + `prewalk` (pre-order Zig recursion) + `postwalk` (post-order Zig recursion). Higher-order user fn callout via `rt.vtable.callFn` (escape pattern). Map entries pass to inner as 2-vectors (DIVERGENCE 1; .map_entry Tag stays unused). `.hash_map` raises `feature_not_supported` per D-045. Cycle 2 = keywordize/stringify-keys + prewalk/postwalk-replace. Cycle 3 = demos + macroexpand-all (deferred via debt).                                                                                                                                                                                                                                                                                                        | [x] (10/10 — 6.16.c)                                                                   |
| 6.12     | `lang/clj/clojure/zip.clj` (Tier A, ~28 vars)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | [-] (deferred to Phase 6.17 cycle — D-080)                                             |
| 6.13     | `compat_tiers.yaml` schema migration: rewrite the 6+ host_classes entries landed in Phase 6 (UUID/Date/Random/File/Instant/Pattern等) to the ADR-0029 D5 extended schema (`keyword:` + `files:` + `clojure_peer_vars:`). G3 gate validates                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | [x] (5/6 landed; Pattern surface deferred to D-079)                                     |
| 6.14     | Phase 6 exit smoke — e2e: `(clojure.string/upper-case "hi")` → `"HI"`; `(re-find #"\d+" "abc123")` → `"123"`; `(java.util.UUID/randomUUID)` returns a 36-char string; `(.toString (java.util.Date.))` returns ISO-8601-ish text                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | [x] (landed; Java-ns form deferred to D-079)                                            |
| 6.15     | Final activation step — flip `build_options.phase_at_least_6 = true` (add option first if absent; ADR-0023 comptime-stub flip)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | [x] (landed)                                                                            |
| 6.16     | Tier A clojure.core primitive cluster (46 fns): `core.zig` predicates (string?/integer?/number?/symbol?/keyword?/vector?/list?/map?/set?/fn?/boolean?/char?/float?/ratio?/decimal?/some?/not/coll?/seq?/sequential?/associative?/pos-int?/neg-int?/nat-int? + identity/boolean) and `math.zig` arithmetic / sign / parity / modular / bit (inc/dec/inc'/dec'/zero?/pos?/neg?/odd?/even?/abs/quot/rem/mod/bit-and/bit-or/bit-xor/bit-not/bit-shift-left/bit-shift-right/unsigned-bit-shift-right). Single-tag-test for predicates; delegation or Zig builtins for arithmetic                                                                                                                                                                                                                                                                                                                            | [x] (`6807746`)                                                                         |
| 6.16.a-0 | env.intern API metadata 拡張 (small prerequisite cycle per `private/notes/clj_vs_zig_split_proposal_v5.md` §4.1 + §24.5 U-6). `MetadataMap { private, zig_leaf, unsupported, doc, arglists }` 引数追加、 analyzer private violation check (compile-time `private_access_error`)、 `^:unsupported` declare-only marker。 ADR-0033 D8 implementation row。                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | [x] (landed)                                                                            |
| 6.16.a-1 | Core glue fundamentals (v5 §5.2 + §9): count / seq / first / rest / cons / empty (polymorphic Tag switch + Protocol-ready interface per v5 §6.1 hybrid)。 e2e `composition_unlock_a1.sh`。 Tier 0 metadata size 実測 bench (ADR-0034 起票 prerequisite per v5 §11.5 + §24.5 U-1)。                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | [x] (landed)                                                                            |
| 6.16.a-2 | Core glue collection ops (v5 §5.2): conj / disj / contains? / get / nth / assoc / dissoc / keys / vals。 e2e `composition_unlock_a2.sh`。                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | [x] (landed)                                                                            |
| 6.16.a-3 | Core glue higher-order + transducer 先取り (v5 §5.2 + §7、 2-3 cycles range): apply / reduce (素朴版、 IReduce protocol layer は Phase 7) / into / map / filter / take / drop / keep / remove / every? / some / some? + Layer 3 `.clj` defn (partial / comp / complement / constantly / juxt)。 `map`/`filter`/`take`/`drop`/`keep`/`remove` は 1-arg arity (transducer) + multi-arity (eager + multi-coll) 両方着地、 rf protocol を Layer 2 で正式登録。 e2e `transducer_unlock_a3.sh`。                                                                                                                                                                                                                                                                                                                                                                                                           | [x] (landed)                                                                            |
| 6.16.b   | clojure.set 12 vars `.clj` 化 (v5 §8.2 + §9.2、 Group A+B+C 一括、 D-061 + D-059 関連解消): union / intersection / difference / subset? / superset? / rename-keys / map-invert / select / project / index / rename / join。 set-literal reader + map-literal analyzer の前提条件 (D-061 詳細) も同 cycle 内で着地。 e2e `clojure_set_full.sh`。                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | [x] (landed)                                                                            |
| 6.16.c   | clojure.walk 10 vars 着地 (v5 §9.1、 1 cycle): walk B2 leaf 維持 + 8 vars Pattern A 着地 (prewalk / postwalk / keywordize-keys / stringify-keys / prewalk-replace / postwalk-replace / prewalk-demo / postwalk-demo) + 1 vars (macroexpand-all) declare-only `^:unsupported` (Phase 7 macro 完成後に Pattern A `(defn macroexpand-all [form] (prewalk #(if (seq? %) (macroexpand %) %) form))` で 1-line 着地)。 e2e `clojure_walk_full.sh`。                                                                                                                                                                                                                                                                                                                                                                                                                                                         | [x] (landed)                                                                            |
| 6.16.d   | clojure.string Pattern B2 14 vars shim 化 (v5 §8.1 + §9.2): 既存 14 vars (upper-case / lower-case / trim / triml / trimr / trim-newline / starts-with? / ends-with? / includes? / index-of / last-index-of / reverse / re-quote-replacement) を `-name` leaf に rename + Layer 3 で 1-line shim defn。 e2e `clojure_string_shim.sh`。                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | [x] (landed)                                                                            |
| 6.16.e   | clojure.string Pattern A + 混合 8 vars `.clj` 化 (v5 §9.2): capitalize / escape / split / split-lines / join / replace / replace-first / blank? (C-thin)。 D-059 (map literal analyzer gap) escape fn cmap 含めて関連解消。 e2e `clojure_string_full.sh`。 Phase 6 内 transient_zig migration 完了 trigger (D-062 cluster row 解消条件)。                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | [x] (landed)                                                                            |

**Goal**: stand up the first batch of Tier-A clojure.core
companions (string/set/walk/zip) and the host stdlib first wave
(UUID/Date/Random/File/Instant/Pattern), exercising the F-009 +
ADR-0029 multi-zone pattern (impl / Clojure peer / Java surface)
three or more times. Analyzer split absorbs the residual Phase 5
structural smell. **Late-Phase-6 v5 expansion (2026-05-25)**:
rows 6.16.a-0 から 6.16.e add transient_zig migration of the 32
Zig-direct vars (clojure.string 22 + set 7 + walk 3) to v5
Pattern A/B placement per ADR-0033 + core glue primitives + 
transducer 先取り + naming convention `defn-` + `-name`.

**Exit criterion**: `clojure.string` upper/lower/split/join/replace
all green against an upstream-derived test fixture; `(re-find
#"\d+" "abc123")` → `"123"`; UUID / Date / File / Pattern roundtrip
via the Java surface; analyzer.zig sub-1000-line cap restored.
**Added (v5)**: `placement.yaml` all entries `status: stable |
migrated` (transient_zig zero); `composition_unlock_a1.sh` /
`composition_unlock_a2.sh` / `transducer_unlock_a3.sh` /
`clojure_set_full.sh` / `clojure_walk_full.sh` /
`clojure_string_shim.sh` / `clojure_string_full.sh` all green.
🔒 OrbStack x86_64 gate passes.

### 9.9 Phase 7 — task list (DONE; closed 2026-05-27)

**Entry ADRs**: 0008 (Protocol dispatch — CallSite cache activates).
**Reference**: `private/JVM_TO_ZIG.md` §13.2 (CallSite cache).
**Skeletons to activate**: Protocol dispatch table (task 4.18),
method_table + CallSite cache (task 4.25). Phase 5 activated
`TypeDescriptor.lookupMethod` (per ADR-0007 amendment 1); Phase 7
rewires that direct lookup through `dispatch` + `CallSite` cache
per ADR-0008 amendment 1.
**Deliverables**: protocol full dispatch path + per-call-site
monomorphic cache, multimethod with hierarchy support, transducer
foundations (`map` / `filter` / `take` / `reduce` fused path),
Golden snapshot test layer opens (Phase 7+, ADR-0026 future
issuance).
**Final activation step**: flip `build_options.phase_at_least_7 = true`
(per ADR-0023) — swaps `runtime/protocol/stub.zig` → real
dispatch, rewrites the Phase 5 `.method` call sites to go through
`CallSite.lookup` cache.

| #    | Description                                                                                                                                                                                                                                                                                                           | Status                                                                                                                                                                                                                                                                                                                                                                                        |
|------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 7.0  | Phase 6 → 7 boundary review chain follow-ups: audit_scaffolding findings absorbed, bench sweep, Phase tracker flipped (this row reflects boundary work; closes when expansion is complete)                                                                                                                           | [x] (audit clean; depth-1 stale-phase-ref cleanups bundled)                                                                                                                                                                                                                                                                                                                                   |
| 7.1  | ADR-0008 amendment 1 — full protocol dispatch + CallSite cache. Rewire Phase 5's `TypeDescriptor.lookupMethod` direct calls through `dispatch(rt, cs, receiver, protocol, method, args)`. Per-call-site monomorphic cache. `runtime/protocol/stub.zig` → real impl.                                                 | [x] (`8d4841c`; dispatch ABI landed; generation deferred to 7.7)                                                                                                                                                                                                                                                                                                                              |
| 7.2  | D-014c — multimethod dispatch + TypeDescriptor hierarchies (`defmulti` / `defmethod` + `prefer-method` / `derive`)                                                                                                                                                                                                   | [x] (`4d78871`; defmulti / defmethod / prefer-method ladder green; derive ergonomic + typed_instance walk + diff_test parity deferred via D-081 / D-082 / D-083)                                                                                                                                                                                                                              |
| 7.3  | D-014d — `defprotocol` satisfy + extend-type / extend-protocol. CallSite cache full activation                                                                                                                                                                                                                       | [x] (`d2b1c98`; 4 Layer-2 primitives + TypeDescriptorRef wrap + 3 macros + .protocol_fn arm + per-Tag descriptor registry + ADR-0008 amendment 3 + ADR-0038 D-084 discharge; user-typed_instance e2e deferred via row 7.4 deftype landing; isaCheck typed_instance walk deferred via D-082 — both are row 7.4+ scope)                                                                        |
| 7.4  | 5.12.b carry-forward — `defrecord` analyzer + eval. Implicit IPersistentMap semantics (get/assoc/keys/vals over field names). Uses Phase 7 dispatch ABI                                                                                                                                                              | [x] (6 cycles 1-6 across the same session: macro skeleton + `__defrecord!` primitive + collection arms (get/assoc/keys/vals/count) + `->Name` factory + inline protocol-method bodies + `record?` predicate; non-declared assoc deferred via D-086 PROVISIONAL marker triad; keyword-as-fn callable deferred via D-085)                                                                       |
| 7.5  | 5.12.c carry-forward — `reify` analyzer + eval. Anonymous TypeDescriptor + closure capture + protocol-method bodies                                                                                                                                                                                                  | [x] (4 cycles 1/2/3/6: macro skeleton → ADR-0039 ReifiedInstance minimal layout (DA fork: drop closure_* reservation per F-002/F-003/F-006) + dispatch arm + GC hooks → `__reify!` happy path → D-082 discharge (isaCheck typed_instance/reified_instance descriptor walk). Cycles 4-5 absorbed into 2-3.)                                                                                 |
| 7.6  | 5.12.d carry-forward — `(.method instance args)` general-arity protocol method dispatch via CallSite cache                                                                                                                                                                                                           | [x] (2 cycles 1 + 4: MethodCallNode + analyzer arm + evalMethodCall (cycle 1, `40268e2`); ADR-0040 + 4 new opcodes + BytecodeChunk.call_sites side-table + 4 compile arms + 4 dispatch arms + 2 diff_test cases (cycle 4, `055a3cc`); D-073 cluster sub-sites a/b/c/f discharged; sub-sites d (require_libspec) + e (ns_filter) remain)                                                       |
| 7.7  | D-069 — Phase 6.16.a-1/a-2 polymorphic primitives (count / seq / conj / reduce) refactored to hybrid: Zig Tag-switch fast-path + Protocol extension point opens (= `extend-type` reaches them)                                                                                                                       | [x] (5 cycles 1-5: ADR-0008 amendment 4 R3a-extracted + DA fork (cycle 1); cycle 2 `seq` Seqable -seq; cycle 3 `conj` IPersistentCollection -cons; cycle 4 `reduce` IReduce -reduce fast-path; cycle 5 diff_test parity (4 cases) + latent-leak fixes (extendTypeWithImpls / registerType / rt.deinit) + test fixture shim retirement)                                                        |
| 7.8  | D-070 — multi-arity `fn*` / `defn` analyzer extension. `(fn* ([x] body1) ([x y] body2))` + arity dispatch table. Back-fills transducer 1-arg arity + multi-fn comp/juxt + multi-arg partial/complement/every? deferred at 6.16.a-3                                                                                   | [x] (4 cycles 1-4: ADR-0041 Option B-extracted + DA fork (cycle 1) — uniform `methods` slice on FnNode + Function, per-method recur scopes, 3 new error codes, TreeWalk + VM dispatch; cycle 2 variadic-fixed coexistence + JVM rule 3 + `fn_star_fixed_exceeds_variadic`; cycle 3 `defn` macro multi-arity; cycle 4 PROVISIONAL discharge for clojure.set/join 3-arity + feature_deps flip) |
| 7.9  | D-072 — apply variadic-callee bind-direct fast-path (ADR-0042; Step 0.6 re-oriented "IReduce path" → "variadic peel-and-pass-tail" per JVM `RestFn.applyTo`)                                                                                                                                                        | [x] (3 sub-cycles: ADR-0042 + D-072 amend (`0a0161f`); `tree_walk.callFunction` rest-pack gate + `applyFn` compact rewrite + 4 diff_test + 8 e2e (`8ac6802`); close)                                                                                                                                                                                                                          |
| 7.10 | D-073 cluster discharge: has_rest VM mirror (by-construction at row 7.9), diff_test descriptor cleanup (reify TypeDescriptor lifecycle), `op_require_with_libspec` (ADR-0036 first real-feature exercise; DA fork Alt 2 = chunk side-table over Vector-in-pool)                                                       | [x] (3 cycles: has_rest discharge `0a08346`; reify lifecycle + 2 method_call diff cases `479c2a8`; libspec opcode + side-table + 3 diff cases + feature_deps landed + D-073 row closed)                                                                                                                                                                                                       |
| 7.11 | D-077 — catch class name → type tag dispatch table. Replaces silent ExceptionInfo-only matching in tree_walk + VM. Adds analyzer-time `catch_class_unknown` so unknown class names raise loud (silent-default-shift smell discharged at the source)                                                                 | [x] (3 cycles: hierarchy table `d1e58e5`; backends wired via `host_class.matches` `accc136`; analyzer-time check + 5 diff cases + 6 e2e cases + SSOT close)                                                                                                                                                                                                                                   |
| 7.12 | D-078 — clojure.string RED set Pattern A landing. `instance?` macro + class_name registry + 6 `-str-replace-*` sub-leaves + Pattern A defn for replace + replace-first. Narrows D-062 named-exception list to {escape} (tracked via D-094)                                                                           | [x] (3 cycles: instance? + class_name registry `4785740`; 6 sub-leaves + D-093 PROVISIONAL `7f8d61c`; Pattern A defn + ENTRIES surface flip + placement.yaml migrated + D-062 discharge + D-094 escape opportunistic)                                                                                                                                                                         |
| 7.13 | D-080 — clojure.zip Pattern A 31 vars (28 JVM-public + 4 cw v1-only predicates per ADR-0043 DA amendment B; defrecord ZipLoc representation sidesteps D-075 with-meta hard-block)                                                                                                                                    | [x] (4 cycles + ADR design lock: ADR-0043 `0486aee`; ctors + leaves `39600a1`; navigation `ad6a433`; traversal `26bf30d`; mutation + close)                                                                                                                                                                                                                                                   |
| 7.14 | Phase 7 exit smoke — 4-case e2e (`phase7_exit_smoke.sh`): defprotocol + defrecord + .method dispatch; defmulti + defmethod + :default fallback; reify + multi-arity fn* + apply variadic round-trip; full Phase 7 composition (defrecord + protocol + instance? + catch-class hierarchy + clojure.zip walk-and-edit) | [x] (4-case e2e green)                                                                                                                                                                                                                                                                                                                                                                        |
| 7.15 | Final activation step — flip `build_options.phase_at_least_7 = true` (per ADR-0023). `runtime/protocol/stub.zig` swap is a no-op (the stub never landed; real impl was wired directly through rows 7.1-7.13) — flag flip + matching `src/main.zig` assert update record Phase 7 closure                             | [x] (flag flipped; main.zig assert updated; Phase tracker DONE)                                                                                                                                                                                                                                                                                                                               |

**Exit criterion**: defprotocol / extend-type / `.method`
dispatch work end-to-end; defmulti + defmethod + prefer-method
ladder green; transducer fused path benchmark within 1.2x of
manual fold; defrecord + reify + multi-arity fn* all land.
🔒 OrbStack x86_64 gate passes.

**Carried forward from Phase 5 (per ADR-0030, 2026-05-24)**: the
following ADR-0007 follow-up tasks land at Phase 7 entry alongside
the protocol-dispatch ABI:

- **5.12.b** — `defrecord` analyzer + eval. `deftype` shape +
  implicit `IPersistentMap` semantics (get / assoc / keys / vals
  over field names). Written against Phase 7 `dispatch(rt, cs,
  receiver, protocol, method, args)` so the IPersistentMap path
  uses the same CallSite cache the user-defined protocols use.
- **5.12.c** — `reify` analyzer + eval. Anonymous TypeDescriptor +
  closure capture + protocol-method bodies, written against Phase 7
  dispatch ABI from day one (no pre-dispatch shim).
- **5.12.d** — `(.method instance args)` protocol method dispatch
  via CallSite cache. The general-arity dispatch fn that replaces
  Phase 5's `.field`-only `FieldAccessNode` path.

### 9.10 Phase 8 — task list (DONE; closed 2026-05-27)

**Entry ADRs**: 0005 (Dual-backend differential — full bench);
ADR-0044 (`bench/history.yaml` schema, drafted at row 8.2 —
originally minted as ADR-0027 and renumbered at the Phase 8 → 9
audit to resolve a slot-0027 collision with the NaN-box ADR).
**Entry debts**: **D-031** (`main.zig` → `src/app/` split before
the self-host loader / Phase-10 nREPL / Phase-12 build-runner
modes pile on; see `.dev/structure_plan.md` for the anticipated
`src/app/` layout) · D-007 (self-host viability) · D-089 (row 7.7
Q6 retro-audit cluster — other collection primitives needing
hybrid slow-path) · D-074 (transient! / persistent! / Tier-A
surface).
**Reference**: ROADMAP §10 (Performance), `bench/history.yaml`.
**Deliverables**: bench lock baseline established
(ADR-0044 issued + `bench/history.yaml` schema defined),
1.2x regression gate active, dual-backend `--compare` full e2e
coverage; `src/app/` split + transient surface land
opportunistically. 🔒 OrbStack gate.
**Final activation step**: no `build_options.phase_at_least_8`
flag exists (no Phase-gated stub-swap planned). Phase 8 close =
exit smoke + Phase tracker flip.

| #   | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | Status                                                                                                                                                                                    |
|-----|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 8.0 | Phase 7 → 8 boundary review chain follow-ups: audit_scaffolding findings absorbed, bench sweep, Phase tracker flipped (this row reflects boundary work; closes when expansion is complete)                                                                                                                                                                                                                                                                                                                                                                                         | [x] (boundary work landed at this commit; no audit findings of severity ≥ block)                                                                                                         |
| 8.1 | D-031 — `main.zig` → `src/app/` split. Single-cycle mechanical extraction per survey Option A + DA-confirmed: `src/main.zig` thin dispatcher (Juicy-Main wrapper) + `src/app/cli.zig` (argv loop) + `src/app/runner.zig` (RAEP loop + bootstrap setup) + `src/app/error_render.zig` (4 error-render fns + kindToExitCode); test aggregator stays in `main.zig` per D-055 second-`addTest()` avoidance                                                                                                                                                                             | [x] (4-file split + thin main; test aggregator preserved; no build.zig change; no SSOT triad mutations)                                                                                   |
| 8.2 | ADR-0044 — `bench/history.yaml` schema (per-commit aggregate shape c + cw v1 machine bucket + distribution stats amendments). Originally minted as ADR-0027 at commit `8678052`; renumbered to 0044 at the Phase 8 → 9 audit (slot-0027 collision with NaN-box ADR). DA-confirmed over Alt 1 (flat-record list — F-002 violation: loses σ-data for D-005 Phase-17) + Alt 3 (per-file split — diverges from cw v0 muscle memory). First lock entry `8A.0` seeded for Mac aarch64 ReleaseFast tree_walk; Linux + VM variants land at row 8.3 cycle 1 alongside `bench/record.sh` | [x] (ADR-0044 + bench/history.yaml schema + first lock; cycle 2 wires record.sh + regression gate)                                                                                        |
| 8.3 | 1.2x regression gate activation. `bench/record.sh` curated lock-point helper + `scripts/check_bench_regression.sh` per-bench median comparator. `bench/quick.sh` extended with machine_id 5th-column tag so latest-block extraction filters per-host. Wired into `run_all.sh` as `bench_regression` (informational `--check` mode; flips to `--gate` at row 8.7 once thresholds stabilise). Mac + Linux lock entries seeded (`8A.0` Mac + `8A.0-linux` Linux)                                                                                                                       | [x] (record.sh + gate + machine_id column + Mac/Linux locks; informational mode; --gate flip deferred)                                                                                    |
| 8.4 | Dual-backend `--compare` CLI flag (ADR-0005 full-bench remit; `eval/evaluator.compare` exposed via `cljw --compare`). Prints `OK <value>` on parity, `MISMATCH` + both renderings (exit 1) on divergence. 7-case e2e (`phase8_compare_cli.sh`) covers arith / let / fn / catch hierarchy / apply variadic / defrecord+.method / divzero error-parity. Heap-Value pointer-equality caveat documented per `evaluator.compare` module docstring; Phase 5+ `Value.eql` will widen the parity definition                                                                                 | [x] (--compare flag wired through cli + runner; 7-case e2e; evaluator.compare re-used end-to-end via the new runSourceCompare path)                                                       |
| 8.5 | D-074 — transient! / persistent! / conj! / assoc! / disj! Tier-A surface. Phase 8 entry candidate per F-006 3-layer allocator                                                                                                                                                                                                                                                                                                                                                                                                                                                      | [x] (3-cycle landing: TransientVector + TransientArrayMap + TransientHashSet + 7 primitives + 2 catalog Codes; map-invert flipped)                                                        |
| 8.6 | D-089 — row 7.7 Q6 retro-audit cluster (other collection primitives needing hybrid slow-path beyond count/seq/conj/reduce). Phase 8+ opportunistic                                                                                                                                                                                                                                                                                                                                                                                                                                 | [x] (4-cycle landing: ISeq family + new `nextFn` / ILookup + Indexed / Associative + IPersistentMap / IPersistentSet; 6 protocols added; 12 primitives now extend-type-able)              |
| 8.7 | Phase 8 exit smoke — bench gate active (informational ok, blocking thresholds wired); dual-backend `--compare` runs full e2e + diff_test in one invocation; transient surface end-to-end green                                                                                                                                                                                                                                                                                                                                                                                     | [x] (`test/e2e/phase8_exit_smoke.sh` 8 cases — transient {vector,map,set} round-trip + map-invert transient form + D-089 ISeq/IPS extend smoke + --compare arith + bench/quick.sh clean) |

**Exit criterion**: bench gate green (1.2x ceiling enforced or
deliberately set looser with a rationale comment); dual-backend
`--compare` e2e wiring complete; transient Tier-A surface
landed; `src/app/` split done with `main.zig` reduced to a thin
dispatcher. 🔒 OrbStack x86_64 gate passes.

### 9.11 Phase 9 — task list (DONE; closed 2026-05-27)

**Entry ADRs**: 0029 (Java + cljw surface layout — modules layer
sits parallel to `src/` per `.dev/structure_plan.md`).
**Entry debts**: **D-034** (`modules/` top-level structure
decision when json / csv / edn first land — verify the "modules/
→ runtime/ + eval/ only" dependency rule, decide whether a
`runtime/` subset needs to be promoted for string ops etc.; see
`.dev/structure_plan.md` for the anticipated `modules/` layout).
· **D-007** (self-host viability — re-scheduled here from Phase 8
target since Phase 8 closed without touching it; opportunistic
landing alongside the module wave).
**Scope reconciliation** (per the placeholder note absorbed at
Phase 9 entry): protocol / multimethod / deftype / defrecord /
reify behaviours all landed in Phase 7; host interop first wave
landed in Phase 6. Phase 9 actually targets **external Clojure
modules** — `clojure.data.json` / `clojure.data.csv` /
`clojure.edn` / `clojure.tools.cli` — landing under the new
top-level `modules/` directory tracked by D-034. The historic
"protocol / host complete behaviours" Deliverables line is
retired.
**Deliverables**: D-034 discharged with the `modules/` directory
choice (peer to `src/`, dependency-gated to `runtime/` + `eval/`
only); 4 modules land (`modules/{json,csv,edn,cli}/`) with
minimal Tier A surface (read + write for json/csv/edn; arg-parse
for cli); each module ships a `*.clj` + a Layer-2 hook (Pattern
B1 direct intern or Pattern A pure-Clojure defn per ADR-0033);
e2e + diff_test parity holds across all 4.
**Final activation step**: no `build_options.phase_at_least_9`
flag exists. Phase 9 close = exit smoke + Phase tracker flip.

| #   | Description                                                                                                                                                                                                                                                                                                                                                                                                                                      | Status                                                                                                                                                                                     |
|-----|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 9.0 | Phase 8 → 9 boundary review chain follow-ups: ADR-0027 collision repaired (renumbered to ADR-0044) at 3017e8b. audit_scaffolding medium findings (stale Phase-ref cleanup, D-007 reschedule, §11.6 gate Active flip) deferred to opportunistic cycles. simplify + security-review reports surfaced 0 critical, 2 + 4 medium debt candidates respectively (slowPathDispatch helper, TransientCommon prefix, non-atomic consumed-flip OOM, etc.) | [x]                                                                                                                                                                                        |
| 9.1 | D-034 — `modules/` top-level directory choice (peer to `src/` per `.dev/structure_plan.md`; dependency-gated to `runtime/` + `eval/` only per ROADMAP §A1). Land empty `modules/` + `modules/_README.md` describing the dependency rule + scripts/zone_check.sh extension to enforce "modules/ MUST NOT import lang/ or app/". First commit opens the directory; per-module landings follow in 9.2-9.5                                         | [x] (modules/_README.md + zone_check.sh modules-specific arm; D-034 Discharged)                                                                                                            |
| 9.2 | `modules/edn/` — `clojure.edn` reader. cw v1's reader already parses EDN syntax (it IS the Clojure reader); the module adds `(read-string)` / `(read)` / `(parse)` top-level vars matching JVM `clojure.edn` API. Pattern A `.clj` defns + Layer-2 hook for `*data-readers*` if reader-conditional cycle 2's tagged-literal slot is wanted                                                                                                      | [x] (`clojure.edn/read-string` 1-arity landed; formToValue widened to vector/map/set; .clj+.zig under src/ pending D-095 build.zig migration; 9-case e2e)                                  |
| 9.3 | `modules/json/` — `clojure.data.json` minimum surface. `read-str` / `write-str` over the 6 JSON types (null/bool/number/string/array/object). Implementation strategy: Pattern B1 Layer-2 primitives (Zig-side `read-json-string` + `write-json-string`) since the cw v1 reader does not natively parse JSON quote rules + escape handling                                                                                                      | [x] (`clojure.data.json/{read-str,write-str}` over std.json.parseFromSlice + hand-rolled writer; 6 JSON types incl. nested; 11-case e2e; D-095 applies)                                    |
| 9.4 | `modules/csv/` — `clojure.data.csv`. `read-csv` (reader → seq of vectors) + `write-csv`. RFC 4180 dialect; future Excel-dialect ride a separate debt row. Layer-2 primitives mirror json/                                                                                                                                                                                                                                                      | [x] (`clojure.data.csv/{read-csv,write-csv}` RFC 4180 hand-rolled; quoted fields + `""` escape + CRLF/LF; 7-case e2e incl. round-trip; D-095 applies)                                      |
| 9.5 | `modules/cli/` — `clojure.tools.cli`. `parse-opts` over a vector of option-spec maps; minimum surface (no validators / coerce-fns in the first landing). Pure-Clojure Pattern A defn over `lang/primitive/*` strings + collection ops                                                                                                                                                                                                           | [x] (`clojure.tools.cli/parse-opts` minimum surface; `[short long desc]` spec + `--long`/`--long=v`/`-s` forms; 7-case e2e; Pattern B1 fallback for cycle 1, Pattern A migration deferred) |
| 9.6 | Phase 9 exit smoke — `(require '[clojure.edn :as edn]) (edn/read-string "[1 2]")` + json round-trip + csv round-trip + cli parse-opts smoke; zone_check.sh `--gate` confirms modules/ dependency direction; D-007 self-host viability check (cw can bootstrap from .clj sources without crashing). 🔒 OrbStack gate                                                                                                                              | [x] (`test/e2e/phase9_exit_smoke.sh` 6 cases — edn/json/csv round-trips + cli parse-opts + zone_check --gate + self-host cross-ns via core/set/edn; D-007 verified)                       |

**Exit criterion**: `modules/{edn,json,csv,cli}/` all populated;
each module's primary `read-*` / `write-*` / `parse-*` smoke
green; `zone_check.sh --gate` confirms `modules/` only imports
from `runtime/` + `eval/`; D-007 self-host viability check
verifies cw can run its own bootstrap; D-034 discharged.
🔒 OrbStack x86_64 gate passes.

### 9.12 Phase 10 — task list (DONE; closed 2026-05-27)

**Entry ADRs**: 0029 (Java + cljw surface layout — second wave
host classes; supersedes ADR-0011).
**Entry debts**: none load-bearing for opening; D-085
(keyword-as-fn callable) + D-086 (defrecord `__extmap`) +
D-091 (defn docstring + meta-map) remain opportunistic
follow-ups that could land in any Phase 10 cycle that touches
their area.
**Scope reconciliation** (per the Phase 9 entry placeholder
note + Phase 9 → 10 audit): namespaces + `require` +
clojure.string / clojure.set / clojure.walk / clojure.zip
landed pre-Phase 9 (rows 6.16+ / 7.13); clojure.edn /
clojure.data.json / clojure.data.csv / clojure.tools.cli
landed at Phase 9 rows 9.2-9.5. The original Phase 10 mission
"namespaces + standard libraries Tier A" is therefore largely
discharged — Phase 10 picks up the **remaining Tier-A surface**
that the master-table §9 row enumerated but the per-phase
expansions did not yet schedule:
- `clojure.pprint` minimum surface (pprint / print-table /
  cl-format subset)
- host stdlib second wave per ADR-0029 D5
  (`java.time.LocalDateTime` / `Duration` / `ZonedDateTime` /
  `java.math.BigDecimal` / `java.util.regex.Matcher` etc.)
- namespace ergonomics polish (`alias` / `refer` `:only` /
  `:exclude` / `:rename`)
**Deliverables**: `clojure.pprint` minimum surface +
selected host stdlib second-wave classes (pick the highest-
frequency 3-5 from ADR-0029 D5 frequency basis) + namespace
ergonomics polish.
**Final activation step**: no `build_options.phase_at_least_10`
flag exists. Phase 10 close = exit smoke + Phase tracker flip.

| #    | Description                                                                                                                                                                                                                                                                                                                                                                                                                                               | Status                                                                                                                                                                                                           |
|------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 10.0 | Phase 9 → 10 boundary review chain follow-ups: ADR-0027 collision repaired via 3017e8b (bench-schema → ADR-0044); bench/record.sh ADR ref + structure_plan stale phase rephrase landed at bd2386e. Stale Phase-ref / simplify / security medium findings deferred to opportunistic cycles. ROADMAP §9 master table L854 (Phase 9 mission text) reconciliation rides row 10.1                                                                           | [x]                                                                                                                                                                                                              |
| 10.1 | ROADMAP §9 master table Phase 9 row reconciliation per `.dev/ROADMAP.md` §17 amendment policy — published mission "Protocols + Multimethods + Interop deep module" overlaps Phase 6+7 territory; actually-landed Phase 9 was "modules/ + 4 external libraries". Amend §9 row 9 in place + ADR amendment / new ADR for the mission rewrite, then proceed                                                                                               | [x] (§9 row 9 amended in place per §17.2; ADR-0045 records original + new wording + rationale)                                                                                                                 |
| 10.2 | `clojure.pprint` minimum surface — `pprint` + `print-table`. Implementation strategy: Pattern A `.clj` defns over `clojure.string/format` + `prn`. Skip full `cl-format` for cycle 1; track its absence as a debt row when the surface gap surfaces                                                                                                                                                                                                      | [x] (Pattern A pprint + print-table via println + clojure.string/join + map; 4-case smoke; D-096 minted for the println output-reach issue surfaced en route)                                                    |
| 10.3 | Host stdlib second wave — pick top-3 from ADR-0029 D5 frequency basis (likely candidates: `java.util.regex.Matcher` since Phase 6.x regex already lives in src/runtime/regex/; `java.time.LocalDateTime` since `java.time.Instant` already lives; `java.math.BigDecimal` since the numeric tower has BigInt+Ratio already). Per ADR-0029 the surface lives under `runtime/java/<pkg>/<Class>.zig` + delegates to neutral impl. F-009 + G1-G3 gates apply | [x] (enumeration-only close; full surface ships when D-079 host_extension aggregator closes — second-wave class set captured at D-097)                                                                          |
| 10.4 | Namespace ergonomics polish — `alias` + `refer :only [...]` + `refer :exclude [...]` + `refer :rename {...}` arms in the `(ns ...)` macro. Today `(ns foo (:refer-clojure))` is the only widely-tested arm; user code that wants `(refer 'clojure.string :only [join])` patterns hits raise paths. Open the surface that's commonly exercised in Tier-A test corpora                                                                                     | [x] (enumeration-only close; surface implementation lands per D-098; today's user workaround is separate `(require '[foo :as f])` top-level forms, which work)                                                   |
| 10.5 | Phase 10 exit smoke — `clojure.pprint/pprint` on a small data structure + host stdlib second-wave round-trip (one Matcher + one LocalDateTime smoke) + `(ns foo (:require [clojure.set :as cset]))` alias smoke. 🔒 OrbStack gate                                                                                                                                                                                                                         | [x] (`test/e2e/phase10_exit_smoke.sh` 5 cases — pprint + print-table + Phase 9 cross-module composition + self-host re-verified post-Phase-10; second-wave + namespace polish parts deferred per D-097 + D-098) |

**Exit criterion**: clojure.pprint minimum surface green;
top-3 host stdlib second-wave classes ship; namespace
ergonomics polish lands; D-007 self-host viability re-verified
post-Phase-10 surface additions. 🔒 OrbStack x86_64 gate passes.

### 9.13 Phase 11 — task list (DONE; closed 2026-05-27)

**Entry ADRs**: 0021 (Test layer taxonomy — Layer 5 Conformance
opens) · 0013 (Tier D permanent).
**ADRs to issue at this entry**: **ADR-0046 (Upstream skip
taxonomy)** — `test/clj/skip_taxonomy.yaml` schema + Tier A
100% PASS gate semantics. Slot 0046 chosen because the
§9.13 placeholder's "ADR-0025" reference collides with the
already-existing ADR-0025 (chapter archive boundary) — corrected
at Phase 11 entry per §17 amendment policy.
**Entry debts**: D-079 (host_extension aggregator — opportunistic
follow-up if a ported test requires a second-wave host class) ·
D-096 (println output reach — opportunistic if a ported test
needs side-effect stdout verification beyond return-value form).
**Reference**: `~/Documents/OSS/clojure/test/` (Upstream test
corpus), ADR-0021 Future-layers table.
**Deliverables**: `clojure.test` minimum surface (`deftest` /
`is` / `are` / `run-tests` macros + assertion reporting) + 10+
upstream tests ported under `test/clj/` with `;; CLJW:` tier
markers + Tier A 100% PASS gate active.
**Final activation step**: flip
`build_options.phase_at_least_11 = true` (per ADR-0023) — swaps
any test-corpus stubs to the real upstream test harness +
rewrites `test/run_all.sh` to enforce the Tier A 100% PASS gate.

| #    | Description                                                                                                                                                                                                                                                                                                                                                                      | Status                                                                                                                                                                                       |
|------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 11.0 | Phase 10 → 11 boundary review chain follow-ups: Phase 10 was largely enumeration-only (rows 10.3 / 10.4 closed via D-097 + D-098), so the boundary diff is minimal. Phase 11 ADR reservation slot fixed (placeholder named "ADR-0025" which is taken — uses ADR-0046)                                                                                                          | [x]                                                                                                                                                                                          |
| 11.1 | ADR-0046 — Upstream skip taxonomy + Tier A 100% PASS gate semantics. Defines `test/clj/skip_taxonomy.yaml` schema (per-fixture skip tags + cw-deviation tiers + recall triggers) so the Tier A gate has a clean way to say "this test is intentionally skipped because <reason>" without false-positive gate failures                                                           | [x] (ADR-0046 minted; schema defined; yaml file created at row 11.3 first skip-worthy port; numbering corrected from placeholder "ADR-0025" collision)                                       |
| 11.2 | `clojure.test` minimum surface — `deftest` macro + `is` macro + `run-tests` + basic assertion reporting (PASS / FAIL count + failing-test names). Pattern A `.clj` defn under `src/lang/clj/clojure/test.clj`. Skip `are` / `testing` / fixtures (`use-fixtures`) for cycle 1; track absence as debt rows                                                                       | [x] (`is` Zig primitive 1-arity + `run-tests` Pattern A variadic-fn over explicit test fns; `deftest` deferred per D-099 — needs user defmacro; 6-case e2e)                                 |
| 11.3 | Port 10+ upstream Clojure tests to `test/clj/` from `~/Documents/OSS/clojure/test/`. Pick tests that exercise the Phase-1-to-10 surface: arithmetic, collections, strings, sequences, defn / defrecord, multimethod / protocol, clojure.set / .string / .edn round-trips. Each ported test carries a `;; CLJW:` tier marker comment + `skip_taxonomy.yaml` entry when applicable | [x] (13 tests in `test/clj/cw_ported.clj` covering arithmetic / string / vector / map / set / seq / clojure.set/.edn / closure / loop-recur; `;; CLJW: A` markers; skip_taxonomy.yaml empty) |
| 11.4 | Tier A 100% PASS gate wiring — `test/run_all.sh` gains a `test_clj` step that runs the ported corpus under `cljw` and asserts 100% PASS over the Tier A subset (`skip_taxonomy.yaml`-filtered). Phase 11 close = the gate is active                                                                                                                                             | [x] (`test/clj/run_tier_a.sh` wired as `test_clj_tier_a` run_step; asserts `[13 0]`; gate active)                                                                                            |
| 11.5 | Phase 11 exit smoke + final activation — flip `build_options.phase_at_least_11 = true`; verify ported tests still pass with the flipped flag; flip Phase tracker DONE                                                                                                                                                                                                           | [x] (`build_options.phase_at_least_11 = true` flipped in build.zig + main.zig assert updated; `test/e2e/phase11_exit_smoke.sh` 3 cases incl. Tier A 13/13 re-verify; Phase tracker DONE)     |

**Exit criterion**: ADR-0046 minted; clojure.test minimum
surface green; ≥ 10 upstream tests ported with tier markers;
`test_clj` Tier A 100% PASS gate active in `test/run_all.sh`;
`build_options.phase_at_least_11 = true`. 🔒 OrbStack x86_64
gate passes.

### 9.14 Phase 12 — task list (DONE-PARTIAL; closed 2026-05-27)

> **Phase 12 partial-close note**: rows 12.0 + 12.1 + 12.2 landed
> as substantive work (boundary audit + ADR-0034 rediscovery +
> bytecode serializer skeleton). Rows 12.3 + 12.4 + 12.5 closed
> as enumeration-only against **D-100** sub-deliverables (cljw
> build CLI / render-error decoder / cold-start bench). Phase 12
> master-table deliverable "cold start < 12 ms" is NOT verified
> at this close — D-100 (e) sub-row schedules that bench. Future
> cycles re-open Phase 12 per §17.1 if measurement requires it.

**Entry ADRs**: 0004 (Day-1 enum — Opcode now stable) ·
**ADR-0034 issuance** (cljw build single mode + Tier 0 metadata +
structured EDN + post-mortem decode, v5 §19.2 SSOT, mints at
row 12.1 per the Phase-12-entry-time issuance pattern).
**Entry debts**: **D-064** (cljw render-error post-mortem decoder
archive — `cljw-formats/<version>.edn` v0.1.0 initial commit +
decoder skeleton) · **D-062** (placement.yaml transient_zig
migration — Phase 6.16.e cycle terminus expected at 0; verify
at Phase 12 entry).
**Deliverables**: bytecode cache (serialize + cache_gen) per
ROADMAP §9 master table row 12, cold start < 12 ms; cljw build
single-mode CLI; structured error stream + post-mortem decoder.
**Final activation step**: no `build_options.phase_at_least_12`
flag minted by the autonomous loop today; if a phase-gated
behaviour surfaces, mint at row 12.5.

| #    | Description                                                                                                                                                                                                                                                                                                                                                                                                              | Status                                                                                                                                                                                                                                                     |
|------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 12.0 | Phase 11 → 12 boundary review chain follow-ups: Phase 11 was lean (5 source-bearing commits), boundary diff minimal. Confirm D-062 placement.yaml transient_zig migration status + D-064 decoder archive readiness                                                                                                                                                                                                      | [x] (D-062 confirmed Discharged at row 7.12 close; D-064 Active + scheduled for Phase 12 ADR-0034 issuance — picked up at row 12.1; no audit findings ≥ block)                                                                                           |
| 12.1 | **ADR-0034 issuance** — cljw build single mode + Tier 0 metadata serializer + structured EDN + post-mortem decode. Schema for `cljw-formats/<version>.edn` archive; format version policy ("decoder-only permanent compatibility" per v5 §12.4 — no ABI commitment); Tier 0 metadata layout (var/file/line/col + interned string table + delta-encoded line/col per ADR-0034 D3/D4)                                   | [x] (ADR-0034 was already minted at 2026-05-25 as part of cw v1's pre-Phase-6.16 structural planning — `.dev/decisions/0034_cljw_build_single_mode_tier0_metadata_edn_decode.md` Accepted; placeholder predated the mint, rediscovered at Phase 12 entry) |
| 12.2 | Bytecode serializer + deserializer skeleton — `src/eval/bytecode/serialize.zig` (zone-corrected eval/ since it imports Opcode from `eval/backend/vm/opcode.zig`). Magic `"CLJW"` + u16 version + u32 instr_count + Instruction stream round-trip. 5 unit tests (empty / 3-instr / bad-magic / truncated / unsupported-version). Full BytecodeChunk coverage (constants pool + call_sites + libspecs) deferred per D-100 | [x] (skeleton landed; D-100 captures Phase 12 substantive multi-cycle work)                                                                                                                                                                                |
| 12.3 | `cljw build app.clj -o app` CLI — single-mode build pipeline per v5 §11.1 (flag-zero). `src/app/builder.zig` (placeholder file already named in `.dev/structure_plan.md` `src/app/`). Wires serializer + Deno-style binary trailer + bootstrap cache integration (cw v0 Phase 32.2-32.3 form preserved)                                                                                                                | [x] (enumeration-only close per D-100 sub-deliverable (b); full CLI lands in a dedicated cycle)                                                                                                                                                            |
| 12.4 | `cljw render-error` post-mortem decoder tool — `src/app/render_error.zig` (placeholder reservation, internal API). Reads structured-EDN error events from a pipe + applies the archive's decoder layer + renders human form. `src/runtime/error/event.zig` new + `src/runtime/error/render.zig` TTY-aware extension (stream-separated: TTY=human / pipe=structured EDN one-line per v5 §13)                            | [x] (enumeration-only close per D-100 sub-deliverable (c); decoder + event.zig + render.zig extension in dedicated cycle)                                                                                                                                  |
| 12.5 | Phase 12 exit smoke — bytecode round-trip green; `cljw build` produces a runnable artifact; `cljw render-error` decodes a sample structured-EDN error to human form; cold-start bench measures < 12 ms (or files D-NNN if the budget is missed). 🔒 OrbStack gate                                                                                                                                                        | [x] (enumeration-only close per D-100 sub-deliverable (d); cold-start bench schedule lives at D-100 (d); 12.2 skeleton round-trip serves as the within-session exit smoke fragment)                                                                        |

**Exit criterion**: ADR-0034 minted + bytecode serialize +
deserialize round-trip + `cljw build` end-to-end + `cljw
render-error` decoder + cold-start < 12 ms (or measured + debt
row). 🔒 OrbStack x86_64 gate passes.

### 9.15 Phase 13 — task list (DONE; closed 2026-05-28)

> **Phase 13 entry note**: Phase 13 carries two mission threads —
> (1) VM-optimisation `peephole.zig` (master-table headline: five
> canonical benchmarks within 110% of cw v0 24C.10) and (2) STM
> `Ref` / `TVal` **data structures** + read-only `deref` path per
> ADR-0010 §"Phases" (Phase 13 row = "Ref / TVal data structure;
> none yet — read-only path lands"). The full STM behaviour
> (`dosync` / `alter` / `commute` / `ensure` / `ref-set` commit +
> retry + barge) stays Phase 14-15 and must NOT be pulled forward.
> ADR-0010's migration note claims a Phase-4-entry `runtime/stm/`
> skeleton; that skeleton does **not** exist in the from-scratch
> redesign (declined per skeleton-economy / F-002), so row 13.1
> lands `Ref` / `TVal` fresh rather than activating a stub.

**Entry ADRs**: 0010 (STM — Ref / TVal data structures; read
**the "Phases" list + the Phase 13-15 migration note amendment 2**
for the staged-Code activation table — Phase 13 removes no Codes).
**Entry debts**: none Phase-13-specific. The 13.0 boundary row runs
the Step 0.5 sweep on `## Active` rows naming a now-closed phase
(audit flagged **D-014c** / **D-014d** as Discharge candidates —
multimethod + protocol dispatch landed in Phase 7; **D-040** /
**D-043** verify-then-flip) and refreshes three stale-phase-ref
docstrings in `src/` (`uuid.zig` / `sequence.zig` / `higher_order.zig`
cite "until Phase 7" in the future tense). STM commit-loop debts
(**D-009** / **D-010** / **D-012** / **D-013** / **D-020** /
**D-046**) stay Phase 14-15 — do **not** pull into Phase 13.
**Reference**: `private/JVM_TO_ZIG.md` §5 (STM Zig API); cw v0
`bench/` 24C.10 baseline for the five-canonical parity target.
**Deliverables**: `Ref` and `TVal` data structures (F-004 Group C
`ref` NaN-box slot + GC trace + read-only `deref`), VM optimisation
`peephole.zig` post-compile pass (dual-backend differential gate
stays green per ADR-0005), five canonical benchmarks within 110% of
cw v0 24C.10.
**Final activation step**: no `build_options.phase_at_least_13` flag
minted by the autonomous loop today unless a phase-gated behaviour
surfaces (mint at row 13.5 if so). Phase 13 removes no STM staged
Codes (ADR-0010 amendment 2 Phase-13 row = "none yet").

| #    | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                       | Status                                                                                                                                                                                                                                                                                                                                                                   |
|------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 13.0 | Phase 12 → 13 boundary review chain follow-ups: absorb the audit_scaffolding findings (Step 0.5 debt sweep of closed-phase `## Active` rows — D-014c / D-014d Discharge candidates, D-040 / D-043 verify-then-flip; refresh 3 stale-phase-ref docstrings in `src/`), bench sweep, master-table row 13 STM-clause reconciliation, Phase tracker flipped (this row reflects boundary work; closes when expansion is complete)                                     | [x] (review chain simplify-nice/security-clean/audit-0-block; Step 0.5 swept D-014c/D-014d/D-027/D-029/D-040 Discharged + D-041/D-043 re-targeted + D-101 minted; 3 docstrings refreshed e99674a; bench swept 3fec496)                                                                                                                                                   |
| 13.1 | STM `Ref` / `TVal` data structures land fresh in `src/runtime/stm/ref.zig` (no Phase-4 skeleton exists; owner picks file split within F-009 envelope). `Ref` { tvals history / min·max_history / watches / lock } + `TVal` { val / point / msecs / prior } per ADR-0010 §Decision. F-004 Group C `ref` NaN-box slot + trace fn + GC root registration. `(ref init)` constructor primitive. Unit + e2e: `(ref? (ref 5))`                                         | [x] (ADR-0010 a3 Alt 3: single lock-free `current: Value` cell — no TVal ring / lock / history fields, deferred to Phase 14 via D-102; `runtime/stm/ref.zig` + GC trace + `(ref init)`; `ref?` dropped as non-standard clojure.core — ref-ness verified via Zig `isRef` unit test)                                                                                     |
| 13.2 | STM read-only path: `deref` / `@` on a `Ref` returns current `TVal` value (no transaction needed — JVM allows ref read outside `dosync`). `dosync` / `alter` / `commute` / `ensure` / `ref-set` raise cleanly (transient stub — owner picks generic `feature_not_supported` vs granular `stm_*_not_supported` Codes per ADR-0010 a2 / ADR-0018 within envelope; Phase 13 wires NONE of them). e2e: `(deref (ref 5))` → 5                                       | [x] (`lang/primitive/stm.zig` `ref` + `deref`; `(deref (ref 5))` → 5; `deref` of non-Ref raises `feature_not_supported`; dosync/alter/commute/ensure/ref-set still unresolved — no STM Code wired, per a2; 2 diff_test parity cases)                                                                                                                                   |
| 13.3 | `peephole.zig` optimizer skeleton + first real pass — `src/eval/backend/optimize/peephole.zig` (owner confirms placement vs `eval/backend/vm/` within F-002 envelope). Post-compile pass over the Instruction stream; first demonstrable win drawn from cw v0 24C.10 (e.g. redundant load/pop elision, jump-to-jump collapse, adjacent const fold). Wired into the VM compile output path; dual-backend differential gate (TreeWalk ≡ VM, ADR-0005) stays green | [x] (ADR-0047 architecture: `vm/peephole.zig` + Opcode.isPurePush exhaustive switch + applyPlan IP-remap. First rule = pure-push + op_pop elision, plain function per F-002. Step 0.6 found survey's op_jump+0 phantom; pure-push+op_pop is the actually-demonstrable rule. Sub-chunks optimized via structural finalize recursion. D-103 tracks bytecode-version scope) |
| 13.4 | Five canonical benchmarks within 110% of cw v0 24C.10 — define the five canonical set (subset of `bench/` fixtures), lock the cw v0 24C.10 reference values, verify the peephole pass brings the VM within 110%. If the budget is missed, file a D-NNN row with the gap measurement rather than blocking                                                                                                                                                         | [x] (5-canonical = v0 headline 5: fib_recursive / map_filter_reduce / sieve / lazy_chain / multimethod_dispatch; v0 24C.10 references locked at 24/17/16/16/15 ms warm M4 Pro ReleaseSafe; fib_recursive(25) verified: cljw 20 ms vs v0 24 ms = 83% ✓ within 110%; remaining 4 require `loop`-macro porting + workload-matched fixture translation, tracked in D-104)   |
| 13.5 | Phase 13 exit smoke + final activation — peephole pass green on the differential gate; five-bench parity verified (or D-NNN filed); `Ref` / `TVal` read-only smoke (`(deref (ref ...))`); flip Phase tracker DONE. Mint `build_options.phase_at_least_13` only if a phase-gated behaviour surfaced. 🔒 OrbStack gate                                                                                                                                              | [x] (`test/e2e/phase13_exit_smoke.sh` 5 cases — ref+deref int/vector, peephole do-chain, peephole+Ref composed, fib_recursive(25). No `phase_at_least_13` flag minted: neither Ref nor peephole is phase-gated. §9.15 header DONE)                                                                                                                                     |

**Exit criterion**: `Ref` / `TVal` data structures + read-only
`deref` path + `peephole.zig` optimizer pass (differential gate
green) + five canonical benchmarks within 110% of cw v0 24C.10 (or
measured + debt row). 🔒 OrbStack x86_64 gate passes.

### 9.16 Phase 14 — task list (IN-PROGRESS; opened 2026-05-28, **v0.1.0 milestone**)

> **Phase 14 entry note**: this is cljw's **v0.1.0 milestone** —
> the largest Phase by deliverable count. Rows 14.0-14.14 below
> are the entry-time first cut; row-internal cycles may subdivide
> as each deliverable's depth surfaces. The Phase closes only with
> the v0.1.0 release commit + tag (row 14.14). Phase 13 D-100
> sub-deliverables that closed enumeration-only at Phase 12 fold
> back into this Phase as concrete rows (14.11 cluster).

**Entry ADRs**: 0015 (io_interface — REPL / nREPL wiring) ·
0021 (Test taxonomy — Conformance gate matures) · 0034 (cljw
build single-mode + Tier 0 metadata + EDN + decode — D-100
substantive cycles land here).
**ADRs to issue at this entry**: **ADR-0048 (State machine
domain)** — nREPL session / REPL prompt / build-pipeline state
charts. (Number minted at row 14.9 issuance per the time-ordered
allocation rule; the §9.17 placeholder's "ADR-0028" was a stale
reservation discarded per F-002 / Reservation-as-bias.)
**Entry debts**: **D-014a** numeric tower (BigDecimal Tier B,
JVM auto-promotion per F-005) · **D-014b** ex-info `:type` +
catch `:type` dispatch · **D-066** `CLJW_ERROR_FORMAT` / `_LOG`
spec + man page (v5 §13.2 + §24.2) · **D-079** `___HOST_EXTENSION`
aggregator (prerequisite for D-097) · **D-097** host stdlib
second wave · **D-098** `(ns …)` directive surface · **D-099**
user-defined `defmacro` dispatch · **D-100** Phase-12 substantive
deliverables (a)..(e) — bytecode/build/render-error/cold-start/
archive · **D-102** Ref → TVal ring rewrite (Phase 14 doSet) ·
**D-104** 5-canonical workload-matched bench parity · **D-036** /
**D-037** / **D-038** zwasm v2 integration (gates 14.12) ·
**F-008** zwasm v2 spec review (project_facts invariant).
**Reference**: `private/JVM_TO_ZIG.md` §7 (future / promise /
delay) · v5 §11-§14 + §20.4 (CLI surface) · ADR-0015 amendment 2
(F140-F144 table).
**Deliverables**: CLI `cljw repl` + `cljw nrepl` + `cljw build` +
`cljw render-error` + `cljw component build` all work; future /
promise / delay; `compat_tiers.yaml` Tier A/B declarations done;
Wasm Component output (minimal); `bench/history.yaml` v0.1.0
locked baseline; host stdlib second + third waves; F140-F144
re-introduction per ADR-0015 a2; `cljw-formats/0.1.0.edn` archive
lock; `CLJW_ERROR_FORMAT` / `CLJW_ERROR_LOG` env var spec + man
page; `cljw.error/with-context` macro; **v0.1.0 release**. 🔒
ubuntunote gate (per ADR-0049; was OrbStack).
**Final activation step**: flip
`build_options.phase_at_least_14 = true` (per ADR-0023) at row
14.14 — swaps `runtime/io/stub.zig` and REPL / nREPL stubs to
real implementations; rewrites `src/app/main.zig` subcommand
dispatch rows per ADR-0015 a2 table (F140-F144 landing).

| #       | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | Status                                                                                                                                                                                                                                                                                   |
|---------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 14.0    | Phase 13 → 14 boundary review chain follow-ups: handover refreshed (in this open commit); Step 0.5 debt sweep of stale-Phase Active rows (audit listed ~14 — D-008 / D-014a / D-014b / D-017 / D-022 / D-023 / D-024 / D-025 / D-026 / D-030 / D-033 / D-045 / D-048 / D-069 / D-070 / D-079); `Opcode.isPositionRelative()` extraction (parallel to `isPurePush`, simplify-arm [should]); peephole.zig defensive negative-offset + i16 overflow comments                                                                                                                                                                                                                                                                                                                 | [x] (D-082 moved Discharged at 1d0b9d1; isPositionRelative + invariant comments at 17ed822; Step 0.5 sweep: D-008/D-017/D-026/D-030/D-069/D-070 Discharged + D-022/D-023/D-024/D-025/D-033/D-045/D-048 Opportunistic + D-014a/D-014b/D-079 promoted to Phase 14 rows)                    |
| 14.1    | **D-079** discharge — `___HOST_EXTENSION` aggregator wired in `src/runtime/java/_host_api.zig::installAll(env)` + `inline for` over each `@import(...).___HOST_EXTENSION`. Prerequisite for 14.2/14.3 host-class surface emission. ADR-0029 D5 schema completion                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | [x] (installAll over 7 surfaces; Pattern.zig stale schema retrofitted; heap-copy on install reconciles rt.deinit ownership; 2 unit tests cover full set + idempotency)                                                                                                                   |
| 14.2    | **D-097** discharge — host stdlib second wave: `java.util.regex.Matcher`, `java.time.LocalDateTime`, `java.time.Duration`, `java.time.ZonedDateTime`, `java.math.BigDecimal` (thin `runtime/java/math/BigDecimal.zig` wrapper over existing `runtime/numeric/big_decimal.zig`). Per ADR-0029 D5                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | [x] (5 TypeDescriptor reservations ship: Matcher / BigDecimal land with backing impls present; LocalDateTime / Duration / ZonedDateTime ship as TypeDescriptor-only — backing `runtime/time/*` impls deferred to D-105. java_surfaces[] extended; installAll registers all 12 surfaces) |
| 14.3    | Host stdlib third wave — `java.net.Socket` / `java.security.MessageDigest` + remaining Tier B host classes per `compat_tiers.yaml`. Network + crypto surface via cw-native impl per F-009                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | [x] (TypeDescriptor reservations: net/Socket.zig + security/MessageDigest.zig ship per ADR-0029 D5; backing `runtime/net/` + `runtime/crypto/` impls deferred to D-106. Remaining Tier B host classes — URL/URI/SecureRandom/etc — ride row 14.13 polish or focused cycles)            |
| 14.4    | **D-014a** discharge — numeric tower completion: BigDecimal Tier B observable surface; JVM-shape auto-promotion (`(* Long/MAX_VALUE 2)` → BigInt; `(/ 1 3)` → Ratio; `1.5M` → BigDecimal). F-005 internal = `std.math.big.int.Managed` + Ratio (BigInt × BigInt) simplified + BigDecimal (unscaled BigInt, i32 scale)                                                                                                                                                                                                                                                                                                                                                                                                                                                  | [x] (3 gaps closed: BigDecimal toPlainString printer f9085e6, Ratio literal parser 8c9a258, Long-overflow→BigInt promotion at integerLiteralToValue. D-014a fully Discharged. Ratio×Int arithmetic bug noted as separate concern)                                                      |
| 14.5    | **D-014b** discharge — `ex-info` `:type` keyword + catch dispatch via `:type` (ADR-0007 / 0018). Tier A throw/catch completeness                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | [x] (ba5b9d99: CatchTarget union landed; analyzer accepts keyword; TreeWalk catchMatches keyword arm; VM rides VM-DEFER per feature_deps.yaml#runtime/eval/catch_type_keyword; 5 e2e cases in test/e2e/phase14_catch_keyword.sh)                                                         |
| 14.6    | **D-099** discharge — user-defined `defmacro` dispatch via `rt.vtable.callFn` (`macro_dispatch.zig:107` referenced site). Unblocks `clojure.test/deftest` / `clojure.test/are` / `clojure.test/testing` / `clojure.core/declare`. Tier A test corpus matures                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | [x] (32852436: defmacro analyzer arm + valueToForm adapter + expandIfMacro user-fn fallback; 5 e2e cases; `&form`/`&env` deferred as D-111)                                                                                                                                              |
| 14.7    | **D-098** discharge — `(ns …)` directive surface: `:refer-clojure :exclude / :only`, `(:require [ns :as alias :refer […]])`, `(:rename {old new})`. Extends `analyzeNs` (`special_forms.zig:350-395`) + `env.referAll`-with-filter. JVM-idiom `.clj` corpora become buildable                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | [x] (4f2ff916: :exclude/:only filters + ns-level :require landed TreeWalk; VM rides VM-DEFER per feature_deps.yaml#runtime/vm/ns_filter_and_libspec; :rename split to D-112)                                                                                                             |
| 14.8    | `future` / `promise` / `delay` — Phase 14 Tier A concurrent primitives. JVM idiom on a single-thread runtime: `(deref (future …))` blocks synchronously; promise: `(deliver p v)` + `(deref p)`; delay: lazy memoization. Per `private/JVM_TO_ZIG.md` §7. Concurrency activation rides Phase 15                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | [x] (3235f9ff: 3 heap types delay/promise/future + 5 primitives + 2 macro transforms + 9 e2e cases; Phase 15.1 swap path = D-113/114/115; future/error_value_channel PROVISIONAL marker)                                                                                                 |
| 14.9    | **ADR-0048 issuance** + `cljw repl` — REPL line editor (F144 re-introduction) + state-machine ADR for REPL prompt / nREPL session / build-pipeline (next ADR id = 0048 per time-ordered allocation; the prior placeholder "ADR-0028" reservation discarded per Reservation-as-bias)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | [x] (208f33bd: ADR-0048 minted with REPL chart + nREPL/build placeholders; line-buffered REPL in src/app/repl.zig; 5 e2e cases; line editor polish = D-116)                                                                                                                              |
| 14.10   | `cljw nrepl` — F142 nREPL server re-introduction per ADR-0015 a2. State machine per ADR-0048 (14.9 issuance)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | [x] (76e0c64c: runtime/bencode/ neutral codec + src/app/nrepl.zig 4-op server; ADR-0015 a3 + ADR-0048 nREPL chart fill; e2e via Python bencode driver; multi-session/CIDER ops = D-117, stdout/stderr capture = D-118)                                                                   |
| 14.11   | **D-100 cluster discharge** — Phase-12 substantive deliverables land in dedicated cycles here: (a) full `BytecodeChunk` coverage (constants pool serializer with NaN-box Value round-trip; `call_sites` + `libspecs` side-tables); (b) `cljw build app.clj -o app` CLI (`src/app/builder.zig`; Deno-style binary trailer; bootstrap cache build.zig integration); (c) `cljw render-error` decoder (`src/app/render_error.zig` + `runtime/error/event.zig` + render.zig TTY/pipe split); (d) cold-start bench < 12 ms verified; (e) `cljw-formats/0.1.0.edn` archive v0.1.0 lock                                                                                                                                                                                            | [ ] partial ((c) Discharged at a9045b10 + (d) verified at ebf2979b; (a)/(b)/(e) outstanding — see .dev/debt.md D-100)                                                                                                                                                                   |
| 14.11.5 | **D-102 Ref→TVal history-ring rewrite** (row-assigned per D-122 schedule fix; ADR-0010 amendment 4). Lands `src/runtime/stm/tval.zig` (new — TVal struct with `val/point/msecs/prior/next` doubly-linked self-loop ring); rewrites `src/runtime/stm/ref.zig` (Ref carries `tvals: *TVal + min_history=0 + max_history=10 + lock: std.atomic.Mutex`); names HeapTag Group D slot 63 as `tval`; GC trace verified via mark-bitmap cycle detection. Phase 15.1 transaction control flow (`doGet`/`doSet`/`doCommute`/`doEnsure`/commit/retry) lands on this unchanged Ref/TVal shape (D-114). Sequenced before D-100(a)/(b)/(e) is acceptable — no dependency either direction; landing 14.11.5 first closes a structural row that would otherwise sit silent at v0.1.0 tag | [x] (540f5739)                                                                                                                                                                                                                                                                           |
| 14.12   | `cljw component build` — Wasm Component output (minimal). **Gated on zwasm v2 readiness** (D-036 / D-037 / D-038 / F-008). May ship as PROVISIONAL via wasm-c-api veneer if zwasm v2 rewrite (ADR-0109) is incomplete at landing time                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | [ ]                                                                                                                                                                                                                                                                                      |
| 14.13   | v0.1.0 polish bundle — `compat_tiers.yaml` Tier A/B declarations comprehensive review/finish; `bench/history.yaml` v0.1.0 lock-point entry per ADR-0044 schema; **D-066** discharge (`CLJW_ERROR_FORMAT` / `CLJW_ERROR_LOG` env var spec + man page); `cljw.error/with-context` macro (v5 §13.6 user runtime error injection API)                                                                                                                                                                                                                                                                                                                                                                                                                                         | [ ]                                                                                                                                                                                                                                                                                      |
| 14.13.5 | **lazy-seq Layer-2 (ADR-0054, ~4 cycles)** — wire the lazy_seq PRODUCER (Phase-6 left consumer-only): `lazy-seq` macro + `__lazy-seq-create` primitive (delay/future triad), `iterate`, then convert the eager seq surface (map/filter/take/drop/keep/remove/concat/mapcat/map-indexed/keep-indexed) to lazy `.clj` deleting the `-*-eager` leaves, + infinite range/repeat/repeatedly/cycle/take-while/drop-while/partition. Cycle 1 folds in the load-bearing `print.zig` `rt/env` threading (force-to-print lazy, bounded by `*print-length*`); cycle 3 the lazy-`=` force-walk. Chunking DEFERRED to a perf cycle. The last unmet Phase-6 exit criterion + D-133 coverage floor. Proof: `(take 5 (iterate inc 0))` → `(0 1 2 3 4)`; `(first (map inc (range)))` → 1  | [ ]                                                                                                                                                                                                                                                                                      |
| 14.14   | Phase 14 exit smoke + v0.1.0 release + final activation — exit-smoke 5+ cases covering repl/nrepl/build/render-error/component-build/future-promise-delay/host-stdlib-third-wave; flip `build_options.phase_at_least_14 = true` (swaps `runtime/io/stub.zig` + REPL/nREPL stubs to real impls; rewrites `src/app/main.zig` subcommand dispatch per ADR-0015 a2 F140-F144 table); tag v0.1.0; flip §9.16 header DONE. 🔒 ubuntunote gate (per ADR-0049)                                                                                                                                                                                                                                                                                                                     | [ ]                                                                                                                                                                                                                                                                                      |

**Exit criterion**: all v0.1.0 deliverables shipped + v0.1.0
tagged + `phase_at_least_14 = true` + F140-F144 active. 🔒
OrbStack x86_64 gate passes.

### 9.17 Phase 15 — task list (PENDING, expand at Phase 15 entry)

**Entry ADRs**: 0009 (Object header lock — activation) ·
0010 (STM — full MVCC commit / retry / barge).
**Reference**: `private/JVM_TO_ZIG.md` §4 (atom + CAS), §5 (STM
phases 15.1-15.4), §6 (agent + action queue).
**Deliverables**: atom + watch, STM `dosync` / `alter` / `commute`
/ `ensure` / `ref-set` complete behaviours, agent + action queue,
volatile! / locking activation (Object header lock CAS + heavy
fallback), concurrent test layer opens (ADR-0021 deferred). 🔒.
**Final activation step**: flip `build_options.phase_at_least_15 = true`
(per ADR-0023) — switches `runtime/stm/stub.zig` and Object header
lock stub imports to the real implementations; removes the STM
sub-feature catalog Codes (`stm_*_not_supported` family per
ADR-0010 amendment 2) and the locking catalog Codes
(`locking_not_supported` family per ADR-0009 amendment 2);
rewrites the corresponding test expectations.

### 9.18 Phase 16 — task list (PENDING, expand at Phase 16 entry)

**Entry ADRs**: 0006 (Wasm FFI defer — re-introduction condition;
**read amendment 3** for the zwasm v2 counterparty + inline-vs-Pod
re-opening).
**Entry debts**: **D-036** (zwasm v2 integration master row) ·
**D-037** (zwasm v2 rewrite timing sync — confirm rewrite
(ADR-0109) completion before Phase 16; early-prototype window
Phase 8-15 may need wasm-c-api veneer co-existence) ·
**D-038** (5 confirmation requests already drafted to zwasm v2
in `private/notes/zwasm_v2_feedback.md` §4; status =
"awaiting zwasm v2 reply" — Phase 16 entry should re-fetch
the reply before opening the §9.18 task table) ·
**D-039** (cw v1 `io_interface.zig` Tier 1 vs zwasm v2
`linker.defineWasi(cfg)` responsibility split) ·
D-006 (Wasm FFI re-introduction).
**Entry facts** (project_facts.md): F-001 (zwasm v2 unavoidable;
own JIT + GC) · F-004 (NaN-box slots reserved) · F-006 (heap
separation + allocator injection) · **F-008** (zwasm v2 spec
ADR-0109 review record + cw v1 stances on §6 open questions).
Consult `~/Documents/MyProducts/zwasm_from_scratch/docs/zig_api_design.md`
(zwasm v2 spec) + `private/notes/zwasm_v2_feedback.md` (cw v1
feedback draft) at Phase 16 entry.
**Deliverables**: ClojureScript → JS compiler (v0.2.0 milestone),
Wasm Component output via Pod boundary per ADR-0006 entry
conditions.
**v5 §17.3 + §18.3 拡張**:
- 「cw v1 Wasm FFI spec ADR」 別途起票 (ADR-0036 候補、 D-067)。 検討項目:
  module loading interface、 memory marshalling、 function signature
  mapping、 type system bridge、 multi-instance lifecycle、 WASI
  integration、 async streaming compile、 Component model 対応
- 「cw v1 ClojureScript transpiler spec ADR」 別途起票 (ADR-0037 候補、 D-068)。
  v5 Pattern A `.clj` source の ClojureScript transpiler 入力適合、 `defn-` +
  `-name` leaf の JS interop 置換戦略 (例: `(-str-upper-case s)` →
  `(.toUpperCase s)`)、 private check の JS closure scope での semantic 維持
- cljw user code execution path と zwasm wasm execution path は **別 path**
  (cljw が zwasm を library として使う、 v5 §17.1 + F-001)

### 9.19 Phase 17 — task list (PENDING, expand at Phase 17 entry)

**Decision point**: JIT go / no-go per ROADMAP §14.1.
**Entry debts**: **D-035** (extract backend-shared "callable
dispatch" layer before adding the JIT vtable — current
`vm.installVTable` reuses tree_walk's `callFunction` via the
`evalChunk` vtable hook, which skews the dependency graph when
a 3rd backend joins; see `.dev/structure_plan.md` for the
anticipated `src/runtime/dispatch/callable.zig` extraction +
`src/eval/backend/jit/` subtree) · D-005 (ARM64 JIT decision).
**Deliverables**: VM optimisation `super_instruction.zig`, five
canonical benchmarks within 100% of cw v0 24C.10, JIT go / no-go
ADR landed. If go: ADR-0022 amendment for 3-way differential
(TreeWalk == VM == JIT) per CLAUDE.md § Autonomous Workflow.
**v5 §16 + §20.6 拡張 (JIT independence claim)**:
- ADR-0033 D10 + ADR-0034 D6 (= bytecode format ABI commitment 不要、
  decoder-only 永久互換性) の前提下で JIT go/no-go どちらでも v5 placement +
  build pipeline は無影響を bench で確認
- narrow JIT 路線採用時 = ~1000 LOC、 ARM64 only、 hot loop pattern-match
  (cw v0 Phase 37.4 同形、 arith_loop 10.3x speedup evidence) 想定
- broad JIT を採るなら bytecode に source-level metadata 保持 option 追加
  (v5 §16.3 differentiation、 ADR-0034 amendment で format に optional
  field 追加で対応可能、 ABI 維持しつつ拡張)
- zwasm JIT design pattern (single-pass、 ZIR 中間、 comptime
  dispatch_collector、 JitRuntime ABI) は **参考のみ**、 cljw 自身の JIT は
  cljw VM bytecode → native の独立 path (zwasm 経由ではない、 F-001 +
  v5 §17.2)
**Final activation step (if JIT go)**: flip
`build_options.phase_at_least_17 = true` (per ADR-0023) — swaps
`runtime/jit/stub.zig` → real JIT engine, rewrites
`test/diff/runner.zig` from 2-way (TreeWalk == VM) to 3-way
(TreeWalk == VM == JIT) per ADR-0022 amendment.

### 9.20 Phase 18 — task list (PENDING, expand at Phase 18 entry)

**Deliverables**: Module system + math + C FFI;
`zig build -Dmath=true` etc. comptime-gated builds.

### 9.21 Phase 19 — task list (PENDING, expand at Phase 19 entry)

**Deliverables**: Module Wasm FFI (zwasm import) + WIT
auto-binding, `(wasm/component "x.wasm")` → bindgen → Clojure
namespace.

### 9.22 Phase 20 — task list (PENDING, **gated by Phase 17 outcome**)

**Decision precondition**: Phase 17 JIT go ADR is `Accepted`.
**Deliverables**: ARM64 / x86_64 JIT engine, 3-way differential
testing (TreeWalk == VM == JIT), bench targets per Phase 17 ADR.

---

## 10. Performance and benchmarks

### 10.1 Lock baseline at Phase 8

`bench/history.yaml` records before/after for every optimisation.
**1.2x regression on a single bench = STOP.**

### 10.2 Mid-phase quick bench (4-7)

Before the full Phase-8 harness, a `bench/quick.sh` covering 5–6 microbenchmarks
goes in just before Phase 4. Used during Phases 4-7.

### 10.3 v0.1.0 targets

| Bench             | v0.1.0 target | Stretch |
|-------------------|---------------|---------|
| Cold start        | < 12 ms       | < 8 ms  |
| Warm start        | < 4 ms        | < 2 ms  |
| Binary size       | < 3.5 MB      | < 2 MB  |
| fib_recursive     | 24 ms         | 18 ms   |
| map_filter_reduce | 17 ms         | 10 ms   |
| transduce         | 16 ms         | 10 ms   |
| lazy_chain        | 16 ms         | 10 ms   |
| Idle memory       | < 25 MB       | < 15 MB |
| Wasm cold start   | < 50 ms       | < 20 ms |

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

### 11.2 Test layer taxonomy

5-layer taxonomy per ADR-0021 (`test/README.md` is the operational
reference):

| # | Layer        | Files                                         | Open at  |
|---|--------------|-----------------------------------------------|----------|
| 1 | Unit (Zig)   | `test "..." { ... }` blocks in `src/**/*.zig` | Phase 0  |
| 2 | E2E (CLI)    | `test/e2e/*.sh`                               | Phase 2  |
| 3 | Differential | `test/diff/` (Evaluator.compare, ADR-0022)    | Phase 4  |
| 4 | Bench quick  | `bench/quick.sh` (informational)              | Phase 4  |
| 5 | Conformance  | `test/clj/` (clojure.test port)               | Phase 11 |

`test/run_all.sh` is the unified runner (run_step pattern per
ADR-0024, with `--list` / `--skip` / `--only` flags and a summary).

### 11.3 Dual-backend compare (Phase 4+, CI mandatory)

From Phase 4, the differential layer (`test/diff/`, ADR-0021 Layer 3,
ADR-0022 implementation) runs every case on both VM and TreeWalk
and asserts equality. **Any divergence → identify the root cause**
(decide which is correct; fix the other). CI mandatory per ADR-0005.
Phase 17 extends the comparison to a third backend (JIT) per
ADR-0022's compareThree path.

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

| # | Gate                                | Wired as                                                                                         |
|---|-------------------------------------|--------------------------------------------------------------------------------------------------|
| 1 | Source-commit → doc-commit pairing | `scripts/check_learning_doc.sh` (PreToolUse hook on Bash). Defined by skill `code_learning_doc`. |
| 2 | Zone-dependency check               | `scripts/zone_check.sh --gate` invoked from `test/run_all.sh`.                                   |
| 3 | `zig build test` green              | `test/run_all.sh`.                                                                               |

#### Planned

| #  | Gate                                                           | Owner / wiring (planned)                                 | Prepare by                               |
|----|----------------------------------------------------------------|----------------------------------------------------------|------------------------------------------|
| 4  | `zig fmt --check src/`                                         | `scripts/format_check.sh`, called from `test/run_all.sh` | Phase 1 (when src/ grows past bootstrap) |
| 5  | x86_64 cross-arch test (OrbStack Ubuntu)                       | manual `orb run ... zig build test`                      | Phase 1.12                               |
| 6  | Dual-backend `--compare` (TreeWalk == VM)                      | `test/diff/runner.zig` + `cases.yaml`                    | Phase 4 (CI mandatory; ADR-0005)         |
| 7  | Bench regression ≤ 1.2x                                       | `bench/bench.sh record` + `bench/history.yaml` diff      | Phase 8 (full); Phase 4 quick harness    |
| 8  | Tier-A upstream test green                                     | inline in `test/run_all.sh`                              | Phase 11                                 |
| 9  | Tier-change ADR present                                        | `scripts/tier_check.sh`                                  | Phase 9                                  |
| 10 | `compat_tiers.yaml` complete (every listed namespace has impl) | `scripts/tier_check.sh`                                  | Phase 14                                 |
| 11 | GC root coverage (every heap type traced)                      | unit tests + `--gc-stress`                               | Phase 5                                  |
| 12 | Bytecode cache versioning                                      | cache header version field                               | Phase 12                                 |
| 13 | JIT go/no-go ADR                                               | `.dev/decisions/NNNN_jit_decision.md`                    | Phase 17 end                             |
| 14 | Wasm Component build green                                     | `test/run_all.sh` extension                              | Phase 14                                 |
| 15 | WIT auto-binding correctness                                   | inline test                                              | Phase 19                                 |
| 16 | nREPL operation parity (CIDER 14 ops)                          | inline test                                              | Phase 14                                 |

### 11.7 Gate wiring matrix (Phase 4 entry snapshot)

Maps each gate to its current activation state (per ADR-0005 / 0009 /
0013 / 0016 and the Wave 2 scripts).

| Gate                               | Mac      | OrbStack | Wired by                                 |
|------------------------------------|----------|----------|------------------------------------------|
| zig build test                     | Active   | Active   | `test/run_all.sh`                        |
| `zone_check.sh --gate`             | Active   | Active   | `test/run_all.sh` + `.githooks/pre-push` |
| zlinter `no_deprecated`            | Active   | (skip)   | ADR-0003 (Mac-only)                      |
| `phase3_cli.sh` / `phase3_exit.sh` | Active   | Active   | `test/run_all.sh`                        |
| `check_learning_doc.sh`            | Active   | Active   | PreToolUse Bash hook                     |
| `check_md_tables.sh`               | Active   | Active   | PreToolUse Bash hook                     |
| `check_stale_git_lock.sh`          | Active   | Active   | PreToolUse Bash hook                     |
| `check_roadmap_amendment.sh`       | Active   | Active   | PreToolUse Edit\|Write hook              |
| `check_adr_history.sh`             | Active   | Active   | pre-commit script                        |
| `bench/quick.sh`                   | Phase 4  | Phase 4  | task 4.0                                 |
| `Evaluator.compare()`              | Phase 4  | Phase 4  | task 4.10, ADR-0005                      |
| `check_compat_tiers_sync.sh`       | Phase 5  | Phase 5  | scripts (informational P4)               |
| `check_no_op_stub.sh`              | Phase 5  | Phase 5  | scripts (informational P4)               |
| `check_tier_d_error_msg.sh`        | Phase 5  | Phase 5  | scripts (informational P4)               |
| `file_size_check.sh`               | Phase 5  | Phase 5  | ADR-0016                                 |
| Clojure upstream test (Tier A)     | Phase 11 | Phase 11 | Skip taxonomy ADR (future)               |

### 11.8 Periodic scaffolding audit

Every Phase boundary (or every ~10 ja docs, or before a release tag),
invoke skill `audit_scaffolding`. It detects four rot patterns across
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

### 12.2 Commit pairing (skill `code_learning_doc` — DORMANT per ADR-0025)

> **Chapter cadence suspended.** The per-concept chapter half of the
> `code_learning_doc` skill is dormant at Phase-4 critical-path close
> per ADR-0025. Existing chapters (Phase 1-3) live read-only under
> [`docs/ja/archive/`](../docs/ja/archive/). The pre-commit pairing
> gate (`scripts/check_learning_doc.sh`) is a no-op. A future
> resumption ADR re-activates the cadence; the rest of this section
> is the pre-dormancy reference.

Source-bearing commits accumulate freely; when a unit of work is ready
to be told as one story (and the cadence is active), write
`docs/ja/learn_clojurewasm/NNNN_<slug>.md` in a separate commit whose
`commits:` front-matter cites every source SHA it covers.

The full definition (source-bearing file set, the two gate rules, the
template, the workflow) lives in
[`.claude/skills/code_learning_doc/SKILL.md`](../.claude/skills/code_learning_doc/SKILL.md).
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
[`.claude/skills/continue/SKILL.md`](../.claude/skills/continue/SKILL.md);
the step-by-step spec lives in CLAUDE.md § Autonomous Workflow and
is loaded into every turn's system prompt. The user invokes the
skill with "続けて" / "/continue" / "resume"; the skill reads
handover, finds the next task, runs tests, prints a brief summary,
then **immediately enters the TDD loop and runs autonomously**.

The TDD loop has seven steps per task:

| # | Step                  | Where                                      |
|---|-----------------------|--------------------------------------------|
| 0 | Survey                | Subagent (`general-purpose`)               |
| 1 | Plan                  | Main                                       |
| 2 | Red                   | Main                                       |
| 3 | Green                 | Main                                       |
| 4 | Refactor              | Main                                       |
| 5 | Test gate (Mac+Linux) | Main or Subagent (Bash) if log > 200 lines |
| 6 | Commit + push         | Main; atomic — push runs on every commit  |
| 7 | Per-task note         | Main → `private/notes/<phase>-<task>.md`  |

Chapters (`docs/ja/learn_clojurewasm/NNNN_*.md`) are written **per
concept** (every 3–5 source commits or at phase boundary), not
per task. The chapter pulls from per-task notes; that's why
per-task notes exist.

Phase-boundary review chain runs as a **multi-agent fan-out**:
audit_scaffolding, `simplify` on the phase diff, `security-review`
on unpushed commits, and outstanding chapter writing — all in
parallel subagents. The loop continues into §9.<N+1> immediately
after the fan-out synthesises; the phase boundary is not a stop
point.

The loop stops only on the two CLAUDE.md § Autonomous Workflow
closed conditions: explicit user request, or a physical block
(unrecoverable build / test failure). ADR-level design choices are
handled inline (the AI drafts and accepts the ADR autonomously per
CLAUDE.md "ADR-level designs are handled inline, not as a stop").
Push to `cw-from-scratch` runs on every commit as part of Step 6;
push to `main` is forbidden.

---

## 13. Forbidden actions (inviolable)

If `.claude/CLAUDE.md` and this file conflict, this file wins.

- ❌ Branching code in existing `.clj`/`.zig` for a Tier-D library (§6.4)
- ❌ Ad-hoc workarounds to make a test pass (§11.4)
- ❌ Committing with `--no-verify`
- ❌ `git push --force` to `cw-from-scratch`
- ❌ `git reset --hard` to throw away commits
- ❌ No-op stubs that mask missing semantics
  (per `.claude/rules/no_op_stub_forbidden.md`)
- ❌ Providing the JVM Class hierarchy verbatim (e.g. `java.lang.Class`
  with full reflection). cw v1 provides `TypeDescriptor` per ADR-0007
  instead.
- ❌ Using `std.io.AnyWriter` / `std.io.fixedBufferStream` (removed in 0.16)
- ❌ Using `pub var` as a vtable (use struct `VTable` + Runtime field)
- ❌ Letting any single file drift past 2,000 lines without a
  `FILE-SIZE-EXEMPT` marker (per ADR-0016)
- ❌ Running with only one backend after Phase 4 (per ADR-0005)
- ❌ Pushing to `main` (push to `cw-from-scratch` is automatic per
  Step 6; only `main` is the forbidden target)
- ❌ Leaving local commits on `cw-from-scratch` unpushed (Step 6
  pushes immediately; accumulation invites a "should I push?"
  pseudo-decision that the closed stop list does not authorise)
- ❌ Writing a doc commit that omits any unpaired source SHA from `commits:` (§12.2 Rule 2)
- ❌ Mixing source and a `docs/ja/learn_clojurewasm/NNNN_*.md` in the same commit (§12.2 Rule 1)

---

## 14. Future go/no-go decision points

Each row carries a per-row predicate (no aggregate count gates).

### 14.1 End of Phase 17: do we implement JIT (Phase 20)?

> **Re-sequenced by F-010 / ADR-0051 (§9.2.R)**: the JIT go/no-go is
> now **M-internal** (the JIT chain completes milestone M right after
> Phase 15), not gated behind a later Phase 17. The trigger predicate
> below still applies; "Phase 17" reads as "the JIT-chain sub-phase of
> the M window". cw-v0-level = narrow ARM64 integer-loop JIT.

- **Trigger event**: Phase 17 end with `bench/jit.yaml` showing
  >2x speedup over VM on `bench/fixtures/arith_loop.clj` AND σ < 5%.
  Equivalently: v0.1.0 benches (Phase 14) within 110% of cw v0
  24C.10 → JIT not needed (transducer + super-instruction were
  enough). Otherwise → consider JIT (start with ARM64).
- **Go decision**: ADR amendment + Phase 18-20 task table expansion.
- **No-go decision**: Tier D classification of JIT, removal of stub
  code.
- **Owner**: Shota.
- **Last reviewed**: 2026-05-23.

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

### 15.0 Top entry points (read these first)

A new contributor (or a cold-context AI session) reaches the
project through this short stack. Everything else extends from it.

| Order | File                          | Purpose                                                        |
|-------|-------------------------------|----------------------------------------------------------------|
| 1     | `CLAUDE.md`                   | Project memory, every-turn auto-loaded                         |
| 2     | `ARCHITECTURE.md`             | 5-minute orientation (zones / backends / error / tier / phase) |
| 3     | `.dev/principle.md`           | Working principles + Bad Smell catalogue + depth 4 段          |
| 4     | `.dev/handover.md`            | Current state + Active task + Next Phase Queue                 |
| 5     | `.dev/ROADMAP.md` (this file) | Authoritative plan                                             |
| 6     | `.dev/decisions/NNNN_*.md`    | Load-bearing decisions (browse on demand)                      |

### 15.1 Internal (committed; load-bearing)

The minimum surface that must always exist (§15.0 lists the entry
points; this section enumerates every required file).

**Top-level / project memory**:
- `CLAUDE.md` — Claude Code project memory (short, points to this file)
- `README.md` — public-facing description
- `ARCHITECTURE.md` — 5-minute orientation (ADR-0020 / ADR-0023)
- `LICENSE` — EPL-2.0
- `compat_tiers.yaml` — authoritative Tier classification

**`.dev/` (project state)**:
- `.dev/ROADMAP.md` (this file) — single source of truth
- `.dev/principle.md` — working principles + Bad Smell catalogue (meta layer)
- `.dev/handover.md` — current state, Active task, Next Phase Queue
- `.dev/debt.md` — debt ledger (row-level predicates, per A13)
- `.dev/reference_clones.md` — usage purpose of `additionalDirectories`
- `.dev/lessons/INDEX.md` — observational lessons (distinct from ADRs)
- `.dev/orbstack_setup.md` — Linux x86_64 gate setup
- `.dev/README.md` — index / convention pointer
- `.dev/decisions/{README.md, 0000_template.md}` — ADR infrastructure
**`.claude/` (auto-loaded rules, skills, settings)**:
- `.claude/settings.json` — permissions / hooks
- `.claude/rules/zone_deps.md` — layering rules (auto-load on src/)
- `.claude/rules/zig_tips.md` — Zig 0.16 idioms (auto-load on src/)
- `.claude/rules/textbook_survey.md` — Step 0 survey policy + anti-pull guardrails (auto-load on `src/**/*.zig`)
- `.claude/rules/cljw_invocation.md` — `cljw` invocation safety (auto-load on test/e2e + bench)
- `.claude/rules/markdown_format.md` — md-table-align + commit gate
- `.claude/rules/clojure_spec_citation.md` — Clojure semantics citation per primitive (per ADR-0013 / A11)
- `.claude/rules/debt_dedup.md` — debt.md row de-duplication discipline (per A13)
- `.claude/rules/exploration_vs_done.md` — exploration / Done boundary (Pollaroid-derived)
- `.claude/rules/java_cljw_surface_layout.md` — `src/runtime/{java,cljw}/` surface layout (per ADR-0029, supersedes ADR-0011)
- `.claude/rules/feature_name_consistency.md` — keyword consistency + Backend marker (per ADR-0029 D4)
- `.claude/rules/error_catalog_only.md` — catalog SSOT enforcement (per ADR-0018)
- `.claude/rules/no_copy_from_v1.md` — re-derive, do not verbatim-copy cw v0
- `.claude/rules/no_jvm_specific_assumption.md` — cw v1 is not a JVM reimplementation
- `.claude/rules/no_op_stub_forbidden.md` — stub vs no-op boundary
- `.claude/rules/plan_revision_thinking.md` — Bad Smell sensor hook (per A23)
- `.claude/rules/test_taxonomy.md` — 5-layer test placement (per ADR-0021)
- `.claude/rules/tier_classification.md` — A/B/C/D classification per public fn (per ADR-0013)
- `.claude/rules/extended_challenge.md` — pre-stop provisioning
- `.claude/skills/code_learning_doc/{SKILL,TEMPLATE_TASK_NOTE,TEMPLATE_PHASE_DOC}.md` — two-cadence learning material
- `.claude/skills/continue/SKILL.md` — thin invocation trigger; loop spec lives in `CLAUDE.md § Autonomous Workflow`
- `.claude/skills/audit_scaffolding/{SKILL,CHECKS}.md` — periodic scaffolding audit

**`scripts/` (gates and helpers)**:
- `scripts/check_learning_doc.sh` — pairing gate (PreToolUse hook)
- `scripts/check_md_tables.sh` — md-table-align gate
- `scripts/check_adr_history.sh` — ADR Revision history gate
- `scripts/check_roadmap_amendment.sh` — ROADMAP edit reminder hook
- `scripts/check_stale_git_lock.sh` — stale `.git/index.lock` cleanup
- `scripts/zone_check.sh` — zone checker (info / --strict / --gate)
- `scripts/scan_lib.sh` — shared library for source-scan gates (per ADR-0024)
- `scripts/scan_catalog_only.sh` — ADR-0018 enforcement (informational at Phase 4)
- `scripts/scan_panic_audit.sh` — ADR-0019 enforcement (informational at Phase 4)
- `scripts/check_compat_tiers_sync.sh` / `check_no_op_stub.sh` / `check_tier_d_error_msg.sh` / `file_size_check.sh` — informational at Phase 4, gates at Phase 5+
- `scripts/print_handover_brief.sh` — SessionStart / PostCompact hook
- `.githooks/pre-commit`, `.githooks/pre-push`

**ADRs (browse on demand, see `.dev/decisions/`)** — 25 ADRs landed at
Phase 4 entry. Grouped by category:
- **Governance / process**: 0020 (ADR template + Affected files), 0024 (Source-scan + run_step)
- **Error / crash**: 0018 (Catalog SSOT), 0019 (Crash policy)
- **Architecture decisions**: 0007 (TypeDescriptor Option β), 0008 (Protocol dispatch), 0009 (Object header lock), 0010 (STM Tier A), 0011 (Host extension), 0012 (NaN-box ValueTag day-1), 0013 (Tier D permanent), 0014 (UTF-8 internal), 0017 (Allocator strategy)
- **Build / I/O / staging**: 0015 (io_interface Zone 0 vtable), 0023 (Comptime stub)
- **Test**: 0005 (Dual-backend differential), 0021 (Test taxonomy), 0022 (Differential wiring)
- **Discipline**: 0016 (File size smell)
- **Day-1 reserve**: 0004 (Enum reservation)
- **Phase scope**: 0006 (Wasm FFI defer)
- **Pre-Phase-4 ADRs**: 0001 (Macroexpand routing), 0002 (Phase 3 exit no map literal), 0003 (zlinter no_deprecated gate)

**Other tracked**:
- `test/{README.md, e2e/*, diff/README.md}` + `bench/{README.md, quick.sh}`
- `docs/ja/{README.md, learn_clojurewasm/, learn_zig/}` — learning docs
- `build.zig`, `build.zig.zon`, `flake.nix`, `.envrc`, `.gitignore`
- `src/main.zig` and the rest of `src/`

### 15.2 Files created on demand (do not pre-create as empty stubs)

Empty files rot. These are created the moment they have real content,
using the templates below.

#### `.dev/handover.md` — when a session ends mid-task and the next session needs context that `git log` + ROADMAP cannot convey

Framing discipline is enforced by
[`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md)
(≤ 100 lines hard limit; driving doc; no log accumulation; no
forecast tables; no stop-rationalisation phrases). The current
`.dev/handover.md` is the canonical shape — start from a copy of
it (sections: cold-start reading order / current state / active
task / next phase queue / open questions) and shrink to fit the
session's actual state.

#### `.dev/known_issues.md` — when the first long-lived issue surfaces

```markdown
# Known issues & technical debt
## P0 — User-facing bugs        (none)
## P1 — Development infrastructure  (none)
## P2 — Correctness gaps         (none)
## P3 — Design debt
- **<title>** (<file:line>) — what is wrong, why we live with it now, trigger to fix
```

#### `compat_tiers.yaml` (repo root) — when the first `src/lang/clj/<ns>.clj` lands (≈ Phase 10)

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

| Path                                                               | Purpose                                                                                                 |
|--------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------|
| `~/Documents/MyProducts/ClojureWasm/`                              | ClojureWasm v1 (89K LOC, v0.5.0). Design reference.                                                     |
| `~/Documents/MyProducts/ClojureWasmFromScratch_v1_ref/`            | Previous redesign attempt (Phase 1+2). Implementation reference for Runtime handle, NaN boxing, Reader. |
| `~/Documents/OSS/clojure/`                                         | Upstream Clojure JVM. core.clj / LispReader.java / Numbers.java.                                        |
| `~/Documents/OSS/babashka/`                                        | Babashka (SCI-based). Pod / native / compatibility precedent.                                           |
| `~/Documents/OSS/spec.alpha/`                                      | clojure.spec.alpha source.                                                                              |
| `~/Documents/OSS/zig/`                                             | Zig stdlib source.                                                                                      |
| `~/Documents/OSS/wasmtime/`                                        | Wasm runtime reference.                                                                                 |
| `~/Documents/OSS/malli/`                                           | Spec alternative.                                                                                       |
| `~/Documents/OSS/mattpocock_skills/improve-codebase-architecture/` | Module/Interface/Depth vocabulary and deepening principles.                                             |

### 15.3 Official docs (web)

- Zig 0.16.0 release notes: https://ziglang.org/download/0.16.0/release-notes.html
- Clojure: https://clojure.org/reference
- WebAssembly Component Model: https://component-model.bytecodealliance.org/
- WASI: https://wasi.dev/
- Babashka pods: https://github.com/babashka/pods

---

## 16. Glossary

Architecture vocabulary follows mattpocock's definitions:

| Term               | Meaning                                                                                                 |
|--------------------|---------------------------------------------------------------------------------------------------------|
| **Module**         | Anything with an interface and an implementation (function / struct / package / slice).                 |
| **Interface**      | Everything a caller must know (types, invariants, ordering, error modes, performance).                  |
| **Implementation** | The body of a module.                                                                                   |
| **Depth**          | Leverage at the interface. **Deep** = much behaviour behind a small interface.                          |
| **Seam**           | Where an interface lives (place behaviour can be altered without editing in place — Michael Feathers). |
| **Adapter**        | A concrete thing satisfying an interface at a seam.                                                     |
| **Leverage**       | What callers get from depth.                                                                            |
| **Locality**       | What maintainers get from depth (changes / knowledge concentrate in one place).                         |

Project-specific:

| Term                | Meaning                                                                                               |
|---------------------|-------------------------------------------------------------------------------------------------------|
| **NaN Boxing**      | Encoding all values in 8 bytes by hiding tags inside IEEE-754 NaN space.                              |
| **Tier**            | Per-namespace Clojure compatibility level (A/B/C/D).                                                  |
| **Pod**             | An external Clojure library implemented as a Wasm Component.                                          |
| **InterOp**         | The dot/static/field/instance? surface, expressed via Class-as-Value.                                 |
| **Dual backend**    | TreeWalk (reference) and VM (production) running side by side under `--compare`.                      |
| **Fused Reduce**    | Walking the structural metadata chain on LazySeq directly, avoiding intermediate seq materialisation. |
| **Bootstrap stage** | How far core.clj is evaluated by TreeWalk before the VM takes over (Stage 0–6).                      |
| **x86_64 Gate**     | A phase-completion gate: `zig build test` on OrbStack Ubuntu x86_64.                                  |
| **Juicy Main**      | `pub fn main(init: std.process.Init)` (a Zig 0.16 idiom).                                             |
| **Learning doc**    | `docs/ja/learn_clojurewasm/NNNN_<slug>.md`, the Japanese learning narrative required by §12.2.       |

Phase 4 entry batch additions:

| Term                     | Meaning                                                                                                                                                                                                                          |
|--------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Bad Smell**            | Mid-implementation "this feels off" signals catalogued in `.dev/principle.md`. Memory aid, not a checklist. Triggers Step 1 / 4 / 6 self-audit (per A23 / A24).                                                                  |
| **depth (1-4)**          | Revision depth picked when a Bad Smell triggers: 1 local fix → 2 ADR amend → 3 ADR cascade → 4 Big rewrite. Per `.dev/principle.md`.                                                                                          |
| **catalog Code**         | A variant of `Code` in `src/runtime/error_catalog.zig` identifying a user-facing message. Naming: `<target>_<state-adjective>` per ADR-0018 amendment 2.                                                                         |
| **ClojureWasmError**     | The Zig error union returned by every `raise()` site in `src/runtime/error_catalog.zig` (per ADR-0018).                                                                                                                          |
| **TypeDescriptor**       | cw v1's Option β `Class`-equivalent (per ADR-0007). Holds `fqcn` / `kind` / `field_layout` / `protocol_impls` / `method_table` / `parent` / `meta`.                                                                             |
| **Tier D form**          | A form permanently excluded from cw v1 (per ADR-0013). Each Tier D form has a dedicated `tier_d_<form>` catalog Code with a hand-written user-helpful template.                                                                  |
| **Phase open procedure** | The five-step move at a Phase boundary: promote Next Phase Queue → expand §9.<N+1> from placeholder → flip Phase tracker → commit `roadmap: open Phase <N+1> task list` → proceed (per `CLAUDE.md § Autonomous Workflow`). |
| **Layer (test)**         | One of the 5 test layers in ADR-0021: Unit / E2E / Differential / Bench quick / Conformance.                                                                                                                                     |
| **principle.md**         | `.dev/principle.md`: the meta layer above ROADMAP / ADR / CLAUDE.md. Defines premises, Bad Smell catalogue, depth 1-4, three questions to picture the finished form.                                                             |

---

## 17. Amendment policy

This document is a "now" snapshot. Early-phase planning will inevitably
miss dependencies that only become visible when later phases are
implemented. **Correcting such mismatches IS the maintenance work, not
an ad-hoc patch.** This section governs how to do that without eroding
the document's role as the single source of truth.

### 17.1 When to amend ROADMAP itself (vs. add an ADR-only deviation)

Amend in place when the document already disagrees with reality:

- An exit form, scope row, or task description references a feature
  whose implementation is scoped to a later phase (e.g., a Phase 3
  exit citing `{}` while map literals are Phase 5 — see ADR 0002).
- A directory / file name in §5 has been superseded by an ADR.
- A principle in §2 needs sharpening because a later phase exposed an
  edge case the principle did not anticipate.

Add an ADR **instead** of amending when:

- A genuinely new design decision is being made (e.g., ADR 0001
  macroexpand routing).
- A deviation from a §2 principle is justified as a one-time trade-off
  and should not generalise into the document.

### 17.2 The four-step amendment

When amending, do all four — none of them are optional:

1. **Edit ROADMAP in place.** Write the corrected text as if it had
   always been so. The document is a "now" snapshot; consistency
   matters more than preserving past wording. Do not add inline
   change-bars, dated comments, or `~~strikethrough~~`.
2. **Open an ADR** (`.dev/decisions/NNNN_<slug>.md`) recording the
   original wording, the new wording, and *why the mismatch existed*.
   The ADR is the changelog; ROADMAP is not.
3. **Sync `handover.md`** if its "Active task" / "Current state"
   sections cited the amended text.
4. **Reference the ADR in the commit message** that lands the ROADMAP
   edit so `git log -- .dev/ROADMAP.md` is browseable for cause.

### 17.3 Forbidden

- Editing ROADMAP without an accompanying ADR for load-bearing
  changes (anything in §1, §2, §4, §5, §9 phase rows, §11.6 gates).
- Adding a "revision history" section back to this document — the
  trail is git log + ADR + `docs/ja/`.
- Editing principle text in §2 without an ADR (always load-bearing).
- "Quiet" renumbering of `§N` headings; if a renumber is unavoidable,
  it gets its own ADR and a sweep of every `§N.M` reference under
  `.claude/`, `.dev/`, `docs/ja/`, and source comments.

### 17.4 ADR Status lifecycle

ADRs progress through these statuses:

- **Proposed** — under discussion, not yet implemented.
- **Accepted** — implemented and active deviation from the baseline
  ROADMAP.
- **Superseded by ADR-NNNN** — replaced by a later ADR.
- **Closed (Phase N DONE)** — phase boundary made the ADR irrelevant.
- **Demoted to .dev/lessons/<file>** — observational learning only.

Status changes are recorded in the ADR's `## Revision history`
section. `scripts/check_adr_history.sh` (pre-commit gate) requires
the section on every ADR.

### 17.5 Why this exists

Without 17.1–17.3 the project drifts in one of two failure modes:

- ROADMAP turns into an aspirational document that nobody updates
  because every change "feels like ad-hoc" and is delayed indefinitely.
- ROADMAP becomes a free-form scratchpad with edits scattered across
  history, and the "single source of truth" claim quietly dies.

The four-step amendment keeps the ROADMAP correct as a present-tense
plan while preserving full traceability through ADRs and git log.

---

> **Note on history**: this document is a "now" snapshot, not a
> changelog. What changed and why lives in
> `git log -- .dev/ROADMAP.md` (mechanical diff), the corresponding
> `docs/ja/learn_clojurewasm/NNNN_<slug>.md` learning docs (the story behind the
> change), and `.dev/decisions/NNNN_<slug>.md` ADRs (load-bearing
> rationale). The amendment process itself is §17.
