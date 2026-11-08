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
const root_set = @import("../runtime/gc/root_set.zig");
const Reader = @import("reader.zig").Reader;
const analyzer = @import("analyzer/analyzer.zig");
const macro_dispatch = @import("macro_dispatch.zig");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const eval_budget_mod = @import("../runtime/concurrency/eval_budget.zig");
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const Value = @import("../runtime/value/value.zig").Value;
const tree_walk = @import("backend/tree_walk.zig");
const vm = @import("backend/vm.zig");
const vm_compiler = @import("backend/vm/compiler.zig");
const driver = @import("driver.zig");
const error_info = @import("../runtime/error/info.zig");

pub const CompareResult = struct {
    tree_walk: anyerror!Value,
    vm: anyerror!Value,
    /// `true` when both backends produced the same NaN-boxed bit pattern, or
    /// failed with the same Zig error.
    equal: bool,
    /// Source position of the error each backend raised; null when that
    /// backend returned a value. Only `line`/`column` are captured: the
    /// `file` field of a fixture-analysed form is "unknown" on both
    /// backends and carries no signal.
    tree_walk_loc: ?ErrorPos = null,
    vm_loc: ?ErrorPos = null,
    /// `true` when both backends agree on WHERE the failure is: neither
    /// raised, or both raised at the same line:column. The error half of
    /// the dual-backend contract (ADR-0036). A backend that raises the
    /// same Kind at 0:0 while the other reports 3:11 is a parity break,
    /// invisible to `equal` (which only compares returned Values).
    loc_equal: bool = true,
};

/// The comparable part of a raised error's `SourceLocation`.
pub const ErrorPos = struct {
    line: u32,
    column: u16,
};

/// The position of the error a just-finished backend run raised, or null
/// when the run returned a value. Reads the threadlocal payload without
/// clearing it, so the caller's own error handling still sees it; must be
/// called before the next run overwrites the slot. A run that failed
/// without publishing a payload (a user throw, OOM) reports 0:0, the same
/// position a dropped location has, rather than null ("did not raise").
fn errorPos(result: anyerror!Value) ?ErrorPos {
    _ = result catch {
        const info = error_info.peekLastError() orelse return .{ .line = 0, .column = 0 };
        return .{ .line = info.location.line, .column = info.location.column };
    };
    return null;
}

pub fn compare(
    rt: *Runtime,
    env: *Env,
    table: *const macro_dispatch.Table,
    arena: std.mem.Allocator,
    source: []const u8,
) CompareResult {
    // runOnce does not reset the threadlocal error slot, so clear it before
    // each run: a stale payload from an earlier raise must not be read as
    // this run's position.
    error_info.clearLastError();
    tree_walk.installVTable(rt);
    const tw_value = runOnce(rt, env, table, arena, source, .tree_walk);
    // Read the raise position NOW: the threadlocal payload is a single slot
    // that the VM run below overwrites.
    const tw_loc = errorPos(tw_value);

    error_info.clearLastError();
    vm.installVTable(rt);
    const vm_value = runOnce(rt, env, table, arena, source, .vm);
    const vm_loc = errorPos(vm_value);

    const equal = if (tw_value) |tw| blk: {
        const vm_v = vm_value catch break :blk false;
        break :blk @intFromEnum(tw) == @intFromEnum(vm_v);
    } else |tw_err| blk: {
        _ = vm_value catch |vm_err| break :blk tw_err == vm_err;
        break :blk false;
    };
    const loc_equal = if (tw_loc) |a|
        if (vm_loc) |b| a.line == b.line and a.column == b.column else false
    else
        vm_loc == null;
    return .{
        .tree_walk = tw_value,
        .vm = vm_value,
        .equal = equal,
        .tree_walk_loc = tw_loc,
        .vm_loc = vm_loc,
        .loc_equal = loc_equal,
    };
}

pub const BackendChoice = enum { tree_walk, vm };

pub fn installBackend(rt: *Runtime, backend: BackendChoice) void {
    switch (backend) {
        .tree_walk => tree_walk.installVTable(rt),
        .vm => vm.installVTable(rt),
    }
}

fn runOnce(
    rt: *Runtime,
    env: *Env,
    table: *const macro_dispatch.Table,
    arena: std.mem.Allocator,
    source: []const u8,
    backend: BackendChoice,
) anyerror!Value {
    return runOnceLabeled(rt, env, table, arena, source, "<compare>", backend);
}

pub fn runOnceLabeled(
    rt: *Runtime,
    env: *Env,
    table: *const macro_dispatch.Table,
    arena: std.mem.Allocator,
    source: []const u8,
    source_label: []const u8,
    backend: BackendChoice,
) anyerror!Value {
    var reader = Reader.init(arena, source);
    reader.file_name = source_label;
    var last: Value = .nil_val;
    while (true) {
        const form_opt = try reader.read();
        const form = form_opt orelse break;
        // D-374: unroll a top-level `(do …)` so the compare oracle exercises the
        // same per-child analyze+eval sequencing as the production eval paths.
        last = try evalTopLevelInBackend(rt, env, table, arena, form, backend);
    }
    return last;
}

