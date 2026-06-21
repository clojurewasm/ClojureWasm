// SPDX-License-Identifier: EPL-2.0
//! EXPERIMENT (D-404 / ADR-0135) — Wasm component introspection + typed invoke.
//! `(wasm/component-exports "p.wasm")` lists a component's typed func exports;
//! `(wasm/component-invoke "p.wasm" "func" & args)` lowers cljw values per the
//! export's WIT signature, invokes through zwasm's Canonical ABI, and lifts the
//! result tree back to Clojure data per the ADR-0135 mapping.
//!
//! EXPLORATION MODE: rides the LOCAL relative-path zwasm dep (build.zig.zon
//! flip, uncommitted, push-suppressed). Adopts the finished-form zwasm CM-API
//! (pin 5795c3d0): `comp.open`→`Opened` (REQ-1), `resolveFuncSig`/`WitType`
//! (REQ-3, replaces the old hand-rolled TypeCtx), label-carrying enum/variant/
//! flags values (REQ-2). The finished form (require-a-component → one Var per
//! export) lands per D-404 once stable.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: wasm/component-exports, wasm/component-invoke

const std = @import("std");
const zwasm = @import("zwasm");
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const Value = @import("../../value/value.zig").Value;
const error_catalog = @import("../../error/catalog.zig");
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const string_mod = @import("../../collection/string.zig");
const vector_mod = @import("../../collection/vector.zig");
const map_mod = @import("../../collection/map.zig");
const set_mod = @import("../../collection/set.zig");
const keyword_mod = @import("../../keyword.zig");
const file_io = @import("../../file_io.zig");
const host_instance = @import("../../host_instance.zig");
const type_descriptor = @import("../../type_descriptor.zig");

const comp = zwasm.feature.component.host;
const ctypes = zwasm.feature.component.types;
const ComponentValue = comp.ComponentValue;
const WitType = comp.WitType;
const WasiHost = zwasm.wasi.host.Host;

/// Read + FS-jail-resolve a component path argument.
fn readComponentBytes(rt: *Runtime, path_val: Value, loc: SourceLocation) anyerror![]const u8 {
    if (!path_val.isString())
        return error_catalog.raise(.wasm_path_invalid, loc, .{});
    const path = string_mod.asString(path_val);
    // ADR-0158 (D-404 Impl D): a `cljw build` binary bakes every static
    // `:require`d component's bytes into an embedded table keyed by the
    // resolved path. Serve from memory before any FS read so the binary is
    // self-contained. A genuinely dynamic `(wasm/load runtime-path)` whose path
    // was not embedded misses here and falls through to the FS jail load.
    for (rt.embedded_components) |c| {
        if (std.mem.eql(u8, c.path, path)) return rt.gpa.dupe(u8, c.bytes);
    }
    const jailed = file_io.jailResolve(rt.gpa, rt.fs_jail_root, path) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.FsJailEscape => return error_catalog.raise(.fs_jail_escape, loc, .{ .fn_name = "wasm/component", .path = path }),
    };
    defer if (jailed) |j| rt.gpa.free(j);
    const open_path = jailed orelse path;
    return file_io.readAll(rt.io, rt.gpa, open_path) catch
        error_catalog.raise(.wasm_load_read_failed, loc, .{ .path = path });
}

/// Render a `WitType` human-readably for the introspection probe:
/// "string", "u32", "record{xs: list<u32>, label: string}", "enum{a, b}", …
fn writeWitType(w: *std.Io.Writer, ty: WitType) anyerror!void {
    switch (ty) {
        .prim => |p| try w.writeAll(@tagName(p)),
        .list => |elem| {
            try w.writeAll("list<");
            try writeWitType(w, elem.*);
            try w.writeAll(">");
        },
        .record => |fields| {
            try w.writeAll("record{");
            for (fields, 0..) |f, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("{s}: ", .{f.name});
                try writeWitType(w, f.ty);
            }
            try w.writeAll("}");
        },
        .tuple => |types| {
            try w.writeAll("tuple<");
            for (types, 0..) |t, i| {
                if (i > 0) try w.writeAll(", ");
                try writeWitType(w, t);
            }
            try w.writeAll(">");
        },
        .variant => |cases| {
            try w.writeAll("variant{");
            for (cases, 0..) |c, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(c.name);
            }
            try w.writeAll("}");
        },
        .enum_ => |labels| {
            try w.writeAll("enum{");
            for (labels, 0..) |l, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(l);
            }
            try w.writeAll("}");
        },
        .option => |inner| {
            try w.writeAll("option<");
            try writeWitType(w, inner.*);
            try w.writeAll(">");
        },
        .result => |r| {
            try w.writeAll("result<");
            if (r.ok) |ok| try writeWitType(w, ok.*) else try w.writeAll("_");
            try w.writeAll(", ");
            if (r.err) |er| try writeWitType(w, er.*) else try w.writeAll("_");
            try w.writeAll(">");
        },
        .flags => |labels| {
            try w.writeAll("flags{");
            for (labels, 0..) |l, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(l);
            }
            try w.writeAll("}");
        },
        .own => |i| try w.print("own<{d}>", .{i}),
        .borrow => |i| try w.print("borrow<{d}>", .{i}),
    }
}

