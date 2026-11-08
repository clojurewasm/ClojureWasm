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
const marshal = @import("marshal.zig");
const surface = @import("surface.zig");
const promote = @import("../../numeric/promote.zig");
const big_int = @import("../../numeric/big_int.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const mark_sweep = @import("../../gc/mark_sweep.zig");
const gc_heap_mod = @import("../../gc/gc_heap.zig");

const comp = zwasm.feature.component.host;
const ctypes = zwasm.feature.component.types;
const ComponentValue = comp.ComponentValue;
const WitType = comp.WitType;
const WasiHost = zwasm.wasi.host.Host;
const SigCache = @import("component_sig_cache.zig").SigCache;

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
fn openComponent(rt: *Runtime, engine: *zwasm.Engine, host: *WasiHost, bytes: []const u8, opts: comp.InstantiateOpts, loc: SourceLocation) anyerror!comp.Opened {
    host.* = WasiHost.init(rt.gpa) catch return error_catalog.raise(.wasm_load_failed, loc, .{});
    errdefer host.deinit();
    host.io = rt.io;
    return comp.open(engine, rt.gpa, bytes, host, opts) catch |e|
        error_catalog.raise(.wasm_component_open_failed, loc, .{ .reason = @errorName(e) });
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
    var opened = try openComponent(rt, &engine, &host, bytes, .{}, loc);
    defer host.deinit();
    defer opened.deinit();

    const funcs = try opened.exportedFuncs(rt.gpa);
    defer ctypes.TypeInfo.freeExportedFuncs(rt.gpa, funcs);

    var type_arena = std.heap.ArenaAllocator.init(rt.gpa);
    defer type_arena.deinit();

    // `out` and each export map are unrooted locals until returned.
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
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

/// A `u64` above `maxInt(i64)` exactly, as a BigInt. ADR-0135's table already
/// promised this ("u64/s64 may promote to BigInt at the f64 edge, F-005"); the
/// code did a narrowing `@intCast` instead, which panics in ReleaseSafe.
fn bigFromU64(rt: *Runtime, n: u64) !Value {
    var m = try std.math.big.int.Managed.init(rt.gc.infra);
    defer m.deinit();
    try m.set(n);
    return try big_int.allocFromManaged(rt, &m, .bigint);
}

/// `[:tag …]` → the tag's keyword name. The shared shape check for `result` and
/// `variant`, which ADR-0135 amendment 2 gave the same tagged-vector form so one
/// destructuring idiom covers every WIT sum type.
fn taggedVectorTag(v: Value, loc: SourceLocation) ![]const u8 {
    if (v.tag() != .vector or vector_mod.count(v) == 0)
        return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "a result / variant argument must be a [:tag payload] vector" });
    const head = vector_mod.nth(v, 0);
    if (head.tag() != .keyword)
        return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "the first element of a result / variant argument must be a keyword" });
    return keyword_mod.asKeyword(head).name;
}

/// The optional payload slot of a `[:tag payload]` vector, lowered against the
/// arm's type. Absent slot + absent type is the payload-less case; a mismatch in
/// either direction is a usage error rather than a silent nil.
fn taggedVectorPayload(rt: *Runtime, scratch: std.mem.Allocator, v: Value, ty: ?*const WitType, loc: SourceLocation, owner: Value) !?*ComponentValue {
    const has_slot = vector_mod.count(v) > 1;
    if (ty == null) {
        if (has_slot)
            return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "this case carries no payload, but one was supplied" });
        return null;
    }
    if (!has_slot)
        return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "this case carries a payload, but none was supplied" });
    const boxed = try scratch.create(ComponentValue);
    boxed.* = try lower(rt, scratch, vector_mod.nth(v, 1), ty.?.*, loc, owner);
    return boxed;
}

