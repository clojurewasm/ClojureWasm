//! Stage-1 bootstrap — read+analyse+evaluate `clj/clojure/core.clj`
//! after `primitive.registerAll` populates the `rt` namespace and
//! `macro_transforms.registerInto` populates the analyzer's macro
//! Table.
//!
//! ### Why a separate module
//!
//! `main.zig` already runs the read-analyse-eval loop for user input
//! (CLI / file / stdin). The Stage-1 prologue uses the same loop but
//! over an embedded source string and a synthetic `<bootstrap>` source
//! label. Splitting it out keeps `main.zig` focused on argv handling
//! and lets unit tests drive the prologue without touching argv.
//!
//! ### Phase 3.12 scope
//!
//! - `loadCore` accepts an arena (caller-owned), runs the loop, and
//!   propagates errors via the standard `runtime/error.zig` pipeline
//!   so error context (file `<bootstrap>`, line, column) is preserved
//!   for the renderer.
//! - The embedded source `clj/clojure/core.clj` only uses today's
//!   special forms (`def`, `fn*`, `if`) — Clojure-level macros that
//!   themselves require user-defined `defmacro` arrive in later tasks.
//! - Wiring into `main.zig`'s startup chain is task 3.13.

const std = @import("std");

const Reader = @import("../eval/reader.zig").Reader;
const analyzeForm = @import("../eval/analyzer.zig").analyze;
const macro_dispatch = @import("../eval/macro_dispatch.zig");
const tree_walk = @import("../eval/backend/tree_walk.zig");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const Value = @import("../runtime/value.zig").Value;

/// The Stage-1 prologue source. Embedded at compile time so the binary
/// is self-contained — `cljw` does not need its source tree on disk to
/// boot.
pub const CORE_SOURCE: []const u8 = @embedFile("clj/clojure/core.clj");

/// Source label attributed to errors raised while evaluating the
/// prologue. Surfaces in `formatErrorWithContext` output as the
/// `<file>` portion of `<file>:<line>:<col>: ...`.
pub const SOURCE_LABEL: []const u8 = "<bootstrap>";

/// Read + analyse + evaluate the embedded `core.clj`. Caller supplies
/// an arena; the bootstrap allocates Forms / Nodes from it. Errors
/// propagate as `anyerror` (the analyzer / tree-walk error sets) and
/// have already been routed through `setErrorFmt` so the threadlocal
/// `Info` is populated for the renderer.
pub fn loadCore(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    macro_table: *const macro_dispatch.Table,
) !void {
    var reader = Reader.init(arena, CORE_SOURCE);
    while (true) {
        const form_opt = try reader.read();
        const form = form_opt orelse break;

        const node = try analyzeForm(arena, rt, env, null, form, macro_table);

        var locals: [tree_walk.MAX_LOCALS]Value = [_]Value{.nil_val} ** tree_walk.MAX_LOCALS;
        _ = try tree_walk.eval(rt, env, &locals, node);
    }
}

// --- tests ---

const testing = std.testing;
const primitive = @import("primitive.zig");
const macro_transforms = @import("macro_transforms.zig");

const Fixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,
    env: Env,
    arena: std.heap.ArenaAllocator,
    table: macro_dispatch.Table,

    fn init(self: *Fixture, alloc: std.mem.Allocator) !void {
        self.threaded = std.Io.Threaded.init(alloc, .{});
        self.rt = Runtime.init(self.threaded.io(), alloc);
        self.env = try Env.init(&self.rt);
        self.arena = std.heap.ArenaAllocator.init(alloc);
        self.table = macro_dispatch.Table.init(alloc);

        tree_walk.installVTable(&self.rt);
        try primitive.registerAll(&self.env);
        try macro_transforms.registerInto(&self.env, &self.table);
    }

    fn deinit(self: *Fixture) void {
        self.table.deinit();
        self.arena.deinit();
        self.env.deinit();
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "loadCore evaluates `(def not ...)` so 'not' resolves in user/" {
    var fix: Fixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try loadCore(fix.arena.allocator(), &fix.rt, &fix.env, &fix.table);

    const user = fix.env.findNs("user") orelse return error.TestUnexpectedResult;
    const not_var = user.resolve("not") orelse return error.TestUnexpectedResult;
    try testing.expect(!not_var.root.isNil());
}
