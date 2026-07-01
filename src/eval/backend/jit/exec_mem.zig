// SPDX-License-Identifier: EPL-2.0
//! Executable-memory primitive for the D-133 narrow ARM64 integer-loop JIT
//! (ADR-0151). The riskiest mechanical part of the JIT, spiked first per
//! ADR-0089: allocate a page, emit raw little-endian ARM64 u32 instructions
//! into it, flip it executable (W^X), flush the instruction cache, and hand
//! back a callable entry pointer.
//!
//! Lifecycle (compile-once, per ADR-0151 — NOT incremental W↔X toggling):
//!   1. `CodeBuffer.init(len)` mmaps one or more pages **RW**.
//!   2. `emit(word)` appends a 32-bit instruction (every ARM64 instruction is
//!      one little-endian u32).
//!   3. `finalize(Fn)` flips the page **RX** (`mprotect`), flushes the icache,
//!      and returns the typed entry pointer. After this the buffer is frozen.
//!   4. `deinit()` munmaps.
//!
//! W^X note (ADR-0151): the compile-once "mmap RW → mprotect RX" path is proven
//! on Apple Silicon (cw v0's jit.zig ships it). The `MAP_JIT` +
//! `pthread_jit_write_protect_np` toggle is only needed for repeated W↔X
//! patching, which a compile-once leaf does not do — deferred until a later
//! milestone needs it.
//!
//! ARM64-only: callers gate on `builtin.cpu.arch == .aarch64` (a non-aarch64
//! host runs the loop on the VM — the JIT is inert there, no behaviour change).

const std = @import("std");
const builtin = @import("builtin");

const PAGE_SIZE = std.heap.page_size_min;

pub const ExecMemError = error{ MmapFailed, MprotectFailed };

