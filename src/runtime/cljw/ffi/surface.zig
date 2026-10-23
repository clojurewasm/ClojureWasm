// SPDX-License-Identifier: EPL-2.0
//! cljw.ffi native primitives: dlopen a C library and call its symbols
//! (ADR-0202). The public API is the bundled `cljw/ffi.clj`; this file
//! registers the `-`-prefixed leaves it wraps.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: cljw.ffi/open, close, sym, function, call, string, bytes
//!
//! Surface (leaves, interned into `cljw.ffi`):
//!   `(-open path)`                        -> a `cljw.ffi.Library` host instance
//!   `(-close lib)`                        -> nil, idempotent
//!   `(-sym lib name)`                     -> the symbol address as an integer
//!   `(-prepare lib name [types] ret)`     -> a `cljw.ffi.Function` host instance
//!   `(-invoke lib fn-handle & args)`      -> the converted C return value
//!   `(-string ptr)` / `(-bytes ptr n)`    -> copies out of C memory
//!
//! Errors are `ex-info` with `{:ffi/error <kind> ...}` data, the contract
//! shared with clojurust's `clojure.rust.ffi`, so they are built here rather
//! than through the error catalog (whose exceptions carry no ex-data).
//!
//! Ownership: a Library holds the dlopen handle in `state[0]` (0 once closed)
//! and its finaliser closes a dropped one. Libraries open with RTLD_NODELETE,
//! so `dlclose` never unmaps code a Go or Rust runtime inside the library still
//! runs. A Function holds the symbol address and the packed signature; it
//! does not own the library, the Clojure closure in `ffi.clj` keeps both alive.
const std = @import("std");
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const Value = @import("../../value/value.zig").Value;
const error_catalog = @import("../../error/catalog.zig");
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const string_mod = @import("../../collection/string.zig");
const vector_mod = @import("../../collection/vector.zig");
const map_mod = @import("../../collection/map.zig");
const java_array = @import("../../collection/java_array.zig");
const ex_info = @import("../../collection/ex_info.zig");
const keyword_mod = @import("../../keyword.zig");
const dispatch = @import("../../dispatch.zig");
const promote = @import("../../numeric/promote.zig");
const host_instance = @import("../../host_instance.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const safepoint = @import("../../concurrency/safepoint.zig");
const abi = @import("abi.zig");

// ── Errors as data ──────────────────────────────────────────────────────────

const Field = struct {
    key: []const u8,
    val: union(enum) { kw: []const u8, str: []const u8, int: i64, value: Value },
};

/// Throw `(ex-info msg {:ffi/error kind ...fields})`.
fn fail(rt: *Runtime, kind: []const u8, fields: []const Field, comptime fmt: []const u8, fmt_args: anytype) anyerror {
    const msg = try std.fmt.allocPrint(rt.gpa, "ffi: " ++ fmt, fmt_args);
    defer rt.gpa.free(msg);
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    var data = map_mod.empty();
    data = try map_mod.assoc(rt, data, try keyword_mod.intern(rt, "ffi", "error"), try keyword_mod.intern(rt, null, kind));
    for (fields) |f| {
        const v = switch (f.val) {
            .kw => |s| try keyword_mod.intern(rt, null, s),
            .str => |s| try string_mod.alloc(rt, s),
            .int => |i| Value.initInteger(i),
            .value => |x| x,
        };
        data = try map_mod.assoc(rt, data, try keyword_mod.intern(rt, null, f.key), v);
    }
    dispatch.last_thrown_exception = try ex_info.alloc(rt, msg, data, Value.nil_val);
    return error.ThrownValue;
}

fn failArgType(rt: *Runtime, index: usize, type_name: []const u8) anyerror {
    return fail(rt, "arg-type", &.{
        .{ .key = "index", .val = .{ .int = @intCast(index) } },
        .{ .key = "type", .val = .{ .kw = type_name } },
    }, "argument {d} is not a valid :{s}", .{ index, type_name });
}

fn failClosed(rt: *Runtime) anyerror {
    return fail(rt, "closed", &.{}, "the library is closed", .{});
}

fn failSignature(rt: *Runtime, name: []const u8, reason: []const u8) anyerror {
    return fail(rt, "signature", &.{
        .{ .key = "symbol", .val = .{ .str = name } },
        .{ .key = "reason", .val = .{ .str = reason } },
    }, "bad signature for {s}: {s}", .{ name, reason });
}

/// The text of the last dl* failure, or a fixed fallback.
fn dlReason() []const u8 {
    return if (std.c.dlerror()) |p| std.mem.span(p) else "unknown dynamic loader error";
}

// ── Host objects ────────────────────────────────────────────────────────────

var library_descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.ffi.Library",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
    .host_finalise = &finaliseLibrary,
};

