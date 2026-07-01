// SPDX-License-Identifier: EPL-2.0
//! VM peephole optimizer — post-compile, behaviour-preserving local
//! rewrites over the `Instruction` stream (ADR-0047, Phase 13 row 13.3).
//!
//! Runs inside `compiler.finalize`, so every chunk — top-level AND
//! each fn sub-chunk (which finalizes the same way) — is optimized,
//! and the Phase-12 serializer caches the optimized chunk. Peephole
//! stays in the 110% tier: removal-only, NO instruction fusion
//! (fusion is Phase 17 `super_instruction.zig`, 100% tier).
//!
//! The single load-bearing primitive is `applyPlan`: rules mark a
//! `keep` mask, `applyPlan` compacts the stream and re-resolves the
//! three position-referencing operands (`op_jump` / `op_jump_if_false`
//! / `op_push_handler`, signed-i16-offset-relative-to-next). Physical
//! removal is the only honest optimization for cljw's opcode set;
//! `op_nop` null-out would still pay a dispatch turn.
//!
//! First rule: pure-push + `op_pop` elision. A pure push (per
//! `Opcode.isPurePush`) immediately followed by `op_pop` is a no-op
//! (net stack 0, no side effect). Written as a plain function — a
//! one-entry rule registry is excessive skeleton per F-002.

const std = @import("std");
const opcode_mod = @import("opcode.zig");
const Opcode = opcode_mod.Opcode;
const Instruction = opcode_mod.Instruction;

/// Absolute target index of a position-relative instruction at `index`.
/// `applyJump` (`vm.zig`) adds the offset AFTER advancing ip past the
/// op, so the target = `index + 1 + offset`. Caller guarantees the op
/// at `index` is `Opcode.isPositionRelative()` true.
///
/// Codegen invariant: every emitted offset (forward or `op_recur`'s
/// negative back-edge) targets a real instruction in `[0, instrs.len]`
/// — the patchJump arithmetic (`compiler.zig:525-529`) never produces a
/// pre-chunk target. The `@intCast(usize)` therefore never underflows
/// on a well-formed chunk; if a future codegen change broke this
/// invariant, the trap surfaces in safe builds rather than corrupting
/// the IP-remap silently.
fn branchTarget(instrs: []const Instruction, index: usize) usize {
    const off = @as(i16, @bitCast(instrs[index].operand));
    const t = @as(i64, @intCast(index)) + 1 + off;
    return @intCast(t);
}

/// Optimize an instruction stream. Returns either the input slice
/// unchanged (no rewrite fired) or a freshly arena-allocated compacted
/// slice with branch operands re-resolved.
pub fn optimize(arena: std.mem.Allocator, instrs: []const Instruction) ![]const Instruction {
    if (instrs.len == 0) return instrs;

    // Targets[i] = true if some branch jumps to absolute index i.
    // A branch target must never be removed (orphaning the incoming
    // edge would corrupt control flow). Sized len+1 so a target
    // one-past-end (defensive — codegen never emits this today) lands
    // in-range without a separate check.
    const targets = try arena.alloc(bool, instrs.len + 1);
    @memset(targets, false);
    for (instrs, 0..) |ins, i| {
        if (ins.opcode.isPositionRelative()) {
            const t = branchTarget(instrs, i);
            if (t <= instrs.len) targets[t] = true;
        }
    }

    const keep = try arena.alloc(bool, instrs.len);
    @memset(keep, true);
    const removed = markPurePushPop(instrs, targets, keep);
    if (removed == 0) return instrs;

    return try applyPlan(arena, instrs, keep);
}

/// Rule: a pure push immediately followed by `op_pop` is removable.
/// Skips a candidate pair if either of its two indices is a branch
/// target. Returns the number of instructions marked for removal.
fn markPurePushPop(instrs: []const Instruction, targets: []const bool, keep: []bool) usize {
    var removed: usize = 0;
    var i: usize = 0;
    while (i + 1 < instrs.len) {
        const pushable = instrs[i].opcode.isPurePush();
        const pops = instrs[i + 1].opcode == .op_pop;
        const safe = !targets[i] and !targets[i + 1];
        if (pushable and pops and safe) {
            keep[i] = false;
            keep[i + 1] = false;
            removed += 2;
            i += 2;
        } else {
            i += 1;
        }
    }
    return removed;
}

