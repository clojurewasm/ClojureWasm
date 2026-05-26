// SPDX-License-Identifier: EPL-2.0
//! Multimethod primitives for the `rt/` namespace.
//!
//! Per ADR-0008 Phase 7.2 amendment (Alt 1) — `defmulti` /
//! `defmethod` / `prefer-method` lower to these Layer-2 primitives
//! plus a `def`; no special analyzer Node is involved. The
//! primitives mutate the underlying MultiFn struct in place and
//! reset `method_cache` when the table or prefer ordering shifts.

const std = @import("std");
const value = @import("../../runtime/value/value.zig");
const Value = value.Value;
const HeapHeader = value.HeapHeader;
const HeapTag = value.HeapTag;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const map_mod = @import("../../runtime/collection/map.zig");
const multimethod_mod = @import("../../runtime/multimethod.zig");
const symbol_mod = @import("../../runtime/symbol.zig");

const MultiFn = multimethod_mod.MultiFn;

fn expectMultiFn(arg: Value, loc: SourceLocation) anyerror!*MultiFn {
    if (arg.tag() != .multi_fn) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "multimethod-primitive",
            .expected = "multi_fn",
            .actual = @tagName(arg.tag()),
        });
    }
    return arg.decodePtr(*MultiFn);
}

/// `(rt/__make-multifn name dispatch-fn default-val)` — allocate a
/// fresh MultiFn Value. `name` is the user-visible symbol
/// (`'my-fn`); `dispatch-fn` is the function that produces the
/// dispatch value from call args; `default-val` is the dispatch
/// value used when no method matches (Clojure's `:default`).
/// `hierarchy_ref` defaults to nil (= no per-instance hierarchy;
/// the global hierarchy is consulted at the Clojure layer).
pub fn makeMultiFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__make-multifn", args, 3, loc);
    if (args[0].tag() != .symbol) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "__make-multifn",
            .expected = "symbol",
            .actual = @tagName(args[0].tag()),
        });
    }
    const mf = try rt.gc.alloc(MultiFn);
    mf.* = .{
        .header = HeapHeader.init(.multi_fn),
        .name = args[0],
        .dispatch_fn = args[1],
        .default_dispatch_val = args[2],
        .hierarchy_ref = Value.nil_val,
        .method_table = map_mod.empty(),
        .prefer_table = map_mod.empty(),
        .method_cache = map_mod.empty(),
        .cached_hierarchy_snapshot = Value.nil_val,
    };
    return Value.encodeHeapPtr(.multi_fn, mf);
}

/// `(rt/__add-method! mf dispatch-val method-fn)` — mutate `mf`'s
/// method_table to bind `dispatch-val → method-fn`. Resets
/// method_cache because the resolution surface changed (mirrors
/// JVM `MultiFn.addMethod` which calls `resetCache()` inline).
/// Returns `mf`.
pub fn addMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__add-method!", args, 3, loc);
    const mf = try expectMultiFn(args[0], loc);
    mf.method_table = try map_mod.assoc(rt, mf.method_table, args[1], args[2]);
    mf.method_cache = map_mod.empty();
    return args[0];
}

/// `(rt/__remove-method! mf dispatch-val)` — mutate `mf`'s
/// method_table to remove `dispatch-val`. Resets method_cache.
/// Returns `mf`.
pub fn removeMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__remove-method!", args, 2, loc);
    const mf = try expectMultiFn(args[0], loc);
    mf.method_table = try map_mod.dissoc(rt, mf.method_table, args[1]);
    mf.method_cache = map_mod.empty();
    return args[0];
}

/// `(rt/__prefer-method! mf x y)` — record that `x` is preferred
/// over `y` (i.e. `(prefer-method f x y)`). Mutates `mf`'s
/// prefer_table; resets method_cache.  Returns `mf`.
pub fn preferMethod(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__prefer-method!", args, 3, loc);
    const mf = try expectMultiFn(args[0], loc);
    const set_mod = @import("../../runtime/collection/set.zig");

    // prefer_table[x] = existing-set ∪ {y}; create the set if missing.
    const existing = try map_mod.get(mf.prefer_table, args[1]);
    var preferred_over: Value = if (existing.tag() == .hash_set) existing else set_mod.empty();
    preferred_over = try set_mod.conj(rt, preferred_over, args[2]);

    mf.prefer_table = try map_mod.assoc(rt, mf.prefer_table, args[1], preferred_over);
    mf.method_cache = map_mod.empty();
    return args[0];
}

/// `(rt/__methods mf)` — return the multimethod's method_table.
pub fn methods(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("__methods", args, 1, loc);
    const mf = try expectMultiFn(args[0], loc);
    return mf.method_table;
}

/// `(rt/__get-method mf dispatch-val)` — return the resolved
/// method Value for `dispatch-val` or nil if no method matches.
/// Mirrors `clojure.core/get-method` (returns nil rather than
/// raising on no-match — differs from internal `getMethod` which
/// raises). Suppresses the multimethod_no_method raise via the
/// no-method → nil convention.
pub fn getMethodPrim(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__get-method", args, 2, loc);
    const mf = try expectMultiFn(args[0], loc);
    return multimethod_mod.getMethod(rt, mf, args[1], loc) catch |err| switch (err) {
        error.ValueError => return Value.nil_val,
        else => return err,
    };
}