var function_descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.ffi.Function",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};

fn isA(v: Value, d: *const type_descriptor.TypeDescriptor) bool {
    return v.tag() == .host_instance and host_instance.asHostInstance(v).descriptor == d;
}

/// ADR-0106 finaliser: close a library the program dropped without `close`.
fn finaliseLibrary(infra: std.mem.Allocator, state: *[host_instance.STATE_WORDS]u64) void {
    _ = infra;
    if (state[0] == 0) return;
    _ = std.c.dlclose(@ptrFromInt(@as(usize, @intCast(state[0]))));
    state[0] = 0;
}

/// The open dlopen handle behind `lib`, or the `:closed` / `:arg-type` throw.
fn openHandle(rt: *Runtime, lib: Value) !*anyopaque {
    if (!isA(lib, &library_descriptor)) return failArgType(rt, 0, "library");
    const h = host_instance.asHostInstance(lib).state[0];
    if (h == 0) return failClosed(rt);
    return @ptrFromInt(@as(usize, @intCast(h)));
}

/// A NUL-terminated copy of a string argument, owned by `gpa`.
fn symbolName(rt: *Runtime, v: Value, index: usize) ![:0]u8 {
    if (!v.isString()) return failArgType(rt, index, "string");
    return rt.gpa.dupeZ(u8, string_mod.asString(v));
}

/// The address `v` names: nil is 0, an integer is taken as unsigned.
fn addressOf(v: Value) ?usize {
    if (v.isNil()) return 0;
    const i = promote.exactI64(v) catch return null;
    return @bitCast(i);
}

/// A `:pointer` argument: an address, or a primitive array passed as the
/// address of its storage (no copy; C reads and writes the elements in place,
/// valid for the call). The array is an argument, so it stays rooted, and the
/// collector never moves it.
fn pointerArg(v: Value) ?usize {
    if (java_array.isArray(v)) {
        const a = java_array.asArray(v);
        if (a.kind == .object) return null;
        return @intFromPtr(a.data);
    }
    return addressOf(v);
}

// ── Leaves ──────────────────────────────────────────────────────────────────

fn openFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("cljw.ffi/open", args, 1, loc);
    const path = try symbolName(rt, args[0], 0);
    defer rt.gpa.free(path);
    const handle = std.c.dlopen(path.ptr, .{ .NOW = true, .NODELETE = true }) orelse {
        const reason = dlReason();
        return fail(rt, "open", &.{
            .{ .key = "path", .val = .{ .value = args[0] } },
            .{ .key = "reason", .val = .{ .str = reason } },
        }, "cannot open {s}: {s}", .{ path, reason });
    };
    return host_instance.alloc(rt, &library_descriptor, .{ @intFromPtr(handle), 0, 0, 0 });
}

fn closeFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("cljw.ffi/close", args, 1, loc);
    if (!isA(args[0], &library_descriptor)) return failArgType(rt, 0, "library");
    const h = host_instance.asHostInstance(args[0]).state[0];
    if (h != 0) {
        host_instance.setState(args[0], 0, 0);
        _ = std.c.dlclose(@ptrFromInt(@as(usize, @intCast(h))));
    }
    return Value.nil_val;
}

/// dlsym `name` in `lib`; the `:symbol` throw when absent.
fn lookup(rt: *Runtime, lib: Value, name_v: Value) !usize {
    const handle = try openHandle(rt, lib);
    const name = try symbolName(rt, name_v, 1);
    defer rt.gpa.free(name);
    _ = std.c.dlerror();
    const addr = std.c.dlsym(handle, name.ptr) orelse
        return fail(rt, "symbol", &.{.{ .key = "symbol", .val = .{ .value = name_v } }}, "symbol not found: {s}", .{name});
    return @intFromPtr(addr);
}