/// Lower a cljw Value into a `ComponentValue` directed by the WIT param type
/// (the ADR-0135 table, lower direction). Compound nodes allocate on `scratch`
/// (an arena the invoke owns); strings borrow the GC string. enum/variant are
/// passed by ORDINAL (zwasm REQ-2: the lower path is label-less; a cljw keyword
/// maps to its ordinal via the WitType labels here).
fn lower(rt: *Runtime, scratch: std.mem.Allocator, v: Value, ty: WitType, loc: SourceLocation, owner: Value) anyerror!ComponentValue {
    switch (ty) {
        .prim => |p| return switch (p) {
            .bool => .{ .bool = v.isTruthy() },
            .string => blk: {
                if (!v.isString()) return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "wasm/component-invoke", .actual = @tagName(v.tag()) });
                break :blk .{ .string = string_mod.asString(v) };
            },
            // Range-checked through the SAME helper `wasm/call` uses
            // (`marshal.coerceInt`). These were bare `@intCast`s, which in
            // ReleaseSafe — the shipped config — is a process-killing safety
            // panic on out-of-range caller data, not a catchable error. The
            // core-module surface next door had always checked; the component
            // surface never inherited it.
            .u8 => .{ .u8 = try marshal.coerceInt(v, u8, loc) },
            .s8 => .{ .s8 = try marshal.coerceInt(v, i8, loc) },
            .u16 => .{ .u16 = try marshal.coerceInt(v, u16, loc) },
            .s16 => .{ .s16 = try marshal.coerceInt(v, i16, loc) },
            .u32 => .{ .u32 = try marshal.coerceInt(v, u32, loc) },
            .s32 => .{ .s32 = try marshal.coerceInt(v, i32, loc) },
            .u64 => .{ .u64 = try marshal.coerceInt(v, u64, loc) },
            .s64 => .{ .s64 = try marshal.coerceInt(v, i64, loc) },
            .f32 => .{ .f32 = @floatCast(v.asFloat()) },
            .f64 => .{ .f64 = v.asFloat() },
            // A WIT `char` is a Unicode scalar value, and cljw's char IS one
            // (21-bit, unlike a JVM Character — ADR-0135 amendment 2). Accept
            // the char directly; an integer codepoint is also accepted because
            // the LIFT side hands back a char and a caller may have built one
            // arithmetically. This row had never worked: it was
            // `@intCast(v.asInteger())`, and `asInteger()` on a char value is
            // not its codepoint, so the first end-to-end run of the typed
            // fixture is what surfaced it.
            .char => .{ .char = if (v.tag() == .char) v.asChar() else try marshal.coerceInt(v, u21, loc) },
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
                out[i] = .{ .name = f.name, .value = try lower(rt, scratch, fv, f.ty, loc, owner) };
            }
            return .{ .record = out };
        },
        .list => |elem| {
            if (v.tag() != .vector)
                return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "a WIT list param expects a vector" });
            const n = vector_mod.count(v);
            const items = try scratch.alloc(ComponentValue, n);
            var i: u32 = 0;
            while (i < n) : (i += 1) items[i] = try lower(rt, scratch, vector_mod.nth(v, i), elem.*, loc, owner);
            return .{ .list = items };
        },
        .tuple => |types| {
            if (v.tag() != .vector or vector_mod.count(v) != types.len)
                return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "a WIT tuple param expects a vector of the tuple arity" });
            const items = try scratch.alloc(ComponentValue, types.len);
            for (types, 0..) |t, i| items[i] = try lower(rt, scratch, vector_mod.nth(v, @intCast(i)), t, loc, owner);
            return .{ .tuple = items };
        },
        .option => |inner| {
            if (v.isNil()) return .{ .option = null };
            const boxed = try scratch.create(ComponentValue);
            boxed.* = try lower(rt, scratch, v, inner.*, loc, owner);
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
        .own => return .{ .own = try rawResourceHandle(v, owner, loc) },
        .borrow => return .{ .borrow = try rawResourceHandle(v, owner, loc) },
        // The tagged-vector shapes ADR-0135 amendment 2 settled, in the LOWER
        // direction: `[:ok v]` / `[:err e]` and `[:case-name payload]`, payload
        // slot optional. Both were `feature_not_supported`, so the shapes the
        // lift side produces could not be handed back — a component taking a
        // `result` or `variant` param was unreachable, and the amendment's own
        // round-trip was untestable.
        .result => |r| {
            const tag = try taggedVectorTag(v, loc);
            const is_ok = std.mem.eql(u8, tag, "ok");
            if (!is_ok and !std.mem.eql(u8, tag, "err"))
                return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "a result argument must be [:ok v] or [:err e]" });
            const pt: ?*const WitType = if (is_ok) r.ok else r.err;
            const payload = try taggedVectorPayload(rt, scratch, v, pt, loc, owner);
            return .{ .result = .{ .is_ok = is_ok, .payload = payload } };
        },
        .variant => |cases| {
            const tag = try taggedVectorTag(v, loc);
            for (cases, 0..) |c, i| {
                if (!std.mem.eql(u8, c.name, tag)) continue;
                const payload = try taggedVectorPayload(rt, scratch, v, c.payload, loc, owner);
                return .{ .variant = .{ .case = @intCast(i), .case_name = c.name, .payload = payload } };
            }
            return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "the variant case keyword does not name a case of this type" });
        },
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
/// `component_handle` (ADR-0159): when non-null (the cached `component-call`
/// path), an `own` result becomes a typed GC-resource wrapper that roots that
/// component and can be `wasm/resource-drop`'d; null (the one-shot
/// `component-invoke` path, no persistent component to own it) keeps the bare
/// integer. `borrow` is never owned, so it stays a bare integer in both.
fn lift(rt: *Runtime, cv: ComponentValue, loc: SourceLocation, component_handle: ?Value) anyerror!Value {
    return switch (cv) {
        .bool => |b| Value.initBoolean(b),
        .s8 => |n| Value.initInteger(n),
        .u8 => |n| Value.initInteger(n),
        .s16 => |n| Value.initInteger(n),
        .u16 => |n| Value.initInteger(n),
        .s32 => |n| Value.initInteger(n),
        .u32 => |n| Value.initInteger(n),
        // `Value.initInteger` silently demotes an out-of-i48 value to a LOSSY
        // float (its own doc says so), and i48 is only about +/-1.4e14 — well
        // inside what a guest can legitimately return. `promote.wrapI64` is the
        // canonical exact-i64 entry: it stays a fixnum in range and promotes to
        // a heap Long outside it, matching F-005's numeric tower.
        .s64 => |n| try promote.wrapI64(rt, n),
        // A u64 above i64's maximum has no i64 to widen to at all. The old
        // `@intCast` was a ReleaseSafe panic on GUEST-CONTROLLED data — an
        // untrusted component could kill the host by returning a large u64.
        .u64 => |n| if (n <= std.math.maxInt(i64))
            try promote.wrapI64(rt, @intCast(n))
        else
            try bigFromU64(rt, n),
        .f32 => |f| Value.initFloat(f),
        .f64 => |f| Value.initFloat(f),
        .char => |c| Value.initChar(c),
        .string => |s| try string_mod.alloc(rt, s),
        .list, .tuple => |items| blk: {
            var out = vector_mod.empty();
            for (items) |item| out = try vector_mod.conj(rt, out, try lift(rt, item, loc, component_handle));
            break :blk out;
        },
        .record => |fields| blk: {
            var m = map_mod.empty();
            for (fields) |f|
                m = try map_mod.assoc(rt, m, try keyword_mod.intern(rt, null, f.name), try lift(rt, f.value, loc, component_handle));
            break :blk m;
        },
        .option => |opt| if (opt) |p| try lift(rt, p.*, loc, component_handle) else Value.nil_val,
        // `[:ok v]` / `[:err e]`, the payload slot omitted when the arm carries
        // none (ADR-0135 amendment 2). This REPLACES an err→throw mapping that
        // discarded the error value entirely: the old arm raised `.wasm_trap`
        // with no payload, so a component returning `err("not found")` reached
        // the user as "WebAssembly module trapped (e.g. divide-by-zero,
        // out-of-bounds, or an unreachable instruction)" — a different thing
        // from a normal return, and the err value simply gone.
        //
        // Throwing also has no meaning off the return position: `lift` is
        // recursive, so a `result` nested in a `list` or `record` aborted the
        // whole lift and discarded the successfully-lifted prefix.
        // `Explainer.md` is normative that `result` is the RECOVERY channel,
        // i.e. a value. Throwing sugar belongs on top, not underneath.
        .result => |r| blk: {
            var out = vector_mod.empty();
            out = try vector_mod.conj(rt, out, try keyword_mod.intern(rt, null, if (r.is_ok) "ok" else "err"));
            if (r.payload) |p| out = try vector_mod.conj(rt, out, try lift(rt, p.*, loc, component_handle));
            break :blk out;
        },
        // `[:case-name payload]`, payload omitted when the case carries none —
        // the same tagged-vector shape as `result`, so one destructuring idiom
        // covers every WIT sum type. A case with no label (zwasm REQ-2 gives the
        // ordinal only) falls back to the integer index in the tag slot.
        .variant => |vt| blk: {
            var out = vector_mod.empty();
            const case_tag: Value = if (vt.case_name.len > 0)
                try keyword_mod.intern(rt, null, vt.case_name)
            else
                Value.initInteger(vt.case);
            out = try vector_mod.conj(rt, out, case_tag);
            if (vt.payload) |p| out = try vector_mod.conj(rt, out, try lift(rt, p.*, loc, component_handle));
            break :blk out;
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
        .own => |h| if (component_handle) |ch| try makeResourceHandle(rt, ch, h) else Value.initInteger(h),
        .borrow => |h| Value.initInteger(h),
    };
}

// === Component resource handle (ADR-0159, D-404 Impl E) ===
//
// An `own<T>` result becomes a `.host_instance` wrapper carrying its owning
// component handle (state[0], a `.host_instance` ComponentLoaded Value), the raw
// zwasm handle (state[1]), and a one-shot dropped flag (state[2]). `host_trace`
// marks state[0] so a held resource ROOTS its component (the `Opened` cannot be
// collected while a resource is reachable; java.util.Iterator cursor precedent).
// There is deliberately NO `host_finalise`: rooting only holds while the resource
// is reachable, so a same-cycle collection of the resource + its component gives
// no finaliser ordering (F-006 mark-sweep) — any drop from the resource finaliser
// could touch a freed `Opened`. Release is therefore DETERMINISTIC
// (`wasm/resource-drop` / a `with-resource` scope, where the held wrapper proves
// the component live); `componentFinalise`'s `Opened.deinit()` drains the whole
// table at component teardown as the backstop. See ADR-0159 § Divergence.

var resource_descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.wasm.Resource",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = Value.nil_val,
    .host_trace = &resourceTrace,
};

