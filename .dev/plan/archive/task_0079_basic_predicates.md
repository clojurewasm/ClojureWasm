# T9.13: boolean, true?, false?, some?, any?

## Goal

Add basic predicate functions:

- `boolean` — coerce to boolean
- `true?` — is value exactly true?
- `false?` — is value exactly false?
- `some?` — is value not nil?
- `any?` — always returns true

## Plan

1. Add to core.clj (simple enough, no Zig builtins needed)
2. Tests in bootstrap.zig
3. Update vars.yaml

## Log

- Added boolean, true?, false?, some?, any? to core.clj
- All very simple: boolean=(if x true false), true?/false?=(= x true/false), some?=(not (nil? x)), any?=true
- All tests pass, no regressions
- vars.yaml updated
