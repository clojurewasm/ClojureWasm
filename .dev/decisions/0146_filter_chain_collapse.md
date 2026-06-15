# ADR-0146 — Filter-chain collapsing: go/no-go = NO-GO (the cljw sieve is fn-call-bound, not depth-bound); redirect the sieve to the fn-call/closure-invocation lever

- **Status**: Proposed → **Rejected (NO-GO)** (2026-06-15)
- **Relates to**: ADR-0145 (JIT no-go → run the 3-loser runtime campaign, sieve
  first — this ADR is that unit's investigation), F-002 (finished-form wins;
  also: do not ship complexity for a rare-pattern win that misses the campaign
  target), F-006 (published-root GC), F-011 (behavioural equivalence vs `clj`),
  O-023 (the existing `fuse` reduce-fusion slug), D-386 (dispatch perf — the
  fn-call lever this redirects to).
- **Devil's-advocate**: fresh-context fork (2026-06-15), reflected verbatim in
  § Alternatives considered. It recommended the Zig producer (Alt 2) over the
  `.clj` walk (Alt 1) — sound *given the survey's premise*, which the
  implementation-time measurement then **falsified** (see § Decision).
- **Survey**: `private/notes/9.2.S-sieve-filter-chain-survey.md` (v0 mechanism +
  cljw state + the Step-0.6 re-laying) + this ADR's measurement section.

## Context

The `sieve` benchmark (functional nested-filter Sieve of Eratosthenes) is one of
ADR-0145's three open Python-losers: sieve(1000) cljw 27.5 ms vs Python 18.8 ms
(py 1.46×); sieve(3000) cljw 133.5 ms vs Python 18.2 ms (py 7.33×). The survey +
DA both modelled the pathology as v0 did — a **k-deep nested `filter` lazy-seq**
whose depth multiplies the per-element evaluator re-entry — and v0 won this exact
benchmark 1645→16 ms (103×, label 24C.7) with a Zig `lazy_filter_chain` producer
that collapses the nesting to one flat-pred walk.

A full Stage-1 implementation of that producer was built and measured (a dedicated
`chain` slot on `LazySeq` + a Zig flat-walk producer in `force` + a `-filter-chain`
primitive + the GC-root frame). It **works and collapses correctly** (instrumented:
the pred vector grows 1→2→3→… while depth stays 1).

## Decision — NO-GO, with the measurement that overturned the premise

**The cljw sieve is fn-call-bound, NOT depth-bound. The collapse does not move it,
so it is rejected; the sieve's real lever is fn-call/closure-invocation speed.**

Measured (ReleaseSafe, hyperfine), collapse vs naive:

| workload                              | naive (nested) | collapsed | effect       |
|---------------------------------------|----------------|-----------|--------------|
| sieve(3000)                           | 139.1 ms       | 133.0 ms  | ~1.05× (noise) |
| deep 40-nest `(filter pos? …)` cheap  | 23.7 ms        | 9.0 ms    | **2.6×**     |

The collapse gives a real **2.6×** on *deep* nests with *cheap* predicates — but
**~0 on the sieve**, because the per-element cost in the sieve is the **predicate
call**, not the lazy-seq nesting. Isolation (1M elements, single filter):

| predicate                                   | time    | per element |
|---------------------------------------------|---------|-------------|
| user `fn*` `(fn [x] (not= 0 (mod x 7)))`     | 766 ms  | ~766 ns     |
| builtin `odd?`                              | 138 ms  | ~138 ns     |

A user-`fn*` predicate costs **~5.5× a builtin** (frame setup + arg bind + var
derefs + the nested `mod`/`not=` builtin calls). The sieve does on the order of a
million such user-`fn*` calls; that dominates. The depth multiplier that crippled
v0 (1645 ms) is **already largely absent in cljw** — cljw's lazy machinery (O-004
chunking + the cheap `force`) starts at 27 ms where v0 started at 1645 ms, i.e.
cljw is already near v0's *post-collapse* 16 ms. **v0's pathology did not transfer;
the survey/DA premise was v0-shaped and wrong for cljw.**

Two further nails (beyond "it doesn't help"):

1. **Correctness gap requiring Layer-0 seqable replication.** The producer lives in
   `force` (Layer 0, `lazy_seq.zig`) and used `lazy_seq.seq/first/rest`, which only
   handle lazy/list/chunked/range — **not vector/map/string bases**. `(filter pos?
   [1 2 3])` returned `nil` for `first` → `pos? nil` TypeError; `CLJW_GC_TORTURE=1`
   surfaced it. (The diff oracle PASSED — both backends run the same producer, so
   the bug is identical on both and produces no TreeWalk≠VM DIFF; the real oracle is
   `clj`, and torture/direct probing caught it. A useful reminder that the diff
   oracle is necessary, not sufficient.) Fixing it correctly means replicating the
   Layer-2 seqable+chunking handling (`(seq coll)` + the chunked arm) inside Layer 0
   — significant added complexity for a rare-pattern win.

2. **Cost vs value.** Even fixed, the win is a *rare* pattern (40-deep filter nests
   are not written; 2-3 deep get a modest shave), paid for with a permanent slot on
   the **highest-cardinality heap object** (`LazySeq`), a branch in the hot `force`
   path, and the seqable-replication complexity. Per F-002, shipping that to bank a
   narrow win that misses the campaign target is the wrong trade. The valuable output
   of this cycle is the **finding**, not the code.