/// GC-trace: mark the owning component handle Value held in state[0] (roots the
/// `ComponentLoaded` box while this resource is reachable). GC-ROOT: §H — a moving
/// GC must RELOCATE state[0], not just mark [ref: .dev/gc_rooting.md §H].
fn resourceTrace(gc_ptr: *anyopaque, state: *[host_instance.STATE_WORDS]u64) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const ch: Value = @enumFromInt(state[0]);
    if (ch.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
}

/// Wrap an `own` handle as a GC-resource value rooting `component_handle`.
fn makeResourceHandle(rt: *Runtime, component_handle: Value, handle: u32) anyerror!Value {
    return host_instance.alloc(rt, &resource_descriptor, .{ @intFromEnum(component_handle), handle, 0, 0 });
}

/// True iff `v` is a component resource wrapper.
fn isResourceHandle(v: Value) bool {
    return v.tag() == .host_instance and host_instance.asHostInstance(v).descriptor == &resource_descriptor;
}

/// Extract the raw zwasm handle from `v` for a `borrow`/`own` param. `owner` is
/// the component being called; the wrapper must belong to it.
///
/// The wrapper is the ONLY accepted form. A bare integer used to fall through to
/// `@intCast(v.asInteger())`, which is wrong three times over: `asInteger` does
/// not check the tag (any Value became a table index), a negative integer is a
/// ReleaseSafe `@intCast` panic on caller data — the exact host-crash class the
/// numeric rows in this file closed — and a handle number carries no owner, so
/// it indexes whichever table it is handed to. There is no legitimate source of
/// a raw handle number: every one a caller can hold came out of a component
/// call already wrapped.
///
/// The owner check is what ADR-0159's Consequences already claimed ("can't be
/// passed to another component's method") and nothing enforced. It matters
/// because handle numbers are dense per-instance table indices starting at 1
/// (zwasm `resource_table.zig`), so a foreign handle does not reliably fail —
/// it names a DIFFERENT live resource in the callee.
fn rawResourceHandle(v: Value, owner: Value, loc: SourceLocation) anyerror!u32 {
    if (!isResourceHandle(v)) return error_catalog.raise(.wasm_resource_expected, loc, .{});
    const inst = host_instance.asHostInstance(v);
    if (inst.state[2] != 0) return error_catalog.raise(.wasm_resource_dropped, loc, .{});
    if (inst.state[0] != @intFromEnum(owner)) return error_catalog.raise(.wasm_resource_foreign, loc, .{});
    return @intCast(inst.state[1]);
}

