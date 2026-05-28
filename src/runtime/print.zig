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

const value_mod = @import("value/value.zig");
const Value = value_mod.Value;
const keyword = @import("keyword.zig");
const symbol = @import("symbol.zig");
const string_collection = @import("collection/string.zig");
const list_collection = @import("collection/list.zig");
const vector_collection = @import("collection/vector.zig");
const set_collection = @import("collection/set.zig");
const map_collection = @import("collection/map.zig");
const ex_info_collection = @import("collection/ex_info.zig");
const big_int_mod = @import("numeric/big_int.zig");
const ratio_mod = @import("numeric/ratio.zig");
const big_decimal_mod = @import("numeric/big_decimal.zig");
const td_mod = @import("type_descriptor.zig");
const lazy_seq_mod = @import("lazy_seq.zig");
const env_mod = @import("env.zig");

/// Realize a (possibly lazy) seq into a concrete list for printing, then
/// render it. `printValue` is a pure `(w, v)` renderer with no `rt`/`env`,
/// so it cannot force a `.lazy_seq`; the user-facing print entry points
/// (REPL / `-e` result, nREPL, `prn`/`print`/`str`) — which DO have
/// `rt`/`env` — call this instead so a lazy result renders as `(…)`
/// rather than `#<lazy_seq>`. ADR-0054 cycle 2. Top-level only for now;
/// nested lazy (a lazy seq inside a vector/map) realization rides a
/// follow-up (rare in REPL output).
pub fn printResult(rt: *Runtime, env: *env_mod.Env, w: *Writer, v: Value) anyerror!void {
    if (v.tag() != .lazy_seq) return printValue(w, v);
    // Walk first/rest to full realization, collecting into a list.
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(rt.gpa);
    var cur = v;
    while (true) {
        const s = try lazy_seq_mod.seq(rt, env, cur);
        if (s.tag() == .nil) break;
        try items.append(rt.gpa, try lazy_seq_mod.first(rt, env, s));
        cur = try lazy_seq_mod.rest(rt, env, s);
    }
    var realized = Value.nil_val;
    var i = items.items.len;
    while (i > 0) {
        i -= 1;
        realized = try list_collection.consHeap(rt, items.items[i], realized);
    }
    try printValue(w, realized);
}

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
        .symbol => {
            const s = symbol.asSymbol(v);
            if (s.ns) |n| {
                try w.writeAll(n);
                try w.writeByte('/');
            }
            try w.writeAll(s.name);
        },
        .string => try printString(w, string_collection.asString(v)),
        .list => try printList(w, v),
        .vector => try printVector(w, v),
        .hash_set => try printSet(w, v),
        .array_map, .hash_map => try printMap(w, v),
        .ex_info => try printExInfo(w, v),
        .big_int => try printBigInt(w, v),
        .ratio => try printRatio(w, v),
        .big_decimal => try printBigDecimal(w, v),
        .typed_instance => try printTypedInstance(w, v),
        else => |t| try w.print("#<{s}>", .{@tagName(t)}),
    }
}

fn printBigInt(w: *Writer, v: Value) Writer.Error!void {
    // BigInt's Managed.format renders just the digits; suffix with
    // `N` to disambiguate from a plain Long in pr-str round-trip.
    const m = big_int_mod.asManaged(v);
    try w.print("{f}N", .{m});
}

fn printRatio(w: *Writer, v: Value) Writer.Error!void {
    // numerator and denominator are *BigInt; render each Managed
    // without the trailing `N` and join with `/`.
    const r = v.decodePtr(*const ratio_mod.Ratio);
    try w.print("{f}/{f}", .{ r.numer.m, r.denom.m });
}

fn printBigDecimal(w: *Writer, v: Value) Writer.Error!void {
    // value = unscaled * 10^(-scale). For scale > 0 we render with
    // a decimal point inserted; for scale <= 0 we use scientific-ish
    // `<unscaled>E<-scale>M` (rare; matches JVM `toPlainString` for
    // scale > 0, otherwise `toString`).
    const bd = v.decodePtr(*const big_decimal_mod.BigDecimal);
    if (bd.scale == 0) {
        try w.print("{f}M", .{bd.unscaled.m});
        return;
    }
    // Render unscaled digits into a scratch buffer first, then place
    // the decimal point per JVM `BigDecimal.toPlainString` for
    // scale > 0 (`1.5M` from unscaled=15, scale=1) or append trailing
    // zeros for scale < 0 (`1500M` from unscaled=15, scale=-2).
    // Phase 14 row 14.4 (D-014a) gap (c) discharge.
    var buf: [128]u8 = undefined;
    var sw: std.Io.Writer = .fixed(&buf);
    sw.print("{f}", .{bd.unscaled.m}) catch {
        // Unscaled wider than 128 chars — fall back to the lossy form
        // rather than a panic; user can re-render via toString once
        // arbitrary-width path lands.
        return w.print("{f}M", .{bd.unscaled.m});
    };
    const written = buf[0..sw.end];
    const neg = written.len > 0 and written[0] == '-';
    const digits = if (neg) written[1..] else written;
    if (neg) try w.writeByte('-');
    if (bd.scale > 0) {
        const scale_u: usize = @intCast(bd.scale);
        if (scale_u >= digits.len) {
            try w.writeAll("0.");
            for (0..scale_u - digits.len) |_| try w.writeByte('0');
            try w.writeAll(digits);
        } else {
            const dot_pos = digits.len - scale_u;
            try w.writeAll(digits[0..dot_pos]);
            try w.writeByte('.');
            try w.writeAll(digits[dot_pos..]);
        }
    } else {
        try w.writeAll(digits);
        const trailing: usize = @intCast(-bd.scale);
        for (0..trailing) |_| try w.writeByte('0');
    }
    try w.writeByte('M');
}

