// SPDX-License-Identifier: EPL-2.0
//! Shared REPL evaluation engine (ADR-0170): the per-form
//! read → analyze → eval loop with `*1`/`*2`/`*3`/`*e` history
//! rotation, optional `*out*`/`*err*` capture, stop-on-first-error,
//! and CLI-grade error rendering — driven through caller-supplied
//! sinks. Consumers: the nREPL `eval`/`load-file` ops (bencode
//! sinks) and the CLI REPL (terminal sinks). One engine, so the two
//! REPLs cannot drift (F-011): `(inc *1)` works identically in
//! CIDER and `cljw repl`, and both render the same caret error text.
//!
//! ns handling is deliberately NOT here: the CLI REPL wants `in-ns`
//! to persist globally, the nREPL op wants per-session save/restore —
//! each caller manages `env.current_ns` around this call.

const std = @import("std");
const Writer = std.Io.Writer;

const Runtime = @import("../runtime/runtime.zig").Runtime;
const Env = @import("../runtime/env.zig").Env;
const env_mod = @import("../runtime/env.zig");
const Value = @import("../runtime/value/value.zig").Value;
const GcHeap = @import("../runtime/gc/gc_heap.zig").GcHeap;
const Reader = @import("../eval/reader.zig").Reader;
const analyzeForm = @import("../eval/analyzer/analyzer.zig").analyze;
const macro_dispatch = @import("../eval/macro_dispatch.zig");
const driver = @import("../eval/driver.zig");
const root_set = @import("../runtime/gc/root_set.zig");
const print = @import("../runtime/print.zig");
const text_io = @import("../runtime/io/text_io.zig");
const dispatch = @import("../runtime/dispatch.zig");
const error_render = @import("error_render.zig");

/// REPL history state (`*1` `*2` `*3` `*e`) with the GC pin
/// discipline built in.
///
/// GC-ROOT: held star Values are `GcHeap.pin`ned (permanent_roots)
/// while stored and unpinned on overwrite / release — between evals
/// nothing else references a REPL result, so an unpinned `*1` would
/// be swept and the next deref would touch freed memory. See
/// `.dev/gc_rooting.md` § REPL star history.
pub const StarState = struct {
    gc: *GcHeap,
    values: [4]Value = @splat(.nil_val),

    pub const idx_1 = 0;
    pub const idx_2 = 1;
    pub const idx_3 = 2;
    pub const idx_e = 3;

    pub fn init(gc: *GcHeap) StarState {
        return .{ .gc = gc };
    }

    /// Roll the history chain with a fresh eval result: `*3` drops
    /// (unpin), `*2`→`*3`, `*1`→`*2`, `v`→`*1` (pin).
    pub fn rotate(self: *StarState, v: Value) !void {
        try self.gc.pin(v);
        _ = self.gc.unpin(self.values[idx_3]);
        self.values[idx_3] = self.values[idx_2];
        self.values[idx_2] = self.values[idx_1];
        self.values[idx_1] = v;
    }

    /// Set `*e` (most recent caught exception value).
    pub fn setE(self: *StarState, v: Value) !void {
        try self.gc.pin(v);
        _ = self.gc.unpin(self.values[idx_e]);
        self.values[idx_e] = v;
    }

    /// Unpin everything (owner teardown).
    pub fn release(self: *StarState) void {
        for (self.values) |v| _ = self.gc.unpin(v);
        self.values = @splat(.nil_val);
    }
};

pub const Options = struct {
    source: []const u8,
    /// Error-rendering label: `<repl:N>`, `<nrepl>`, or a file name.
    source_label: []const u8,
    /// History state to bind + rotate, or null to skip `*1`..`*e`.
    stars: ?*StarState = null,
    /// Bind `*out*`/`*err*` to capture writers and emit the captured
    /// text through the sink per top-level form (nREPL). False = let
    /// prints flow to the process stdio (CLI REPL).
    capture_output: bool = false,
    /// true → emit a value per top-level form (REPL eval);
    /// false → emit only the LAST form's value (clj load-file).
    emit_each_value: bool = true,
};

