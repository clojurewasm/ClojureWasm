# Test Porting Plan (Phase 42+)

Every implementation phase from Phase 42 onward MUST include upstream test porting
as an integral part of each iteration. Tests are not optional follow-up work.

## Iteration Protocol

Each sub-task (e.g., 43.5) follows this cycle:

1. **Implement** — TDD cycle (Red/Green/Refactor) with Zig unit tests
2. **Port upstream tests** — Find and port relevant tests from upstream Clojure
3. **Regression check** — Run ALL existing upstream tests, not just new ones
4. **Commit** — Implementation + tests together in one commit

## Upstream Test Porting Rules

### Loading Strategy (in priority order)

1. **Verbatim load**: Load the upstream test file as-is if no Java interop blocks it.
   Only adjust `(ns ...)` form if needed (e.g., remove `:import` for Java classes).
2. **CLJW adaptation**: If specific tests use Java interop, mark changes with
   `;; CLJW: <reason>` and adapt to CW equivalents. Never delete assertions.
3. **CLJW-ADD tests**: Add CW-specific tests for behavior not covered upstream
   (e.g., array seq integration, CW-specific error types).

### What to Port

For each implemented feature, check these upstream test locations:

| Feature Area          | Upstream Test File(s)                               |
|-----------------------|-----------------------------------------------------|
| Core functions        | `test_clojure/other_functions.clj`                  |
| Data structures       | `test_clojure/data_structures.clj`                  |
| Sequences             | `test_clojure/sequences.clj`                        |
| Numbers/Math          | `test_clojure/numbers.clj`, `test_clojure/math.clj` |
| Predicates            | `test_clojure/predicates.clj`                       |
| Control flow          | `test_clojure/control.clj`                          |
| Strings               | `test_clojure/string.clj`                           |
| Protocols             | `test_clojure/protocols.clj`                        |
| Multimethods          | `test_clojure/multimethods.clj`                     |
| Vars/Binding          | `test_clojure/vars.clj`                             |
| Arrays (Java interop) | `test_clojure/java_interop.clj` (array sections)    |
| Atoms                 | `test_clojure/atoms.clj`                            |
| Transducers           | `test_clojure/transducers.clj`                      |
| Transients            | `test_clojure/transients.clj`                       |

Upstream location: `/Users/shota.508/Documents/OSS/clojure/test/clojure/test_clojure/`

### File Header (required)

```clojure
;; Upstream: clojure/test/clojure/test_clojure/<name>.clj
;; Upstream lines: <N>
;; CLJW markers: <K>
```

### Marker Format

```clojure
;; CLJW: <description>         -- semantic change (Java -> CW equivalent)
;; CLJW-ADD: <reason>          -- test not in upstream
```

## Regression Check

After porting tests for a sub-task, run the FULL upstream test suite:

```bash
# Run all upstream tests (both backends)
for f in test/upstream/clojure/test_clojure/*.clj; do
  echo "=== $f ==="
  ./zig-out/bin/cljw "$f" 2>&1 | tail -2
done

# TreeWalk
for f in test/upstream/clojure/test_clojure/*.clj; do
  echo "=== $f ==="
  ./zig-out/bin/cljw --tree-walk "$f" 2>&1 | tail -2
done
```

Or use the runner script if available:
```bash
bash test/upstream/run_all.sh
```

## Already Ported Files (39 files)

See `test/upstream/clojure/test_clojure/` for the full list.
Key files with high assertion counts:
- sequences.clj (1654 upstream lines, 39 CLJW markers)
- data_structures.clj (1363 upstream lines, 35 CLJW markers)
- numbers.clj (959 upstream lines, 60 CLJW markers)
- control.clj (446 upstream lines, 21 CLJW markers)
- math.clj (327 upstream lines, 13 CLJW markers)

## Phase 42-43 Test Porting Status

### Phase 42: Quick Wins + Protocol Extension

| Sub-task | Features                                 | Upstream Test File  | Status                  |
|----------|------------------------------------------|---------------------|-------------------------|
| 42.1     | uri?, uuid?, destructure                 | other_functions.clj | N/A (no upstream tests) |
| 42.2     | extend, extenders, extends?, find-*      | protocols.clj       | DONE                    |
| 42.3     | get-thread-bindings, bound-fn*, bound-fn | vars.clj            | DONE                    |

### Phase 43: Numeric Types + Arrays

| Sub-task | Features                        | Upstream Test File     | Status |
|----------|---------------------------------|------------------------|--------|
| 43.1-4   | Array ops, typed arrays, macros | arrays.clj (ported)    | DONE   |
| 43.5     | BigInt, bigint, biginteger      | numbers.clj (24t/276a) | DONE   |
| 43.6     | BigDecimal, bigdec, M literal   | numbers.clj (26t/323a) | DONE   |
| 43.7     | +', *', -', inc', dec'          | numbers.clj            | TODO   |
| 43.8     | Ratio, numerator, denominator   | numbers.clj            | TODO   |
