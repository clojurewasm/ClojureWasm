# ClojureWasm Architecture

> A short orientation for new contributors. `.dev/ROADMAP.md` is the
> authoritative plan; this file is the entry point. ADRs in
> `.dev/decisions/` carry load-bearing decisions; this file
> summarises the shape.

## What ClojureWasm is

ClojureWasm (binary: `cljw`) is a Clojure language runtime written
in Zig 0.16. It does **not** target the JVM; it implements Clojure
semantics directly, with a TreeWalk interpreter + a bytecode VM as
dual backends and an embeddable WebAssembly engine boundary — a
polyglot FFI today (`zig build -Dwasm`), calling Wasm modules from
Clojure.

Charter: full Clojure compatibility for the Tier A subset
(~700 vars of `clojure.core` + key namespaces), single-binary
distribution, and batch / REPL / nREPL / `build` entry points.

## Four zones (layered architecture)

Source is divided into four zones with a strict downward-only
dependency rule (SSOT [`.claude/rules/zone_deps.md`](.claude/rules/zone_deps.md);
ROADMAP §A1):

| Zone | Path                       | Responsibility                                        |
|------|----------------------------|-------------------------------------------------------|
| 0    | `src/runtime/`             | Value, GC, collections, dispatch, env, error catalog  |
| 1    | `src/eval/`                | reader, analyzer, backends (`backend/{tree_walk,vm}`) |
| 2    | `src/lang/`                | primitives, host stdlib equivalents, bootstrap macros |
| 3    | `src/app/`, `src/main.zig` | CLI / REPL / nREPL / `build`                          |

Lower zones do not import upper zones; cross-zone calls go through
vtables installed at startup (`Runtime.vtable`). A second rule keeps
the host-surface trees apart: `runtime/cljw/**` and `runtime/java/**`
must not import each other. `scripts/zone_check.sh --gate` enforces
both against an in-script baseline.

## Dual backend