fn symFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("cljw.ffi/sym", args, 2, loc);
    return promote.wrapI64(rt, @bitCast(@as(u64, try lookup(rt, args[0], args[1]))));
}

/// The `abi.Type` a type keyword names, or the `:signature` throw.
fn typeOf(rt: *Runtime, sym_name: []const u8, v: Value) !abi.Type {
    if (v.tag() == .keyword) {
        const kw = keyword_mod.asKeyword(v);
        if (kw.ns == null) if (abi.Type.fromName(kw.name)) |t| return t;
        var buf: [96]u8 = undefined;
        return failSignature(rt, sym_name, std.fmt.bufPrint(&buf, "unknown type :{s}", .{kw.name}) catch "unknown type");
    }
    return failSignature(rt, sym_name, "a type must be a keyword");
}

fn prepareFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("cljw.ffi/function", args, 4, loc);
    _ = try openHandle(rt, args[0]);
    if (!args[1].isString()) return failArgType(rt, 1, "string");
    const name = string_mod.asString(args[1]);

    const types_v = args[2];
    if (!types_v.isNil() and types_v.tag() != .vector) return failSignature(rt, name, "the argument types must be a vector");
    const n: u32 = if (types_v.isNil()) 0 else vector_mod.count(types_v);
    if (n > abi.MAX_ARGS) return failSignature(rt, name, "more than 14 arguments");
    var types: [abi.MAX_ARGS]abi.Type = undefined;
    for (0..n) |i| types[i] = try typeOf(rt, name, vector_mod.nth(types_v, @intCast(i)));
    const ret = try typeOf(rt, name, args[3]);

    const sig = switch (abi.Signature.init(types[0..n], ret)) {
        .ok => |s| s,
        .err => |e| return failSignature(rt, name, e.reason()),
    };
    const addr = try lookup(rt, args[0], args[1]);
    return host_instance.alloc(rt, &function_descriptor, .{ addr, sig.pack(), 0, 0 });
}

/// Scratch copies that must outlive the call and no longer: `:string` and
/// `:bytes` arguments. Raw allocations: each is overwritten whole at once,
/// so the safe-build `undefined` fill `Allocator.alloc`/`free` add would be
/// two more passes over every byte.
const Temps = struct {
    bufs: [abi.MAX_INT_ARGS][]u8 = undefined,
    n: usize = 0,

    fn alloc(t: *Temps, gpa: std.mem.Allocator, n: usize) ![]u8 {
        const len = @max(n, 1);
        const p = gpa.rawAlloc(len, .@"1", @returnAddress()) orelse return error.OutOfMemory;
        t.bufs[t.n] = p[0..len];
        t.n += 1;
        return p[0..len];
    }

    fn free(t: *Temps, gpa: std.mem.Allocator) void {
        for (t.bufs[0..t.n]) |b| gpa.rawFree(b, .@"1", @returnAddress());
    }
};

/// Place argument `i` of type `t` into `slots`.
fn marshal(rt: *Runtime, i: usize, t: abi.Type, v: Value, slots: *abi.Slots, temps: *Temps) !void {
    switch (t) {
        .int => {
            const x = promote.exactI64(v) catch return failArgType(rt, i, "int");
            slots.putInt(@bitCast(@as(i64, @as(i32, @truncate(x)))));
        },
        .long => {
            const x = promote.exactI64(v) catch return failArgType(rt, i, "long");
            slots.putInt(@bitCast(x));
        },
        .pointer => slots.putInt(pointerArg(v) orelse return failArgType(rt, i, "pointer")),
        .double => slots.putDouble(switch (v.tag()) {
            .float => v.asFloat(),
            .integer => @floatFromInt(v.asInteger()),
            else => return failArgType(rt, i, "double"),
        }),
        .string => {
            if (v.isNil()) return slots.putInt(0);
            if (!v.isString()) return failArgType(rt, i, "string");
            const s = string_mod.asString(v);
            const z = try temps.alloc(rt.gpa, s.len + 1);
            @memcpy(z[0..s.len], s);
            z[s.len] = 0;
            slots.putInt(@intFromPtr(z.ptr));
        },
        .bytes => {
            if (v.isNil()) return slots.putInt(0);
            if (!java_array.isKind(v, .byte)) return failArgType(rt, i, "bytes");
            const src = java_array.asArray(v).bytes();
            const buf = try temps.alloc(rt.gpa, src.len);
            @memcpy(buf[0..src.len], src);
            slots.putInt(@intFromPtr(buf.ptr));
        },
        .void => unreachable,
    }
}

