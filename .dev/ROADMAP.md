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

| # | Axis                               | Edge over the field                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
|---|------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1 | **Edge-native Clojure**            | Babashka is native but produces no Wasm. SCI is JS-only. v2 makes Wasm Component a first-class output.                                                                                                                                                                                                                                                                                                                                                              |
| 2 | **Wasm-native interop**            | `require` a Wasm **component** as a Clojure ns (finished form: **ADR-0135** + **Amendment 1**, 2026-06-21 user-directed — `(:require ["x.wasm" :as x])`, resolution order, type leverage, single-binary embed **ADR-0158**, always-latest **F-016**). **ACTIVE epic = D-404** (blocker dissolved; phases A ns-`:require` wiring → B resolution → C types → D single-binary → E resource/registry). Inversely, expose Clojure functions as WIT exports (later). |
| 3 | **Comprehensible runtime**         | Codebase is small enough to be read end-to-end. Each phase ships a written walkthrough.                                                                                                                                                                                                                                                                                                                                                                             |
| 4 | **Zig-level optimisation ceiling** | The *meta*-differentiator. Babashka rides GraalVM, clj rides the JVM: to make a hot path fast you must work *within* the host's object model / bytecode / GC. cljw is Zig from the metal up, so any primitive can be rewritten / fused / comptime-specialised (NaN-box, superinstructions, D-133 JIT) as a **Zig PR, not a host-engineering project** — a higher optimisation ceiling than any JVM-bound Clojure, provable per-workload.                           |

**Axis 2 is the north star** (ADR-0099 / **ADR-0135**): WebAssembly component as
a first-class namespace — the analogue of clj↔Java / cljs↔JS / cljd↔Dart, but
cleaner. Among the four dialects only cljw's host binding is a *language-neutral,
spec-defined, self-describing* contract (no `.wit` sidecar; the component binary
embeds its own interface types), not a single vendor's runtime.

**Compatibility is the adoption table-stakes, not a second-class chore.** A
processor only gets used if real Clojure assets run on it; the down-and-dirty
"make existing libraries work" grind is first-class work, and discovering that
upstream *core* features were indirectly broken is itself valuable. Binary size
& speed are deliberately deferrable — the foundation is already small/fast and
tunable later by a concentrated comptime/JIT campaign (§10, D-133); the only
discipline is to keep the hot paths clean while the compat grind adds slow-OK
`.clj` wrappers over fast Zig primitives.

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

### 1.5 Working strategy (post-M / day-to-day operating mode)

How the differentiation (§1.2) and compatibility are pursued in practice, so a
fresh session re-recognises the *direction*, not just the next task. Three
standing tracks run in parallel; none is a one-time phase.

1. **Compat grind, made systematic + measured (not reactive).** The 2026-06-12
   finding: *function-level* triage (load a real lib, run its core functions,
   diff vs the `clj` oracle) is strictly more productive than load-only triage
   — it found `data.json`/`pprint` core gaps that load-triage missed. So the
   grind gets a **standing library-conformance harness** (D-405): a corpus of
   "load lib → exercise its functions → diff vs clj", reported as a coverage
   number + worklist, so "what real Clojure code still does not run" is a
   measured, converging metric rather than an accidental discovery. Host-frontier
   gaps (`clojure.lang.*` markers, reflection, `Compiler`, JVM internals) are
   cleared **big-bang** (not drip-feed, the Micro-coverage-grind smell) and the
   **language-feature ↔ Tier-D boundary is documented as it is hit** (D-406):
   deftype implementing a `clojure.lang.*` interface = a language feature;
   reflection / bytecode generation = Tier D (cljw-native alternative). Drawing
   that line is what makes "Clojure assets run as-is" *converge* instead of being
   an unbounded treadmill.

2. **Differentiation as a *standing proof*, not a future campaign.** The edges
   are already structurally present (§1.2) — the work is to *prove them
   continuously*, cheaply: (a) one "fast Zig primitive" benchmark showing a hot
   path (e.g. JSON parse / regex) beating the JVM *because* the runtime is
   rewritable — the axis-4 thesis made measurable; (b) one **Wasm-component-FFI
   demo** (ADR-0135) loading a real component and calling it as a namespace; (c)
   a one-line **startup-ms + binary-size** bench so "lightweight" is a number
   that also guards against bloat. Tracked by D-407.

3. **Keep the foundation tunable for the later concentrated campaign.** Size /
   speed are solved later by a focused comptime/JIT/superinstruction push (§10,
   D-133), *not* by daily perf work. The only standing discipline: compat
   wrappers may be slow `.clj` (json options, pprint dispatch are the pattern —
   raw fast Zig primitive + thin slow wrapper), but the **core primitives + the
   dual-backend hot paths stay fast and un-polluted** (PERF marker + the
   TreeWalk≡VM diff oracle already protect this).