**Redirect.** The sieve (and fib, and all user-fn-heavy code) is gated on
**`fn*`/closure invocation speed**. That is the next lever — the D-386 dispatch /
intrinsic territory (O-028/029 already shaved fib via ip-hoist + alloc-free arith;
the closure-call path — frame setup, arg binding, var deref of `mod`/`not=` — is the
next surface). It is **higher value** than collapse: it moves every Python-losing
*compute* bench, not one rare lazy pattern. The collapse is recoverable from this
ADR + git history if a real deep-nested-filter workload ever justifies it
(commits/history are the backup — user, 2026-06-15).

**fused-reduce in its proper form stays a live, separate goal** (user direction,
2026-06-15: *"fused reduce はめちゃくちゃ効果が高かった…正しい姿で入れたい / 実験も
柔軟に…何段階かで諦めないでいきたい"*). It is the **reduce** path (O-023 already beats
Python on `map_filter_reduce`); its 正しい姿 is the unified transform descriptor /
extending fusion — pursued when a reduce-heavy bench needs it, NOT bundled with the
sieve (which never reduces). Tracked as **D-445** (open, not deferred-forever).

## Alternatives considered (Devil's-advocate fork, fresh context, 2026-06-15)

> Reflected verbatim. The DA grounded against the actual cljw code and v0. Its
> recommendation (Alt 2 / Zig producer) was correct **conditional on the premise
> that the sieve is depth-bound** — the premise the implementation-measurement
> falsified. Preserved as the rationale record + the reason the NO-GO is evidence-,
> not effort-, grounded.

**Fact A — v0's winning fix WAS a2's shape, not a1's.** The 103× sieve win
(1645→16ms) came from the Zig `lazy_filter_chain` union arm producing the next
survivor directly in Zig and re-stamping the chain marker on `rest_source`. The
separate fused-reduce only got sieve to 40ms (2× Python). So the `.clj`-tree-walk
approach is what left sieve above Python in v0; the Zig producer is what crossed.

**Fact B — sieve never reduces.** It forces via `first`/`rest`/`take`, never
`reduce`. cljw's O-023 fuse fires only in `reduceFn`'s 3-arg arm. So a chain marker
must be read on the lazy force path.

### Alt 1 — smallest-diff: `chain` slot read on the lazy force path only (≈ a1)
`.clj`-level flattening read; flat short-circuit loop over N preds per survivor.
- Better: honest about what sieve exercises; clears the torture gate trivially.
- Breaks: keeps the per-element `.clj` `lazy-seq`/`cons`/`loop` tree-walk; v0's data
  says ~40ms-class, plausibly still above Python — a correct but incomplete landing.

### Alt 2 — finished-form-clean: Zig `lazy_filter_chain` producer (v0's shape) [DA pick]
Zig flat-walk; predicates via `callFn`; tail re-stamps the chain.
- Better: the only alternative with measured evidence of beating Python *in v0*;
  removes both the depth re-entry and the per-element `.clj` tree-walk.
- Breaks / the real axis: a new Zig GC-root site (F-006) — bounded and
  gate-verifiable (the `reduceFn` `gc_roots[]` idiom is copy-adaptable). [This was
  built; the GC-root frame worked. What the DA could not foresee without measuring
  was that the cljw sieve isn't depth-bound, so removing the depth cost banks ~0.]

### Alt 3 — wildcard: fold `chain` + `fuse` into one "lazy transform descriptor"
One `xf_desc` slot consumed by `-fused-reduce` AND a flat producer.
- Better: the most finished-form-clean answer to "two slots is duplication"; the
  user's fused-reduce 正しい姿. Future-proofs `map`-chain collapse.
- Breaks: touches the gate-green O-023 path; a transducer stack ≠ a pred vector — a
  deliberate refactor ADR, and (post-measurement) one whose lazy-walk half is moot
  for the sieve. The reduce half lives on as D-445.

### Verdict (DA, then corrected by measurement)
DA: commit to Alt 2 (the Zig producer); a1-first was the Cycle-budget-defer smell.
**Measurement correction:** the whole a1-vs-a2 axis assumed the sieve is
depth-bound. It is fn-call-bound. So Alt 2's "removes the per-element `.clj`
tree-walk" advantage banks nothing on the sieve (the `.clj` scaffolding was never
the cost). The Cycle-budget-defer smell does not apply to a NO-GO grounded in
*measured no-effect on the target* — that is finished-form judgment (F-002), not an
effort dodge. Both a1 and a2 are rejected for the sieve; the lever is fn-call speed.

## Consequences

- No source lands this cycle (the Stage-1 implementation was reverted after the
  measurement). The cycle's deliverable is the **finding** + this redirect.
- The §9.2.S sieve loser stays **OPEN**, retargeted at **`fn*`/closure invocation
  speed** (the next stage; D-386 dispatch / intrinsic family).
- **D-445** (open, NOT deferred-forever): fused-reduce in its proper form (the
  unified transform descriptor) — the user's live interest, on the **reduce** path,
  pursued when a reduce-heavy bench needs it.
- A lesson worth keeping: **the diff oracle (TreeWalk≡VM) is necessary but not
  sufficient** — a bug identical on both backends passes it; `clj` corpus + torture
  + direct probing are the backstops (already project doctrine; reinforced here).
- No `chain` slot is added to `LazySeq`; the hot `force` path is unchanged.

## Affected files

- None land. (Reverted: `src/runtime/lazy_seq.zig`, `src/lang/primitive/higher_order.zig`,
  `src/lang/clj/clojure/core.clj`.)
- `.dev/debt.yaml` — D-445 row (fused-reduce proper form, reduce path).
- This ADR + the survey note — the preserved investigation.
