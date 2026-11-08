# Mutation sweep — ac3a7ff0 (seed 1)

- Candidates enumerated: 280
- Mutants run: 12
- Killed: 4
- Survived: 7
- Equivalent (registered, not scored): 0
- Unviable (did not compile): 1
- **Mutation score: 36.4%** (killed / (killed + survived))

## Survivors — each is a line no test constrains

| file | line | operator | change |
|---|---:|---|---|
| `src/runtime/print.zig` | 293 | cmp_gt_to_ge | `while (ks.tag() == .list and list_collection.countOf(ks) > 0) : (ks = list_collection.rest(ks)) {` -> `while (ks.tag() == .list and list_collection.countOf(ks) >= 0) : (ks = list_collection.rest(ks)) {` |
| `src/runtime/print.zig` | 386 | cmp_gt_to_ge | `if (items.items.len > lim) break;` -> `if (items.items.len >= lim) break;` |
| `src/runtime/print.zig` | 441 | cmp_eq_to_ne | `while (t.tag() == .list and list_collection.countOf(t) > 0) : (t = list_collection.rest(t)) {` -> `while (t.tag() != .list and list_collection.countOf(t) > 0) : (t = list_collection.rest(t)) {` |
| `src/runtime/print.zig` | 847 | branch_force_true | `if (i > 0) try w.writeAll(sep);` -> `if (true) try w.writeAll(sep);` |
| `src/runtime/print.zig` | 1261 | cmp_eq_to_ne | `if (inst.field_count >= 1 and inst.fields()[0].tag() == .integer) {` -> `if (inst.field_count >= 1 and inst.fields()[0].tag() != .integer) {` |
| `src/runtime/print.zig` | 1480 | branch_force_true | `if (!first.*) try w.writeAll(if (kv) ", " else " ");` -> `if (!first.*) try w.writeAll(if (true) ", " else " ");` |
| `src/runtime/print.zig` | 1496 | cmp_lt_to_le | `while (j < child_count) : (j += 1) {` -> `while (j <= child_count) : (j += 1) {` |

### Survivors per file

- `src/runtime/print.zig`: 7

