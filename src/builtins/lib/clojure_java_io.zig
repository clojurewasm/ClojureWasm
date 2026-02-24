// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.java.io — Protocol-based I/O functions.
//! Replaces clojure/java/io.clj (supplements existing io.zig Zig builtins).
//! Merges io.zig::java_io_builtins + protocol-based builtins.
//! UPSTREAM-DIFF: Protocol dispatch uses cond on predicates (CW has no Java type hierarchy).
//! UPSTREAM-DIFF: reader slurps file into PushbackReader (in-memory, not streaming).
//! UPSTREAM-DIFF: input-stream/output-stream delegate to reader/writer (character-based).

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../../runtime/value.zig");
const Value = value_mod.Value;
const var_mod = @import("../../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const err = @import("../../runtime/error.zig");
const bootstrap = @import("../../runtime/bootstrap.zig");
const dispatch = @import("../../runtime/dispatch.zig");
const clojure_core_protocols = @import("clojure_core_protocols.zig");
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const io_mod = @import("../io.zig");
const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;

// ============================================================
// Helpers
// ============================================================

fn callCore(allocator: Allocator, name: []const u8, args: []const Value) !Value {
    const env = dispatch.macro_eval_env orelse return error.EvalError;
    const core_ns = env.findNamespace("clojure.core") orelse return error.EvalError;
    const v = core_ns.mappings.get(name) orelse return error.EvalError;
    return bootstrap.callFnVal(allocator, v.deref(), args);
}

fn resolveCoreFn(name: []const u8) !Value {
    const env = dispatch.macro_eval_env orelse return error.EvalError;
    const core_ns = env.findNamespace("clojure.core") orelse return error.EvalError;
    const v = core_ns.mappings.get(name) orelse return error.EvalError;
    return v.deref();
}

/// Check if value is a map with :__reify_type matching class_name
fn isReifyType(allocator: Allocator, v: Value, class_name: []const u8) bool {
    const tag = v.tag();
    if (tag != .hash_map and tag != .map) return false;
    const rt_key = Value.initKeyword(allocator, .{ .ns = null, .name = "__reify_type" });
    const rt_val = callCore(allocator, "get", &.{ v, rt_key }) catch return false;
    if (rt_val.tag() != .string) return false;
    return std.mem.eql(u8, rt_val.asString(), class_name);
}

/// Resolve a path from various input types (string, File map, URI map)
fn resolvePath(allocator: Allocator, x: Value) ![]const u8 {
    if (x.tag() == .string) return x.asString();
    if (isReifyType(allocator, x, "java.io.File")) {
        const path = try callCore(allocator, ".getPath", &.{x});
        return path.asString();
    }
    if (isReifyType(allocator, x, "java.net.URI")) {
        const scheme = try callCore(allocator, ".getScheme", &.{x});
        if (scheme.tag() == .nil or (scheme.tag() == .string and std.mem.eql(u8, scheme.asString(), "file"))) {
            const path = try callCore(allocator, ".getPath", &.{x});
            return path.asString();
        }
        return err.setErrorFmt(.eval, .value_error, .{}, "Cannot resolve non-file URI to path", .{});
    }
    // Fallback: str
    const s = try callCore(allocator, "str", &.{x});
    return s.asString();
}

// ============================================================
// Coercions protocol methods
// ============================================================

/// (as-file x) — enhanced version handling File/URI maps
fn asFileFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to as-file", .{args.len});
    const x = args[0];
    if (x.tag() == .nil) return Value.nil_val;
    if (x.tag() == .string) return callCore(allocator, "__interop-new", &.{ Value.initString(allocator, try allocator.dupe(u8, "java.io.File")), x });
    if (isReifyType(allocator, x, "java.io.File")) return x;
    if (isReifyType(allocator, x, "java.net.URI")) {
        const url = try asUrlFn(allocator, &.{x});
        return asFileFn(allocator, &.{url});
    }
    return err.setErrorFmt(.eval, .value_error, .{}, "Cannot coerce to file", .{});
}

/// (as-url x) — coerce to URI
fn asUrlFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to as-url", .{args.len});
    const x = args[0];
    if (x.tag() == .nil) return Value.nil_val;
    if (x.tag() == .string) return callCore(allocator, "__interop-new", &.{ Value.initString(allocator, try allocator.dupe(u8, "java.net.URI")), x });
    if (isReifyType(allocator, x, "java.net.URI")) return x;
    if (isReifyType(allocator, x, "java.io.File")) {
        const path = try callCore(allocator, ".getPath", &.{x});
        const uri_str = try callCore(allocator, "str", &.{ Value.initString(allocator, try allocator.dupe(u8, "file:")), path });
        return callCore(allocator, "__interop-new", &.{ Value.initString(allocator, try allocator.dupe(u8, "java.net.URI")), uri_str });
    }
    return err.setErrorFmt(.eval, .value_error, .{}, "Cannot coerce to URL", .{});
}

// ============================================================
// IOFactory protocol methods
// ============================================================

