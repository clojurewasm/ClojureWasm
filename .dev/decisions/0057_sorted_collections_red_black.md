# 0057 — Sorted collections: persistent left-leaning red-black tree

**Status**: Accepted (Devil's-advocate fork landed 2026-05-30; adopted the DA's finished-form Alt-2 over the survey's smallest-diff flat-array)
**Date**: 2026-05-30
**Author**: Shota Kudo (drafted with Claude autonomous loop)
**Tags**: sorted-map, sorted-set, red-black, persistent, F-002, F-004, F-006, A6, ADR-0053, gap-sweep

## Context

`sorted-map` / `sorted-set` / `sorted-map-by` / `sorted-set-by` / `subseq`
/ `rsubseq` / `rseq` / `sorted?` are unimplemented (corpus gap sweep,
`.dev/core_coverage_gaps.md`). Tags `sorted_map = 46` / `sorted_set = 47`
are day-1 reserved; no interior-node struct was reserved. `compare` /
`runtime/compare.zig::valueCompare` (ADR-0053, D-137) already provides a
general 3-way comparator with a defined cross-type order, so there is no
prerequisite. The open question is the **representation**.

The Step-0 survey (`private/notes/phaseA26-sorted-coll-survey.md`)
recommended a **flat sorted array** `[k0 v0 k1 v1 …]` + binary search, on
the grounds that a persistent red-black tree "buys speed, not a cleaner
shape." A mandatory Step-0.6 Devil's-advocate fork pressure-tested that
recommendation against F-002 and found it to be smallest-diff bias.

## Decision

Sorted collections use a **persistent left-leaning red-black (LLRB) tree**
(Sedgewick variant — one node struct + `color` field + 2-3 rotation
helpers, far less code than JVM `PersistentTreeMap`'s 8-subclass
hierarchy), in a new `runtime/collection/sorted.zig`:

- `SortedMap { header, count: u32, comparator: Value, root: Value, meta: Value }`;
  interior `RbNode { header, color: u8, _pad, key, val, left, right }`
  under a new `rb_node` tag (claims `reserved_c11 = 43`).
- `SortedSet` **wraps a SortedMap** (element→element), mirroring the
  existing `PersistentHashSet`→map precedent.
- Default comparator = `valueCompare` (ADR-0053); `-by` variants carry a
  custom comparator Value invoked via `rt.vtable.callFn` /
  `invokeCallable` (the path `sort` already uses). Duplicate keys collapse
  by comparator-equality (compare → 0).
- `assoc`/`dissoc` are O(log n) **path-copy with structural sharing** —
  the same persistent contract the HAMT, CHAMP, and vector trie honor.
- Dispatch: `sorted.zig` owns both tags; the primitive chokepoints
  (`collection.zig`, `sequence.zig`, `lookup.zig` IFn, `print.zig`) gain
  `.sorted_map`/`.sorted_set` arms. map.zig is NOT extended (already >1000
  LOC, A6). `rb_node` gets a `traceGc` (left/right/key/val) like
  `traceHamtMapNode`.

Cycle split: **A** structs + GC + `valueCompare`-ordered build / get /
contains / count / seq + `sorted-map`/`sorted-set` + `sorted?`; **B**
insert-rebalance assoc/dissoc-delete (the hard LLRB delete) + dup-collapse
+ `-by`; **C** in-order `seqFrom` leaf + `.clj` `subseq`/`rsubseq` + `rseq`
+ flip `reversible?` (currently hardcoded to `vector?`).

## Alternatives considered

The Devil's-advocate subagent (fresh context, briefed with the F-NNN
envelope) produced these, reflected verbatim:

**Alt 1 — Smallest-diff: set-wraps-map + entries as a raw `[*]Value` heap
slice (one new `sorted_entries` tag).** Better: most cache-friendly
contiguous scan; reuses set-over-map. Breaks: adds a GC tag AND a *novel*
variable-length realloc allocation idiom the codebase has never used
(every existing struct is fixed-size inline); O(n) copy on every assoc.
F-NNN: respects all, but is "the textbook Smallest-diff-bias path —
minimizes feature-LOC while adding a GC tag + novel idiom, the trade F-002
says is wrong."

