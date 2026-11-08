// SPDX-License-Identifier: EPL-2.0
//! Layer 7 (Property) — laws the printer obeys for every input. ADR-0186.
//!
//! The oracle is `std.fmt.parseFloat`, which shares no implementation with
//! `printFloat`, so agreement between them is evidence rather than a tautology.
//!
//! Boundaries the generator crosses on purpose: both zeros, both infinities,
//! NaN, the smallest denormal, `f64` max, and the decimal/exponent switch the
//! renderer makes around 1.0E7 and 1.0E-3.

const std = @import("std");
const prop = @import("prop.zig");
const build_options = @import("build_options");
const print = @import("../runtime/print.zig");
const string_escape = @import("../runtime/string_escape.zig");
const value_mod = @import("../runtime/value/value.zig");
const Value = value_mod.Value;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const Env = @import("../runtime/env.zig").Env;
const SourceLocation = @import("../runtime/error/info.zig").SourceLocation;
const keyword = @import("../runtime/keyword.zig");
const string_collection = @import("../runtime/collection/string.zig");
const vector_collection = @import("../runtime/collection/vector.zig");
const map_collection = @import("../runtime/collection/map.zig");
const set_collection = @import("../runtime/collection/set.zig");

const Writer = std.Io.Writer;
const testing = std.testing;

/// One value nesting a vector, a map and a set over leaves of every scalar
/// kind, shaped by the generated ints so a slice covers many structures rather
/// than one. The map crosses the ArrayMap -> HAMT boundary at 16 entries and
/// the set at 8, which is where the printer switches walk.
fn buildNested(rt: *Runtime, xs: []i64) !Value {
    var vec = vector_collection.empty();
    var map = map_collection.empty();
    var set = set_collection.empty();
    for (xs, 0..) |x, i| {
        const leaf: Value = switch (@as(u3, @truncate(@as(u64, @bitCast(x))))) {
            0, 1 => Value.initInteger(x),
            2 => Value.initFloat(@as(f64, @floatFromInt(@rem(x, 1_000_000)))),
            3 => try keyword.intern(rt, null, "k"),
            4 => try string_collection.alloc(rt, "a\"b\n"),
            5 => .true_val,
            6 => .nil_val,
            7 => Value.initChar('x'),
        };
        vec = try vector_collection.conj(rt, vec, leaf);
        map = try map_collection.assoc(rt, map, Value.initInteger(@intCast(i)), leaf);
        set = try set_collection.conj(rt, set, leaf);
    }
    var out = try vector_collection.conj(rt, vector_collection.empty(), vec);
    out = try vector_collection.conj(rt, out, map);
    out = try vector_collection.conj(rt, out, set);
    return try map_collection.assoc(rt, map_collection.empty(), try keyword.intern(rt, null, "root"), out);
}

/// Gate defaults, overridable for a sweep: `zig build test -Dprop-seed=0x… -Dprop-iters=…`.
fn config() prop.Config {
    return .{ .seed = build_options.prop_seed, .iters = build_options.prop_iters };
}

/// Values a uniform bit pattern would essentially never produce, drawn often
/// enough that every printer branch is reached.
const specials = [_]f64{
    0.0,                    -0.0,                       1.0,               -1.0,
    0.5,                    0.1,                        1.0e7,             9.999999e6,
    1.0e-3,                 9.99e-4,                    1.0e20,            1.0e-20,
    std.math.inf(f64),      -std.math.inf(f64),         std.math.nan(f64), std.math.floatMin(f64),
    std.math.floatMax(f64), std.math.floatTrueMin(f64),
};

/// A slice of f64 spanning the whole space: one third named boundaries, the
/// rest uniform 64-bit patterns (which include denormals and NaN payloads).
const FloatSlice = struct {
    max_len: usize = 24,

    pub fn generate(self: FloatSlice, rand: std.Random, alloc: std.mem.Allocator, size: usize) ![]f64 {
        const len = rand.uintLessThan(usize, @min(size, self.max_len) + 1);
        const out = try alloc.alloc(f64, len);
        for (out) |*slot| {
            slot.* = if (rand.uintLessThan(u8, 3) == 0)
                specials[rand.uintLessThan(usize, specials.len)]
            else
                @bitCast(rand.int(u64));
        }
        return out;
    }

    /// Drop a chunk, then halve one element toward zero.
    pub fn shrink(self: FloatSlice, alloc: std.mem.Allocator, v: []f64, out: *std.ArrayList([]f64)) !void {
        _ = self;
        if (v.len > 0) {
            try out.append(alloc, try alloc.dupe(f64, v[0 .. v.len / 2]));
            try out.append(alloc, try alloc.dupe(f64, v[v.len / 2 ..]));
        }
        for (v, 0..) |x, i| {
            if (x == 0 or !std.math.isFinite(x)) continue;
            const smaller = try alloc.dupe(f64, v);
            smaller[i] = x / 2.0;
            try out.append(alloc, smaller);
            break;
        }
    }

    pub fn free(self: FloatSlice, alloc: std.mem.Allocator, v: []f64) void {
        _ = self;
        alloc.free(v);
    }

    pub fn describe(self: FloatSlice, alloc: std.mem.Allocator, v: []f64) ![]u8 {
        _ = self;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        try buf.append(alloc, '[');
        for (v, 0..) |x, i| {
            if (i > 0) try buf.appendSlice(alloc, ", ");
            try buf.print(alloc, "{d} (0x{x})", .{ x, @as(u64, @bitCast(x)) });
        }
        try buf.append(alloc, ']');
        return buf.toOwnedSlice(alloc);
    }
};

