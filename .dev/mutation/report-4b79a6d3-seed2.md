# Mutation sweep — 4b79a6d3 (seed 2)

- Candidates enumerated: 133
- Mutants run: 3
- Killed: 1
- Survived: 0
- Equivalent (registered, not scored): 2
- Unviable (did not compile): 0
- **Mutation score: 100.0%** (killed / (killed + survived))

No unexplained survivors in this sample.

## Equivalent — registered as unobservable

- `src/runtime/collection/vector.zig:284` const_bump_in_arith — Reached only when the tail holds exactly one element, i.e. count = 32m+1. arrayFor selects a 32-element leaf by i >> SHIFT_BITS, and (32m-1) >> 5 == (32m-2) >> 5, so `count - 2` and `count - 3` always name the same leaf. No input distinguishes them.
- `src/runtime/collection/vector.zig:529` const_bump_in_arith — popTail is entered only with new_count = 32m (a full-leaf boundary) and level >= SHIFT_BITS. new_count-1 and new_count-2 differ only in bit 0, which every level's >> level discards, so sub_index is identical at every level of the descent.