/// A page-aligned RW→RX code buffer. Holds the mmap'd region + the write
/// cursor; `finalize` freezes it and yields the entry pointer.
pub const CodeBuffer = struct {
    /// The mmap'd region (page-multiple length). Aligned to the page size so
    /// `mprotect` accepts it.
    buffer: []align(PAGE_SIZE) u8,
    /// Bytes written so far (always a multiple of 4 — one ARM64 word each).
    offset: usize = 0,
    /// Set by `finalize`; a second emit/finalize after freezing is a bug.
    frozen: bool = false,

    /// Reserve at least `min_bytes` of RW executable-capable memory (rounded up
    /// to a page multiple). One page is plenty for a leaf integer loop.
    pub fn init(min_bytes: usize) ExecMemError!CodeBuffer {
        const len = std.mem.alignForward(usize, @max(min_bytes, PAGE_SIZE), PAGE_SIZE);
        const mem = std.posix.mmap(
            null,
            len,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch return error.MmapFailed;
        return .{ .buffer = @alignCast(mem) };
    }

    pub fn deinit(self: *CodeBuffer) void {
        std.posix.munmap(self.buffer);
        self.* = undefined;
    }

    /// Append one little-endian 32-bit ARM64 instruction. Caller ensures the
    /// page has room (a leaf loop is far under one page); an overflow is a
    /// compiler bug, surfaced as a safe-build bounds panic rather than silent
    /// corruption.
    pub fn emit(self: *CodeBuffer, word: u32) void {
        std.debug.assert(!self.frozen);
        std.mem.writeInt(u32, self.buffer[self.offset..][0..4], word, .little);
        self.offset += 4;
    }

    /// Freeze the buffer executable and return the entry pointer typed as `Fn`
    /// (a `*const fn (...) callconv(.c) ...`). After this the buffer is RX and
    /// no further `emit` is allowed. ARM64 requires an icache flush between the
    /// last write and the first execution.
    pub fn finalize(self: *CodeBuffer, comptime Fn: type) ExecMemError!Fn {
        const prot: std.posix.PROT = .{ .READ = true, .EXEC = true };
        if (std.c.mprotect(self.buffer.ptr, self.buffer.len, prot) != 0)
            return error.MprotectFailed;
        icacheInvalidate(self.buffer.ptr, self.offset);
        self.frozen = true;
        return @ptrCast(@alignCast(self.buffer.ptr));
    }
};

/// Flush the instruction cache for `[ptr, ptr+len)` — mandatory on ARM64 before
/// executing freshly written code (the D-cache write is not coherent with the
/// I-cache). macOS exposes `sys_icache_invalidate`; other ARM64 hosts use the
/// compiler builtin `__clear_cache`. Brought in via `@extern` (neither is in the
/// Zig 0.16 stdlib), the pattern cw v0 uses.
fn icacheInvalidate(ptr: [*]const u8, len: usize) void {
    if (builtin.os.tag == .macos) {
        const f = @extern(*const fn ([*]const u8, usize) callconv(.c) void, .{
            .name = "sys_icache_invalidate",
        });
        f(ptr, len);
    } else {
        const f = @extern(*const fn ([*]const u8, [*]const u8) callconv(.c) void, .{
            .name = "__clear_cache",
        });
        f(ptr, ptr + len);
    }
}

// --- ARM64 encoding helpers (only what the spike test needs; the codegen
//     milestone grows this set) ---

/// `MOVZ Xd, #imm16` (64-bit, no shift) — load a 16-bit immediate, zeroing the
/// rest. Base 0xD2800000 | (imm16 << 5) | Rd.
pub fn movzX(rd: u5, imm16: u16) u32 {
    return 0xD2800000 | (@as(u32, imm16) << 5) | rd;
}

/// `RET` (returns to X30, the link register). 0xD65F03C0.
pub fn ret() u32 {
    return 0xD65F03C0;
}

/// `ADD Xd, Xn, Xm` (64-bit, shifted-register form, shift 0). Base 0x8B000000
/// | (Rm << 16) | (Rn << 5) | Rd. The integer-loop body's `op_add_locals` lowers
/// to this once both operands are unboxed in registers.
pub fn addRegX(rd: u5, rn: u5, rm: u5) u32 {
    return 0x8B000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
}

/// `SUB Xd, Xn, Xm` (64-bit, shifted-register, shift 0). Base 0xCB000000.
pub fn subRegX(rd: u5, rn: u5, rm: u5) u32 {
    return 0xCB000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
}

/// `SBFM Xd, Xn, #immr, #imms` (64-bit, sf=1 N=1). Base 0x93400000. The
/// alias `SBFX Xd, Xn, #lsb, #width` is `SBFM` with immr=lsb, imms=lsb+width-1
/// — the JIT unboxes a fixnum payload with `SBFX Xd, Xn, #0, #48` (sign-extend
/// the i48 NaN-box payload into a full i64).
pub fn sbfmX(rd: u5, rn: u5, immr: u6, imms: u6) u32 {
    return 0x93400000 | (@as(u32, immr) << 16) | (@as(u32, imms) << 10) | (@as(u32, rn) << 5) | rd;
}

/// `SBFX Xd, Xn, #lsb, #width` (sign-extracting bitfield) = the `SBFM` alias.
pub fn sbfxX(rd: u5, rn: u5, lsb: u6, width: u6) u32 {
    return sbfmX(rd, rn, lsb, lsb + width - 1);
}

/// `MOVK Xd, #imm16, LSL #(hw*16)` (64-bit) — overwrite a 16-bit field, keep the
/// rest. Base 0xF2800000 | (hw << 21). The JIT re-boxes a fixnum by stamping the
/// `0xFFFC` tag into bits [63:48] with `MOVK Xd, #0xFFFC, LSL #48` (hw=3) over
/// the in-range i48 result.
pub fn movkX(rd: u5, imm16: u16, hw: u2) u32 {
    return 0xF2800000 | (@as(u32, hw) << 21) | (@as(u32, imm16) << 5) | rd;
}

/// ARM64 condition codes (the `B.cond` / `CSET` selector). The JIT uses `.ne`
/// for the fixnum tag-check deopt, `.vs` for the i48-overflow deopt (F-005), and
/// the relational ones (`.ge`/`.gt`/`.lt`/`.le`/`.eq`) for the loop branch.
pub const Cond = enum(u4) {
    eq = 0x0,
    ne = 0x1,
    hs = 0x2,
    lo = 0x3,
    mi = 0x4,
    pl = 0x5,
    vs = 0x6,
    vc = 0x7,
    hi = 0x8,
    ls = 0x9,
    ge = 0xA,
    lt = 0xB,
    gt = 0xC,
    le = 0xD,
    al = 0xE,
};

/// `CMP Xn, #imm12` (64-bit) = `SUBS XZR, Xn, #imm12`. Base 0xF100001F
/// (Rd=XZR=31). Sets NZCV for the following `B.cond`.
pub fn cmpImmX(rn: u5, imm12: u12) u32 {
    return 0xF100001F | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5);
}

