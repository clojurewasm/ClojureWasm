# ADR-0065 — Lazy-chain reduce performance via chunked seqs + transducers (NOT cw-v0 meta-fuse); D-163

**Status**: Proposed → Accepted (2026-05-31)

**Context owner**: autonomous loop (§9.2.S perf campaign, D-163)

## Context

`(count (map inc (range 1e5)))` ≈ 42s ≈ 420µs/element: each lazy_seq
element re-evaluates the `map` body through tree-walk (`(lazy-seq (cons
(f (first s)) (map f (rest s))))`) + allocates a Cons + lazy_seq node +
calls `f`, once per element. `reduceFn` has fast arms for `.range`
(O-001) and `.vector` (O-002) but the moment a `map`/`filter` wrapper
sits over the source, the chain drops to the generic per-element
`seqFn → firstFn → nextFn` walk.

The D-163 debt row captured **cw v0's `fusedReduce`** as the blueprint:
meta-annotated lazy-seqs (`__zig-lazy-map`/`-filter`/`-take`) + a
meta-chain walk that fuses the chain into a 0-alloc pass (measured 1336×
on lazy_chain). That row predates cljw shipping its **complete,
JVM-shaped transducer machinery** (`map`/`filter`/`take`/`drop`/`keep`/
`remove` 1-arg xform arities + `transduce`/`completing`/`cat`/`into`-with-
xform/`vec` — core.clj). Per CLAUDE.md, a debt row naming a future
approach is a *memo, not a contract*; this ADR re-lays it.

Survey: `private/notes/phase9.2.S-D163-reduce-fusion-survey.md`.

## Decision

**Adopt the JVM finished form — chunked seqs for the implicit path +
transducers for the explicit 0-alloc opt-in — a single reducing-function
model. Reject cw-v0's meta-annotated `fusedReduce` (a second, parallel
fusion mechanism = F-011 violation). Land Alt C (chunk-aware map/filter +
a `chunked_cons` reduce arm) as the first increment of this finished
form.**

- **Implicit path** `(reduce f (map g coll))` (user wrote no transducer):
  `map`/`filter` PRESERVE the source's 32-element chunking (JVM
  `chunk-cons` shape) — realise ≤32 elements per thunk into a
  `ChunkBuffer`, emit a `chunked_cons` with a `lazy-seq` tail — and
  `reduceFn` gains a `chunked_cons` arm that drains a whole chunk per
  step. ~32× fewer thunk realisations.
- **Explicit path** `(transduce (map g) f coll)` / `(into [] (map g)
  coll)`: the existing transducer arities already fuse with zero
  intermediate seq allocation. No change needed; this is where the
  0-alloc win lives, by user opt-in (the JVM contract).

There is **no cw-v0-style meta-fuse** — JVM has no such mechanism; cw v0
invented it because it lacked the chunked-seq + transducer combination
cljw already has.

### Realistic expectation (NOT overclaimed)

Chunking collapses the per-thunk tree-walk + alloc term (~32× on that
term) but does **not** touch the per-element `f` vtable call. After
chunking, that per-element dispatch is the dominant residual — the same
`callFnVal` cost D-163 cross-refs to D-133 (JIT) / the superinstruction
pass, correctly **out of scope** for this fusion cycle. **Expected
overall: ~4-7× on the implicit path** (the timeout pathology becomes
~1-2s), not 32×. cw-v0 meta-fuse cannot fix the `f`-call term either, so
its marginal advantage over chunking is only ~10-15% (eliminating the
ChunkBuffer allocs) — not worth a permanent parallel mechanism.

## First-cycle scope (one unit, gated on the headline benchmark)

The `chunked_cons` reduce arm and chunk-aware `map`/`filter` **must land
together** — the reduce arm alone buys nothing because `map`'s current
`.clj` body re-wraps with plain `cons`, shredding chunks back to
per-element Cons cells (DA Trap 1).

1. `reduceFn` `chunked_cons` arm: drain a whole `ChunkBuffer` per step
   (between `.vector` and the generic arm), `reduced`-checked. `PERF:`
   marker + O-NNN ledger row.
2. A `.clj`-callable chunk-builder surface backed by `chunked_cons.zig`:
   `chunk-buffer` / `chunk-append` / `chunk` / `chunk-cons` /
   `chunk-first` / `chunk-rest` / `chunked-seq?` (JVM-named).
3. Rewrite the 2-arg `map`/`filter`/`keep`/`remove` `.clj` bodies to
   preserve chunking (realise ≤32 per thunk into a ChunkBuffer, emit a
   `chunked_cons` with a `lazy-seq` tail) — JVM `chunk-cons` shape.
4. Gate on `(count (map inc (range 1e5)))` + `(reduce + (map inc (range
   1e5)))`; record the measured before/after in `optimizations.md`.

