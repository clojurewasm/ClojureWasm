// SPDX-License-Identifier: EPL-2.0
//! Regex compile pipeline (parser + AST + IR) — namespace-neutral
//! implementation per F-009.
//!
//! Implements ADR-0031 Alternative 2 (two-tier IR + lazy DFA over
//! Pike-NFA). This module owns the parser → AST → `Program` IR
//! pipeline. The matcher lives in `match.zig` (Pike VM, cycle 1
//! correctness baseline) and `dfa.zig` (lazy DFA fast path,
//! cycle 2).
//!
//! Two surfaces consume this file:
//!   1. `lang/primitive/regex.zig` — Clojure-ns peer (`re-pattern`
//!      / `re-find` / `re-matches` / `re-seq` / `re-groups` in
//!      clojure.core).
//!   2. `runtime/java/util/regex/Pattern.zig` — Java surface
//!      (`(java.util.regex.Pattern/compile ...)` etc.).
//!
//! Status: Phase 6.6 cycle 1 SKELETON — types declared, parser
//! and IR emission land in the next commits of this cycle. Per
//! `no_op_stub_forbidden`, `compile(...)` raises an explicit
//! error rather than silently dropping semantics.

const std = @import("std");

/// Compile flags. `(?i)` inline modifier rewrites at compile
/// time into case-folded character classes (ADR-0031 Alt 2 cycle
/// 4); the runtime sees only the folded form.
pub const Flags = packed struct(u8) {
    case_insensitive: bool = false,
    _pad: u7 = 0,
};

/// IR instruction (Pike VM opcode). Matches Russ Cox's
/// thread-list VM design — `char` / `range` advance, `match` is
/// the accept state, `jmp` / `split` change the PC, `save`
/// records a capture-group boundary into the thread's slot
/// array.
pub const Inst = union(enum) {
    char: u8,
    range: struct { lo: u8, hi: u8 },
    match: void,
    jmp: u32,
    split: struct { a: u32, b: u32 },
    save: u32,
};

/// Compiled program — the IR boundary between parser/optimiser
/// and the runtime matcher (NFA / DFA). Lifetime equals the
/// `Pattern` Value that owns it.
pub const Program = struct {
    insts: []const Inst,
    capture_count: u16,
    flags: Flags,

    pub fn deinit(self: *Program, alloc: std.mem.Allocator) void {
        alloc.free(self.insts);
    }
};

pub const CompileError = error{
    /// Phase 6.6 cycle 1 skeleton — body lands in the next
    /// commit. Per `no_op_stub_forbidden`, this is an explicit
    /// "not implemented" rather than a silent drop.
    NotImplemented,

    /// Reserved for parser errors once the parser lands.
    UnexpectedToken,
    UnclosedGroup,
    UnclosedClass,
    InvalidQuantifier,
    InvalidEscape,
} || std.mem.Allocator.Error;

/// Compile a regex pattern source into a `Program`. Caller owns
/// the resulting `Program` and must call `Program.deinit` to
/// free the IR slice.
///
/// Status: skeleton — returns `CompileError.NotImplemented` until
/// the parser + AST emit lands.
pub fn compile(alloc: std.mem.Allocator, pattern: []const u8, flags: Flags) CompileError!Program {
    _ = alloc;
    _ = pattern;
    _ = flags;
    return CompileError.NotImplemented;
}
