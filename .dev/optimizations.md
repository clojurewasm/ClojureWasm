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
>
> ⚠️ **Measurement mode (2026-06-01 correction).** Many absolute numbers
> in the O-001…O-004 rows below were measured on a **Debug** binary
> (`zig build` defaults to Debug; a Debug tree-walk interpreter is
> ~10-100× slower than the shipped build). They are **NOT** representative
> of shipped speed — e.g. `(count (vec (range 1e6)))` reads ~121s in Debug
> but **~0.02s in ReleaseFast**, and startup is ~0.48s Debug vs **~ms**
> Release (cljw already meets the ms-level cold-start mission target;
> cw v0 claims ~4ms). The algorithmic wins are real (O(n) beats
> O(n log n); chunked beats per-element in any mode), but the urgency was
> Debug-inflated. **Future O-NNN numbers MUST be Release** — measure only
> via `scripts/perf.sh` (see `.claude/rules/perf_measure_release.md`).

## How to read / maintain

- Every optimization that trades simplicity for speed gets (a) a
  `// PERF: <what> [refs: O-NNN, …]` marker at the code site and
  (b) a row here. The `O-NNN` id is this ledger's; cross-ref the
  driving `D-NNN` debt row when one exists (perf debt lives in
  `.dev/debt.yaml`; this ledger is the *implemented* optimizations).
- A "fast path" that can be removed and replaced by the naive form
  with no behaviour change is the cleanest kind — note the naive
  fallback explicitly so a future reader can verify by deletion.
- When an optimization is reverted / superseded, mark the row
  `RETIRED <date>` rather than deleting it (history).

## Entries

| ID    | Site                                                                                                                                                       | Naive form (the contract)                                                                                                                                                                            | Optimized form                                                                                                                                                                                                                                                                                          | Why faster                                                                                                                                                                                                                                                                         | Verified by                                                                                                                                                                                                     | Refs             |
|-------|------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------|
| O-001 | `runtime/collection/range.zig` + call sites                                                                                                                | `(range a b s)` as a lazy cons-seq (one cons + lazy_seq per element)                                                                                                                                 | Compact `.range` value `{start,end,step,count}`: O(1) count/nth, tight-loop reduce, chunked-cons `seq`                                                                                                                                                                                                  | No per-element alloc on count/nth/reduce; 1 alloc/32 on walk                                                                                                                                                                                                                       | `phase14_range_indexed.sh` + diff oracle vs `clj`                                                                                                                                                               | D-163 / D-168    |
| O-002 | `higher_order.zig::reduceFn` (`.vector` arm)                                                                                                               | `reduce` over a vector via `seqFn` → `vectorToList` (N-element eager cons list), then walk via first/next                                                                                           | Index-walk: `vector.nth(coll, i)` in a tight `i` loop, honouring `reduced`                                                                                                                                                                                                                              | No N-element intermediate cons list; `(reduce f bigvec)` / `(into to bigvec)` went O(n) alloc → O(1). Measured `(reduce + (vec (range 1e6)))` 182s → fast                                                                                                                        | `phase14_*` reduce e2e + diff oracle vs `clj`                                                                                                                                                                   | D-163            |
| O-003 | `vector.zig::fromSlice` + `transient/transient_vector.zig::toPersistent` + `core.clj` `into`/`vec`                                                         | `persistent!` rebuilds the persistent vector via N persistent `conj`s (O(n log n)); `into`/`vec` = `(reduce conj …)`, also N persistent conjs                                                       | Bulk `fromSlice` builds the HAMT trie bottom-up from the transient's flat buffer in O(n) (32-element leaves → interiors grouped 32-at-a-time → root; last ≤32 = tail); `into`/`vec` route editable targets (vector/hash-map/hash-set, NOT sorted/nil/list) through `transient`/`conj!`/`persistent!` | `persistent!` O(n log n) → O(n); `into`/`vec` build O(n) over a flat buffer + one O(n) trie conversion, vs N persistent conjs. Measured `(count (vec (range 1e6)))` 121s → 2.4s; `(reduce + (vec (range 1e6)))` 123s → 2.5s                                                     | `vector.zig` boundary unit test (n ∈ {0,1,31,32,33,63,64,65,1023,1024,1025,1e5}: `fromSlice` == conj-built, same shift/tail/root) + diff oracle vs `clj` (into/vec over vector/map/set/sorted/nil/list + meta) | D-180            |
| O-004 | `core.clj` `map`/`filter`/`keep` 2-arg + `higher_order.zig::reduceFn` chunked arm + `sequence.zig::countFn` chunk drain + `chunked_cons.zig` chunk-builder | `(map f coll)` / `(filter pred coll)` build a meta-less lazy-seq walked one element per `nextFn` — each step allocs a cons + lazy_seq node and tree-walks the `.clj` body (~408µs/element measured) | Chunk-preserving: when the source is chunked (range seq / chunked map), transform a whole 32-chunk per thunk into a fresh chunk (JVM `chunk-cons` shape); `reduce`/`count` drain a chunk per step. Fill loop stays in `.clj` (a tree-walk loop is ~2µs/iter, negligible vs the 408µs amortised)         | The ~408µs/element lazy-seq machinery is paid once per 32 elements, not per element. Measured `(count (map inc (range 1e5)))` 41.3s → 2.8s (~15x); `(reduce + (map inc (range 1e5)))` → 2.4s. (Residual is the per-element `f` vtable call ≈ 2µs — D-133's, not this cycle's.) | `phase14_chunked_seq.sh` (chunk-boundary count 1/32/33/65/1000 + reduce/nth/last/=/lazy-take) + diff oracle vs `clj`                                                                                            | D-163 / ADR-0065 |

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

2. **cljw startup ≈ 0.48s per invocation** — D-140. **NOTE (corrected
   2026-05-31): clojure.core is ALREADY AOT-restored from an embedded
   bytecode envelope, NOT re-parsed.** ADR-0056 (Cycle 2b) built
   `cache_gen` → AOT-compiles `core.clj` to a bytecode envelope at build
   time → `@embedFile`'d into the cljw binary as `bootstrap_cache`;
   `runner.zig` `setupCoreAot` restores core from it on every `cljw -e`/
   file/stdin run (the prior "re-parses+analyses+evaluates core.clj"
   description was stale — it predates Cycle 2b). So the residual ~0.48s
   is NOT core re-eval; it is (unprofiled) the envelope RESTORE
   (deserialize + run the `op_def` chunks to intern ~hundreds of core
   vars on the VM) + `primitive.registerAll` + process spawn + the
   full-self-exe read `tryRunEmbedded` does to check for a trailer (a
   footer-only seek would avoid it — noted in `builder.zig:135`). The
   11 non-core `.clj` files (string/set/walk/…) are lazy on `require`,
   so a minimal `cljw -e 1` does not load them. **Next step = PROFILE
   the 0.48s** (the bottleneck moved since the docs were written), then
   targeted tuning (footer seek / faster restore) + ADR-0056 Cycle 3
   (AOT or lazy-defer the non-core files). Architecture already exists
   (ADR-0056); this is profile-and-tune, not a new cache. Highest
   dev-velocity ROI (every test/probe pays it).

## Out-of-scope future optimizations (tracked, not yet implemented)

- *(none currently — the map/filter/take reduce-fusion that was listed
  here landed as O-004 / D-163 first cycle.)*
