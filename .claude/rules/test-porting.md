# Test Porting Rules

Auto-load paths: `test/**/*.clj`

## Prohibited (NEVER)

1. Reduce test cases or change expected values to make tests pass
2. Replace exception tests with `:unreachable` or sentinel values
3. Delete `thrown?` assertions
4. Expand upstream `are` into individual `is` (are macro works)
5. Mix original tests into upstream test files
6. Change assertion expected values to match incorrect implementation behavior

## Required (ALWAYS)

1. Preserve upstream `(ns ...)` form (mark changes with `;; CLJW:`)
2. Preserve upstream copyright notices verbatim
3. Mark ALL changes with `;; CLJW: <reason>` marker
4. Run both VM + TreeWalk before committing

## On Test Failure

1. Identify cause: unimplemented / bug / semantic diff / Java-only
2. Unimplemented → implement the missing feature or fix the bug
3. Bug → fix in place
4. Java-only (pure JVM interop: class hierarchy, JMX, classloaders) → mark with `;; CLJW: JVM interop`

## Marker Format

```
;; CLJW: <description>         — semantic change (Java→Zig equivalent)
;; CLJW-ADD: <reason>          — test not in upstream
```

## File Header (required for each ported file)

```clojure
;; Upstream: clojure/test/clojure/test_clojure/<name>.clj
;; Upstream lines: <N>
;; CLJW markers: <K>
```

## Guardrails

- **Implement, don't work around.** Test failure = implementation issue.
  Fix the implementation, never change expected values.
- **No skipping.** If a test fails, implement the missing feature or fix
  the bug. The only exception is pure JVM interop (Java class hierarchy,
  JMX, classloaders, etc.) which is physically impossible to implement.
- **No assertion reduction.** Ported file assertion count must match upstream.
- **Both backends.** Verify on VM + TreeWalk.
