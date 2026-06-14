# 0023 — Comptime conditional import + stub struct pattern

- **Status**: Accepted
- **Date**: 2026-05-23
- **Author**: Shota Kudo (drafted with Claude)
- **Tags**: phase-4-entry, zig, comptime, stub, phase-staging

## Context

cw v1 stages features across phases. At Phase 4 entry the mark-sweep
GC heap (ADR-0017) is reserved as a packed bit slot but not
allocated; the Object header lock (ADR-0009) is reserved similarly;
STM (ADR-0010) is declarations only; TypeDescriptor method tables
(ADR-0007 / 0008) are skeleton.

When source needs to reference these features at compile time, two
forces collide:

1. **No-op stub is forbidden** (`.claude/rules/no_op_stub_forbidden.md`).
   A function that pretends to be the real implementation but does
   nothing is the worst case.
2. **Compile errors slow the loop** when a feature is "obviously
   not implemented yet". Catching it as a catalog error
   (`feature_not_supported`) is the runtime-error path; the
   compile-time path needs a parallel form.

zwasm v1 uses `opaque {}` and `comptime` conditional imports to
maintain a build-time switch without inflating the symbol table.

## Decision

cw v1 adopts two complementary patterns for phase-staged code:

### Pattern A — Comptime conditional import

When a higher-zone import depends on a phase activation:

```zig
const build_config = @import("build_options");

pub const GcHeap = if (build_config.phase_at_least_5)
    @import("runtime/gc/mark_sweep.zig").GcHeap
else
    @import("runtime/gc/stub.zig").GcHeap;
```

The compile decision is at `build.zig`, exposed as a comptime bool
in `build_options`. The phase boundary determines which import is
real and which is the stub.

### Pattern B — Stub struct

The stub module presents the same public API as the real one, but
every function returns `error.NotImplementedYet`:

```zig
//! runtime/gc/stub.zig — Phase 4 stub for runtime/gc/mark_sweep.zig.
//! Activated at Phase 5.

const std = @import("std");

pub const GcHeap = struct {
    pub fn init(_: std.mem.Allocator) GcHeap {
        return .{};
    }

    pub fn deinit(_: *GcHeap) void {}

    /// Allocation is the only function the rest of the runtime
    /// reaches. Returning error.NotImplementedYet at this layer
    /// surfaces through the top-level catch (ADR-0019) as a
    /// catalog `internal_error` (since user input does not reach
    /// this path directly at Phase 4 — only Phase 5 builtins
    /// would).
    pub fn alloc(_: *GcHeap, comptime _: type) error{NotImplementedYet}!*anyopaque {
        return error.NotImplementedYet;
    }
};
```

Pattern B is **distinct from a no-op stub** because:

1. The function returns an explicit `error.NotImplementedYet`,
   which propagates as a `ClojureWasmError` to the catalog at the
   call site. The user does not see this Code directly (`alloc`
   is internal); the dispatching site translates it.
2. The module file carries `//! Phase N stub for ...` in the
   doc-comment header.
3. The real module (`mark_sweep.zig`) has the same public API,
   so swapping at Phase 5 changes only the comptime import.

## Alternatives considered

### Alternative A — `@panic("Phase 5 only")` in every stub function

- **Sketch**: stub bodies are `@panic`.
- **Why rejected**: ADR-0019 forbids `@panic` in any path
  reachable by user input. Even though stub `alloc` is internal,
  Phase 5 builtins like `(vec ...)` would route there, making it
  a user-reachable panic. `error.NotImplementedYet` keeps the
  return as a catalog error.

### Alternative B — `opaque {}` for everything

- **Sketch**: every staged type is `opaque {}` in the stub module.
- **Why rejected**: `opaque` prevents the stub from carrying any
  field at all, which forces the real-module API to be reshaped
  to accommodate. A stub `struct { _: u8 = 0 }` keeps the API
  parallel.

### Alternative C — Build flag `-Dno_gc` and runtime checks

- **Sketch**: leave `mark_sweep.zig` always imported, but the GC
  is a no-op at Phase 4.
- **Why rejected**: this is the no-op stub pattern Shota
  explicitly forbade. Even if the no-op only allocates from the
  arena instead of the GC heap, the *signal* that the GC is not
  running gets lost.

## Consequences

- **Positive**: feature staging is mechanical (one comptime
  import, one stub module). The real module lands as a swap;
  callers do not change. The pattern explicitly distinguishes
  "not implemented yet" (Pattern B) from "no-op pretending to
  work" (forbidden).
- **Negative**: each staged feature carries a parallel
  `stub.zig` file. The cost is one ~30-line file per feature
  (mark_sweep_stub, stm_stub, locking_stub, ...). Acceptable.
- **Neutral / follow-ups**: `build.zig` exposes `phase_at_least_N`
  comptime bools for N in {4, 5, 7, 11, 14, 15, 17}. Each phase
  boundary flips one bool from `false` to `true`. The list of
  bools is the phase progression manifest.

## Affected files

- `build.zig` (Phase 4 task TBD) — add `phase_at_least_5` /
  `phase_at_least_7` / ... comptime bools to `build_options`
- `src/runtime/gc/stub.zig` (Phase 4 task 4.17 area) — example
  stub for ADR-0017 GcHeap
- `src/runtime/lock/stub.zig` (Phase 4 task 4.19 area) — stub for
  ADR-0009 lock activation
- `src/runtime/stm/stub.zig` (Phase 4 task TBD) — stub for
  ADR-0010 STM
- `.claude/rules/no_op_stub_forbidden.md` — cross-reference this
  ADR as the canonical Pattern B example

## References

- ADR-0019 (Crash policy — Pattern B is Layer 2 in the crash
  taxonomy)
- ADR-0009 / ADR-0010 / ADR-0017 (phase-staged features that
  benefit from this pattern)
- `.claude/rules/no_op_stub_forbidden.md`
- zwasm v1 `src/wasm_validator_stub.zig` (precedent)

## Revision history

- 2026-05-23: Status: Proposed -> Accepted (initial landing).
- 2026-06-15 (ADR-0142 / D-440 R5): the `build_options.phase_at_least_N`
  phase-activation manifest (Pattern A) is **RETIRED**. The flags guarded zero
  live code paths in practice — every comptime-stub-staged feature shipped its
  real impl directly rather than behind `if (build_options.phase_at_least_N)`,
  so the flags were defined + unit-tested but never gated source. The §9
  completion-grade reframe (ADR-0142) replaced the phase-number model with gap
  areas, making the per-phase flag meaningless. Removed from `build.zig` +
  `src/main.zig`. The comptime-stub *pattern* itself (real-vs-stub module
  selection without a runtime branch) remains valid; only the phase-numbered
  flag manifest is gone. A future capability-gated build flag (if needed) would
  be named by capability, not phase number (cf. D-443).