/// A copy of the NUL-terminated C string at `addr`, or nil for NULL.
fn stringAt(rt: *Runtime, addr: usize) !Value {
    if (addr == 0) return Value.nil_val;
    const p: [*:0]const u8 = @ptrFromInt(addr);
    return string_mod.alloc(rt, std.mem.span(p));
}

fn invokeFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityMin("cljw.ffi/invoke", args, 2, loc);
    _ = try openHandle(rt, args[0]);
    if (!isA(args[1], &function_descriptor)) return failArgType(rt, 1, "function");
    const state = host_instance.asHostInstance(args[1]).state;
    const sig = abi.Signature.unpack(state[1]);
    const call_args = args[2..];
    if (call_args.len != sig.argc) return fail(rt, "arity", &.{
        .{ .key = "expected", .val = .{ .int = sig.argc } },
        .{ .key = "got", .val = .{ .int = @intCast(call_args.len) } },
    }, "wrong number of arguments: expected {d}, got {d}", .{ sig.argc, call_args.len });

    var slots: abi.Slots = .{};
    var temps: Temps = .{};
    defer temps.free(rt.gpa);
    for (sig.argTypes(), call_args, 0..) |t, v, i| try marshal(rt, i, t, v, &slots, &temps);

    const raw = safepoint.blocking(abi.call, .{ @as(usize, @intCast(state[0])), sig.ret, &slots });
    return switch (sig.ret) {
        .void => Value.nil_val,
        .int => Value.initInteger(abi.intFromWord(raw.word)),
        .long, .pointer => promote.wrapI64(rt, @bitCast(@as(u64, raw.word))),
        .double => Value.initFloat(raw.double),
        .string => stringAt(rt, raw.word),
        .bytes => unreachable,
    };
}

fn stringFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("cljw.ffi/string", args, 1, loc);
    const addr = addressOf(args[0]) orelse return failArgType(rt, 0, "pointer");
    return stringAt(rt, addr);
}

fn bytesFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("cljw.ffi/bytes", args, 2, loc);
    const addr = addressOf(args[0]) orelse return failArgType(rt, 0, "pointer");
    const n = promote.exactI64(args[1]) catch return failArgType(rt, 1, "long");
    if (n < 0 or n > std.math.maxInt(u32)) return failArgType(rt, 1, "long");
    if (addr == 0) return Value.nil_val;
    const src: [*]const u8 = @ptrFromInt(addr);
    return java_array.fromBytes(rt, src[0..@intCast(n)]);
}

/// Create the `cljw.ffi` leaves. Called by `runtime/cljw/_host_api.zig`
/// when `build_options.ffi` is set (x86_64 / aarch64, Linux or macOS).
pub fn register(env: *Env) !void {
    const ns = try env.findOrCreateNs("cljw.ffi");
    _ = try env.intern(ns, "-open", Value.initBuiltinFn(&openFn), null);
    _ = try env.intern(ns, "-close", Value.initBuiltinFn(&closeFn), null);
    _ = try env.intern(ns, "-sym", Value.initBuiltinFn(&symFn), null);
    _ = try env.intern(ns, "-prepare", Value.initBuiltinFn(&prepareFn), null);
    _ = try env.intern(ns, "-invoke", Value.initBuiltinFn(&invokeFn), null);
    _ = try env.intern(ns, "-string", Value.initBuiltinFn(&stringFn), null);
    _ = try env.intern(ns, "-bytes", Value.initBuiltinFn(&bytesFn), null);
}

test {
    _ = abi;
}
