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
const sorted_collection = @import("collection/sorted.zig");
const ex_info_collection = @import("collection/ex_info.zig");
const big_int_mod = @import("numeric/big_int.zig");
const ratio_mod = @import("numeric/ratio.zig");
const big_decimal_mod = @import("numeric/big_decimal.zig");
const td_mod = @import("type_descriptor.zig");
const lazy_seq_mod = @import("lazy_seq.zig");
const range_collection = @import("collection/range.zig");
const env_mod = @import("env.zig");
const dispatch_mod = @import("dispatch.zig");
const SourceLocation = @import("error/info.zig").SourceLocation;

/// Realize any lazy seqs nested in `v` into concrete lists, then render.
/// `printValue` is a pure `(w, v)` renderer with no `rt`/`env`, so it
/// cannot force a `.lazy_seq`; the user-facing entry points (REPL / `-e`
/// result, nREPL, `prn`/`print`/`str`) — which DO have `rt`/`env` — call
/// this so lazy results render as `(…)`, not `#<lazy_seq>`. ADR-0054
/// cycle 2 originally realized only the TOP level; this now realizes
/// nested lazy seqs in the seq family (lazy_seq / list / vector), fixing
/// `(partition-by …)` / `(split-at …)` / `(into [] (partition-all …))`
/// which produced `(#<lazy_seq> …)`. Lazy seqs nested as map values /
/// set elements are a rare residual (still `#<lazy_seq>`).
pub fn printResult(rt: *Runtime, env: *env_mod.Env, w: *Writer, v: Value) anyerror!void {
    try printValue(w, try deepRealize(rt, env, v));
}

fn listFromItems(rt: *Runtime, items: []const Value) !Value {
    var realized = Value.nil_val;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        realized = try list_collection.consHeap(rt, items[i], realized);
    }
    return realized;
}

/// Deep-realize lazy seqs in the seq family so the pure `printValue` sees
/// concrete contents. Scalars / maps / sets pass through unchanged (lazy
/// nested in a map value / set element is a rare residual).
fn deepRealize(rt: *Runtime, env: *env_mod.Env, v: Value) anyerror!Value {
    switch (v.tag()) {
        // `.list` shares the generic seq walk: a `.list` cons may carry a
        // non-list seq as its rest (a "Cons over a seq", e.g.
        // `(conj (range 3) 99)` / `(cons x (map …))`), so a `.list`-only
        // walk would drop the lazy tail. `lazy_seq_mod.seq/first/rest`
        // force lazy layers and route `.list` cells to the list ops, so
        // one loop realizes both (F-011 commonisation).
        .lazy_seq, .list => return realizeSeqWalk(rt, env, v),
        // A `Sequential` deftype (e.g. `Eduction`) prints as its realized
        // seq, not the deftype default `#Name[..]` (D-190 / ADR-0068). The
        // marker — NOT `Seqable` — is the discriminator: a record is Seqable
        // yet prints map-style, so only `Sequential` types route through the
        // same `-seq` walk. Non-Sequential typed_instances pass through to
        // `printTypedInstance` (records render map-style there).
        .typed_instance => {
            if (typedInstanceIsSequential(v)) {
                // Coerce via the `Seqable -seq` protocol first: `realizeSeqWalk`'s
                // `lazy_seq_mod` helpers cannot coerce a typed_instance (that
                // coercion is the seq primitive's job, Layer-2 / D-189). The
                // coerced result is a lazy_seq/list that deepRealize then walks.
                // `dispatchOrNull` (not `dispatch`) so a Sequential-but-not-
                // Seqable deftype falls back to the default render instead of
                // raising mid-print.
                var cs: dispatch_mod.CallSite = .{};
                const noloc: SourceLocation = .{};
                if (try dispatch_mod.dispatchOrNull(rt, env, &cs, v, "Seqable", "-seq", &.{v}, noloc)) |s| {
                    return deepRealize(rt, env, s);
                }
            }
            return v;
        },
        .vector => {
            const n = vector_collection.count(v);
            var out = vector_collection.empty();
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                out = try vector_collection.conj(rt, out, try deepRealize(rt, env, vector_collection.nth(v, i)));
            }
            return out;
        },
        else => return v,
    }
}