/// `CMP Xn, Xm` (64-bit) = `SUBS XZR, Xn, Xm`. Base 0xEB00001F. The loop
/// condition (`op_branch_*_locals`) lowers to this + a `B.cond`.
pub fn cmpRegX(rn: u5, rm: u5) u32 {
    return 0xEB00001F | (@as(u32, rm) << 16) | (@as(u32, rn) << 5);
}

/// `B.cond <±imm19 instructions>`. Base 0x54000000 | (imm19 << 5) | cond, where
/// `imm19` is the signed offset IN INSTRUCTIONS (×4 bytes) from THIS branch to
/// the target. A backward loop branch passes a negative offset.
pub fn bCond(cond: Cond, imm19: i19) u32 {
    const off: u32 = @as(u19, @bitCast(imm19));
    return 0x54000000 | (off << 5) | @intFromEnum(cond);
}

/// `UBFM Xd, Xn, #immr, #imms` (64-bit, sf=1 N=1). Base 0xD3400000. `LSR` is the
/// alias `UBFM Xd, Xn, #shift, #63`.
pub fn ubfmX(rd: u5, rn: u5, immr: u6, imms: u6) u32 {
    return 0xD3400000 | (@as(u32, immr) << 16) | (@as(u32, imms) << 10) | (@as(u32, rn) << 5) | rd;
}

/// `LSR Xd, Xn, #shift` (logical shift right) = the `UBFM Xd,Xn,#shift,#63`
/// alias. The JIT extracts a NaN-box top-16 tag with `LSR Xd, Xn, #48`.
pub fn lsrX(rd: u5, rn: u5, shift: u6) u32 {
    return ubfmX(rd, rn, shift, 63);
}

