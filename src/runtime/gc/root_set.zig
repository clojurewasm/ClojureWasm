// SPDX-License-Identifier: EPL-2.0
//! Root-set enumeration for cw v1 mark-sweep GC per ADR-0028 §5.
//!
//! **Phase 5 row 5.3.a skeleton.** The mark phase iterates 10 root
//! sources before transitive trace. They are enumerated here as a
//! single comptime list so 5.3.b's mark body has a stable contract.
//!
//! Root sources (per ADR-0028 §5 table, including the 5 cw v0 "late-
//! patched" gaps that cw v1 refuses to inherit as `suppressCollection`
//! workarounds):
//!
//!   1. `Runtime.envs.entries` — every Namespace's Var roots (Vars
//!      are rooted at `def` time per ADR-0028 §5 Var-rooting clarif).
//!   2. `Env.current_frame` — dynamic binding stack threadlocal.
//!   3. `Fn.closure_bindings` on every live `fn_val`.
//!   4. `LazySeq.thunk` + `LazySeq.ctx` + `LazySeq.seq_cache`
//!      (cw v0 D100 #5; refuses suppress per F-006).
//!   5. `ProtocolFn` / `MultiFn` inline caches (`cached_type_key`,
//!      `cached_method`) (cw v0 D100 #2).
//!   6. `refer()` borrowed symbol-name pointers → owned slice on
//!      `infra_alloc` at refer time (cw v0 D100 #3).
//!   7. Macro-expansion scratch: `Analyzer.macro_root_slot`
//!      (cw v0 D100 #6; refuses `suppressCollection` escape hatch).
//!   8. `TypedInstance.field_values` (transitively from descriptor
//!      reachability).
//!   9. `CallSite.last_method` (Phase 7 `dispatch` activation; slot
//!      reserved as explicit `null` at Phase 5).
//!  10. `Runtime.gc.permanent_roots: std.ArrayListUnmanaged(Value)`
//!      — embedder-pinned values (FFI / test fixtures).
//!
//! At 5.3.a the enumerator returns an empty iterator (no roots exist
//! yet because the wiring into Runtime + per-source enumerators lands
//! in 5.3.b). The enum tag + iterator surface here let 5.3.b wire
//! source-by-source without re-shaping the contract.

const std = @import("std");
const testing = std.testing;

const value_mod = @import("../value/value.zig");
const Value = value_mod.Value;

/// Identifier for one of the 10 root sources enumerated by the mark
/// phase. Used by 5.3.b to dispatch into the source-specific walker.
pub const RootSource = enum {
    ns_vars,
    current_frame,
    fn_closures,
    lazy_seqs,
    protocol_caches,
    refer_borrows,
    macro_root_slot,
    typed_instances,
    callsite_methods,
    permanent_roots,
};

/// Root-set iterator. **Phase 5.3.a skeleton** returns no roots; 5.3.b
/// wires the per-source walkers into `next()`. The shape (iterator
/// with `next() ?Value`) stays so 5.3.b can flip on one source at a
/// time without re-shaping the contract.
pub const RootIterator = struct {
    // 5.3.b adds: source: RootSource, runtime_ref: *Runtime, cursors
    // per source. For 5.3.a the iterator is always exhausted.
    done: bool = true,

    pub fn next(self: *RootIterator) ?Value {
        _ = self;
        return null;
    }
};

/// Build a root-set iterator for the given runtime. **Phase 5.3.a
/// stub** returns an immediately-exhausted iterator; 5.3.b wires the
/// runtime-aware enumerators.
pub fn enumerate() RootIterator {
    return .{};
}

// --- tests ---

test "RootSource enum lists 10 sources per ADR-0028 §5" {
    // The integer count is comptime-derivable; assert it stays at 10
    // so adding/removing a source is a visible diff.
    try testing.expectEqual(@as(comptime_int, 10), @typeInfo(RootSource).@"enum".fields.len);
}

test "RootIterator at 5.3.a returns no roots (skeleton)" {
    var it = enumerate();
    try testing.expect(it.next() == null);
    try testing.expect(it.next() == null);
}
