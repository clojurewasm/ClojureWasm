# ADR-0095 — GC children of non-swept containers must be re-reached every collect

- **Status**: Proposed → Accepted (2026-06-05); Alt D landed (2026-06-05, next commit)
- **Amends**: ADR-0028 (mark-sweep GC) + ADR-0091 (operand-stack root walk).
  Sibling to ADR-0094 (reentrant-primitive accumulator rooting) — same
  campaign (D-251), a *different* root-gap class.
- **Driven by**: D-251 (GC root walk vs a real runtime env), surfaced by the
  D-250 torture mode.

## Context

cljw's precise mark-sweep GC (ADR-0028) sweeps objects on the `gc.allocations`
live list and clears the `HeapHeader.gc_and_lock.gc_mark` cycle bit on every
survivor at the end of each `sweep` — so each collect starts with every
GC-swept object un-marked, and `mark()`'s cycle-invariant short-circuit
(`if mark==1 return`) is per-collect.

The D-250 torture mode (force a collect at every VM back-edge poll) exposed two
distinct ways a **GC-allocated child becomes reachable only through a container
that does NOT live on `gc.allocations`**, so the child is swept even though it
is logically live. ADR-0094 covers the third way (a Zig local held across
reentrant eval); this ADR covers the two container classes:

### Class 1 — process-lifetime mark-waypoints (the stale-bit membrane)

`Function` / `ProtocolDescriptor` / `ProtocolFn` / `TypeDescriptorRef` are
`gpa.create`'d and registered via `Runtime.trackHeap` (freed only at
`Runtime.deinit`); they are NOT on `gc.allocations`, so `sweep` never clears
their mark bit. The bit doubles as the mark-phase cycle/visited flag. After the
FIRST collect marks such an object, its bit stays 1 forever, so from the SECOND
collect on `mark()` short-circuits before calling the object's per-tag trace —
and any GC child reachable **only** through it is never re-marked → swept.

`Function.closure_bindings` is the exemplar: `(vec (map inc (range 1 200)))`
under torture sweeps the source `range` (captured in the `map` lazy-seq thunk's
closure) on the collect AFTER the thunk fn was first marked — the thunk fn's
stale bit blocks `traceFunction` from re-marking its closure. Confirmed by
instrumenting: the same `lazy_seq` is marked each collect, its `thunk` is a
`fn_val` each collect, yet the closure-captured range is marked on collect *N*
and swept on collect *N+1* (the collect that first leaves the thunk fn's bit
already set).

### Class 2 — bytecode constant pools (the un-rooted literal)

A string / collection literal in source compiles to a `gc.alloc`'d Value stored
in a `BytecodeChunk.constants` slice. The slice itself lives in the run-lifetime
analyser arena (never swept), but the **literal it points at is on
`gc.allocations`** and is reachable ONLY through the pool until an `op_const`
loads it onto the operand stack. The constant pool was never a GC root, so a
collect firing BEFORE the load (the torture case) sweeps the still-unloaded
literal; `op_const` then pushes a dangling pointer. `"hello"` alone corrupts to
`"\xef\xbf\xbd..."` under torture; every string / collection literal is
affected (the dominant reason torture crashed on "every real program").

The prior `traceFunction` comment asserted constants "live in the arena, never
GC-swept" — false for the literal *values* (only the slice is arena-resident),
and the secondary "walking them reaches non-GC-shaped headers" risk is closed
because `Value.heapHeader()` already returns `null` for `var_ref`/`ns` (the only
heap-tagged Env-lifetime non-GC types), the same filter the operand-stack walk
uses.

## Decision

**Class 1** — `GcHeap` keeps a `persistent_marks` list of every `trackHeap`'d
object's header (registered in `Runtime.trackHeap`). `collect()` clears the mark
bit on each at mark-phase start, so a process-lifetime waypoint is re-traced
every cycle and its GC children are re-reached. The objects are still never
swept (not on `gc.allocations`); clearing is harmless — its sole purpose is to
let the per-tag trace run each collect. A truly-unreachable waypoint simply
isn't re-marked, and its children are correctly collectible (it can never be
invoked again).

**Class 2** — root every live chunk's constant pool, two complementary paths:

- **Executing chunks** — `root_set.EvalFrame` gains a `constants: []const Value`
  field; every `vm.eval` activation publishes `chunk.constants` alongside its
  `stack`/`locals`, so the whole pool is a root for the chunk's entire
  execution (covers the non-`Function` top-level eval chunk too). The root walk
  drains `stack[0..sp]` → `locals` → `constants`, all via `heapHeader()`.
