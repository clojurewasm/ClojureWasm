# GC-rooting SSOT — every site that publishes / holds / decodes a GC root

> **SSOT for the cljw GC rooting surface** (user direction 2026-06-05: "GC
> まわりの散りを SSOT 化、将来 GC 方式を変えるときに移行しやすく"). The current
> GC is precise **mark-sweep, non-moving, single-generation** (F-006). A future
> **moving / compacting** GC rewrites object pointers on collect; each site
> below carries a **migration-impact** line stating what that GC needs here that
> the non-moving one does not, so the swap can be enumerated mechanically.
>
> Grep target: `rg 'GC-ROOT:' src/` finds the in-code markers that anchor each
> published-root site to this file (the `GC-ROOT:` marker discipline, sibling to
> `PERF:` / `.dev/optimizations.md`). The marker rule lives in
> `.claude/rules/gc_root_marker.md` (carry-over: pending — the auto-mode
> classifier blocks `.claude/rules/*` edits as self-modification, memory
> `claude-rules-edit-permission-block`).
>
> Keep current: re-run the sweep (a `general-purpose` agent over `src/`) at each
> Phase boundary or when a new reentrant primitive / root slot / per-tag trace
> lands; reconcile against this file. The mechanical guards (below) catch the
> two highest-value drifts automatically.

## The three seams

1. **ALLOCATION** — `GcHeap.alloc(T)` (`src/runtime/gc/gc_heap.zig`) +
   `Runtime.trackHeap` (`src/runtime/runtime.zig`). `*T` and the live-list
   `*HeapHeader` are the SAME address (HeapHeader-at-offset-0, comptime-checked).
2. **TRACE** — per-tag `tag_ops.tag_trace_table` via `registerTrace`
   (`src/runtime/gc/tag_ops.zig`); each type registers in `registerGcHooks()`.
3. **ROOT ENUMERATION** — `root_set.enumerate` / `RootIterator.next`
   (`src/runtime/gc/root_set.zig`).

The D-251 / ADR-0094 / ADR-0095 bug class was **root-holding**: a site holds a
GC `Value` in a Zig local across reentrant eval, or in an off-`gc.allocations`
container, and must publish it. Category C is the live front of that class.

## Mechanical guards (drift cannot accumulate silently)

- **membrane ↔ trace consistency** — `Runtime.init` asserts every tag with a
  registered trace or finaliser is `isGcManaged` (`runtime.zig`), so the trace
  table and the `heap_tag.isGcManaged` membrane (G) cannot drift.
- **GC torture** — `CLJW_GC_TORTURE=N` forces a collect every Nth VM back-edge
  poll; an UNROOTED-CANDIDATE (C) surfaces deterministically as a UAF.
  `test/e2e/phase16_gc_torture.sh` locks the closed sites.

---

## A. EvalFrame producers (`root_set.EvalFrame`)

`EvalFrame { stack, sp, locals, constants, parent }`, threadlocal head
`eval_frame_head`. Walk drains `stack[0..sp]` → `locals` → `constants` → parent.

| #  | Site                                              | Kind                                                     | Roots                                                                                                                                                               |
|----|---------------------------------------------------|----------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| A1 | `eval/backend/vm.zig` (`eval` body)               | VM activation (one per `vm.eval`, chained via `op_call`) | operand `stack[0..sp]`, call-frame `locals`, `constants = chunk.constants` (executing chunk's literal pool, ADR-0095 2a)                                            |
| A2 | `lang/primitive/higher_order.zig` (`reduceFn`)    | reentrant-primitive MANUAL frame (ADR-0094)              | 3 slots `[f, acc/coll, cur]`, refreshed in place before each reentrant call                                                                                         |
| A3 | `runtime/concurrency/safepoint.zig` (test)        | test-only fixture                                        | —                                                                                                                                                                  |
| A4 | `runtime/iref.zig` (`notifyWatches`)              | shared IRef watch firing (agent drainer + STM commit)    | 3 slots `[ref, watch map, key cursor]`, cursor refreshed before each `vt.callFn` (a watch fn re-enters the VM)                                                      |
| A5 | `runtime/concurrency/lock_tx.zig` (`fireWatches`) | post-commit ref-watch firing                             | flat `[ref, old, new, ...]` notifies list published whole: an already-fired `old` recycled from the ring would otherwise be swept before a later notification fires |

**Migration-impact:** `stack`/`locals`/`constants` are **const** views; a moving
GC must rewrite relocated operand/local/constant Values, so they become mutable
and the walk forwards (not just marks). `chunk.constants` lives in the analyser
arena — under relocation the literals it holds still move, so the pool needs
writability or a literal-copy-to-heap. A2's `gc_roots` Zig array is already a
mutable local handed to the collector by address — migration-clean.

## B. Threadlocal root slots

| Slot                            | Declared       | Written                                                                           | Walked                               |
|---------------------------------|----------------|-----------------------------------------------------------------------------------|--------------------------------------|
| `eval_frame_head`               | `root_set.zig` | A1/A2 (set head / defer-restore)                                                  | yes                                  |
| `macro_root_slot`               | `root_set.zig` | **NO production writer** (test-only; Phase-B-deferred infra)                      | yes                                  |
| `gc_self_guard`                 | `root_set.zig` | **NO production writer** (test-only; #4-deferred infra)                           | yes                                  |
| `current_frame` (binding stack) | `env.zig`      | `pushFrame`/`popFrame` (dynamic binding / `let`-dynamic / `push-thread-bindings`) | yes (drains each frame's `bindings`) |

**Key:** `macro_root_slot` + `gc_self_guard` are declared + walked + tested but
never written by production — inert until Phase-B / #4 wiring. Torture cannot
exercise them today. **Migration-impact:** single addressable `?Value` /
chain-head slots — the collector writes through them; migration-clean once the
walk is "yield slot to forward" not "yield header to mark". `current_frame`'s
`BindingMap.valueIterator()` is **by-value** — a moving GC needs `getPtr`
iteration to rewrite relocated binding values.

## C. Reentrant primitives holding GC accumulators across eval (the bug class)

A Zig fn loops over `invokeCallable`/`seqFn`/`firstFn`/`nextFn`/`force`/
`vt.callFn`/`dispatchOrNull` (each re-enters `vm.eval` → back-edge poll / torture
collect) while holding a `Value` accumulator in a Zig local on no published
stack. ROOTED → opened an `EvalFrame`. UNROOTED-CANDIDATE → latent UAF the next
torture round can hit.

**ROOTED (safe):** `reduceFn` (A2) — the canonical exemplar. Also
`equal.zig` `seqEqualInstance` (realizes a Sequential-instance operand via the
ISeq `-next` protocol) and `seqEqualWalk` (walks two native seqs via lazy
cursors — its frame roots the operands, the advancing cursor heads, AND the
per-step elements). `seqEqualWalk` was an UNLISTED unrooted candidate until
2026-06-25: comparing two lazy seqs interleaves their realization, and a collect
mid-walk corrupted the comparison (a math.combinatorics partitions test failed
intermittently; minimal repro `(= (map inc (range 50)) (filter pos? (map inc
(range 50))))` → false under alloc-torture). Now frame-rooted; e2e guard
`phase16_gc_torture/lazy_eq_interleave`.

**UNROOTED-CANDIDATE (tracked D-252):**

| #  | Site                                                                    | Held accumulator                                                            | Reentrant call                                                      | Severity                                                                                       |
|----|-------------------------------------------------------------------------|-----------------------------------------------------------------------------|---------------------------------------------------------------------|------------------------------------------------------------------------------------------------|
| C1 | `higher_order.zig` `applyFn`                                            | `collected: ArrayList(Value)` on `rt.gpa` (off-heap, off-stack)             | `seqFn`/`firstFn`/`nextFn` per spread element                       | HIGH (apply-over-lazy; N-wide off-heap list)                                                   |
| C2 | `higher_order.zig` `everyQFn`                                           | `cur` seq cursor                                                            | `seqFn`/`firstFn`/`invokeCallable`/`nextFn`                         | med                                                                                            |
| C3 | `higher_order.zig` `someFn`                                             | `cur`, `r`                                                                  | same as C2                                                          | med                                                                                            |
| C4 | `collection/sorted.zig` `insert` (recursion)                            | half-built RB-subtrees                                                      | `compareKeys → vt.callFn` (custom `sorted-map-by` comparator only) | HIGH on `-by` path                                                                             |
| C5 | `collection/sorted.zig` `deleteNode`                                    | rebalanced nodes                                                            | custom comparator `vt.callFn`                                       | HIGH on `-by` path                                                                             |
| C6 | `lang/primitive/walk.zig` `walkFn`/`applyInner`                         | partially-rebuilt nested collection                                         | `vt.callFn` per node                                                | med                                                                                            |
| C7 | `runtime/multimethod.zig` `callMultiFn`                                 | `dispatch_val` between the 2 reentrant evals                                | `vt.callFn` dispatch then method                                    | low-med                                                                                        |
| C8 | defprotocol/defrecord path (`protocol.zig`/`type_descriptor.zig` reify) | a protocol-path Value swept to nil                                          | reentrant eval during protocol bootstrap                            | KNOWN-OPEN (torture)                                                                           |
| C9 | filter/keep/remove chunk-builder (`.clj` + `chunked_cons.zig`)          | partial chunk over a chunked source, consumed by a lazy op / CLI auto-print | lazy thunk machinery                                                | KNOWN-OPEN (torture); suspected membrane/lazy-realisation interaction, NOT a missing Zig frame |

**Migration-impact:** all of C need the SAME fix the moving GC needs — publish
the accumulator as a mutable, collector-addressable root (an `EvalFrame` slot
like A2). Fixing C1-C9 now (for torture-green) doubles as moving-GC prep. C1's
gpa `ArrayList` is hardest (a moving GC walks + rewrites every element).

## D. Permanent / pinned roots

| #  | Mechanism                                                                                                | Roots                                                                                                                                                                                                             |
|----|----------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| D1 | `GcHeap.pin`/`unpin` → `permanent_roots: ArrayList(Value)`                                              | embedder-pinned Values                                                                                                                                                                                            |
| D2 | `future.zig` `gc.pin(fut_val)`                                                                           | Future result cell (worker write target, no deref'er)                                                                                                                                                             |
| D3 | `agent.zig` `gc.pin(agent_val)`                                                                          | Agent (drainer thread)                                                                                                                                                                                            |
| D4 | `trackHeap` → `heap_objects` + `gc.registerPersistentMark` → `persistent_marks: ArrayList(*anyopaque)` | process-lifetime gpa objects (`Function`, `ProtocolDescriptor`, `ProtocolFn`, `TypeDescriptorRef`) OUTSIDE `gc.allocations`; `collect` clears their mark bit each cycle so their trace re-runs (ADR-0095 Class 1) |
| D5 | `trackHeap` callers                                                                                      | `tree_walk.zig` (Function ×3), `protocol.zig` (×3), `type_descriptor.zig` (×1)                                                                                                                                 |

**Migration-impact:** D1-D3 are addressable `ArrayList(Value)` — rewrite each
entry on move. **D4 is the single highest-risk migration site:** raw
`*anyopaque` header aliases of objects a moving GC may relocate, AND those
objects are not in `allocations` (a compacting sweep won't naturally see them).
A moving GC must keep `trackHeap`'d objects pinned (non-moving region) OR upgrade
`persistent_marks` to a forwardable handle list — decide before relocating any
`trackHeap`'d object.

## E. In-txn / concurrency roots

| #  | Mechanism                                                                              | Roots                                                                                                                                                                                                                                                                                                                                                                           |
|----|----------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| E1 | `lock_tx.current_tx` + `markRoots` (self, `mark_sweep.collect`)                        | in-txn `vals` cache + pending `commutes` Values (#4a')                                                                                                                                                                                                                                                                                                                          |
| E2 | `markRegisteredTxs` → worker `tx_slot`                                                | each parked worker's `current_tx` (future/agent point `tx_slot` at theirs)                                                                                                                                                                                                                                                                                                      |
| E3 | `ThreadGcContext` registry (`registerThread`/`unregisterThread`, fixed `[64]`)         | union of every live worker's `current_frame`+`macro_root_slot`+`eval_frame_head`+`gc_self_guard`+`tx_slot` (registrants: future.worker, agent.drainer)                                                                                                                                                                                                                          |
| E4 | safepoint STW (`gc_requested`/`park`/`stopWorld`, target recomputed each wake)         | mechanism (not a source) ensuring workers quiescent during collect; `stopWorld` recomputes the park target from the lock-free `registered_count` each wake + a leaving worker calls `noteWorkerLeft`, so a tiny-action drainer that unregisters before it ever parks cannot hang the collector (D-244 #4)                                                                       |
| E5 | `object_monitor` `held[]`                                                              | **NOT a GC root** (locked object already rooted via the operand-stack walk; held-set only counts re-entries)                                                                                                                                                                                                                                                                    |
| E6 | safepoint blocking-safepoint (`enterBlocked`/`exitBlocked` via `lockMutexAtSafepoint`) | mechanism (not a source): a registered WORKER blocking on a lock held ACROSS a collect counts as parked so the STW rendezvous proceeds; its published EvalFrame is walked while it blocks. Applied at the `delay` once-lock — the only site that runs arbitrary eval (the thunk) under a lock, so the COLLECTING main holds it across a collect (D-244 #4 delay-once deadlock) |

**Migration-impact:** E1/E2 walk `tx.vals` **by value** — needs mutable map-slot
iteration to rewrite relocated values (and `*Ref` keys move if Refs are
GC-managed). E3 stores pointers to worker threadlocal slots — migration-clean.
E5's raw `*HeapHeader` identity lookup must rekey on move (or pin the monitored
object for the `locking` body).

## F. Per-tag traces + leaf cross-check

~37 `registerTrace` + 13 `registerFinaliser`, all from `registerGcHooks()`
(aggregated in `Runtime.init`). Trace body walks GC fields via
`field.heapHeader()` (the membrane, G) + `mark(gc, child)`. Full per-tag table:
see `private/notes/gc-rooting-ssot-sweep.md` §F (the raw sweep). GC-managed LEAF
tags with NO trace (terminal): `.string` (bytes on infra, finaliser only),
`.big_int` (limbs on gpa, finaliser only). Non-GC tags (filtered by `isGcManaged`,
never marked): `.symbol`, `.keyword`, `.var_ref`, `.ns`.

**Migration-impact (every trace, ~37 sites):** today `if (x.heapHeader()) |h|
mark(gc, h)` is a read-only mark; a moving GC makes each a **mark+rewrite** of
the field slot. Centralise via a `markSlot(gc, *Value)` helper so the 37 sites
call one updated path. This is the bulk of the moving-GC trace work.

## G. The membrane (`Value.heapHeader()` + `isGcManaged`)

| #  | Site                                            | Role                                                                                                                                                                                        |
|----|-------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| G1 | `Value.heapHeader()` (`value.zig`)              | the single `Value → ?*HeapHeader` decode; returns `null` for f64 / immediate band / **heap-tagged-but-non-GC** via `isGcManaged` BEFORE `decodePtr`. Every root walk + trace funnels here. |
| G2 | `heap_tag.isGcManaged(tag)`                     | the SSOT classifier: `false` for `{symbol, keyword, var_ref, ns}` (gpa-interned / Env-lifetime, no header@0), `true` otherwise (ADR-0095 Alt D)                                             |
| G3 | `Runtime.init` consistency guard                | asserts trace/finaliser tags ⊆ GcManaged                                                                                                                                                   |
| G4 | `Tag`↔`HeapTag` 1:1 integer cast (`value.zig`) | relies on slots 0..63 identical (immediate band already returned)                                                                                                                           |

Other manual header users: `mark_sweep.mark` (the engine), `locking.zig`
(monitor object header, not a root), `clearPersistentMarks` cast (D4), the
whole-u32 `gc_and_lock` CAS in `object_monitor` (preserves 30 mark bits while
flipping 2 lock bits).

**Migration-impact:** G is the chokepoint the moving-GC redesign should exploit
— install the read-barrier / forwarding-pointer read HERE so all ~40 downstream
`heapHeader()` callers forward uniformly. Returning a bare `*HeapHeader` by value
is the "raw alias breaks under relocation" hazard; hand back the slot address or
a forwarding-aware handle instead. `isGcManaged` stays correct (the non-GC set
doesn't move — interned symbols/keywords, Env-lifetime var_ref/ns).

## H. `.host_instance` Value-in-raw-slot (ADR-0106 / ADR-0114)

`.host_instance` (`runtime/host_instance.zig`) carries a fixed `[4]u64 state`
plus its surface descriptor. Most host types are GC-leaf (Random's LCG seed, URI
/ StringBuilder's gpa-buffer pointer = non-Value words). **java.util.Iterator is
the exception**: its cursor seq is a live `Value` stored as a raw `u64` in
`state[0]`. The shared `.host_instance` tracer forwards to
`descriptor.host_trace`, which decodes via `heapHeader()` (G1) and marks — so the
current non-moving GC is correct.

**Migration-impact (the reason this is its own section, not just an F row):**
unlike every other trace, the Value here lives in a `u64` slot the standard
typed-field walker CANNOT recognise as a pointer. A moving GC must RELOCATE it
through `host_trace` (rewrite `state[0]` with the forwarded bits), so the
`markSlot(gc, *Value)` centralisation (F) does NOT automatically cover it — the
host_trace hooks need their own mark+rewrite pass. The finished-form fix is a
closed `host_state_shape` enum on the descriptor (`leaf` / `owns_buffer` /
`holds_value@idx`) so the shared tracer relocates `holds_value` slots uniformly
instead of per-hook (DA Alt B-finished-form-clean; debt **D-318**).

---

## Migration checklist (moving / compacting GC swap), ordered by risk

1. **Membrane (`heapHeader`, G) becomes forwarding-aware** — the linchpin; do first.
2. **Every trace fn → mark+rewrite (F, ~37 sites)** — centralise via `markSlot(gc, *Value)`.
3. **`persistent_marks` (D4) — highest-risk** — pin `trackHeap`'d objects in a non-moving region OR forwardable handles.
4. **EvalFrame slot views become mutable (A)** — `stack`/`locals`/`constants` writable; arena constant pool writable or literal-copy-to-heap.
5. **Off-heap root containers as rewritable arrays (C1, D1-D3, E1-E2)** — `getPtr`/index iteration, write forwarded pointers.
6. **Close UNROOTED-CANDIDATE C1-C9 with the EvalFrame pattern FIRST** — torture-green now == moving-GC prep. Priority: C1, C4/C5, C8, C9.
7. **Map / set iteration becomes slot-mutable (B `current_frame`, E1 `tx.vals`, F map traces)** — `getPtr` or post-move rehash.
8. **Monitor / lock (E5, G)** — pin monitored objects for the `locking` body, or rekey on relocation.
9. **`macro_root_slot` / `gc_self_guard` (B)** — inert today; wire (Phase-B) then migrate (trivial single slots).
10. **`ThreadGcContext` (E3)** — already migration-clean (forwards through slot pointers).

## Site census (grep target)

- EvalFrame producers: 6 production (vm, reduceFn, iref.notifyWatches, lock_tx.fireWatches, equal.seqEqualInstance, equal.seqEqualWalk) + 1 test.
- Threadlocal root slots: 4 (2 inert).
- Reentrant accumulators: 3 rooted (`reduceFn`, `equal.seqEqualInstance`, `equal.seqEqualWalk`) + 9 UNROOTED-CANDIDATE (C1-C9, D-252).
- Permanent/pinned: 3 `pin` callers + 6 `trackHeap`/`persistent_marks` callers.
- In-txn/concurrency: self-tx + worker-tx + `ThreadGcContext` (2 registrants) + safepoint (STW rendezvous + blocking-safepoint).
- Per-tag traces: ~37 `registerTrace` + 13 `registerFinaliser`; 4 non-GC tags + 2 GC-leaf tags.
- Membrane: 1 decode + 1 classifier + 1 guard; ~40 downstream callers.

## Cross-references

- ADR-0028 (mark-sweep GC) · ADR-0091 (operand-stack root + thread union) ·
  ADR-0094 (reentrant-primitive accumulator rooting) · ADR-0095 (external-
  container rooting + `isGcManaged` membrane).
- F-004 (NaN-box 64-slot, 47-bit GPA-backed heap) · F-006 (mark-sweep,
  non-moving, single-gen) — the moving-GC swap is an F-006 amendment (user-owned).
- `.dev/debt.yaml` D-251 (the rooting campaign) · D-252 (the C1-C9 candidates).
- `private/notes/gc-rooting-ssot-sweep.md` — the raw sweep (full per-site
  file:line detail).