/// `(wasm/resource-drop h)` — release a component `own` resource: run its guest
/// destructor via the owning component's `Opened.dropResource`, then mark the
/// wrapper dropped (one-shot; a second drop is a no-op, NOT a zwasm stale-handle
/// trap). Deterministic release per ADR-0159; the held wrapper proves the
/// component live, so the `Opened` is valid here. Returns nil.
pub fn resourceDropFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("wasm/resource-drop", args, 1, loc);
    if (!isResourceHandle(args[0]))
        return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "wasm/resource-drop expects a component resource handle" });
    const inst = host_instance.asHostInstance(args[0]);
    if (inst.state[2] != 0) return Value.nil_val; // already dropped — idempotent.
    const comp_handle: Value = @enumFromInt(inst.state[0]);
    if (comp_handle.tag() != .host_instance or
        host_instance.asHostInstance(comp_handle).descriptor != &component_descriptor)
        return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "resource handle's owning component is not a loaded component" });
    const box: *ComponentLoaded = @ptrFromInt(host_instance.asHostInstance(comp_handle).state[0]);
    box.opened.dropResource(@intCast(inst.state[1])) catch |e| switch (e) {
        // zwasm's `.single` variant has no resource table: a structural
        // property of the component, not a trap (D-568).
        error.NoResourceTable => return error_catalog.raise(.wasm_resource_no_table, loc, .{}),
        else => return error_catalog.raise(.wasm_component_trap, loc, .{}),
    };
    host_instance.setState(args[0], 2, 1);
    return Value.nil_val;
}

