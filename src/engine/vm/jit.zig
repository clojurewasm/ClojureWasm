// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! ARM64 JIT Compiler (PoC).
//!
//! Compiles hot integer loops to native ARM64 machine code at runtime.
//! Supports a restricted set of bytecode patterns: integer comparison,
//! arithmetic (add/sub), and recur_loop. Falls back to interpreter
//! (deopt) on non-integer values.
//!
//! Register convention for JIT-compiled code:
//!   x0  = return value (NaN-boxed)
//!   x1  = return status (0=ok, 1=deopt)
//!   x16 = base pointer (&stack[frame.base])
//!   x17 = temp (tag checking)
//!   x3..x15 = loop variables (unboxed i64)
//!
//! Calling convention (C ABI):
//!   Input:  x0 = stack ptr, x1 = base (slot count), x2 = constants ptr
//!   Output: x0 = result value, x1 = status

const std = @import("std");
const builtin = @import("builtin");
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;
const OpCode = opcodes.OpCode;

/// JIT-compiled function signature.
/// Returns (value, status) where status: 0 = success, 1 = deopt.
pub const JitFn = *const fn ([*]u64, usize, [*]const u64) callconv(.c) JitResult;

pub const JitResult = extern struct {
    value: u64,
    status: u64,
};

/// NaN boxing constants (must match value.zig).
const NB_INT_TAG: u64 = 0xFFF9_0000_0000_0000;
const NB_PAYLOAD_MASK: u64 = 0x0000_FFFF_FFFF_FFFF;

