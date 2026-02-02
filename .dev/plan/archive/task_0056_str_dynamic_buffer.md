# T7.2: str Dynamic Buffer (F12)

## Goal

Replace fixed 4KB buffer in str/pr-str with dynamic Writer.Allocating.

## Problem

`strFn`, `strSingle`, `prStrFn` use `var buf: [4096]u8 = undefined` with fixed Writer.
Large string operations fail with StringTooLong error.

## Plan

1. Replace `Writer = .fixed(&buf)` with `Writer.Allocating = .init(allocator)`
2. Use `.written()` or `.toOwnedSlice()` to get result
3. Add test: str concatenation > 4KB works

## Log

- Starting T7.2
- Replaced fixed `var buf: [4096]u8` with `Writer.Allocating` in strFn, strSingle, prStrFn
- Added test: 60 \* 100 = 6000 byte string concatenation succeeds
- All 657 tests pass (656 + 1 new)
- DONE
