# 0039 — `ReifiedInstance` minimal layout (drop reserved closure_* fields)

- **Status**: Accepted (Devil's-advocate fork landed 2026-05-26)
- **Date**: 2026-05-26
- **Author**: Shota Kudo (drafted with Claude autonomous loop)
- **Tags**: type-descriptor, reify, closure-capture, F-002, F-003,
  F-006, layout-decision

## Context

`src/runtime/type_descriptor.zig::ReifiedInstance` (extern struct) was
reserved at row 7.5 entry by ADR-0007's TypeDescriptor reservation
table with three fields beyond `header` + `descriptor`:

```zig
pub const ReifiedInstance = extern struct {
    header: HeapHeader,
    closure_count: u32,
    _pad: [4]u8 = .{ 0, 0, 0, 0 },
    descriptor: *const TypeDescriptor,
    closure_bindings_ptr: [*]Value,
    ...
};
```

The reservation anticipated that reified instances would carry
closed-over locals directly on the heap struct (mirroring JVM
Clojure's `Compiler.java::NewInstanceExpr` synthetic-class layout,
where final fields hold captured locals).

Row 7.5 Step 0 survey (`private/notes/phase7-7.5-survey.md` §4)
discovered that **closure capture is already discharged by `fn*`'s
`allocFunction` snapshot** (`src/eval/backend/tree_walk.zig`
L177-L206). The reify macro lowers method bodies to `(fn* [this]
body)`, and each method-Value already carries its closure_bindings
when `__reify!` sees it at primitive-evaluation time. Storing the
same bindings a second time on `ReifiedInstance` would be either
**dead code** (one site shadows the other and the second site is
never read) or **silent-shadowing** (dispatch reads from the wrong
site).

The reservation is now a memo against a need that does not
materialise. Per F-002 (finished-form cleanliness wins) and the
project's Reservation-as-bias smell, we drop the fields rather than
freeze them with a `PROVISIONAL:` marker that points at no upstream
gate (which would collapse into a permanent no-op per
`.claude/rules/provisional_marker.md` row 4).

## Decision

Shrink `ReifiedInstance` to the minimum that the dispatch ABI needs:

```zig
pub const ReifiedInstance = extern struct {
    header: HeapHeader,
    descriptor: *const TypeDescriptor,

    comptime {
        std.debug.assert(@alignOf(ReifiedInstance) >= 8);
        std.debug.assert(@offsetOf(ReifiedInstance, "header") == 0);
        std.debug.assert(@sizeOf(ReifiedInstance) == 16);
    }
};
```

Two cache-word size (16 bytes), naturally 8-aligned. Header at offset
0 (GC walker invariant). Descriptor at offset 8 — back-pointer to a
`*const TypeDescriptor` that itself lives on `rt.gpa` (process
lifetime, never traced).

GC hooks for `.reified_instance`:

- **Trace fn**: no-op. No Value fields on the struct; the descriptor
  pointer is to `rt.gpa`-owned memory which is never GC-reachable.
- **Finalise fn**: no-op. No `gc.infra`-owned tail array (unlike
  `TypedInstance` whose `field_values_ptr` slice needs releasing).

The `allocReifiedInstance(rt, descriptor)` helper allocates the
struct on `rt.gc.alloc` and returns a `.reified_instance`-tagged
Value via `Value.encodeHeapPtr`.

The dispatch ABI at `src/runtime/dispatch.zig` L139-L142 grows a
parallel `.reified_instance` arm reading `inst.descriptor` (same
offset-8 layout pattern as `TypedInstance`).

## Consequences

### Positive

- F-002: finished form ships, not a reservation-frozen intermediate.
- F-003: per-instance metadata slot (D-075 IObj semantics — JVM
  `reify` always implements IObj) is deferred to D-075's owner. D-075
  will add the slot to `TypedInstance` AND `ReifiedInstance`
  symmetrically at that point, not asymmetrically pre-empt here.
- F-006: GC trace surface shrinks. `traceReifiedInstance` is a no-op
  function; the mark phase pays zero cost for reified instances.
  Cache line behaviour also benefits (16-byte struct fits 4-per-cache-line
  on a 64-byte line).
- ADR-0007 reservation table is "honored by deletion" — the slot
  existed, we considered it, the finished form does not need it.
  An amendment paragraph (this ADR) records the deletion.

### Negative

- Future feature wanting per-instance metadata on reified instances
  must add the slot then (D-075 owner). Trade-off: one focused
  metadata cycle adds slots to both `TypedInstance` and
  `ReifiedInstance` symmetrically vs. two scattered partial
  pre-emptions. F-003's structural-deferral principle prefers the
  former.

### Neutral

- F-004 (NaN-box slot economy): no Value tag change; `.reified_instance`
  slot stays at 27.
- F-009 (feature-implementation neutrality): the alloc helper lives
  in `runtime/type_descriptor.zig` (Layer 0), wrapped by the
  `__reify!` primitive (Layer 2) — same shape as `TypedInstance` +
  `allocInstance`.

## Alternatives considered

(Devil's-advocate fork output reflected verbatim, 2026-05-26)

### Alt 1 — Smallest-diff: keep + mark PROVISIONAL

Retain the current `closure_count` + `_pad` + `closure_bindings_ptr`
fields, add a `PROVISIONAL:` marker pointing at a new debt row.

**Better than current**: zero edit to existing layout; ADR-0007
reservation table needs no amendment.

**Breaks**: This is the **Reservation-as-bias smell** verbatim
(F-002 ¶4). The `PROVISIONAL:` marker would point at no real
upstream feature gating discharge — `fn*` closure capture already
works; there is nothing to wait for. That collapses the third
PROVISIONAL row into the fourth (permanent no-op) per
`provisional_marker.md`. Also forces a GC trace decision (do we
walk `closure_bindings_ptr` or not?) for fields nothing writes to
— pure cognitive tax.

**F-NNN impact**: violates F-002 (smallest-diff bias); F-004 neutral
(no slot change); F-006 negative (trace surface carries dead Value
slice); F-003 neutral.

### Alt 2 — Finished-form-clean (Survey §4 Option A) — SELECTED

See Decision section above.

### Alt 3 — Wildcard: single `meta` Value slot now

Pre-allocate one `meta: Value = nil_val` slot in anticipation of
D-075's IObj semantics.

**Better than others**: Pre-allocates the slot D-075 is statistically
certain to want (JVM's `reify always implements IObj` semantics are
documented; survey §1 ¶4 names it). Saves one struct-layout
migration later.

**Breaks**: Pre-empts D-075's decision asymmetrically
(`TypedInstance` does **not** get the same field in this cycle, so
the two diverge). That asymmetry is the bug D-075 would have to
undo on landing. PROVISIONAL marker has no upstream gate (`fn*` is
already done; D-075 is downstream — markers point at *upstream
blockers*, not *downstream consumers*), so the triad would be
misapplied per `provisional_marker.md` §"Boundary rules".

**F-NNN impact**: weakly violates F-003 (pre-deciding what D-075's
owner should decide); F-002 ambiguous (cleaner than Option 1, less
clean than Option 2); F-006 slightly negative vs Option 2 (one
extra Value to trace); F-004 neutral.

### DA recommendation

Lead with Option 2. Survey §4 already converged on it; F-002 + F-003
+ F-006 all point the same direction; the only argument against
Option 2 is "we'll re-add a slot in D-075", which is exactly the
kind of pre-emption F-003 forbids.

## Affected files

- `src/runtime/type_descriptor.zig` — shrink `ReifiedInstance` struct
  (delete `closure_count` / `_pad` / `closure_bindings_ptr` + the
  `closure()` accessor), add `allocReifiedInstance` helper, add
  `traceReifiedInstance` / `finaliseReifiedInstance` no-op hooks,
  extend `registerGcHooks` to register them.
- `src/runtime/dispatch.zig` — extend the descriptor-resolution arm
  at L139-L142 to handle `.reified_instance` alongside
  `.typed_instance`.
- `.dev/decisions/0007_type_descriptor.md` — amendment paragraph
  recording the reservation deletion (cross-link to this ADR).

## References

- `.claude/rules/provisional_marker.md` — Skeleton vs transient stub
  vs PROVISIONAL vs permanent no-op (the boundary table this ADR
  honours).
- `.dev/principle.md` — Reservation-as-bias smell entry.
- `.dev/project_facts.md` — F-002, F-003, F-006.
- `private/notes/phase7-7.5-survey.md` §4 — full struct-layout
  design space.
- ADR-0007 — TypeDescriptor reservation table this ADR amends.
- ADR-0009 — heap-value-only lock semantics (no interaction; reified
  instances carry no per-instance lock per the same rule that
  applies to `TypedInstance`).
