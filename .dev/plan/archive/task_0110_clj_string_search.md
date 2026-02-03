# T13.4: clojure.string search/replace ops

Phase 13b — clojure.string namespace expansion

## Goal

Add includes?, starts-with?, ends-with?, replace to clj_string.zig.

## Result

- 4 functions added to src/common/builtin/clj_string.zig
- Builtins table: 5 → 9 entries
- All use simple string operations (no regex)
- replace does global replacement (all occurrences)

## Log

- Added TDD tests first (Red)
- Initial implementation used `.true` / `.false` → Value has `.boolean` field
- Fixed to `Value{ .boolean = ... }` pattern
- All unit tests pass
- E2E verified via TreeWalk
- SCI: 72/74 tests, 259 assertions (unchanged)
