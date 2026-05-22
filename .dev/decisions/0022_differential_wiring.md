# 0022 — Differential test wiring (TreeWalk + VM, Phase 17+ JIT)

- **Status**: Accepted
- **Date**: 2026-05-23
- **Author**: Shota Kudo (drafted with Claude)
- **Tags**: phase-4-entry, test, differential, dual-backend, runner

## Context

ADR-0005 declares "dual-backend differential testing is the
oracle, CI mandatory from Phase 4". ADR-0005 sets the direction but
does not specify *how* the runner is shaped, where cases live, or
how a third backend (JIT) extends the layout in Phase 17.

ADR-0021 places the differential layer at slot 3 of the test
taxonomy but defers the implementation contract to this ADR.

## Decision

`test/diff/` is the differential layer's home.

### Files

```
test/diff/
  README.md        ← V5-1 landing (this commit)
  runner.zig       ← Phase 4 task 4.10 landing
  cases.yaml       ← Phase 4 task 4.10 landing
  fixtures/        ← Phase 4 task 4.10 landing (per-case Clojure sources)
```

### runner.zig shape

```zig
//! test/diff/runner.zig — differential runner per ADR-0022.
//!
//! Pulls cases.yaml at comptime via @embedFile, dispatches each
//! case to TreeWalk and VM, compares Value bit-for-bit.

const std = @import("std");
const testing = std.testing;
const Evaluator = @import("../../src/eval/evaluator.zig").Evaluator;

const cases_yaml = @embedFile("cases.yaml");

test "differential cases" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = try parseCases(alloc, cases_yaml);

    var rt = try Runtime.init(alloc);
    defer rt.deinit();

    for (cases) |case| {
        if (case.skip_reason) |reason| {
            std.debug.print("[skip] {s}: {s}\n", .{ case.name, reason });
            continue;
        }
        const result = try Evaluator.compare(&rt, rt.root_env, case.src);
        if (!result.equal) {
            std.debug.print(
                "DIFF: {s}\n  tree_walk = {f}\n  vm = {f}\n",
                .{ case.name, result.tree_walk, result.vm },
            );
            return error.DifferentialMismatch;
        }
    }
}
```

`parseCases` is a thin YAML reader (no full YAML spec; just the
subset needed for cases.yaml).

### cases.yaml schema

```yaml
cases:
  - name: arith_add_basic
    src: "(+ 1 2)"
    expected: 3
    skip_reason: null

  - name: closure_capture_local
    src: |-
      ((let* [x 1] (fn* [y] (+ x y))) 2)
    expected: 3
    skip_reason: null

  - name: try_catch_returns_handler_value
    src: |-
      (try* (throw (ex-info "boom" {})) (catch ExceptionInfo e :caught))
    expected: ":caught"
    skip_reason: null

  - name: lazy_seq_realisation_order
    src: "(take 3 (map inc (range)))"
    expected: "(1 2 3)"
    skip_reason: "Layer 1 covers this; differential not needed for Phase 4."
```

The `expected` field is informational (the runner does not assert
against it; the runner asserts TreeWalk == VM). It documents what
the case should evaluate to so a reviewer can sanity-check.

### Phase 17 extension to 3-way

When JIT lands:

```zig
const result = try Evaluator.compareThree(&rt, rt.root_env, case.src);
if (!(result.tw_eq_vm and result.tw_eq_jit)) {
    return error.DifferentialMismatch;
}
```

The case file does not change; only `runner.zig` adopts the 3-way
helper. ADR-0005 amendment at Phase 17 entry codifies this.

### Wiring into `test/run_all.sh`

`test/run_all.sh` calls `zig build test`, which discovers the
inline `test "differential cases"` block in `runner.zig` along with
the unit tests. No separate runner binary.

## Alternatives considered

### Alternative A — Cases written as Zig `test "..."` blocks

- **Sketch**: each case is a `test "name"` block in `runner.zig`.
- **Why rejected**: cases.yaml is easier to edit by people who
  don't write Zig, and a `skip_reason` per case is simpler to
  manage than a Zig `if` guard. The case list grows to dozens in
  Phase 4-5 and hundreds by Phase 11.

### Alternative B — Bash script wrapper around `cljw`

- **Sketch**: `test/diff/runner.sh` invokes `cljw -e '...'` twice
  and diffs stdout.
- **Why rejected**: bytes-level stdout diff is noisy (Value
  formatting differences, source-location lines). The
  `Evaluator.compare()` API at the Zig level returns a structured
  `result` and `.equal` boolean, which is the right granularity.

## Consequences

- **Positive**: differential cases live in one YAML, editable
  without Zig knowledge. Phase 17 extension to 3-way is a
  one-line change in `runner.zig`. The runner is `zig build test`
  native, no extra wiring.
- **Negative**: a custom YAML reader in `parseCases`. Acceptable
  scope (case file format is small), but adds ~50 lines to
  `runner.zig`.
- **Neutral / follow-ups**: when fixtures get reused (Phase 5+),
  `test/diff/fixtures/*.clj` files can be referenced by
  `case.fixture: path/to/file.clj` instead of inline `src`.

## Affected files

- `test/diff/README.md` (new, this commit)
- `test/diff/runner.zig` (Phase 4 task 4.10)
- `test/diff/cases.yaml` (Phase 4 task 4.10)
- `test/diff/fixtures/` (Phase 4 task 4.10, populated as cases grow)
- `src/eval/evaluator.zig` (Phase 4 task 4.10, `compare()` API)

## References

- ADR-0005 (Dual-backend differential oracle, parent decision)
- ADR-0021 (Test taxonomy, Layer 3)
- ROADMAP §9.6 task 4.10 (`Evaluator.compare()`)

## Revision history

- 2026-05-23: Status: Proposed -> Accepted (initial landing).