fn renderFloat(buf: []u8, f: f64) ![]const u8 {
    var w: Writer = .fixed(buf);
    try print.printFloat(&w, f);
    return w.buffered();
}

/// Every finite float prints to something that parses back to the SAME bits,
/// and every non-finite one prints to its reader literal.
fn roundTrips(_: void, xs: []f64) anyerror!void {
    var buf: [512]u8 = undefined;
    for (xs) |f| {
        const s = try renderFloat(&buf, f);
        if (std.math.isNan(f)) {
            try testing.expectEqualStrings("##NaN", s);
        } else if (std.math.isPositiveInf(f)) {
            try testing.expectEqualStrings("##Inf", s);
        } else if (std.math.isNegativeInf(f)) {
            try testing.expectEqualStrings("##-Inf", s);
        } else {
            const back = std.fmt.parseFloat(f64, s) catch return error.PrintedFloatDoesNotParse;
            // Bit equality, not `==`: it separates 0.0 from -0.0, which `==` does not.
            if (@as(u64, @bitCast(back)) != @as(u64, @bitCast(f))) return error.FloatRoundTripLostBits;
        }
    }
}

/// A finite float always prints something a Clojure reader can take back as a
/// float: a digit is present, and the only non-digit characters are the ones
/// float syntax allows.
fn readableShape(_: void, xs: []f64) anyerror!void {
    var buf: [512]u8 = undefined;
    for (xs) |f| {
        if (!std.math.isFinite(f)) continue;
        const s = try renderFloat(&buf, f);
        if (s.len == 0) return error.EmptyRendering;
        var saw_digit = false;
        for (s) |c| switch (c) {
            '0'...'9' => saw_digit = true,
            '.', '-', '+', 'E' => {},
            else => return error.UnexpectedCharacterInFloat,
        };
        if (!saw_digit) return error.NoDigitsInFloat;
        // A float must not render as an integer literal, or reading it back
        // yields a Long.
        if (std.mem.findAny(u8, s, ".E") == null) return error.FloatRendersAsInteger;
    }
}

test "property: printFloat output re-parses to the same f64" {
    try prop.forAll([]f64, testing.allocator, config(), FloatSlice{}, {}, roundTrips);
}

test "property: a finite float renders as float syntax, never integer syntax" {
    try prop.forAll([]f64, testing.allocator, config(), FloatSlice{}, {}, readableShape);
}

// --- string escaping: printString vs the reader's unescape ---

/// Bytes worth drawing far more often than a uniform sample would: the five
/// sequences `printString` escapes, the quote/backslash pair that terminates a
/// token, control bytes it passes through raw, and multi-byte UTF-8 lead bytes.
const interesting_bytes = [_]u8{
    '"',  '\\', '\n', '\t', '\r',
    0x00, 0x01, 0x1f, 0x7f, ' ',
    'a',  'Z',  '0',  ';',  '(',
    ')',  '[',  ']',  '{',  '}',
    '#',  '^',  '`',  '~',  '@',
};

/// A byte string over the interesting set plus uniform noise. Not constrained
/// to valid UTF-8 on purpose: `printString` walks bytes, so a lone
/// continuation byte must survive the round trip like any other.
const ByteString = struct {
    max_len: usize = 40,

    pub fn generate(self: ByteString, rand: std.Random, alloc: std.mem.Allocator, size: usize) ![]u8 {
        const len = rand.uintLessThan(usize, @min(size, self.max_len) + 1);
        const out = try alloc.alloc(u8, len);
        for (out) |*slot| {
            slot.* = if (rand.uintLessThan(u8, 2) == 0)
                interesting_bytes[rand.uintLessThan(usize, interesting_bytes.len)]
            else
                rand.int(u8);
        }
        return out;
    }

    /// Halve, then drop one byte — the shortest string that still fails is
    /// almost always a single escape.
    pub fn shrink(self: ByteString, alloc: std.mem.Allocator, v: []u8, out: *std.ArrayList([]u8)) !void {
        _ = self;
        if (v.len == 0) return;
        try out.append(alloc, try alloc.dupe(u8, v[0 .. v.len / 2]));
        try out.append(alloc, try alloc.dupe(u8, v[v.len / 2 ..]));
        var i: usize = 0;
        while (i < v.len) : (i += 1) {
            const smaller = try alloc.alloc(u8, v.len - 1);
            @memcpy(smaller[0..i], v[0..i]);
            @memcpy(smaller[i..], v[i + 1 ..]);
            try out.append(alloc, smaller);
        }
    }

    pub fn free(self: ByteString, alloc: std.mem.Allocator, v: []u8) void {
        _ = self;
        alloc.free(v);
    }

    pub fn describe(self: ByteString, alloc: std.mem.Allocator, v: []u8) ![]u8 {
        _ = self;
        return std.fmt.allocPrint(alloc, "{d} bytes: {any}", .{ v.len, v });
    }
};