fn witTypeName(alloc: std.mem.Allocator, ty: WitType) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    try writeWitType(&aw.writer, ty);
    return aw.toOwnedSlice();
}

/// Open a component into a unified `Opened` handle (zwasm REQ-1 `comp.open`
/// auto-selects single-module vs WASI-P2 graph). The WasiHost is caller-owned
/// and must outlive `Opened` (the graph path borrows it); both are freed by the
/// caller's `defer`s in LIFO order (opened first, then host).
fn openComponent(rt: *Runtime, engine: *zwasm.Engine, host: *WasiHost, bytes: []const u8, loc: SourceLocation) anyerror!comp.Opened {
    host.* = WasiHost.init(rt.gpa) catch return error_catalog.raise(.wasm_load_failed, loc, .{});
    errdefer host.deinit();
    host.io = rt.io;
    return comp.open(engine, rt.gpa, bytes, host, .{}) catch
        error_catalog.raise(.wasm_load_failed, loc, .{});
}

/// `(wasm/component-exports "p.wasm")` — vector of
/// `{:name "greet" :params [["name" "string"] …] :result "string"}` maps,
/// straight from the component's self-describing type section.
pub fn componentExportsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("wasm/component-exports", args, 1, loc);
    const bytes = try readComponentBytes(rt, args[0], loc);
    defer rt.gpa.free(bytes);

    var engine = zwasm.Engine.init(rt.gpa, .{}) catch
        return error_catalog.raise(.wasm_load_failed, loc, .{});
    defer engine.deinit();
    var host: WasiHost = undefined;
    var opened = try openComponent(rt, &engine, &host, bytes, loc);
    defer host.deinit();
    defer opened.deinit();

    const funcs = try opened.exportedFuncs(rt.gpa);
    defer ctypes.TypeInfo.freeExportedFuncs(rt.gpa, funcs);

    var type_arena = std.heap.ArenaAllocator.init(rt.gpa);
    defer type_arena.deinit();

    var out = vector_mod.empty();
    for (funcs) |f| {
        const sig = (opened.resolveFuncSig(type_arena.allocator(), f.name) catch null) orelse continue;
        var m = map_mod.empty();
        m = try map_mod.assoc(rt, m, try keyword_mod.intern(rt, null, "name"), try string_mod.alloc(rt, f.name));
        var params = vector_mod.empty();
        for (sig.params) |p| {
            const tn = try witTypeName(rt.gpa, p.ty);
            defer rt.gpa.free(tn);
            const pair = try vector_mod.fromSlice(rt, &.{
                try string_mod.alloc(rt, p.name),
                try string_mod.alloc(rt, tn),
            });
            params = try vector_mod.conj(rt, params, pair);
        }
        m = try map_mod.assoc(rt, m, try keyword_mod.intern(rt, null, "params"), params);
        const res: Value = if (sig.result) |rty| blk: {
            const tn = try witTypeName(rt.gpa, rty);
            defer rt.gpa.free(tn);
            break :blk try string_mod.alloc(rt, tn);
        } else Value.nil_val;
        m = try map_mod.assoc(rt, m, try keyword_mod.intern(rt, null, "result"), res);
        out = try vector_mod.conj(rt, out, m);
    }
    return out;
}

