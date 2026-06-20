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
//! `(defmacro foo ...)` needs to register a user-defined macro at eval
//! time (the user-fn fallback below).
//!
//! ### Form-level expansion, not Value-level
//!
//! Zig-level transforms operate on `Form` (the analyzer's input AST),
//! not `Value` (the runtime data model). That keeps locations
//! attached, avoids Form↔Value round-trips for static cases, and
//! matches v1's organization. The Form↔Value boundary lives only at
//! the user-fn invocation site.

const std = @import("std");
const Form = @import("form.zig").Form;
const Value = @import("../runtime/value/value.zig").Value;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const Var = env_mod.Var;
const error_mod = @import("../runtime/error/info.zig");
const error_catalog = @import("../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const list_collection = @import("../runtime/collection/list.zig");

/// Signature of a Zig-level macro transform. Receives the call-site
/// argument forms (the head symbol has already been stripped) and
/// returns a fresh Form built in `arena`. `rt` is provided so the
/// transform can call `rt.gensym(...)` for hygienic auto-symbols
/// (used by `and` / `or` / `if-let` / `when-let`).
///
/// Errors should be reported via `error_catalog.raise(.code, loc,
/// args)` so the renderer attributes them to the call site and the
/// template stays in the catalog SSOT. The return error set is
/// `error_mod.ClojureWasmError` (the wide tag set used throughout the
/// analyzer) so call sites in `analyze` can `try` the result without
/// a type widen — see `reader.ReadError` / `analyzer.AnalyzeError`
/// for the same pattern.
pub const ExpandError = error_mod.ClojureWasmError;
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
/// expansion succeeds. A macro Var with a Zig-table entry expands via
/// that entry; otherwise it falls through to `vtable.callFn` for a
/// user-defined `defmacro` (the fallback below).
pub fn expandIfMacro(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    table: *const Table,
    head_var: *const Var,
    head_name: []const u8,
    args: []const Form,
    call_form: Form,
    scope: ?*const @import("analyzer/analyzer.zig").Scope,
    loc: SourceLocation,
) ExpandError!?Form {
    if (!head_var.flags.macro_) return null;
    // D-476 nil-root gate: a builtin macro is a nil-root marker (table); a user/
    // lib macro has a callable root and must run its own body even if it shadows
    // a builtin name. Consult the table only for marker Vars.
    const macro_fn = head_var.deref();
    if (!isCallable(macro_fn)) {
        if (table.lookup(head_name)) |f| return try f(arena, rt, args, loc);
        return error_catalog.raise(.macro_var_not_callable, loc, .{ .name = head_name });
    }
    // D-099: user-defined `defmacro` fallback. We run the args through
    // `formToValue` → callFn → `valueToForm` to round-trip the call through the
    // runtime's evaluator. The implicit `&form` / `&env` Values are prepended
    // (ADR-0086): the lowered macro fn's params are `[&form &env & user-params]`.
    const analyzer_mod = @import("analyzer/analyzer.zig");
    // `&form` = the call form as a Value, with `{:line :column}` meta
    // synthesized from the call site (cljw Forms are metadata-less per
    // ADR-0037, so the meta is attached to the list Value here).
    const amp_form = try buildAmpForm(arena, rt, env, call_form, loc);
    // `&env` = a map of the in-scope local symbols (key = value = symbol;
    // no LocalBinding class per ADR-0059); `{}` at top level.
    const amp_env = try buildAmpEnv(arena, rt, env, scope, loc);
    // [&form &env & user-args]. The analyzer's per-call arena owns the
    // slice; the Values themselves live on rt's GC heap.
    var value_args = try arena.alloc(Value, args.len + 2);
    value_args[0] = amp_form;
    value_args[1] = amp_env;
    for (args, 0..) |arg, i| {
        value_args[i + 2] = try analyzer_mod.formToValue(rt, env, arg);
    }
    const vtable = rt.vtable orelse
        return error_catalog.raiseInternal(loc, "expandIfMacro: rt.vtable not installed");
    // vtable.callFn returns `anyerror!Value`; narrow to our analyzer-
    // facing ClojureWasmError envelope. The side-channel error info
    // is already populated by the callee, so re-raising preserves
    // attribution.
    const result_val = vtable.callFn(rt, env, macro_fn, value_args, loc) catch |e|
        return narrowCallFnError(e, loc);
    return analyzer_mod.valueToForm(arena, rt, env, result_val, loc) catch |e| return narrowCallFnError(e, loc);
}

/// Build the implicit `&form` Value (ADR-0086): the macro call form as a list
/// Value carrying `{:line :column}` metadata synthesized from the call site
/// (cljw list Values carry meta even though symbols do not — ADR-0037).
fn buildAmpForm(arena: std.mem.Allocator, rt: *Runtime, env: *Env, call_form: Form, loc: SourceLocation) ExpandError!Value {
    const analyzer_mod = @import("analyzer/analyzer.zig");
    const form_val = try analyzer_mod.formToValue(rt, env, call_form);
    const meta_pairs = try arena.alloc(Form, 4);
    meta_pairs[0] = .{ .data = .{ .keyword = .{ .name = "line" } }, .location = loc };
    meta_pairs[1] = .{ .data = .{ .integer = @intCast(call_form.location.line) }, .location = loc };
    meta_pairs[2] = .{ .data = .{ .keyword = .{ .name = "column" } }, .location = loc };
    meta_pairs[3] = .{ .data = .{ .integer = @intCast(call_form.location.column) }, .location = loc };
    const meta_val = try analyzer_mod.formToValue(rt, env, .{ .data = .{ .map = meta_pairs }, .location = loc });
    if (form_val.tag() == .list)
        return list_collection.withMeta(rt, form_val, meta_val) catch |e| return narrowCallFnError(e, loc);
    return form_val;
}

/// Build the implicit `&env` Value (ADR-0086): a map of the in-scope local
/// symbols (key = value = the symbol; no LocalBinding class per ADR-0059, and
/// the JVM value is an opaque non-reproducible `LocalBinding` anyway). `nil`
/// when there are no in-scope locals (clj-verified: top-level + `(let [] …)`
/// both yield nil, not `{}`). Keys include destructuring temps, matching JVM
/// `&env` (oracle-verified) — only the temp NAMES differ (opaque divergence).
fn buildAmpEnv(arena: std.mem.Allocator, rt: *Runtime, env: *Env, scope: ?*const @import("analyzer/analyzer.zig").Scope, loc: SourceLocation) ExpandError!Value {
    const analyzer_mod = @import("analyzer/analyzer.zig");
    const Scope = analyzer_mod.Scope;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var cur: ?*const Scope = scope;
    while (cur) |s| : (cur = s.parent) {
        var it = s.bindings.keyIterator();
        while (it.next()) |k| {
            const gop = try seen.getOrPut(arena, k.*);
            if (!gop.found_existing) try names.append(arena, k.*);
        }
    }
    if (names.items.len == 0) return Value.nil_val;
    const pairs = try arena.alloc(Form, names.items.len * 2);
    for (names.items, 0..) |nm, i| {
        pairs[i * 2] = makeSymbol(nm, loc);
        pairs[i * 2 + 1] = makeSymbol(nm, loc);
    }
    return analyzer_mod.formToValue(rt, env, .{ .data = .{ .map = pairs }, .location = loc });
}

/// Narrow `anyerror` (from `vtable.callFn`) to the analyzer-facing
/// `ClojureWasmError` envelope. Shared with `analyzer.liftTagged`
/// (ADR-0073 data-reader fn application) — both invoke a user fn via the
/// vtable from analyze-time and must re-raise inside the narrow set.
pub fn narrowCallFnError(e: anyerror, loc: SourceLocation) ExpandError {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.SyntaxError => error.SyntaxError,
        error.NumberError => error.NumberError,
        error.StringError => error.StringError,
        error.NameError => error.NameError,
        error.ArityError => error.ArityError,
        error.ValueError => error.ValueError,
        error.NotImplemented => error.NotImplemented,
        error.TypeError => error.TypeError,
        error.ArithmeticError => error.ArithmeticError,
        error.IndexError => error.IndexError,
        error.IoError => error.IoError,
        error.InternalError => error.InternalError,
        // Anything outside the ClojureWasmError envelope (e.g. a Zig-
        // level error tag the runtime synthesised) lands as
        // InternalError so the AnalyzeError surface stays narrow.
        else => error_catalog.raiseInternal(loc, "macro callFn raised foreign error"),
    };
}