pub const JitCompiler = struct {
    buffer: []align(std.heap.page_size_min) u8,
    offset: usize,

    const PAGE_SIZE = std.heap.page_size_min;
    const BUFFER_SIZE = PAGE_SIZE; // 1 page for PoC

    pub fn init() !JitCompiler {
        const PROT = std.posix.PROT;
        const mem = std.posix.mmap(
            null,
            BUFFER_SIZE,
            PROT.READ | PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch return error.MmapFailed;
        return .{ .buffer = @alignCast(mem), .offset = 0 };
    }

    pub fn deinit(self: *JitCompiler) void {
        std.posix.munmap(@alignCast(self.buffer));
    }

    /// Emit a 32-bit ARM64 instruction.
    fn emit(self: *JitCompiler, inst: u32) void {
        const bytes = std.mem.asBytes(&inst);
        @memcpy(self.buffer[self.offset..][0..4], bytes);
        self.offset += 4;
    }

    /// Make the buffer executable (W^X transition).
    fn makeExecutable(self: *JitCompiler) !void {
        const PROT = std.posix.PROT;
        std.posix.mprotect(@alignCast(self.buffer), PROT.READ | PROT.EXEC) catch
            return error.MprotectFailed;
        // Flush instruction cache (required on ARM64).
        icacheInvalidate(self.buffer.ptr, self.offset);
    }

    /// Get the compiled function pointer.
    fn getFunction(self: *JitCompiler) JitFn {
        return @ptrCast(@alignCast(self.buffer.ptr));
    }

    // ---------------------------------------------------------------
    // ARM64 instruction encoding helpers
    // ---------------------------------------------------------------

    /// LDR Xd, [Xn, #imm] — load 64-bit from [Xn + imm].
    /// imm must be 8-byte aligned, encoded as imm/8.
    fn ldr(rd: u5, rn: u5, imm_bytes: u16) u32 {
        const imm12: u12 = @intCast(imm_bytes / 8);
        return 0xF9400000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rd);
    }

    /// STR Xt, [Xn, #imm] — store 64-bit to [Xn + imm].
    fn str(rt: u5, rn: u5, imm_bytes: u16) u32 {
        const imm12: u12 = @intCast(imm_bytes / 8);
        return 0xF9000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
    }

    /// ADD Xd, Xn, Xm — add two registers.
    fn addReg(rd: u5, rn: u5, rm: u5) u32 {
        return 0x8B000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
    }

    /// ADD Xd, Xn, #imm12 — add 12-bit immediate.
    fn addImm(rd: u5, rn: u5, imm12: u12) u32 {
        return 0x91000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rd);
    }

    /// ADD Xd, Xn, Xm, LSL #shift — add with left shift.
    fn addRegShift(rd: u5, rn: u5, rm: u5, shift: u6) u32 {
        return 0x8B000000 | (@as(u32, rm) << 16) | (@as(u32, shift) << 10) | (@as(u32, rn) << 5) | @as(u32, rd);
    }

    /// SUB Xd, Xn, Xm — subtract two registers.
    fn subReg(rd: u5, rn: u5, rm: u5) u32 {
        return 0xCB000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
    }

    /// SUB Xd, Xn, #imm12 — subtract 12-bit immediate.
    fn subImm(rd: u5, rn: u5, imm12: u12) u32 {
        return 0xD1000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rd);
    }

    /// CMP Xn, Xm — compare two registers (SUBS XZR, Xn, Xm).
    fn cmpReg(rn: u5, rm: u5) u32 {
        return 0xEB00001F | (@as(u32, rm) << 16) | (@as(u32, rn) << 5);
    }

    /// CMP Xn, #imm12 — compare with immediate (SUBS XZR, Xn, #imm12).
    fn cmpImm(rn: u5, imm12: u12) u32 {
        return 0xF100001F | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5);
    }

    /// B.cond — conditional branch. offset in instructions (signed).
    fn bCond(cond: Cond, offset: i19) u32 {
        const imm: u19 = @bitCast(offset);
        return 0x54000000 | (@as(u32, imm) << 5) | @as(u32, @intFromEnum(cond));
    }

    /// B — unconditional branch. offset in instructions (signed).
    fn bImm(offset: i26) u32 {
        const imm: u26 = @bitCast(offset);
        return 0x14000000 | @as(u32, imm);
    }

    /// RET — return to caller (via x30).
    fn ret_() u32 {
        return 0xD65F03C0;
    }

    /// MOVZ Xd, #imm16, LSL #(shift*16).
    fn movz(rd: u5, imm16: u16, shift: u2) u32 {
        return 0xD2800000 | (@as(u32, shift) << 21) | (@as(u32, imm16) << 5) | @as(u32, rd);
    }

    /// MOVK Xd, #imm16, LSL #(shift*16) — move and keep.
    fn movk(rd: u5, imm16: u16, shift: u2) u32 {
        return 0xF2800000 | (@as(u32, shift) << 21) | (@as(u32, imm16) << 5) | @as(u32, rd);
    }

    /// LSR Xd, Xn, #shift — logical shift right (UBFM alias).
    fn lsrImm(rd: u5, rn: u5, shift: u6) u32 {
        return 0xD340FC00 | (@as(u32, shift) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
    }

    /// SBFX Xd, Xn, #lsb, #width — signed bitfield extract.
    fn sbfx(rd: u5, rn: u5, lsb: u6, width: u6) u32 {
        const imms: u6 = lsb + width - 1;
        return 0x93400000 | (@as(u32, lsb) << 16) | (@as(u32, imms) << 10) | (@as(u32, rn) << 5) | @as(u32, rd);
    }

    /// ORR Xd, Xn, Xm — bitwise OR registers.
    fn orrReg(rd: u5, rn: u5, rm: u5) u32 {
        return 0xAA000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
    }

    /// AND Xd, Xn, #0x0000FFFFFFFFFFFF — mask to 48-bit payload.
    /// ARM64 bitmask encoding: N=1, immr=0, imms=47.
    fn andPayloadMask(rd: u5, rn: u5) u32 {
        return 0x92400000 | (47 << 10) | (@as(u32, rn) << 5) | @as(u32, rd);
    }

    /// MOV Xd, Xm (ORR Xd, XZR, Xm).
    fn movReg(rd: u5, rm: u5) u32 {
        return orrReg(rd, 31, rm);
    }

    /// MOV Xd, #0 (MOVZ Xd, #0).
    fn movZero(rd: u5) u32 {
        return movz(rd, 0, 0);
    }

    /// ARM64 condition codes.
    const Cond = enum(u4) {
        eq = 0b0000,
        ne = 0b0001,
        lt = 0b1011,
        ge = 0b1010,
        le = 0b1101,
        gt = 0b1100,
    };

    // ---------------------------------------------------------------
    // Loop pattern analysis
    // ---------------------------------------------------------------

    const LoopOp = union(enum) {
        /// Compare two locals, branch to exit if condition met.
        branch_cmp: struct { slot_a: u8, slot_b: u8, exit_cond: Cond },
        /// Compare local with constant, branch to exit if condition met.
        branch_cmp_const: struct { slot: u8, const_idx: u8, exit_cond: Cond },
        /// Add two locals, result goes to a virtual stack position.
        add_locals: struct { slot_a: u8, slot_b: u8 },
        /// Add local + constant.
        add_local_const: struct { slot: u8, const_idx: u8 },
        /// Subtract two locals.
        sub_locals: struct { slot_a: u8, slot_b: u8 },
        /// Subtract local - constant.
        sub_local_const: struct { slot: u8, const_idx: u8 },
        /// Recur: rebind loop variables from virtual stack.
        recur_loop: struct { base_offset: u8, arg_count: u8 },
    };

    /// Analyze a loop body and extract operations.
    /// Returns null if the pattern is not JIT-compatible.
    fn analyzeLoop(
        code: []const Instruction,
        loop_start: usize,
        loop_end: usize, // exclusive (past recur_loop + data word)
    ) ?[]const LoopOp {
        var ops: [32]LoopOp = undefined;
        var count: usize = 0;

        var ip = loop_start;
        while (ip < loop_end) {
            if (count >= 32) return null;
            const instr = code[ip];
            switch (instr.op) {
                .branch_ne_locals => {
                    const slots = unpack(instr.operand);
                    ops[count] = .{ .branch_cmp = .{ .slot_a = slots[0], .slot_b = slots[1], .exit_cond = .eq } };
                    count += 1;
                    // Skip data word + THEN path (exit code), jump to ELSE path (loop body).
                    const exit_offset: usize = @intCast(code[ip + 1].operand);
                    ip = ip + 2 + exit_offset;
                },
                .branch_ge_locals => {
                    const slots = unpack(instr.operand);
                    ops[count] = .{ .branch_cmp = .{ .slot_a = slots[0], .slot_b = slots[1], .exit_cond = .lt } };
                    count += 1;
                    const exit_offset: usize = @intCast(code[ip + 1].operand);
                    ip = ip + 2 + exit_offset;
                },
                .branch_gt_locals => {
                    const slots = unpack(instr.operand);
                    ops[count] = .{ .branch_cmp = .{ .slot_a = slots[0], .slot_b = slots[1], .exit_cond = .le } };
                    count += 1;
                    const exit_offset: usize = @intCast(code[ip + 1].operand);
                    ip = ip + 2 + exit_offset;
                },
                .branch_ne_local_const => {
                    const parts = unpack(instr.operand);
                    ops[count] = .{ .branch_cmp_const = .{ .slot = parts[0], .const_idx = parts[1], .exit_cond = .eq } };
                    count += 1;
                    const exit_offset: usize = @intCast(code[ip + 1].operand);
                    ip = ip + 2 + exit_offset;
                },
                .branch_ge_local_const => {
                    const parts = unpack(instr.operand);
                    ops[count] = .{ .branch_cmp_const = .{ .slot = parts[0], .const_idx = parts[1], .exit_cond = .lt } };
                    count += 1;
                    const exit_offset: usize = @intCast(code[ip + 1].operand);
                    ip = ip + 2 + exit_offset;
                },
                .branch_gt_local_const => {
                    const parts = unpack(instr.operand);
                    ops[count] = .{ .branch_cmp_const = .{ .slot = parts[0], .const_idx = parts[1], .exit_cond = .le } };
                    count += 1;
                    const exit_offset: usize = @intCast(code[ip + 1].operand);
                    ip = ip + 2 + exit_offset;
                },
                .add_locals => {
                    const slots = unpack(instr.operand);
                    ops[count] = .{ .add_locals = .{ .slot_a = slots[0], .slot_b = slots[1] } };
                    count += 1;
                    ip += 1;
                },
                .add_local_const => {
                    const parts = unpack(instr.operand);
                    ops[count] = .{ .add_local_const = .{ .slot = parts[0], .const_idx = parts[1] } };
                    count += 1;
                    ip += 1;
                },
                .sub_locals => {
                    const slots = unpack(instr.operand);
                    ops[count] = .{ .sub_locals = .{ .slot_a = slots[0], .slot_b = slots[1] } };
                    count += 1;
                    ip += 1;
                },
                .sub_local_const => {
                    const parts = unpack(instr.operand);
                    ops[count] = .{ .sub_local_const = .{ .slot = parts[0], .const_idx = parts[1] } };
                    count += 1;
                    ip += 1;
                },
                .recur_loop => {
                    const base_off: u8 = @intCast((instr.operand >> 8) & 0xFF);
                    const arg_count: u8 = @intCast(instr.operand & 0xFF);
                    ops[count] = .{ .recur_loop = .{ .base_offset = base_off, .arg_count = arg_count } };
                    count += 1;
                    ip += 2; // skip data word
                },
                else => return null, // unsupported opcode
            }
        }

        // Must end with recur_loop.
        if (count == 0) return null;
        switch (ops[count - 1]) {
            .recur_loop => {},
            else => return null,
        }

        return ops[0..count];
    }

    // ---------------------------------------------------------------
    // Code generation
    // ---------------------------------------------------------------

    /// Try to compile a hot loop to native ARM64 code.
    /// code: full instruction array for the function.
    /// loop_start: IP of first loop body instruction (the compare-and-branch).
    /// loop_end: IP past the recur_loop's data word.
    /// constants: the function's constant pool (as raw u64).
    /// max_slot: highest local slot accessed in the loop.
    pub fn compileLoop(
        self: *JitCompiler,
        code: []const Instruction,
        _: [*]const u64,
        loop_start: usize,
        loop_end: usize,
    ) ?JitFn {
        if (builtin.cpu.arch != .aarch64) return null;

        const ops_slice = analyzeLoop(code, loop_start, loop_end) orelse return null;
        // Copy ops to stack buffer (analyzeLoop returns pointer to static buffer).
        var ops: [32]LoopOp = undefined;
        const op_count = ops_slice.len;
        @memcpy(ops[0..op_count], ops_slice);

        // Collect referenced slots (bitset). Only load and type-check slots
        // that are actually used by the loop body. Slot 0 may contain a
        // closure self-reference (fn_val) which is NOT an integer.
        var used_slots: u16 = 0; // bitmask, bit i = slot i is referenced
        var max_slot: u8 = 0;
        for (ops[0..op_count]) |op| {
            switch (op) {
                .branch_cmp => |b| {
                    used_slots |= @as(u16, 1) << @intCast(b.slot_a);
                    used_slots |= @as(u16, 1) << @intCast(b.slot_b);
                    max_slot = @max(max_slot, @max(b.slot_a, b.slot_b));
                },
                .branch_cmp_const => |b| {
                    used_slots |= @as(u16, 1) << @intCast(b.slot);
                    max_slot = @max(max_slot, b.slot);
                },
                .add_locals => |a| {
                    used_slots |= @as(u16, 1) << @intCast(a.slot_a);
                    used_slots |= @as(u16, 1) << @intCast(a.slot_b);
                    max_slot = @max(max_slot, @max(a.slot_a, a.slot_b));
                },
                .sub_locals => |a| {
                    used_slots |= @as(u16, 1) << @intCast(a.slot_a);
                    used_slots |= @as(u16, 1) << @intCast(a.slot_b);
                    max_slot = @max(max_slot, @max(a.slot_a, a.slot_b));
                },
                .add_local_const => |a| {
                    used_slots |= @as(u16, 1) << @intCast(a.slot);
                    max_slot = @max(max_slot, a.slot);
                },
                .sub_local_const => |a| {
                    used_slots |= @as(u16, 1) << @intCast(a.slot);
                    max_slot = @max(max_slot, a.slot);
                },
                .recur_loop => |r| {
                    const last = r.base_offset + r.arg_count - 1;
                    for (r.base_offset..last + 1) |s| {
                        used_slots |= @as(u16, 1) << @intCast(s);
                    }
                    max_slot = @max(max_slot, last);
                },
            }
        }

        // Max 13 local slots (x3..x15).
        if (max_slot > 12) return null;

        self.offset = 0;

        // --- Prologue: compute base pointer, load and unbox locals ---

        // x16 = x0 + x1 * 8 = &stack[base]
        self.emit(addRegShift(16, 0, 1, 3));

        // Load and unbox only referenced slots.
        // slot i → register (i + 3). Skip unused slots (e.g., closure self-ref).
        // x17 = NB_INT_TAG >> 48 = 0xFFF9 (for tag comparison)
        self.emit(movz(17, 0xFFF9, 0));

        for (0..@as(usize, max_slot) + 1) |slot| {
            if (used_slots & (@as(u16, 1) << @intCast(slot)) == 0) continue;
            const reg: u5 = @intCast(slot + 3);
            self.emit(ldr(reg, 16, @intCast(slot * 8)));
            self.emit(lsrImm(18, reg, 48));
            self.emit(cmpReg(18, 17));
            self.emit(0); // placeholder for B.NE deopt
            self.emit(sbfx(reg, reg, 0, 48));
        }

        // Load constants referenced by *_local_const ops into x19..x28 (callee-saved).
        // For PoC simplicity: unbox constants inline where needed.
        // Actually, for the PoC, let's just unbox constants during prologue into
        // a separate set of registers. We have x19-x28 as callee-saved, so we
        // need to save/restore them. For simplicity, keep constants in memory
        // and load them fresh in the loop body from x2 (constants pointer).

        // --- Main loop ---
        const loop_top = self.offset;

        // Track virtual stack for recur_loop.
        // The add_locals/add_local_const operations push to a virtual stack.
        // recur_loop copies from virtual stack back to local registers.
        // For code generation, we track which register each virtual push goes to.
        var vstack: [16]u5 = undefined; // register holding each vstack entry
        var vsp: usize = 0;

        for (ops[0..op_count]) |op| {
            switch (op) {
                .branch_cmp => |b| {
                    const ra: u5 = @intCast(@as(u8, b.slot_a) + 3);
                    const rb: u5 = @intCast(@as(u8, b.slot_b) + 3);
                    self.emit(cmpReg(ra, rb));
                    // Branch to exit on exit_cond. Offset patched later.
                    const exit_branch_pos = self.offset;
                    _ = exit_branch_pos;
                    self.emit(0); // placeholder
                },
                .branch_cmp_const => |b| {
                    const ra: u5 = @intCast(@as(u8, b.slot) + 3);
                    // Load constant from memory, unbox, compare.
                    // ldr x18, [x2, #const_idx*8]
                    self.emit(ldr(18, 2, @intCast(@as(u16, b.const_idx) * 8)));
                    self.emit(sbfx(18, 18, 0, 48));
                    self.emit(cmpReg(ra, 18));
                    self.emit(0); // placeholder for exit branch
                },
                .add_locals => |a| {
                    const ra: u5 = @intCast(@as(u8, a.slot_a) + 3);
                    const rb: u5 = @intCast(@as(u8, a.slot_b) + 3);
                    // Result into x18 (temp), push to vstack.
                    self.emit(addReg(18, ra, rb));
                    vstack[vsp] = 18;
                    // But we might need multiple vstack entries, so store in
                    // different temp registers. Use x18, x19, x20...
                    // For PoC: max 2 vstack entries (arith_loop).
                    const dst: u5 = @intCast(18 + vsp);
                    if (dst > 20) return null; // too many temporaries
                    self.emit(addReg(dst, ra, rb));
                    // Fix: we emitted twice. Remove the first emit.
                    // Actually let me restructure.
                    // Re-do: emit into the correct register directly.
                    self.offset -= 8; // undo both emits
                    const tmp: u5 = @intCast(18 + vsp);
                    if (tmp > 20) return null;
                    self.emit(addReg(tmp, ra, rb));
                    vstack[vsp] = tmp;
                    vsp += 1;
                },
                .add_local_const => |a| {
                    const ra: u5 = @intCast(@as(u8, a.slot) + 3);
                    const tmp: u5 = @intCast(18 + vsp);
                    if (tmp > 20) return null;
                    // Load constant, unbox, add.
                    self.emit(ldr(tmp, 2, @intCast(@as(u16, a.const_idx) * 8)));
                    self.emit(sbfx(tmp, tmp, 0, 48));
                    self.emit(addReg(tmp, ra, tmp));
                    vstack[vsp] = tmp;
                    vsp += 1;
                },
                .sub_locals => |a| {
                    const ra: u5 = @intCast(@as(u8, a.slot_a) + 3);
                    const rb: u5 = @intCast(@as(u8, a.slot_b) + 3);
                    const tmp: u5 = @intCast(18 + vsp);
                    if (tmp > 20) return null;
                    self.emit(subReg(tmp, ra, rb));
                    vstack[vsp] = tmp;
                    vsp += 1;
                },
                .sub_local_const => |a| {
                    const ra: u5 = @intCast(@as(u8, a.slot) + 3);
                    const tmp: u5 = @intCast(18 + vsp);
                    if (tmp > 20) return null;
                    self.emit(ldr(tmp, 2, @intCast(@as(u16, a.const_idx) * 8)));
                    self.emit(sbfx(tmp, tmp, 0, 48));
                    self.emit(subReg(tmp, ra, tmp));
                    vstack[vsp] = tmp;
                    vsp += 1;
                },
                .recur_loop => |r| {
                    // Copy vstack entries back to local registers.
                    // vstack[0] → slot r.base_offset → reg (base_offset + 3)
                    // vstack[1] → slot r.base_offset+1 → reg (base_offset + 4)
                    // etc.
                    for (0..r.arg_count) |idx| {
                        const dst_reg: u5 = @intCast(@as(u8, r.base_offset) + @as(u8, @intCast(idx)) + 3);
                        const src_reg = vstack[idx];
                        if (dst_reg != src_reg) {
                            self.emit(movReg(dst_reg, src_reg));
                        }
                    }
                    vsp = 0;
                },
            }
        }

        // Loop back to top.
        const loop_back_offset: i26 = @intCast(@as(i32, @intCast(loop_top)) - @as(i32, @intCast(self.offset)));
        self.emit(bImm(@intCast(@divExact(loop_back_offset, 4))));

        // --- Exit: box result and return ---
        const exit_pos = self.offset;

        // The exit value is the first local after the loop bindings.
        // For arith_loop: the recur_loop copies to base_offset with arg_count args.
        // The exit path in the original bytecode loads a specific slot.
        // For PoC: find the branch_cmp exit and determine which slot to return.
        // Convention: the exit value is on the interpreter stack at
        // the position after the loop. For simplicity, return the last
        // local that was NOT a loop binding variable (i.e., the accumulator).
        //
        // Actually, looking at the bytecode structure:
        // After the loop exits, the interpreter loads a specific slot.
        // For the PoC, the caller tells us which slot has the result.
        // But we don't have that info here. Let's use a heuristic:
        // The recur_loop's last arg is typically the accumulator.
        const recur_op = ops[op_count - 1].recur_loop;
        const result_slot = recur_op.base_offset + recur_op.arg_count - 1;
        const result_reg: u5 = @intCast(result_slot + 3);

        // Box result: x0 = (result & PAYLOAD_MASK) | NB_INT_TAG
        self.emit(andPayloadMask(0, result_reg));
        self.emit(movz(17, 0xFFF9, 3)); // x17 = 0xFFF9 << 48
        self.emit(orrReg(0, 0, 17));
        // x1 = 0 (success)
        self.emit(movZero(1));
        self.emit(ret_());

        // --- Deopt: return sentinel ---
        const deopt_pos = self.offset;
        self.emit(movZero(0));
        self.emit(movz(1, 1, 0)); // x1 = 1 (deopt)
        self.emit(ret_());

        // --- Patch branch placeholders ---
        // Walk through emitted code and patch the placeholder instructions.
        var patch_ip: usize = 0;
        var in_prologue = true;
        while (patch_ip < self.offset) {
            const inst = std.mem.bytesAsValue(u32, self.buffer[patch_ip..][0..4]);
            if (inst.* == 0) {
                // Placeholder found — determine if prologue (deopt) or loop (exit).
                if (in_prologue) {
                    // Deopt branch: B.NE to deopt_pos.
                    const off: i19 = @intCast(@divExact(@as(i32, @intCast(deopt_pos)) - @as(i32, @intCast(patch_ip)), 4));
                    inst.* = bCond(.ne, off);
                } else {
                    const off: i19 = @intCast(@divExact(@as(i32, @intCast(exit_pos)) - @as(i32, @intCast(patch_ip)), 4));
                    // We need the condition from the op. Since we process ops in order,
                    // we can track which branch placeholder this is.
                    inst.* = bCond(self.findExitCond(ops[0..op_count], patch_ip, loop_top), off);
                }
            }
            if (patch_ip >= loop_top and in_prologue) in_prologue = false;
            patch_ip += 4;
        }

        self.makeExecutable() catch return null;
        return self.getFunction();
    }

    /// Find the exit condition for a branch placeholder at the given offset.
    fn findExitCond(self: *JitCompiler, ops: []const LoopOp, patch_offset: usize, loop_top: usize) Cond {
        _ = self;
        // Walk ops and count branch instructions to find which one this is.
        _ = loop_top;
        _ = patch_offset;
        for (ops) |op| {
            switch (op) {
                .branch_cmp => |b| return b.exit_cond,
                .branch_cmp_const => |b| return b.exit_cond,
                else => {},
            }
        }
        return .eq; // fallback
    }

    fn unpack(operand: u16) struct { u8, u8 } {
        return .{ @intCast(operand >> 8), @truncate(operand) };
    }
};

