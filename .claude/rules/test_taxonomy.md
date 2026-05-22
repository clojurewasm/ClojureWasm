---
paths:
  - src/**/*.zig
  - test/**
  - bench/**
---

# Test taxonomy (5 layers)

## Rule

Every test belongs to exactly one of the 5 layers per ADR-0021.
Choose the layer before writing the test.

| # | Layer        | Where                                     | When to choose                                                                  |
|---|--------------|-------------------------------------------|---------------------------------------------------------------------------------|
| 1 | Unit         | `src/**/*.zig` inside `test "..."` blocks | Single function, deterministic, no I/O. Default.                                |
| 2 | E2E (CLI)    | `test/e2e/*.sh`                           | `cljw -e '...'` invocation surface, error message rendering, exit codes.        |
| 3 | Differential | `test/diff/cases.yaml`                    | TreeWalk and VM must produce equal Value for the same source. ADR-0005 / 0022.  |
| 4 | Bench quick  | `bench/quick.sh` + `bench/fixtures/`      | Performance baseline / regression catch (informational, never fails the build). |
| 5 | Conformance  | `test/clj/` (Phase 11+)                   | Adapted upstream Clojure JVM test.                                              |

## Why

- "Where does this test go?" was a recurring review question; the
  table answers it.
- The 5 layers match the runner steps in `test/run_all.sh`
  (zig_build_test, e2e_*, diff_runner, bench_quick, test_clj).
- ADR-0021 names 8 future layers (Integration, Golden, Property,
  Fuzz, Memleak, Concurrency, Bench full, Wasm component) — they
  open at their phase, not at Phase 4 entry.

## How to apply

### Decision rule

Ask in order:

1. Is it a single deterministic function call? → Layer 1.
2. Is it `cljw -e ...` / file invocation? → Layer 2.
3. Does it require TreeWalk and VM to agree? → Layer 3.
4. Is it a performance measurement? → Layer 4.
5. Is it an upstream Clojure test port (Phase 11+)? → Layer 5.

If none fit, the test is in a future layer (defer or open the
future layer's directory).

### Naming

- Layer 1: `test "<verb> <object> <expected>"`
  (e.g., `test "+ on two integers"`).
- Layer 2: file name `phase<N>_<scope>.sh`, case name in the file.
- Layer 3: `cases.yaml` `name:` is `<area>_<scenario>`
  (`closure_capture_local`, `recur_loop_n3`).
- Layer 4: bench fixture `bench/fixtures/<area>_<scenario>.clj`.
- Layer 5: upstream filename is preserved.

## Counter-examples

Don't write a Layer 1 unit test that shells out to `cljw` (that
belongs in Layer 2).

Don't write a Layer 3 case that does not exercise the
backend boundary (TreeWalk-only behaviour belongs in Layer 1).

Don't measure performance with a Layer 1 test (Layer 4 is the
home).
