// SPDX-License-Identifier: EPL-2.0
//! Width-portable atomic ops. Native and wasm64 lower a 64-bit atomic
//! directly; wasm32 cannot (its backend caps atomic operands at 32 bits).
//! cljw runs single-threaded on wasm, so there a >32-bit "atomic" degrades to
//! a plain load / store / read-modify-write. Operands of 32 bits or fewer, and
//! every op on non-wasm32 targets, lower to the real atomic builtin unchanged.
//!
//! `Value(T)` mirrors the slice of `std.atomic.Value` cljw uses, so a 64-bit
//! cell (`std.atomic.Value(u64)` / `(i64)`) can swap to `atomics.Value(...)`
//! and keep working on wasm32.

const std = @import("std");
const builtin = @import("builtin");

const AtomicOrder = std.builtin.AtomicOrder;
const AtomicRmwOp = std.builtin.AtomicRmwOp;

/// This target cannot lower an atomic op on a `T`-wide operand.
pub inline fn degrades(comptime T: type) bool {
    return builtin.cpu.arch == .wasm32 and @bitSizeOf(T) > 32;
}

pub inline fn load(comptime T: type, ptr: *const T, comptime order: AtomicOrder) T {
    if (comptime degrades(T)) return ptr.*;
    return @atomicLoad(T, ptr, order);
}

pub inline fn store(comptime T: type, ptr: *T, val: T, comptime order: AtomicOrder) void {
    if (comptime degrades(T)) {
        ptr.* = val;
        return;
    }
    @atomicStore(T, ptr, val, order);
}

pub inline fn rmw(comptime T: type, ptr: *T, comptime op: AtomicRmwOp, operand: T, comptime order: AtomicOrder) T {
    if (comptime degrades(T)) {
        const old = ptr.*;
        ptr.* = switch (op) {
            .Xchg => operand,
            .Add => old +% operand,
            .Sub => old -% operand,
            .And => old & operand,
            .Or => old | operand,
            .Xor => old ^ operand,
            .Nand => ~(old & operand),
            .Max => @max(old, operand),
            .Min => @min(old, operand),
        };
        return old;
    }
    return @atomicRmw(T, ptr, op, operand, order);
}

pub inline fn cmpxchgStrong(comptime T: type, ptr: *T, expected: T, new: T, comptime succ: AtomicOrder, comptime fail: AtomicOrder) ?T {
    if (comptime degrades(T)) {
        if (ptr.* == expected) {
            ptr.* = new;
            return null;
        }
        return ptr.*;
    }
    return @cmpxchgStrong(T, ptr, expected, new, succ, fail);
}

pub inline fn cmpxchgWeak(comptime T: type, ptr: *T, expected: T, new: T, comptime succ: AtomicOrder, comptime fail: AtomicOrder) ?T {
    if (comptime degrades(T)) {
        if (ptr.* == expected) {
            ptr.* = new;
            return null;
        }
        return ptr.*;
    }
    return @cmpxchgWeak(T, ptr, expected, new, succ, fail);
}

/// The `std.atomic.Value` subset cljw uses, made width-portable via the helpers
/// above. `raw` stays public for parity with `std.atomic.Value`.
pub fn Value(comptime T: type) type {
    return struct {
        raw: T,

        const Self = @This();

        pub fn init(v: T) Self {
            return .{ .raw = v };
        }

        pub inline fn load(self: *const Self, comptime order: AtomicOrder) T {
            return @This().loadFn(self, order);
        }

        // Distinct name to avoid shadowing the module-level `load` inside methods.
        inline fn loadFn(self: *const Self, comptime order: AtomicOrder) T {
            if (comptime degrades(T)) return self.raw;
            return @atomicLoad(T, &self.raw, order);
        }

        pub inline fn store(self: *Self, val: T, comptime order: AtomicOrder) void {
            if (comptime degrades(T)) {
                self.raw = val;
                return;
            }
            @atomicStore(T, &self.raw, val, order);
        }

        pub inline fn swap(self: *Self, val: T, comptime order: AtomicOrder) T {
            return rmw(T, &self.raw, .Xchg, val, order);
        }

        pub inline fn fetchAdd(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return rmw(T, &self.raw, .Add, operand, order);
        }

        pub inline fn fetchSub(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return rmw(T, &self.raw, .Sub, operand, order);
        }
    };
}
