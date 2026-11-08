// SPDX-License-Identifier: EPL-2.0
//! cljw.ffi calling convention: C signatures as data, and the two-shape call
//! that reaches any of them without libffi (ADR-0202).
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: cljw.ffi/function, cljw.ffi/call (through `surface.zig`)
//!
//! Pure layer: no Value, no GC, no OS. A `Signature` is the validated, packed
//! form of `[arg-types ret-type]`; `call` places integer-class arguments into
//! six `usize` slots and doubles into eight `f64` slots and calls the symbol
//! through one of two function pointer types. Unused slots are zero.
const std = @import("std");

/// The C types cljw.ffi speaks. `void` is a return type only, `bytes` an
/// argument type only (`Signature.init` enforces both).
pub const Type = enum(u3) {
    void,
    int,
    long,
    double,
    pointer,
    string,
    bytes,

    /// The keyword name a Clojure caller writes for this type.
    pub fn name(t: Type) []const u8 {
        return @tagName(t);
    }

    pub fn fromName(s: []const u8) ?Type {
        return std.meta.stringToEnum(Type, s);
    }

    /// True for the types passed in a general-purpose register.
    pub fn isIntegerClass(t: Type) bool {
        return switch (t) {
            .int, .long, .pointer, .string, .bytes => true,
            .void, .double => false,
        };
    }
};

pub const MAX_INT_ARGS = 6;
pub const MAX_DOUBLE_ARGS = 8;
pub const MAX_ARGS = MAX_INT_ARGS + MAX_DOUBLE_ARGS;

/// Why a signature was refused. `surface.zig` turns it into the
/// `{:ffi/error :signature :reason ...}` text.
pub const SignatureError = enum {
    void_argument,
    bytes_return,
    too_many_int_args,
    too_many_double_args,

    pub fn reason(e: SignatureError) []const u8 {
        return switch (e) {
            .void_argument => ":void is a return type only",
            .bytes_return => ":bytes is an argument type only; return :pointer and copy with bytes",
            .too_many_int_args => "more than 6 integer-class arguments (:int :long :pointer :string :bytes)",
            .too_many_double_args => "more than 8 :double arguments",
        };
    }
};

/// A validated C signature, small enough to live in two host-instance words.
pub const Signature = struct {
    argc: u8,
    ret: Type,
    args: [MAX_ARGS]Type,

    pub const Result = union(enum) { ok: Signature, err: SignatureError };

    /// Validate `args` + `ret` against the register-only call shape.
    pub fn init(args: []const Type, ret: Type) Result {
        if (ret == .bytes) return .{ .err = .bytes_return };
        var n_int: usize = 0;
        var n_dbl: usize = 0;
        for (args) |t| switch (t) {
            .void => return .{ .err = .void_argument },
            .double => n_dbl += 1,
            else => n_int += 1,
        };
        if (n_int > MAX_INT_ARGS) return .{ .err = .too_many_int_args };
        if (n_dbl > MAX_DOUBLE_ARGS) return .{ .err = .too_many_double_args };
        var sig: Signature = .{ .argc = @intCast(args.len), .ret = ret, .args = undefined };
        @memset(&sig.args, .void);
        @memcpy(sig.args[0..args.len], args);
        return .{ .ok = sig };
    }

    /// Pack into one word: 3 bits per argument type, then 4 bits of argc and 3
    /// of return type above the 14 argument fields.
    pub fn pack(sig: Signature) u64 {
        var w: u64 = 0;
        for (sig.args[0..sig.argc], 0..) |t, i| w |= @as(u64, @intFromEnum(t)) << @intCast(3 * i);
        w |= @as(u64, sig.argc) << (3 * MAX_ARGS);
        w |= @as(u64, @intFromEnum(sig.ret)) << (3 * MAX_ARGS + 4);
        return w;
    }

    pub fn unpack(w: u64) Signature {
        var sig: Signature = .{
            .argc = @intCast((w >> (3 * MAX_ARGS)) & 0xF),
            .ret = @enumFromInt(@as(u3, @truncate(w >> (3 * MAX_ARGS + 4)))),
            .args = undefined,
        };
        @memset(&sig.args, .void);
        for (0..sig.argc) |i| sig.args[i] = @enumFromInt(@as(u3, @truncate(w >> @intCast(3 * i))));
        return sig;
    }

    pub fn argTypes(sig: *const Signature) []const Type {
        return sig.args[0..sig.argc];
    }
};

