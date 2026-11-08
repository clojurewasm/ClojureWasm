// SPDX-License-Identifier: EPL-2.0
//! Shared backing impl for the `java.util.concurrent.atomic` surfaces
//! (ADR-0029 / ADR-0106). One `.host_instance` word (`state[0]`) holds the
//! value; every mutation moves it with `@cmpxchgWeak` or `@atomicRmw`, so the
//! surfaces are safe under cljw's real OS threads.
//!
//! Backend: impl-only
//! Impl deps: host_instance
//! Clojure peer: none
//!
//! This file exports no `___HOST_EXTENSION` of its own — the per-class surface
//! files under this directory carry the markers and share this `Impl`. The
//! three marker lines above must each stand alone: `check_surface_marker.sh`
//! anchors `Backend:` with `$`, so a trailing parenthetical reads as a
//! malformed marker.
//!
//! `Impl` is comptime-parameterised by the class's descriptor slot, its name
//! (for arity/type errors) and its `Repr`, because AtomicLong / AtomicInteger
//! differ only in the class the value is REPORTED under: cljw has one integer
//! width, so both store an `i64` and neither truncates. Divergence AD-062.

const std = @import("std");
const atomics = @import("../../../../atomics.zig");
const type_descriptor = @import("../../../../type_descriptor.zig");
const Value = @import("../../../../value/value.zig").Value;
const Runtime = @import("../../../../runtime.zig").Runtime;
const Env = @import("../../../../env.zig").Env;
const SourceLocation = @import("../../../../error/info.zig").SourceLocation;
const error_catalog = @import("../../../../error/catalog.zig");
const host_instance = @import("../../../../host_instance.zig");

/// How the single state word is read and written on the Clojure side.
pub const Repr = enum { integer, boolean };

pub const MethodSpec = struct {
    name: []const u8,
    f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value,
};

