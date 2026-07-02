# 0028 — Mark-sweep GC + 3-layer allocator (Phase 5 entry)

- **Status**: Accepted
- **Date**: 2026-05-24
- **Author**: Shota Kudo (drafted with Claude, autonomous-loop self-accept per CLAUDE.md § "ADR-level designs are handled inline" after Devil's-advocate subagent review)
- **Tags**: phase-5-entry, gc, allocator, mark-sweep, free-pool, finaliser, F-006
- **Co-issued with**: ADR-0027 (NaN-box 第二世代). Paired Accepted set per §9.7 row 5.1. ADR-0027 owns the slot map + per-tag dispatch table; this ADR owns the per-tag GC-trace + finaliser dispatch + the 3-layer allocator boundary.

## Context

ADR-0017 (Phase 4 entry) committed cw v1 to a **3-allocator** model — per-evaluation arena + general-purpose + mark-sweep GC heap — and reserved the `gc_mark: u30` bits on `HeapHeader` (ADR-0009 amendment 2). The skeleton landed at task 4.0a / 4.19 (Phase 4); no `collect()` body, no free-pool, no per-tag finaliser.

User invariant **F-006** (`.dev/project_facts.md`) fixes Phase 5's body:

- **mark-sweep, single generation** (cw v0 path inheritance). Generational deferred to ROADMAP §89.2.
- **3-layer allocator**: `infra_alloc` (GPA, process-lifetime) + `node_arena` (Arena, per-program lifetime — Reader Form / Analyzer Node) + `gc_alloc` (mark-sweep, Value-lifetime).
- **cw v0 free-pool optimisation inherited** — intrusive per-(size, alignment) free list, 3-7× speed-up on `gc_stress` / `nested_update` (cited verbatim under §3 Block C).
- **cw v0 D100 5 root-set gaps pre-enumerated** — (a) macro-expansion lazy-seq realisation paths, (b) ProtocolFn / MultiFn inline caches, (c) refer()-borrowed string pointers, (d) closure-captured Values in macro callFnVal, (e) valueToForm intermediate trees. cw v0 patched these late; cw v1 lists them in the root-source table from day 1.
- **zwasm v2 integration heap layout**: cw heap and Wasm linear memory are **separate spaces**; zwasm internal bookkeeping accepts a cw GC allocator at `Engine.init(allocator)` so the dual-GC lifecycle mismatch (cw v0 D110) does not recur. `wasm_module` / `wasm_fn` are cw-GC-managed Values; zwasm metadata lives underneath them.

The 5.0 cleanup audit (ADR-0026 + `private/notes/phase5-skeleton-audit.md`) bound 8 input constraints; bullets #1 / #3 / #5 / #6 are ADR-0028's territory and are quoted verbatim in §"Inputs from 5.0 audit" below.

cw v0 archaeology at `private/notes/phase5-5.1-survey.md` produced three load-bearing findings that change cw v1's shape vs. cw v0:

1. cw v0 stores mark bits **externally** in `allocations: AutoArrayHashMapUnmanaged(usize, AllocInfo)` (`gc.zig:181-185, 296-301`). cw v1 stores marks **inline** per ADR-0009 + F-006; the spare 29 bits (1 mark used out of 30) are a free-pool size-class hint per F-006's inheritance language.
2. cw v0 overlays the free-pool `FreeNode { next }` at **offset 0** of the freed payload (`gc.zig:158-162`) — clobbering the header. cw v1's mandatory `HeapHeader` at offset 0 forces the overlay to **offset 8** (after the 8-byte header).
3. cw v0 calls **no per-tag finaliser** for BigInt (`gc.zig:1125-1129` literally just `markPtr(bi)`). `std.math.big.int.Managed`'s limb array leaks silently until the GC heap reclaims the backing — fragile when the limbs sit on a different allocator. cw v1 mandates a per-tag finaliser table from day 1.

cw v0 also takes a `suppressCollection()` escape hatch (`analyzer/analyzer.zig:567-571`) for D100 root causes #5 and #6 (macro-expansion lazy-seq closure captures + half-built valueToForm trees) — turning GC off across the macro-expansion bracket. cw v1 refuses the escape hatch per F-002 (finished form wins): macro-expansion roots must be enumerable, not suppressed.

## Decision

### 1. GC strategy: single-generation tracing mark-sweep

Stop-the-world tracing collector, two phases:

- **Mark**: visit every root, recursively trace through GC-managed pointers, set `HeapHeader.gc_and_lock.gc_mark` bit 0 to 1 on every reached object. Per-tag dispatch (§5 trace table) decides which pointer fields to follow.
- **Sweep**: walk the GC heap's allocation list. For every object with `gc_mark == 0`: call the per-tag finaliser (§4), unlink from the live list, push onto the matching `(size, alignment)` free pool (§3). For every object with `gc_mark == 1`: clear the bit and keep.

Trigger: `gc_alloc.alloc` checks `bytes_since_last_gc > threshold` with an **adaptive threshold** (per Devil's-advocate Load-bearing concern #2): `threshold = max(1 MiB, last_live_bytes * 2)`. The 1 MiB floor is for tests / cold startup; the doubling rule keeps growth amortised once a REPL or batch process has a live-set baseline (avoids the "first def triggers a full GC mid-load on a 4 MiB Clojure source" failure mode the concern flagged). Env-overridable for tests. Explicit `(System/gc)` Tier A in Phase 7 calls the same entry point.

Concurrency: Phase 5 ships single-threaded (the `Runtime.io` defaults to the `io_default` single-thread accessor per Block A). The collector takes no mutex because there is no concurrent mutator. Phase 15 STM activation revisits this; the GC mutex hook lives behind `Runtime.gc_mutex: std.Io.Mutex = .init` (declared but not consulted at Phase 5).

### 2. 3-layer allocator boundary

Per F-006 + ADR-0017, three distinct allocators with non-overlapping lifetimes:

| Layer        | Allocator                 | Lifetime           | What lives here                                                                                                                                   |
|--------------|---------------------------|--------------------|---------------------------------------------------------------------------------------------------------------------------------------------------|
| 1 (longest)  | `infra_alloc` = GPA       | Process            | `Runtime` itself, `Namespace`, `Var`, `TypeDescriptor` (incl. `method_table` slice), interned `keyword` table                                     |
| 2 (middle)   | `node_arena` = Arena      | Per-program / eval | Reader `Form` tree, Analyzer `Node` tree, per-eval scratch buffers                                                                                |
| 3 (shortest) | `gc_alloc` = GcHeap.alloc | Value-collected    | All Heap Values (`string` payload, `vector` HAMT nodes, `hash_map` nodes, `lazy_seq` cells, `big_int` wrappers, `TypedInstance.field_values`, …) |

Pointer ownership rule (per F-006): a Value field that **owns** another Value is `gc_alloc`. A Value field that **borrows** structurally-shared infrastructure is `infra_alloc`. Crossing the boundary requires an explicit copy-to-`node_arena` at the hand-off (cw v0 D100 fix (1) — `valueToForm` copies GC-allocated string data into `node_arena` before returning).

`TypeDescriptor` itself is **`infra_alloc`** (namespace-lifetime — survives every GC); `TypedInstance.field_values: []Value` is **`gc_alloc`** (the slice's backing memory is GC-traced, and each element is a Value visited by §5 trace). This split satisfies audit bullet #3.

**Block B reconciliation** (per Devil's-advocate Alt 2 item 4): Block B's cw v0 comment reads "GPA: infrastructure (never collected)". The "never collected" predicate applies to the **allocator state** (no mark-sweep over `infra_alloc` itself; cw v0's GC heap does not trace into GPA-owned memory). It does **not** forbid individual allocations on `infra_alloc` from being freed — explicit `infra_alloc.free(...)` from a per-tag finaliser (§4) is the normal lifetime-end path for the `std.math.big.int.Managed` limbs that F-005 places on `infra_alloc`. Without this clarification, a 5.3 GC implementation owner reading Block B in isolation may infer that finalisers cannot free.

### 3. Free-pool recycling (inherited from cw v0; offset-8 overlay)

After sweep, dead objects are not immediately returned to the GPA. They are pushed onto per-(size, alignment) intrusive linked lists kept on `GcHeap`:

```zig
const FreeNode = struct { next: ?*FreeNode };
const FreePoolKey = struct { size: usize, alignment: u8 };
free_pools: std.AutoHashMapUnmanaged(FreePoolKey, ?*FreeNode) = .empty,
```

On the next `alloc(size, align)` call, the heap pops the matching pool's head in O(1) before falling back to `infra_alloc.rawAlloc`. cw v0's measured impact is the textbook (Block C, verbatim):

```
// Impact: gc_stress 324ms -> 46ms (7x), nested_update 124ms -> 41ms (3x).
```

**DIVERGENCE from cw v0** (per F-002 + ADR-0009): cw v0 overlays `FreeNode` at offset 0 of the freed payload (`gc.zig:158-162`), clobbering the `HeapHeader`. cw v1's `HeapHeader` is **invariantly at offset 0** (ADR-0009 mandate; the GC mark phase reads the header to decide tracing). The overlay slot therefore moves to **offset 8** (immediately after the 8-byte header):

```zig
// Layout when an object is on a free pool:
//   bytes [0..7]   : HeapHeader (preserved; gc_mark cleared by sweep)
//   bytes [8..15]  : FreeNode { next: ?*FreeNode }  -- overlaid in payload
//   bytes [16..]   : remainder of original payload (uninitialised garbage)
//
// Constraint: freed block payload >= @sizeOf(FreeNode) = 8 bytes.
//             Heap allocations are min-16 bytes (header + 8) to satisfy this.
```

The 16-byte minimum is enforced in `gc_alloc.alloc`: requests below 16 bytes round up. Header preservation lets a future `(System/identityHashCode)` Tier B reuse the header even after free-and-realloc.

### 4. Per-Tag dispatch infrastructure (descriptor + trace + finaliser)

Per Devil's-advocate Alt 1 + cross-coupling §"Triple Tag-indexed table" consolidation: three comptime tables, each `[64]?*const X` indexed by `@intFromEnum(Tag)`, live together in `runtime/gc/tag_ops.zig` (alternative shape: a single `TagOps = struct { descriptor: ?*const TypeDescriptor, trace: ?*const TraceFn, finaliser: ?*const FinaliserFn }` — choice of "three parallel arrays" vs "single struct-of-arrays" deferred to §9.7 row 5.3 owner per F-003; both index by Tag, both are constant-time, both build at comptime).

```zig
// Descriptor table — read by 5.11 TypeDescriptor activation + class-of dispatch.
pub const tag_descriptor_table: [64]?*const TypeDescriptor = blk: {
    var t: [64]?*const TypeDescriptor = @splat(null);
    t[@intFromEnum(Tag.string)]  = &native_descriptors.string;
    t[@intFromEnum(Tag.vector)]  = &native_descriptors.vector;
    // ... one entry per primitive-mapped Tag (5.11 fills)
    break :blk t;
};

// Trace table — called from mark phase, walks outgoing GC-managed pointers.
pub const tag_trace_table: [64]*const fn (gc: *GcHeap, header: *HeapHeader) void = ...;

// Finaliser table — called from sweep before unlink + free-pool push.
pub const tag_finaliser_table: [64]?*const fn (header: *HeapHeader) void = ...;
```

cw v0's class-of is a string switch (`predicates.zig:387-390`) — cw v1 replaces it with constant-time `tag_descriptor_table[@intFromEnum(value.tag())]` per F-004 + ADR-0007.

**Tags that need a finaliser today (Phase 5 + foresight)**:

- `big_int` / `ratio` / `big_decimal`: free `std.math.big.int.Managed` limbs back to `infra_alloc` (the limbs live on GPA per F-005's stdlib-affine internals; the Block B reconciliation in §2 documents that this `infra_alloc.free` is the normal path, not a violation of "never collected").
- `wasm_module` / `wasm_fn`: drop zwasm v2 `Module` / `FuncEntity` references (Phase 16 entry wires the bodies; the slot stays declared and the table entry stays `null` until then — see "Sweep ordering invariant" below for the contract Phase 16 entry must honour before any allocation lands).
- `ex_info`: arena message-buffer release — only if the message string lives outside `gc_alloc`; current Phase 3 shipping path keeps it in arena so no finaliser entry.
- `host_instance`: dispatches through `TypeDescriptor.finaliser` (the descriptor knows the host class's deinit shape per ADR-0011).

**Sweep ordering invariant**: sweep calls `tag_finaliser_table[tag](header)` **before** unlinking from the live list and **before** pushing onto the matching free pool. Finalisers are **no-alloc** — they may only `infra_alloc.free` / external deinit / no-op; allocation through `gc_alloc` from inside a finaliser is a Phase-5-enforced panic (`std.debug.panic("gc_alloc from finaliser")`). No inter-finaliser ordering guarantee (sweep walks the live list in allocation order; finaliser A's side-effects must not depend on whether finaliser B has run). Per Devil's-advocate Load-bearing concern #1 + Alt 2 item 3.

**Phase 16 entry contract** (per Devil's-advocate Load-bearing concern #6): when Phase 16 lands the first `wasm_module` allocation, the `tag_finaliser_table[wasm_module]` entry **must be set first** — the order is (i) finaliser body lands, (ii) table entry flips from `null` to the deinit fn, (iii) first allocation. The `null`-during-Phase-5 stub is guarded by the access pattern (`if (tag_finaliser_table[tag]) |f| f(header);`) so a missed step at Phase 16 entry causes a silent leak, not a crash — the contract above prevents the leak.

**DIVERGENCE from cw v0** (per F-002 + F-005): cw v0 has no finaliser dispatch (`gc.zig:1125-1129` just `markPtr(bi)`); BigInt limbs sit on the GC heap and get reclaimed only when the next sweep visits them, with no explicit `deinit` call. The fragility shows up when the limbs migrate to a different allocator (e.g. Ratio's two BigInts). cw v1's finaliser table is the day-1 plug for the gap.

### 5. Per-tag GC-trace dispatch (root set + transitive trace)

The trace table from §4 (`tag_trace_table: [64]*const fn (gc: *GcHeap, header: *HeapHeader) void`) is consulted by the mark phase. Each entry walks the type-specific outgoing pointers and calls `gc.mark(child)` on each.

**Mark cycle invariant** (per Devil's-advocate Load-bearing concern #3): `gc.mark(child)` checks `child.header.gc_and_lock.mark == 1` before descending; the mark bit doubles as the visited-flag during the mark phase. Cycles (e.g. `LazySeq` whose `thunk` captures another `LazySeq` whose `seq_cache` points back) terminate at the second visit.

**Root sources + tag-trace entries** (mark phase consumes both; entries are tagged with their **shape**: `E` = entry-point root walker, `T` = per-Tag trace entry registered into `tag_ops.tag_trace_table` from the owning module, `D` = documentary / closed-by-construction / no GC edge ever). See amendment 1 below for the demotion rationale.

| #  | Source                                                                      | Shape | Reason                                                                                                                                                                                                   |
|----|-----------------------------------------------------------------------------|-------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1  | `Runtime.envs.entries` — all Namespace `Var` roots                         | E     | Vars are rooted **at `def` time**; `ns-unmap` (Phase 7+) removes the root atomically                                                                                                                     |
| 2  | `Env.current_frame` — dynamic binding stack (`env.zig` threadlocal)        | E     | `binding` form Values must survive across `*pushFrame*` boundaries                                                                                                                                       |
| 3  | `Fn.closure_bindings` on every live `fn_val`                                | T     | Not a root — Fn objects become reachable via Var (source #1) graph. `tag_trace_table[.fn_val]` registered from `tree_walk.zig` walks `closure_bindings`. cw v0 D100 #5 closed by transitive trace.      |
| 4  | `LazySeq.thunk` + `LazySeq.ctx` + `LazySeq.seq_cache`                       | T     | Not a root — LazySeq reachable via Var graph. `tag_trace_table[.lazy_seq]` registered at 5.7 alongside `force()`. cw v0 D100 #5 closed by transitive trace.                                             |
| 5  | `ProtocolFn` / `MultiFn` inline caches (`cached_type_key`, `cached_method`) | D     | **No live structs in cw v1** (zero grep hits). Phase 7 entry creates them; the cache state will live on `CallSite` (row 9), not embedded in the protocol fn (cw v1 splits per ADR-0008).                 |
| 6  | `refer()` borrowed symbol-name pointers → owned slice on `infra_alloc`     | D     | **Closed at construction**: `env.zig:229 referAll` already dupes the key onto `self.alloc` (= `rt.gpa`). cw v0's late-patch is unnecessary in cw v1. Var pointer rooted via source #1's `mappings`.      |
| 7  | Macro-expansion scratch: `macro_root_slot`                                  | E     | cw v0 D100 #6 — `threadlocal var macro_root_slot: ?Value` declared in `runtime/gc/root_set.zig` (Layer 0); analyzer/macro_dispatch sets/clears via downward import. Refuses cw v0 `suppressCollection`. |
| 8  | `TypedInstance.field_values` (transitively from descriptor reachability)    | T     | Not a root — TypedInstance reachable via Var graph. `tag_trace_table[.typed_instance]` registered at 5.11 alongside `lookupMethod`. Audit bullet #3 transitive trace.                                   |
| 9  | `CallSite.last_method`                                                      | D     | Cache slots point at **namespace-owned** TypeDescriptor + MethodEntry (process-lifetime, not GC-managed). **No GC edge ever** — cw v1 splits the cache off the protocol fn so it carries no Value.      |
| 10 | `GcHeap.permanent_roots: std.ArrayList(Value)`                              | E     | Escape valve for embedder-pinned Values (FFI / test fixtures / future REPL prompt buffer). `GcHeap.pin`/`unpin` API.                                                                                     |

**Live entry-point walkers (E)**: 4 — rows 1, 2, 7, 10.
**Tag-trace entries (T)**: 3 — rows 3, 4, 8 (registered into `tag_trace_table` from owning module).
**Documentary (D)**: 3 — rows 5, 6, 9 (no walker body, no trace entry; preserved as design invariants).

> **Amendment 2 (2026-06-05, Phase B #3b — ADR-0091).** Rows 2
> (`current_frame`) + 7 (`macro_root_slot`) are **subsumed into a single
> `thread_roots` E-source** that walks, per live thread (self + every
> registered worker `ThreadGcContext`), its binding-frame chain + macro slot
> + **VM operand-stack frame chain** (`vm.eval`'s `stack[0..sp]` + `locals`,
> newly rooted for Phase B real threads, #3b-step1) + an **in-flight
> fabrication self-guard** (`gc_self_guard`, #3b-step2b — the
> `op_vector/map/set_literal` accumulator window). Live E-walkers 4 → 3 (rows 1, the
> `thread_roots` union, 10); the `RootSource` Zig enum count 10 → 9. The
> per-thread union-addressing (`frameSourceAt`/`macroSourceAt` + the `src_idx`
> cursors from amendment-era #3a) is commonized into one `threadContextAt`
> helper + one thread-major cursor. Rationale + the Devil's-advocate fork
> (Option A fold rejected; Alt 1 clean-11th-source vs Alt 2 union vs Alt 3
> thread-driven spine) live in **ADR-0091**. See the Revision history entry
> below.

Per Devil's-advocate Alt 2 item 2: Var rooting is committed to "at `def` time" (cw v0's `permanent_roots` escape valve at row 10 was a late-answer workaround; cw v1 commits the timing in row 1). Per Load-bearing concern #4: `refer()` owned-slice lives on `infra_alloc` (per-namespace lifetime; explicit ownership stated). Per Load-bearing concern #5: row 9 demoted to D (no GC edge ever) so the "reserved as `null`" framing is dropped entirely — the cache holds no GC-managed pointers in any Phase.

**Macro-expansion root slot** (refuses the cw v0 suppress escape hatch): `Analyzer.macro_root_slot: ?Value` is set before `callFnVal` for macro expansion, cleared after `valueToForm` completes. The mark phase walks it like any other root. This satisfies F-006's "5 root-set gaps must be pre-enumerated" requirement for cases (5) and (6) — the two cw v0 patched with `suppressCollection`.

### 6. Header bit layout (`HeapHeader.gc_and_lock` 30 spare bits)

`gc_and_lock: packed struct(u32) { lock_state: u2, gc_mark: u30 }` (ADR-0009).
Per Devil's-advocate Alt 1: this ADR commits **only** the bits the Phase-5 mark phase consumes; the partition of the remaining 28 bits is **deferred to §9.7 row 5.3 GC implementation owner** per F-003 decision-deferral (the size-class distribution that drives the split needs measurement on real Clojure workloads — 5.3 owner has the bench harness; 5.1 ADR draft does not).

| Bit range | Field              | Purpose                                                                                                                                                                                                                                                                      |
|-----------|--------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 0         | `mark`             | Set during mark phase, cleared during sweep; doubles as cycle-visited flag (per §5 invariant)                                                                                                                                                                               |
| 1         | tri-colour reserve | Declared, unused at Phase 5; reserved for Phase 7+ incremental-GC upgrade candidate                                                                                                                                                                                          |
| 2..29     | owned by 5.3       | **Partition deferred to §9.7 row 5.3 owner per F-003**; expected use = `size_class` field for free-pool key collapse (see §3) + future generational tag / weak-ref bit / allocation timestamp; the exact width is row 5.3's call based on measured size-class distribution |

The free-pool key collapse from `(size, alignment)` to a single header-resident `size_class` index (which lets `free_pools` shrink from `HashMap<FreePoolKey, ?*FreeNode>` to `[N]?*FreeNode` flat array) is the **expected** consumer of bits 2..N — the row 5.3 owner picks N (Devil's-advocate Alt 3 wildcard sketch suggests 5 bits = 32 classes; the draft does not commit to it). The wildcard's quantisation-vs-exact tradeoff is row 5.3 owner's measurement.

**DIVERGENCE from cw v0** (per F-006 inheritance language): cw v0 has no header bits at all — marks live in an external hash-map (`gc.zig:181-185`). cw v1's inline layout removes the hash-lookup per access. Audit bullet #5 is satisfied "in spirit" (the choice exists in writing — mark bit + cycle invariant + free-pool collapse target) but the exact partition for bits 2..29 lives with row 5.3.

### 7. zwasm v2 allocator-injection seam (foresight, F-001 + F-008)

`Runtime.gc.allocator()` exposes the cw GC as a `std.mem.Allocator` that satisfies the zwasm v2 §1 strict-pass: `zwasm.Engine.init(rt.gc.allocator(), .{})`. zwasm metadata (Module / FuncEntity / Instance state) is then allocated through the same heap as cw Values, eliminating cw v0's D110 "dual-GC lifecycle mismatch". `wasm_module` / `wasm_fn` Tag-D slots' finalisers (table from §4) drop the zwasm reference; the per-allocation GPA underneath is the same for both.

Phase 5 wires the seam at declaration only (the `gc.allocator()` method exists; no consumer yet). Phase 16 entry consumes it per F-008 + D-036.

### 8. Activation scope (Phase 5 source rewrite)

Per ADR-0017 amendment 1 + ADR-0009 amendment 2 the Phase 5 activation rewrites every Phase 1-4 heap allocation site:

- `runtime/value.zig` (and the post-5.2 `runtime/value/` split) — every `HeapHeader.init` call site routes through `gc_alloc` instead of `gpa.allocator()`. ~20 grep sites today.
- `runtime/collection/{string, list, ex_info}.zig` — `gpa.create(T)` → `gc.alloc(T)`; `gpa.dupe(u8, …)` → `gc.dupe(u8, …)`. ex_info message string stays in arena per ADR-0017 amendment 1 explicit carve-out.
- `runtime/lazy_seq.zig` (today's 4.24 skeleton) — `LazySeq` struct + thunk closure allocation routes through `gc.alloc` at 5.7.
- `runtime/numeric/big_int.zig` — wrapper allocation through `gc.alloc`; `std.math.big.int.Managed` continues to take `infra_alloc` per F-005 (the wrapper carries `infra_alloc` as the limbs' allocator; the finaliser releases through the same).
- `Catalog Codes removed by §9.7 row 5.15`: ADR-0017 amendment 1's `gc_*_not_supported` family + ADR-0009 amendment 2's `locking_*_not_supported` are removed at the `build_options.phase_at_least_5 = true` flip. The `locking_*` family stays — only the `gc_*` Codes go (lock_state activation is Phase 15 per ADR-0009).

The rewrite is expected per ROADMAP §A25 + F-002. Depth 3 (cross-file refactor of alloc call sites) is typical; depth 4 only if the per-eval arena / GcHeap boundary itself needs an ADR revision.

### 9. What this ADR does NOT decide

- Tag enumeration / slot map — owned by ADR-0027 (paired).
- LazySeq `force()` mutex shape — deferred to §9.7 row 5.7 per audit bullet #2.
- Generational GC — F-006 explicit deferral; ROADMAP §89.2.
- Lock state activation (`gc_and_lock.lock_state`) — Phase 15 per ADR-0009.
- D-040 `MethodEntry` rename — Phase 7 per debt row.
- Phase 16 inline-vs-Pod choice for `wasm_funcref` / `wasm_externref` — D-036; the finaliser table reserves D4-D7 with `null` until then.

## Inputs from 5.0 audit

Bullets #1 / #3 / #5 / #6 from `private/notes/phase5-skeleton-audit.md` §"5.1 input bullets" bind this ADR. Quoted verbatim (paraphrase-loss protection per ADR-0026 §3):

> 1. GC root-set must enumerate `LazySeq.thunk` + `LazySeq.ctx` + `LazySeq.seq_cache`. Today the skeleton uses `std.atomic.Value(?*SeqOpaque)` (anyopaque) for the cache — the GC marker cannot blindly trace an opaque pointer, so the mark path will need either (a) a tag-bit on the cache slot saying "this is a Seq*", or (b) a per-LazySeq sub-tag stored on the header. cw v0's F-006 "macro-expansion-time lazy-seq realisation paths" gap is exactly this. The ADR-0028 root-source list must name `LazySeq` explicitly.
> 3. TypeDescriptor's `method_table: []const MethodEntry` slice must land in a GC-aware allocator, because the namespace owning it is itself process-lifetime (`infra_alloc` per F-006). Slot placement decision: the descriptor itself is namespace-owned (not GC-managed), but a `TypedInstance.field_values: []Value` slice IS GC-managed (mark walks the slice). The GC ADR must distinguish "TypeDescriptor live forever" vs "TypedInstance is a GC root entry-point through its descriptor pointer".
> 5. `HeapHeader.gc_and_lock.gc_mark: u30` is 30 bits today. F-006 commits to single-generation mark-sweep; 30 bits is overkill for a one-bit mark (29 spare). The ADR-0028 mark phase needs at most 1 bit (or 2 for tri-colour); the remaining bits are a free-pool size-class hint candidate per cw v0's free-pool optimisation. 5.1 should record the choice of "what the other 29 bits carry" so 5.3 (GC impl) doesn't re-decide it under task pressure.
> 6. `HeapHeader` is 8 bytes today (tag + flags + pad + gc_and_lock). F-006 free-pool needs a `next: ?*HeapHeader` link somewhere when an object sits on the free list — either inside the freed object's payload (cw v0 path) or a separate per-size-class chain. 5.1 should at least note which the ADR-0028 commits to.

Bullet #1 → §5 row 4 (LazySeq enumerated explicitly; the `seq_cache: std.atomic.Value(?*SeqOpaque)` tracing question resolves as "the cache slot's pointer is a `*Cons` post-realisation; per-LazySeq sub-tag stored on the cell at allocation lets the trace walk follow it"; 5.7 owner finalises the encoding).
Bullet #3 → §2 (`TypeDescriptor = infra_alloc`; `TypedInstance.field_values = gc_alloc`).
Bullet #5 → §6 (1 bit mark + 1 bit tri-colour reserve + 5 bit size_class + 23 bit reserved).
Bullet #6 → §3 (intrusive at offset 8, after header; 16-byte minimum allocation).

## Verbatim cw v0 reference (paraphrase-loss protection)

### Block A — `io_default.zig:9-21` rationale (the Zig-0.16 `std.Io.Mutex` constraint used in §1 + bullet #2 deferral)

```
//! Process-wide default `std.Io` accessor.
//!
//! Zig 0.16 removed `std.Thread.Mutex` and friends; the replacement
//! `std.Io.Mutex` requires an `io` argument for lock/unlock. CW carries
//! many module-level mutexes (interned keywords, hooks, namespaces, etc.)
//! that don't have access to an `init.io` value at the call site.
//!
//! This module exposes a single shared `std.Io` that defaults to a
//! single-threaded io suitable for tests and pre-init code paths.
//! Production entry points (main, cache_gen) call `set(init.io)` early
//! to upgrade the shared io to the real cancelable one used by
//! `thread_pool.zig`. After that, every mutex picks up the production io.
```

cw v1 adopts the same `io_default` shape when row 5.7 picks `std.Io.Mutex` for `LazySeq.force()`. Recorded here so §9.7 row 5.7 owner does not re-derive.

### Block B — `gc.zig:153-156` 3-allocator comment (the textbook reference for §2)

```
/// Three-allocator architecture (D69-D70):
///   - GPA: infrastructure (never collected)
///   - node_arena: AST nodes (freed per-eval)
///   - GC allocator (this): runtime Values (mark-sweep collected)
```

cw v1 names the layers `infra_alloc` / `node_arena` / `gc_alloc` (§2) — semantics match cw v0 exactly.

### Block C — `gc.zig:158-162, 208-219` FreeNode + measured impact (§3)

```
/// Free-list node — overlaid directly on freed allocation memory.
/// The freed block must be >= @sizeOf(FreeNode) to be recyclable.
const FreeNode = struct {
    next: ?*FreeNode,
};

// --- Free-pool recycling ---
// Dead allocations from sweep are not immediately freed back to the OS.
// Instead, they are cached in per-(size, alignment) free pools. On the
// next allocation of the same size, the pool provides a recycled block
// in O(1) — a simple linked-list pop. This avoids the full GPA
// rawAlloc/rawFree overhead (which includes page-level bookkeeping).
//
// The FreeNode struct is overlaid directly on the freed memory (intrusive
// linked list), so no extra allocation is needed to track free blocks.
//
// Impact: gc_stress 324ms -> 46ms (7x), nested_update 124ms -> 41ms (3x).
```

cw v1 lifts the data structure and the perf rationale; the **DIVERGENCE** (§3) is the offset-8 placement so the header stays intact.

## Alternatives considered

A fresh-context `general-purpose` subagent was forked as Devil's advocate per CLAUDE.md § "ADR-level designs are handled inline" (depth ≥ 2 mandate). Brief: F-001..F-008 envelope; produce 3 alternative shapes (smallest-diff / finished-form-clean / wildcard) per ADR; do not propose F-NNN-violating alternatives. Full output at `private/notes/phase5-5.1-devils-advocate.md` (~440 lines). The ADR-0028 portion is reflected here verbatim.

### Would-violate-F-NNN findings

**None.** All three ADR-0028 alternatives stay within F-001 / F-005 / F-006 / F-008.

### Subagent summary judgement (ADR-0028 portion, verbatim)

> ADR-0028 (mark-sweep GC + 3-layer allocator) — substantively correct on the big shape (mark-sweep, three layers, offset-8 free node, per-tag finaliser, root-set enumeration). But it has the **most concentrated reservation-as-bias smell in the entire pair** at §6 (23 reserved bits in `gc_mark`), and one **load-bearing omission** at §5 row 1 (`Runtime.envs.entries` Var roots): Vars hold root Values, but the ADR does not name whether a freshly def'd Var that is *not yet referenced* is reachable from the namespace map — cw v0's `permanent_roots` workaround exists precisely because this question was answered late.

### Alt 1 — Smallest-diff (verbatim)

> **Sketch**: Land mark-sweep, 3-layer alloc, root-set table, finaliser table, offset-8 overlay — but **defer the §6 bit allocation past bit 0 (mark) to the 5.3 GC implementation owner**. Specifically, §6 in this ADR commits to: bit 0 = mark (used); bit 1 = tri-colour reserve (declared, unused at Phase 5); bits 2–29 = "owned by 5.3, decided when allocator + free-pool body lands".
>
> Same approach the ADR already takes for "LazySeq `force()` mutex shape — deferred to §9.7 row 5.7 per audit bullet #2". The bit-2..29 split is exactly the same kind of decision: it depends on the free-pool's measured size-class distribution, which is *5.3 owner's measurement to make*. Audit bullet #5 says "5.1 should record the choice of 'what the other 29 bits carry' so 5.3 doesn't re-decide it under task pressure" — but the *finished* free-pool may want a different split (e.g., 8-bit size_class + 22 reserved if Phase 7 transducers spawn many distinct sizes). Reserve the bits in the ADR text (don't burn them on a guess); 5.3 lands the split.
>
> **Better than current draft**: Removes the **23 reserved bits** smell at §6 (the largest Reservation-as-bias surface in either ADR). Aligns with F-003 (decision-deferral on structural plans). Removes the dual "finaliser table commits to N entries" / "size_class is 5-bit" double-binding.
>
> **Breaks**: Audit bullet #5 ("5.1 should record the choice") is partially un-satisfied — record only "1-bit mark + 1-bit tri-colour reserve; 28 bits available, partitioned at 5.3". The bullet is satisfied in spirit (the choice exists in writing) but not in letter. Acceptable per F-003.
>
> **Cost**: tiny.

### Alt 2 — Finished-form-clean (verbatim)

> **Sketch**: Alt 1 plus:
>
> 1. **Split ADR-0028 into ADR-0028a (mark-sweep GC body) and ADR-0028b (3-layer allocator boundary).** ADR-0020 governance says "one ADR, one load-bearing decision". 0028 has *two*: (a) mark-sweep + free-pool inherited and (b) 3-layer alloc boundary with TypeDescriptor on infra and TypedInstance on gc. These are independently amendable.
> 2. **Name the `Runtime.envs.entries` Var-root question explicitly.** §5 row 1 says "Var deref is the primary Value entry; ns survives forever" — but does *defining* a Var promote its initial Value to a root, or only does *deref* through the namespace map? cw v0's `permanent_roots` escape valve exists because cw v0 answered this late. cw v1 should commit: "Vars are rooted at `def` time; un-interning a Var (Phase 7+ `ns-unmap`) removes the root atomically."
> 3. **Add finaliser-ordering rule.** §5 sweep description says "call the per-tag finaliser, unlink from the live list, push onto the matching free pool". What if the finaliser *itself* allocates (e.g., logs the deinit somewhere)? The ADR should commit: "finalisers are no-alloc — they may only `infra_alloc.free` or no-op; allocation through `gc_alloc` from a finaliser is a Phase-5-enforced panic."
> 4. **Reconcile Block B contradiction.** Block B (cw v0 comment) says "GPA: infrastructure (never collected)" but cw v1 §4 finaliser releases `Managed` limbs back to `infra_alloc`. The ADR should write one sentence: "Block B's 'never collected' applies to the infra_alloc *as an allocator state* (no mark-sweep over it), not to individual allocations made on it; explicit `infra_alloc.free` from a finaliser is the normal path."
>
> **Better than current draft**: Each split ADR is amendable independently. The Var-root and finaliser-ordering rules close two of the cw v0 D100 gaps that F-006 names. Block B is no longer a contradiction the next session has to re-resolve.
>
> **Breaks**: More ADR numbers. The "paired ADR" framing with 0027 becomes a triplet. ADR-0029 was reserved for `runtime/value/` split aliasing.
>
> **Cost**: medium.

### Alt 3 — Wildcard (verbatim, abridged)

> **Sketch**: **Drop the per-(size, alignment) free-pool and use a single per-size-class freelist with the size_class stored on the header (already in §6).** Quantise allocation sizes to 32 size classes (powers-of-two from 16 to 4 KiB, then large), store the class on the header, and the free pools become `[32]?*FreeNode` — a flat array, no hash lookup at all.
>
> **Why within F-NNN envelope**: F-006 says "intrusive linked list per (size, alignment) free pool" — but the (size, alignment) wording was the cw v0 inheritance language. The *finished form* on cw v1 has fixed alignment, so the free-pool's (size, alignment) shape over-keys.
>
> **Better than current draft**: alloc fast-path becomes `pool[class].pop() orelse fallback()` — no hash compute, no key allocation. 23 reserved bits at §6 shrink to ~18.
>
> **Breaks**: Quantisation wastes memory for in-between sizes (estimate: 5-15 %). "32 size classes" is a magic number. Need a benchmark.
>
> **Cost**: medium.

### Load-bearing concerns the ADR omits (verbatim)

> 1. Sweep ordering vs finaliser side-effects. If finaliser A causes finaliser B to need re-running, sweep diverges. Commit "finalisers are independent; no inter-finaliser ordering guarantee".
> 2. Trigger threshold tuning. §1 says "default 1 MiB, env-overridable for tests". 1 MiB is fine for tests; for a REPL session loading a 4 MiB Clojure source, the first def triggers a full GC mid-load. Either name a higher default or commit to "adaptive: trigger = max(1 MiB, last_live_bytes * 2)".
> 3. Cycle handling for `LazySeq.seq_cache`. The ADR should commit: "mark recursion checks `header.gc_mark == 1` before descending; the bit doubles as visited-flag during mark phase." This is implied but not stated.
> 4. `refer()` borrowed string pointers — "move to owned-slice (no longer GC-traced) at refer time" says the data shape changes at refer time. Who owns the new slice? `infra_alloc` is the natural choice but not stated.
> 5. The §5 row 9 `CallSite.last_method` reservation. F-003 says reservations on structural plans defer to the owning Phase. Either move row 9 to a "Phase 7 adds these roots" note, or commit to "the slot is reserved as `null` until 5.x activates" — don't leave it ambiguous.
> 6. §4 finaliser for `wasm_module` / `wasm_fn` — text says "the slot is declared and the table entry stays `null` until then [Phase 16]". But F-001 says zwasm v2's `Engine` accepts the cw GC allocator at init; if zwasm v2 metadata is allocated through `gc_alloc`, the *finaliser* must release the zwasm Module *before* the underlying memory is recycled. Commit: "Phase 16 entry MUST land the finaliser before the first `wasm_module` allocation".

### Main loop disposition

Devil's-advocate Alt 1 **applied**: §6 bit allocation deferred — only mark bit + tri-colour reserve committed; bits 2..29 partition is row 5.3 owner's call per F-003. Removes the 23-reserved-bits Reservation-as-bias smell (the largest in the pair).

Alt 2 item 1 (ADR split into 0028a / 0028b) **not applied**: the two decisions are tightly coupled at the per-tag dispatch level (§4 consolidates descriptor + trace + finaliser tables, all indexed by Tag; the dispatch tables live inside the GC body and the allocator boundary). Splitting would force `tag_ops.zig` to live in one ADR while its consumer lives in another. Recorded as a future-supersession candidate for `D-043`-style debt if a future amendment touches only one of the two halves; for now the coupling argues for the single ADR.

Alt 2 item 2 **applied**: §5 row 1 commits "Vars are rooted at `def` time; `ns-unmap` (Phase 7+) removes the root atomically".

Alt 2 item 3 **applied**: §4 commits the no-alloc finaliser invariant + the panic-on-violation rule + no-inter-finaliser-ordering guarantee.

Alt 2 item 4 (Block B reconciliation) **applied**: §2 carries the one-sentence reconciliation paragraph distinguishing allocator-state from individual-allocation lifetimes.

Alt 3 (wildcard size-class quantisation) **not applied at Phase 5 entry** — the wildcard becomes row 5.3 owner's measurement-driven choice within the F-NNN envelope (§6's "expected use = size_class field for free-pool key collapse" reserves the design space without committing the quantisation). Recorded for 5.3 owner as the strongest candidate.

Load-bearing concerns #1 (sweep / finaliser ordering) **applied** at §4 Sweep ordering invariant; #2 (trigger threshold tuning) **applied** at §1 (adaptive threshold formula committed); #3 (cycle handling) **applied** at §5 Mark cycle invariant; #4 (`refer()` ownership) **applied** at §5 row 6 (owned slice on `infra_alloc`); #5 (row 9 ambiguity) **applied** at §5 row 9 (explicit `null` reserve); #6 (Phase 16 wasm_module finaliser ordering) **applied** at §4 Phase 16 entry contract.

Per Devil's-advocate cross-coupling §"Triple Tag-indexed table" + ADR-0027 §3 consolidation: **§4 absorbs `tag_descriptor_table`** (moved out of ADR-0027 §3); three tables co-locate as `tag_descriptor_table` + `tag_trace_table` + `tag_finaliser_table`, with `TagOps` struct-of-arrays as an explicit row 5.3 owner's alternative.

### Amendment 3 (2026-07-02) — explicit gray worklist for the mark phase

A fresh-context Devil's-advocate subagent was forked per the depth ≥ 2
mandate. Bug: the original recursive `mark()` (mark → trace_fn → mark per
child) overflowed the native stack on a ≥~400k-deep cons chain
(`(count (repeat 1000000 1))` SIGSEGV during a mid-walk collect; verified
by `CLJW_GC_THRESHOLD_MB=4096` making the same expr return 1000000). The
draft fix was: on-GcHeap `mark_worklist` gray stack, bit-set-then-push,
auto-drain guarded by a `mark_draining: bool`, degrade-to-recursion on
append OOM. The DA's findings (reflected near-verbatim):

**Would-violate-F-NNN findings: none.** F-006 commits to mark-sweep /
single generation / 3-layer allocator and says nothing about mark-phase
traversal mechanics. No alternative touches F-004 / F-005 / the ADR-0009
8-byte-header invariant.

**Verification of the draft's concerns**: (1) traversal-order change has
no observers — sweep walks `allocations` in allocation order;
`persistent_marks` bits are cleared before marking and re-shaded on
reach; gc_torture asserts deterministic UAF surfacing, not mark order;
and no registered trace fn recurses internally (all ~35 route descent
through `mark`), so the conversion fixes deep cons chains, RB trees, and
HAMT spines uniformly with trace fns byte-for-byte unchanged.
(2) The draft's OOM-fallback was its one unsound joint: infra-append OOM
correlates with a large heap, which is where the deep chain lives, so
the fallback reintroduces unbounded recursion exactly under memory
pressure — and because the bit is set at push time each object is pushed
at most once, so `allocations + persistent_marks` bounds the worklist
and a single `ensureTotalCapacity` in `collect()` deletes the OOM branch
entirely. (3) The `mark_draining` bool is race-free under the
`gc_mutex`-serialized STW collect but is a hidden control-flow
inversion. (4) An intrusive gray-list through `HeapHeader` was
investigated and rejected: a link needs 8 bytes, the header is locked at
8 bytes by ADR-0009 (offset-8 FreeNode overlay + 16-byte minimum
allocation key on it), and growing every live object permanently to
optimize a transient mark structure contradicts the side-table
precedent recorded on `GcHeap`. Pointer-reversal (Deutsch-Schorr-Waite)
also rejected: it needs per-tag knowledge of which field is mid-traversal,
incompatible with the opaque `tag_trace_table` fn-pointer design.

**Alt 1 — smallest-diff**: the draft + guaranteed-capacity worklist
(reserve in `collect()`, delete the OOM fallback, keep auto-drain).
Better: removes the only unsound path; mark itself never allocates.
Breaks: the reserve can OOM — but before any bit is set, where aborting
the collect is a safe degradation (heap intact; pressure resurfaces at
the next `gc.alloc`).

**Alt 2 — finished-form-clean (ADOPTED)**: Alt 1's capacity guarantee +
drop `mark_draining` entirely; `mark()` is push-only (shade gray) and
`collect()` gains one explicit `drainGray()` (blacken) after all three
root-publication passes (root-set loop, `current_tx`,
`markRegisteredTxs`), before `sweep()`. `collect()` reads as the
textbook tri-color structure — publish roots → drain → sweep — which is
the shape the §6 bit-1 tri-colour reserve and a future incremental /
parallel marker inherit; the draft's auto-drain would have to be undone
by that owner. Cost: direct `mark()` callers relying on transitivity
(two unit tests: `stm/tval.zig` self-loop, the new deep-chain test) add
a `drainGray` call — per F-002 the test edits are not a valid tiebreaker.

**Alt 3 — wildcard**: allocation-free fixed 4096-slot mark stack +
Boehm-style overflow rescan of `allocations` **and `persistent_marks`**
(a rescan that misses waypoints would strand their children — the D-251
class). Zero allocation during collect; attractive for a
memory-budgeted Wasm-edge profile (gap area II). Rejected now: worst
case O(passes × live) on wide structures, more invariants, a magic
constant needing a bench. On record as the edge-profile candidate.

**Applied**: Alt 2, plus the DA's four amendment obligations —
(a) bit-before-push recorded as a LOAD-BEARING invariant in `mark`'s
docstring (push-before-bit would let a failed push leave a
traced-looking-but-untraced object → live child swept → UAF);
(b) `collect()`'s "mark/sweep never allocate" comment rewritten to
"never allocate through `gc.alloc`; worklist capacity reserved up front
on `gc.infra` before any bit is set"; (c) `mark_worklist` freed in
`GcHeap.deinit`; (d) Consequences note added: the worklist is STW-only
state — a future parallel marker (gap area III) replaces it.

## Consequences

- **Positive**: cw v0's `suppressCollection` escape hatch is rejected by enumeration (§5 root row 7). cw v0's silent BigInt limb leak is closed by per-tag finaliser dispatch (§4). cw v0's external mark hash-map is replaced by inline bits (§6) — one less heap-write per object per mark, one less hash-lookup per access. cw v0's free-pool perf inheritance is preserved (Block C) under the offset-8 overlay (§3).
- **Negative**: 16-byte minimum allocation wastes up to 8 bytes per small object (currently only `boolean_true` / `boolean_false` could fit smaller — but those are NaN-box immediates, not heap allocations; the real impact is `cons` cell at ~16 bytes — already at the minimum). Per-tag dispatch tables (§4 finaliser + §5 trace) add 1 KiB ROM (.const data) for the 64 slots × 2 tables × 8-byte function pointers — negligible.
- **Neutral / follow-ups**: §7 zwasm seam is declaration-only at Phase 5; Phase 16 entry consumes per F-008 + D-036. Generational GC stays an open question (D-016) decided by Phase 5 bench results (ROADMAP §10.2 quick bench window).
- **Amendment 3**: mark depth is O(1) native stack regardless of object-graph depth (deep cons chains / RB trees / HAMT spines all mark iteratively). `gc.mark_worklist` retains its high-water capacity across collects (peak 8 bytes per live non-leaf object during a collect; no shrink policy — add one if a one-off huge collect ever matters). The worklist is STW-only state; a future parallel marker (gap area III) replaces it, per the same forward note `fabrication_depth` carries.

## Affected files

- `.dev/decisions/0027_*.md` (paired — see §0).
- `src/runtime/gc/` ★new directory per `.dev/structure_plan.md` (F-006 decree):
  - `mark_sweep.zig` (mark / sweep bodies + `GcHeap` struct)
  - `root_set.zig` (root enumeration table)
  - `free_pool.zig` (per-size-class intrusive list + offset-8 overlay)
  - `arena_node.zig` (Arena allocator factory)
  - `gc_strategy.zig` (vtable for the future Arena ↔ MarkSweep switch per ADR-0023)
- `src/runtime/value.zig` (and post-5.2 `runtime/value/heap_header.zig`) — `HeapHeader.gc_and_lock.gc_mark` bit layout per §6.
- `src/runtime/native_descriptors.zig` (paired with ADR-0027 §3) — gains finaliser hook references for native-class wrappers (BigInt / Ratio / BigDecimal initially).
- `src/runtime/numeric/big_int.zig` (post-5.9) — gains `deinitGc` finaliser; allocator boundary commits to `infra_alloc` for limbs.
- `src/runtime/collection/*.zig` — `gc.alloc` routing in §8.
- `src/eval/analyzer/macro_expand.zig` (post-5.13 split) — `Analyzer.macro_root_slot` set / cleared per §5 row 7.
- `src/runtime/error_catalog.zig` — `gc_*_not_supported` family removed at §9.7 row 5.15 flip.
- Test surface: `test/gc/{mark_sweep_basic,free_pool,finaliser,root_set}.zig` (5.3 task lands), plus rewrites of existing tests that today expect `Code.gc_alloc_not_supported`.

## References

- `.dev/project_facts.md` F-001 (zwasm v2 unavoidable), F-002 (finished form wins), F-003 (decision-deferral), F-005 (numeric tower internal allocator), F-006 (GC strategy + 3-layer alloc + cw v0 D100 5 gaps — decree), F-008 (zwasm v2 allocator strict-pass).
- `.dev/principle.md` § Bad Smell catalogue (Workaround smell — the cw v0 `suppressCollection` rejection in §5).
- `.dev/decisions/0009_object_header_heap_only_lock.md` (HeapHeader.gc_and_lock — §6 owns the 30-bit split).
- `.dev/decisions/0017_allocator_strategy.md` (the 3-layer skeleton — this ADR is the body).
- `.dev/decisions/0023_comptime_stub_pattern.md` (gc_strategy.zig vtable for future Arena/MarkSweep switch).
- `.dev/decisions/0026_phase5_entry_scope.md` (verdict table; this ADR is row 5.1's deliverable).
- `.dev/decisions/0027_nan_box_second_generation.md` (paired — §1 §3 §4 reference its slot map + Tag widths).
- `.dev/structure_plan.md` `runtime/gc/` decreed split (F-006).
- `.dev/debt.md` D-011 (this ADR satisfies), D-020 (header bit helpers — 5.3 lands), D-016 (generational re-eval after bench), D-036 (zwasm Pod-vs-inline — Phase 16).
- `private/notes/phase5-skeleton-audit.md` (5.1 input bullets — quoted above).
- `private/notes/phase5-5.1-survey.md` (cw v0 archaeology — §1-3 DIVERGENCE call-outs).
- `.claude/rules/zig_tips.md` § Mutex (the constraint behind Block A's `io_default` pattern; deferral to row 5.7).

## Revision history

- 2026-07-02 (amendment 3): mark phase converted from recursive per-child descent to an explicit gray worklist (`GcHeap.mark_worklist` + push-only `mark()` + `drainGray()` as a named `collect()` phase between root publication and sweep). Trigger: `(count (repeat 1000000 1))` SIGSEGV — a ≥~400k-deep cons chain overflowed the native stack when a mid-walk collect marked it recursively (confirmed via `CLJW_GC_THRESHOLD_MB` deferral); found by the 2026-07-02 debt/code-truth audit as an unledgered bug. DA fork (Alt 1 capacity-guaranteed auto-drain / Alt 2 explicit-drain tri-color [adopted] / Alt 3 fixed-stack + Boehm overflow-rescan [edge-profile candidate, on record]) reflected into Alternatives considered § Amendment 3. Load-bearing: bit-set-BEFORE-push; `collect()` reserves `allocations + persistent_marks` capacity before any bit is set (failed reserve aborts the collect safely); trace fns unchanged. Smell category: the original recursion was a latent Reservation-as-bias on §5's "recursively traces" wording — depth-unbounded recursion was never a recorded decision, just inherited shape.
- 2026-05-24: Status: Proposed → Accepted (autonomous-loop self-accept after Devil's-advocate subagent review reflected verbatim into Alternatives considered; Alt 1 applied — §6 bit allocation deferred past mark/tri-colour to row 5.3 owner; Alt 2 items 2 / 3 / 4 applied — Var rooting timing + no-alloc finaliser invariant + Block B reconciliation; Load-bearing concerns #1-6 all applied; per-Tag dispatch tables absorbed from ADR-0027 §3 per Alt 1 cross-coupling resolution; Alt 2 item 1 ADR-split not applied — coupling argues for single ADR; Alt 3 wildcard recorded as row 5.3 owner candidate). Co-issued with ADR-0027.
- 2026-06-05 (amendment 2): §5 Root sources table re-tabled for Phase B #3b (D-244) per **ADR-0091**. Rows 2 (`current_frame`) + 7 (`macro_root_slot`) subsumed into a single `thread_roots` E-source (binding-frame chain + macro slot + **VM operand-stack frame chain**, per live thread — self TLS + every registered worker `ThreadGcContext`). The operand stack (`vm.eval` `stack[0..sp]` + `locals`) is newly rooted so a Phase-B worker mid-`eval` does not hold un-rooted Values a concurrent `collect()` would sweep (the ADR-0090 leading-finding UAF). Net: live E-walkers 4 → 3; `RootSource` Zig enum count 10 → 9; the triplicated per-thread union-addressing helpers (`frameSourceAt`/`macroSourceAt` + their `src_idx` cursors) commonized into one `threadContextAt` + one thread-major cursor (F-011). Runtime-inert at land (no live auto-collect; empty registry + null `eval_frame_head` at quiescent collect points = today's roots). The alloc-boundary safepoint that makes auto-collect / worker-collect fire is #3b-step2 (couples to #4). DA-fork (Option A fold rejected as a different-kind conflation; Alt 1 clean-11th-source vs Alt 2 union-cursor [adopted] vs Alt 3 thread-driven spine [Phase-15/JIT re-conception candidate]) reflected verbatim into ADR-0091's Alternatives considered. Smell category: structural-imagination (F-003) — the per-thread union became the dominant root structure once a third per-thread source [operand stack] arrived, so it is named once instead of triplicated. (#3b-step2b adds a 4th `thread_roots` sub-walk — the per-thread `gc_self_guard` in-flight-fabrication slot for the `op_vector/map/set_literal` accumulator window — via the same thread-major cursor, no enum change; the cursor topology Alt 2 chose accommodates it as another sub-phase per ADR-0091's "extends, not rewrites".)
- 2026-05-24 (amendment 1): §5 Root sources table re-shaped per the `private/notes/phase5-5.3.b.3-survey.md` finding that only 4 of the 10 enumerated sources are entry-point walkers in cw v1. Rows 3 / 4 / 8 demoted to **T** (tag-trace entries registered into `tag_ops.tag_trace_table` from the owning module — `tree_walk.zig` / `lazy_seq.zig` / `type_descriptor.zig`); rows 5 / 6 / 9 demoted to **D** (no live structs in cw v1 / closed-at-construction in `referAll` / cache holds namespace-owned pointers with no GC edge). Net: 4 live walkers + 3 tag-trace registrations + 3 documentary rows. Row 7 also moved from "Analyzer.macro_root_slot" to "macro_root_slot" because the slot lives in `runtime/gc/root_set.zig` (Layer 0) per the survey's zone-respecting access-path decision (Layer 1 reads/writes via downward import). Devil's-advocate Load-bearing concern #5's "reserved as `null` in 5.x" framing for row 9 withdrawn — the cache carries no GC-managed pointers in any Phase. Smell trigger: caught during 5.3.b.3 implementation prep when the survey traced each source against the actual cw v1 struct layouts; the original §5 table was inherited from ADR-0028's initial draft which mirrored cw v0's root-source enumeration without re-evaluating each source against cw v1's design (e.g. cw v1 splits ProtocolFn cache into per-CallSite per ADR-0008 — row 5 becomes empty by construction). Smell category: Spec-drift (ADR text inherited a cw v0 enumeration into a cw v1 design that doesn't have the same shape).