/// `(wasm/component-invoke "p.wasm" "func" & args)` — one-shot typed invoke
/// (open → resolveFuncSig → lower → invokeTyped → lift → teardown).
///
/// "One-shot" describes the CALL, not the component's lifetime: when the result
/// holds a resource handle the component outlives the call, because the handle
/// names something inside it. See the branch in the body.
pub fn componentInvokeFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArityMin("wasm/component-invoke", args, 2, loc);
    // A handle from `wasm/load-component` (or a resource handle from one) is
    // already open: invoke on it instead of refusing it as "not a path". Only
    // a path string takes the one-shot open-and-teardown route below.
    if (!args[0].isString()) return componentCallFn(rt, env, args, loc);
    if (!args[1].isString())
        return error_catalog.raise(.wasm_export_name_invalid, loc, .{});
    const bytes = try readComponentBytes(rt, args[0], loc);
    defer rt.gpa.free(bytes);
    const fname = string_mod.asString(args[1]);

    // Heap-allocated even though most calls tear it down at return: whether the
    // component must OUTLIVE the call is decided from the signature, which is not
    // known until it is open. Stack locals (what this used to use) foreclose that
    // decision — they made an `own` result a handle into a table destroyed one
    // line later: a number naming nothing, or naming a DIFFERENT resource in
    // whatever instance it was next handed to (ADR-0159 amendment 1).
    const box = try openComponentBoxed(rt, bytes, .{}, loc);
    var escapes = false;
    defer if (!escapes) freeComponentBox(rt, box);

    var arena = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena.deinit();
    const sig = (box.opened.resolveFuncSig(arena.allocator(), fname) catch null) orelse
        return error_catalog.raise(.wasm_export_not_found, loc, .{ .name = fname });

    if (sig.result == null or !witTypeHoldsResource(sig.result.?)) {
        // Nothing in the result can outlive the instance, so the one-shot keeps
        // its deterministic teardown — the common case is unchanged.
        //
        // `owner` is nil: the component was created inside this call, so no
        // handle a caller could hold belongs to it, and every resource ARGUMENT
        // is rejected. That is the right answer rather than a special rule —
        // a resource param on this path never had a valid value.
        return invokeWithSig(rt, &box.opened, sig, fname, args[2..], loc, Value.nil_val);
    }

    // The result names something inside the instance, so the instance's lifetime
    // becomes its reachability — the same GC-owned box `wasm/load-component`
    // builds. `own` then has ONE meaning on both entry points, and
    // `resource-drop` / `with-resource` work here exactly as they do there.
    const handle = try host_instance.alloc(rt, &component_descriptor, .{ @intFromPtr(box), 0, 0, 0 });
    escapes = true;
    return invokeWithSig(rt, &box.opened, sig, fname, args[2..], loc, handle);
}

/// Does this WIT type hold a resource handle anywhere inside it? Recursive
/// because `record { handle: own<T> }` and `list<own<T>>` are handles too — a
/// check that only looked at the top level would let the nested ones through.
fn witTypeHoldsResource(ty: WitType) bool {
    return switch (ty) {
        .own, .borrow => true,
        .list, .option => |inner| witTypeHoldsResource(inner.*),
        .tuple => |ts| for (ts) |t| {
            if (witTypeHoldsResource(t)) break true;
        } else false,
        .record => |fs| for (fs) |f| {
            if (witTypeHoldsResource(f.ty)) break true;
        } else false,
        .variant => |cs| for (cs) |c| {
            if (c.payload) |pt| if (witTypeHoldsResource(pt.*)) break true;
        } else false,
        .result => |r| (r.ok != null and witTypeHoldsResource(r.ok.?.*)) or
            (r.err != null and witTypeHoldsResource(r.err.?.*)),
        .prim, .enum_, .flags => false,
    };
}

/// resolveFuncSig → `invokeWithSig`, on an already-open `Opened`. The
/// `component-call` entry point; the one-shot resolves the signature itself
/// because it decides the component's lifetime from it.
fn invokeOnOpened(rt: *Runtime, box: *ComponentLoaded, fname: []const u8, call_args: []const Value, loc: SourceLocation, component_handle: Value) anyerror!Value {
    const sig = (try box.funcSig(fname)) orelse
        return error_catalog.raise(.wasm_export_not_found, loc, .{ .name = fname });
    return invokeWithSig(rt, &box.opened, sig, fname, call_args, loc, component_handle);
}