/// Realize a seq-family value into a concrete list by walking its
/// `seq`/`first`/`rest`. Shared by the `.lazy_seq`/`.list` arm and the
/// `Sequential` typed_instance arm (F-011 commonisation): `lazy_seq_mod`
/// forces lazy layers, routes `.list` cells to the list ops, and coerces a
/// Seqable deftype through its `-seq` (D-189), so one loop realizes all.
fn realizeSeqWalk(rt: *Runtime, env: *env_mod.Env, v: Value) anyerror!Value {
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(rt.gpa);
    var cur = v;
    while (true) {
        const s = try lazy_seq_mod.seq(rt, env, cur);
        if (s.tag() == .nil) break;
        try items.append(rt.gpa, try deepRealize(rt, env, try lazy_seq_mod.first(rt, env, s)));
        cur = try lazy_seq_mod.rest(rt, env, s);
    }
    return listFromItems(rt, items.items);
}

/// True iff a `.typed_instance`'s descriptor declares the `Sequential`
/// marker protocol — the discriminator for "prints as a seq" (D-190 /
/// ADR-0068). Shares `declaresProtocol` with `sequential?` (one SSOT).
fn typedInstanceIsSequential(v: Value) bool {
    const inst = v.decodePtr(*const td_mod.TypedInstance);
    return inst.descriptor.declaresProtocol("Sequential");
}

/// Render an f64 in Clojure surface form, matching JVM `Double.toString`.
/// A Clojure double always prints with a decimal point or exponent so it
/// reads back as a double, not a long (D-149); the JVM switches to
/// computerized scientific notation `<d>.<dd>E<exp>` outside the decimal
/// window `1e-3 ≤ |x| < 1e7` — i.e. when the decimal exponent leaves
/// `[-3, 6]` (D-166). NaN / ±Inf use the cljw reader's `##` syntax.
///
/// The shortest round-trip digits come from Zig's `std.fmt.float.render`
/// in scientific mode (`[-]d[.frac]e[-]exp`, lowercase e, signed exponent
/// with no leading zeros) — those digits already match the JVM, so this is
/// a RE-LAYOUT, not a float→string algorithm. This is the single float
/// formatter; the analyzer's Form printer (`eval/form.zig`) delegates here
/// (F-011 commonisation). Acceptable divergence: the smallest subnormal
/// prints `5.0E-324` (Ryū shortest) where the JVM prints `4.9E-324` — same
/// double, value-exact.
pub fn printFloat(w: *Writer, f: f64) Writer.Error!void {
    if (std.math.isNan(f)) return w.writeAll("##NaN");
    if (std.math.isPositiveInf(f)) return w.writeAll("##Inf");
    if (std.math.isNegativeInf(f)) return w.writeAll("##-Inf");

    // Scientific shortest form is ≤ 53 bytes for an f64, so a 64-byte buffer
    // cannot overflow — render's only error (BufferTooSmall) is unreachable.
    var buf: [64]u8 = undefined;
    const sci = std.fmt.float.render(&buf, f, .{ .mode = .scientific, .precision = null }) catch unreachable;

    var rest = sci;
    const negative = rest[0] == '-';
    if (negative) rest = rest[1..];

    const e_idx = std.mem.findScalar(u8, rest, 'e').?;
    const mant = rest[0..e_idx];
    const exp10 = std.fmt.parseInt(i32, rest[e_idx + 1 ..], 10) catch unreachable;

    // Significant digits with the `.` stripped: lead digit + optional frac.
    var digbuf: [32]u8 = undefined;
    digbuf[0] = mant[0];
    var len: usize = 1;
    if (mant.len > 1) { // mant[1] is the '.'
        @memcpy(digbuf[1 .. mant.len - 1], mant[2..]);
        len = mant.len - 1;
    }
    const digits = digbuf[0..len];

    if (negative) try w.writeByte('-');

    if (exp10 >= -3 and exp10 <= 6) {
        // Decimal layout (no exponent).
        if (exp10 >= 0) {
            const point: usize = @intCast(exp10 + 1); // digits before the point
            if (point >= len) {
                try w.writeAll(digits);
                try w.splatByteAll('0', point - len); // pad the integer part
                try w.writeAll(".0"); // JVM always keeps one fractional digit
            } else {
                try w.writeAll(digits[0..point]);
                try w.writeByte('.');
                try w.writeAll(digits[point..]);
            }
        } else {
            // |x| < 1: `0.` + (-exp10-1) leading zeros + every digit.
            try w.writeAll("0.");
            try w.splatByteAll('0', @intCast(-exp10 - 1));
            try w.writeAll(digits);
        }
    } else {
        // Scientific layout: `d.<rest>E<exp>`, mantissa always carries a `.`.
        try w.writeByte(digits[0]);
        try w.writeByte('.');
        if (len > 1) try w.writeAll(digits[1..]) else try w.writeByte('0');
        try w.writeByte('E');
        try w.print("{d}", .{exp10});
    }
}

