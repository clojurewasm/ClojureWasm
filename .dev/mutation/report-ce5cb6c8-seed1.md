# Mutation sweep — ce5cb6c8 (seed 1)

- Candidates enumerated: 141
- Mutants run: 8
- Killed: 3
- Survived: 3
- Unviable (did not compile): 2
- **Mutation score: 50.0%** (killed / (killed + survived))

## Survivors — each is a line no test constrains

| file | line | operator | change |
|---|---:|---|---|
| `src/runtime/collection/vector.zig` | 284 | const_bump_in_arith | `const new_tail_leaf = arrayFor(old, old.count - 2);` -> `const new_tail_leaf = arrayFor(old, old.count - 3);` |
| `src/runtime/collection/vector.zig` | 529 | const_bump_in_arith | `const sub_index = ((new_count - 1) >> @as(u5, @intCast(level))) & MASK;` -> `const sub_index = ((new_count - 2) >> @as(u5, @intCast(level))) & MASK;` |
| `src/runtime/collection/vector.zig` | 534 | bool_and_to_or | `if (new_child == null and sub_index == 0) {` -> `if (new_child == null or sub_index == 0) {` |

### Survivors per file

- `src/runtime/collection/vector.zig`: 3