/// Whatever `printString` writes, the reader's unescape takes back to the
/// original bytes. The two carry independent escape tables — `print.zig` has
/// its own `switch`, `runtime/string_escape.zig` is what the reader calls — so
/// agreement is evidence, not a tautology.
fn escapeRoundTrips(_: void, s: []u8) anyerror!void {
    var buf: [1024]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try print.printString(&w, s);
    const rendered = w.buffered();

    // The rendering is always a quoted token, and the quotes are the only
    // unescaped ones in it.
    if (rendered.len < 2) return error.RenderingTooShort;
    if (rendered[0] != '"' or rendered[rendered.len - 1] != '"') return error.RenderingNotQuoted;

    const body = rendered[1 .. rendered.len - 1];
    const back = string_escape.unescape(testing.allocator, body, .{}) catch
        return error.PrintedStringDoesNotUnescape;
    // `unescape` returns the input BORROWED when it holds no backslash, and a
    // fresh slice otherwise; free only what it allocated.
    defer if (back.ptr != body.ptr) testing.allocator.free(back);

    if (!std.mem.eql(u8, back, s)) return error.StringRoundTripChangedBytes;
}

test "property: printString output unescapes back to the original bytes" {
    try prop.forAll([]u8, testing.allocator, config(), ByteString{}, {}, escapeRoundTrips);
}

// --- the port seam: a null port cannot reach the VM ---

/// Instrumented backend: counts entries instead of doing anything. The oracle
/// for "was the VM entered" shares no code with the ~800-line renderer, so
/// unlike comparing two rendered strings it cannot be fooled by a wrong byte
/// appearing on both sides.
var vm_entries: usize = 0;

fn countingCallFn(rt: *Runtime, env: *Env, fn_val: Value, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = .{ rt, env, fn_val, args, loc };
    vm_entries += 1;
    return .nil_val;
}

fn countingTypeKey(val: Value) []const u8 {
    _ = val;
    return "counted";
}

/// `printValue(null, …)` never consults `print-method` and never dispatches a
/// protocol, for any value — the null says the caller cannot evaluate, and the
/// renderer must honour that even with a backend installed and ready.
///
/// Since the ports became a parameter this is enforced by the type, so the
/// property is a regression guard: it fails the day anyone reintroduces an
/// ambient channel (a thread-local, a global) for the same job.
fn nullPortNeverConsults(rt: *Runtime, xs: []i64) anyerror!void {
    const v = try buildNested(rt, xs);
    vm_entries = 0;
    var buf: [8192]u8 = undefined;
    var w: Writer = .fixed(&buf);
    print.printValue(null, &w, v) catch |err| switch (err) {
        // A value larger than the buffer is not what this law is about.
        error.WriteFailed => {},
        else => return err,
    };
    if (vm_entries != 0) return error.NullPortConsultedTheVm;
}

test "property: a null port is never consulted" {
    const gen = prop.IntSlice{ .distinct = 8, .max_len = 24 };
    const body = struct {
        fn f(_: void, xs: []i64) anyerror!void {
            var th = std.Io.Threaded.init(testing.allocator, .{});
            defer th.deinit();
            var rt = Runtime.init(th.io(), testing.allocator);
            defer rt.deinit();
            rt.vtable = .{ .callFn = countingCallFn, .valueTypeKey = countingTypeKey };
            try nullPortNeverConsults(&rt, xs);
        }
    }.f;
    try prop.forAll([]i64, testing.allocator, config(), gen, {}, body);
}

/// `printValue` is TOTAL: every value the generator can build renders without
/// an error other than the buffer filling, and renders something. The heap
/// tags with no dedicated branch fall back to `#<tag>`, and this is what says
/// so — a new tag with no arm shows up here rather than in a user's REPL.
fn printValueIsTotal(rt: *Runtime, xs: []i64) anyerror!void {
    const v = try buildNested(rt, xs);
    var buf: [8192]u8 = undefined;
    var w: Writer = .fixed(&buf);
    print.printValue(null, &w, v) catch |err| switch (err) {
        error.WriteFailed => return,
        else => return err,
    };
    if (w.buffered().len == 0) return error.PrintedNothing;
}

test "property: printValue renders every generated value without raising" {
    const gen = prop.IntSlice{ .distinct = 8, .max_len = 24 };
    const body = struct {
        fn f(_: void, xs: []i64) anyerror!void {
            var th = std.Io.Threaded.init(testing.allocator, .{});
            defer th.deinit();
            var rt = Runtime.init(th.io(), testing.allocator);
            defer rt.deinit();
            try printValueIsTotal(&rt, xs);
        }
    }.f;
    try prop.forAll([]i64, testing.allocator, config(), gen, {}, body);
}
