// SPDX-License-Identifier: EPL-2.0
//! IRef watch notification (Layer 0): the shared `(fn key ref old new)` firing
//! loop used by every IRef whose state change happens on a non-primitive layer
//! — the agent drainer (`agent.zig`) and the STM commit (`lock_tx.zig`), with
//! the var `alter-var-root` site joining when wired. These run in Layer 0 (or a
//! worker thread), so they cannot reach the Layer-2 `higher_order.invokeCallable`
//! the synchronous atom path (`lang/primitive/atom.zig`) uses; this funnels the
//! identical loop through the Runtime vtable `callFn` instead.
//!
//! Storage of the `{key -> fn}` map stays per-type (each ref struct owns its
//! `watches` field); only the firing loop is shared here.

const value_mod = @import("value/value.zig");
const Value = value_mod.Value;
const Runtime = @import("runtime.zig").Runtime;
const Env = @import("env.zig").Env;
const root_set = @import("gc/root_set.zig");
const map_mod = @import("collection/map.zig");
const list_mod = @import("collection/list.zig");
const error_mod = @import("error/info.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("dispatch.zig");
const ex_info = @import("collection/ex_info.zig");

/// Run `validator` (if non-nil) against `newval` BEFORE the change is committed
/// (clj `ARef.validate`). A falsey return throws IllegalStateException "Invalid
/// reference state" so the caller MUST NOT commit (the ref is left unchanged); a
/// validator that itself throws propagates as-is. Layer-0 helper for the STM
/// commit (`lock_tx.zig`), which cannot reach the Layer-2 `invokeCallable` the
/// synchronous atom path uses — funnels through the Runtime vtable `callFn`,
/// like `notifyWatches`. `newval` is published on an EvalFrame (GC-ROOT) so a
/// collect during the validator's VM re-entry cannot sweep it.
pub fn validateOrThrow(rt: *Runtime, env: *Env, validator: Value, newval: Value) !void {
    if (validator.isNil()) return;
    const vt = rt.vtable orelse return error.InternalError;
    var gc_roots: [1]Value = .{newval};
    var gc_sp: u16 = 1;
    var gc_frame: root_set.EvalFrame = .{ .stack = &gc_roots, .sp = &gc_sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;
    const ok = try vt.callFn(rt, env, validator, &[_]Value{newval}, .{});
    if (!ok.isTruthy()) {
        dispatch.last_thrown_exception = try ex_info.allocException(rt, "Invalid reference state", "IllegalStateException");
        return error.ThrownValue;
    }
}

/// Fire every registered watch `(fn key ref old new)` for `ref_val`. `watches`
/// is the ref's `{key -> fn}` map (nil / empty short-circuits). A watch fn may
/// re-enter the VM (e.g. a nested `swap!`), so `[ref, watch map, key cursor]`
/// are published on an EvalFrame (GC-ROOT) — a collect mid-notify must not sweep
/// the cursor [ref: .dev/gc_rooting.md §C]. Runs the fns in key-iteration order.
pub fn notifyWatches(rt: *Runtime, env: *Env, ref_val: Value, watches: Value, old: Value, new: Value) !void {
    if (watches.tag() != .array_map and watches.tag() != .hash_map) return;
    if (map_mod.count(watches) == 0) return;
    const vt = rt.vtable orelse return error.InternalError;
    var cur = try map_mod.keys(rt, watches);
    var gc_roots: [3]Value = .{ ref_val, watches, cur };
    var gc_sp: u16 = 3;
    var gc_frame: root_set.EvalFrame = .{ .stack = &gc_roots, .sp = &gc_sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;
    const loc: SourceLocation = .{};
    while (!cur.isNil()) {
        gc_roots[2] = cur;
        const key = list_mod.first(cur);
        const f = try map_mod.get(watches, key);
        const cb = [_]Value{ key, ref_val, old, new };
        _ = try vt.callFn(rt, env, f, &cb, loc);
        cur = list_mod.rest(cur);
    }
}