test "exec_mem: emit + call a trivial ARM64 leaf fn returning a constant" {
    if (builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    var buf = try CodeBuffer.init(64);
    defer buf.deinit();
    // fn() -> u64 { return 42; }  =  movz x0, #42 ; ret
    buf.emit(movzX(0, 42));
    buf.emit(ret());
    const f = try buf.finalize(*const fn () callconv(.c) u64);
    try std.testing.expectEqual(@as(u64, 42), f());
}

test "exec_mem: a second emitted fn with a different constant" {
    if (builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    var buf = try CodeBuffer.init(64);
    defer buf.deinit();
    buf.emit(movzX(0, 1337));
    buf.emit(ret());
    const f = try buf.finalize(*const fn () callconv(.c) u64);
    try std.testing.expectEqual(@as(u64, 1337), f());
}

test "exec_mem: 2-arg leaf proves C-ABI args (x0,x1) + add/sub by execution" {
    if (builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    // fn(a, b) -> u64 { return a + b; }  =  add x0, x0, x1 ; ret
    var add_buf = try CodeBuffer.init(64);
    defer add_buf.deinit();
    add_buf.emit(addRegX(0, 0, 1));
    add_buf.emit(ret());
    const add = try add_buf.finalize(*const fn (u64, u64) callconv(.c) u64);
    try std.testing.expectEqual(@as(u64, 42), add(40, 2));

    // fn(a, b) -> i64 { return a - b; }  =  sub x0, x0, x1 ; ret
    var sub_buf = try CodeBuffer.init(64);
    defer sub_buf.deinit();
    sub_buf.emit(subRegX(0, 0, 1));
    sub_buf.emit(ret());
    const sub = try sub_buf.finalize(*const fn (i64, i64) callconv(.c) i64);
    try std.testing.expectEqual(@as(i64, 38), sub(40, 2));
    try std.testing.expectEqual(@as(i64, -5), sub(5, 10));
}

test "exec_mem: fixnum unbox (SBFX) + rebox (MOVK tag) round-trip vs value.zig" {
    if (builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const Value = @import("../../../runtime/value/value.zig").Value;
    const nb = @import("../../../runtime/value/nan_box.zig");
    const INT_TOP16: u16 = @truncate(nb.NB_INT_TAG >> nb.NB_TAG_SHIFT); // 0xFFFC

    // unbox: fn(boxed_value_bits) -> i64 { sbfx x0, x0, #0, #48 ; ret }
    var ub = try CodeBuffer.init(64);
    defer ub.deinit();
    ub.emit(sbfxX(0, 0, 0, 48));
    ub.emit(ret());
    const unbox = try ub.finalize(*const fn (u64) callconv(.c) i64);

    // rebox: fn(int) -> u64 { movk x0, #0xFFFC, lsl #48 ; ret }  (in-range i48 only)
    var rb = try CodeBuffer.init(64);
    defer rb.deinit();
    rb.emit(movkX(0, INT_TOP16, 3));
    rb.emit(ret());
    const rebox = try rb.finalize(*const fn (i64) callconv(.c) u64);

    const cases = [_]i64{ 0, 42, -5, 1, -1, nb.NB_I48_MAX, nb.NB_I48_MIN };
    for (cases) |k| {
        const boxed: u64 = @intFromEnum(Value.initInteger(k));
        // JIT unbox == value.zig's asInteger (the deopt-free fixnum path).
        try std.testing.expectEqual(k, unbox(boxed));
        // JIT rebox of the in-range int == value.zig's boxed encoding.
        try std.testing.expectEqual(boxed, rebox(k));
    }
}

test "exec_mem: CMP + B.cond control flow proven by execution" {
    if (builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    // fn(x) -> u64 { if (x != 0) return 1; else return 99; }
    //   0: cmp x0, #0
    //   1: b.ne +3   (-> instr 4)
    //   2: movz x0, #99
    //   3: ret
    //   4: movz x0, #1
    //   5: ret
    var buf = try CodeBuffer.init(64);
    defer buf.deinit();
    buf.emit(cmpImmX(0, 0));
    buf.emit(bCond(.ne, 3));
    buf.emit(movzX(0, 99));
    buf.emit(ret());
    buf.emit(movzX(0, 1));
    buf.emit(ret());
    const f = try buf.finalize(*const fn (u64) callconv(.c) u64);
    try std.testing.expectEqual(@as(u64, 99), f(0));
    try std.testing.expectEqual(@as(u64, 1), f(5));
    try std.testing.expectEqual(@as(u64, 1), f(123456));

    // Backward branch (the loop shape): count x0 down to 0, return iterations.
    // fn(n) -> u64 { c=0; while (n != 0) { n=n-1; c=c+1; } return c; }
    //   0: movz x1, #0          ; c = 0
    //   1: cmp x0, #0           ; loop:
    //   2: b.eq +4   (-> instr 6 = done)
    //   3: sub x0, x0, x2-no... use immediate decrement via sub reg needs a reg=1
    // Simpler: keep #1 in x3 first.
    //   0: movz x1, #0          ; c
    //   1: movz x3, #1          ; one
    //   2: cmp x0, #0           ; loop:
    //   3: b.eq +4   (-> instr 7 done)
    //   4: sub x0, x0, x3       ; n--
    //   5: add x1, x1, x3       ; c++
    //   6: b.al -4   (-> instr 2 loop)   [b.cond AL = unconditional]
    //   7: mov x0, x1 ; ret  -> use add x0,x1,xzr then ret
    var lp = try CodeBuffer.init(64);
    defer lp.deinit();
    lp.emit(movzX(1, 0)); // c=0
    lp.emit(movzX(3, 1)); // one=1
    lp.emit(cmpImmX(0, 0)); // loop:
    lp.emit(bCond(.eq, 4)); // -> done (instr 3 + 4 = instr 7)
    lp.emit(subRegX(0, 0, 3)); // n--
    lp.emit(addRegX(1, 1, 3)); // c++
    lp.emit(bCond(.al, -4)); // -> loop (instr 6 - 4 = instr 2)
    lp.emit(addRegX(0, 1, 31)); // x0 = c + xzr(31)  (done:)
    lp.emit(ret());
    const loop = try lp.finalize(*const fn (u64) callconv(.c) u64);
    try std.testing.expectEqual(@as(u64, 0), loop(0));
    try std.testing.expectEqual(@as(u64, 1), loop(1));
    try std.testing.expectEqual(@as(u64, 1000), loop(1000));
}

test "exec_mem: deopt arm — fixnum tag-check + i48-overflow range-check (F-005)" {
    if (builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const Value = @import("../../../runtime/value/value.zig").Value;
    const nb = @import("../../../runtime/value/nan_box.zig");
    const INT_TOP16: u16 = @truncate(nb.NB_INT_TAG >> nb.NB_TAG_SHIFT); // 0xFFFC

    // fn(boxed_a, boxed_b) -> { value: u64, status: u64 }  (x0, x1)
    //   status 0 = both fixnum AND sum fits i48 → value = boxed(a+b)
    //   status 1 = deopt (non-fixnum operand OR i48 overflow) → VM runs it
    const Ret = extern struct { value: u64, status: u64 };
    var buf = try CodeBuffer.init(128);
    defer buf.deinit();
    buf.emit(movzX(2, INT_TOP16)); //  0: x2 = 0xFFFC (tag)
    buf.emit(lsrX(3, 0, 48)); //        1: x3 = top16(a)
    buf.emit(cmpRegX(3, 2)); //         2: cmp x3, x2
    buf.emit(bCond(.ne, 14)); //        3: a not fixnum -> deopt (instr 17)
    buf.emit(lsrX(3, 1, 48)); //        4: x3 = top16(b)
    buf.emit(cmpRegX(3, 2)); //         5
    buf.emit(bCond(.ne, 11)); //        6: b not fixnum -> deopt (instr 17)
    buf.emit(sbfxX(3, 0, 0, 48)); //    7: x3 = unbox(a)
    buf.emit(sbfxX(4, 1, 0, 48)); //    8: x4 = unbox(b)
    buf.emit(addRegX(3, 3, 4)); //      9: x3 = a + b (full i64)
    buf.emit(sbfxX(4, 3, 0, 48)); //   10: x4 = sign-extend low48 of sum
    buf.emit(cmpRegX(4, 3)); //        11: fits i48 iff x4 == x3
    buf.emit(bCond(.ne, 5)); //        12: overflow -> deopt (instr 17)
    buf.emit(movkX(3, INT_TOP16, 3)); //13: rebox sum (stamp tag into [63:48])
    buf.emit(addRegX(0, 3, 31)); //    14: x0 = value = x3
    buf.emit(movzX(1, 0)); //          15: x1 = status = 0
    buf.emit(ret()); //                16
    buf.emit(movzX(1, 1)); //          17: deopt: status = 1
    buf.emit(movzX(0, 0)); //          18: value = 0 (sentinel)
    buf.emit(ret()); //                19
    const f = try buf.finalize(*const fn (u64, u64) callconv(.c) Ret);

    // ok: 40 + 2 = 42, both fixnum, fits i48.
    const ok = f(@intFromEnum(Value.initInteger(40)), @intFromEnum(Value.initInteger(2)));
    try std.testing.expectEqual(@as(u64, 0), ok.status);
    try std.testing.expectEqual(@intFromEnum(Value.initInteger(42)), ok.value);
    // ok: negatives.
    const okn = f(@intFromEnum(Value.initInteger(5)), @intFromEnum(Value.initInteger(-12)));
    try std.testing.expectEqual(@as(u64, 0), okn.status);
    try std.testing.expectEqual(@intFromEnum(Value.initInteger(-7)), okn.value);
    // deopt: non-fixnum operand (nil).
    const dn = f(@intFromEnum(Value.initInteger(40)), @intFromEnum(Value.nil_val));
    try std.testing.expectEqual(@as(u64, 1), dn.status);
    // deopt: i48 overflow (MAX + 1 leaves the i48 window → VM auto-promotes to BigInt).
    const dov = f(@intFromEnum(Value.initInteger(nb.NB_I48_MAX)), @intFromEnum(Value.initInteger(1)));
    try std.testing.expectEqual(@as(u64, 1), dov.status);
}