TreeWalk and the bytecode VM evaluate the same `analyzer` output
Node. `Evaluator.compare` (`--compare` on the CLI) runs both and
fails on a mismatch; the build's differential oracle runs `zig build
test` twice (the VM build + a `-Dbackend=tree_walk` build) so every
unit + diff case is checked on both backends (ADR-0005 / 0021 / 0022).
The VM has since grown an in-VM flattened call-frame stack (ADR-0131)
and superinstruction fusion (`op_*_local_const` / `op_*_locals` /
`op_branch_*` / `op_recur_loop`, plus a fused `reduce`; D-386) — all
VM-internal, still verified bit-for-bit against TreeWalk by the oracle.

## Error system

`src/runtime/error/catalog.zig` is the Single Source Of Truth for
every user-facing error message (ADR-0018). Other modules call
`error_catalog.raise(.code, loc, args)`; `setErrorFmt` stays inside
the `error/` subsystem (catalog + render internals), not arbitrary
call sites. The Zig error union is `ClojureWasmError`. Crash policy
distinguishes user input (Layer 1, catalog), runtime invariant
violation (Layer 2, `internal_error` / `raiseInternal`), and native
crash (Layer 3, top-level catch + signal handler) per ADR-0019.

## Tier system

Clojure compatibility is graded:

- **Tier A**: full semantic match, upstream test suite passes.
- **Tier B**: same names, same behaviour, cw-native implementation.
- **Tier C**: best-effort with documented gaps.
- **Tier D**: permanently excluded (`gen-class`, `gen-interface`,
  `compile`, deep proxy, deep bean, `java.awt.*`, `javax.swing.*`,
  `java.applet.*`, deep `java.lang.reflect.*`) per ADR-0013.

`data/compat_tiers.yaml` (repo root) is the authoritative classification
data, read by the Tier A PASS gate and the per-form `tier_d_<form>`
catalog Codes (ADR-0018 amendment 2).

## Current state

The core language is largely in place and exercised end-to-end:

- Reader, analyzer, both backends, the error system, persistent
  collections + a mark-sweep GC.
- The **numeric tower** (F-005): a single `f64` double plus three
  heap big types — arbitrary-precision `BigInt`, `Ratio`, and
  `BigDecimal` — with JVM-style auto-promotion (`Long`→`BigInt`,
  `(/ 1 3)`→`Ratio`, `1.5M`→`BigDecimal`).
- Lazy / chunked sequences, transducers; protocols, records,
  multimethods, `deftype` / `reify`.
- **Concurrency**: STM (`ref` / `dosync` / `alter` / `commute` /
  `ensure`), `atom`, `agent`, `future` / `promise` / `delay`,
  reference watches, `locking`, `volatile`, real OS threads.
- **Namespaces** + a full base-protocol **nREPL** (ADR-0170:
  sessions, `completions` / `lookup` / `eldoc`, `*1`..`*e` history,
  CLI-grade error rendering — CIDER works end-to-end), a
  `deps.edn`-aware classpath, and a growing set of `clojure.*`
  standard-library namespaces (`string` / `set` / `walk` / `zip` /
  `edn` / `math` / `pprint` / `test` / `repl` / `data.json` /
  `data.csv` / `tools.cli` …).
- A polyglot **WebAssembly FFI** behind `-Dwasm` (`wasm/load` +
  `wasm/call`), embedding the `zwasm` engine — whose JIT-backed
  engine (zwasm v2.2+) runs hot Wasm loops as native code.

Performance work is ledgered in `.dev/optimizations.md` (`O-NNN` rows;
`PERF:` markers in source anchor each site); the dedicated campaign
(ROADMAP §9.2.S) is paused with its baseline recorded in
`.dev/perf_v0_baseline.md`. On cold-start `cljw` beats or matches
CPython on most `bench/` workloads (see
[`bench/README.md`](bench/README.md)).

Releases are tagged (`v1.2.0` current; see `CHANGELOG.md`) and ship as
single binaries for macOS arm64 + Linux x86_64, plus a Homebrew tap
(`brew install clojurewasm/tap/cljw`). The original linear phase plan
is retired; remaining work is tracked as gap areas (ROADMAP §9.0:
concurrency-hardening / Wasm-edge-native / VM-perf) + a row-level debt
ledger (`.dev/debt.yaml`).

## Where to look

| Question                                   | File                                                     |
|--------------------------------------------|----------------------------------------------------------|
| What are the project's working principles? | `.dev/principle.md` (the meta layer)                     |
| Why is the architecture this way?          | `.dev/ROADMAP.md` §2 (principles), §4 (architecture)   |
| What load-bearing decision was made?       | `.dev/decisions/NNNN_*.md`                               |
| What is the current state?                 | `.dev/handover.md`                                       |
| What debt is tracked?                      | `.dev/debt.yaml`                                         |
| What namespace is at what tier?            | `data/compat_tiers.yaml`                                 |
| What does a term mean?                     | `.dev/ROADMAP.md` §16 (glossary)                        |
| What testing layer is what?                | `.dev/decisions/0021_test_taxonomy.md`, `test/README.md` |
| What rules apply to a `.zig` file edit?    | `.claude/rules/*.md` (auto-loaded per path)              |

## Build & test

```sh
# Per-commit smoke (fast: diff oracle ×2 + units + lint + build + the changed e2e)
bash test/run_all.sh --smoke <e2e-step>
# Full gate (batched alone at the ≤5-commit ceiling / phase boundary / pre-tag):
# zig build test ×2 (VM + tree_walk = the differential oracle) + zone/static
# checks + zlinter + build_cljw + corpus_regression + the e2e shell suite.
bash test/run_all.sh

zig build run -- -e '(+ 1 2)'       # eval inline expression
zig build -Dwasm -Doptimize=ReleaseSafe   # the shipped, Wasm-enabled binary
zig fmt src/                          # format
zig build lint -- --max-warnings 0    # zlinter (Mac-only, ADR-0003)
```

The two-tier gate is ADR-0107 (the full e2e suite grew heavy, so it
batches rather than running per commit). Performance is **not** a gate
step — it is measured on demand via `bench/compare_langs.sh` /
`bench/run_bench.sh` (bench was retired from the gate 2026-06-11).

Cross-platform coverage: CI runs the gate on macOS (arm64) and Linux
(x86_64) on every push and pull request. A maintainer can also drive a
native-Linux gate over SSH with `bash scripts/run_remote_ubuntu.sh`
(host + path are configurable via `CLJW_UBUNTU_HOST` / `CLJW_REMOTE_DIR`).

## Contributing

The agreement is documented in `CLAUDE.md` (working agreement +
workflow). The short version: TDD red → green → refactor, ROADMAP
§17 amendment policy for any deviation from the plan.