/// Render `v` to `w` in `pr-str` style. Phase-3 surface covers nil /
/// Render a char in readable (`pr`) form, JVM-faithful (D-154): named
/// forms for the standard whitespace chars, `\<ch>` for printable ASCII,
/// `\uXXXX` otherwise. (The raw `str`/`print` form emits the bare char —
/// see `lang/primitive/core.zig::writeArgsSpaced`.)
/// `print`-form of a char (D-185): the bare UTF-8 character, no `\` literal
/// prefix. Mirrors `writeArgsSpaced`'s top-level raw-char path (D-154) for
/// chars nested inside a collection printed under `print`/`println`.
pub fn printCharRaw(w: *Writer, cp: u21) Writer.Error!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch 0;
    try w.writeAll(buf[0..n]);
}

pub fn printCharReadable(w: *Writer, cp: u21) Writer.Error!void {
    switch (cp) {
        '\n' => try w.writeAll("\\newline"),
        '\t' => try w.writeAll("\\tab"),
        '\r' => try w.writeAll("\\return"),
        ' ' => try w.writeAll("\\space"),
        8 => try w.writeAll("\\backspace"),
        12 => try w.writeAll("\\formfeed"),
        else => {
            if (cp > 32 and cp < 127) {
                try w.writeByte('\\');
                try w.writeByte(@intCast(cp));
            } else {
                try w.print("\\u{x:0>4}", .{cp});
            }
        },
    }
}

/// boolean / integer / float / char / keyword / builtin_fn / string /
/// list. Other heap kinds render as `#<tag>` placeholders so the user
/// always sees *something* instead of an undecipherable address —
/// Phase 3.10+ adds dedicated branches as the heap types ship.
/// Clojure's `*print-readably*` (D-185), as a thread-local since the pure
/// `printValue` renderer carries no `rt`/`env`. `true` (default) = `pr`
/// form: strings quoted, chars as `\X` literals. `false` = `print` form:
/// strings raw, chars bare — set by `print`/`println` for the whole render
/// (incl. nested collection elements), restored after. `pr`/`prn`/`pr-str`/
/// `str`-collections keep the default.
pub threadlocal var print_readably: bool = true;

