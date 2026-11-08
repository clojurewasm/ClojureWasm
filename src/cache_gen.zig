// SPDX-License-Identifier: EPL-2.0
//! Build-time tool (ADR-0056 Cycle 2): AOT-compile the eager bootstrap
//! (`clojure.core`) to a bytecode envelope and write it to the output
//! path passed as argv[1] (build.zig's `addOutputFileArg`). The main
//! `cljw` binary `@embedFile`s the result so a future startup can restore
//! core from bytecode (`driver.runEnvelope`) instead of re-parsing +
//! analyzing + evaluating core.clj on every process / Wasm instance.
//!
//! Runs the VM compiler over core.clj (via `builder.buildEnvelope`, which
//! compiles-then-evals each form), so the produced fns carry `bytecode`
//! and serialize cleanly — the `vmRecompileAll` equivalent, done once at
//! build time (ADR-0056 §Decision). The runtime default backend stays
//! tree_walk; AOT-restored fns dispatch on the VM via the Cycle-0
//! evalChunk wiring.

const std = @import("std");

const Runtime = @import("runtime/runtime.zig").Runtime;
const Env = @import("runtime/env.zig").Env;
const macro_dispatch = @import("eval/macro_dispatch.zig");
const driver = @import("eval/driver.zig");
const bootstrap = @import("lang/bootstrap.zig");
const serialize = @import("eval/bytecode/serialize.zig");
const builder = @import("app/builder.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var args = init.minimal.args.iterate();
    _ = args.skip(); // argv[0]
    const out_path = args.next() orelse return error.MissingOutputPath;
    const sources_out_path = args.next() orelse return error.MissingOutputPath;

    var rt = Runtime.init(io, gpa);
    defer rt.deinit();
    var env = try Env.init(&rt);
    defer env.deinit();
    driver.installVTable(&rt);
    var macro_table = macro_dispatch.Table.init(gpa);
    defer macro_table.deinit();
    // Prefix only (no loadCore): buildBootstrapEnvelope compiles+evals the WHOLE
    // eager bootstrap (core.clj + the 23 non-core bundled `.clj` libs) into this
    // fresh env as it produces the chunks; the chunks are the artifact (D-452
    // Part B — the non-core libs no longer re-parse from source every startup).
    try bootstrap.setupCorePrefix(&rt, &env, &macro_table);

    const payload = try builder.buildBootstrapEnvelope(gpa, &rt, &env, &macro_table, arena, bootstrap.ACTIVE_FILES);
    defer gpa.free(payload);

    const out = try std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    defer out.close(io);
    var wbuf: [4096]u8 = undefined;
    var ow = out.writer(io, &wbuf);
    try ow.interface.writeAll(payload);
    try ow.interface.flush();

    // C5'-b (ADR-0173): second artifact — the flate-compressed .clj sources
    // blob ([count u32] then per file: label len+bytes, uncompressed_len u32,
    // compressed len+bytes). cache_gen runs in raw mode, so entry.source is
    // always non-null here.
    const sources_blob = blk: {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeInt(u32, @intCast(bootstrap.ACTIVE_FILES.len), .little);
        for (bootstrap.ACTIVE_FILES) |file| {
            const src = file.source.?;
            const packed_bytes = try serialize.flateCompress(gpa, src);
            defer gpa.free(packed_bytes);
            try w.writeInt(u32, @intCast(file.label.len), .little);
            try w.writeAll(file.label);
            try w.writeInt(u32, @intCast(src.len), .little);
            try w.writeInt(u32, @intCast(packed_bytes.len), .little);
            try w.writeAll(packed_bytes);
        }
        break :blk try aw.toOwnedSlice();
    };
    defer gpa.free(sources_blob);
    const sout = try std.Io.Dir.cwd().createFile(io, sources_out_path, .{ .truncate = true });
    defer sout.close(io);
    var swbuf: [4096]u8 = undefined;
    var sow = sout.writer(io, &swbuf);
    try sow.interface.writeAll(sources_blob);
    try sow.interface.flush();
}
