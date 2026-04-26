//! Env — namespace graph + Var registry + dynamic-binding stack.
//!
//! Phase 2.1 ships only the **skeleton**: an `Env.init(rt)` that
//! constructs an empty namespace map, plus `Env.deinit`. This is
//! enough for `dispatch.zig` and `runtime.zig` to compile and for
//! their tests to run. Phase 2.3 fills in `Namespace`, `Var`, the
//! threadlocal `current_frame` binding stack, and the `findNs` /
//! `referAll` operations the analyzer + bootstrap rely on.
//!
//! Splitting this way is forced by the import graph: `dispatch.VTable`
//! takes `*Runtime` and `*Env`, and `Runtime` carries `vtable: ?VTable`,
//! so all three files must compile in one commit. Leaving Env at the
//! minimum compilable shape keeps Phase 2.1 a single, small landing.
//!
//! ### Architecture (the full picture)
//!
//! - **Runtime** (`runtime.zig`): process-wide. io / gpa / keywords / vtable.
//! - **Env** (this file): per CLI invocation or per nREPL session.
//!   namespace graph + current_ns. Multiple Envs can share one Runtime.
//! - **threadlocal** (this file, from 2.3): the binding-frame chain
//!   for Clojure's `(binding [*foo* 42] body)` semantics.

const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;

/// Per-session container.
///
/// **Phase 2.1**: just owns its allocator (= `rt.gpa`) and a
/// process-lifetime back-reference to Runtime. The `namespaces` map
/// is empty. Phase 2.3 extends with `Namespace` / `Var` / `findNs` /
/// `referAll`.
pub const Env = struct {
    rt: *Runtime,
    /// Allocator used for namespace tables and Var allocations.
    /// Aliased to `rt.gpa`; held as a separate field so callers can
    /// pass `env.alloc` directly.
    alloc: std.mem.Allocator,

    pub fn init(rt: *Runtime) !Env {
        return .{ .rt = rt, .alloc = rt.gpa };
    }

    pub fn deinit(self: *Env) void {
        // Phase 2.3 will free the namespace map's contents here.
        _ = self;
    }
};

// --- tests ---

const testing = std.testing;

test "Env.init / deinit on a Runtime" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();

    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    var env = try Env.init(&rt);
    defer env.deinit();

    try testing.expectEqual(&rt, env.rt);
    try testing.expect(env.alloc.ptr == testing.allocator.ptr);
}

test "Two Envs can share one Runtime" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();

    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    var env_a = try Env.init(&rt);
    defer env_a.deinit();
    var env_b = try Env.init(&rt);
    defer env_b.deinit();

    try testing.expectEqual(env_a.rt, env_b.rt);
}