/// Lower a cljw Value into a `ComponentValue` directed by the WIT param type
/// (the ADR-0135 table, lower direction). Compound nodes allocate on `scratch`
/// (an arena the invoke owns); strings borrow the GC string. enum/variant are
/// passed by ORDINAL (zwasm REQ-2: the lower path is label-less; a cljw keyword
/// maps to its ordinal via the WitType labels here).
fn lower(rt: *Runtime, scratch: std.mem.Allocator, v: Value, ty: WitType, loc: SourceLocation) anyerror!ComponentValue {
    switch (ty) {
        .prim => |p| return switch (p) {
            .bool => .{ .bool = v.isTruthy() },
            .string => blk: {
                if (!v.isString()) return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "wasm/component-invoke", .actual = @tagName(v.tag()) });
                break :blk .{ .string = string_mod.asString(v) };
            },
            .u8 => .{ .u8 = @intCast(v.asInteger()) },
            .s8 => .{ .s8 = @intCast(v.asInteger()) },
            .u16 => .{ .u16 = @intCast(v.asInteger()) },
            .s16 => .{ .s16 = @intCast(v.asInteger()) },
            .u32 => .{ .u32 = @intCast(v.asInteger()) },
            .s32 => .{ .s32 = @intCast(v.asInteger()) },
            .u64 => .{ .u64 = @intCast(v.asInteger()) },
            .s64 => .{ .s64 = v.asInteger() },
            .f32 => .{ .f32 = @floatCast(v.asFloat()) },
            .f64 => .{ .f64 = v.asFloat() },
            .char => .{ .char = @intCast(v.asInteger()) },
            else => error_catalog.raise(.feature_not_supported, loc, .{ .name = "wasm/component-invoke: this WIT param type" }),
        },
        .record => |fields| {
            const mt = v.tag();
            if (mt != .array_map and mt != .hash_map)
                return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "a WIT record param expects a map" });
            const out = try scratch.alloc(ComponentValue.Field, fields.len);
            for (fields, 0..) |f, i| {
                const kw = try keyword_mod.intern(rt, null, f.name);
                const fv = map_mod.get(v, kw) catch Value.nil_val;
                out[i] = .{ .name = f.name, .value = try lower(rt, scratch, fv, f.ty, loc) };
            }
            return .{ .record = out };
        },
        .list => |elem| {
            if (v.tag() != .vector)
                return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "a WIT list param expects a vector" });
            const n = vector_mod.count(v);
            const items = try scratch.alloc(ComponentValue, n);
            var i: u32 = 0;
            while (i < n) : (i += 1) items[i] = try lower(rt, scratch, vector_mod.nth(v, i), elem.*, loc);
            return .{ .list = items };
        },
        .tuple => |types| {
            if (v.tag() != .vector or vector_mod.count(v) != types.len)
                return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "a WIT tuple param expects a vector of the tuple arity" });
            const items = try scratch.alloc(ComponentValue, types.len);
            for (types, 0..) |t, i| items[i] = try lower(rt, scratch, vector_mod.nth(v, @intCast(i)), t, loc);
            return .{ .tuple = items };
        },
        .option => |inner| {
            if (v.isNil()) return .{ .option = null };
            const boxed = try scratch.create(ComponentValue);
            boxed.* = try lower(rt, scratch, v, inner.*, loc);
            return .{ .option = boxed };
        },
        .enum_ => |labels| {
            const idx = try enumOrdinal(v, labels, loc);
            return .{ .@"enum" = .{ .index = idx } };
        },
        .flags => |labels| {
            // a set of keywords → the bit-set per the type's label order.
            var bits: u32 = 0;
            for (labels, 0..) |l, i| {
                const kw = try keyword_mod.intern(rt, null, l);
                if (set_mod.contains(v, kw) catch false) bits |= (@as(u32, 1) << @intCast(i));
            }
            return .{ .flags = .{ .bits = bits } };
        },
        .own => return .{ .own = @intCast(v.asInteger()) },
        .borrow => return .{ .borrow = @intCast(v.asInteger()) },
        .result, .variant => return error_catalog.raise(.feature_not_supported, loc, .{ .name = "wasm/component-invoke: result/variant param (rare on the input side)" }),
    }
}

/// Map a cljw keyword (or integer ordinal) to an enum/variant case index using
/// the WIT labels (zwasm REQ-2 input direction).
fn enumOrdinal(v: Value, labels: []const []const u8, loc: SourceLocation) anyerror!u32 {
    if (v.tag() == .keyword) {
        const name = keyword_mod.asKeyword(v).name;
        for (labels, 0..) |l, i| if (std.mem.eql(u8, l, name)) return @intCast(i);
        return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "unknown WIT enum/variant label" });
    }
    return @intCast(v.asInteger());
}

