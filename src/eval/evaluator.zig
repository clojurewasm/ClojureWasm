// SPDX-License-Identifier: EPL-2.0
//! Differential evaluator — runs the same source through both backends
//! and reports whether the produced Values match (ROADMAP §9.6 / 4.10,
//! ADR-0005, ADR-0022).
//!
//! `compare` is the gate's atomic unit. The caller supplies a fully
//! initialised `Runtime` + `Env` + macro `Table` (the caller's zone
//! owns primitive registration and macro registration — `evaluator`
//! cannot import `lang/*` per `zone_deps.md`). `compare` swaps the
//! vtable between runs so each backend sees its own dispatch table on
//! the same `Runtime`.
//!
//! `compare` cases must be **pure expressions** — anything that
//! mutates `env` (a top-level `def`) will leak from the first backend
//! run into the second. Heap-allocated Values (keywords / lists /
//! vectors / Functions) compare by NaN-boxed bit pattern, which
//! differs across separately allocated heap objects even when the
//! Clojure-level value matches. Adopting a `Value.eql`-based parity
//! check would widen the comparison; the gate uses bit-equality today.

const std = @import("std");
const Reader = @import("reader.zig").Reader;
const analyzer = @import("analyzer/analyzer.zig");
const macro_dispatch = @import("macro_dispatch.zig");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const Value = @import("../runtime/value/value.zig").Value;
const tree_walk = @import("backend/tree_walk.zig");
const vm = @import("backend/vm.zig");
const vm_compiler = @import("backend/vm/compiler.zig");

pub const CompareResult = struct {
    tree_walk: anyerror!Value,
    vm: anyerror!Value,
    /// `true` when both backends succeeded AND produced the same
    /// NaN-boxed bit pattern. See module docstring for the
    /// immediate-Value caveat.
    equal: bool,
};

pub fn compare(
    rt: *Runtime,
    env: *Env,
    table: *const macro_dispatch.Table,
    arena: std.mem.Allocator,
    source: []const u8,
) CompareResult {
    tree_walk.installVTable(rt);
    const tw_value = runOnce(rt, env, table, arena, source, .tree_walk);

    vm.installVTable(rt);
    const vm_value = runOnce(rt, env, table, arena, source, .vm);

    const equal = blk: {
        const tw = tw_value catch break :blk false;
        const vm_v = vm_value catch break :blk false;
        break :blk @intFromEnum(tw) == @intFromEnum(vm_v);
    };
    return .{ .tree_walk = tw_value, .vm = vm_value, .equal = equal };
}

const BackendChoice = enum { tree_walk, vm };

fn runOnce(
    rt: *Runtime,
    env: *Env,
    table: *const macro_dispatch.Table,
    arena: std.mem.Allocator,
    source: []const u8,
    backend: BackendChoice,
) anyerror!Value {
    var reader = Reader.init(arena, source);
    var last: Value = .nil_val;
    while (true) {
        const form_opt = try reader.read();
        const form = form_opt orelse break;
        const node = try analyzer.analyze(arena, rt, env, null, form, table);
        var locals: [256]Value = [_]Value{.nil_val} ** 256;
        last = switch (backend) {
            .tree_walk => try tree_walk.eval(rt, env, &locals, node),
            .vm => blk: {
                const chunk = try vm_compiler.compile(rt, arena, node);
                break :blk try vm.eval(rt, env, &locals, &chunk);
            },
        };
    }
    return last;
}

// --- tests ---

const testing = std.testing;

/// Local fixture: builds a self-contained rt+env+table+arena suitable
/// for one-shot compare cases. Heap state is reset per call (each
/// caller `defer fix.deinit()`).
const Fixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,
    env: Env,
    arena: std.heap.ArenaAllocator,
    table: macro_dispatch.Table,

    fn init(alloc: std.mem.Allocator) !Fixture {
        var f: Fixture = undefined;
        f.threaded = std.Io.Threaded.init(alloc, .{});
        f.rt = Runtime.init(f.threaded.io(), alloc);
        f.env = try Env.init(&f.rt);
        f.arena = std.heap.ArenaAllocator.init(alloc);
        f.table = macro_dispatch.Table.init(alloc);
        return f;
    }

    fn deinit(self: *Fixture) void {
        self.table.deinit();
        self.arena.deinit();
        self.env.deinit();
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "compare: integer literal" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    const r = compare(&f.rt, &f.env, &f.table, f.arena.allocator(), "42");
    try testing.expect(r.equal);
    try testing.expectEqual(@as(i64, 42), (try r.tree_walk).asInteger());
}

test "compare: if with both branches" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    const r = compare(&f.rt, &f.env, &f.table, f.arena.allocator(), "(if true 1 2)");
    try testing.expect(r.equal);
    try testing.expectEqual(@as(i64, 1), (try r.tree_walk).asInteger());
}

test "compare: boolean and nil immediate Values" {
    var f1 = try Fixture.init(testing.allocator);
    defer f1.deinit();
    const r_true = compare(&f1.rt, &f1.env, &f1.table, f1.arena.allocator(), "true");
    try testing.expect(r_true.equal);

    var f2 = try Fixture.init(testing.allocator);
    defer f2.deinit();
    const r_nil = compare(&f2.rt, &f2.env, &f2.table, f2.arena.allocator(), "nil");
    try testing.expect(r_nil.equal);

    var f3 = try Fixture.init(testing.allocator);
    defer f3.deinit();
    const r_false = compare(&f3.rt, &f3.env, &f3.table, f3.arena.allocator(), "false");
    try testing.expect(r_false.equal);
}

test "ADR-0125: a step budget kills an infinite loop under BOTH backends" {
    // Dual-backend parity (F-011): run each backend with a FRESH budget (the
    // counter must not carry across runs — DP4) and assert the same uncatchable
    // `resource_exhausted` outcome. `loop*` is the special form (no macro-table
    // dependency in the Fixture). The vm gate build covers the VM poll site;
    // the tree_walk build covers the loop* poll site — this test exercises both
    // regardless of the build's configured default.
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();
    inline for (.{ BackendChoice.tree_walk, BackendChoice.vm }) |backend| {
        f.rt.eval_budget = .{ .step_ceiling = 50_000 };
        const r = runOnce(&f.rt, &f.env, &f.table, f.arena.allocator(), "(loop* [] (recur))", backend);
        try testing.expectError(error.ResourceExhausted, r);
    }
    f.rt.eval_budget = null;
}