/// lower args → invokeTyped → lift result, against an already-resolved signature.
/// `component_handle` (ADR-0159) is the component that owns both sides: an `own`
/// result wraps into a GC-resource rooting it, and a resource ARGUMENT must
/// already belong to it. `nil` means the component is anonymous (a one-shot whose
/// result holds no resource) — then no resource argument can be valid either.
fn invokeWithSig(rt: *Runtime, opened: *comp.Opened, sig: anytype, fname: []const u8, call_args: []const Value, loc: SourceLocation, component_handle: Value) anyerror!Value {
    if (call_args.len != sig.params.len)
        return error_catalog.raise(.wasm_arity_mismatch, loc, .{ .name = fname, .expected = sig.params.len, .actual = call_args.len });
    var arena = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena.deinit();
    // Scalar-sized calls lower entirely on the stack; only a large payload
    // (long string / list) reaches the arena's heap.
    var sfa = std.heap.stackFallback(512, arena.allocator());
    const scratch = sfa.get();

    const in = try scratch.alloc(ComponentValue, call_args.len);
    for (call_args, sig.params, 0..) |a, p, i| in[i] = try lower(rt, scratch, a, p.ty, loc, component_handle);

    const out = opened.invokeTyped(fname, in, rt.gpa) catch |e| switch (e) {
        error.OutOfFuel => return error_catalog.raise(.wasm_component_fuel_exhausted, loc, .{}),
        else => return error_catalog.raise(.wasm_component_trap, loc, .{}),
    };
    if (out) |o| {
        defer o.deinit(rt.gpa);
        // `lift` builds nested collections from unrooted locals.
        rt.gc.enterFabrication();
        defer rt.gc.exitFabrication();
        return try lift(rt, o, loc, component_handle);
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
    /// Export name -> resolved `FuncSig`, per handle (CLJW-COMPONENT-CALL-CACHE).
    /// Borrows names from `opened`'s TypeInfo, so it is torn down first.
    sigs: SigCache,

    fn funcSig(self: *ComponentLoaded, name: []const u8) std.mem.Allocator.Error!?comp.FuncSig {
        return self.sigs.get(&self.opened, name);
    }
};

/// `.host_instance` finaliser for a component handle: state[0] is the
/// `*ComponentLoaded`. Frees the zwasm triple in LIFO order. No-GC-trace: every
/// field lives in zwasm's separate space (F-006), so the descriptor sets no
/// `host_trace`.
/// Open a component into the heap-allocated `ComponentLoaded` triple both entry
/// points hand to the GC. Every partial-failure unwind lives here rather than at
/// the call sites: the one-shot path has to decide AFTER opening whether the box
/// escapes, and a caller-side `errdefer` for the same resources would then fire
/// alongside its own teardown and double-free (it did — an `0xaa…` segfault on
/// the error path).
fn openComponentBoxed(rt: *Runtime, bytes: []const u8, opts: comp.InstantiateOpts, loc: SourceLocation) anyerror!*ComponentLoaded {
    const engine = try rt.gpa.create(zwasm.Engine);
    errdefer rt.gpa.destroy(engine);
    engine.* = zwasm.Engine.init(rt.gpa, .{}) catch
        return error_catalog.raise(.wasm_load_failed, loc, .{});
    errdefer engine.deinit();

    const host = try rt.gpa.create(WasiHost);
    errdefer rt.gpa.destroy(host);
    var opened = try openComponent(rt, engine, host, bytes, opts, loc);
    // LIFO: `opened` borrows `host`, so host.deinit registers first and runs last.
    errdefer host.deinit();
    errdefer opened.deinit();

    const box = try rt.gpa.create(ComponentLoaded);
    box.* = .{ .engine = engine, .host = host, .opened = opened, .sigs = SigCache.init(rt.gpa) };
    return box;
}

/// Release a `ComponentLoaded` — the same order `componentFinalise` uses, for a
/// box that never reached the GC.
fn freeComponentBox(rt: *Runtime, box: *ComponentLoaded) void {
    box.opened.deinit();
    box.host.deinit();
    box.engine.deinit();
    rt.gpa.destroy(box.host);
    rt.gpa.destroy(box.engine);
    rt.gpa.destroy(box);
}

fn componentFinalise(infra: std.mem.Allocator, state: *[host_instance.STATE_WORDS]u64) void {
    const box: *ComponentLoaded = @ptrFromInt(state[0]);
    box.sigs.deinit();
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

/// `(wasm/load-component "p.wasm" {:fuel N :max-memory-pages M})` → a cached component handle.
/// Options are optional; omitted axes retain zwasm's finite defaults. Like
/// wasm/load, a nonpositive budget explicitly opts a trusted guest out. Opens once,
/// frees the load buffer immediately (REQ-7), and keeps the `Opened` alive
/// behind a GC-finalised host_instance for `(wasm/component-call …)` to invoke
/// across time.
pub fn loadComponentFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("wasm/load-component", args, 1, 2, loc);
    var opts: comp.InstantiateOpts = .{};
    if (args.len == 2) {
        const parsed = try surface.parseLoadOpts(rt, args[1], loc);
        // Components are interpreter-pinned by zwasm. Do not accept options
        // that would promise an engine or deadline we cannot enforce.
        for ([_][]const u8{ "engine", "timeout-ms" }) |name| {
            const key = try keyword_mod.intern(rt, null, name);
            if (try map_mod.contains(args[1], key))
                return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "components support :fuel and :max-memory-pages, not :engine or :timeout-ms" });
        }
        if (parsed.fuel) |b| opts.fuel = b;
        if (parsed.max_memory_pages) |b| opts.max_memory_pages = b;
    }
    const bytes = try readComponentBytes(rt, args[0], loc);
    defer rt.gpa.free(bytes); // REQ-7: the Opened owns its bytes — drop the load buffer now.

    const box = try openComponentBoxed(rt, bytes, opts, loc);
    errdefer freeComponentBox(rt, box);
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
    // A RESOURCE handle also names its component — it carries the owner in
    // state[0], which is the whole point of the wrapper. Accepting it here is
    // what makes a resource returned by a one-shot `component-invoke` usable:
    // that component has no other name, so without this the caller would hold a
    // live handle it could only drop, never call a method on.
    const comp_handle = if (isResourceHandle(args[0])) blk: {
        const inst = host_instance.asHostInstance(args[0]);
        if (inst.state[2] != 0) return error_catalog.raise(.wasm_resource_dropped, loc, .{});
        break :blk @as(Value, @enumFromInt(inst.state[0]));
    } else args[0];
    if (comp_handle.tag() != .host_instance or
        host_instance.asHostInstance(comp_handle).descriptor != &component_descriptor)
        return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "wasm/component-call expects a (wasm/load-component …) handle or a resource handle from one" });
    if (!args[1].isString())
        return error_catalog.raise(.wasm_export_name_invalid, loc, .{});
    const box: *ComponentLoaded = @ptrFromInt(host_instance.asHostInstance(comp_handle).state[0]);
    // Pass the component handle so an `own` result wraps into a GC-resource that
    // roots THIS component (ADR-0159).
    return invokeOnOpened(rt, box, string_mod.asString(args[1]), args[2..], loc, comp_handle);
}