/// Compact `instrs` to the kept subset and re-resolve every surviving
/// branch operand against the new instruction indices.
fn applyPlan(arena: std.mem.Allocator, instrs: []const Instruction, keep: []const bool) ![]const Instruction {
    // new_index[old] = new position of `old` if kept (= count of kept
    // instructions strictly before `old`). Always valid for kept
    // indices and for branch targets (which are kept by construction).
    // Sized len+1 to make a defensive one-past-end target map cleanly.
    const new_index = try arena.alloc(usize, instrs.len + 1);
    var n: usize = 0;
    for (instrs, 0..) |_, old| {
        new_index[old] = n;
        if (keep[old]) n += 1;
    }
    new_index[instrs.len] = n;

    const out = try arena.alloc(Instruction, n);
    var j: usize = 0;
    for (instrs, 0..) |ins, old| {
        if (!keep[old]) continue;
        var copy = ins;
        if (ins.opcode.isPositionRelative()) {
            const old_t = branchTarget(instrs, old);
            const new_t = new_index[old_t];
            // Compaction only ever shrinks distances (kept ≤ old) and
            // preserves the sign of (target - origin), so |new_off| ≤
            // |old_off|. The original offset fit in i16 (compiler's
            // patchJump enforces it), therefore new_off fits too — the
            // @intCast(i16) cannot overflow on a well-formed chunk.
            const new_off = @as(i64, @intCast(new_t)) - @as(i64, @intCast(j)) - 1;
            copy.operand = @as(u16, @bitCast(@as(i16, @intCast(new_off))));
        }
        out[j] = copy;
        j += 1;
    }
    return out;
}

// --- tests ---

const testing = std.testing;

fn inst(op: Opcode, operand: u16) Instruction {
    return .{ .opcode = op, .operand = operand };
}

fn jmp(off: i16) Instruction {
    return .{ .opcode = .op_jump, .operand = @as(u16, @bitCast(off)) };
}

fn jif(off: i16) Instruction {
    return .{ .opcode = .op_jump_if_false, .operand = @as(u16, @bitCast(off)) };
}

test "peephole: pure-push + op_pop pair is removed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const input = [_]Instruction{
        inst(.op_const, 0),
        inst(.op_pop, 0),
        inst(.op_const, 1),
        inst(.op_ret, 0),
    };
    const out = try optimize(a, &input);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(Opcode.op_const, out[0].opcode);
    try testing.expectEqual(@as(u16, 1), out[0].operand);
    try testing.expectEqual(Opcode.op_ret, out[1].opcode);
}

test "peephole: stream with no removable pair is returned unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const input = [_]Instruction{
        inst(.op_const, 0),
        inst(.op_ret, 0),
    };
    const out = try optimize(a, &input);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(input[0].opcode, out[0].opcode);
    try testing.expectEqual(input[1].opcode, out[1].opcode);
}

test "peephole: jump operand re-resolved when a pair is removed between jump and target" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // op_jump +3 (target = op_ret), then a removable (const, pop)
    // pair, then op_const, op_ret. After removal the jump's distance
    // to op_ret shrinks from 3 to 1.
    const input = [_]Instruction{
        jmp(3), // 0: jump → 4 (op_ret)
        inst(.op_const, 99), // 1: removable pair start
        inst(.op_pop, 0), // 2: removable pair end
        inst(.op_const, 1), // 3: kept
        inst(.op_ret, 0), // 4: jump target
    };
    const out = try optimize(a, &input);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqual(Opcode.op_jump, out[0].opcode);
    try testing.expectEqual(@as(i16, 1), @as(i16, @bitCast(out[0].operand)));
    try testing.expectEqual(Opcode.op_const, out[1].opcode);
    try testing.expectEqual(@as(u16, 1), out[1].operand);
    try testing.expectEqual(Opcode.op_ret, out[2].opcode);
}

test "peephole: branch target inside a candidate pair blocks the removal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // op_jump_if_false +0 → target = index 1 (the op_const). The
    // const+pop pair starts at the target, so the guard must block
    // its removal (removing index 1 would orphan the incoming edge).
    const input = [_]Instruction{
        jif(0), // 0: jif → 1
        inst(.op_const, 0), // 1: branch target — guard prevents removal
        inst(.op_pop, 0), // 2: would-be pop, kept
        inst(.op_ret, 0), // 3
    };
    const out = try optimize(a, &input);
    try testing.expectEqual(@as(usize, 4), out.len);
    try testing.expectEqual(Opcode.op_const, out[1].opcode);
    try testing.expectEqual(Opcode.op_pop, out[2].opcode);
}

test "peephole: empty stream returns unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const empty: []const Instruction = &.{};
    const out = try optimize(a, empty);
    try testing.expectEqual(@as(usize, 0), out.len);
}
