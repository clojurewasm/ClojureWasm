//! Macro dispatch — Layer-1 entry point for macro expansion.
//!
//! ADR 0001 routes macro expansion through this module instead of
//! through `runtime/dispatch.VTable`. The analyzer holds a
//! `*const Table` and consults it from `analyzeList` whenever a list
//! head resolves to a Var with `flags.macro_` set.
//!
//! ### Why a Table, not a vtable
//!
//! Macros are not a single-function dispatch (the way `callFn` is) —
//! they are a name → impl mapping. Modeling that as a `StringHashMap`
//! is direct; modeling it as a vtable would require a discriminator
//! enum and a switch. The Table is also runtime-mutable, which is what
//! we need at Phase 3.12 when `(defmacro foo ...)` registers a
//! user-defined macro at eval time (the user-fn fallback below).
//!
//! ### Form-level expansion, not Value-level
//!
//! Zig-level transforms operate on `Form` (the analyzer's input AST),
//! not `Value` (the runtime data model). That keeps locations
//! attached, avoids Form↔Value round-trips for static cases, and
//! matches v1's organization. The Form↔Value boundary lives only at
//! the user-fn invocation site (deferred to Phase 3.12).

const std = @import("std");
const Form = @import("form.zig").Form;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const Var = env_mod.Var;
const error_mod = @import("../runtime/error.zig");
const SourceLocation = error_mod.SourceLocation;

/// Signature of a Zig-level macro transform. Receives the call-site
/// argument forms (the head symbol has already been stripped) and
/// returns a fresh Form built in `arena`. `rt` is provided so the
/// transform can call `rt.gensym(...)` for hygienic auto-symbols
/// (used by `and` / `or` / `if-let` / `when-let`).
///
/// Errors should be reported via `error_mod.setErrorFmt(.macroexpand,
/// kind, loc, ...)` so the renderer attributes them to the call site.
/// The return error set is `error_mod.Error` (the wide tag set used
/// throughout the analyzer) so call sites in `analyze` can `try` the
/// result without a type widen — see `reader.ReadError` /
/// `analyzer.AnalyzeError` for the same pattern.
pub const ExpandError = error_mod.Error;
pub const ZigExpandFn = *const fn (
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) ExpandError!Form;

/// Static-name → impl table. The analyzer holds a `*const Table` and
/// looks up by the head symbol's local name. Owned by `main.zig`
/// (Layer 3); populated once at startup by
/// `lang.macro_transforms.registerInto`.
pub const Table = struct {
    entries: std.StringHashMapUnmanaged(ZigExpandFn) = .empty,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Table {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Table) void {
        self.entries.deinit(self.alloc);
    }

    /// Register a Zig-level transform under `name`. Names must be
    /// unique; double-registration is a programmer error and asserts
    /// in debug. The `name` slice is borrowed (it's expected to be a
    /// string literal owned by `lang/macro_transforms.zig`).
    pub fn register(self: *Table, name: []const u8, f: ZigExpandFn) !void {
        const gop = try self.entries.getOrPut(self.alloc, name);
        std.debug.assert(!gop.found_existing); // double-registration bug
        gop.value_ptr.* = f;
    }

    pub fn lookup(self: *const Table, name: []const u8) ?ZigExpandFn {
        return self.entries.get(name);
    }
};

/// Try to expand a macro call. Returns `null` if `head_var` is not a
/// macro. Returns a freshly allocated Form (owned by `arena`) when
/// expansion succeeds. Phase 3.12 will extend this to fall through to
/// `vtable.callFn` for user-defined `defmacro`; for now, a macro Var
/// without a Zig-table entry produces a clean `not_implemented` error.
pub fn expandIfMacro(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    table: *const Table,
    head_var: *const Var,
    head_name: []const u8,
    args: []const Form,
    loc: SourceLocation,
) ExpandError!?Form {
    _ = env; // unused until Phase 3.12 user-fn path
    if (!head_var.flags.macro_) return null;
    if (table.lookup(head_name)) |f| {
        return try f(arena, rt, args, loc);
    }
    return error_mod.setErrorFmt(
        .macroexpand,
        .not_implemented,
        loc,
        "User-defined macro '{s}' cannot be expanded yet (Phase 3.12+)",
        .{head_name},
    );
}