The Wasm-as-namespace finished form (track 2b, ADR-0135) is paced by **zwasm's
Component-Model embedding-API freeze** (zwasm ADR-0170) — cljw drafts the design
now (ADR-0135's mapping table) and implements when that API freezes (D-404).

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

| #   | Principle                                                   | ADR source                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
|-----|-------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| A10 | Dual-backend differential testing is the oracle             | `Evaluator.compare()` CI mandatory; mismatch = build failure (ADR-0005)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| A11 | Day-one enum reservation                                    | `SpecialFormTag` / `Opcode` / `ValueTag` sized for phases 4-20 (ADR-0004, ADR-0012)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| A12 | File size is a smell detector, not a metric                 | 1,000-line soft cap / 2,000-line hard cap, `FILE-SIZE-EXEMPT` marker (ADR-0016)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| A13 | Debt ledger maintenance                                     | `.dev/debt.yaml` row-level predicates; phase boundary audit per row                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| A14 | Structural discipline markers                               | `FILE-SIZE-EXEMPT`, `SIBLING-PUB`, `SKIP-<reason>` markers, grep-indexed                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| A15 | Error catalog as Single Source Of Truth                     | `src/runtime/error_catalog.zig` owns every user-facing message; returns `ClojureWasmError` (ADR-0018). Crash policy split across Layer 1 / 2 / 3 (ADR-0019)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| A16 | Test taxonomy is 5-layer at Phase 4 entry                   | `test/README.md` lists Layer 1-5 with Phase activation (ADR-0021)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| A17 | Differential testing is CI mandatory                        | `test/diff/runner.zig` + `cases.yaml` (ADR-0005, ADR-0022)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| A18 | Source-scan gates share a framework                         | `scripts/scan_lib.sh` (ADR-0024); existing 4 check_*.sh adopt at Phase 5                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| A19 | ARCHITECTURE.md is the 5-minute orientation                 | repo root `ARCHITECTURE.md` (ADR-0020)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| A20 | run_step is the runner dispatch pattern                     | `test/run_all.sh` `run_step` + summary (ADR-0024)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| A21 | Comptime conditional import + stub struct for phase staging | `runtime/X/stub.zig` parallels real X, `build_options.phase_at_least_N` switches (ADR-0023)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| A22 | ADRs carry "Affected files" from 0020 onward                | `.dev/decisions/0000_template.md` + every new ADR (ADR-0020)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| A23 | Bad Smell sensor + four depths of revision                  | `.dev/principle.md` + `.claude/rules/plan_revision_thinking.md` (no ADR — meta layer above ADR / ROADMAP)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| A24 | Autonomous workflow is direct sequential                    | `CLAUDE.md § Autonomous Workflow` (cw v0-style, in-loop reflexive re-read of principle.md at Steps 1 / 4 / 6)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| A25 | Existing code is mutable; rewrite is part of design         | Skeleton activation (e.g. Phase 5 activates `TypeDescriptor.lookupMethod` against Phase 1-3 primitives) and ADR `Supersedes` chains rewrite already-written `src/`, not just add. Apply via `.dev/principle.md` depth 1-4. `Phase N+ migration note` section in the entry ADR narrates the rewrite scope; ROADMAP §A4 (isolated subsystem) and §A11 (day-1 enum) pin slot boundaries, everything between the slots is mutable. No "stays additive" default.                                                                                                                                                                                  |
| A26 | cw-v0 gap incorporation is plan-driven (not v0-copy)        | When opening Phase 15+ or minting quality-loop rows, consult [`.dev/cw_v0_parity_and_gap_plan.md`](./cw_v0_parity_and_gap_plan.md) — the 2026-05-29 parity snapshot + per-gap cw-v1-redesign direction + ordering + ROADMAP-amendment hook (user directive: incorporate most v0 gaps, but redesigned on cw v1's architecture with better design/ordering, never copied). Amend §9 in place per §17 referencing that doc. F-003 foresight — the owning phase decides the concrete design (Devil's-advocate at depth ≥ 2). Gaps with no current §9 row (`deps`/`test`/`--list-vars`/some namespaces) get NEW rows minted at incorporation. |

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
│   ├── debt.yaml                   row-level debt ledger (ADR-0072; replaced the planned known_issues.md)
│   ├── placement.yaml              Clojure-ns var placement SSOT (ADR-0033; covers the planned status/vars.yaml)
│   ├── principle.md                Bad Smell catalogue + revision depths
│   └── project_facts.md            user-declared invariants (F-001…)
│
├── .claude/
│   ├── settings.json               permissions, env, hooks
│   ├── rules/                      auto-loaded path-matched rules
│   │   ├── zone_deps.md            (loads on src/**/*.zig, build.zig)
│   │   ├── zig_tips.md             (loads on src/**/*.zig, build.zig)
│   │   └── tier_classification.md  (tier discipline; replaced the planned compat_tiers.md)
│   │   (… ~31 rules total; see `ls .claude/rules/`)
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

### 6.5 The host-frontier boundary (ADR-0136)

Which `clojure.lang.*` / `java.*` surface is **a language feature cljw must
provide** vs **Tier D = JVM implementation detail** is decided by a 4-rule
procedure, run **in order** (first match wins). This is what makes "Clojure
assets run as-is" a *finite, converging* goal instead of a treadmill
(D-406; the rules were derived from the 2026-06-12/13 conformance
campaign's classifications).

- **R1 — Artifact test → Tier D.** Satisfying the name requires a Java
  artifact (joda-time, Jackson, …) or JVM machinery (bytecode emission,
  classloaders, reflection metadata). The refusal names the cljw-native
  path (pure-Clojure alternative or a future Wasm component, ADR-0135).
  Canonical example: bouncer → clj-time → joda. cljw never shims a Java
  library.
- **R2 — Polymorphism-seam test → language feature.** A `clojure.lang.*`
  abstraction clojure.core itself dispatches on (deftype/reify/extend
  supertype position, or the class facet: `instance?` / `isa?` /
  `extend-protocol` / `print-method`). Coverage is definition-wide
  (F-013); closed set = [`host_interfaces.yaml`](../host_interfaces.yaml)
  (G4).
- **R3 — Value-semantics test → language feature.** The observable
  behaviour is a pure function of Clojure values (`Util/equiv`, `Murmur3`,
  boxed-number statics, `StringBuilder`/`StringWriter`,
  `Pattern`/`Matcher`, `UUID`, `Date`/`Instant`, java.util collection-VIEW
  methods). Thin surface over a neutral impl (F-009); closed set =
  [`compat_tiers.yaml`](../compat_tiers.yaml) (G2/G3). Tiebreak: a name
  both value-semantic and arguably JVM-internal goes R3 iff its behaviour
  is clj-oracle-checkable (F-011), else R4.
- **R4 — Implementation-leak default → Tier D.** Everything else
  (`clojure.lang.Compiler/*`, host-class reflection, JVM-internal
  statics). **Default-deny**: a name no rule claims is Tier D until an
  ADR amendment claims it.

Each closed set declares its admitting rule at the file level
(host_interfaces.yaml = R2; compat_tiers.yaml host_classes = R3); future
`tier: D` rows carry a per-row `frontier_rule: R1|R4` (the refusal text
differs). Worked-example table: ADR-0136. The
upstream-corpus scan (does `clojure/src/clj/**` use the name?) is
*non-normative evidence* for R2/R3 judgements, never the rule.

---

## 7. Concurrency design

### 7.1 Clojure reference-types ↔ pinned-Zig-0.16 primitive mapping (ADR-0090)

| Clojure prim         | pinned-Zig-0.16 mechanism (via `io_default` singleton where an `io` arg is unavailable)     | File                                                       | Phase               |
|----------------------|---------------------------------------------------------------------------------------------|------------------------------------------------------------|---------------------|
| **atom**             | `std.atomic.Value` CAS + validators + watches                                               | `runtime/atom.zig`                                         | B                   |
| **ref / STM**        | MVCC `LockingTransaction` (per-ref `std.Io.Mutex` + `Ref`/`TVal` ring), retry-only (AD-013) | `runtime/stm/*`, `runtime/concurrency/lock_tx.zig`         | B                   |
| **agent**            | thread pool (`std.Io.Threaded`) + action queue (send / send-off / error-mode)               | `runtime/agent.zig`, `runtime/concurrency/thread_pool.zig` | B                   |
| **future / pmap**    | `std.Thread.spawn` (KEPT in 0.16) + `std.Io.Condition` result cell                          | `runtime/future.zig`                                       | B                   |
| **promise**          | `std.Io.Mutex` + `std.Io.Condition`                                                         | `runtime/promise.zig`                                      | B                   |
| **delay**            | single `std.Io.Mutex` + state machine                                                       | `runtime/delay.zig`                                        | B                   |
| **volatile!**        | `@atomicLoad` / `@atomicStore`                                                              | `runtime/volatile.zig`                                     | B                   |
| **binding**          | `threadlocal current_frame` + conveyor-fn frame clone on spawn (D-241)                      | `runtime/env.zig`                                          | done + B conveyance |
| **locking**          | heap-value `std.Io.Mutex` (ADR-0009 `lock_state`), heap values only — NOT a JVM monitor    | `runtime/locking.zig`                                      | B                   |
| **GC thread-safety** | global alloc `std.Io.Mutex` + `ThreadGcContext` root-publication handshake (no safepoint)   | `runtime/gc/*`, `runtime/concurrency/gc_thread.zig`        | B                   |

> **Redesigned by ADR-0090 (the Phase-B-entry §7 redesign, landed 2026-06-04).**
> Corrected premise: the **pinned Zig 0.16.0** (what cljw compiles against) KEEPS
> `std.Thread.spawn` + `std.atomic.Value`; it moved the sync primitives to
> `std.Io.Mutex` / `Io.Condition` / `Io.Threaded`, reached via a process-wide
> `io_default` singleton (so `Allocator.VTable` callbacks with no `io` in hand can
> still lock). cw v0 ships this on the same pinned compiler; cljw re-derives it
> clean (`no_copy_from_v1`), spike-validated this session. The GC gains a
> **root-publication handshake** (collection walks the union of all live threads'
> `ThreadGcContext` root sets; the alloc/collect shared lock makes the
> install-window collection-free) for multi-thread mark-safety with no hot-loop
> safepoint — still single-gen mark-sweep (F-006; concurrent mark stays §89.2).
> Today `future`/`promise`/`delay`/`pmap` still run synchronously and the GC is
> single-threaded; ADR-0090 §1-7 is the build plan (rework-OK + per-commit gate,
> F-002). (`std.Thread.{Mutex,Condition,Pool}` and `runtime/binding_stack.zig`
> are gone — see `zig_tips.md` + ADR-0090 Context; the OSS `~/Documents/OSS/zig`
> clone is post-0.16 master and the WRONG tree for 0.16 API questions.)

### 7.2 STM is PLANNED, not yet implemented (corrected 2026-06-04, ADR-0089)

> **Status correction (ADR-0089)**: this section previously read "STM is
> implemented". That was false. As of 2026-06-04 only the `ref` shell exists;
> `dosync` / `alter` / `commute` / `ensure` / `ref-set` do **not** resolve. The
> transaction machinery is **Phase B** work (the staging table below already
> assigned it to Phase 14/15). The design (MVCC per ADR-0010) is decided; the
> §7.1 Zig-mechanism mapping is **pre-Zig-0.16** and is redesigned at Phase B
> entry (see §7.1 note).

`ref` / `dosync` / `alter` / `commute` / `ensure` / `ref-set` are **designed**
as Tier A per ADR-0010 (not yet built). The cw v1 charter explicitly aims
beyond Babashka's subset; STM is the signature Clojure concurrency
primitive and is included — landing in Phase B.

The implementation reproduces JVM `LockingTransaction.java` **observable**
semantics (internals free, F-011 §2): MVCC with TVal ring history per ref,
thread-local transaction context, retry loop with snapshot validation, ordered
locking by ref identity (deadlock-free). cljw is **retry-only** — JVM's barge
(younger-transaction preemption for starvation control) is **dropped per
ADR-0090** (result-equivalent; only contention fairness/throughput differs;
**AD-013 reserved** — its `accepted_divergences.yaml` entry + pin land with the
Phase B concurrent STM test). MVCC is chosen for observable snapshot-semantics fidelity under the
F-010 real-library loop, not because the ring is already built (that would be
Reservation-as-bias; see ADR-0090 Alternatives).

Phase staging (the data-structure shells landed through Phase 13-14; the
transaction engine + commit/retry is **Phase B** per ADR-0090):

- Done (≤ Phase 14): `Ref` / `TVal` data structures + `doGet` shell.
- Phase B: `doSet` / `doCommute` / `doEnsure` + commit + retry loop + commute
  fast path + the concurrent integration test (ADR-0090 §3, over the
  `runtime/concurrency/lock_tx.zig` engine; the GC root-publication handshake is
  a prerequisite and lands first).

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

### 8.2 Component as a first-class namespace (the finished form — ADR-0135)

The north-star (§1.2 axis 2): `require` a **Wasm component** and call its
exports with Clojure data, the types negotiated by the Canonical ABI. The
load-bearing design — surface (`deps.edn :cljw/wasm-deps` + `require`;
`load-component` REPL hatch), the **WIT ↔ Clojure value mapping table**, and the
key property that a **component binary is self-describing (no `.wit` sidecar
needed)** — lives in **ADR-0135**. Today's `(wasm/load)`+`(wasm/call handle
"export")` (ADR-0099) is the minimal core-module layer below it.

- WIT pod-invoke shape (escape hatch for un-portable Tier-C/D libs):
  `interface clojure-pod { invoke: func(name: string, args: list<value>) -> result<value>; }`,
  load with `(require '[my-lib :as lib :pod "my.wasm"])`. Faster/safer/edge-
  compatible vs Babashka's subprocess pods.
- **Gating dependency**: zwasm's Component-Model embedding-API freeze (zwasm
  ADR-0170, `-Dcomponent` — functional, not yet frozen). cljw drafts now
  (ADR-0135), implements on freeze (D-404).

### 8.3 WIT / Component Model timeline

| Capability                            | Phase                     | Note                                                           |
|---------------------------------------|---------------------------|----------------------------------------------------------------|
| WASI 0.2 (preview2)                   | Phase 14                  | Component build begins. Minimal exports.                       |
| `wasm/load`+`wasm/call` core FFI      | done (spike)              | ADR-0099 minimal core-module surface; the layer below ADR-0135 |
| **Component-as-namespace** (ADR-0135) | when zwasm CM API freezes | introspect component → ns; WIT↔clj mapping; D-404            |
| Pod loader                            | Phase 14-15               | `app/pod.zig`                                                  |
| WIT auto-binding                      | Phase 19                  | adopt wit-bindgen or similar                                   |
| WASI 0.3 (concurrency)                | Phase 19+                 | when std.Io WASI backend stabilises                            |
| WasmGC                                | v0.2+                     | conflicts with NaN boxing; linear memory leads                 |

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

| Phase | Name                                                                                            | Exit criteria (summary)                                                                                                                                            | Gate |
|-------|-------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------|------|
| 1     | Value + Reader + Error + Arena GC                                                               | Reads / prints `(+ 1 2)` as a Form                                                                                                                                 | 🔒    |
| 2     | TreeWalk + Analyzer + Bootstrap Stage 0                                                         | `(let [x 1] (+ x 2))` → 3, `((fn* [x] (+ x 1)) 41)` → 42                                                                                                         |      |
| 3     | defn + Bootstrap Stage 1-3 + ExceptionInfo                                                      | `(defn f [x] (+ x 1)) (f 2)` → 3; try/catch works                                                                                                                 |      |
| 4     | VM + Compiler + Opcodes                                                                         | Every TreeWalk test passes on the VM too                                                                                                                           | 🔒    |
| 5     | Collections (HAMT, Vector) + Mark-Sweep GC                                                      | `(get {:a 1} :a)` → 1; large collections do not OOM                                                                                                               | 🔒    |
| 6     | LazySeq + concat + higher-order foundations                                                     | `(take 5 (iterate inc 0))` → (0 1 2 3 4)                                                                                                                          |      |
| 7     | map / filter / reduce / range + transducers base                                                | Fused reduce produces zero intermediate seqs (target: v1's 391x)                                                                                                   |      |
| 8     | Evaluator.compare() + dual-backend verify                                                       | Every test agrees on TreeWalk and VM. `bench/history.yaml` initialised.                                                                                            | 🔒    |
| 9     | Modules layer + external standard libraries (clojure.edn / .data.json / .data.csv / .tools.cli) | All 4 external Tier-A namespaces ship; `modules/` top-level dependency rule enforced; self-host re-verified                                                        |      |
| 10    | Namespaces + require + standard libraries (Tier A)                                              | clojure.string / clojure.set etc. tests are green                                                                                                                  |      |
| 11    | clojure.test framework + start porting upstream tests                                           | deftest / is / are work; 10+ upstream tests ported                                                                                                                 |      |
| 12    | Bytecode cache (serialize + cache_gen)                                                          | Cold start `< 12 ms`; cache format versioning established                                                                                                          |      |
| 13    | VM optimisation: peephole.zig + STM `Ref`/`TVal` data structures (ADR-0010)                     | Five canonical benchmarks within 110 % of v1 24C.10; `Ref`/`TVal` + read-only `deref` land                                                                         |      |
| 14    | CLI + REPL + nREPL + deps.edn + Wasm Component build + **v0.1.0**                               | `cljw repl`, `cljw nrepl`, `cljw component build` all work; compat_tiers.yaml complete                                                                             | 🔒    |
| 15    | **Concurrency** — BUILT + race-hardened (gap area I; ADR-0142)                                 | atom/ref+STM/agent/future/promise/delay/locking/volatile ship; gap = parity/load (R1) + D-442/D-105 (`:volatile-mutable` happens-before DONE 2026-06-16: ADR-0152) | 🔒    |
| 16    | **Wasm/edge-native** BUILT (gap area II) · ClojureScript→JS = future                          | component build/run/require ship (`cljw.wasm/*`); CLJS→JS genuinely unbuilt                                                                                       |      |
| 17    | **VM perf: fusion → JIT** PARTIAL (gap area III)                                               | superinstruction/fusion slice landed (D-386 / O-018/019/021/023); narrow ARM64 JIT = milestone M                                                                   |      |
| 18    | math + module/deps DONE · **C FFI** = future                                                   | `clojure.math` + deps.edn ship; C FFI (`dlopen`/libffi) genuinely unbuilt                                                                                          |      |
| 19    | **Wasm/edge-native** cont. — WIT auto-binding (gap area II)                                    | component require BUILT; gap = WIT marshalling (D-404) + zwasm integration shape (D-036/D-350)                                                                     |      |
| 20    | **broad JIT** = future (distal; gated on gap-area-III fusion outcome)                           | narrow ARM64 JIT (milestone M) is the near-term scope; broad JIT decided after fusion lands                                                                        |      |

### 9.0 Completion-grade gap-area model (ADR-0142 / F-015 / D-440)

The project is **near-complete** (R2 accurate-position survey,
`private/notes/p14-r2-accurate-position-survey.md`). Phases 9-13 are DONE,
Phase 14 is done modulo the v0.1.0 tag, and the old "Phase 15-20 = future
work, expand at entry" framing is retired: most of that work is **BUILT**.
What remains is organized as **three completion-grade gap areas** + a small
**genuinely-future bucket** — not a forward phase queue. Old phase NUMBERS are
preserved only as stable section anchors for existing citations (F-015 cl.4 —
numbering is an input, not a constraint); the gap area is the real unit.

**Phase-number → gap-area redirect** (so existing "Phase N" / §9.N citations
in ADRs / debt rows / overlays still resolve while R4/R5 rewrite them at source):

| Former phase / §        | Gap area / status                                                                |
|--------------------------|----------------------------------------------------------------------------------|
| Phase 9-13 (§9.11-9.15) | **DONE** (Phase 12 = DONE, not "DONE-PARTIAL")                                   |
| Phase 14 (§9.16)        | **DONE modulo the v0.1.0 tag** — release mechanics (tag + version reconcile)    |
| Phase 15 (§9.17)        | **Gap area I — Concurrency hardening** (BUILT + race-hardened)                  |
| Phase 16 (§9.18)        | **Gap area II — Wasm/edge-native** (BUILT) · ClojureScript→JS = future bucket |
| Phase 17 (§9.19)        | **Gap area III — VM perf: fusion → JIT** (PARTIAL)                             |
| Phase 18 (§9.20)        | math + module/deps **DONE** · C FFI = future bucket                             |
| Phase 19 (§9.21)        | **Gap area II — Wasm/edge-native** (WIT auto-binding; D-404)                    |
| Phase 20 (§9.22)        | **future bucket** — broad JIT (distal; narrow ARM64 JIT = milestone M)          |

**Gap areas (the live hardening fronts):**

- **(I) Concurrency hardening** — atom/ref+STM(MVCC)/agent/future/promise/delay/
  locking/volatile/pmap all ship + race-hardened (`phase16_concurrency_stress.sh`
  caught+fixed real races). Gaps: clj-parity/load (Track R R1 — done this session:
  agent ctor options/D-441, await-for, swap-vals!/reset-vals!, io!), `future-cancel`/
  `seque`/legacy-agent surface (**D-442**), java.time trio (**D-105**).
  (`:volatile-mutable` cross-thread happens-before DONE 2026-06-16 — ADR-0152 /
  D-444; un-accepted AD-018, the residual IRIW gap = AD-034.) Hardening defers
  (gated, engine correct without them): D-244 #4a' auto-collect, D-245 Option C
  blocking monitor.
- **(II) Wasm / edge-native** — `cljw.wasm/*` component build/run/require BUILT
  (`src/runtime/cljw/wasm/`, embeds zwasm v2 per F-001). Gaps: WIT param marshalling
  (**D-404**), zwasm integration finished-form (**D-036 / D-350 / D-039**).
- **(III) VM perf (fusion → JIT)** — arith/compare-branch superinstructions +
  reduce/lazy-seq fusion landed (**D-386 / O-018/019/021/023**). Gaps: remaining
  fusion surface; **narrow ARM64 JIT (F-010 milestone M)** → broad JIT go/no-go
  (distal, D-005 / D-035).

**Genuinely-future bucket** (no impl; honest future): ClojureScript→JS compiler,
C FFI (`dlopen`/libffi), broad JIT (Phase 20).

> **Milestone M** (F-010) = concurrency complete (gap area I drained to parity)
> + the cw-v0-level narrow ARM64 JIT. M is a **named milestone token**, not a
> phase number — F-010's gate references it by name, not by "Phase 15".

The §9.17-9.22 sections below keep their numbered anchors but their bodies are
reframed to the gap-area role (stale stub-swap "Final activation step" /
`phase_at_least_N` framing dropped — those impls shipped). **Sequencing
(ADR-0142)**: R4 (debt re-barrier) + R5 (instruction 大整理) run in the same
D-440 arc to rewrite "Phase N target" barriers + the phase-entry machinery to
gap-area terms; until then this redirect table is the bridge. The capability-
matrix successor model (drop phase numbers entirely) is forward debt **D-443**.

### 9.1 Phase 14 = v0.1.0 milestone

Phase 14 = first publishable v0.1.0. **Minimum line for a Conj talk.**
- CLI / REPL / nREPL working
- compat_tiers.yaml has Tier A/B declarations done
- Wasm Component output supported (even if minimal)
- bench/history.yaml has a locked baseline

> **Version-string reconcile (ADR-0142, 2026-06-15)**: the deliverables above
> all ship; the single remaining item is cutting the tag. `build.zig.zon` is
> currently `1.0.0-alpha.1` (the working pre-release string), NOT `v0.1.0`. The
> "v0.1.0" label here + the v0.x ladder in §9.2 are the original milestone naming
> kept for history; the actual published version is whatever the tag-cut step
> stamps (user-owned). Treat `1.0.0-alpha.1` as the live version, "v0.1.0" as the
> milestone *name*, not a literal version assertion.

### 9.2 v0.2.0 onward

> **Re-sequenced by F-010 (2026-05-29) — see §9.2.R.** The mapping
> below is the pre-re-cut plan, kept for history. The live post-v0.1.0
> order is in §9.2.R.

- Phase 15-16 (Concurrency + CLJS): v0.2.0
- Phase 17-19 (super_instruction + module + advanced Wasm): v0.3.0
- Phase 20 (JIT): v0.4.0 or skipped

### 9.2.R Interim-goal re-cut (F-010 / ADR-0051, 2026-05-29; restored A→B→C by ADR-0089 2026-06-04)

> **Restore note (ADR-0089, 2026-06-04)**: this section's intent — Phase 15
> (concurrency) BEFORE the quality-elevation loop — was inverted in practice
> (the session ran the quality loop pre-Phase-15). ADR-0089 restores the order
> as **Phase A (consolidation) → Phase B (KNOWN-unimplemented CORE,
> concurrency-led = this section's Phase 15) → Phase C (library-driven gap-hunt =
> the quality loop)**. The clean-bounded clj-parity frontier is drained, so the
> quality loop is re-cast as **library-driven** (Phase C) on a concurrency-capable
> base, not an open-ended `clojure.core` grind.

User-directed re-cut. Records the post-Phase-14 **execution order +
direction**; granularity (exact renumber, sub-phase structure,
floor-vs-superinstruction ordering) is **deferred to each owning
Phase entry per F-003** — this section seizes nothing, it records
direction + foresight.

> **Priority refinement (user chat, 2026-06-05)** — after the Phase B
> concurrency core + the complete #4a' GC-rooting landed:
> - **Docs / release-prep OUTRANKS the low-value concurrency tail.**
>   First land a single-sheet **Clojure-vs-ClojureWasm differences doc**
>   (ClojureScript-style; debt D-249). The low-value tail (agent watches/
>   validator, `await-for`, `shutdown-agents`, with-local-vars) is **NOT
>   skipped** — implemented AFTER completeness rises; a tentative
>   completion that leaves them as tracked tasks is fine first.
> - **Phase C = library-driven gap-hunt FIRST, THEN Wasm / edge-native.**
>   Wasm COMPILATION itself is further off; **before the release, integrate
>   zwasm**; the rest of the Wasm story is a **post-release best-effort
>   goal**.
> - **GC completeness**: the #4a' rooting is done; gate the production
>   auto-collect-ON behind a **GC torture mode** validation (debt D-250)
>   + user-awareness. Heap-tag layout stays **64 slots** (F-004 Revision
>   2026-06-05; 128 + region allocator = D-247, only when slots run out);
>   the **Group D wasm→tail reorg** (D-248) is a ready, non-breaking
>   cleanup. Detail: `private/notes/layout-gc-decisions-2026-06-05.md`.

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

### 9.2.S Performance tuning campaign (PARKED into Phase B; ADR-0063, 2026-05-31; re-cut ADR-0089 2026-06-04)

> **ACTIVE sub-strategy (2026-06-24): collection-perf — [ADR-0165](decisions/0165_collection_perf_strategy.md) / D-520.**
> The fastest-script campaign (ADR-0148) won the STARTUP axis (cold-start arc) and ratio_sum;
> cljw's VM beats babashka's SCI on pure compute (fib_loop/tak 2×). The remaining losses
> (sieve/destructure/gc_*/bigint, 1.02–1.16×) are the COLLECTION/library layer. Strategy: keep
> best-of-breed algorithms (cljw already has CHAMP/radix+tail/array-map/std.math.big; RRB
> rejected), win on Zig-native LAYOUT, **transients-first**. The JIT (D-386) is the separate
> bigger compute frontier. Full plan + experiment/regression protocol: ADR-0165.

> **Re-cut (ADR-0089, 2026-06-04)**: the "resume here" marker is stale — the
> session ran the F-010 quality loop, not this perf campaign. Under the
> A→B→C re-cut, perf (D-163 lazy-chain reduce, D-140 startup cache) folds into
> **Phase B** (it shares the concurrency/VM substrate) or runs as a parallel
> overlay there. It is no longer the standing "resume here" line — Phase A
> (consolidation) is.

**User-directed pull-forward.** The §9.2.R sequence parks perf (the
JIT/fusion chain) after Phase 15. But per-element interpreter overhead
(`reduce`/`map`/`into`/`vec` over large inputs, lazy-seq realisation,
cljw startup) became a **dev-iteration bottleneck** before then, so the
user pulled a perf campaign forward (2026-05-31): *"あからさまに遅いと
数々のこれからのイテレーションのボトルネックになるので、 前倒しでもやって
おく価値があります … cw v0 なども参考に、 このプロジェクトの作り方で最適な
もので速度チューニング … ROI の高いものから自律的に判断して進め、 手戻りも
していい（コミットこまめにするとrevertしやすい）"*.

This is a **repeatable, ROI-ordered, refactor-gated** cluster (the F-010
discipline applied to perf): each unit is its own commit (revert-
friendly), held to F-002 finished-form + F-011 commonisation, gated
individually, and **measured before/after**. Every speed-for-simplicity
trade carries a `// PERF:` marker + a row in
[`.dev/optimizations.md`](./optimizations.md) (the SSOT, ADR-0063); the
naive form stays the behavioural contract (F-011 equivalence vs `clj`).
cw v0 (`Meta.range` / `fusedReduce` / incremental-trie transients) is
the precedent, re-derived cljw-appropriately (not copied; F-004 standalone
slots, not slot-cram).

**Units, ROI-ordered** (impact × frequency / effort·risk). Measured on
mac-arm-m4pro, 0.48s startup baseline subtracted:

| Unit  | What                                                                                                                                                                                                                                                                                                                                                           | Status                      | ROI note                                                                                                                                                                   |
|-------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| O-001 | Compact `.range` value (O(1) count/nth, tight reduce, chunked seq)                                                                                                                                                                                                                                                                                             | **DONE** `72d7bfcc`         | `(count (range 1e6))` ~118s → 0ms                                                                                                                                         |
| O-002 | `reduce` over a vector index-walks (no `seqFn`→`vectorToList` eager N-cons)                                                                                                                                                                                                                                                                                   | **DONE** `0898ba2c`         | `(reduce + (vec (range 1e6)))` 182s → 123s (residual = build side, D-180)                                                                                                 |
| O-003 | **Bulk `persistent!` / `vector.fromSlice`** — `toPersistent` builds the HAMT from the transient's flat buffer in O(n) (was N persistent conjs O(n log n)) + `into`/`vec` route editable targets through transients                                                                                                                                            | **DONE** (D-180)            | `(count (vec (range 1e6)))` 121s → 2.4s; `(reduce + (vec 1e6))` 123s → 2.5s. Boundary unit test (n ∈ {0,1,31,32,33,63,64,65,1023,1024,1025,1e5}) + diff oracle green    |
| D-163 | **Lazy-chain reduce perf** (ADR-0065 re-laid: chunked seqs for the implicit `(reduce f (map g coll))` path + existing transducers for the explicit 0-alloc opt-in — JVM finished form, NOT cw-v0 meta-fuse = F-011 second mechanism). First cycle (Alt C): `chunked_cons` reduceFn arm + `.clj` chunk-builder primitives + chunk-aware map/filter/keep/remove | **ACTIVE** (ADR-0065)       | `(count (map inc (range 1e5)))` = 42s ≈ 420µs/elem. Realistic **~4-7×** (chunking kills the per-thunk tree-walk; per-element `f` vtable residual is D-133). Own ADR-0065 |
| D-140 | **cljw startup bootstrap cache** — re-parse+analyse+eval ~1000-line `core.clj` per invocation ≈ 0.48s                                                                                                                                                                                                                                                        | after D-163 (architectural) | **Highest dev-velocity ROI** (every test/probe pays it; e2e suite's ~138s parallel block is dominated by it). Pre-analysed bootstrap cache à la ClojureScript             |

**Resume contract**: O-001/O-002/O-003 (D-180) DONE. Start at **D-163**
(map/filter/take reduce-fusion — its own ADR; `.range` O-001 + the
chunked-cons seq are the substrate), then D-140 startup bootstrap cache.
Re-measure each before/after; record the win in `optimizations.md`.
This cluster runs ahead of the §9.2.R Phase-15/JIT sequence and does not
renumber it (F-003: §9.2.R's ordering is intact; this is a pulled-forward
overlay). Granularity (whether D-163/D-140 become numbered phases) defers
to their entry per F-003.

### 9.2.T Public-ization polish sweep (post-perf operating mode; ADR-0166, 2026-06-24)

**User-directed.** After §9.2.S's perf campaign reached the boundary of its cheap
levers (O-051 the last clean one; the rest GC-arch / JIT-fenced — ADR-0165
Amendment 1 / D-520), the standing `/continue` mode shifts to **polishing the
project as a public artifact** (anyone clones it into their own environment).
Repeatable like the F-010 quality-loop floor — each `/continue` self-selects ONE
category and drains it **EASIEST-FIRST** (by tractability, not value — 2026-06-25
user decision; drain the whole list, niche/deferred included, to clear 残件; Step
0.5 `quality_floor:` drain). SSOT
= **ADR-0166**; drain rows **D-522…D-529** (comment de-pointering + condensation /
doc audit vs code-truth / `private/` decouple + per-task-note retire / rules +
skills review / java-interop static-member gaps / clj-parity upstream alignment /
real-`deps.edn` library usage / marker-comment inventory). Mostly no behaviour
change; code-touching rows (interop / parity / lib bugs) take the diff-oracle gate.
The §9.2.S perf levers stay in standing debt for a future deliberate decision.

**Release mechanics for 1.0.0-rc.1 (ADR-0167, 2026-07-01, user-directed).** Sibling
to ADR-0166: 0166 = internal *quality* (comments/docs/scaffolding/interop/parity);
**0167 = the release *mechanics* an external clone needs** (CI / community-health
files / CHANGELOG / third-party attribution / personal-environment decoupling /
version staging), gap-analysed against the zwasm v2.0.0-rc.1 series (S0…S7). The
**rc.1 readiness gate is FINITE and explicit** = Track A rows **D-536…D-540** +
version staging **D-541** + release-artifact workflow **D-542** + dep-pin coherence
**D-543** — this finite set is the SSOT for "can the user cut the tag?". Track B
(the ADR-0166 D-522…D-529 drain) is **fully drained but does NOT gate the rc.1
signal** (F-compliant: F-002 governs per-task quality, not inter-task order; a
release *candidate* cannot wait on the open-ended D-529 real-lib discovery). The
final `1.0.0-rc.1` bump + `git tag`/publish is **USER-OWNED** — the loop prepares
everything but never tags.

### 9.2.P clj-parity root-cause campaign (largely worked; folded into gap-area-I hardening per ADR-0142; ADR-0076, 2026-06-02)

**User-directed.** A periodic audit surfaced the user's concern that small
cljw↔clj mismatches "利用されるときの不信感につながりそう". The user directed
(2026-06-02): root-cause-resolve the real gaps ("A系は解消", big surgery
accepted per F-002), and record the intentional ones ("B…妥当な差異なので、
しっかり許容した、と記録…ルール化や自動防御"). This campaign is the A half; the
B half is the accepted-divergence framework (ADR-0076 §1 — SSOT
`.dev/accepted_divergences.yaml` + rule + gate).

Like §9.2.S this is a **repeatable, refactor-gated** cluster anchored on a
standing **`quality-loop floor: clj-parity`** debt Barrier (F-010), so it
cannot rot half-done and new sweep-found divergences drain through it. Each
unit is its own commit (revert-friendly), F-002/F-011-held, gated, and leaves
a **corpus line** behind (the pin — anti-D-177 mechanical re-check via
`check_corpus_regression.sh`).

**Units** (ADR-0076 table; the honest loop-vs-user split):

| Unit      | Debt  | Gap (clj-visible)                              | あるべき論                                                                                                                         | Owner              |
|-----------|-------|------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------|--------------------|
| C1 (lead) | D-164 | empty `()`/seq → `nil`; `(seq? '())`→false   | interned distinct empty value in existing `.list`/seq tags (no new slot); uniform across every seq fn — highest leverage          | loop               |
| C2        | D-205 | BigDecimal map-key `(get {1.5M :v} 1.5M)`→nil | numeric arm in rt-free `keyEqValue` + scale-normalized hash                                                                        | loop               |
| C3        | D-207 | `.toString`/`.equals`/`.hashCode`/`.getClass`  | dispatch-level Object fallback → `str`/`=`/`hash`/`class` (F-009)                                                                 | loop               |
| C4        | D-209 | `map-entry?` + distinct MapEntry               | activate the **reserved** Group-A `.map_entry` slot (≠ F-004 amend)                                                               | loop               |
| C5        | D-198 | `(Exception. "x")` host-class ctors            | D-048 host-class machinery (dependency-ordered)                                                                                    | loop (after D-048) |
| C6        | D-200 | `#inst`/Date                                   | ship the **no-slot** cljw-native `typed_instance` Date; dedicated `.date` slot = **user F-004** option                             | loop + user (slot) |
| C7        | D-165 | long in (2^47, 2^63] -> BigInt `...N`          | heap-boxed Long (B2 flag on heap-int; NO new slot, F-004 unchanged); stays Long to i64, BigInt past i64; overflow-promote = AD-008 | loop               |

**Resume contract**: start at **C1 (D-164)** — one representation fix
clears every seq predicate (`seq?`/`list?`/`empty?`/`=` on `()`), the single
highest-trust win. Then C2 → C3 → C4 → C6(no-slot Date) → C5(after D-048).
**All 7 units are now loop-resolvable** (user-decided 2026-06-02, ADR-0076
am1): C7 D-165 = heap-boxed Long (B2 flag, NO F-004 amendment; F-005 surface
already wants Long-to-i64); C6 #inst = no-slot typed_instance Date. The
Long-overflow-past-i64 promote-vs-throw is the accepted divergence AD-008
(cljw promotes per F-005; clj throws); the promoting prime-arithmetic family
is deferred D-211. This overlay runs ahead of §9.2.R and does not renumber it (F-003).

### 9.3 Phase 1 — task list (DONE; archived)
> DONE; expanded task detail archived → [`ROADMAP_archive_phases_1-13.md`](./ROADMAP_archive_phases_1-13.md). §9 tracker + `git log` = SSOT.

### 9.4 Phase 2 — task list (DONE; archived)
> DONE; expanded task detail archived → [`ROADMAP_archive_phases_1-13.md`](./ROADMAP_archive_phases_1-13.md). §9 tracker + `git log` = SSOT.

### 9.5 Phase 3 — task list (DONE; archived)
> DONE; expanded task detail archived → [`ROADMAP_archive_phases_1-13.md`](./ROADMAP_archive_phases_1-13.md). §9 tracker + `git log` = SSOT.

### 9.6 Phase 4 — task list (DONE; archived)
> DONE; expanded task detail archived → [`ROADMAP_archive_phases_1-13.md`](./ROADMAP_archive_phases_1-13.md). §9 tracker + `git log` = SSOT.

### 9.6.x Dependency graph (Phase 4 task ordering)
> DONE; expanded task detail archived → [`ROADMAP_archive_phases_1-13.md`](./ROADMAP_archive_phases_1-13.md). §9 tracker + `git log` = SSOT.

### 9.7 Phase 5 — task list (DONE; foundational — code landed; §9 tracker records Phase 5 DONE. Expanded rows flipped 2026-06-04 to match the tracker: GC/numeric-tower/TypeDescriptor/deftype/analyzer-split all present, and Phases 6-13 build on them.)
> DONE; expanded task detail archived → [`ROADMAP_archive_phases_1-13.md`](./ROADMAP_archive_phases_1-13.md). §9 tracker + `git log` = SSOT.

### 9.7.x Dependency graph (Phase 5 task ordering)
> DONE; expanded task detail archived → [`ROADMAP_archive_phases_1-13.md`](./ROADMAP_archive_phases_1-13.md). §9 tracker + `git log` = SSOT.

### 9.8 Phase 6 — task list (DONE; closed 2026-05-26)
> DONE; expanded task detail archived → [`ROADMAP_archive_phases_1-13.md`](./ROADMAP_archive_phases_1-13.md). §9 tracker + `git log` = SSOT.

### 9.9 Phase 7 — task list (DONE; closed 2026-05-27)
> DONE; expanded task detail archived → [`ROADMAP_archive_phases_1-13.md`](./ROADMAP_archive_phases_1-13.md). §9 tracker + `git log` = SSOT.

### 9.10 Phase 8 — task list (DONE; closed 2026-05-27)
> DONE; expanded task detail archived → [`ROADMAP_archive_phases_1-13.md`](./ROADMAP_archive_phases_1-13.md). §9 tracker + `git log` = SSOT.

### 9.11 Phase 9 — task list (DONE; closed 2026-05-27)
> DONE; expanded task detail archived → [`ROADMAP_archive_phases_1-13.md`](./ROADMAP_archive_phases_1-13.md). §9 tracker + `git log` = SSOT.

### 9.12 Phase 10 — task list (DONE; closed 2026-05-27)
> DONE; expanded task detail archived → [`ROADMAP_archive_phases_1-13.md`](./ROADMAP_archive_phases_1-13.md). §9 tracker + `git log` = SSOT.

### 9.13 Phase 11 — task list (DONE; closed 2026-05-27)
> DONE; expanded task detail archived → [`ROADMAP_archive_phases_1-13.md`](./ROADMAP_archive_phases_1-13.md). §9 tracker + `git log` = SSOT.

### 9.14 Phase 12 — task list (DONE; closed 2026-05-27; "DONE-PARTIAL" corrected to DONE per ADR-0142 — the bytecode cache is complete: AOT envelope embedded + interleaved per-chunk restore)
> DONE; expanded task detail archived → [`ROADMAP_archive_phases_1-13.md`](./ROADMAP_archive_phases_1-13.md). §9 tracker + `git log` = SSOT.

### 9.15 Phase 13 — task list (DONE; closed 2026-05-28)
> DONE; expanded task detail archived → [`ROADMAP_archive_phases_1-13.md`](./ROADMAP_archive_phases_1-13.md). §9 tracker + `git log` = SSOT.

### 9.16 Phase 14 — task list (DONE modulo the v0.1.0 tag; opened 2026-05-28, **v0.1.0 milestone**; ADR-0142 — CLI/REPL/nREPL/deps.edn/Wasm-component-build all ship; the single remaining item is the tag-cut + version-string reconcile, user-owned)

> **Resume wiring (read before picking a `[ ]` task)**: the only two open rows —
> **14.12** (`cljw component build`, **blocked-by zwasm CM readiness** → D-036 /
> D-404 / ADR-0135) and **14.14** (exit-smoke + **v0.1.0 tag, user-deferred** — not
> cut yet) — are **both BLOCKED**. So `/continue` does **not** start them. The
> active work is the **post-M quality-loop operating mode** (F-010 / §1.5 3-track
> working strategy), **handover + debt-driven** (the `quality-loop floor:` rows +
> D-400 / D-404–D-407), not §9.16 row order. The handover Resume contract is the
> authoritative pointer; this note just keeps the §9 mechanism from misdirecting a
> fresh session to the two blocked rows.
>
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
14.14. Per **ADR-0015 a3 + a5**, this is now a **milestone marker
flip**, not a stub swap: the io-stub-swap it nominally gated never
materialised (`runtime/io/stub.zig` was never written — `runtime/io/`
holds `interface.zig` Tier-1 only), and F142 nREPL (14.10) / F143 REPL
(14.9) / F144 `cljw build` (14.11) all landed **ungated** as
`src/app/cli.zig` dispatch arms. So the flip is `build.zig` `false→true`
+ the `src/main.zig` manifest test, with zero behavioural consumer
gates. F140/F141 (HTTP server/client) are **out of v0.1.0 scope** (no
backing impl; not gated by this flag).

| #       | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | Status                                                                                                                                                                                                                                                                                                                                                                      |
|---------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 14.0    | Phase 13 → 14 boundary review chain follow-ups: handover refreshed (in this open commit); Step 0.5 debt sweep of stale-Phase Active rows (audit listed ~14 — D-008 / D-014a / D-014b / D-017 / D-022 / D-023 / D-024 / D-025 / D-026 / D-030 / D-033 / D-045 / D-048 / D-069 / D-070 / D-079); `Opcode.isPositionRelative()` extraction (parallel to `isPurePush`, simplify-arm [should]); peephole.zig defensive negative-offset + i16 overflow comments                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | [x] (D-082 moved Discharged at 1d0b9d1; isPositionRelative + invariant comments at 17ed822; Step 0.5 sweep: D-008/D-017/D-026/D-030/D-069/D-070 Discharged + D-022/D-023/D-024/D-025/D-033/D-045/D-048 Opportunistic + D-014a/D-014b/D-079 promoted to Phase 14 rows)                                                                                                       |
| 14.1    | **D-079** discharge — `___HOST_EXTENSION` aggregator wired in `src/runtime/java/_host_api.zig::installAll(env)` + `inline for` over each `@import(...).___HOST_EXTENSION`. Prerequisite for 14.2/14.3 host-class surface emission. ADR-0029 D5 schema completion                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | [x] (installAll over 7 surfaces; Pattern.zig stale schema retrofitted; heap-copy on install reconciles rt.deinit ownership; 2 unit tests cover full set + idempotency)                                                                                                                                                                                                      |
| 14.2    | **D-097** discharge — host stdlib second wave: `java.util.regex.Matcher`, `java.time.LocalDateTime`, `java.time.Duration`, `java.time.ZonedDateTime`, `java.math.BigDecimal` (thin `runtime/java/math/BigDecimal.zig` wrapper over existing `runtime/numeric/big_decimal.zig`). Per ADR-0029 D5                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | [x] (5 TypeDescriptor reservations ship: Matcher / BigDecimal land with backing impls present; LocalDateTime / Duration / ZonedDateTime ship as TypeDescriptor-only — backing `runtime/time/*` impls deferred to D-105. java_surfaces[] extended; installAll registers all 12 surfaces)                                                                                    |
| 14.3    | Host stdlib third wave — `java.net.Socket` / `java.security.MessageDigest` + remaining Tier B host classes per `compat_tiers.yaml`. Network + crypto surface via cw-native impl per F-009                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | [x] (TypeDescriptor reservations: net/Socket.zig + security/MessageDigest.zig ship per ADR-0029 D5; backing `runtime/net/` + `runtime/crypto/` impls deferred to D-106. Remaining Tier B host classes — URL/URI/SecureRandom/etc — ride row 14.13 polish or focused cycles)                                                                                               |
| 14.4    | **D-014a** discharge — numeric tower completion: BigDecimal Tier B observable surface; JVM-shape auto-promotion (`(* Long/MAX_VALUE 2)` → BigInt; `(/ 1 3)` → Ratio; `1.5M` → BigDecimal). F-005 internal = `std.math.big.int.Managed` + Ratio (BigInt × BigInt) simplified + BigDecimal (unscaled BigInt, i32 scale)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | [x] (3 gaps closed: BigDecimal toPlainString printer f9085e6, Ratio literal parser 8c9a258, Long-overflow→BigInt promotion at integerLiteralToValue. D-014a fully Discharged. Ratio×Int arithmetic bug noted as separate concern)                                                                                                                                         |
| 14.5    | **D-014b** discharge — `ex-info` `:type` keyword + catch dispatch via `:type` (ADR-0007 / 0018). Tier A throw/catch completeness                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | [x] (ba5b9d99: CatchTarget union landed; analyzer accepts keyword; TreeWalk catchMatches keyword arm; VM rides VM-DEFER per feature_deps.yaml#runtime/eval/catch_type_keyword; 5 e2e cases in test/e2e/phase14_catch_keyword.sh)                                                                                                                                            |
| 14.6    | **D-099** discharge — user-defined `defmacro` dispatch via `rt.vtable.callFn` (`macro_dispatch.zig:107` referenced site). Unblocks `clojure.test/deftest` / `clojure.test/are` / `clojure.test/testing` / `clojure.core/declare`. Tier A test corpus matures                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | [x] (32852436: defmacro analyzer arm + valueToForm adapter + expandIfMacro user-fn fallback; 5 e2e cases; `&form`/`&env` deferred as D-111)                                                                                                                                                                                                                                 |
| 14.7    | **D-098** discharge — `(ns …)` directive surface: `:refer-clojure :exclude / :only`, `(:require [ns :as alias :refer […]])`, `(:rename {old new})`. Extends `analyzeNs` (`special_forms.zig:350-395`) + `env.referAll`-with-filter. JVM-idiom `.clj` corpora become buildable                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | [x] (4f2ff916: :exclude/:only filters + ns-level :require landed TreeWalk; VM rides VM-DEFER per feature_deps.yaml#runtime/vm/ns_filter_and_libspec; :rename split to D-112)                                                                                                                                                                                                |
| 14.8    | `future` / `promise` / `delay` — Phase 14 Tier A concurrent primitives. JVM idiom on a single-thread runtime: `(deref (future …))` blocks synchronously; promise: `(deliver p v)` + `(deref p)`; delay: lazy memoization. Per `private/JVM_TO_ZIG.md` §7. Concurrency activation rides Phase 15                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | [x] (3235f9ff: 3 heap types delay/promise/future + 5 primitives + 2 macro transforms + 9 e2e cases; Phase 15.1 swap path = D-113/114/115; future/error_value_channel PROVISIONAL marker)                                                                                                                                                                                    |
| 14.9    | **ADR-0048 issuance** + `cljw repl` — REPL line editor (F144 re-introduction) + state-machine ADR for REPL prompt / nREPL session / build-pipeline (next ADR id = 0048 per time-ordered allocation; the prior placeholder "ADR-0028" reservation discarded per Reservation-as-bias)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | [x] (208f33bd: ADR-0048 minted with REPL chart + nREPL/build placeholders; line-buffered REPL in src/app/repl.zig; 5 e2e cases; line editor polish = D-116)                                                                                                                                                                                                                 |
| 14.10   | `cljw nrepl` — F142 nREPL server re-introduction per ADR-0015 a2. State machine per ADR-0048 (14.9 issuance)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | [x] (76e0c64c: runtime/bencode/ neutral codec + src/app/nrepl.zig 4-op server; ADR-0015 a3 + ADR-0048 nREPL chart fill; e2e via Python bencode driver; multi-session/CIDER ops = D-117, stdout/stderr capture = D-118)                                                                                                                                                      |
| 14.11   | **D-100 cluster discharge** — Phase-12 substantive deliverables land in dedicated cycles here: (a) full `BytecodeChunk` coverage (constants pool serializer with NaN-box Value round-trip; `call_sites` + `libspecs` side-tables); (b) `cljw build app.clj -o app` CLI (`src/app/builder.zig`; Deno-style binary trailer; bootstrap cache build.zig integration); (c) `cljw render-error` decoder (`src/app/render_error.zig` + `runtime/error/event.zig` + render.zig TTY/pipe split); (d) cold-start bench < 12 ms verified; (e) `cljw-formats/0.1.0.edn` archive v0.1.0 lock                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | [x] (D-100 cluster fully discharged: (a) @194eefaf BytecodeChunk serializer + (c) @a9045b10 render-error + (d) @ebf2979b cold-start; (b) `cljw build` — per-form eval @41092c86, fn_val serialization @19d6b8cc (ADR-0034 am2), EnvelopeIterator @8758a03b, CLI+self-exe trailer+startup-run @d5f0612e, F-009 setupCore @924992bb; (e) `cljw-formats/0.1.0.edn` @9aa4f6c1) |
| 14.11.5 | **D-102 Ref→TVal history-ring rewrite** (row-assigned per D-122 schedule fix; ADR-0010 amendment 4). Lands `src/runtime/stm/tval.zig` (new — TVal struct with `val/point/msecs/prior/next` doubly-linked self-loop ring); rewrites `src/runtime/stm/ref.zig` (Ref carries `tvals: *TVal + min_history=0 + max_history=10 + lock: std.atomic.Mutex`); names HeapTag Group D slot 63 as `tval`; GC trace verified via mark-bitmap cycle detection. Phase 15.1 transaction control flow (`doGet`/`doSet`/`doCommute`/`doEnsure`/commit/retry) lands on this unchanged Ref/TVal shape (D-114). Sequenced before D-100(a)/(b)/(e) is acceptable — no dependency either direction; landing 14.11.5 first closes a structural row that would otherwise sit silent at v0.1.0 tag                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | [x] (540f5739)                                                                                                                                                                                                                                                                                                                                                              |
| 14.12   | `cljw component build` — Wasm Component output (minimal). **Gated on zwasm v2 readiness** (D-036 / D-037 / D-038 / F-008). May ship as PROVISIONAL via wasm-c-api veneer if zwasm v2 rewrite (ADR-0109) is incomplete at landing time                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | [ ]                                                                                                                                                                                                                                                                                                                                                                         |
| 14.13   | v0.1.0 polish bundle — `compat_tiers.yaml` Tier A/B declarations comprehensive review/finish; `bench/history.yaml` v0.1.0 lock-point entry per ADR-0044 schema; **D-066** discharge (`CLJW_ERROR_FORMAT` / `CLJW_ERROR_LOG` env var spec + man page); `cljw.error/with-context` macro (v5 §13.6 user runtime error injection API)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | [x] done 2026-05-29 (bench 14A.0 3f5aa415; binding 15d7e21f; with-context c3aa601c; ADR-0055, ADR-0042 am1; compat + D-066 earlier)                                                                                                                                                                                                                                         |
| 14.13.5 | **lazy-seq Layer-2 (ADR-0054, ~4 cycles)** — wire the lazy_seq PRODUCER (Phase-6 left consumer-only): `lazy-seq` macro + `__lazy-seq-create` primitive (delay/future triad), `iterate`, then convert the eager seq surface (map/filter/take/drop/keep/remove/concat/mapcat/map-indexed/keep-indexed) to lazy `.clj` deleting the `-*-eager` leaves, + infinite range/repeat/repeatedly/cycle/take-while/drop-while/partition. Cycle 1 folds in the load-bearing `print.zig` `rt/env` threading (force-to-print lazy, bounded by `*print-length*` — **CORRECTION (ADR-0089, 2026-06-04): the `*print-length*` BOUND was NOT delivered here; `deepRealize` realized infinite seqs fully and hung. Fixed 2026-06-04 @0e3edad8 by bounding `realizeSeqWalk` to length+1 — D-222 b**); cycle 3 the lazy-`=` force-walk. Chunking DEFERRED to a perf cycle. The last unmet Phase-6 exit criterion + D-133 coverage floor. Proof: `(take 5 (iterate inc 0))` → `(0 1 2 3 4)`; `(first (map inc (range)))` → 1. **STATUS 2026-05-29**: ALL 4 cycles DONE — cycle 1 (producer+iterate) @e2e99de8; cycle 2 (lazy map/filter/keep/remove + print realize) @e14d024c; cycle 3 (concat/mapcat/drop lazy + infinite 0-arg range + lazy `=` force-walk in equal.zig) + cycle 4 (repeat/repeatedly/cycle/take-while/drop-while/partition) landed across @8e0ce4db (cycle 3) + @3661d7f5 (cycle 4) — BOTH shipped red (range `iterate` forward-ref + the cycle-4 fns never in core.clj) — then @8f7a1e63 moved `iterate` above `range` but its commit message claimed the cycle-4 fns while the edit did NOT land, so the gate stayed red until @ec9ccfed actually added repeat/repeatedly/cycle/take-while/drop-while/partition + `list` (caught on resume by reading run_all.sh from the on-disk log). Lazy-seq Layer-2 COMPLETE; gate green. Row closed. | [x]                                                                                                                                                                                                                                                                                                                                                                         |
| 14.14   | Phase 14 exit smoke + v0.1.0 release + final activation — (a) exit-smoke 5+ cases covering repl/nrepl/build/render-error/component-build(error-path; row 14.12 zwasm-v2-gated)/future-promise-delay/host-stdlib; (b) flip `build_options.phase_at_least_14 = true` — **milestone marker per ADR-0015 a5** (NOT a stub swap: `runtime/io/stub.zig` never existed; F142/F143/F144 landed ungated at 14.10/14.9/14.11; F140/F141 HTTP out of v0.1.0 scope), so the flip is `build.zig` + the `src/main.zig` manifest test only; (c) tag v0.1.0; flip §9.16 header DONE. 🔒 ubuntunote gate (per ADR-0049)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | [ ]                                                                                                                                                                                                                                                                                                                                                                         |

**Exit criterion**: all v0.1.0 deliverables shipped + v0.1.0
tagged + `phase_at_least_14 = true` (milestone marker per
ADR-0015 a5). F142/F143/F144 landed ungated (rows 14.9-14.11);
F140/F141 (HTTP) are out of v0.1.0 scope. 🔒 **ubuntunote**
x86_64 gate passes (per ADR-0049; OrbStack retired).

> **§9.17-9.22 reframed to the §9.0 gap-area model (ADR-0142).** These keep
> their numbered anchors for citation stability; the "PENDING, expand at entry"
> placeholders + the `phase_at_least_N` stub-swap "Final activation step"
> sentences are dropped because those impls SHIPPED. Each section now records
> BUILT status + the named gaps + the debt rows that drain them.

### 9.17 Gap area I — Concurrency hardening (formerly "Phase 15"; BUILT + race-hardened)

**Status: BUILT.** atom (`swap!`/`swap-vals!`/`reset!`/`reset-vals!`/CAS/
add-watch/remove-watch/set-validator!/get-validator) · volatile · ref+STM (full
MVCC `dosync`/`alter`/`commute`/`ensure`/`ref-set`, `runtime/stm/` +
`concurrency/lock_tx.zig`) · agent (send/send-off/await/await-for/agent-error/
restart-agent/error-mode/error-handler/validator/meta) · future/promise/delay ·
locking (`concurrency/object_monitor.zig`) · reduced · pmap/pcalls/pvalues
(sequential, result-correct). Race-hardened: `phase16_concurrency_stress.sh`
caught+fixed real races (atom non-atomic swap, STM doGet stale read); corpus
`test/diff/clj_corpus/concurrency.txt`.

**Gaps (the hardening front):**
- **clj-parity / load** — Track R R1 (this session: agent ctor options/D-441,
  await-for, swap-vals!/reset-vals!, io! — corpus-locked).
- **D-442** — `future-cancel`/`future-cancelled?`/`seque` (infra-gated) + the
  low-value legacy/executor agent surface (classify implement/AD/stub).
- **`:volatile-mutable` cross-thread happens-before — DONE 2026-06-16** (ADR-0152
  / D-444): volatile fields route through `@atomicLoad(.acquire)`/`@atomicStore(.release)`,
  distinct from the plain `:unsynchronized-mutable`. Un-accepted AD-018; the
  residual JMM IRIW cross-volatile total-order gap (acquire/release, not seq_cst)
  = AD-034.
- **D-105** — java.time trio (LocalDateTime/Duration/ZonedDateTime are skeletons;
  Instant + Date ship).
- **Gated-defer (engine correct without them)**: D-244 #4a' auto-collect
  (higher-risk; collect is explicit/test-triggered today), D-245 Option C
  blocking monitor (Option A spinning ships; gated on a real contention workload).

**Reference**: `private/JVM_TO_ZIG.md` §4-6. Entry ADRs 0009 (object-header lock)
/ 0010 (STM MVCC) are LANDED (ADR-0090/0092/0093). 🔒.

### 9.18 Gap area II — Wasm / edge-native (formerly "Phase 16"; component BUILT) · CLJS→JS = future

**Status: Wasm component BUILT.** `cljw.wasm/*` (`load`/`call`/`run`/
`component-exports`/`component-invoke`/`load-component`/`component-call`/
`require-component`) over `src/runtime/cljw/wasm/{engine,component,marshal,
surface}.zig`, embedding zwasm v2 (`@import("zwasm")`, F-001 — SHA-pinned dep,
interp-only). e2e `phase16_wasm_{run,component,ffi,require_component}.sh` (real,
build `-Dwasm`). Gated `-Dwasm` opt-in by design (lazy dep), NOT unimplemented.

**Gaps**: WIT param-type marshalling raises `feature_not_supported`
(`component.zig`) for some types → **D-404** (full WIT↔EDN table); zwasm
integration finished-form → **D-036 / D-350 / D-039** (responsibility split,
embedding shape). Entry facts: F-001 (zwasm unavoidable) · F-004 · F-006 · F-008
(zwasm v2 spec review). Consult zwasm `docs/zig_api_design.md` +
`docs/consuming_prerelease_zwasm.md` (the SHA-pin procedure).

**ClojureScript → JS compiler = genuinely-future bucket.** No `emit-js`/cljs
backend exists (only `#?(:clj/:cljs)` reader-conditional handling). The original
`.clj`-source transpiler design (ADR-0037 candidate, D-068) stands as future work;
F-010 de-prioritizes CLJS. cljw user-code path and zwasm wasm path stay separate
(F-001).

### 9.19 Gap area III — VM perf: fusion → JIT (formerly "Phase 17"; PARTIAL)

**Status: PARTIAL.** A real fusion/superinstruction slice landed: local-const /
local-LOCAL arith fusion + compare-and-branch fusion (**D-386 / O-018/019/021**,
`vm.zig` + `intrinsic.zig` + `opcode.zig`) + reduce/lazy-seq fusion (**O-023**).
The named `super_instruction.zig` file does not exist; the work it represents is
partly done.

**Gaps**: remaining fusion surface; the **narrow ARM64 JIT** (~1000 LOC, hot-loop
pattern-match, cw v0 Phase 37.4 shape — arith_loop ~10x evidence) = **F-010
milestone M** near-term; **broad JIT** go/no-go is distal (gap area / §9.22),
decided after fusion lands. **D-035** (extract a backend-shared `callable
dispatch` layer — `src/runtime/dispatch/callable.zig` + `src/eval/backend/jit/`
subtree — before a 3rd backend joins) · **D-005** (ARM64 JIT decision). If JIT go:
ADR-0022 amendment for 3-way differential (TreeWalk == VM == JIT). cljw's JIT is
an independent cljw-bytecode→native path (NOT via zwasm; F-001); bytecode ABI is
decoder-only-compatible (ADR-0033 D10 / ADR-0034 D6) so JIT go/no-go does not
perturb placement/build.

### 9.20 math + module/deps DONE (formerly "Phase 18") · C FFI = future

**Status: math + module/deps DONE.** `clojure.math` ships (`clojure/math.clj`,
e2e `phase14_math*`); the deps.edn resolver + the `modules/` zone rule already
exist (Phase 14). **C FFI = genuinely-future bucket**: no `dlopen`/`dlsym`/
`libffi`/`c_ffi`; `zig build -D<lib>` comptime-gated module builds are future
work, low priority.

### 9.21 Gap area II (cont.) — WIT auto-binding (formerly "Phase 19")

**Status: component require BUILT** (see §9.18). **Gap**: full WIT auto-binding
(`(wasm/component "x.wasm")` → bindgen → Clojure namespace) — some WIT param
marshalling is fixture-blocked → **D-404**; the zwasm integration shape is
**D-036 / D-350**. This is the same Wasm/edge-native gap area as §9.18.

### 9.22 broad JIT = future bucket (formerly "Phase 20"; distal)

**Status: UNBUILT (intentionally distal).** No `jit/` impl (only forward
comments). The near-term JIT scope is the **narrow ARM64 JIT** (milestone M,
gap area III / §9.19); a **broad ARM64/x86_64 JIT** with 3-way differential
(TreeWalk == VM == JIT) is decided only after the gap-area-III fusion outcome.
**D-005** (ARM64 JIT decision) is the entry debt.

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
- `.dev/debt.yaml` — debt ledger (row-level predicates, per A13)
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
- `.claude/rules/debt_dedup.md` — debt.yaml row de-duplication discipline (per A13)
- `.claude/rules/exploration_vs_done.md` — exploration / Done boundary (Pollaroid-derived)
- `.claude/rules/feature_name_consistency.md` — keyword consistency + Backend marker + `src/runtime/{java,cljw}/` surface layout (per ADR-0029 D1-D6; absorbed the former `java_cljw_surface_layout.md`, deleted per ADR-0062)
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

#### `.dev/known_issues.md` — SUPERSEDED (not created; `.dev/debt.yaml` is the ledger per ADR-0072)

> The template below is retained for historical context only. The row-level
> `debt.yaml` replaced this plan.

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

(This file exists at the repo root.) The planned companion rule
`.claude/rules/compat_tiers.md` was SUPERSEDED by
`.claude/rules/tier_classification.md` (the tier discipline rule that actually
landed); do not create `compat_tiers.md`.

#### `.dev/status/vars.yaml` — SUPERSEDED (not created)

Per-var tracking is covered by `placement.yaml` (Clojure-ns var placement SSOT,
ADR-0033) + `compat_tiers.yaml` (var/class tier). The originally-planned
`status/vars.yaml` + `generate_vars_yaml.clj` generator were not built.

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