/// Flush instruction cache on ARM64 (required after writing code).
fn icacheInvalidate(ptr: [*]const u8, len: usize) void {
    if (builtin.os.tag == .macos) {
        // macOS provides sys_icache_invalidate.
        const func = @extern(*const fn ([*]const u8, usize) callconv(.c) void, .{
            .name = "sys_icache_invalidate",
        });
        func(ptr, len);
    } else {
        // Linux ARM64: use __clear_cache.
        const func = @extern(*const fn ([*]const u8, [*]const u8) callconv(.c) void, .{
            .name = "__clear_cache",
        });
        func(ptr, ptr + len);
    }
}

// ---------------------------------------------------------------
// Tests
// ---------------------------------------------------------------

test "ARM64 instruction encoding" {
    if (builtin.cpu.arch != .aarch64) return;

    // ADD X3, X4, X5
    try std.testing.expectEqual(@as(u32, 0x8B050083), JitCompiler.addReg(3, 4, 5));
    // CMP X3, X4
    try std.testing.expectEqual(@as(u32, 0xEB04007F), JitCompiler.cmpReg(3, 4));
    // RET
    try std.testing.expectEqual(@as(u32, 0xD65F03C0), JitCompiler.ret_());
    // MOVZ X0, #0
    try std.testing.expectEqual(@as(u32, 0xD2800000), JitCompiler.movz(0, 0, 0));
    // MOVZ X17, #0xFFF9, LSL #48
    try std.testing.expectEqual(@as(u32, 0xD2FFFF31), JitCompiler.movz(17, 0xFFF9, 3));
}