/// Build the method set for one atomic class. `td_slot` is the surface file's
/// own descriptor cell, filled by `initDescriptor` so `<init>` can allocate.
pub fn Impl(
    comptime td_slot: *?*const type_descriptor.TypeDescriptor,
    comptime class_name: []const u8,
    comptime repr: Repr,
) type {
    return struct {
        const Self = @This();

        fn wordPtr(recv: Value) *u64 {
            return &@constCast(host_instance.asHostInstance(recv)).state[0];
        }

        fn load(recv: Value) i64 {
            return @bitCast(atomics.load(u64, wordPtr(recv), .seq_cst));
        }

        /// The Clojure value the stored word denotes.
        fn out(n: i64) Value {
            return switch (repr) {
                .integer => Value.initInteger(n),
                .boolean => Value.initBoolean(n != 0),
            };
        }

        /// The word an argument denotes. A boolean atomic takes any value and
        /// reads its truthiness, as `(AtomicBoolean. x)` does on the JVM only
        /// for a real boolean — cljw has no unboxing step to reject at.
        fn in(v: Value, loc: SourceLocation) anyerror!i64 {
            return switch (repr) {
                .integer => @as(i64, try error_catalog.expectInteger(v, class_name, loc)),
                .boolean => if (v.isTruthy()) 1 else 0,
            };
        }

        /// `(java.util.concurrent.atomic.AtomicLong.)` / `(… n)`.
        fn initAtomic(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = env;
            if (args.len > 1)
                return error_catalog.raise(.arity_not_expected, loc, .{ .got = args.len, .fn_name = class_name ++ ".", .expected = 1 });
            const initial: i64 = if (args.len == 1) try in(args[0], loc) else 0;
            const td = td_slot.* orelse return error.NoVTable;
            return host_instance.alloc(rt, td, .{ @bitCast(initial), 0, 0, 0 });
        }

        fn get(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity(".get", args, 1, loc);
            return out(load(args[0]));
        }

        fn set(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity(".set", args, 2, loc);
            atomics.store(u64, wordPtr(args[0]), @bitCast(try in(args[1], loc)), .seq_cst);
            return Value.nil_val;
        }

        /// `.lazySet` — cljw has no relaxed-store tier to spend, so it is `.set`.
        fn lazySet(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            return set(rt, env, args, loc);
        }

        fn getAndSet(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity(".getAndSet", args, 2, loc);
            const next: u64 = @bitCast(try in(args[1], loc));
            const prev = atomics.rmw(u64, wordPtr(args[0]), .Xchg, next, .seq_cst);
            return out(@bitCast(prev));
        }

        fn compareAndSet(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity(".compareAndSet", args, 3, loc);
            const expect: u64 = @bitCast(try in(args[1], loc));
            const next: u64 = @bitCast(try in(args[2], loc));
            return Value.initBoolean(atomics.cmpxchgStrong(u64, wordPtr(args[0]), expect, next, .seq_cst, .seq_cst) == null);
        }

        /// Add `delta` and hand back one of the two sides. Saturating, so a
        /// counter at `Long/MAX_VALUE` pins instead of wrapping to negative.
        fn addBy(recv: Value, delta: i64, comptime want: enum { before, after }) Value {
            const ptr = wordPtr(recv);
            while (true) {
                const cur_bits = atomics.load(u64, ptr, .seq_cst);
                const cur: i64 = @bitCast(cur_bits);
                const next = cur +| delta;
                if (atomics.cmpxchgWeak(u64, ptr, cur_bits, @as(u64, @bitCast(next)), .seq_cst, .seq_cst) == null)
                    return out(switch (want) {
                        .before => cur,
                        .after => next,
                    });
            }
        }

        fn incrementAndGet(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity(".incrementAndGet", args, 1, loc);
            return addBy(args[0], 1, .after);
        }

        fn decrementAndGet(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity(".decrementAndGet", args, 1, loc);
            return addBy(args[0], -1, .after);
        }

        fn getAndIncrement(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity(".getAndIncrement", args, 1, loc);
            return addBy(args[0], 1, .before);
        }

        fn getAndDecrement(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity(".getAndDecrement", args, 1, loc);
            return addBy(args[0], -1, .before);
        }

        fn addAndGet(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity(".addAndGet", args, 2, loc);
            return addBy(args[0], try in(args[1], loc), .after);
        }

        fn getAndAdd(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity(".getAndAdd", args, 2, loc);
            return addBy(args[0], try in(args[1], loc), .before);
        }

        fn longValue(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity(".longValue", args, 1, loc);
            return Value.initInteger(load(args[0]));
        }

        const NUMERIC = [_]MethodSpec{
            .{ .name = "incrementAndGet", .f = &incrementAndGet },
            .{ .name = "decrementAndGet", .f = &decrementAndGet },
            .{ .name = "getAndIncrement", .f = &getAndIncrement },
            .{ .name = "getAndDecrement", .f = &getAndDecrement },
            .{ .name = "addAndGet", .f = &addAndGet },
            .{ .name = "getAndAdd", .f = &getAndAdd },
            .{ .name = "longValue", .f = &longValue },
            .{ .name = "intValue", .f = &longValue },
        };

        const COMMON = [_]MethodSpec{
            .{ .name = "<init>", .f = &initAtomic },
            .{ .name = "get", .f = &get },
            .{ .name = "set", .f = &set },
            .{ .name = "lazySet", .f = &lazySet },
            .{ .name = "getAndSet", .f = &getAndSet },
            .{ .name = "compareAndSet", .f = &compareAndSet },
            .{ .name = "weakCompareAndSet", .f = &compareAndSet },
        };

        pub const METHODS = switch (repr) {
            .integer => COMMON ++ NUMERIC,
            .boolean => COMMON,
        };

        pub fn initDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
            if (td.method_table.len != 0) return; // idempotent
            td_slot.* = td;
            const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, METHODS.len);
            for (METHODS, 0..) |m, i| {
                entries[i] = .{
                    .protocol_name = "",
                    .method_name = try gpa.dupe(u8, m.name),
                    .method_val = Value.initBuiltinFn(m.f),
                };
            }
            td.method_table = entries;
        }
    };
}