pub fn printValue(w: *Writer, v: Value) Writer.Error!void {
    switch (v.tag()) {
        .nil => try w.writeAll("nil"),
        .boolean => try w.writeAll(if (v.asBoolean()) "true" else "false"),
        .integer => try w.print("{d}", .{v.asInteger()}),
        .float => try printFloat(w, v.asFloat()),
        .char => if (print_readably) try printCharReadable(w, v.asChar()) else try printCharRaw(w, v.asChar()),
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
        .string => if (print_readably) try printString(w, string_collection.asString(v)) else try w.writeAll(string_collection.asString(v)),
        .list => try printList(w, v),
        .range => try printRange(w, v),
        .vector => try printVector(w, v),
        .hash_set => try printSet(w, v),
        .sorted_set => try printSortedSet(w, v),
        .sorted_map => try printSortedMap(w, v),
        .array_map, .hash_map => try printMap(w, v),
        .ex_info => try printExInfo(w, v),
        .big_int => try printBigInt(w, v),
        .ratio => try printRatio(w, v),
        .big_decimal => try printBigDecimal(w, v),
        .typed_instance => try printTypedInstance(w, v),
        .type_descriptor => try printTypeDescriptor(w, v),
        .var_ref => try printVarRef(w, v),
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
    // value = unscaled * 10^(-scale). Reproduces JVM `BigDecimal.toString`:
    // plain notation when `scale >= 0` AND the adjusted exponent
    // `(precision-1) - scale >= -6`, otherwise scientific `d.dddE±exp`.
    const bd = v.decodePtr(*const big_decimal_mod.BigDecimal);

    // Render unscaled digits into a scratch buffer; split off the sign.
    var buf: [1024]u8 = undefined;
    var sw: std.Io.Writer = .fixed(&buf);
    sw.print("{f}", .{bd.unscaled.m}) catch {
        // Unscaled wider than the buffer — fall back to the lossy form
        // rather than a panic.
        return w.print("{f}M", .{bd.unscaled.m});
    };
    const written = buf[0..sw.end];
    const neg = written.len > 0 and written[0] == '-';
    const digits = if (neg) written[1..] else written;
    const n: i64 = @intCast(digits.len);
    const adj_exp: i64 = (n - 1) - bd.scale;

    if (neg) try w.writeByte('-');
    if (bd.scale >= 0 and adj_exp >= -6) {
        // Plain notation (toPlainString).
        if (bd.scale == 0) {
            try w.writeAll(digits);
        } else {
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
        }
    } else {
        // Scientific: one digit, optional fraction, `E`, signed exponent.
        try w.writeByte(digits[0]);
        if (digits.len > 1) {
            try w.writeByte('.');
            try w.writeAll(digits[1..]);
        }
        try w.writeByte('E');
        if (adj_exp >= 0) try w.writeByte('+');
        try w.print("{d}", .{adj_exp});
    }
    try w.writeByte('M');
}

fn printTypedInstance(w: *Writer, v: Value) Writer.Error!void {
    const inst = v.decodePtr(*const td_mod.TypedInstance);
    const fqcn = inst.descriptor.fqcn orelse "<anonymous>";
    // A record prints map-style `#Name{:k v, …}` from its declared field
    // layout (D-190 / ADR-0068). The `user.`-ns prefix JVM emits is deferred
    // to the ns surface (D-058/079); declared fields only — assoc'd extra
    // keys (`__extmap`, D-086) are a separate residual.
    if (inst.descriptor.kind == .defrecord) {
        if (inst.descriptor.field_layout) |layout| {
            const fs = inst.fields();
            try w.print("#{s}{{", .{fqcn});
            for (layout, 0..) |fe, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print(":{s} ", .{fe.name});
                try printValue(w, fs[fe.index]);
            }
            try w.writeByte('}');
            return;
        }
    }
    try w.print("#{s}[", .{fqcn});
    for (inst.fields(), 0..) |fv, i| {
        if (i > 0) try w.writeByte(' ');
        try printValue(w, fv);
    }
    try w.writeByte(']');
}

/// Render a `.type_descriptor` Value (the value `(class x)` returns) as
/// its simple class name (ADR-0059): `Long`, `String`, `PersistentVector`,
/// or a user record's `Point`. Simple name, not a JVM FQCN, per the
/// no-JVM-assumption rule. Anonymous (reify) descriptors fall back to the
/// generic placeholder since they carry no name.
fn printTypeDescriptor(w: *Writer, v: Value) Writer.Error!void {
    const td = td_mod.asTypeDescriptorRef(v);
    if (td.fqcn) |name| {
        try w.writeAll(name);
    } else {
        try w.writeAll("#<type>");
    }
}

