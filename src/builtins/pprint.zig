// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

// pprint builtins — pretty-printing for Clojure data structures.
//
// Simplified implementation of clojure.pprint/pprint.
// Formats nested data structures with indentation when they exceed
// the right margin (default 72 columns).

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const PersistentList = value_mod.PersistentList;
const PersistentVector = value_mod.PersistentVector;
const PersistentArrayMap = value_mod.PersistentArrayMap;
const PersistentHashMap = value_mod.PersistentHashMap;
const PersistentHashSet = value_mod.PersistentHashSet;
const var_mod = @import("../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const collections = @import("collections.zig");
const io = @import("io.zig");
const err = @import("../runtime/error.zig");
const Writer = std.Io.Writer;

const default_right_margin: usize = 72;

// ============================================================
// Pretty-print core
// ============================================================

/// Format a value as a single-line pr-str, returns the string.
/// Caller must have setPrintAllocator set before calling.
fn singleLine(allocator: Allocator, val: Value) ![]const u8 {
    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const v = collections.realizeValue(allocator, val) catch val;
    v.formatPrStr(&w) catch return "";
    const s = w.buffered();
    return try allocator.dupe(u8, s);
}

/// Recursively pretty-print `val` into writer `w`.
/// `col` tracks the current column position.
fn pprintImpl(allocator: Allocator, w: anytype, val: Value, col: *usize, margin: usize) !void {
    const v = collections.realizeValue(allocator, val) catch val;

    // Try single-line first
    const s = try singleLine(allocator, v);
    if (col.* + s.len <= margin) {
        try w.writeAll(s);
        col.* += s.len;
        return;
    }

    // Need multi-line formatting for collections
    switch (v.tag()) {
        .list => {
            try w.writeByte('(');
            col.* += 1;
            const new_indent = col.*;
            const list = v.asList();
            for (list.items, 0..) |item, i| {
                if (i > 0) {
                    try w.writeByte('\n');
                    try writeSpaces(w, new_indent);
                    col.* = new_indent;
                }
                try pprintImpl(allocator, w, item, col, margin);
            }
            try w.writeByte(')');
            col.* += 1;
        },
        .cons => {
            try w.writeByte('(');
            col.* += 1;
            const new_indent = col.*;
            var first = true;
            var cur = v;
            while (true) {
                if (cur.tag() == .cons) {
                    const cell = cur.asCons();
                    if (!first) {
                        try w.writeByte('\n');
                        try writeSpaces(w, new_indent);
                        col.* = new_indent;
                    }
                    try pprintImpl(allocator, w, cell.first, col, margin);
                    first = false;
                    cur = cell.rest;
                } else if (cur.tag() == .list) {
                    const list = cur.asList();
                    for (list.items) |item| {
                        if (!first) {
                            try w.writeByte('\n');
                            try writeSpaces(w, new_indent);
                            col.* = new_indent;
                        }
                        try pprintImpl(allocator, w, item, col, margin);
                        first = false;
                    }
                    break;
                } else if (cur == Value.nil_val) {
                    break;
                } else {
                    // dotted pair — shouldn't happen in Clojure
                    break;
                }
            }
            try w.writeByte(')');
            col.* += 1;
        },
        .vector => {
            try w.writeByte('[');
            col.* += 1;
            const new_indent = col.*;
            const vec = v.asVector();
            for (vec.items, 0..) |item, i| {
                if (i > 0) {
                    try w.writeByte('\n');
                    try writeSpaces(w, new_indent);
                    col.* = new_indent;
                }
                try pprintImpl(allocator, w, item, col, margin);
            }
            try w.writeByte(']');
            col.* += 1;
        },
        .map => {
            try w.writeByte('{');
            col.* += 1;
            const new_indent = col.*;
            const am = v.asMap();
            var i: usize = 0;
            while (i < am.entries.len) : (i += 2) {
                if (i > 0) {
                    try w.writeAll(",\n");
                    try writeSpaces(w, new_indent);
                    col.* = new_indent;
                }
                try pprintImpl(allocator, w, am.entries[i], col, margin);
                try w.writeByte(' ');
                col.* += 1;
                try pprintImpl(allocator, w, am.entries[i + 1], col, margin);
            }
            try w.writeByte('}');
            col.* += 1;
        },
        .hash_map => {
            try w.writeByte('{');
            col.* += 1;
            const new_indent = col.*;
            const entries = try v.asHashMap().toEntries(allocator);
            var i: usize = 0;
            while (i < entries.len) : (i += 2) {
                if (i > 0) {
                    try w.writeAll(",\n");
                    try writeSpaces(w, new_indent);
                    col.* = new_indent;
                }
                try pprintImpl(allocator, w, entries[i], col, margin);
                try w.writeByte(' ');
                col.* += 1;
                try pprintImpl(allocator, w, entries[i + 1], col, margin);
            }
            try w.writeByte('}');
            col.* += 1;
        },
        .set => {
            try w.writeAll("#{");
            col.* += 2;
            const new_indent = col.*;
            const set = v.asSet();
            for (set.items, 0..) |item, i| {
                if (i > 0) {
                    try w.writeByte('\n');
                    try writeSpaces(w, new_indent);
                    col.* = new_indent;
                }
                try pprintImpl(allocator, w, item, col, margin);
            }
            try w.writeByte('}');
            col.* += 1;
        },
        else => {
            // Atom or unsupported type — just output single-line
            try w.writeAll(s);
            col.* += s.len;
        },
    }
}

fn writeSpaces(w: anytype, n: usize) !void {
    for (0..n) |_| try w.writeByte(' ');
}

// ============================================================
// Builtin functions
// ============================================================

/// (pprint object) => nil  — pretty-print object to stdout
pub fn pprintFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to pprint", .{args.len});

    value_mod.setPrintAllocator(allocator);
    defer value_mod.setPrintAllocator(null);

    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();

    var col: usize = 0;
    try pprintImpl(allocator, &aw.writer, args[0], &col, default_right_margin);

    io.writeOutput(aw.writer.buffered());
    io.writeOutputByte('\n');
    return Value.nil_val;
}

// ============================================================
// BuiltinDef table
// ============================================================

pub const builtins = [_]BuiltinDef{
    .{ .name = "pprint", .func = pprintFn, .doc = "Pretty-prints the object to the output stream that is the current value of *out*.", .arglists = "([object])", .added = "1.0" },
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "pprint - simple value" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    io.setOutputCapture(alloc, &buf);
    defer io.setOutputCapture(null, null);

    _ = try pprintFn(alloc, &[_]Value{Value.initInteger(42)});
    try testing.expectEqualStrings("42\n", buf.items);
}

test "pprint - short vector on one line" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    io.setOutputCapture(alloc, &buf);
    defer io.setOutputCapture(null, null);

    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2), Value.initInteger(3) };
    const vec = PersistentVector{ .items = &items };
    _ = try pprintFn(alloc, &[_]Value{Value.initVector(&vec)});
    try testing.expectEqualStrings("[1 2 3]\n", buf.items);
}

test "pprint - short map on one line" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    io.setOutputCapture(alloc, &buf);
    defer io.setOutputCapture(null, null);

    const entries = [_]Value{
        Value.initKeyword(alloc, .{ .name = "a", .ns = null }),
        Value.initInteger(1),
    };
    const am = PersistentArrayMap{ .entries = &entries };
    _ = try pprintFn(alloc, &[_]Value{Value.initMap(&am)});
    try testing.expectEqualStrings("{:a 1}\n", buf.items);
}