/// Lift a `ComponentValue` tree to Clojure data per ADR-0135. With zwasm REQ-2
/// labels the FULL mapping is value-derivable: enum→keyword, flags→set of
/// keywords, variant→tagged map, result→value|throw, record→map, option→nil|v.
fn lift(rt: *Runtime, cv: ComponentValue, loc: SourceLocation) anyerror!Value {
    return switch (cv) {
        .bool => |b| Value.initBoolean(b),
        .s8 => |n| Value.initInteger(n),
        .u8 => |n| Value.initInteger(n),
        .s16 => |n| Value.initInteger(n),
        .u16 => |n| Value.initInteger(n),
        .s32 => |n| Value.initInteger(n),
        .u32 => |n| Value.initInteger(n),
        .s64 => |n| Value.initInteger(n),
        .u64 => |n| Value.initInteger(@intCast(n)),
        .f32 => |f| Value.initFloat(f),
        .f64 => |f| Value.initFloat(f),
        .char => |c| Value.initChar(c),
        .string => |s| try string_mod.alloc(rt, s),
        .list, .tuple => |items| blk: {
            var out = vector_mod.empty();
            for (items) |item| out = try vector_mod.conj(rt, out, try lift(rt, item, loc));
            break :blk out;
        },
        .record => |fields| blk: {
            var m = map_mod.empty();
            for (fields) |f|
                m = try map_mod.assoc(rt, m, try keyword_mod.intern(rt, null, f.name), try lift(rt, f.value, loc));
            break :blk m;
        },
        .option => |opt| if (opt) |p| try lift(rt, p.*, loc) else Value.nil_val,
        .result => |r| blk: {
            if (r.is_ok) break :blk if (r.payload) |p| try lift(rt, p.*, loc) else Value.nil_val;
            // err arm → catchable cljw exception (ADR-0135 result→throw).
            break :blk error_catalog.raise(.wasm_trap, loc, .{});
        },
        .variant => |vt| blk: {
            // {:wit/case :name :value v} — the case label (REQ-2) when present.
            var m = map_mod.empty();
            const case_kw: Value = if (vt.case_name.len > 0)
                try keyword_mod.intern(rt, null, vt.case_name)
            else
                Value.initInteger(vt.case);
            m = try map_mod.assoc(rt, m, try keyword_mod.intern(rt, "wit", "case"), case_kw);
            const payload: Value = if (vt.payload) |p| try lift(rt, p.*, loc) else Value.nil_val;
            m = try map_mod.assoc(rt, m, try keyword_mod.intern(rt, null, "value"), payload);
            break :blk m;
        },
        .@"enum" => |e| if (e.label.len > 0)
            try keyword_mod.intern(rt, null, e.label)
        else
            Value.initInteger(e.index),
        .flags => |fl| blk: {
            // → a set of keywords (the labels whose bit is set).
            var s = set_mod.empty();
            for (fl.labels, 0..) |l, i| {
                if ((fl.bits & (@as(u32, 1) << @intCast(i))) != 0)
                    s = try set_mod.conj(rt, s, try keyword_mod.intern(rt, null, l));
            }
            break :blk s;
        },
        .own => |h| Value.initInteger(h),
        .borrow => |h| Value.initInteger(h),
    };
}

/// `(wasm/component-invoke "p.wasm" "func" & args)` — one-shot typed invoke
/// (open → resolveFuncSig → lower → invokeTyped → lift → teardown). The require
/// path will cache the instance; this is the experiment's roundtrip probe.
pub fn componentInvokeFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityMin("wasm/component-invoke", args, 2, loc);
    if (!args[1].isString())
        return error_catalog.raise(.wasm_export_name_invalid, loc, .{});
    const bytes = try readComponentBytes(rt, args[0], loc);
    defer rt.gpa.free(bytes);

    var engine = zwasm.Engine.init(rt.gpa, .{}) catch
        return error_catalog.raise(.wasm_load_failed, loc, .{});
    defer engine.deinit();
    var host: WasiHost = undefined;
    var opened = try openComponent(rt, &engine, &host, bytes, loc);
    defer host.deinit();
    defer opened.deinit();

    return invokeOnOpened(rt, &opened, string_mod.asString(args[1]), args[2..], loc);
}

/// resolveFuncSig → lower args → invokeTyped → lift result, on an already-open
/// `Opened`. Shared by the one-shot `component-invoke` and the handle-based
/// `component-call` (the latter persists the Opened across calls).
fn invokeOnOpened(rt: *Runtime, opened: *comp.Opened, fname: []const u8, call_args: []const Value, loc: SourceLocation) anyerror!Value {
    var arena = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena.deinit();
    const sig = (opened.resolveFuncSig(arena.allocator(), fname) catch null) orelse
        return error_catalog.raise(.wasm_export_not_found, loc, .{ .name = fname });
    if (call_args.len != sig.params.len)
        return error_catalog.raise(.wasm_arity_mismatch, loc, .{ .name = fname, .expected = sig.params.len, .actual = call_args.len });

    const in = try arena.allocator().alloc(ComponentValue, call_args.len);
    for (call_args, sig.params, 0..) |a, p, i| in[i] = try lower(rt, arena.allocator(), a, p.ty, loc);

    const out = opened.invokeTyped(fname, in, rt.gpa) catch
        return error_catalog.raise(.wasm_trap, loc, .{});
    if (out) |o| {
        defer o.deinit(rt.gpa);
        return try lift(rt, o, loc);
    }
    return Value.nil_val;
}

