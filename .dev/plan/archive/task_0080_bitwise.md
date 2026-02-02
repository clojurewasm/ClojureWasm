# T9.14: bit-and, bit-or, bit-xor, bit-not, bit-shift-left, bit-shift-right

## Goal

Add bitwise operations as Zig builtins:

- `bit-and` — bitwise AND
- `bit-or` — bitwise OR
- `bit-xor` — bitwise XOR
- `bit-not` — bitwise NOT (complement)
- `bit-shift-left` — left shift
- `bit-shift-right` — right shift

## Plan

1. Add implementations in numeric.zig
2. Add BuiltinDefs to builtins table
3. Update registry count test
4. Add unit tests
5. Update vars.yaml

## Log

- Added bit-and, bit-or, bit-xor, bit-not, bit-shift-left, bit-shift-right to numeric.zig
- All integer-only, error on non-integer args
- Shift range checked: 0-63
- Registry count updated: 97 → 103
- All tests pass, no regressions
- vars.yaml updated: all 6 bitwise ops → done
