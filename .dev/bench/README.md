# Collection-algorithm parity bench (cljw vs clj)

Motivating question (user, 2026-08-13): *for performance, should cljw reimplement
the same immutable algorithms core Clojure does?*

Answered by measurement rather than by reading either implementation, per the
"measure the provider before you abstract it" principle: the same probe form is
evaluated in a cljw nREPL and a JVM Clojure 1.12.4 nREPL on the same box.

## Method

`scaling_form.edn` — run a FIXED number of operations (2000, after 300 warmup
iterations so the JVM has JIT-compiled) against collections of growing size
`[1000 4000 16000]`. Flat wall-clock across sizes means the operation is
O(1)/O(log n) per call; time growing with the size factor means O(n).

Run it in both REPLs:

    code cider spawn repl_type=cljw name=perf-cljw project_dir=<repo>
    code cider spawn repl_type=clj  name=perf-clj  project_dir=<repo>
    code cider eval  session_name=... code=<contents of scaling_form.edn, one line>

`scaling.clj` / `traversal.clj` are the standalone script forms (`cljw
.dev/bench/scaling.clj`) — same probes, human-readable output, plus a
whole-collection traversal probe that checks for accidental O(n²).

## Result, 2026-08-13 (ms per 2000 ops at n=16000, ReleaseSafe vs clj 1.12.4)

| op | clj | cljw | verdict |
|---|---|---|---|
| `nth` (mid) | 0.31 | 0.26 | cljw faster |
| `assoc` (mid) | 5.17 | 1.20 | cljw faster |
| `conj` | 2.79 | 2.29 | comparable |
| `map` `get` | 0.58 | 0.42 | cljw faster |
| `map` `assoc` | 3.38 | 2.26 | cljw faster |
| `map` `dissoc` | 5.09 | 1.15 | cljw faster |
| `list` `conj` | 0.36 | 0.43 | comparable |
| **`pop`** | **1.93** | **8278** | **4288× slower → FIXED (O-056), now 2.47** |
| **`subvec`** | **1.06** | **7929** | **7480× slower** |
| **`seq`** | **0.60** | **2123** | **3549× slower → FIXED (O-058), now 0.36** |
| **`rest`** | **0.87** | **2253** | **2576× slower → FIXED (O-058), now 0.39** |
| **`next`** | **0.99** | **2164** | **2184× slower → FIXED (O-058), now 0.38** |
| **`list` `count`** | **0.18** | **481** | **2711× slower → FIXED (O-057), now 0.19** |

### Correction: the small deltas above are NOT reliable

The first table's "cljw faster" verdicts on the sub-microsecond ops were an
artefact of too few reps and no baseline. Re-measured best-of-7 over 20000 ops
with an empty-loop baseline subtracted (n=16000):

| per 20000 ops | clj | cljw | |
|---|---|---|---|
| **empty `dotimes`** | **0.043** | **0.900** | **clj 21× faster** |
| `nth` | 0.373 | 0.879 | cljw 2.4× |
| `assoc` | 49.38 | 21.43 | cljw 2.3× |
| map `assoc` | 73.93 | 18.77 | cljw 3.9× |
| map `dissoc` | 2.62 | 8.15 | clj 3.1× |
| `conj` | 1.75 | 7.62 | clj 4.4× |

Two separate things, which the first table conflated:

- **Interpretation speed: the JVM is far ahead.** An empty loop costs cljw 45ns
  per iteration against the JVM's 2.2ns. That is not Zig losing to Java — it is
  an *interpreter* (tree-walk / VM) losing to a *JIT* that has compiled the loop
  to native code with the induction variable in a register. Nothing about the
  collection work changes it; only a compiler would.
- **The persistent structures themselves: same league, trading wins.** cljw is
  ahead on `nth` and on both `assoc`es (its bump-allocating GC makes the
  path-copy cheaper); the JVM is ahead on `conj` and `dissoc`. No 1000× effects
  in either direction once the algorithms match.

So: do not read this bench as "Zig beats the JVM". Read it as "the data
structures are sound, and every catastrophic number below is algorithmic".

### The catastrophic numbers are algorithmic, not linguistic

Every loss is one of two specific mistakes, and neither is a data-structure
problem:

