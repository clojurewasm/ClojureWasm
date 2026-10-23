# Collection performance: cljw against JVM Clojure, measured

The question this page answers came from a user: *for performance, should cljw
reimplement the same immutable algorithms core Clojure does?*

It is answered by measurement rather than by reading either implementation. The
internal ledger of individual optimizations lives in `.dev/optimizations.md`;
this page is the user-facing view: what you can expect, where cljw is still
slower, and what to do about it.

**Short version.** The persistent data structures are in the same league as the
JVM's, trading wins op by op. The *interpreter* is far behind the JVM's JIT and
will stay behind until cljw compiles, which makes tight numeric loops 25 to 75
times slower than warm JVM Clojure. Every catastrophic gap ever measured here
turned out to be a specific algorithmic mistake in cljw, not a consequence of
Zig against Java or of the GC; all four found so far are fixed. For hot numeric
kernels, call compiled code: the same work in Zig through `cljw.ffi` runs about
150 times faster than in cljw.

## Method

`.dev/bench/scaling_form.edn` runs a **fixed** number of operations against
collections of growing size `[1000 4000 16000]`, after warmup iterations so the
JVM has JIT-compiled. Flat wall-clock across sizes means the operation is
O(1)/O(log n) per call; time growing with the size factor means O(n).

Both runtimes are exercised on the same box, same probe, in the same session:
cljw built `-Doptimize=ReleaseSafe`, against JVM **Clojure 1.12.4**. Numbers
below are at **n = 16000**. Reproduce with:

```sh
cljw .dev/bench/scaling.clj      # cljw side, human-readable
```

Sub-microsecond results are reported best-of-7 with an empty-loop baseline
subtracted. Without that, per-call noise and loop overhead swamp the signal and
produce confident-looking nonsense in both directions.

## Two different questions, which are easy to conflate

### 1. Interpretation speed: the JVM is far ahead

| per 20000 iterations | clj 1.12.4 | cljw |
|---|---|---|
| empty `dotimes` | **0.043 ms** | 0.900 ms |

An empty loop costs cljw ~45 ns per iteration against the JVM's ~2.2 ns. That is
not Zig losing to Java. It is an **interpreter** (tree-walk / VM) losing to a
**JIT** that has compiled the loop to native code with the induction variable in
a register. No amount of collection work changes it; only a compiler would. This
is tracked as the runtime's own "gap area III" (fusion, then a narrow ARM64 JIT).

Every number in the next section carries this overhead. Read them as *relative*
structural cost, not as a language comparison.

### 2. The persistent structures themselves: same league, trading wins

| per 20000 ops, n=16000 | clj 1.12.4 | cljw | faster |
|---|---|---|---|
| vector `assoc` (mid) | 49.38 ms | **21.43 ms** | cljw, 2.3× |
| map `assoc` | 73.93 ms | **18.77 ms** | cljw, 3.9× |
| vector `nth` | **0.373 ms** | 0.879 ms | clj, 2.4× |
| map `dissoc` | **2.62 ms** | 8.15 ms | clj, 3.1× |
| vector `conj` | **1.75 ms** | 7.62 ms | clj, 4.4× |

cljw is ahead on both `assoc`es (its bump-allocating GC makes the path-copy
cheaper) and behind on `conj` and `dissoc`. There are no 1000× effects in
either direction once the algorithms match.

So: this is not "Zig beats the JVM". It is "the data structures are sound, and
the catastrophic numbers were bugs."

## The catastrophic gaps were all algorithmic, and all are fixed

Four operations were once 1000× to 12000× slower than JVM Clojure. Every one was
a specific mistake, of exactly two kinds.

**An abstraction-barrier violation**: the Clojure layer re-implementing an
operation the Zig layer already provided correctly.

| op | was | now | vs clj |
|---|---|---|---|
| `pop` (vector) | 8278 ms | **2.47 ms** | 1.93 ms, within 1.3× |
| `count` (list) | 481 ms | **0.19 ms** | 0.18 ms, parity |

`pop` was `(into [] (take (dec (count coll)) coll))` in `core.clj`, rebuilding a
whole fresh trie, while `vector.zig` already had a faithful
`PersistentVector.pop()` that nothing called. `count` on a list walked the chain
even though every cons cell already stored its length: the stored number was
distrusted because a cell can head a mixed chain where it means something else.
The fix was to make the field say *when* it is exact, not to compute it again.

**Materialising where Clojure keeps a view**: the more systemic kind.

| op | was | now | vs clj |
|---|---|---|---|
| `seq` (vector) | 2123 ms | **0.36 ms** | 0.60 ms, cljw 1.7× faster |
| `rest` (vector) | 2253 ms | **0.39 ms** | 0.87 ms, cljw 2.2× faster |
| `next` (vector) | 2164 ms | **0.38 ms** | 0.99 ms, cljw 2.6× faster |
| `subvec` (2000 ops) | 9215 ms | **0.77 ms** | 1.06 ms, cljw 1.4× faster |

