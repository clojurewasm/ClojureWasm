# cw v1 test layout

> 8 layers (ADR-0021 + ADR-0186). `test/run_all.sh` is the single entry point.
>
> **Contributors: read [`docs/testing.md`](../docs/testing.md) first** — this
> file is the in-tree map, that one is the guide (how to run each layer, how to
> read its failures, where a new test belongs).

## Layers

| # | Layer             | Where                                     | Tool                  | Open at               |
|---|-------------------|-------------------------------------------|-----------------------|-----------------------|
| 1 | Unit              | `src/**/*.zig` inside `test "..."` blocks | `zig build test`      | Phase 0               |
| 2 | E2E (CLI)         | `test/e2e/*.sh`                           | bash + `cljw`         | Phase 2               |
| 3 | Differential      | `test/diff/`                              | `Evaluator.compare()` | Phase 4               |
| 4 | Bench (on demand) | `bench/compare_langs.sh` / `run_bench.sh` | bash + `cljw`         | on demand (not gated) |
| 5 | Conformance       | `test/clj/` (Phase 11+)                   | `clojure.test`        | Phase 11              |
| 6 | Golden snapshot   | `test/golden/`                            | `test/golden/run.sh`  | ADR-0186              |
| 7 | Property          | `src/testing/prop_*.zig` (see `test/prop/README.md`) | `zig build test` | ADR-0186         |
| 8 | Mutation          | `scripts/mutation/`                       | `scripts/mutation/run.sh` | ADR-0186 (on demand) |

## "Where does this test go?"

- **Single function, deterministic, no I/O**: Layer 1 (inline next
  to the function).
- **CLI smoke / `cljw -e '...'` works end-to-end**: Layer 2.
- **Same Clojure source must produce the same Value on both
  backends (TreeWalk + VM)**: Layer 3.
- **Performance measurement**: Layer 4 — run on demand via `bench/`
  (no longer part of the gate as of 2026-06-11).
- **Upstream Clojure JVM test (port)**: Layer 5 (Phase 11+).
- **Everything a program printed must stay the same**: Layer 6 — a whole-program
  stdout/stderr/exit snapshot, for when the thing to protect is the output as a
  whole rather than one asserted substring.
- **A law that must hold for every input, not just the chosen ones**: Layer 7.
- **"Does any test actually constrain this line?"**: Layer 8 — not a test, a
  measurement of the others. On demand; never in the per-commit gate.

## Running

```sh
bash test/run_all.sh                # all layers, every gate
zig build test                       # Layer 1 only
bash test/e2e/phase3_cli.sh          # one specific e2e
bash bench/compare_langs.sh --cold   # Layer 4: cross-language perf (on demand)
```

`test/run_all.sh` accepts `--skip <name>` / `--only <name>` /
`--list` flags (per ADR-0024 run_step pattern).

## Future layers (still deferred)

`test/integration/` (Phase 5+) and `fuzz/` (Phase 6+) remain unopened.
Golden, property and mutation opened with ADR-0186; `test/clj/` opened at
Phase 11. Directories are created when a layer opens, not as empty
placeholders.

## Conventions

- Inline `test "..."` block name describes the user-visible
  behaviour, not the internal mechanism (`test "+ on two integers"`,
  not `test "primAdd inline call"`).
- Shell e2e exits non-zero on failure, prints a one-line summary
  including the failing case name.
- `test/diff/cases.yaml` (Phase 4 task 4.10) lists every
  differential case with a `skip_reason: null` (enabled) or text
  (skipped with reason).