/// (make-reader x opts)
fn makeReaderFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to make-reader", .{args.len});
    const x = args[0];
    const opts = args[1];
    if (x.tag() == .nil) return err.setErrorFmt(.eval, .value_error, .{}, "Cannot open <nil> as a Reader.", .{});
    // PushbackReader — already a reader
    if (isReifyType(allocator, x, "java.io.PushbackReader")) return x;
    // StringReader — wrap in PushbackReader
    if (isReifyType(allocator, x, "java.io.StringReader")) {
        return callCore(allocator, "__interop-new", &.{ Value.initString(allocator, try allocator.dupe(u8, "java.io.PushbackReader")), x });
    }
    // String — try as file path
    if (x.tag() == .string) {
        const content = try callCore(allocator, "slurp", &.{x});
        return callCore(allocator, "__interop-new", &.{ Value.initString(allocator, try allocator.dupe(u8, "java.io.PushbackReader")), content });
    }
    // File — read and wrap
    if (isReifyType(allocator, x, "java.io.File")) {
        const path = try callCore(allocator, ".getPath", &.{x});
        const content = try callCore(allocator, "slurp", &.{path});
        return callCore(allocator, "__interop-new", &.{ Value.initString(allocator, try allocator.dupe(u8, "java.io.PushbackReader")), content });
    }
    // URI — read from path
    if (isReifyType(allocator, x, "java.net.URI")) {
        const path_str = try resolvePath(allocator, x);
        return makeReaderFn(allocator, &.{ Value.initString(allocator, try allocator.dupe(u8, path_str)), opts });
    }
    return err.setErrorFmt(.eval, .value_error, .{}, "Cannot open as a Reader.", .{});
}

/// (make-writer x opts)
fn makeWriterFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to make-writer", .{args.len});
    const x = args[0];
    const opts = args[1];
    if (x.tag() == .nil) return err.setErrorFmt(.eval, .value_error, .{}, "Cannot open <nil> as a Writer.", .{});
    // StringWriter or BufferedWriter — already a writer
    if (isReifyType(allocator, x, "java.io.StringWriter")) return x;
    if (isReifyType(allocator, x, "java.io.BufferedWriter")) return x;
    // String — open file for writing
    if (x.tag() == .string) {
        const append_val = if (opts.tag() != .nil) try callCore(allocator, "get", &.{ opts, Value.initKeyword(allocator, .{ .ns = null, .name = "append" }) }) else Value.false_val;
        return callCore(allocator, "__interop-new", &.{ Value.initString(allocator, try allocator.dupe(u8, "java.io.BufferedWriter")), x, append_val });
    }
    // File — write to path
    if (isReifyType(allocator, x, "java.io.File")) {
        const path = try callCore(allocator, ".getPath", &.{x});
        return makeWriterFn(allocator, &.{ path, opts });
    }
    // URI — write to path
    if (isReifyType(allocator, x, "java.net.URI")) {
        const path_str = try resolvePath(allocator, x);
        return makeWriterFn(allocator, &.{ Value.initString(allocator, try allocator.dupe(u8, path_str)), opts });
    }
    return err.setErrorFmt(.eval, .value_error, .{}, "Cannot open as a Writer.", .{});
}

/// (make-input-stream x opts) — delegates to make-reader (CW has no separate byte streams)
fn makeInputStreamFn(allocator: Allocator, args: []const Value) anyerror!Value {
    return makeReaderFn(allocator, args);
}

/// (make-output-stream x opts) — delegates to make-writer (CW has no separate byte streams)
fn makeOutputStreamFn(allocator: Allocator, args: []const Value) anyerror!Value {
    return makeWriterFn(allocator, args);
}

// ============================================================
// Public API
// ============================================================

/// (reader x & opts) — coerce x to a reader
fn readerFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to reader", .{args.len});
    const x = args[0];
    const opts = if (args.len > 1) blk: {
        const hash_map_fn = try resolveCoreFn("hash-map");
        break :blk try bootstrap.callFnVal(allocator, hash_map_fn, args[1..]);
    } else Value.nil_val;
    return makeReaderFn(allocator, &.{ x, opts });
}

/// (writer x & opts) — coerce x to a writer
fn writerFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to writer", .{args.len});
    const x = args[0];
    const opts = if (args.len > 1) blk: {
        const hash_map_fn = try resolveCoreFn("hash-map");
        break :blk try bootstrap.callFnVal(allocator, hash_map_fn, args[1..]);
    } else Value.nil_val;
    return makeWriterFn(allocator, &.{ x, opts });
}

/// (input-stream x & opts) — coerce x to an input stream
fn inputStreamFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to input-stream", .{args.len});
    const x = args[0];
    const opts = if (args.len > 1) blk: {
        const hash_map_fn = try resolveCoreFn("hash-map");
        break :blk try bootstrap.callFnVal(allocator, hash_map_fn, args[1..]);
    } else Value.nil_val;
    return makeInputStreamFn(allocator, &.{ x, opts });
}

