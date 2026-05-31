# Optimizations ledger (SSOT)

> **Purpose.** A discoverable index of every place where cljw's code is
> shaped for *speed* rather than for the simplest correct form. The
> user's directive (2026-05-31): *"将来の最適化のとき、「最適化してる
> んだよ」と分かりやすく — 理想は SSOT 的な箇所があること"*. This is that
> SSOT. Optimizations come in many kinds and not all fit one registry
> cleanly, so this is a **best-effort index**, paired with the
> grep-discoverable in-code `// PERF:` marker
> (see [`.claude/rules/perf_marker.md`](../.claude/rules/perf_marker.md)).
>
> An entry answers: *what is the naive correct form, what is the
> optimized form, why is it faster, and what verifies they agree?*
> The naive form is the behavioural contract; the optimization must be
> observably equivalent (F-011) — only the internal mechanics change.

## How to read / maintain

- Every optimization that trades simplicity for speed gets (a) a
  `// PERF: <what> [refs: O-NNN, …]` marker at the code site and
  (b) a row here. The `O-NNN` id is this ledger's; cross-ref the
  driving `D-NNN` debt row when one exists (perf debt lives in
  `.dev/debt.md`; this ledger is the *implemented* optimizations).
- A "fast path" that can be removed and replaced by the naive form
  with no behaviour change is the cleanest kind — note the naive
  fallback explicitly so a future reader can verify by deletion.
- When an optimization is reverted / superseded, mark the row
  `RETIRED <date>` rather than deleting it (history).

## Entries

| ID    | Site                                                                                               | Naive form (the contract)                                                                                                                      | Optimized form                                                                                                                                                                                                                                                                                          | Why faster                                                                                                                                                                                                                     | Verified by                                                                                                                                                                                                     | Refs          |
|-------|----------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------|
| O-001 | `runtime/collection/range.zig` + call sites                                                        | `(range a b s)` as a lazy cons-seq (one cons + lazy_seq per element)                                                                           | Compact `.range` value `{start,end,step,count}`: O(1) count/nth, tight-loop reduce, chunked-cons `seq`                                                                                                                                                                                                  | No per-element alloc on count/nth/reduce; 1 alloc/32 on walk                                                                                                                                                                   | `phase14_range_indexed.sh` + diff oracle vs `clj`                                                                                                                                                               | D-163 / D-168 |
| O-002 | `higher_order.zig::reduceFn` (`.vector` arm)                                                       | `reduce` over a vector via `seqFn` → `vectorToList` (N-element eager cons list), then walk via first/next                                     | Index-walk: `vector.nth(coll, i)` in a tight `i` loop, honouring `reduced`                                                                                                                                                                                                                              | No N-element intermediate cons list; `(reduce f bigvec)` / `(into to bigvec)` went O(n) alloc → O(1). Measured `(reduce + (vec (range 1e6)))` 182s → fast                                                                    | `phase14_*` reduce e2e + diff oracle vs `clj`                                                                                                                                                                   | D-163         |
| O-003 | `vector.zig::fromSlice` + `transient/transient_vector.zig::toPersistent` + `core.clj` `into`/`vec` | `persistent!` rebuilds the persistent vector via N persistent `conj`s (O(n log n)); `into`/`vec` = `(reduce conj …)`, also N persistent conjs | Bulk `fromSlice` builds the HAMT trie bottom-up from the transient's flat buffer in O(n) (32-element leaves → interiors grouped 32-at-a-time → root; last ≤32 = tail); `into`/`vec` route editable targets (vector/hash-map/hash-set, NOT sorted/nil/list) through `transient`/`conj!`/`persistent!` | `persistent!` O(n log n) → O(n); `into`/`vec` build O(n) over a flat buffer + one O(n) trie conversion, vs N persistent conjs. Measured `(count (vec (range 1e6)))` 121s → 2.4s; `(reduce + (vec (range 1e6)))` 123s → 2.5s | `vector.zig` boundary unit test (n ∈ {0,1,31,32,33,63,64,65,1023,1024,1025,1e5}: `fromSlice` == conj-built, same shift/tail/root) + diff oracle vs `clj` (into/vec over vector/map/set/sorted/nil/list + meta) | D-180         |

## Identified high-ROI candidates (measured, not yet implemented)

Ranked by ROI (impact × frequency / effort·risk). Measured 2026-05-31 on
mac-arm-m4pro, startup baseline 0.48s subtracted where noted.

1. **`persistent!` bulk trie build — DONE (O-003, D-180 discharged).**
   `transient_vector.toPersistent` now calls `vector.fromSlice`, which
   builds the HAMT trie bottom-up from the flat buffer in O(n) instead of
   N persistent conjs (O(n log n)); `into`/`vec` route editable targets
   through `transient`/`conj!`/`persistent!`. **Measured: `(count (vec
   (range 1e6)))` 121s → 2.4s; `(reduce + (vec (range 1e6)))` 123s →
   2.5s.** Verified by the `fromSlice`-vs-conj boundary unit test +
   diff oracle. The residual ~2.4s is per-element `reduce`/`conj!`
   interpreter dispatch + the lazy-seq walk of `from` — addressed by
   D-163 (fusion) / D-140 (startup), not `persistent!`.
   *(The map/set arm of the routing is correctness-enabling, not a perf
   win: routing `into {}` / `into #{}` through transients required
   completing the transient hash map for > 8 entries — ADR-0064, which
   delegates to the persistent HAMT (O(n log n), no map speedup). The
   in-place editable-CHAMP transient that would make maps faster is
   deferred to D-181. The vector arm is the measured O-003 win.)*

2. **cljw startup ≈ 0.48s per invocation** — every `cljw -e` / test /
   probe re-parses + analyses + evaluates ~1000-line `core.clj`. The
   e2e suite's ~138s parallel block is dominated by this (hundreds of
   invocations × 0.48s). **Highest dev-velocity ROI** (every iteration
   pays it) but **architectural** (a pre-analysed bootstrap cache, à la
   ClojureScript's analyzer cache). Tracked: D-140.

## Out-of-scope future optimizations (tracked, not yet implemented)

- **Map/filter/take reduce-fusion** (cw v0 `fusedReduce`: collapse a
  `(reduce f (map g (filter p (range n))))` chain to a single 0-alloc
  pass over the base). The compact `.range` value (O-001) is the
  substrate this operates over. **Measured: `(count (map inc (range
  1e5)))` = 42s ≈ 420µs/element** (the lazy_seq per-element thunk
  realisation). Deferred to the D-163 perf window as its own ADR. cw v0
  measured 1336x on lazy_chain — see D-163's cw-v0
  blueprint note.