Later increments (separate cycles, same mechanism — not throwaway):
route `into`/`sequence`/`eduction` so the explicit path is chunked
0-alloc too. No meta-fuse ever needed.

## Non-goals (explicit)

- **cw-v0 meta-annotated `fusedReduce`** — rejected (F-011; supersedes
  the D-163 blueprint memo).
- **The per-element `f` vtable-dispatch cost** — that is D-133 / the
  superinstruction window, not this cycle.
- **A `meta` union field on the LazySeq value** (Alt A would need it) —
  not introduced.

## Consequences

- The implicit lazy path gets ~4-7× (timeout → ~1-2s); the explicit
  transducer path stays the 0-alloc opt-in. Single mechanism (F-011).
- New `.clj`-callable chunk primitives (JVM-named) — real new surface,
  but JVM-faithful and the substrate later increments reuse.
- `map`/`filter`/`keep`/`remove` 2-arg bodies become chunk-aware (their
  observable lazy semantics unchanged — chunking is an internal
  realisation detail, verified by the diff oracle).
- Composes with O-001 (`.range`→chunked) + O-002 (vector index-walk).

## Alternatives considered

Sourced from a fresh-context Devil's-advocate subagent (mandatory at
depth ≥ 2), briefed with the F-002 / F-011 / P3 / P4 / A6 envelope. Its
analysis is reproduced verbatim; the recommendation (Alt B finished form,
Alt C first increment, reject Alt A) is the shape this ADR adopts.