/// Register images of one call: integer-class arguments in order, doubles in
/// order. `Slots.put*` is how marshalling fills them.
pub const Slots = struct {
    ints: [MAX_INT_ARGS]usize = @splat(0),
    dbls: [MAX_DOUBLE_ARGS]f64 = @splat(0),
    n_int: u8 = 0,
    n_dbl: u8 = 0,

    pub fn putInt(s: *Slots, w: usize) void {
        s.ints[s.n_int] = w;
        s.n_int += 1;
    }

    pub fn putDouble(s: *Slots, d: f64) void {
        s.dbls[s.n_dbl] = d;
        s.n_dbl += 1;
    }
};

const IntShape = *const fn (usize, usize, usize, usize, usize, usize, f64, f64, f64, f64, f64, f64, f64, f64) callconv(.c) usize;
const DoubleShape = *const fn (usize, usize, usize, usize, usize, usize, f64, f64, f64, f64, f64, f64, f64, f64) callconv(.c) f64;

/// The raw return register for `ret`: `.word` for every type except double.
pub const Raw = union(enum) { word: usize, double: f64 };

/// Call the C function at `addr` with `slots`. `ret` picks the shape: a
/// `:double` return reads the float register, anything else the integer one.
pub fn call(addr: usize, ret: Type, slots: *const Slots) Raw {
    const i = slots.ints;
    const d = slots.dbls;
    if (ret == .double) {
        const f: DoubleShape = @ptrFromInt(addr);
        return .{ .double = f(i[0], i[1], i[2], i[3], i[4], i[5], d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7]) };
    }
    const f: IntShape = @ptrFromInt(addr);
    return .{ .word = f(i[0], i[1], i[2], i[3], i[4], i[5], d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7]) };
}

/// A C `int` return: the low 32 bits, sign-extended.
pub fn intFromWord(w: usize) i64 {
    return @as(i32, @bitCast(@as(u32, @truncate(w))));
}

// --- tests ---

const testing = std.testing;

fn mixed(a: c_long, b: f64, c: c_long, d: f64, e: c_long, f: f64) callconv(.c) c_long {
    const fa: f64 = @floatFromInt(a);
    const fc: f64 = @floatFromInt(c);
    const fe: f64 = @floatFromInt(e);
    return @intFromFloat(fa * 1 + b * 10 + fc * 100 + d * 1000 + fe * 10000 + f * 100000);
}

fn halve(x: f64, n: c_int) callconv(.c) f64 {
    return x / @as(f64, @floatFromInt(n));
}

fn negSeven() callconv(.c) c_int {
    return -7;
}

/// The address of `f` as the optimiser cannot see it. A comptime-known callee
/// lets LLVM resolve the indirect call against the real prototype, and a call
/// through a mismatched one is undefined there (measured: ReleaseSafe returned
/// 501 for 654321). A dlsym address is always opaque; this makes the test's so.
fn opaqueAddr(f: anytype) usize {
    var addr: usize = @intFromPtr(f);
    const v: *volatile usize = &addr;
    return v.*;
}

test "a signature packs into one word and unpacks unchanged" {
    const r = Signature.init(&.{ .long, .double, .string, .pointer, .bytes, .int }, .double);
    const sig = r.ok;
    const back = Signature.unpack(sig.pack());
    try testing.expectEqual(sig.argc, back.argc);
    try testing.expectEqual(sig.ret, back.ret);
    try testing.expectEqualSlices(Type, sig.argTypes(), back.argTypes());
}

test "signature limits: seven integer-class args, nine doubles, void arg, bytes return" {
    try testing.expectEqual(SignatureError.too_many_int_args, Signature.init(&(.{.int} ** 7), .int).err);
    try testing.expectEqual(SignatureError.too_many_double_args, Signature.init(&(.{.double} ** 9), .int).err);
    try testing.expectEqual(SignatureError.void_argument, Signature.init(&.{.void}, .int).err);
    try testing.expectEqual(SignatureError.bytes_return, Signature.init(&.{}, .bytes).err);
    const max = Signature.init(&(.{.long} ** 6 ++ .{.double} ** 8), .void).ok;
    try testing.expectEqual(@as(u8, 14), Signature.unpack(max.pack()).argc);
}

test "interleaved long and double args land in their own register files" {
    var s: Slots = .{};
    s.putInt(1);
    s.putDouble(2);
    s.putInt(3);
    s.putDouble(4);
    s.putInt(5);
    s.putDouble(6);
    const r = call(opaqueAddr(&mixed), .long, &s);
    try testing.expectEqual(@as(usize, 654321), r.word);
}

test "a double return reads the float register; an int return is sign-extended" {
    var s: Slots = .{};
    s.putDouble(9);
    s.putInt(2);
    try testing.expectEqual(@as(f64, 4.5), call(opaqueAddr(&halve), .double, &s).double);
    const empty: Slots = .{};
    try testing.expectEqual(@as(i64, -7), intFromWord(call(opaqueAddr(&negSeven), .int, &empty).word));
}