// ---------------------------------------------------------------------------
// Instance caching (D-404 / ADR-0135 substrate) — REQ-7 (zwasm 33e0100c).
//
// `comp.open`'s `Opened` now OWNS a copy of the component bytes, so a host can
// cache it at a stable address and call across time (the load buffer is freed
// immediately after open). This was the REQ-7 blocker: pre-fix, the Opened
// borrowed the caller's bytes, so a cached handle's export names dangled and
// `resolveFuncSig` returned null. The cache is the substrate for
// require-a-component (one Var per export) + resource chains (constructor →
// method own-handle), which the one-shot `component-invoke` cannot express.
// ---------------------------------------------------------------------------

/// A long-lived opened component behind a `(wasm/load-component …)` handle.
/// `engine`/`host` are heap-stable (the WASI-P2 graph borrows `host`); `opened`
/// is stored by value and is self-contained post-REQ-7. Torn down opened → host
/// → engine (LIFO) by the host_instance finaliser.
const ComponentLoaded = struct {
    engine: *zwasm.Engine,
    host: *WasiHost,
    opened: comp.Opened,
};

/// `.host_instance` finaliser for a component handle: state[0] is the
/// `*ComponentLoaded`. Frees the zwasm triple in LIFO order. No-GC-trace: every
/// field lives in zwasm's separate space (F-006), so the descriptor sets no
/// `host_trace`.
fn componentFinalise(infra: std.mem.Allocator, state: *[host_instance.STATE_WORDS]u64) void {
    const box: *ComponentLoaded = @ptrFromInt(state[0]);
    box.opened.deinit();
    box.host.deinit();
    box.engine.deinit();
    infra.destroy(box.host);
    infra.destroy(box.engine);
    infra.destroy(box);
}

var component_descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.wasm.Component",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = Value.nil_val,
    .host_finalise = &componentFinalise,
};

/// `(wasm/load-component "p.wasm")` → a cached component handle. Opens once,
/// frees the load buffer immediately (REQ-7), and keeps the `Opened` alive
/// behind a GC-finalised host_instance for `(wasm/component-call …)` to invoke
/// across time.
pub fn loadComponentFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("wasm/load-component", args, 1, loc);
    const bytes = try readComponentBytes(rt, args[0], loc);
    defer rt.gpa.free(bytes); // REQ-7: the Opened owns its bytes — drop the load buffer now.

    const engine = try rt.gpa.create(zwasm.Engine);
    errdefer rt.gpa.destroy(engine);
    engine.* = zwasm.Engine.init(rt.gpa, .{}) catch
        return error_catalog.raise(.wasm_load_failed, loc, .{});
    errdefer engine.deinit();

    const host = try rt.gpa.create(WasiHost);
    errdefer rt.gpa.destroy(host);
    var opened = try openComponent(rt, engine, host, bytes, loc);
    // errdefer order: opened.deinit must run BEFORE host.deinit (it borrows host),
    // so register host.deinit FIRST (runs last under LIFO).
    errdefer host.deinit();
    errdefer opened.deinit();

    const box = try rt.gpa.create(ComponentLoaded);
    errdefer rt.gpa.destroy(box);
    box.* = .{ .engine = engine, .host = host, .opened = opened };
    return host_instance.alloc(rt, &component_descriptor, .{ @intFromPtr(box), 0, 0, 0 });
}

/// `(wasm/component-call handle "func" & args)` — typed invoke against a cached
/// component handle. Same lower → invokeTyped → lift roundtrip as the one-shot
/// `component-invoke`, but the `Opened` persists across calls (REQ-7), so an
/// `own`-handle returned by one call (a resource constructor) stays valid as the
/// receiver of the next (a method) — the resource-chain the one-shot path cannot
/// express.
pub fn componentCallFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityMin("wasm/component-call", args, 2, loc);
    if (args[0].tag() != .host_instance or
        host_instance.asHostInstance(args[0]).descriptor != &component_descriptor)
        return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "wasm/component-call expects a (wasm/load-component …) handle" });
    if (!args[1].isString())
        return error_catalog.raise(.wasm_export_name_invalid, loc, .{});
    const box: *ComponentLoaded = @ptrFromInt(host_instance.asHostInstance(args[0]).state[0]);
    return invokeOnOpened(rt, &box.opened, string_mod.asString(args[1]), args[2..], loc);
}