1. **An abstraction-barrier violation** — the Clojure layer re-implements an
   operation the Zig barrier already provides correctly. `pop` was the pure
   case: `vector.zig::pop` is a faithful `PersistentVector.pop()`, and
   `core.clj` bypassed it with `(into [] (take (dec (count coll)) coll))`.
   Fixed as O-056; the fix added no algorithm, it just exposed the barrier op.

   `list count` was the same class with a twist: the barrier op existed
   (`Cons.count`, O(1)) but was DISTRUSTED, because a `.list` cell can head a
   mixed chain (`(cons x (map …))`) where the stored number is the `.list`
   prefix length, not the total. Fixed as O-057 by making the field
   self-validating — a `COUNT_UNKNOWN` sentinel marks exactly the chains that
   must still walk — rather than by waiting for the D-178 `.list`/`.cons` tag
   split the old comment deferred to. When a barrier value is right *most* of
   the time, say WHICH times in the value itself; a blanket distrust throws
   the fast path away for every caller.

2. **Materialising where Clojure keeps a VIEW** — `seq`/`rest`/`next` on a
   vector build an eager `PersistentList` (`sequence.zig` `vectorToList` /
   `vectorTailAsList`) where Clojure returns a `ChunkedSeq` holding
   `(vector, index)`; `subvec` eagerly copies (D-044) where Clojure returns an
   `APersistentVector$SubVector` sharing the parent's root and tail.

## Ranked remaining work

| # | Fix | Kind | Unblocks |
|---|---|---|---|
| ~~1~~ | ~~`SubVector` view~~ → still open, but on its OWN | view | `subvec` (7480×) and slice-style ops built on it |
| ~~2~~ | ~~Chunked vector-seq VIEW behind the existing seq protocol~~ | view, not algorithm | **DONE — O-058. `seq`/`rest`/`next` are now an `.array_seq` view; all three are FASTER than clj.** |
| ~~3~~ | ~~Cached count on `PersistentList`~~ | ~~one field~~ | **DONE — O-057.** |

### Correction: (2) never needed (1)

The earlier revision of this file ranked `SubVector` above the vector-seq on the
grounds that it was the seq's *enabler* — "the vector analogue of 'a smaller
range' is 'the vector minus its first 32 elements', which is exactly a
`SubVector` view". That was wrong, and it stalled the larger win behind a
`heap_tag`-census question that did not apply to it.

`next` of a seq is a **seq**, not a collection. Clojure's own answer is
`PersistentVector$ChunkedSeq`, which holds the SAME vector at a higher index —
it never constructs a smaller vector. So the seq view needs `(vector, index)`,
which is what O-058 built, and `subvec` is an independent problem about
returning a *vector* that shares a parent's root and tail.

Two lessons worth keeping, because both were reasoning failures rather than
implementation ones:

- **Check what the reference implementation actually returns** before deriving a
  dependency from an analogy. The analogy to `.range` was apt for the chunking
  *mechanism* and misleading about the *tail type*.
- **A blocked item can block a neighbour that is not actually downstream.** The
  census question ("may we spend one of the 9 `unallocated` names") is real for
  `SubVector` and was never live for the seq view — A14 `.array_seq` was already
  an allocated slot, already declared across every protocol table in
  `interface_membership.zig`, already named in `class_name.zig`, and merely had
  no producer. `equal.zig`'s header anticipated it in as many words: "when a
  producer mints those tags."

### What is left: `subvec` (7480×)

`vector.zig::subvec` eagerly copies (D-044) where Clojure returns an
`APersistentVector$SubVector` sharing the parent's root and tail. This one DOES
have to answer the tag question, and it is a genuine user decision per
`heap_tag.zig`'s own doc:

- **(a) repurpose an `unallocated` slot** (`.tuple` / `.box` are the plausible
  names) — clean and polymorphic, and the census is explicitly published so that
  the question is "may `box` become `subvec`", not "may we amend F-004". Spends
  a name.
- **(b) `start: u32` inside `Vector`'s existing `_pad: [6]u8`** — no struct
  growth and no Tag spent, but then EVERY vector op must honour the offset, and
  any path that reads `root`/`tail` without it goes silently wrong. That review
  surface is the real cost, not the four bytes.

Note the asymmetry with O-058: there, no consumer had to change, because a new
representation satisfied an existing protocol. Option (b) is the opposite shape
— it changes the meaning of an existing representation, so it touches every
consumer. That is the argument for (a) even though (a) is the one that spends
something.

### Caveat that still holds

`reduce` / `doseq` / `into` over a vector were already fast — the index-walk and
chunk-drain fast paths (O-002, O-004, O-032) bypass `seq` entirely, and
`traversal.clj` confirms they stay linear. So O-058 helped hand-written
`loop`/`recur` walks and library code rather than the idiomatic core paths,
which is why it was ranked by breadth rather than by a benchmark regression.
