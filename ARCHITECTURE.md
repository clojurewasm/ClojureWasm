# ClojureWasm Architecture

> 5-minute orientation for new contributors. ROADMAP.md is the
> authoritative plan; this file is the entry point. ADRs in
> `.dev/decisions/` carry load-bearing decisions; this file
> summarises the shape.

## What ClojureWasm is

ClojureWasm (binary: `cljw`) is a Clojure language runtime written
in Zig 0.16. It does **not** target the JVM; it implements Clojure
semantics directly, with TreeWalk + bytecode VM dual backends and
an opt-in WebAssembly module boundary for Phase 16+.

Charter: full Clojure compatibility for the Tier A subset
(~700 vars of `clojure.core` + key namespaces), single-binary
distribution, batch / REPL / nREPL / build / Wasm-component output.

## Four zones (layered architecture)

Source is divided into four zones with a strict downward-only
dependency rule (ROADMAP §A1, enforced by `scripts/zone_check.sh`):

| Zone | Path                       | Responsibility                                        |
|------|----------------------------|-------------------------------------------------------|
| 0    | `src/runtime/`             | Value, GC, collections, dispatch, env, error catalog  |
| 1    | `src/eval/`                | reader, analyzer, backends (tree_walk, vm)            |
| 2    | `src/lang/`                | primitives, host stdlib equivalents, bootstrap macros |
| 3    | `src/app/`, `src/main.zig` | CLI / REPL / nREPL / builder / Wasm-component out     |

Lower zones do not import upper zones. Cross-zone calls go through
vtables installed at startup (`Runtime.vtable`).

## Dual backend

TreeWalk and bytecode VM evaluate the same `analyzer` output Node.
From Phase 4 onward, `Evaluator.compare(rt, env, src)` runs both
backends on every e2e test and fails the build on mismatch
(ADR-0005, ADR-0021, ADR-0022). When Phase 17 introduces JIT, the
comparison extends to a third backend without changing the runner
shape.

## Error system

`src/runtime/error_catalog.zig` is the Single Source Of Truth for
every user-facing error message (ADR-0018). Other modules call
`error_catalog.raise(.code, loc, args)`; direct `setErrorFmt` is
reserved for the catalog file. The Zig error union is
`ClojureWasmError` (full spelling). Crash policy distinguishes
user input (Layer 1, catalog), runtime invariant violation
(Layer 2, `internal_error` catalog code), and native crash
(Layer 3, top-level catch + signal handler) per ADR-0019.

## Tier system

Clojure compatibility is graded:

- **Tier A**: full semantic match, upstream test suite passes.
- **Tier B**: same names, same behaviour, cw-native implementation.
- **Tier C**: best-effort with documented gaps.
- **Tier D**: permanently excluded (gen-class, gen-interface,
  compile, deep proxy, deep bean, java.awt.*, javax.swing.*,
  java.applet.*, deep java.lang.reflect.*) per ADR-0013.

`compat_tiers.yaml` (repo root) is the authoritative classification
data. The runtime reads it for the Tier A 100% PASS gate and the
per-form `tier_d_<form>` catalog Codes (ADR-0018 amendment 2).

## Phase progression

20 phases from bootstrap (Phase 1) to mature runtime + Wasm
distribution (Phase 20). Current state and per-phase task tables
live in ROADMAP §9. The big landmarks:

- **Phase 1-3 (DONE)**: reader, analyzer, TreeWalk, error rendering,
  bootstrap macros, exception handling.
- **Phase 4 (IN-PROGRESS)**: bytecode VM, dual-backend, scaffolding.
- **Phase 5**: persistent collections, mark-sweep GC, lazy-seq,
  numeric tower.
- **Phase 7**: protocols, multimethods, transducers.
- **Phase 11**: upstream Clojure test port (Tier A 100% PASS gate).
- **Phase 14**: future / promise / delay, nREPL, v0.1.0 release.
- **Phase 15**: STM, atom, agent, locking activation.
- **Phase 16**: Wasm component output via Pod boundary.
- **Phase 17**: JIT go / no-go.

## Where to look

| Question                                   | File                                                     |
|--------------------------------------------|----------------------------------------------------------|
| What are the project's working principles? | `.dev/principle.md` (the meta layer)                     |
| Why is the architecture this way?          | `.dev/ROADMAP.md` §2 (principles), §4 (architecture)   |
| What load-bearing decision was made?       | `.dev/decisions/NNNN_*.md`                               |
| What is the current state?                 | `.dev/handover.md`                                       |
| What debt is tracked?                      | `.dev/debt.yaml`                                         |
| What namespace is at what tier?            | `compat_tiers.yaml`                                      |
| What does a term mean?                     | `.dev/ROADMAP.md` §16 (glossary)                        |
| What testing layer is what?                | `.dev/decisions/0021_test_taxonomy.md`, `test/README.md` |
| What rules apply to a `.zig` file edit?    | `.claude/rules/*.md` (auto-loaded per path)              |

## Build & test

```sh
bash test/run_all.sh         # full test suite (zig build test + zone check + e2e + bench)
zig build run                 # run executable (`cljw`)
zig build run -- -e '(+ 1 2)' # eval inline expression
zig fmt src/                  # format
zig build lint -- --max-warnings 0  # zlinter (Mac-only, ADR-0003)
```

Cross-platform gate (manual / Phase boundary as of ADR-0049):
the `ubuntunote` SSH host (native x86_64 Linux). Setup in
[`.dev/ubuntunote_setup.md`](.dev/ubuntunote_setup.md). Run with
`bash scripts/run_remote_ubuntu.sh`. OrbStack
(`.dev/orbstack_setup.md`) is retained as a dev convenience host
but is no longer in the per-commit gate.

## Contributing

The agreement is documented in `CLAUDE.md` (working agreement +
workflow). The short version: TDD red → green → refactor, ROADMAP
§17 amendment policy for any deviation from the plan, never push
to remote without explicit approval.
