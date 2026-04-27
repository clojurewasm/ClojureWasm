//! Value renderer (`pr-str` style).
//!
//! Phase-3.8 extracts the printer from `src/main.zig` so that the REPL,
//! nREPL, the future `pr-str` / `prn` primitives, and (Phase 8+)
//! `--compare`'s diff renderer all converge on a single implementation.
//!
//! Layer-0 module: imports only `runtime/value.zig`, `runtime/keyword.zig`,
//! and the heap collection wrappers under `runtime/collection/`. No
//! analyzer / backend / `lang/` knowledge — the printer is data-driven
//! off `Value.tag()`.
//!
//! ### Surface
//!
//! - `printValue(w, v)` — top-level dispatch. Renders nil / bool / int /
//!   float / char / keyword / builtin_fn directly, delegates to
//!   `printString` / `printList` for heap collections, and falls back to
//!   `#<tag>` for any heap kind whose dedicated branch hasn't shipped
//!   yet (vector, map, fn_val, transient_*, ...).
//! - `printString(w, s)` — `pr-str` form: surrounding `"`, with
//!   `\n` / `\t` / `\r` / `\\` / `\"` escapes mirroring the Reader's
//!   `unescapeString` table (§9.4 / 1.9). Round-trip stable for ASCII.
//! - `printList(w, v)` — `(a b c)` form, walks Cons cells via
//!   `list_collection.first` / `rest` / `countOf`. The list/printer
//!   recursion goes through `printValue` so nested Lists / Strings work.
//!
//! ### Why a Layer-0 module
//!
//! Pretty-printing is a runtime concern (the same renderer is used at
//! REPL prompt, in error messages once strings + collections show up,
//! and from the planned `pr-str` builtin). Putting it in Layer 0 lets
//! `lang/primitive/io.zig` (future) call it without crossing the zone
//! contract.

const std = @import("std");
const Writer = std.Io.Writer;

const value_mod = @import("value.zig");
const Value = value_mod.Value;
const keyword = @import("keyword.zig");
const string_collection = @import("collection/string.zig");
const list_collection = @import("collection/list.zig");

/// Render `v` to `w` in `pr-str` style. Phase-3 surface covers nil /
/// boolean / integer / float / char / keyword / builtin_fn / string /
/// list. Other heap kinds render as `#<tag>` placeholders so the user
/// always sees *something* instead of an undecipherable address —
/// Phase 3.10+ adds dedicated branches as the heap types ship.
pub fn printValue(w: *Writer, v: Value) Writer.Error!void {
    switch (v.tag()) {
        .nil => try w.writeAll("nil"),
        .boolean => try w.writeAll(if (v.asBoolean()) "true" else "false"),
        .integer => try w.print("{d}", .{v.asInteger()}),
        .float => {
            const f = v.asFloat();
            if (std.math.isNan(f)) try w.writeAll("##NaN") //
            else if (std.math.isPositiveInf(f)) try w.writeAll("##Inf") //
            else if (std.math.isNegativeInf(f)) try w.writeAll("##-Inf") //
            else try w.print("{d}", .{f});
        },
        .char => try w.print("\\u{x:0>4}", .{v.asChar()}),
        .builtin_fn => try w.writeAll("#builtin"),
        .keyword => {
            const k = keyword.asKeyword(v);
            try w.writeByte(':');
            if (k.ns) |n| {
                try w.writeAll(n);
                try w.writeByte('/');
            }
            try w.writeAll(k.name);
        },
        .string => try printString(w, string_collection.asString(v)),
        .list => try printList(w, v),
        else => |t| try w.print("#<{s}>", .{@tagName(t)}),
    }
}

/// Render a heap List in `(a b c)` form. Empty list (a List Value
/// whose count is 0) prints as `()`. Walks via `list_collection`'s
/// `first` / `rest` so this stays decoupled from the Cons internals.
pub fn printList(w: *Writer, v: Value) Writer.Error!void {
    try w.writeByte('(');
    var cur = v;
    var first_iter = true;
    while (cur.tag() == .list and list_collection.countOf(cur) > 0) {
        if (!first_iter) try w.writeByte(' ');
        first_iter = false;
        try printValue(w, list_collection.first(cur));
        cur = list_collection.rest(cur);
    }
    try w.writeByte(')');
}

