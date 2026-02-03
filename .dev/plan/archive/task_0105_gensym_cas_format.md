# T12.8: gensym, compare-and-set!, format

## Goal

Add 3 misc Tier 1 utility builtins.

## Plan

1. gensym: global counter + prefix, returns unique symbol
2. compare-and-set!: CAS on atom (single-threaded, simple compare+swap)
3. format: Java String.format-style, supports %s %d %f %%

## Log

- Created `src/common/builtin/misc.zig` with 3 builtins
- gensym: uses global u64 counter, default prefix "G\_\_"
- compare-and-set!: eql-based comparison on atom value
- format: uses formatStr (not formatPrStr) for %s — str semantics, not pr-str
- 8 unit tests
- Registry: 149 -> 152 builtins
- CLI verified: all 3 builtins work end-to-end
- All tests pass (full suite)