> # Devil's-Advocate Analysis — D-163 lazy-chain reduce fusion
>
> ## Ground truth corrections to the framing
>
> 1. **`reduceFn` does NOT have a chunked_cons arm** — confirmed (L184
>    `.range`, L200 `.vector`, then the generic `seqFn→firstFn→nextFn`
>    walk at L219). A `chunked_cons` falls to the generic per-element arm.
> 2. **`(rest <range>)` already yields a chunked_cons** (sequence.zig
>    L508/527 route `.range` through `seqChunk`). So the *source* side of
>    a chain is already chunked. **But the `map`/`filter` clj bodies
>    re-wrap with plain `cons`** (core.clj L53 `(cons (f (first s)) (map f
>    (rest s)))`). `cons` builds a single Cons cell, not a chunk. So even
>    though the source produces 32-wide chunks, the map output is a
>    1-element-Cons-per-thunk lazy chain. The chunk is shredded back to
>    per-element at the map boundary. This means **Alt C's "chunk-aware
>    map/filter" is NOT a small clj tweak** — it requires rewriting the
>    map/filter bodies to allocate + fill a ChunkBuffer + emit a
>    chunked_cons whose `next` is a `lazy-seq` thunk (JVM's
>    `chunk-buffer`/`chunk-append`/`chunk-cons` shape), which today cljw
>    has no `.clj`-callable surface for.
>
> ## Verdict per alternative
>
> ### Alt A — port cw-v0 meta-annotated `fusedReduce`
> - **Better:** Only design with **true 0-intermediate-allocation** for
>   the implicit path (no per-element seq node AND no per-32 ChunkBuffer
>   — a tight i64 loop over the `.range` base applying transforms inline).
>   Proven 1336×. No clj call-site change.
> - **Breaks:** A **second fusion mechanism** parallel to the transducers
>   cljw already ships, which must stay behaviourally identical to the
>   transducer path forever (reduced, nil, chunk boundary, short-circuit)
>   — two contracts for one behaviour. Reverses ADR-0054 (lazy-in-clj) by
>   pulling map/filter 2-arg back into Zig `__zig-lazy-*` primitives. Adds
>   a `meta` union field to the hot LazySeq value (F-004 surface). The
>   16-transform cap + filter-chain-collapse exist *only* for this
>   mechanism.
> - **F-NNN:** **F-011 violation** (one mechanism). The decisive fact. The
>   exact 89K-LOC duplication `no_copy_from_v1` prevents.
> - **Fixes implicit path?** Yes, best (0-alloc).
>
> ### Alt B — transducers + chunked seqs (JVM finished form)
> - **Better:** Single mechanism (F-011-clean). Matches JVM's actual
>   answer. Explicit path routes through the existing transducer arities →
>   0-alloc by opt-in. Implicit path rides chunked seqs. Reuses O-001
>   `.range`→chunk + chunked_cons.
> - **Breaks:** Nothing structurally. The cost is chunk-preserving
>   map/filter + a chunked_cons reduce arm (= Alt C, the first increment).
> - **F-NNN:** F-011/F-002/P3/P4-clean.
> - **Fixes implicit path?** Yes via chunking — **~32× constant factor,
>   NOT 0-alloc** (still one ChunkBuffer + one ChunkedCons per 32 + calls
>   `g` per element).
>
> ### Alt C — chunked_cons reduce arm + chunk-aware map/filter (first increment of B)
> - **Better:** Smallest finished-form-clean step. Lands the load-bearing
>   `chunked_cons` reduce arm + chunk-preserving map/filter. Composes with
>   O-001/O-002. No new value field, no parallel mechanism.
> - **Breaks:** Nothing — but "smallest diff" framing is **misleading**:
>   chunk-aware map/filter requires a new chunk-builder surface callable
>   from `.clj`. That is most of the work of B, not a tweak. Not a
>   half-measure (a real increment of the same mechanism), but not cheap.
> - **F-NNN:** F-011/F-002-clean.
> - **Fixes implicit path?** Yes, ~32× on the amortised term.
>
> ## Explicit answers
>
> ### (a) Is Alt A (the debt-row blueprint) superseded?
> **Yes — superseded, and rejecting it is a sound F-011 call.** The D-163
> row's blueprint predates cljw's complete transducer arities (the row is
> prior-art capture, and CLAUDE.md says debt rows naming future ADRs are
> memos, not contracts). Alt A would bolt a *second* fusion mechanism onto
> a problem the first already addresses — the textbook F-011 violation and
> the cw-v0 duplication `no_copy_from_v1` forbids. **Honest devil's point:
> Alt A buys true 0-allocation on the implicit path (B/C still allocate a
> ChunkBuffer + ChunkedCons per 32 — ~3,125 each for 1e5). But that win is
> recoverable inside the one mechanism via the *explicit* transducer
> surface (`(transduce (map inc) + (range n))`), which cljw already has
> and which IS 0-intermediate-alloc. Alt A's win is unique to fusion, and
> fusion is what transducers are. Verdict: superseded.**
>
> ### (b) Does B/C actually make the implicit path fast? Quantify.
> 420µs/element ≈ three additive costs: (1) per-thunk tree-walk of the
> map body (dominant), (2) per-element `f` vtable call, (3) per-element
> heap alloc. Chunked map/filter eliminates (1) + most of (3) by
> amortising over 32; it does **not** touch (2) — `f` is still called per
> element (Alt A also calls `f` per element). **Quantified residual:** if
> (1)≈300-350µs and (2)≈50-100µs, chunking collapses (1) ~32× to ~10µs and
> leaves (2). **Expected implicit-path: ~420µs → ~60-110µs/element, ~4-7×
> overall, NOT 32×.** Enough to convert the timeout to ~1-2s. The residual
> (2) is the `callFnVal`/dispatch cost D-163 cross-refs to D-133/
> superinstruction — correctly out of scope. **Alt A would NOT fix (2)
> either**, so its true marginal advantage over C is ~10-15%, not worth an
> F-011 violation.
>
> ### (c) Is the finished form a HYBRID (chunked implicit + transducer explicit), no meta-fuse?
> **Yes — exactly the JVM-faithful finished form, no meta-fuse.** JVM:
> implicit `(reduce f (map g coll))` → `map` returns a chunked lazy-seq
> (`chunk-cons`), `reduce` drains via `IChunkedSeq`/`internal-reduce`
> 32-at-a-time (constant-factor, allocates chunks); explicit `(transduce
> (map g) f coll)` → no intermediate seq, 0-alloc. cljw has both
> substrates already. **There is no JVM mechanism corresponding to cw-v0's
> meta-fuse** — cw v0 invented it lacking the chunked+transducer combo.
> Confirmed: no meta-fuse needed.
>
> ### (d) Sequencing — "land Alt C first, measure" correct, or a trap?
> **Sequencing correct, but the "smallest diff" sizing is the trap.**
> Trap 1 — order within C: the `chunked_cons` reduce arm ALONE buys
> **nothing for the implicit `(map inc (range n))` path** because map
> shreds the chunk back to Cons cells. It only helps `(reduce f (range
> n))` over the seq-view + already-chunked sources. The load-bearing piece
> is **chunk-aware map/filter**. So "land the reduce arm first, measure"
> shows ~no improvement on the headline benchmark and misleads. Correct
> first cycle: **the reduce arm AND a `.clj`-callable chunk-builder
> surface AND chunk-aware map/filter together**, gated on the headline
> benchmark. Trap 2 — the chunk-builder surface is new public-ish API
> (`chunk-buffer`/`chunk-append`/`chunk`/`chunk-cons`/`chunk-first`/
> `chunk-rest`); JVM-faithful but real new surface. Size the cycle
> honestly. Neither trap makes C wrong — both are increments of the one
> mechanism, nothing throwaway.
>
> ## Recommendation
> **Adopt Alt B as the finished form; land Alt C as its first increment;
> reject Alt A.** Strongest reason: cljw already ships the complete
> JVM-shaped transducer machinery AND the chunked `.range`/chunked_cons
> substrate, so the finished form is the JVM's own answer — chunked seqs
> (implicit) + transducers (explicit 0-alloc opt-in), a single
> reducing-function model. Alt A adds a second, permanently-co-maintained
> fusion mechanism for a problem this model already solves (F-011
> violation, the cw-v0 89K-LOC pattern). Alt A's only genuine marginal win
> over C is ~10-15% (the residual chunk-alloc), and even Alt A cannot
> touch the dominant residual (the per-element vtable `f` call), which
> belongs to the later D-133/superinstruction window. **Alt A is
> unambiguously superseded by cljw having transducers.** First cycle =
> chunked_cons reduce arm + chunk-builder primitives + chunk-aware
> map/filter, gated on `(count (map inc (range 1e5)))`; sequence-1 without
> sequence-3 will not move the benchmark — they land together.

