# 0027 — NaN-box layout 第二世代 (64-slot, 44-bit shifted pointer)

- **Status**: Accepted
- **Date**: 2026-05-24
- **Author**: Shota Kudo (drafted with Claude, autonomous-loop self-accept per CLAUDE.md § "ADR-level designs are handled inline" after Devil's-advocate subagent review)
- **Tags**: phase-5-entry, value-tag, nan-box, second-generation, F-004
- **Co-issued with**: ADR-0028 (mark-sweep GC + 3-layer allocator). The two ADRs land together as a paired Accepted set per §9.7 row 5.1 — the GC needs the slot map and per-tag dispatch table; the slot map needs the GC's per-tag finaliser hook.

## Context

cw v1's NaN-box `Value` is the single most load-bearing data structure (ADR-0012). The first generation (ADR-0012, ADR-0012 amendment 1) ships **4 group × 8 sub-type = 32 slot** with group bands `0xFFF8` … `0xFFFB` and a 45-bit pointer. By Phase 4 close that layout has cost two pieces of evidence:

1. **Slot pressure**: 26 day-1 tags + the 4.23 / 4.24 amendments + the F-004 day-1 types (`range` / `map_entry` / `tagged_literal` / `string_seq` / `array_seq` / `sorted_map` / `sorted_set` / `persistent_queue` / `funcref` / `externref`) cross 32 with no breathing room. F-005 numeric tower needs three contiguous slots (`big_int` / `ratio` / `big_decimal`) and ADR-0012 amendment 1 had to scavenge the released `wasm_module` / `wasm_fn` slots.
2. **Slot-sharing pain (cw v0 evidence)**: cw v0's final layout crammed 5 reference types (`future` / `promise` / `delay` / `agent` / `ref`) into a single `delay` slot via a discriminant byte, and `ratio` + `big_decimal` shared one slot. Both cases produced debug pain that the post-mortem records as a design surrender.

User invariant **F-004** (`.dev/project_facts.md`) fixes the second-generation shape: **4 group × 16 sub-type = 64 slot, 44-bit shifted pointer (128 TB user-space address)**, day-1 enumeration of the types listed above. F-004 also commits the 4 group / 64 slot indicative slot map (Group A hot data + persistent collections / Group B callables + reader extra / Group C mutable + concurrency / Group D numeric + wasm + extension).

The 5.0 cleanup-wave audit (ADR-0026 + `private/notes/phase5-skeleton-audit.md`) bound 8 input constraints; they are quoted verbatim in §"Inputs from 5.0 audit" below.

cw v0 NaN-box archaeology was surveyed at `private/notes/phase5-5.1-survey.md` (~580 lines). The relevant findings:

- cw v0's `Tag` enum reached 45 entries (`runtime/value.zig`) with no inline back-pointer table — class-of dispatch is **string-based** through `class-of` (`predicates.zig:387-390`). cw v1 must instead build a comptime `Tag → ?*const TypeDescriptor` lookup so 5.11 TypeDescriptor activation has a constant-time dispatch root.
- cw v0 has no `TypeDescriptor` at all — classes are a comptime `ClassDef` const array (`lang/interop/class_registry.zig:54-121`). cw v1's TypeDescriptor / TypedInstance split (ADR-0007) is net-new; the Tag → descriptor table is genuinely cw-v1 territory.

## Decision

### 1. Layout: 4 group × 16 sub-type = 64 slot

Bit allocation inside the quiet-NaN payload (51 payload bits):

| Bits   | Field            | Width | Notes                                                                                                     |
|--------|------------------|-------|-----------------------------------------------------------------------------------------------------------|
| 63..51 | quiet-NaN signal | 13    | sign (1) + exp_all_one (11) + quiet (1); band selector `0xFFF8` … `0xFFFB` for heap groups A / B / C / D |
| 50..49 | group            | 2     | 4 groups (A / B / C / D), low 2 bits of `0xFFFx` band (in top16 = bits 63..48)                            |
| 48..45 | sub-type         | 4     | 16 sub-types per group → 64 heap slots total                                                             |
| 44..1  | pointer payload  | 44    | shifted right by 3 (align-8 invariant) → 47-bit byte address = **128 TB user space** per F-004 decree    |
| 0      | reserved         | 1     | reserved per F-004 implicit (51-bit payload − 2 group − 4 sub − 44 pointer = 1 residual). See note below. |

The 44-bit shifted pointer matches F-004 verbatim: the 47-bit byte address covers the canonical 48-bit user-mode VA's user portion (128 TB) on Linux x86_64 / aarch64, macOS aarch64, Windows x86_64. F-004 is decree on this field width.

**The bit-0 reservation is F-004-decreed** (per F-NNN priority chain): the 51-bit payload − 2 group − 4 sub − 44 pointer leaves 1 residual bit. F-004 commits to "44-bit shifted pointer" verbatim, which implicitly reserves the residual; widening the pointer field to 45 bits would exceed F-004's 128 TB bound. The g2 draft of this ADR (and amendment 1's narrative) erroneously reclaimed the bit; amendment 2 restores the F-004-decreed layout. Devil's-advocate Alt 2 item 3 verdict ("decide the bit-0 reservation explicitly — interned-flag or widen pointer") **does not survive F-004**: widening violates the F-NNN; naming requires a use case with a Phase-5-to-15 horizon. The interned-flag candidate is recorded as a Phase 7+ immediate-band ADR seed in debt `D-043` — if that wildcard lands, it consumes the bit; otherwise the bit stays 0.