**Alt 2 — Finished-form-clean: persistent LLRB red-black tree (`rb_node`),
structural sharing on every assoc/dissoc.** Better: the ONLY alternative
honoring the persistent structural-sharing contract every other cljw
collection already honors; `(into (sorted-map) coll)` — the idiomatic
construction path — is O(n log n) vs the flat array's **O(n²)**;
`subseq`/`seqFrom` is a natural in-order tree walk matching the JVM
reference. Costs: LLRB delete is the hardest single algorithm in the
collection lib (no v0 precedent); claims the last free C tag; many small
node allocs (same *kind* as HAMT/vector, not a new idiom). F-NNN: respects
all (F-004 spend a reserved tag = memo per F-002; F-006 trace; A6 ~500-700
LOC, split set out if needed). **The alternative F-002 points at.**

**Alt 3 — Wildcard: inline-array small + promote-to-RB at a threshold
(ArrayMap→HAMT analogue).** Better: cache-friendly + no-new-idiom for the
common small case AND O(log n) for large; mirrors cljw's existing hash-map
promotion. Costs: highest total complexity (both paths + the
promote/demote boundary); cannot ship without first writing Alt 2's hard
delete; small-map win over plain RB is marginal (log 16 = 4). File as a
post-RB debt row if profiling later shows node-alloc overhead.

**DA verdict (paraphrased):** the flat array does NOT hold under F-002.
"Finished form = simple form" conflates simplicity-of-algorithm with
cleanliness-of-shape; for a *persistent* collection the clean shape is the
structural-sharing one, and an O(n)-copy-on-assoc collection sitting next
to four O(log n) path-copy collections is the *inconsistent* shape. The
O(n²) idiomatic-construction path is the main path quadratically degraded,
not a tail case. "RB delete is hard / ~200 LOC" is the named
Cycle-budget-defer smell, which F-002 forbids as a basis for choosing.
Sub-choices: if flat were chosen, entries-as-PersistentVector beats a raw
slice (no new tag); sorted-set should wrap-a-sorted-map (the established
set-over-map shape), diverging from the survey's independent-array lean.
**Recommendation: Alt 2 (LLRB, set-wraps-map).**

The main loop adopts Alt 2: no F-NNN blocks it, so per F-002 the
finished-form-clean shape must be taken; preferring the flat array on
"less hard code now" grounds is precisely the Cycle-budget-defer smell.

## Consequences

- O(log n) persistent assoc/dissoc/get; structural sharing consistent with
  the other persistent collections. `(into (sorted-map) big-seq)` is
  O(n log n).
- One new heap tag (`rb_node`) + trace fn; `reserved_c11` consumed.
- The LLRB delete (cycle B) is the highest-correctness-risk piece; cover it
  with a build-N-delete-half unit test (like the HAMT canary) + the diff
  oracle. Cycle A ships first (build/read) with delete raising an explicit
  error until cycle B — no silent wrong answer.
- `rseq` + `reversible?` get fixed for vectors as a side effect (cycle C).

## Affected files

- New: `src/runtime/collection/sorted.zig`, `test/e2e/phase14_sorted*.sh`.
- Edit: `src/runtime/value/heap_tag.zig` (`reserved_c11` → `rb_node`),
  `src/runtime/runtime.zig` (register trace), `lang/primitive/`
  collection.zig / sequence.zig + `runtime/collection/lookup.zig` +
  `runtime/print.zig` (dispatch arms), `src/lang/clj/clojure/core.clj`
  (subseq/rsubseq/rseq/sorted?/reversible?), `src/lang/diff_test.zig`.

## Revision history

- 2026-05-30: drafted + accepted. DA fork overturned the survey's
  flat-array recommendation on F-002 grounds (smallest-diff bias /
  Cycle-budget-defer). LLRB chosen as the finished form.
