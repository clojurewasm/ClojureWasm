//! Stage-1 bootstrap — read+analyse+evaluate the embedded Clojure
//! source files (currently `clj/clojure/core.clj` and
//! `clj/clojure/string.clj`) after `primitive.registerAll` populates
//! the kernel namespaces and `macro_transforms.registerInto` populates
//! the analyzer's macro Table.
//!
//! ### Multi-file loader (ADR-0032)
//!
//! `loadCore` iterates `FILES`, a flat table of `{label, source}`
//! pairs. The loader carries **no** namespace knowledge — each `.clj`
//! file declares its own namespace via a leading `(in-ns 'foo.bar)`
//! form (analyzer special form per ADR-0032). After the last file,
//! `current_ns` resets to `user/` so the REPL prompt lands there.
//!
//! ### Phase 3.12 → Phase 6.9 scope
//!
//! - `loadCore` accepts an arena (caller-owned), runs the loop, and
//!   propagates errors via the standard `runtime/error.zig` pipeline.
//!   Errors surface with the file's label so the renderer's
//!   `<file>:<line>:<col>: …` formatting points at the right source
//!   (ADR-0032 + D-058 caveat: the renderer's `SourceContext.text`
//!   slice still points at the first file's bytes until the renderer
//!   learns about multi-file context — a known cosmetic gap for
//!   non-first-file errors).

const std = @import("std");

const Reader = @import("../eval/reader.zig").Reader;
const analyzeForm = @import("../eval/analyzer/analyzer.zig").analyze;
const macro_dispatch = @import("../eval/macro_dispatch.zig");
const driver = @import("../eval/driver.zig");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const Value = @import("../runtime/value/value.zig").Value;

/// One entry in the bootstrap file table. `label` is the synthetic
/// source label the renderer attributes to errors raised while
/// evaluating this file (e.g. `<bootstrap>` for `core.clj`,
/// `<clojure.string>` for `string.clj`).
pub const FileEntry = struct {
    label: []const u8,
    source: []const u8,
};

/// Bootstrap source table — load order matters. `core.clj` must be
/// first because it lands `(def not ...)` and the future
/// `clojure.core` companions that subsequent files may reference.
/// Each non-first file is expected to open with `(in-ns 'foo.bar)`.
pub const FILES: []const FileEntry = &.{
    .{ .label = "<bootstrap>", .source = @embedFile("clj/clojure/core.clj") },
    .{ .label = "<clojure.string>", .source = @embedFile("clj/clojure/string.clj") },
    .{ .label = "<clojure.set>", .source = @embedFile("clj/clojure/set.clj") },
    .{ .label = "<clojure.walk>", .source = @embedFile("clj/clojure/walk.clj") },
};

/// First file's source — exposed so `main.zig`'s renderer can fall
/// back to it when a bootstrap-time error fires (per D-058 the
/// renderer does not yet thread per-file context; this kept the
/// renderer call sites unchanged from the single-file era).
pub const CORE_SOURCE: []const u8 = FILES[0].source;

/// First file's source label — same compatibility purpose as
/// `CORE_SOURCE`.
pub const SOURCE_LABEL: []const u8 = FILES[0].label;

/// Iterate `FILES`, read + analyse + evaluate each form, and reset
/// `current_ns` to `user/` at the end so REPL / file-eval callers
/// see their expected starting namespace. Caller-supplied arena
/// holds Forms / Nodes for the duration; the GC owns Values.
pub fn loadCore(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    macro_table: *const macro_dispatch.Table,
) !void {
    for (FILES) |file| {
        var reader = Reader.init(arena, file.source);
        while (true) {
            const form_opt = try reader.read();
            const form = form_opt orelse break;

            const node = try analyzeForm(arena, rt, env, null, form, macro_table);

            var locals: [driver.MAX_LOCALS]Value = [_]Value{.nil_val} ** driver.MAX_LOCALS;
            _ = try driver.evalForm(rt, env, &locals, arena, node);
        }
    }

    // PROVISIONAL: hardcoded end-of-loadCore refer table pending (ns ...) macro per-file :refer-clojure directive [refs: D-063, D-071, feature_deps.yaml#runtime/bootstrap/refer_table]
    if (env.findNs("clojure.core")) |clojure_core_ns| {
        for ([_][]const u8{ "user", "clojure.set", "clojure.string", "clojure.walk" }) |ns_name| {
            if (env.findNs(ns_name)) |target| {
                try env.referAll(clojure_core_ns, target);
            }
        }
    }

    if (env.findNs("user")) |user_ns| {
        env.current_ns = user_ns;
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

        driver.installVTable(&self.rt);
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

test "loadCore leaves current_ns at user/ after multi-file load" {
    var fix: Fixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try loadCore(fix.arena.allocator(), &fix.rt, &fix.env, &fix.table);

    try testing.expect(fix.env.current_ns != null);
    try testing.expectEqualStrings("user", fix.env.current_ns.?.name);
}

test "loadCore pulls in clojure.string namespace (ADR-0032 + Phase 6.9)" {
    var fix: Fixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try loadCore(fix.arena.allocator(), &fix.rt, &fix.env, &fix.table);

    const cs = fix.env.findNs("clojure.string") orelse return error.TestUnexpectedResult;
    try testing.expect(cs.resolve("upper-case") != null);
    try testing.expect(cs.resolve("lower-case") != null);
    try testing.expect(cs.resolve("blank?") != null);
}