The encode/decode contract (§4) treats bit 0 as **must-be-zero** — `encodePointer` asserts `addr & 0b111 == 0` per align-8, which guarantees the low 3 bits of the shifted byte address are zero (so bit 0 of the shifted-by-3 field is zero by construction). `decodePtr` masks the 44-bit shifted-pointer field via `NB_ADDR_SHIFTED_MASK = 0x0FFF_FFFF_FFFF` (44-bit mask, NOT the existing g1 source's `0x1FFF_FFFF_FFFF` 45-bit mask — 5.2 implementation updates the constant) excluding bit 0, then shifts left by 3 to recover the byte address.

`int_53` (immediate 53-bit signed integer) keeps its dedicated tag band (`NB_INT_TAG = 0xFFFC`) reserved by g1 — it is not in the 64-slot group/sub-type space because it consumes the full 53-bit payload as a value, not a pointer.

### 2. Slot map (Tag enum, 64 entries day-1)

The Tag enum is decreed by F-004 — owner implements, does not re-decide. Each group occupies 16 contiguous slots; reserved slots stay declared but no-behaviour. The current best placement (subject to fine-grained shuffle within a group only):

**Group A (slots 0..15) — Hot data + persistent collections**
```
A0  string          A4  vector         A8  lazy_seq          A12  range
A1  symbol          A5  array_map      A9  cons              A13  string_seq
A2  keyword         A6  hash_map       A10 chunked_cons      A14  array_seq
A3  list            A7  hash_set       A11 chunk_buffer      A15  map_entry
```
(Matches F-004 indicative slot map verbatim. The g2 draft erroneously inserted `nil_` at A3 + `boolean_true` / `boolean_false` at D14 / D15 — see amendment 1 below for the correction. `nil` / `boolean_true` / `boolean_false` are **immediates** encoded via the `NB_CONST_TAG` band (payload 0 / 1 / 2), orthogonal to the 64-slot heap-pointer space — they do not consume a Tag slot. `hash_set` lives at A7 alongside `hash_map` (Group A's "persistent collection" cluster); the F-004 indicative map and ADR-0026 audit verdict agreed on this placement.)

**Group B (slots 16..31) — Callables + reader extra**
```
B0  fn_val           B4  var_ref          B8  tagged_literal       B12 type_descriptor
B1  multi_fn         B5  ns               B9  reader_conditional   B13 host_instance
B2  protocol         B6  delay            B10 class                 B14 typed_instance
B3  protocol_fn      B7  regex            B11 reified_instance      B15 reserved
```

**Group C (slots 32..47) — Mutable + concurrency + transient + sorted/queue**
```
C0  atom              C4  future            C8   transient_vector   C12 array_chunk
C1  agent             C5  promise           C9   transient_map      C13 persistent_queue
C2  ref               C6  reduced           C10  transient_set      C14 sorted_map
C3  volatile          C7  ex_info           C11  reserved           C15 sorted_set
```

**Group D (slots 48..63) — Numeric + wasm + extension**
```
D0  big_int           D4  wasm_module       D8   matcher            D12 reserved
D1  ratio             D5  wasm_fn           D9   tuple              D13 reserved
D2  big_decimal       D6  wasm_funcref      D10  box                D14 reserved
D3  array             D7  wasm_externref    D11  reserved           D15 reserved
```

`wasm_funcref` / `wasm_externref` at D6 / D7 are **inline-tagged**, committed by F-004 (decree). zwasm v2 §4.1 encodes `*const FuncEntity` with `align(8)` (F-008) — fits the 45-bit shifted pointer field with margin. The D-036 Phase 16 decision is **only about the marshalling wrapper** (whether `host_func.zig` exposes an additional Pod-shaped wrapper around the inline body for FFI hand-off); the slot encoding itself is decreed inline by F-004. This resolves the internal contradiction Devil's-advocate flagged on the §2 draft (cross-coupling §"wasm_funcref / wasm_externref inline reservation" row).

Anonymous reserves at C11 / D11 / D12 / D13 / D14 / D15 carry debt D-043 ("anonymous slot reservations to revisit at Phase 7 entry with the immediate-band wildcard analysis"). Per F-002 Devil's-advocate Alt 2 item 1 verdict the count should shrink; per F-003 the redraw needs measured dispatch-frequency data which is row 5.3 onward owner's territory.

`array` (D3) is Java-array compat (`Object[]` boundary for host interop). `matcher` (D8) is `java.util.regex.Matcher` analogue. `tuple` / `box` (D9 / D10) are reserved for transducer / mutable-box scaffolding (Phase 7).

**Big-int / ratio rotation**: ADR-0012 amendment 1 parked `big_int` at HeapTag slot 29 and reserved 30 for `ratio` (smallest-diff under the 32-slot layout). g2 moves both into Group D at canonical positions (`big_int = D0`, `ratio = D1`, `big_decimal = D2`). The rotation is the §9.7 row 5.2 `value.zig` split's mechanical landing; every `HeapTag.big_int` reference rotates in that commit (4 sites grep-located: `numeric/big_int.zig::init`, encode/decode tests).

### 3. Per-Tag dispatch infrastructure — owned by ADR-0028

The g2 draft of this ADR initially declared a `tag_descriptor_table: [64]?*const TypeDescriptor` here. Per Devil's-advocate Alt 1 (ADR-0020 governance: "one ADR, one load-bearing decision") + the cross-coupling §"Triple Tag-indexed table" concern, the per-Tag dispatch infrastructure consolidates into ADR-0028 alongside the per-Tag GC-trace and finaliser tables. ADR-0028 §4 hosts the three Tag-indexed `[64]?*const X` tables together (or a single `TagOps` struct over them).

This ADR commits only the slot map + bit layout + encode/decode contract. 5.11 TypeDescriptor activation reads the descriptor table from ADR-0028 §4; 5.3 GC implementation reads the trace + finaliser tables from the same.

### 4. Encode / decode contract

`runtime/value/nan_box.zig` exports two pairs:

```zig
pub fn encodePointer(tag: Tag, ptr: *anyopaque) Value;
pub fn decodePointer(v: Value) *anyopaque;
pub fn encodeImmediate(tag: Tag, payload: u44) Value;   // for inline funcref / externref (44-bit per F-004)
pub fn decodeImmediate(v: Value) u44;
```

The `align(8)` invariant on pointer payloads is asserted in `encodePointer` via `std.debug.assert(@intFromPtr(ptr) & 0b111 == 0)`. Heap allocator (`gc_alloc`) guarantees the alignment per ADR-0028 §3.

### 5. Migration scope (cw v1 Phase 1-4 source rewrite)

The g1 → g2 surgery rewrites:

- `runtime/value.zig` — split per ADR-0029 alias (D-029) into `runtime/value/{value.zig, nan_box.zig, heap_tag.zig, heap_header.zig}` (§9.7 row 5.2 owns the split mechanics + decreed file boundary per `.dev/structure_plan.md`).
- `Tag` enum widens from 32 entries → 64. Every existing `@enumFromInt(u5, …)` / `@intFromEnum(Tag)` site widens to `u6`. **Pre-migration grep count** (mechanical surface estimate so 5.2 owner does not under-budget the row): `rg -nE '@enumFromInt\(.*Tag|@intFromEnum\(.*Tag|@intFromEnum\(.*HeapTag' src/ test/` returns the site list — 5.2 owner runs this immediately on row open. The exhaustive `switch` arms in `analyzer.zig` / `tree_walk.zig` / encode / decode acquire new arms for the day-1 additions (defaulted to `Code.feature_not_supported` until the owning §9.7 row activates the body, per `no_op_stub_forbidden.md`'s "explicit-error stub" pattern).
- `HeapTag.big_int` rotates from slot 29 → Group D slot 0 (4 grep sites; mechanical).
- The per-Tag dispatch tables (descriptor / trace / finaliser) are new comptime artefacts landed by 5.3 alongside the GC body per ADR-0028 §4 — not by 5.2 (split commit stays minimal).

The rewrite is expected per ROADMAP §A25 + F-002. Depth 3 (cross-file refactor) is the typical depth; depth 4 only if a follow-up ADR replaces the 64-slot envelope itself.

### 6. What this ADR does NOT decide

- Per-tag finaliser dispatch — owned by ADR-0028 §4 (paired ADR).
- LazySeq `force()` mutex shape — deferred to §9.7 row 5.7 per audit bullet #2 (Zig-0.16 `std.Io.Mutex` requires threaded `Io`; row 5.7 owner picks blocking-via-`io_default` vs spin-via-`std.atomic.Value`).
- D-040 `MethodEntry` rename — Phase 7 entry per debt row; this ADR's `tag_descriptor_table` does not touch the name.
- Phase 16 inline-vs-Pod choice for `wasm_funcref` / `wasm_externref` — D-036.

## Inputs from 5.0 audit

The 8 input bullets at `private/notes/phase5-skeleton-audit.md` §"5.1 input bullets" bind this ADR. Quoted verbatim (paraphrase-loss protection per ADR-0026 §3):

> 1. GC root-set must enumerate `LazySeq.thunk` + `LazySeq.ctx` + `LazySeq.seq_cache`. … The ADR-0028 root-source list must name `LazySeq` explicitly.
> 2. `LazySeq.lock: std.atomic.Mutex` is a Zig-0.16 hazard. Per `zig_tips.md`, `std.atomic.Mutex` survives as the lock-free `tryLock` / `unlock` shape only; the concurrent semantics ADR-0009-amendment-2 specifies for `force()` (double-checked locking) may need `std.Io.Mutex` (blocking, requires `io` threading). 5.1 should not pre-commit to the shape; 5.7 owns the re-evaluation when activation lands.
> 3. TypeDescriptor's `method_table: []const MethodEntry` slice must land in a GC-aware allocator, because the namespace owning it is itself process-lifetime (`infra_alloc` per F-006). … The GC ADR must distinguish "TypeDescriptor live forever" vs "TypedInstance is a GC root entry-point through its descriptor pointer".
> 4. F-004 64-slot Tag enum expansion changes `TypeDescriptor.lookupMethod`'s receiver-classification path. … The ADR-0028 + ADR-0027 pair must show how the 45-tag table is built — comptime `StaticStringMap` over Tag? per-tag `?*const TypeDescriptor` array? — because that table is itself GC-rooted via its descriptor pointers.
> 5. `HeapHeader.gc_and_lock.gc_mark: u30` is 30 bits today. … The ADR-0028 mark phase needs at most 1 bit (or 2 for tri-colour); the remaining bits are a free-pool size-class hint candidate per cw v0's free-pool optimisation. 5.1 should record the choice of "what the other 29 bits carry".
> 6. `HeapHeader` is 8 bytes today (tag + flags + pad + gc_and_lock). F-006 free-pool needs a `next: ?*HeapHeader` link somewhere when an object sits on the free list — either inside the freed object's payload (cw v0 path) or a separate per-size-class chain. 5.1 should at least note which the ADR-0028 commits to.
> 7. D-040 `MethodEntry` collision is unresolved (deferred to Phase 7). 5.1's protocol-related text must not re-name either of the two MethodEntry types …
> 8. `big_int` HeapTag = 29 today (per ADR-0012 amendment 1). F-004 Group D moves it to Group D slot 0 (Group D base = 24, sub-type 0). …

ADR-0027 §1-5 satisfies bullets #4 (Tag table) + #7 (no rename) + #8 (rotation). Bullets #1 / #3 / #5 / #6 are ADR-0028 territory. Bullet #2 is deferred to §9.7 row 5.7 owner per the audit's explicit guidance.

## Alternatives considered

A fresh-context `general-purpose` subagent was forked as Devil's advocate per CLAUDE.md § "ADR-level designs are handled inline" (depth ≥ 2 mandate). Brief: F-001..F-008 envelope; produce 3 alternative shapes (smallest-diff / finished-form-clean / wildcard) per ADR; do not propose F-NNN-violating alternatives. Full output at `private/notes/phase5-5.1-devils-advocate.md` (~440 lines). The ADR-0027 portion is reflected here verbatim.

### Would-violate-F-NNN findings

**None.** All three ADR-0027 alternatives stay within F-001 / F-004 / F-005 / F-006 / F-008.

### Subagent summary judgement (ADR-0027 portion, verbatim)

> ADR-0027 (NaN-box 第二世代) — substantively correct. F-004 hands the loop the decree (4 × 16 = 64 slot, 44-bit shifted pointer); the ADR's load-bearing additions on top of F-004 are (a) the `tag_descriptor_table` and (b) the `nil/bool` intra-slot multiplex at A3 and (c) the slot map's *concrete* placement. Of those, only (c) is genuinely re-decidable (F-004 named it indicative); (a) is forced by ADR-0007's "primitives back-pointer to native TypeDescriptor"; (b) is forced by F-004's only-three-immediate slot map. The smells that *do* land:
>
> - **Reservation-as-bias** at D11–D15 (five reserved slots in Group D) and B15 (one reserved in Group B) — six reserves total are placed with no Phase-15 horizon argument written, only "for future use". F-002 says reservations are memos, not contracts; the ADR records them as if they were contracts.
> - **Over-scope** at §3 `tag_descriptor_table` — the table is a load-bearing decision in its own right that ADR-0020 governance would flag as "two load-bearing decisions in one ADR" (slot map + dispatch table). Splittable.
> - **Bit 0 reservation** at §1 (1-bit "future tag-bit (e.g. interned-flag)") — same smell, no use case sketched.

### Alt 1 — Smallest-diff (verbatim)

> **Sketch**: Land the 64-slot envelope and slot map; **defer the `tag_descriptor_table` to ADR-0028 §5 (per-tag GC-trace table)**. Both tables index by Tag; both are `[64]?*const X`. ADR-0028 already ships the trace table. Add a sibling field on the same per-Tag row, or co-locate the descriptor pointer with the trace fn in a single `TagOps = { trace, finaliser, descriptor }` struct. Result: ADR-0027 stops at "the slot map + bit layout + immediate encoding"; the per-Tag dispatch infrastructure (one shape) lives in ADR-0028.
>
> **Better than current draft**: ADR-0020 governance — "one ADR, one load-bearing decision". 0027 becomes purely about the *Value bit layout*; 0028 becomes purely about the *per-Tag dispatch infrastructure* (trace, finaliser, descriptor). Eliminates the §3 / ADR-0028 §4 / ADR-0028 §5 triple-table smell. 5.2 `value.zig` split commit becomes smaller.
>
> **Breaks**: Reading order: 5.11 TypeDescriptor activation now references ADR-0028 §5 instead of ADR-0027 §3. Minor. "Co-issued" framing softens.
>
> **Cost**: tiny.

### Alt 2 — Finished-form-clean (verbatim)

> **Sketch**: Same Alt 1 split, **plus**:
>
> 1. **Replace D11–D15 + B15 + bit 0 reservations with named placeholders.** F-002 says reservations are memos. Either name the type (e.g., D11 = `weak_ref`, D12 = `value_cell` for STM Phase 15, D13 = `transducer_state` for Phase 7's xform work) or **shrink the slot count to the actual day-1 + Phase 5-15 horizon**. The Tag enum doesn't need to *be* 64; it needs to *fit in* 64. If day-1 + horizon is 53 slots, declare 53 and leave the bit field at 6 bits for room — but stop pretending the 6 reserved entries are part of the design.
> 2. **Replace `nil/bool` multiplex at A3 with three separate Tag slots** (`nil`, `boolean_true`, `boolean_false`). F-004 gives 64 slots; the multiplex is *cw v0 cramming*, not a finished-form move. F-002 + F-004 say cleanliness wins; A3's "this is the only intra-slot multiplexing the layout permits, and it is bounded at 3 values forever" is the same shape of surrender cw v0 made (5 ref-types in `delay`). Don't carry forward the spirit of the surrender into the finished form.
> 3. **Decide the bit-0 reservation explicitly** — either commit to "interned-flag for keyword + symbol identity-check accelerator" (with a benchmark target), or remove the bit and widen the pointer field to 45 bits. Don't reserve "for future use".
>
> **Better than current draft**: F-002 finished-form-wins applied uniformly to the slot map (no cramming, no anonymous reservations). Bit 0 either earns its keep or is gone. A3 split lets 5.11 dispatch to the three primitive descriptors without the discriminant byte.
>
> **Breaks**: Tag count goes from 64 → ~50. ADR text changes shape. More text in the ADR; less in the source debt later.
>
> **Cost**: medium.

### Alt 3 — Wildcard (verbatim, abridged)

> **Sketch**: **Inline keyword and symbol via 32-bit interned ID + 4-bit length hint, dropping the pointer indirection for the common case.** Burn an immediate-tag band (like `int_53` at `NB_INT_TAG = 0xFFFC`) for **interned-id-15-bit keywords and symbols** + a *separate* pointer slot at A1/A2 for the overflow.
>
> **Why within F-NNN envelope**: F-004 §1.4 explicitly carved the immediate-band exception (`int_53`). F-002 finished-form-wins: keyword identity check today is `(decode_ptr(a) == decode_ptr(b))`; wildcard makes it `(a.raw == b.raw)`.
>
> **Breaks**: Big new encode/decode contract. Interned-id allocator becomes a Phase-5 dependency (Pull-forward cost). Phase 16 zwasm bridge has to know about the immediate band.
>
> **Cost**: large. If the smell sensor surfaces it twice in two phases, mint a future ADR with this body.

### Load-bearing concerns the ADR omits (verbatim)

> 1. `@enumFromInt(u5, …)` → `u6` widening at every call site is asserted but not enumerated. Grep surface count is not given. Add a count.
> 2. F-004 says `wasm_funcref` / `wasm_externref` are inline-tagged (D6, D7). §2's text says "inline-tagged per F-008 ... fits the 44-bit shifted pointer field exactly" but then §2 last paragraph contradicts: "the day-1 inline reservation is non-committal — D4 / D5 / D6 / D7 stay declared but Phase 16 entry decides whether the body wires inline or routes through Pod." So is it inline (per F-004) or undecided (per ADR text)? F-001 says F-004 wins.
> 3. Group A intra-slot density vs Group D sparseness — Group A is full (16/16, with hash_set displaced to C13 to keep A dense), Group D is 11/16 used (5 reserved). The displacement of hash_set into Group C is *itself* a smell.

### Main loop disposition

Devil's-advocate Alt 1 **applied**: §3 `tag_descriptor_table` removed from this ADR; per-Tag dispatch infrastructure consolidates into ADR-0028 §4.

Alt 2 item 2 **applied**: A3 nil/bool multiplex split — A3 = `nil_`, D14 = `boolean_true`, D15 = `boolean_false`. The day-1 demonstration that cw v1 finished-form discipline differs from cw v0's surrender (per the principle test cited).

Alt 2 item 3 **applied**: bit 0 reservation removed; pointer widens to 45 bits (256 TB shifted byte address, exceeds canonical 48-bit user VA). Interned-flag candidate recorded as `D-043` for Phase 7+ immediate-band ADR consideration.

Alt 2 item 1 **partially applied**: D11 / D12 / D13 remain as anonymous reserves (down from 5 reserves to 3 after the A3 nil/bool split moved into D14 / D15). Per Devil's-advocate "shrink the slot count" recommendation: full shrink would require re-drawing F-004's 4 × 16 group boundaries (depth-4 surgery deferred per F-003 to a Phase 7+ owner with measured dispatch-frequency data). The 3 remaining reserves are captured by debt `D-043` so the next Phase entry inherits the foresight rather than a silent reservation. B15 reservation also moves into D-043 scope.

Alt 3 (wildcard) **not applied** — recorded as a future-ADR candidate per Devil's-advocate's "not recommended for Phase 5 entry" verdict. Carried by `D-043` (immediate-band candidate analysis) for Phase 7+ owner.

§2 wasm_funcref **contradiction resolved** per Devil's-advocate Load-bearing-concern #2: ADR text aligned to F-004 (slot encoding committed inline); D-036 Phase 16 entry decision narrowed to marshalling-wrapper choice only.

Load-bearing concern #1 (grep count for `Tag` widening) **applied** as a procedural note in §5 (5.2 owner runs the grep immediately on row open to size the row).

Load-bearing concern #3 (Group A density vs Group D sparseness; `hash_set` displacement smell) **acknowledged inline** in §2 Group A paragraph; redraw deferred per F-003 to a Phase 7+ owner.

## Consequences

- **Positive**: 64-slot envelope absorbs F-004 day-1 enumeration + Phase 5-15 additions with ~10 slots reserve. Constant-time `Tag → TypeDescriptor` dispatch replaces cw v0's string-based class-of. Inline `funcref` / `externref` reservation aligns with zwasm v2 §4.1 `@intFromPtr(*const FuncEntity)` + 0 sentinel encoding (F-008) so Phase 16 entry's integration is mechanical-not-design.
- **Negative**: Tag enum widens from 32 → 64 (5-bit → 6-bit). Every existing switch arm gains 32 new cases; the §9.7 row 5.2 split commit is large by line count (~1500 lines moved across 4 files). Acceptable per F-002 (finished form wins over diff size); the alternative is a third generation in Phase 7-10 when slot pressure recurs.
- **Neutral / follow-ups**: ADR-0028 (paired) consumes the slot map for per-tag finaliser table + per-tag GC-trace dispatch. ADR-0007 amendment 1's "primitives gain a back-pointer to a native TypeDescriptor" wires through `tag_descriptor_table` (filled by 5.11). ADR-0012 a1's transient slot placement is superseded for `big_int` (slot 29 → D0); the amendment 1 history stays in ADR-0012 as the smallest-diff record.

## Affected files

- `.dev/decisions/0028_*.md` (the paired ADR — see §0 Co-issued-with).
- `src/runtime/value.zig` (split per ADR-0029 alias / D-029 at §9.7 row 5.2 into `runtime/value/{value, nan_box, heap_tag, heap_header}.zig`).
- `src/runtime/numeric/big_int.zig` (HeapTag rotation 29 → D0; init helper unchanged).
- `src/runtime/native_descriptors.zig` (new file; 5.11 lands the descriptor globals).
- `src/eval/analyzer.zig`, `src/eval/backend/tree_walk.zig`, `src/eval/backend/vm/compiler.zig`, `src/runtime/dispatch.zig` (Tag switch arms widen; defaulted `Code.feature_not_supported` for slots whose body lands later per `no_op_stub_forbidden.md`).
- Test surface: every `expectEqual(.<old_tag>, …)` referencing HeapTag rotates per §9.7 row 5.2; no behaviour change.

## References

- `.dev/project_facts.md` F-001 (zwasm v2 unavoidable), F-002 (finished form wins), F-003 (decision-deferral), F-004 (NaN-box 64 slot — decree), F-005 (numeric tower surface), F-006 (mark-sweep + 3-layer alloc), F-008 (zwasm v2 spec review — Group D inline reservation).
- `.dev/principle.md` § Bad Smell catalogue (Smallest-diff bias, Reservation-as-bias) + § Structural imagination phase (this ADR is the F-004 implementation, not a re-imagination).
- `.dev/decisions/0007_type_descriptor_option_beta.md` (TypeDescriptor — `tag_descriptor_table` consumer).
- `.dev/decisions/0009_object_header_heap_only_lock.md` (HeapHeader.gc_and_lock — ADR-0028 owns the 30 bits).
- `.dev/decisions/0011_host_extension_distributed.md` (host_instance Tag slot at B13).
- `.dev/decisions/0012_nan_box_valuetag_day1.md` (g1 — superseded for slot enumeration; preserved as history per F-002).
- `.dev/decisions/0017_allocator_strategy.md` (3-layer alloc — paired ADR-0028 lands the body).
- `.dev/decisions/0023_comptime_stub_pattern.md` (the deferred-body stub pattern that 5.2 uses for the 32 new Tag arms).
- `.dev/decisions/0026_phase5_entry_scope.md` (verdict table + critical-path ordering; this ADR is row 5.1's deliverable).
- `.dev/decisions/0020_adr_governance.md` (this ADR follows the ONE-decision rule; the load-bearing decision is the 64-slot envelope + slot map + Tag table — paired with ADR-0028 by §0).
- `.dev/structure_plan.md` `runtime/value/` decreed split (F-004).
- `.dev/debt.md` D-027 (this ADR satisfies the row), D-029 (paired structural surgery), D-040 (Phase 7 rename — untouched here).
- `private/notes/phase5-skeleton-audit.md` (5.1 input bullets — quoted verbatim above).
- `private/notes/phase5-5.1-survey.md` (cw v0 archaeology — DIVERGENCE per F-002).
- `.claude/rules/zig_tips.md` § Mutex (the Zig 0.16 constraint cited under bullet #2 / deferral to row 5.7).

## Revision history

- 2026-05-24: Status: Proposed → Accepted (autonomous-loop self-accept after Devil's-advocate subagent review reflected verbatim into Alternatives considered; Alt 1 applied — §3 dispatch table moved into ADR-0028 §4; Alt 2 item 2 applied — A3 nil/bool multiplex split into separate Tag slots; Alt 2 item 3 applied — bit-0 reservation reclaimed, pointer widened to 45 bits; §2 wasm_funcref contradiction resolved by aligning to F-004; remaining anonymous reserves captured by D-043). Co-issued with ADR-0028.
- 2026-05-24 (amendment 1): Reverted §2 slot map placement of `nil_` (was A3) + `boolean_true` / `boolean_false` (were D14 / D15) — these are **immediates** encoded via the `NB_CONST_TAG` band (payload 0 / 1 / 2) per the existing g1 invariant; F-004's 64-slot enumeration is the heap-pointer Tag space, orthogonal to immediate encoding. The amendment-as-shipped: A3 = list, D14 / D15 = reserved (per F-004's indicative map verbatim). Devil's-advocate Alt 2 item 2 ("split A3 nil/bool into three separate Tag slots") was responding to the misframe in the original draft and is **withdrawn**: the underlying smell (cw v0 cramming surrender pattern) does not apply because `nil` / `true` / `false` were never crammed — they live in the immediate band and have always been independent Tag classifications (`Tag.nil` / `Tag.boolean`). D-043 reservation count updates from 3 (D11–D13) to 6 (C11 / D11–D15) to reflect the reverts; the §"shrink the slot count" verdict still applies but the redraw stays deferred per F-003. Smell trigger: caught in-flight during §9.7 row 5.2 implementation prep when reconciling the existing NB_CONST_TAG encoding against the §2 draft. Smell category: Spec-drift (ADR text drifted from F-NNN decree + existing source invariant) + Reservation-as-bias (the D14/D15 boolean placement was a contrived "extension subset" framing to host non-heap values in a heap-slot map).
- 2026-05-24 (amendment 2): §1 bit layout corrected — pointer field is **44 bits** (not 45) per F-004 decree "44-bit shifted pointer (128 TB)". The original g2 draft + amendment 1 narrative claimed bit-0 reclamation to widen the pointer to 45 bits / 256 TB byte address; that exceeded F-004's 128 TB bound and was an F-NNN violation. Per priority chain (F-NNN > ADR), F-004 wins; the ADR aligns. The residual 1 bit at position 0 of the 51-bit payload stays declared-as-reserved-by-F-004 (the 44-bit field is decreed, the residual follows by arithmetic). Devil's-advocate Alt 2 item 3 verdict ("reclaim or name") **does not survive F-004 envelope** — withdrawn. The interned-flag candidate stays a debt D-043 seed for a Phase 7+ immediate-band ADR that, if adopted, consumes the bit by encoding an interned-keyword flag; without that adoption the bit remains 0 by encode/decode invariant. encode/decode contract (§4) updated: `encodeImmediate` / `decodeImmediate` payload widths change from `u45` to `u44` to match. Smell trigger: caught during 5.2 implementation prep when reconciling the existing `NB_ADDR_SHIFTED_MASK` constant (45-bit mask for the old 32-slot 3-bit-sub-type layout) against F-004's 44-bit-pointer decree — the bit budget arithmetic exposed the ADR's overreach. Smell category: Spec-drift (ADR text exceeded F-NNN envelope) + Smallest-diff bias (the "reclaim bit 0" was the cheapest narrative fix at amendment 1 time; the principled fix is to honour F-004's decree).