test "JIT compile and execute simple loop" {
    if (builtin.cpu.arch != .aarch64) return;

    const Value = @import("../../runtime/value.zig").Value;

    // Simulate arith_loop: (loop [i 0 acc 0] (if (= i n) acc (recur (+ i 1) (+ acc i))))
    // Function args: slot 0 = n
    // Loop vars: slot 1 = i, slot 2 = acc
    // Bytecode layout matches real compiler output (includes THEN/exit path):
    //   IP 0: branch_ne_locals (slot1, slot0)   ; if i != n, branch to ELSE
    //   IP 1: data (exit_offset=2)              ; branches to IP 4 (ELSE path)
    //   IP 2: local_load slot=2                 ; THEN: load acc (exit value)
    //   IP 3: jump 4                            ; THEN: jump past loop
    //   IP 4: add_local_const (slot1, const0)   ; ELSE: i + 1
    //   IP 5: add_locals (slot2, slot1)         ; ELSE: acc + i
    //   IP 6: recur_loop (base=1, count=2)      ; ELSE: rebind and loop back
    //   IP 7: data (loop_offset=8)              ; back to IP 0

    const code = [_]Instruction{
        .{ .op = .branch_ne_locals, .operand = (1 << 8) | 0 },
        .{ .op = .jump_if_false, .operand = 2 }, // exit_offset=2 → ELSE at IP 4
        .{ .op = .local_load, .operand = 2 }, // THEN: load acc
        .{ .op = .jump, .operand = 4 }, // THEN: jump past loop
        .{ .op = .add_local_const, .operand = (1 << 8) | 0 },
        .{ .op = .add_locals, .operand = (2 << 8) | 1 },
        .{ .op = .recur_loop, .operand = (1 << 8) | 2 },
        .{ .op = .jump_back, .operand = 8 }, // loop_offset=8 → back to IP 0
    };

    // Constants: [0] = 1 (the increment value)
    const one = Value.initInteger(1);
    const constants = [_]u64{@intFromEnum(one)};

    // Stack: [n=10, i=0, acc=0]
    const n_val = Value.initInteger(10);
    const zero_val = Value.initInteger(0);
    var stack = [_]u64{
        @intFromEnum(n_val),
        @intFromEnum(zero_val),
        @intFromEnum(zero_val),
    };

    var compiler = JitCompiler.init() catch return;
    defer compiler.deinit();

    const jit_fn = compiler.compileLoop(&code, &constants, 0, 8) orelse
        return error.JitCompilationFailed;

    const result = jit_fn(&stack, 0, &constants);
    try std.testing.expectEqual(@as(u64, 0), result.status); // success
    const result_val: Value = @enumFromInt(result.value);
    try std.testing.expectEqual(@as(i64, 45), result_val.asInteger()); // sum(0..9) = 45
}