/// (output-stream x & opts) — coerce x to an output stream
fn outputStreamFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to output-stream", .{args.len});
    const x = args[0];
    const opts = if (args.len > 1) blk: {
        const hash_map_fn = try resolveCoreFn("hash-map");
        break :blk try bootstrap.callFnVal(allocator, hash_map_fn, args[1..]);
    } else Value.nil_val;
    return makeOutputStreamFn(allocator, &.{ x, opts });
}

// ============================================================
// Protocol registration
// ============================================================

fn registerProtocols(allocator: Allocator, env: *Env) anyerror!void {
    const io_ns = try env.findOrCreateNamespace("clojure.java.io");
    // Coercions protocol
    _ = try clojure_core_protocols.createProtocol(allocator, io_ns, "Coercions", &.{
        .{ .name = "as-file", .arity = 1 },
        .{ .name = "as-url", .arity = 1 },
    }, false);
    // IOFactory protocol
    _ = try clojure_core_protocols.createProtocol(allocator, io_ns, "IOFactory", &.{
        .{ .name = "make-reader", .arity = 2 },
        .{ .name = "make-writer", .arity = 2 },
        .{ .name = "make-input-stream", .arity = 2 },
        .{ .name = "make-output-stream", .arity = 2 },
    }, false);

    // Bind default-streams-impl var
    const v = try io_ns.intern("default-streams-impl");
    const impl_map = try makeDefaultStreamsImpl(allocator);
    v.bindRoot(impl_map);
}

// ============================================================
// default-streams-impl builder
// ============================================================

fn makeDefaultStreamsImpl(allocator: Allocator) !Value {
    // Build a PersistentArrayMap directly (no callCore at registration time)
    const runtime_collections = @import("../../runtime/collections.zig");
    const entries = try allocator.alloc(Value, 8);
    entries[0] = Value.initKeyword(allocator, .{ .ns = null, .name = "make-reader" });
    entries[1] = Value.initBuiltinFn(&defaultMakeReaderFn);
    entries[2] = Value.initKeyword(allocator, .{ .ns = null, .name = "make-writer" });
    entries[3] = Value.initBuiltinFn(&defaultMakeWriterFn);
    entries[4] = Value.initKeyword(allocator, .{ .ns = null, .name = "make-input-stream" });
    entries[5] = Value.initBuiltinFn(&defaultMakeInputStreamFn);
    entries[6] = Value.initKeyword(allocator, .{ .ns = null, .name = "make-output-stream" });
    entries[7] = Value.initBuiltinFn(&defaultMakeOutputStreamFn);
    const map = try allocator.create(runtime_collections.PersistentArrayMap);
    map.* = .{ .entries = entries };
    return Value.initMap(map);
}

fn defaultMakeReaderFn(allocator: Allocator, args: []const Value) anyerror!Value {
    return makeReaderFn(allocator, args);
}

fn defaultMakeWriterFn(allocator: Allocator, args: []const Value) anyerror!Value {
    return makeWriterFn(allocator, args);
}

fn defaultMakeInputStreamFn(_: Allocator, _: []const Value) anyerror!Value {
    return err.setErrorFmt(.eval, .value_error, .{}, "Cannot open as an InputStream.", .{});
}

fn defaultMakeOutputStreamFn(_: Allocator, _: []const Value) anyerror!Value {
    return err.setErrorFmt(.eval, .value_error, .{}, "Cannot open as an OutputStream.", .{});
}

// ============================================================
// Namespace definition
// ============================================================

const protocol_builtins = [_]BuiltinDef{
    .{ .name = "as-file", .func = &asFileFn, .doc = "Coerce argument to a file." },
    .{ .name = "as-url", .func = &asUrlFn, .doc = "Coerce argument to a URL." },
    .{ .name = "make-reader", .func = &makeReaderFn, .doc = "Creates a BufferedReader. See also IOFactory docs." },
    .{ .name = "make-writer", .func = &makeWriterFn, .doc = "Creates a BufferedWriter. See also IOFactory docs." },
    .{ .name = "make-input-stream", .func = &makeInputStreamFn, .doc = "Creates a BufferedInputStream. See also IOFactory docs." },
    .{ .name = "make-output-stream", .func = &makeOutputStreamFn, .doc = "Creates a BufferedOutputStream. See also IOFactory docs." },
    .{ .name = "reader", .func = &readerFn, .doc = "Attempts to coerce its argument into an open java.io.Reader." },
    .{ .name = "writer", .func = &writerFn, .doc = "Attempts to coerce its argument into an open java.io.Writer." },
    .{ .name = "input-stream", .func = &inputStreamFn, .doc = "Attempts to coerce its argument into an open java.io.InputStream." },
    .{ .name = "output-stream", .func = &outputStreamFn, .doc = "Attempts to coerce its argument into an open java.io.OutputStream." },
};

pub const namespace_def = NamespaceDef{
    .name = "clojure.java.io",
    // io.zig base builtins first, then protocol-based builtins override (e.g. as-file)
    .builtins = &(io_mod.java_io_builtins ++ protocol_builtins),
    .post_register = &registerProtocols,
};