fn printTypedInstance(w: *Writer, v: Value) Writer.Error!void {
    const inst = v.decodePtr(*const td_mod.TypedInstance);
    const fqcn = inst.descriptor.fqcn orelse "<anonymous>";
    try w.print("#{s}[", .{fqcn});
    for (inst.fields(), 0..) |fv, i| {
        if (i > 0) try w.writeByte(' ');
        try printValue(w, fv);
    }
    try w.writeByte(']');
}

/// Render an `ex-info` Value in `#error{ :message "..." :data ... }`
/// form — the same shape Clojure JVM's pr-str emits, modulo ordering.
/// Phase 3.10's data is any Value (most often nil at this stage); a
/// real map renderer ships with the heap-map type later.
pub fn printExInfo(w: *Writer, v: Value) Writer.Error!void {
    try w.writeAll("#error{:message ");
    try printString(w, ex_info_collection.message(v));
    try w.writeAll(" :data ");
    try printValue(w, ex_info_collection.data(v));
    const cause = ex_info_collection.cause(v);
    if (!cause.isNil()) {
        try w.writeAll(" :cause ");
        try printValue(w, cause);
    }
    try w.writeByte('}');
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

/// Render a heap Vector in `[a b c]` form (Phase 6.9 cycle 4 —
/// previously fell through to the `#<vector>` placeholder branch).
/// Indexes via `vector_collection.nth` so this stays decoupled from
/// the HAMT internals.
pub fn printVector(w: *Writer, v: Value) Writer.Error!void {
    try w.writeByte('[');
    const n = vector_collection.count(v);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (i > 0) try w.writeByte(' ');
        try printValue(w, vector_collection.nth(v, i));
    }
    try w.writeByte(']');
}

/// Render an ArrayMap (Phase 6.10 cycle 2) in `{k v k v ...}` form.
/// hash_map-backed maps are not iterated yet (D-045 promotion path
/// has no callable consumers — sets/maps stay ArrayMap-only).
pub fn printMap(w: *Writer, v: Value) Writer.Error!void {
    try w.writeByte('{');
    if (v.tag() == .array_map) {
        const am = v.decodePtr(*const map_collection.ArrayMap);
        var i: u32 = 0;
        while (i < am.count) : (i += 1) {
            if (i > 0) try w.writeAll(", ");
            try printValue(w, am.entries[2 * i]);
            try w.writeByte(' ');
            try printValue(w, am.entries[2 * i + 1]);
        }
    }
    try w.writeByte('}');
}

/// Render a PersistentHashSet in `#{a b c}` form (Phase 6.10 cycle 1).
/// Iterates the backing map's `entries` array directly (set's map is
/// an `array_map` until D-045 promotes to HAMT). Element order is
/// insertion order at this scale.
pub fn printSet(w: *Writer, v: Value) Writer.Error!void {
    try w.writeAll("#{");
    const s = v.decodePtr(*const set_collection.PersistentHashSet);
    if (s.map.tag() == .array_map) {
        const am = s.map.decodePtr(*const @import("collection/map.zig").ArrayMap);
        var i: u32 = 0;
        while (i < am.count) : (i += 1) {
            if (i > 0) try w.writeByte(' ');
            try printValue(w, am.entries[2 * i]);
        }
    }
    // hash_map-backed sets (count > 8 after D-045 lands) skip the
    // body — they currently can't exist because PersistentHashSet
    // raises HashMapPromotionNotImplemented during conj. Add the
    // iteration path when D-045 closes.
    try w.writeByte('}');
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

test "symbol: with and without namespace (no leading colon)" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const s1 = try symbol.intern(&rt, null, "foo");
    const s2 = try symbol.intern(&rt, "ns", "bar");

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("foo", try renderToBuf(&buf, s1));
    try testing.expectEqualStrings("ns/bar", try renderToBuf(&buf, s2));
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