- **Dormant `Function` chunks** — `traceFunction` marks each method / variadic
  chunk's constants (via `heapHeader()`), so a reachable-but-not-executing fn's
  literals are rooted through the fn itself (which Class 1 now re-traces each
  cycle).

Both classes share one principle: **a GC-allocated child reachable only through
a container that lives outside `gc.allocations` must be re-reached by the mark
phase on every collect** — by clearing the container's stale mark bit (Class 1)
or by making the container's pool a walked root (Class 2). Literals stay
GC-allocated (one allocation path, F-011 commonization) rather than forking a
parallel arena-allocation path per collection type.

### Landed-now vs the finished form (Devil's-advocate re-framing)

The DA fork (below, verbatim) re-framed this correctly and is **adopted**: the
"Class 1 / Class 2" labels are two *manifestations*, not two mechanisms. The
real axes are (i) **one total heap/non-GC membrane** — every container-walk
(executing pool, dormant pool, closure bindings, protocol caches) rides the
same "is this Value safe to `mark()`?" filter; and (ii) **one orthogonal
bit-hygiene clear** — never-swept waypoints get their visited-bit reset each
collect. (ii) is independent of (i) and does not fold into it.

**Landed in this ADR's commit** (safe, torture-green on the executing-chunk +
closure surface): the bit-hygiene clear (`persistent_marks` +
`clearPersistentMarks`, axis ii), the executing-chunk constant root
(`EvalFrame.constants`), and the `closure_bindings` trace.

**Deferred to the immediate next unit — the GC-rooting SSOT (DA Alt D, the
chosen finished form)**: the membrane today is an **allow-list of two known
offenders** (`Value.heapHeader()` skips only `.var_ref`/`.ns`). The constant
pool holds heap-tagged Values pointing at non-GC memory beyond those two — a raw
dormant-chunk-constant trace crashed reading `tag_trace_table[112]` (`0x70` = a
pointer low byte mis-read as a tag), so that trace is reverted. The finished
form is a single SSOT predicate `tag_ops.isGcManaged(tag)` (a comptime `[64]bool`
derived from the GC-allocator registration set, with a comptime assert that the
`tag_trace_table` / `tag_finaliser_table` / `isGcManaged` sets agree) that
`heapHeader()` consults instead of the hand-listed switch. That makes the
membrane **total** (the next non-GC heap tag is filtered by construction, not by
a `switch` arm someone forgets), un-blocks the dormant-chunk trace, and is the
shared root-cause handle for the remaining `filter`/`defprotocol` torture gaps.
It is scheduled as the next unit (also the seed of the user-requested
GC-rooting-site SSOT + `GC-ROOT:` marker discipline + future-GC-migration doc),
NOT deferred indefinitely — per F-002 its larger diff is not a reason to ship
the allow-list permanently.

## Consequences

- **Positive**: torture goes from crash-on-every-program to green on the whole
  literal + closure-realiser surface (`"hello"`, `(apply str …)`,
  `interpose`, `vec`/`into`/`mapv`/`frequencies`/`sort` over `map`-of-`range`,
  keyword/string map access). One uniform principle, no per-collection
  allocation fork, reuses the existing `EvalFrame` walk + per-tag trace
  dispatch. Class 1's clear also makes `Function` closures correct under ANY
  future auto-collect, not just torture.