/// Render a `.var_ref` Value (what `(def x ..)` / `(defn ..)` / `resolve`
/// yield) as Clojure's var-quote form `#'ns/name`, reading the owning
/// namespace + symbol name off the Var.
fn printVarRef(w: *Writer, v: Value) Writer.Error!void {
    const var_ptr = v.decodePtr(*const env_mod.Var);
    try w.print("#'{s}/{s}", .{ var_ptr.ns.name, var_ptr.name });
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

/// Render a compact `.range` as a list `(0 1 2 …)` (JVM parity). Computes
/// each element with pure scalar math (`start + i*step`) so it needs no
/// `rt` and allocates nothing — unlike a generic seq-walk. A huge range
/// prints every element (same as realizing a lazy seq).
pub fn printRange(w: *Writer, v: Value) Writer.Error!void {
    try w.writeByte('(');
    const n = range_collection.countOf(v);
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        if (i > 0) try w.writeByte(' ');
        try printValue(w, range_collection.elementAt(v, i));
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
/// Walk a HAMT node pre-order, writing each entry. `kv` true → "k v"
/// pairs (map), false → bare elements (set). `first` threads the
/// separator across the recursion. Alloc-free — the printer has no
/// allocator, so it reads `slots` directly rather than materialising a
/// seq (front-loaded KV pairs, back-loaded children per map.zig).
fn printHamtEntries(w: *Writer, node: *const map_collection.HamtMapNode, first: *bool, comptime kv: bool) Writer.Error!void {
    const data_count = @popCount(node.data_map);
    var i: u32 = 0;
    while (i < data_count) : (i += 1) {
        if (!first.*) try w.writeAll(if (kv) ", " else " ");
        first.* = false;
        try printValue(w, node.slots[2 * i]);
        if (kv) {
            try w.writeByte(' ');
            try printValue(w, node.slots[2 * i + 1]);
        }
    }
    const child_count = @popCount(node.node_map);
    var j: u32 = 0;
    while (j < child_count) : (j += 1) {
        try printHamtEntries(w, node.slots[63 - j].decodePtr(*const map_collection.HamtMapNode), first, kv);
    }
}

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
    } else {
        const phm = v.decodePtr(*const map_collection.PersistentHashMap);
        if (phm.root) |root| {
            var first = true;
            try printHamtEntries(w, root, &first, true);
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
        const am = s.map.decodePtr(*const map_collection.ArrayMap);
        var i: u32 = 0;
        while (i < am.count) : (i += 1) {
            if (i > 0) try w.writeByte(' ');
            try printValue(w, am.entries[2 * i]);
        }
    } else {
        // hash_map-backed set (> 8 elements): walk the backing map's HAMT
        // keys directly (the set stores each element as a map key).
        const phm = s.map.decodePtr(*const map_collection.PersistentHashMap);
        if (phm.root) |root| {
            var first = true;
            try printHamtEntries(w, root, &first, false);
        }
    }
    try w.writeByte('}');
}

/// In-order (ascending) walk of an LLRB tree, alloc-free (the printer has
/// no allocator). `kv` true → "k v" pairs (map), false → bare keys (set).
fn printSortedEntries(w: *Writer, root: Value, first: *bool, comptime kv: bool) Writer.Error!void {
    if (root.tag() != .rb_node) return;
    const n = root.decodePtr(*const sorted_collection.RbNode);
    try printSortedEntries(w, n.left, first, kv);
    if (!first.*) try w.writeAll(if (kv) ", " else " ");
    first.* = false;
    try printValue(w, n.key);
    if (kv) {
        try w.writeByte(' ');
        try printValue(w, n.val);
    }
    try printSortedEntries(w, n.right, first, kv);
}

pub fn printSortedMap(w: *Writer, v: Value) Writer.Error!void {
    try w.writeByte('{');
    const m = v.decodePtr(*const sorted_collection.SortedMap);
    var first = true;
    try printSortedEntries(w, m.root, &first, true);
    try w.writeByte('}');
}

pub fn printSortedSet(w: *Writer, v: Value) Writer.Error!void {
    try w.writeAll("#{");
    const s = v.decodePtr(*const sorted_collection.SortedSet);
    const m = s.map.decodePtr(*const sorted_collection.SortedMap);
    var first = true;
    try printSortedEntries(w, m.root, &first, false);
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