### Main-loop decision

Adopt **Alt B (finished form) / Alt C (first increment); reject Alt A.**
The DA confirms cljw's complete transducer machinery + chunked substrate
make cw-v0's meta-fuse a superseded F-011 violation. The realistic ~4-7×
(not the row's implied 1336×) is accepted honestly: the residual is the
per-element fn-dispatch cost owned by D-133/superinstruction, which no
fusion design in this cycle can remove. The first cycle lands the reduce
arm + chunk primitives + chunk-aware map/filter together (the reduce arm
alone is inert per DA Trap 1).

## Implementation note (2026-05-31, measurement-validated — corrects the DA's residual estimate)

Before implementing, the fill-loop design fork was resolved by measurement
(cljw is a **tree-walk interpreter**, so unlike JVM the `.clj` fill loop is
NOT compiled to bytecode — the question was whether a `.clj` `dotimes` fill
amortises the per-element lazy-seq machinery, or whether the fill itself
must be a Zig per-chunk primitive):

- Pure tree-walk loop, 1e5 iters, multi-op body (`(loop [i 0 acc 0] (if (<
  i 100000) (recur (inc i) (+ acc (inc i))) acc))`) = **0.71s** (~2.3µs/iter
  after the 0.48s startup) → the per-element fn-call + loop overhead (the
  DA's "term 2") is **~2µs, not 50-100µs**.
- `(count (map inc (range 1e5)))` = **41.3s** = ~408µs/element → **term 1
  (per-element lazy-seq machinery: lazy_seq + cons alloc + map-body
  tree-walk + recursive map) is ~408µs and utterly dominates.**

**Resolution:** the `.clj` `dotimes`/`loop` fill is fine — its ~2µs/iter is
dwarfed by the 408µs term-1 it amortises 32×. No Zig per-chunk fill
primitive is needed; the JVM `.clj` chunk-builder surface (thin Zig
`chunk-buffer`/`chunk-append`/`chunk-cons` + `-chunk-count`/`-chunk-nth`/
`chunk-rest`/`chunked-seq?`) works for cljw. **Realistic win is ~25-30×**
(headline 42s → ~1.5s), NOT the DA's 4-7× — the DA overestimated term-2;
the residual after chunking is the amortised chunk overhead (~13µs/element)
+ the ~2µs fill step, not a 50-100µs fn-call. (The per-element `f` vtable
call genuinely is ~2µs and is NOT the bottleneck here; D-133/superinstruction
is for other hot paths, not this one.) High blast radius (map/filter are
used everywhere) → verify with the diff oracle across many seq scenarios
(empty / 1 / 31 / 32 / 33 / 1024 elements; nested map∘filter; lazy
infinite + take; nil; into/reduce/count/last/nth/seq= over the chunked
output) before gating.

## Affected files (first cycle)

- `src/lang/primitive/higher_order.zig` (`reduceFn` `chunked_cons` arm).
- `src/runtime/collection/chunked_cons.zig` + a primitive surface
  (`chunk-buffer`/`chunk-append`/`chunk`/`chunk-cons`/`chunk-first`/
  `chunk-rest`/`chunked-seq?`) registered into `rt`.
- `src/lang/clj/clojure/core.clj` (`map`/`filter`/`keep`/`remove` 2-arg
  bodies chunk-aware).
- `.dev/optimizations.md` (new O-NNN row), `.dev/debt.md` (D-163 blueprint
  re-laid), tests (e2e + diff oracle on lazy chains; bench on the headline
  benchmark).

## Cross-references

F-002 / F-011 / P3 / P4 / A6 · D-163 (re-laid: cw-v0 meta-fuse → JVM
transducer+chunked) · D-133 (JIT — owns the residual per-element dispatch)
· O-001 (`.range`→chunked, the substrate) · O-002 (vector index-walk) ·
ADR-0054 (lazy-in-clj — Alt A would have reversed it) · ADR-0063 (§9.2.S
campaign governance) · survey
`private/notes/phase9.2.S-D163-reduce-fusion-survey.md`.
