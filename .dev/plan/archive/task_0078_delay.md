# T9.12: delay, force, realized?

## Goal

Add delayed evaluation to core.clj:

- `delay` — wraps body in a thunk, evaluates on first deref/force
- `force` — forces a delay (or returns value if not a delay)
- `realized?` — checks if a delay has been forced

## Plan

1. Implement delay using atom-based approach (since no native delay type):
   - `(delay body)` -> creates a map {:\_\_delay true :thunk (fn [] body) :value (atom nil) :realized (atom false)}
2. force: check if delay, if so check realized, if not eval thunk and cache
3. realized?: check the :realized atom
4. Tests and vars.yaml

## Implementation Notes

Since we lack a native Delay type, we'll use a map with atoms for memoization.
This is a pragmatic approach — a native type would be more efficient but requires
Zig-level changes.

## Log

- Added delay, force, realized? to core.clj
- delay: macro creating map with :thunk, :value (atom), :realized (atom)
- force: checks \_\_delay flag, evaluates thunk on first call, caches via reset!
- realized?: checks :realized atom
- Memoization verified: thunk only called once
- All tests pass, no regressions
- vars.yaml updated: delay, force, realized? → done
