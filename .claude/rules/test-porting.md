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
4. When skipping, keep upstream code as comment: `;; CLJW-SKIP: <F## reason>`
5. Run both VM + TreeWalk before committing

## On Test Failure

1. Identify cause: unimplemented / bug / semantic diff / Java-only
2. Unimplemented → create F## entry + CLJW-SKIP (impl goes to Phase B)
3. Bug → fix in place
4. Java-only → CLJW-SKIP: JVM interop

## Marker Format

```
;; CLJW: <description>         — semantic change (Java→Zig equivalent)
;; CLJW-SKIP: <F## reason>    — skip (F## reference required)
;; CLJW-ADD: <reason>          — test not in upstream
```

## File Header (required for each ported file)

```clojure
;; Upstream: clojure/test/clojure/test_clojure/<name>.clj
;; Upstream lines: <N>
;; CLJW markers: <K>
;; CLJW-SKIP count: <J>
```

## Guardrails

- **Implement, don't work around.** Test failure = implementation issue.
  Never change expected values.
- **CLJW-SKIP requires F## reference.** Every skipped test needs a
  checklist.md entry.
- **No assertion reduction.** Ported file assertion count must not be
  less than upstream (excluding CLJW-SKIP).
- **Both backends.** Verify on VM + TreeWalk.