fn isCallable(v: Value) bool {
    return switch (v.tag()) {
        .fn_val, .builtin_fn, .protocol_fn, .multi_fn => true,
        else => false,
    };
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
        makeSymbol("ordinary", .{}),
        null,
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
        makeSymbol("dummy", .{}),
        null,
        .{},
    );
    try testing.expect(expanded != null);
    try testing.expect(expanded.?.data == .boolean);
    try testing.expect(expanded.?.data.boolean == true);
}

test "expandIfMacro raises macro_var_not_callable when root is not a fn" {
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

    // D-099: a macro Var with no callable root falls through
    // the user-fn fallback's isCallable check and surfaces a clean
    // type_error. Earlier (pre-D-099) this raised
    // `user_macro_not_supported` regardless of root shape.
    var v: Var = .{ .ns = env.current_ns.?, .name = "user-defined", .flags = .{ .macro_ = true } };

    const got = expandIfMacro(
        arena.allocator(),
        &rt,
        &env,
        &table,
        &v,
        "user-defined",
        &.{},
        makeSymbol("user-defined", .{}),
        null,
        .{ .file = "<t>", .line = 1, .column = 0 },
    );
    try testing.expectError(error.TypeError, got);
    const info = error_mod.peekLastError() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(error_mod.Phase.macroexpand, info.phase);
    try testing.expectEqual(error_mod.Kind.type_error, info.kind);
}