/// Evaluate `opts.source` form by form. The sink is duck-typed:
///   onValue(text)                        — a form's printed result
///   onOut(text) / onErrOut(text)         — captured *out* / *err*
///   onError(rendered, err_name, thrown)  — rich rendered error text +
///                                          the Zig error name + the
///                                          thrown Value when present
/// Returns true when every form evaluated; false when it stopped on
/// the first error (JVM parity — later forms never run).
pub fn evalSource(
    rt: *Runtime,
    env: *Env,
    macro_table: *const macro_dispatch.Table,
    arena: std.mem.Allocator,
    scratch: std.mem.Allocator,
    opts: Options,
    sink: anytype,
) !bool {
    const core_ns = env.findNs("clojure.core");

    // One frame for the whole call: star bindings (so `(inc *1)`
    // resolves) + the capture writers. Values roll per form via
    // setBinding on this same frame.
    var frame: env_mod.BindingFrame = .{};
    var v1: ?*env_mod.Var = null;
    var v2: ?*env_mod.Var = null;
    var v3: ?*env_mod.Var = null;
    var ve: ?*env_mod.Var = null;
    var out_var: ?*env_mod.Var = null;
    var err_var: ?*env_mod.Var = null;
    if (core_ns) |core| {
        if (opts.stars) |stars| {
            v1 = core.resolve("*1");
            v2 = core.resolve("*2");
            v3 = core.resolve("*3");
            ve = core.resolve("*e");
            if (v1) |v| try frame.bindings.put(scratch, v, stars.values[StarState.idx_1]);
            if (v2) |v| try frame.bindings.put(scratch, v, stars.values[StarState.idx_2]);
            if (v3) |v| try frame.bindings.put(scratch, v, stars.values[StarState.idx_3]);
            if (ve) |v| try frame.bindings.put(scratch, v, stars.values[StarState.idx_e]);
        }
        if (opts.capture_output) {
            out_var = core.resolve("*out*");
            err_var = core.resolve("*err*");
            if (out_var) |v| try frame.bindings.put(scratch, v, try text_io.mintStringWriter(rt));
            if (err_var) |v| try frame.bindings.put(scratch, v, try text_io.mintStringWriter(rt));
        }
    }
    env_mod.pushFrame(&frame);
    defer env_mod.popFrame();

    var reader = Reader.init(arena, opts.source);
    var last_value: ?[]const u8 = null;
    var ok = true;

    while (true) {
        const form_opt = reader.read() catch |err| {
            try flushCaptured(out_var, err_var, sink);
            try renderAndEmit(scratch, opts, err, sink);
            ok = false;
            break;
        };
        const form = form_opt orelse break;

        // D-430: per-form analysis bracket (roots literals through eval).
        var af: root_set.AnalysisFrame = undefined;
        root_set.beginAnalysis(&af, rt.gc.infra);
        defer root_set.endAnalysisPersist(&af, &rt.gc);

        const node = analyzeForm(arena, rt, env, null, form, macro_table) catch |err| {
            try flushCaptured(out_var, err_var, sink);
            try handleEvalError(opts, ve, err, scratch, sink);
            ok = false;
            break;
        };
        var locals: [driver.MAX_LOCALS]Value = [_]Value{.nil_val} ** driver.MAX_LOCALS;
        const result = driver.evalForm(rt, env, &locals, arena, node) catch |err| {
            try flushCaptured(out_var, err_var, sink);
            try handleEvalError(opts, ve, err, scratch, sink);
            ok = false;
            break;
        };
        try flushCaptured(out_var, err_var, sink);
        try rearmCapture(rt, out_var, err_var);

        // Rotate history + refresh the live frame so the NEXT form's
        // `*1` sees this result.
        if (opts.stars) |stars| {
            try stars.rotate(result);
            if (v1) |v| _ = env_mod.setBinding(v, stars.values[StarState.idx_1]);
            if (v2) |v| _ = env_mod.setBinding(v, stars.values[StarState.idx_2]);
            if (v3) |v| _ = env_mod.setBinding(v, stars.values[StarState.idx_3]);
        }

        var aw: Writer.Allocating = .init(scratch);
        try print.printResult(rt, env, &aw.writer, result);
        const value_str = aw.written();
        if (opts.emit_each_value) {
            try sink.onValue(value_str);
        } else {
            last_value = value_str;
        }
    }
    if (ok and !opts.emit_each_value) {
        if (last_value) |lv| try sink.onValue(lv);
    }
    return ok;
}

/// Emit any captured `*out*` / `*err*` text, then re-arm both capture
/// writers for the next form (a fresh string writer per flush keeps
/// each `out` response scoped to its form).
fn flushCaptured(out_var: ?*env_mod.Var, err_var: ?*env_mod.Var, sink: anytype) !void {
    if (out_var) |v| {
        if (env_mod.findBinding(v)) |w| {
            const captured = text_io.writerBytes(w);
            if (captured.len > 0) try sink.onOut(captured);
        }
    }
    if (err_var) |v| {
        if (env_mod.findBinding(v)) |w| {
            const captured = text_io.writerBytes(w);
            if (captured.len > 0) try sink.onErrOut(captured);
        }
    }
}

/// Re-arm the capture writers after a flush. Split from
/// `flushCaptured` because re-minting needs `rt`, which the reader-
/// error path doesn't have on its unwind.
fn rearmCapture(rt: *Runtime, out_var: ?*env_mod.Var, err_var: ?*env_mod.Var) !void {
    if (out_var) |v| _ = env_mod.setBinding(v, try text_io.mintStringWriter(rt));
    if (err_var) |v| _ = env_mod.setBinding(v, try text_io.mintStringWriter(rt));
}

fn handleEvalError(
    opts: Options,
    ve: ?*env_mod.Var,
    err: anyerror,
    scratch: std.mem.Allocator,
    sink: anytype,
) !void {
    // Peek the thrown Value BEFORE rendering — renderError consumes the
    // threadlocal throw state.
    const thrown = dispatch.last_thrown_exception;
    if (thrown) |t| {
        if (opts.stars) |stars| {
            try stars.setE(t);
            if (ve) |v| _ = env_mod.setBinding(v, t);
        }
    }
    try renderAndEmitThrown(scratch, opts, err, thrown, sink);
}

fn renderAndEmit(scratch: std.mem.Allocator, opts: Options, err: anyerror, sink: anytype) !void {
    try renderAndEmitThrown(scratch, opts, err, null, sink);
}

fn renderAndEmitThrown(scratch: std.mem.Allocator, opts: Options, err: anyerror, thrown: ?Value, sink: anytype) !void {
    var aw: Writer.Allocating = .init(scratch);
    error_render.renderError(&aw.writer, .{ .file = opts.source_label, .text = opts.source }, err) catch {};
    try sink.onError(aw.written(), @errorName(err), thrown);
}

// eval_session has no direct unit tests: its contract is pinned by the
// nREPL e2e (phase14_nrepl.sh case 4) + the REPL e2e, and StarState's
// pin discipline is unit-tested from session.zig's registry tests.
// The `test` block below keeps the module in the discovery graph.
test {
    std.testing.refAllDecls(StarState);
}
