# T13.6: key, val, keys, vals, MapEntry ops

Phase 13c — Core.clj Expansion

## Goal

Add key/val builtins for MapEntry access. keys/vals already implemented.

## Result

- key/val added to sequences.zig as vector pair first/second
- keys/vals already done (no changes needed)
- Registry: 154 → 156 builtins
- No MapEntry value type needed — map entries are [k v] vectors

## Log

- TDD: 2 tests (key, val on vector pair), then implemented
- All unit + SCI tests pass (72/74, 259 assertions)
- E2E: (key (first {:a 1})) → :a, (val (first {:a 1})) → 1