/// Backend-parameterized twin of `driver.evalTopLevelForm` for the `--compare`
/// oracle (which pins a specific backend rather than `build_options.backend`).
fn evalTopLevelInBackend(
    rt: *Runtime,
    env: *Env,
    table: *const macro_dispatch.Table,
    arena: std.mem.Allocator,
    form: @import("form.zig").Form,
    backend: BackendChoice,
) anyerror!Value {
    if (driver.topLevelDoChildren(form)) |children| {
        var result: Value = .nil_val;
        for (children) |child| result = try evalTopLevelInBackend(rt, env, table, arena, child, backend);
        return result;
    }
    // D-430: analysis bracket (roots literals through eval) — the oracle
    // twin of driver.evalTopLevelForm's bracket.
    var af: root_set.AnalysisFrame = undefined;
    root_set.beginAnalysis(&af, rt.gc.infra);
    defer root_set.endAnalysisPersist(&af, &rt.gc);
    const node = try analyzer.analyze(arena, rt, env, null, form, table);
    var locals: [256]Value = [_]Value{.nil_val} ** 256;
    return switch (backend) {
        .tree_walk => blk: {
            // GC-ROOT: A6 — top-level locals window (the driver.evalForm twin).
            var gc_stack: [1]Value = .{.nil_val};
            var gc_sp: u16 = 0;
            var gc_frame: root_set.EvalFrame = .{
                .stack = &gc_stack,
                .sp = &gc_sp,
                .locals = &locals,
                .parent = root_set.eval_frame_head,
            };
            root_set.eval_frame_head = &gc_frame;
            defer root_set.eval_frame_head = gc_frame.parent;
            break :blk tree_walk.eval(rt, env, &locals, node);
        },
        .vm => blk: {
            const chunk = try vm_compiler.compile(rt, arena, node);
            break :blk vm.eval(rt, env, &locals, &chunk);
        },
    };
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

    // D-413: init in place — self-referential fixture (env.rt -> &rt,
    // rt.io -> &threaded) must not be moved by value. See diff_test.zig.
    fn init(f: *Fixture, alloc: std.mem.Allocator) !void {
        f.threaded = std.Io.Threaded.init(alloc, .{});
        f.rt = Runtime.init(f.threaded.io(), alloc);
        f.env = try Env.init(&f.rt);
        f.arena = std.heap.ArenaAllocator.init(alloc);
        f.table = macro_dispatch.Table.init(alloc);
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
    var f: Fixture = undefined;
    try Fixture.init(&f, testing.allocator);
    defer f.deinit();
    const r = compare(&f.rt, &f.env, &f.table, f.arena.allocator(), "42");
    try testing.expect(r.equal);
    try testing.expectEqual(@as(i64, 42), (try r.tree_walk).asInteger());
}

test "compare: if with both branches" {
    var f: Fixture = undefined;
    try Fixture.init(&f, testing.allocator);
    defer f.deinit();
    const r = compare(&f.rt, &f.env, &f.table, f.arena.allocator(), "(if true 1 2)");
    try testing.expect(r.equal);
    try testing.expectEqual(@as(i64, 1), (try r.tree_walk).asInteger());
}

test "compare: boolean and nil immediate Values" {
    var f1: Fixture = undefined;
    try Fixture.init(&f1, testing.allocator);
    defer f1.deinit();
    const r_true = compare(&f1.rt, &f1.env, &f1.table, f1.arena.allocator(), "true");
    try testing.expect(r_true.equal);

    var f2: Fixture = undefined;
    try Fixture.init(&f2, testing.allocator);
    defer f2.deinit();
    const r_nil = compare(&f2.rt, &f2.env, &f2.table, f2.arena.allocator(), "nil");
    try testing.expect(r_nil.equal);

    var f3: Fixture = undefined;
    try Fixture.init(&f3, testing.allocator);
    defer f3.deinit();
    const r_false = compare(&f3.rt, &f3.env, &f3.table, f3.arena.allocator(), "false");
    try testing.expect(r_false.equal);
}

test "compare: identical backend errors are agreement" {
    var f: Fixture = undefined;
    try Fixture.init(&f, testing.allocator);
    defer f.deinit();
    const r = compare(&f.rt, &f.env, &f.table, f.arena.allocator(), "missing-symbol");
    try testing.expect(r.equal);
    try testing.expectError(error.NameError, r.tree_walk);
    try testing.expectError(error.NameError, r.vm);
}

test "ADR-0125: a step budget kills an infinite loop under BOTH backends" {
    // Dual-backend parity (F-011): run each backend with a FRESH budget (the
    // counter must not carry across runs — DP4) and assert the same uncatchable
    // `resource_exhausted` outcome. `loop*` is the special form (no macro-table
    // dependency in the Fixture). The vm gate build covers the VM poll site;
    // the tree_walk build covers the loop* poll site — this test exercises both
    // regardless of the build's configured default.
    var f: Fixture = undefined;
    try Fixture.init(&f, testing.allocator);
    defer f.deinit();
    inline for (.{ BackendChoice.tree_walk, BackendChoice.vm }) |backend| {
        const b = try eval_budget_mod.EvalBudget.create(testing.allocator, .{ .step_ceiling = 50_000 });
        eval_budget_mod.current = b;
        defer eval_budget_mod.release(b);
        const r = runOnce(&f.rt, &f.env, &f.table, f.arena.allocator(), "(loop* [] (recur))", backend);
        try testing.expectError(error.ResourceExhausted, r);
    }
}