`(seq v)` built an eager `PersistentList` copy: one allocation and one trie
descent per element, per call. Clojure never copies: its seq over a vector is a
**view** holding `(vector, index)`. cljw now does the same, so all three are
O(1), and `nth` on such a seq is O(1) too (Clojure walks there).

This one mattered out of proportion to any single benchmark, because `seq` /
`rest` / `next` are what every hand-written `loop`/`recur` walk and every
library seq walk uses. It did not show up as a benchmark regression precisely
because the *idiomatic* paths (`reduce`, `doseq`, `into`) already bypassed
`seq` with index-walk and chunk-drain fast paths.

`subvec` was the last of the four. It rebuilt a whole trie per call where
Clojure returns a `SubVector` sharing the parent's root and tail. The fix
(O-059, 2026-08-22; its JVM reference was clj 1.11.1) is a new representation
with the same JVM semantics: a
32-byte `SubVector{start, end, parent}` whatever the span, flattened on nesting,
with `conj`/`assoc`/`pop` staying views. Its seq goes through the same view as a
vector's, so slicing and then walking is O(1) to start.

## What is still slow: per-element work in tight loops

With the structures sound, what remains is the interpreter's cost per element.
Measured 2026-10-22, cljw v1.15.3 against warm JVM Clojure 1.12.6 (2000 warmup
calls, best of 7), on a loaded host, so read the ratios rather than the
absolute numbers:

| per call | clj 1.12.6 | cljw | cljw slower by |
|---|---|---|---|
| `subvec` (constant time on both) | 0.08 µs | 1.0 µs | 13× |
| dot product of 1000 doubles, `(reduce + (map * xs xs))` | 85 µs | 2177 µs | 26× |
| the same as `loop`/`recur` with `nth` | 9.3 µs | 271 µs | 29× |
| `(byte-array v)` from an 8000-element vector | 40 µs | 3001 µs | 74× |

Each element costs several boxed operations at roughly 170 ns each, against a
JIT that compiles the loop to machine code. Two practical consequences:

- **Pick the loop shape.** In cljw a `loop`/`recur` over indices ran 8× faster
  than `(reduce + (map * xs xs))` over the same vector, because it skips building a
  lazy seq of boxed products. The JVM shows the same ordering (9×).
- **Do not build native data one element at a time.** Packing doubles into a
  `byte-array` in Clojure costs more than any computation you then hand it to.

## Tight numeric loops: hand them to compiled code

cljw's answer to the interpreter gap is not to out-run the JIT in Clojure. It
is to make calling compiled code cheap, from the same binary and REPL. The
same dot product and a prime search, measured the same day on v1.15.3:

| work | cljw Clojure | Zig through `cljw.ffi` |
|---|---|---|
| dot product, 1000 doubles | 1.85 ms | **12.2 µs** (about 150×) |
| dot product, 100000 doubles | 357 ms | **1.2 to 5.5 ms**, mostly copying the arguments |
| the 1000th prime | 294 ms by trial division | **1 µs** from a table Zig computed at compile time |

| one call | cost |
|---|---|
| empty Clojure fn | 167 ns |
| native function through `cljw.ffi` | 342 ns |
| wasm export, `:interp` engine | 550 ns |
| wasm export, `:jit` engine | 1.3 to 5.6 µs (grows with module size, being fixed) |

The rule: cross the boundary with a whole batch (hash the batch, take the dot
of the vector), never once per element. Today the cost that remains is getting
data across: `:bytes` arguments are copied on every call. Primitive arrays
passed without the per-element packing, and native buffers that stay on the
native side between calls, are in progress.
[`../examples/zig-native/`](../examples/zig-native/README.md) has the runnable
version of every number in this section.

## What this means if you are choosing cljw

- **Data-structure-heavy code is fine.** Persistent vectors, maps and sets
  perform comparably to the JVM's, sometimes better.
- **Tight numeric loops in Clojure are 25 to 75× slower than warm JVM
  Clojure.** That is a compiler problem, not a library one. Until cljw
  compiles, move the hot kernel to Zig, Rust or C through `cljw.ffi` (native,
  full speed) or `wasm/load` (sandboxed), and keep the program logic in
  Clojure.
- **Startup is where cljw wins outright**: milliseconds against the JVM's
  ~1 to 2 s, which is the whole point for CLI tools, scripts and serverless. See
  [`binary_size.md`](./binary_size.md) for the size side of the same story.
- **If you hit something pathologically slow, it is probably a bug.** Every
  catastrophic gap on this page was, and each was found by running a probe
  rather than by reading code. `.dev/bench/` has the harness; an issue with a
  reproducing form is useful.