const testing = std.testing;

/// The Fixture shape used across `runtime/` unit tests (cf. `numeric/promote.zig`).
const TestFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,

    fn init() TestFixture {
        var fix: TestFixture = .{
            .threaded = std.Io.Threaded.init(testing.allocator, .{}),
            .rt = undefined,
        };
        fix.rt = Runtime.init(fix.threaded.io(), testing.allocator);
        return fix;
    }
    fn deinit(self: *TestFixture) void {
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "lifting a u64 above i64's max is exact, not a ReleaseSafe panic" {
    var fix = TestFixture.init();
    defer fix.deinit();

    // The old code was `Value.initInteger(@intCast(n))`. In ReleaseSafe — the
    // SHIPPED config — that cast is a process-killing safety panic, and `n`
    // here is data the GUEST chose: an untrusted component could take the host
    // down by returning a large u64.
    const big: u64 = std.math.maxInt(u64);
    const v = try bigFromU64(&fix.rt, big);
    try testing.expect(v.tag() == .big_int);

    // Exact, not rounded: 18446744073709551615 must survive as itself.
    var buf: [64]u8 = undefined;
    const m = big_int.asManaged(v);
    const s = try m.toString(testing.allocator, 10, .lower);
    defer testing.allocator.free(s);
    _ = &buf;
    try testing.expectEqualStrings("18446744073709551615", s);
}

test "lifting an s64 outside i48 stays exact instead of demoting to a lossy float" {
    var fix = TestFixture.init();
    defer fix.deinit();

    // `Value.initInteger` silently demotes an out-of-i48 value to a float (its
    // own doc comment says so), and i48 tops out around 1.4e14 — well inside
    // what a guest can legitimately return. Route through the canonical
    // exact-i64 entry instead.
    const n: i64 = std.math.maxInt(i64);
    const v = try promote.wrapI64(&fix.rt, n);
    try testing.expect(v.tag() != .float);

    const m = big_int.asManaged(v);
    const s = try m.toString(testing.allocator, 10, .lower);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("9223372036854775807", s);
}

test "lowering an out-of-range integer is a catchable error, not a panic" {
    // 300 does not fit a WIT `u8`. The component path used a bare `@intCast`
    // and panicked; it now shares `wasm/call`'s range check, whose own doc
    // states the invariant the component path was breaking — "no host crash on
    // caller data".
    const loc: SourceLocation = .{};
    try testing.expectError(
        error.ValueError,
        marshal.coerceInt(Value.initInteger(300), u8, loc),
    );
    // …and an in-range value still passes.
    try testing.expectEqual(@as(u8, 200), try marshal.coerceInt(Value.initInteger(200), u8, loc));
}

/// `[:tag …]` from Zig, so a lowering test does not need a live component.
fn taggedVec(rt: *Runtime, tag: []const u8, payload: ?Value) !Value {
    var out = vector_mod.empty();
    out = try vector_mod.conj(rt, out, try keyword_mod.intern(rt, null, tag));
    if (payload) |pv| out = try vector_mod.conj(rt, out, pv);
    return out;
}

test "result and variant lower from the tagged-vector shape the lift produces" {
    var fix = TestFixture.init();
    defer fix.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loc: SourceLocation = .{};

    // Both were `feature_not_supported`, so ADR-0135 amendment 2's round-trip
    // was one-way: a component taking a `result` or `variant` param could not
    // be called at all, and the shapes the lift hands back could not be handed
    // in. These assert the two directions now agree.
    const u32_ty: WitType = .{ .prim = .u32 };
    const str_ty: WitType = .{ .prim = .string };
    const res_ty: WitType = .{ .result = .{ .ok = &u32_ty, .err = &str_ty } };

    const ok = try lower(&fix.rt, a, try taggedVec(&fix.rt, "ok", Value.initInteger(7)), res_ty, loc, Value.nil_val);
    try testing.expect(ok.result.is_ok);
    try testing.expectEqual(@as(u32, 7), ok.result.payload.?.u32);

    const err = try lower(&fix.rt, a, try taggedVec(&fix.rt, "err", try string_mod.alloc(&fix.rt, "boom")), res_ty, loc, Value.nil_val);
    try testing.expect(!err.result.is_ok);
    try testing.expectEqualStrings("boom", err.result.payload.?.string);

    const f64_ty: WitType = .{ .prim = .f64 };
    const cases = [_]WitType.Case{
        .{ .name = "circle", .payload = &f64_ty },
        .{ .name = "point", .payload = null },
    };
    const var_ty: WitType = .{ .variant = &cases };

    const circle = try lower(&fix.rt, a, try taggedVec(&fix.rt, "circle", Value.initFloat(1.5)), var_ty, loc, Value.nil_val);
    try testing.expectEqual(@as(u32, 0), circle.variant.case);
    try testing.expectEqual(@as(f64, 1.5), circle.variant.payload.?.f64);

    // A payload-less case is `[:tag]`, not `[:tag nil]` — the lift emits the
    // one-element form, so lowering must accept exactly that.
    const point = try lower(&fix.rt, a, try taggedVec(&fix.rt, "point", null), var_ty, loc, Value.nil_val);
    try testing.expectEqual(@as(u32, 1), point.variant.case);
    try testing.expect(point.variant.payload == null);
}

test "a malformed tagged vector is a catchable usage error, not a silent nil" {
    var fix = TestFixture.init();
    defer fix.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loc: SourceLocation = .{};

    const u32_ty: WitType = .{ .prim = .u32 };
    const str_ty: WitType = .{ .prim = .string };
    const res_ty: WitType = .{ .result = .{ .ok = &u32_ty, .err = &str_ty } };
    const cases = [_]WitType.Case{.{ .name = "point", .payload = null }};
    const var_ty: WitType = .{ .variant = &cases };

    // Not a vector at all.
    try testing.expectError(error.ValueError, lower(&fix.rt, a, try keyword_mod.intern(&fix.rt, null, "ok"), res_ty, loc, Value.nil_val));
    // A tag that names no case: silently choosing case 0 would send the guest
    // a different variant than the caller wrote.
    try testing.expectError(error.ValueError, lower(&fix.rt, a, try taggedVec(&fix.rt, "nope", Value.initInteger(1)), res_ty, loc, Value.nil_val));
    try testing.expectError(error.ValueError, lower(&fix.rt, a, try taggedVec(&fix.rt, "square", Value.initInteger(1)), var_ty, loc, Value.nil_val));
    // Payload arity disagreeing with the case's type, in both directions.
    try testing.expectError(error.ValueError, lower(&fix.rt, a, try taggedVec(&fix.rt, "ok", null), res_ty, loc, Value.nil_val));
    try testing.expectError(error.ValueError, lower(&fix.rt, a, try taggedVec(&fix.rt, "point", Value.initInteger(1)), var_ty, loc, Value.nil_val));
}

test "a resource nested inside an aggregate still makes the component outlive the call" {
    // The one-shot's lifetime decision reads this predicate. A top-level-only
    // check would pass `record { text: string, handle: own<T> }` through the
    // teardown branch and hand back a wrapper whose component is already gone —
    // the same defect the fix removes, one level down.
    const own_ty: WitType = .{ .own = 0 };
    const str_ty: WitType = .{ .prim = .string };
    try testing.expect(witTypeHoldsResource(own_ty));
    try testing.expect(witTypeHoldsResource(.{ .borrow = 0 }));
    try testing.expect(!witTypeHoldsResource(str_ty));
    try testing.expect(!witTypeHoldsResource(.{ .enum_ = &.{"a"} }));

    try testing.expect(witTypeHoldsResource(.{ .list = &own_ty }));
    try testing.expect(witTypeHoldsResource(.{ .option = &own_ty }));
    try testing.expect(!witTypeHoldsResource(.{ .list = &str_ty }));

    const fields = [_]WitType.Field{
        .{ .name = "text", .ty = str_ty },
        .{ .name = "handle", .ty = own_ty },
    };
    try testing.expect(witTypeHoldsResource(.{ .record = &fields }));
    try testing.expect(!witTypeHoldsResource(.{ .record = &[_]WitType.Field{.{ .name = "text", .ty = str_ty }} }));

    try testing.expect(witTypeHoldsResource(.{ .tuple = &[_]WitType{ str_ty, own_ty } }));
    try testing.expect(!witTypeHoldsResource(.{ .tuple = &[_]WitType{ str_ty, str_ty } }));

    const cases = [_]WitType.Case{
        .{ .name = "none", .payload = null },
        .{ .name = "some", .payload = &own_ty },
    };
    try testing.expect(witTypeHoldsResource(.{ .variant = &cases }));
    try testing.expect(!witTypeHoldsResource(.{ .variant = &[_]WitType.Case{.{ .name = "none", .payload = null }} }));

    // Both arms of a result, and neither.
    try testing.expect(witTypeHoldsResource(.{ .result = .{ .ok = &own_ty, .err = &str_ty } }));
    try testing.expect(witTypeHoldsResource(.{ .result = .{ .ok = &str_ty, .err = &own_ty } }));
    try testing.expect(!witTypeHoldsResource(.{ .result = .{ .ok = &str_ty, .err = null } }));

    // Nesting through two levels — `list<record { handle: own<T> }>`.
    const rec: WitType = .{ .record = &fields };
    try testing.expect(witTypeHoldsResource(.{ .list = &rec }));
}