/// `(rt/__prefers mf)` — return the multimethod's prefer_table.
pub fn prefers(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("__prefers", args, 1, loc);
    const mf = try expectMultiFn(args[0], loc);
    return mf.prefer_table;
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value,
};

const ENTRIES = [_]Entry{
    .{ .name = "__make-multifn", .f = &makeMultiFn },
    .{ .name = "__add-method!", .f = &addMethod },
    .{ .name = "__remove-method!", .f = &removeMethod },
    .{ .name = "__prefer-method!", .f = &preferMethod },
    .{ .name = "__methods", .f = &methods },
    .{ .name = "__get-method", .f = &getMethodPrim },
    .{ .name = "__prefers", .f = &prefers },
};

pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}

// --- tests ---

const testing = std.testing;
const keyword = @import("../../runtime/keyword.zig");

const TestFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,
    env: Env,

    fn init(self: *TestFixture, alloc: std.mem.Allocator) !void {
        self.threaded = std.Io.Threaded.init(alloc, .{});
        self.rt = Runtime.init(self.threaded.io(), alloc);
        self.env = try Env.init(&self.rt);
    }

    fn deinit(self: *TestFixture) void {
        self.env.deinit();
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "__make-multifn allocates a MultiFn Value with the given name + default" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const name = try symbol_mod.intern(&fix.rt, null, "my-fn");
    const default_kw = try keyword.intern(&fix.rt, null, "default");

    const result = try makeMultiFn(&fix.rt, &fix.env, &[_]Value{ name, Value.nil_val, default_kw }, .{});
    try testing.expect(result.tag() == .multi_fn);

    const mf = result.decodePtr(*MultiFn);
    try testing.expectEqual(@intFromEnum(name), @intFromEnum(mf.name));
    try testing.expectEqual(@intFromEnum(default_kw), @intFromEnum(mf.default_dispatch_val));
}

test "__add-method! mutates method_table and clears method_cache" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const name = try symbol_mod.intern(&fix.rt, null, "my-fn");
    const default_kw = try keyword.intern(&fix.rt, null, "default");
    const multi = try makeMultiFn(&fix.rt, &fix.env, &[_]Value{ name, Value.nil_val, default_kw }, .{});
    const mf = multi.decodePtr(*MultiFn);

    const kw_a = try keyword.intern(&fix.rt, null, "a");
    const m_a = try keyword.intern(&fix.rt, null, "method-a");

    // Seed the cache to verify add-method! resets it.
    mf.method_cache = try map_mod.assoc(&fix.rt, map_mod.empty(), kw_a, m_a);
    try testing.expectEqual(@as(u32, 1), map_mod.count(mf.method_cache));

    _ = try addMethod(&fix.rt, &fix.env, &[_]Value{ multi, kw_a, m_a }, .{});

    const installed = try map_mod.get(mf.method_table, kw_a);
    try testing.expectEqual(@intFromEnum(m_a), @intFromEnum(installed));
    try testing.expectEqual(@as(u32, 0), map_mod.count(mf.method_cache));
}

test "__get-method returns the method on a known dispatch_val" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const name = try symbol_mod.intern(&fix.rt, null, "my-fn");
    const default_kw = try keyword.intern(&fix.rt, null, "default");
    const multi = try makeMultiFn(&fix.rt, &fix.env, &[_]Value{ name, Value.nil_val, default_kw }, .{});

    const kw_a = try keyword.intern(&fix.rt, null, "a");
    const m_a = try keyword.intern(&fix.rt, null, "method-a");
    _ = try addMethod(&fix.rt, &fix.env, &[_]Value{ multi, kw_a, m_a }, .{});

    const got = try getMethodPrim(&fix.rt, &fix.env, &[_]Value{ multi, kw_a }, .{});
    try testing.expectEqual(@intFromEnum(m_a), @intFromEnum(got));
}

test "__get-method returns nil when no method matches" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const name = try symbol_mod.intern(&fix.rt, null, "my-fn");
    const default_kw = try keyword.intern(&fix.rt, null, "default");
    const multi = try makeMultiFn(&fix.rt, &fix.env, &[_]Value{ name, Value.nil_val, default_kw }, .{});

    const kw_missing = try keyword.intern(&fix.rt, null, "missing");
    const got = try getMethodPrim(&fix.rt, &fix.env, &[_]Value{ multi, kw_missing }, .{});
    try testing.expect(got.isNil());
}

test "__remove-method! removes an entry and resets cache" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const name = try symbol_mod.intern(&fix.rt, null, "my-fn");
    const default_kw = try keyword.intern(&fix.rt, null, "default");
    const multi = try makeMultiFn(&fix.rt, &fix.env, &[_]Value{ name, Value.nil_val, default_kw }, .{});
    const mf = multi.decodePtr(*MultiFn);

    const kw_a = try keyword.intern(&fix.rt, null, "a");
    const m_a = try keyword.intern(&fix.rt, null, "method-a");
    _ = try addMethod(&fix.rt, &fix.env, &[_]Value{ multi, kw_a, m_a }, .{});
    try testing.expectEqual(@as(u32, 1), map_mod.count(mf.method_table));

    _ = try removeMethod(&fix.rt, &fix.env, &[_]Value{ multi, kw_a }, .{});
    try testing.expectEqual(@as(u32, 0), map_mod.count(mf.method_table));
}