// --- Form construction helpers (for macro impls) ---
//
// These keep `lang/macro_transforms.zig` readable by hiding the
// boilerplate of allocating Forms in an arena. They live here, not in
// `form.zig`, because they exist to serve macroexpansion specifically
// (other Form callers — Reader, printer — don't need them).

/// Build an `(items...)` list Form, all entries inheriting `loc`.
pub fn makeList(arena: std.mem.Allocator, items: []const Form, loc: SourceLocation) !Form {
    const owned = try arena.dupe(Form, items);
    return .{ .data = .{ .list = owned }, .location = loc };
}

/// Build a `[items...]` vector Form.
pub fn makeVector(arena: std.mem.Allocator, items: []const Form, loc: SourceLocation) !Form {
    const owned = try arena.dupe(Form, items);
    return .{ .data = .{ .vector = owned }, .location = loc };
}

/// Build a bare-name symbol Form (no namespace).
pub fn makeSymbol(name: []const u8, loc: SourceLocation) Form {
    return .{ .data = .{ .symbol = .{ .name = name } }, .location = loc };
}

/// Build a nil literal Form.
pub fn makeNil(loc: SourceLocation) Form {
    return .{ .data = .nil, .location = loc };
}

/// Build a boolean literal Form.
pub fn makeBool(b: bool, loc: SourceLocation) Form {
    return .{ .data = .{ .boolean = b }, .location = loc };
}

// --- tests ---

const testing = std.testing;

fn dummyExpand(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) ExpandError!Form {
    _ = rt;
    _ = args;
    // Return a constant `true` Form to confirm the dispatch wired up.
    _ = arena;
    return makeBool(true, loc);
}

test "Table.register and lookup roundtrip" {
    var t = Table.init(testing.allocator);
    defer t.deinit();
    try t.register("dummy", dummyExpand);
    try testing.expect(t.lookup("dummy") != null);
    try testing.expect(t.lookup("absent") == null);
}

test "expandIfMacro returns null for non-macro Var" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try Env.init(&rt);
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var table = Table.init(testing.allocator);
    defer table.deinit();

    const ns_a = env.current_ns.?;
    var v: Var = .{ .ns = ns_a, .name = "ordinary", .flags = .{} };

    const result = try expandIfMacro(
        arena.allocator(),
        &rt,
        &env,
        &table,
        &v,
        "ordinary",
        &.{},
        .{},
    );
    try testing.expect(result == null);
}

test "expandIfMacro dispatches a registered Zig transform" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try Env.init(&rt);
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var table = Table.init(testing.allocator);
    defer table.deinit();
    try table.register("dummy", dummyExpand);

    var v: Var = .{ .ns = env.current_ns.?, .name = "dummy", .flags = .{ .macro_ = true } };

    const expanded = try expandIfMacro(
        arena.allocator(),
        &rt,
        &env,
        &table,
        &v,
        "dummy",
        &.{},
        .{},
    );
    try testing.expect(expanded != null);
    try testing.expect(expanded.?.data == .boolean);
    try testing.expect(expanded.?.data.boolean == true);
}

test "expandIfMacro errors cleanly for macro Var with no Zig impl" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try Env.init(&rt);
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var table = Table.init(testing.allocator);
    defer table.deinit();

    var v: Var = .{ .ns = env.current_ns.?, .name = "user-defined", .flags = .{ .macro_ = true } };

    const got = expandIfMacro(
        arena.allocator(),
        &rt,
        &env,
        &table,
        &v,
        "user-defined",
        &.{},
        .{ .file = "<t>", .line = 1, .column = 0 },
    );
    try testing.expectError(error.NotImplemented, got);
    const info = error_mod.peekLastError() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(error_mod.Phase.macroexpand, info.phase);
    try testing.expectEqual(error_mod.Kind.not_implemented, info.kind);
}