/// Render `s` in Clojure `pr-str` style: surrounding double quotes,
/// with `\n` / `\t` / `\r` / `\\` / `\"` escape sequences. Other
/// bytes are passed through as-is — `(read-string (pr-str s))` round-
/// trips for ASCII-clean inputs (matches the Reader's `unescapeString`
/// table at §9.4 / 1.9).
pub fn printString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

// --- tests ---

const testing = std.testing;
const Runtime = @import("runtime.zig").Runtime;

fn renderToBuf(buf: []u8, v: Value) ![]const u8 {
    var w: Writer = .fixed(buf);
    try printValue(&w, v);
    return w.buffered();
}

test "atoms: nil / boolean / integer / float" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("nil", try renderToBuf(&buf, .nil_val));
    try testing.expectEqualStrings("true", try renderToBuf(&buf, .true_val));
    try testing.expectEqualStrings("false", try renderToBuf(&buf, .false_val));
    try testing.expectEqualStrings("42", try renderToBuf(&buf, Value.initInteger(42)));
    try testing.expectEqualStrings("-7", try renderToBuf(&buf, Value.initInteger(-7)));
    try testing.expectEqualStrings("##NaN", try renderToBuf(&buf, Value.initFloat(std.math.nan(f64))));
    try testing.expectEqualStrings("##Inf", try renderToBuf(&buf, Value.initFloat(std.math.inf(f64))));
    try testing.expectEqualStrings("##-Inf", try renderToBuf(&buf, Value.initFloat(-std.math.inf(f64))));
}

test "keyword: with and without namespace" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const k1 = try keyword.intern(&rt, null, "foo");
    const k2 = try keyword.intern(&rt, "ns", "bar");

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(":foo", try renderToBuf(&buf, k1));
    try testing.expectEqualStrings(":ns/bar", try renderToBuf(&buf, k2));
}

test "string: pr-str escapes" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    var buf: [128]u8 = undefined;

    const plain = try string_collection.alloc(&rt, "hi");
    try testing.expectEqualStrings("\"hi\"", try renderToBuf(&buf, plain));

    const newline = try string_collection.alloc(&rt, "a\nb");
    try testing.expectEqualStrings("\"a\\nb\"", try renderToBuf(&buf, newline));

    const escaped = try string_collection.alloc(&rt, "q\"back\\");
    try testing.expectEqualStrings("\"q\\\"back\\\\\"", try renderToBuf(&buf, escaped));
}

test "list: empty and nested" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    var buf: [64]u8 = undefined;

    // Build (1 2 3)
    const inner_tail = try list_collection.consHeap(&rt, Value.initInteger(3), .nil_val);
    const inner_mid = try list_collection.consHeap(&rt, Value.initInteger(2), inner_tail);
    const flat = try list_collection.consHeap(&rt, Value.initInteger(1), inner_mid);
    try testing.expectEqualStrings("(1 2 3)", try renderToBuf(&buf, flat));

    // Build (1 (2 3))
    const inner = try list_collection.consHeap(&rt, Value.initInteger(2),
        try list_collection.consHeap(&rt, Value.initInteger(3), .nil_val));
    const nested = try list_collection.consHeap(&rt, Value.initInteger(1),
        try list_collection.consHeap(&rt, inner, .nil_val));
    try testing.expectEqualStrings("(1 (2 3))", try renderToBuf(&buf, nested));
}

test "unhandled heap tag falls back to #<tag>" {
    // Synthesise a fn_val Value (no construction path yet, so we use
    // the encodeHeapPtr API directly with a stack-allocated dummy that
    // never gets dereferenced — printValue's else-arm only reads the
    // Value's tag, never the pointee).
    const Dummy = extern struct { _: u64 align(8) = 0 };
    var dummy: Dummy = .{};
    const v = Value.encodeHeapPtr(.fn_val, &dummy);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("#<fn_val>", try renderToBuf(&buf, v));
}