- **Negative / cost**: Class 1 adds an O(num trackHeap'd objects) bit-clear per
  collect (Functions accumulate over a process — a known separate leak, see
  D-251 follow-up; the clear is cheap, a single AND per object). Class 2 adds
  the constant pool to the per-frame walk + per-`Function`-trace marking (bounded
  by live constants). Perf is Release-measured separately; the algorithmic shape
  is unchanged.
- **Precondition**: `trackHeap`'d objects must have `HeapHeader` at offset 0
  (every production caller — `Function`/`ProtocolDescriptor`/`ProtocolFn`/
  `TypeDescriptorRef` — is an extern struct that satisfies it; the cast is
  deferred to clear-time so a unit-test box that never collects is unaffected).
- **Not chosen**: arena-allocating bytecode literals (Class 2 alt) — would fork
  a non-GC allocation path for every literal collection type (anti-DRY, F-011);
  making `Function` GC-managed (Class 1 alt) — larger surgery (chunk/closure
  lifetime + finaliser) that also fixes the Function leak, deferred as its own
  D-row.

## Alternatives considered (Devil's-advocate fork, fresh context, verbatim)

> **Recommendation: Alternative D (the `isGcManaged(tag)` SSOT classifier) as the finished form, UNIFYING both classes' container-walk safety under one membrane — but it does NOT subsume the Class-1 stale-bit clear, which is a separate concern that survives unchanged.** The draft's 2-class *split* is the wrong framing: the two classes are not two mechanisms, they are one mechanism (re-reach-every-collect) applied through two container kinds, plus one *orthogonal* defect (the persistent stale-bit short-circuit) that the draft has correctly tangled into Class 1 but which is really its own thing.

### Constraint check (no alternative below violates an F-NNN)

F-004 (47-bit pointers span full VA → no cheap heap-range check), F-006 (precise, non-moving, single-gen, one root walk — generational/card-marking explicitly future-not-now), F-011 (one allocation path per type; no parallel arena fork), F-002 (finished-form wins; LOC is not a constraint) are all respected by A/B/D. The would-violate option (card-marking / generational, Alt C) is recorded as the **leading entry** below because it is the one a naive reading of "Class 1 is a write-barrier problem" reaches for.

### Leading entry — Alt C (wildcard, WOULD-VIOLATE-F-006): card-marking / remembered-set for the non-swept containers

Treat `Function`/`ProtocolDescriptor` and the constant pool as an old generation, card-mark writes into their child slots, and at collect only re-trace dirtied cards instead of clearing all `persistent_marks` + walking every pool.
- **Better than draft**: O(dirty cards) instead of O(all trackHeap'd objects) per collect; the only alternative that addresses the draft's own stated negative (Functions accumulate over a process → the bit-clear loop grows unboundedly).
- **Breaks / why rejected**: F-006 codifies single-generation, non-moving, *one* root walk and names generational/card-marking a FUTURE candidate, not now. A write barrier on every closure-slot / constant-pool store is exactly the generational machinery F-006 defers. **This cannot be the primary mechanism today.** Recorded as the wildcard; the draft's full-clear is the F-006-compliant shape and the unbounded-clear cost is a real but *separately-tracked* concern (the Function-leak D-row), not a reason to import a barrier now.

### Alt A — smallest-diff: keep the draft exactly as written (clear-all `persistent_marks` + `EvalFrame.constants` + the reverted dormant-chunk trace)

- **Better than draft**: nothing — it *is* the draft. Its merit is that it is already torture-green on the executing-chunk + closure surface and ships the least new surface.
- **Breaks / risks**: it leaves the `traceFunction` dormant-chunk-constant path **permanently reverted** with a hand-waved "needs a GC-managed-tag classifier someday" comment. That deferral is load-bearing: a reachable-but-not-executing `Function` (stored in a Var, captured in another closure, sitting in a collection) whose body holds a string/collection literal will sweep that literal under any future auto-collect — the exact Class-2 bug, just in the dormant half. The draft's own "Remaining D-251 gaps" §1/§2 (`filter`/`keep` chunk-builder; `defprotocol`/`defrecord` swept-to-nil) smell like the *same* missing classifier resurfacing, not three independent bugs. Shipping A means re-opening this file 2–3 more times.

### Alt B — finished-form-partial: unify Class 1 + Class 2 under the existing membrane, no new classifier

Observe that both classes are literally "a slice of `Value` reachable only through an off-heap container." Class 2's `EvalFrame.constants` already proves the pattern. So drop the per-container special-casing and make BOTH register the same way: the constant pool publishes through `EvalFrame.constants` (done), and `traceFunction` walks `closure_bindings` (done) — and the Class-1 *stale-bit clear* stays as the draft has it, because it is genuinely orthogonal (it is about the visited-bit, not about reachability).
- **Better than draft**: reframes the ADR honestly — there is ONE reachability mechanism (walk the container's `Value` slice as a root or via the owner's trace) plus ONE bit-hygiene fix (clear the persistent visited-bit). The draft's prose already says this ("Both classes share one principle") but then presents them as a 2-class taxonomy, which invites the reader to think there are two mechanisms to maintain.
- **Breaks / risks**: B still cannot trace **dormant** chunk constants, because the raw constant-pool walk crashes (`tag_trace_table[112]` OOB). So B is exactly the draft with better prose — it does not close the dormant gap. The crash is the tell that B is not the finished form: the membrane (`heapHeader()`) is *under-filtering*, and B leaves that defect in place.

### Alt D — FINISHED-FORM-CLEAN (recommended): an `isGcManaged(tag)` SSOT classifier in `tag_ops`, making the membrane total

Root-cause the crash. `Value.heapHeader()` filters only `.var_ref`/`.ns`, but a bytecode constant pool can hold a heap-*tagged* Value whose pointer targets **non-GcHeap memory** — an arena/interned symbol or keyword, an Env-lifetime pointer, anything `gpa.create`'d but not on `gc.allocations`. `heapHeader()` happily decodes it and hands `mark()` a `*HeapHeader` whose first byte is arbitrary → `tag_trace_table[112]` OOB. The `var_ref`/`ns` skip is an *ad-hoc enumeration of two known offenders of a general class*: "heap-tagged but not GC-managed."

The finished form is a single SSOT predicate `tag_ops.isGcManaged(tag: HeapTag) bool` (a comptime `[64]bool` table, registered the same way `tag_trace_table` / `tag_finaliser_table` are — a tag is GcManaged iff it has a registered allocator on `gc.alloc`). `heapHeader()` consults it instead of the hand-listed `.var_ref, .ns` switch. Then:
- The membrane is **total**: any heap-tagged-but-non-GC Value (today `var_ref`/`ns`; tomorrow interned symbols/keywords, arena literals, Env pointers, Wasm externref) is filtered in ONE place, by construction, not by a growing `switch` arm that the next offender forgets to extend.
- `traceFunction` can now safely walk dormant-chunk constants (un-revert the deferred path) — the OOB is structurally impossible because non-GC constants are filtered before `mark()`.
- Class 2's executing/dormant split **collapses**: both go through the same total membrane; `EvalFrame.constants` and `traceFunction`'s constant walk become two callers of one safe walk, not two policies.
- The draft's "Remaining gaps" §1/§2 become directly attackable: a protocol-path Value swept to nil and a chunk-builder source swept are both "container holds a Value the membrane mis-decoded or the walk missed" — the same classifier is the tool.

- **Better than draft**: turns the membrane from an allow-list-of-known-exceptions into a closed predicate; subsumes Class 2's two sub-paths; un-blocks the dormant-chunk trace the draft was forced to revert; gives §1/§2 a shared root-cause handle. This is the "GC-rooting SSOT" the draft's own comment promises — D builds it now instead of deferring it. Per F-002, the larger diff is not a reason to prefer A/B.
- **Breaks / risks**:
  1. **Correctness of the predicate is now load-bearing for memory safety.** If `isGcManaged` returns `true` for a tag that is sometimes non-GC (e.g. a tag reused for both an interned and a heap form), `mark()` crashes again. Mitigation: derive the table mechanically from the `registerGcHooks` set (a tag is GcManaged iff a `gc.alloc` allocator registered it), with a comptime/init-time assert that every tag with a `tag_trace_table` or `tag_finaliser_table` entry is also `isGcManaged` — the three tables must agree.
  2. **`heapHeader()` is hot** (every root-walk yield, every mark descent). A `[64]bool` indexed load is the same cost class as the existing two-arm switch; not a regression, but verify no extra branch in the GC-yield inner loop (Release-measured separately per the draft's perf note).
  3. **Class 1's stale-bit clear is still needed and still orthogonal** — D does NOT remove `clearPersistentMarks`. The classifier fixes *which Values are safe to mark*; the persistent-mark clear fixes *the visited-bit hygiene of never-swept objects*. Conflating them would be a mistake; D keeps them separate (so the ADR should stop presenting "Class 1 vs Class 2" and present "one total membrane + one bit-hygiene clear").
  4. **Symbol/keyword interning status must be confirmed.** D's payoff assumes some constant-pool Values are heap-tagged-but-non-GC (the crash proves at least one such class exists). The implementer must enumerate which constant kinds those are (interned symbol? arena keyword? the `index 112` decode points at a `Value` whose low byte is `0x70`=112, i.e. a pointer's low byte, NOT a tag — confirming it is a non-GC pointer mis-read as a header). This enumeration is the first implementation step and feeds the predicate table.

### Recommendation rationale

F-002 (finished-form) + F-011 (one mechanism, no parallel paths) both point at **Alt D**: the crash is not an incidental bug to route around with a revert — it is the membrane telling you it is incomplete. The draft's `EvalFrame.constants` (Class 2a) is correct and should stay, but framing it as half of a 2-class taxonomy *hides* that the real finished form is "make the heap/non-heap membrane total, then every container-walk — executing pool, dormant pool, closure bindings, protocol caches — rides it safely." Choosing A/B (ship the draft, keep the revert) over D on the grounds that D is a larger diff would be the **Cycle-budget defer smell**: the dormant-chunk gap, §1, and §2 are the same under-filtered-membrane defect resurfacing, and they will cost more in repeated re-opens than building the classifier once. D is recommended even though it expands this cycle's diff (F-002). The one hard caveat carried into implementation: **D must NOT delete `clearPersistentMarks`** — the stale-bit hygiene is a genuinely separate axis and the classifier does not touch it.

**One-line verdict**: The 2-class *split* is the wrong finished form — fold Class 2 into a single **total `isGcManaged(tag)` membrane** (Alt D) that subsumes executing + dormant constant pools + closure bindings under one safe container-walk (and incidentally un-blocks the reverted dormant trace + the §1/§2 gaps), while keeping Class 1's `persistent_marks` *stale-bit clear* as an orthogonal bit-hygiene fix that the classifier does not replace.

### Main-loop disposition

Alt D is **accepted as the finished-form direction** and scheduled as the immediate next unit (the GC-rooting SSOT). This commit lands the F-clean, torture-verified subset that is safe today — the orthogonal bit-hygiene clear (axis ii) + the executing-chunk constant root + the closure trace — because they are correct and complete on their own surface and gate-green now. Alt D's membrane-completion (the `isGcManaged` SSOT + un-reverting the dormant trace) is the next commit, not an indefinite deferral; sequencing two correct units is not the Cycle-budget-defer smell (which is picking a smaller *alternative* as the final answer). The DA's caveat is honored: `clearPersistentMarks` stays as a separate axis.

## Revision — Alt D landed (2026-06-05)

The DA's recommended finished form shipped in the commit after this ADR's
first. `heap_tag.zig` gained `isGcManaged(tag)` — the membrane SSOT —
classifying the heap-tagged-but-non-GC set as `{symbol, keyword, var_ref, ns}`
(`symbol`/`keyword` are `gpa`-interned via the keyword/symbol interners, never
swept; `var_ref`/`ns` are Env pointers). `Value.heapHeader()` now consults it
(`Tag`→`HeapTag` is 1:1 by integer for the heap slots) instead of the
hand-listed `var_ref`/`ns` switch — so EVERY root walk (operand stack, locals,
chunk constants, closure bindings) filters the same set in one place. The
`tag_trace_table[112]` crash is structurally gone (keyword/symbol constants are
filtered before decode), so `traceFunction`'s dormant-chunk-constant trace is
**un-reverted** — a reachable-but-not-executing fn's literals are now rooted
(`(defn g [x] (str "n=" x)) (mapv g …)` keeps `"n="` alive). A `Runtime.init`
consistency guard asserts every tag with a registered trace/finaliser is
`isGcManaged`, so a future `gc.alloc`'d type misclassified as non-GC fails fast
rather than being silently swept while live. phase16_gc_torture.sh +2
(`dormant_lit`, `kw_const`).

The DA caveats are honored: `clearPersistentMarks` (the orthogonal bit-hygiene
axis) is untouched; the membrane is now the single classifier, not an
allow-list. The broader user-requested GC-rooting-site SSOT + `GC-ROOT:` marker
discipline + future-GC-migration doc remains the next unit (this is its first
SSOT piece). The remaining gaps below are now isolated to a different class.

## Remaining D-251 torture gaps (not this ADR)

Two torture failures remain AFTER this ADR, root-caused as distinct classes for
follow-up cycles (recorded in D-251):

1. **`filter`/`keep`/`remove` chunk-builder over a chunked source**, when the
   result is consumed by another lazy op (`(map inc (filter even? (range …)))`)
   or the CLI auto-printer — `even?` receives a swept garbage float; the source
   range / chunk_buffer is swept. Eager VM-driven consumers
   (`doall`/`count`/`reduce`/`vec`/`println`) are clean. The structural
   difference from the now-clean `map` realiser is the conditional
   `(when (pred v) (chunk-append b v))` re-entering eval mid-chunk-build.
2. **`defprotocol`/`defrecord` under torture** — `__make-protocol-fn!: expected
   protocol, got nil` (a protocol-path Value swept to nil).
