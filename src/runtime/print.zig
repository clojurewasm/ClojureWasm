//! Value renderer (`pr-str` style).
//!
//! A single printer so that the REPL, nREPL, the `pr-str` / `prn`
//! primitives, and `--compare`'s diff renderer all converge on one
//! implementation.
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
//!   `#<tag>` for any heap kind without a dedicated branch.
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
//! and from the `pr-str` builtin). Putting it in Layer 0 lets
//! `lang/primitive/io.zig` call it without crossing the zone contract.

const std = @import("std");
const Writer = std.Io.Writer;

const value_mod = @import("value/value.zig");
const Value = value_mod.Value;
const keyword = @import("keyword.zig");
const symbol = @import("symbol.zig");
const multimethod = @import("multimethod.zig");
const protocol = @import("protocol.zig");
const string_collection = @import("collection/string.zig");
const list_collection = @import("collection/list.zig");
const vector_collection = @import("collection/vector.zig");
const set_collection = @import("collection/set.zig");
const map_collection = @import("collection/map.zig");
const map_entry_collection = @import("collection/map_entry.zig");
const root_set = @import("gc/root_set.zig");
const persistent_queue = @import("collection/persistent_queue.zig");
const sorted_collection = @import("collection/sorted.zig");
const ex_info_collection = @import("collection/ex_info.zig");
const big_int_mod = @import("numeric/big_int.zig");
const ratio_mod = @import("numeric/ratio.zig");
const big_decimal_mod = @import("numeric/big_decimal.zig");
const regex_mod = @import("regex/value.zig");
const uuid_mod = @import("uuid.zig");
const tagged_literal_mod = @import("tagged_literal.zig");
const td_mod = @import("type_descriptor.zig");
const instant_mod = @import("time/instant.zig");
const lazy_seq_mod = @import("lazy_seq.zig");
const range_collection = @import("collection/range.zig");
const env_mod = @import("env.zig");
const dispatch_mod = @import("dispatch.zig");
const writer_value = @import("writer_value.zig");
const class_of = @import("class_of.zig");
const SourceLocation = @import("error/info.zig").SourceLocation;

/// Realize any lazy seqs nested in `v` into concrete lists, then render.
/// `printValue` is a pure `(w, v)` renderer with no `rt`/`env`, so it
/// cannot force a `.lazy_seq`; the user-facing entry points (REPL / `-e`
/// result, nREPL, `prn`/`print`/`str`) — which DO have `rt`/`env` — call
/// this so lazy results render as `(…)`, not `#<lazy_seq>`. ADR-0054
/// cycle 2 originally realized only the TOP level; this now realizes
/// nested lazy seqs in the seq family (lazy_seq / list / vector), fixing
/// `(partition-by …)` / `(split-at …)` / `(into [] (partition-all …))`
/// which produced `(#<lazy_seq> …)` — and in map values / set elements
/// (all four map/set tags; hit by potpuri's build-tree, corpus
/// `lazy_nested_print`).
pub fn printResult(rt: *Runtime, env: *env_mod.Env, w: *Writer, v: Value) anyerror!void {
    // ADR-0088: snapshot *print-length*/*print-level* once per top-level value
    // (resets depth to 0) so the recursive `printValue` honours a user binding
    // without a per-element Var deref. Re-snapshotting each call keeps a prior
    // binding from leaking into the next print.
    snapshotPrintLimits();
    // Arm the realize context (same shape as ADR-0127's `active_consult`) so
    // nested dispatch-needing renders — an IPersistentMap-declaring deftype's
    // map-style print — can reach rt/env from inside the pure `printValue`
    // recursion. Saved/restored so a re-entrant print keeps its own ctx.
    const saved = realize_ctx;
    realize_ctx = .{ .rt = rt, .env = env };
    defer realize_ctx = saved;
    try printValue(w, try deepRealize(rt, env, v));
}

/// rt/env for dispatch-needing renders inside the pure `printValue` recursion
/// (armed by `printResult`; the ADR-0127 `active_consult` precedent).
threadlocal var realize_ctx: ?struct { rt: *Runtime, env: *env_mod.Env } = null;

/// Write `v` in `str`-form (the unquoted `toString` rendering) to `w`. The
/// single source for `clojure.core/str` (Layer 2) AND the `.toString`
/// Object-method fallback (Layer 1, D-207) — F-009/F-011. Top-level string
/// / char / regex / uuid render BARE; everything else uses the readable
/// `printResult`, so a NESTED string keeps its quotes (`(str [1 "a"])` →
/// `[1 "a"]`, matching clj's collection toString).
pub fn writeStrValue(rt: *Runtime, env: *env_mod.Env, w: *Writer, v: Value) anyerror!void {
    switch (v.tag()) {
        .nil => {},
        .string => try w.writeAll(string_collection.asString(v)),
        // `str`/`.toString` of a special float uses Java `Double.toString`
        // (`Infinity` / `-Infinity` / `NaN`), NOT the readable `##Inf` reader
        // form `pr`/`prn` use (D-212-class str↔pr split). Normal floats render
        // identically under both, so delegate to `printFloat`.
        .float => {
            const f = v.asFloat();
            if (std.math.isNan(f)) {
                try w.writeAll("NaN");
            } else if (std.math.isPositiveInf(f)) {
                try w.writeAll("Infinity");
            } else if (std.math.isNegativeInf(f)) {
                try w.writeAll("-Infinity");
            } else {
                try printFloat(w, f);
            }
        },
        .char => {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(v.asChar(), &buf) catch 0;
            try w.writeAll(buf[0..n]);
        },
        .regex => try w.writeAll(regex_mod.asRegex(v).source()),
        .uuid => {
            const canon = uuid_mod.canonicalOf(v);
            try w.writeAll(&canon);
        },
        // `(str *ns*)` → bare "user" (clj Namespace.toString = the name), not the
        // readable `#object[Namespace …]` form pr/prn use.
        .ns => try w.writeAll(v.decodePtr(*const env_mod.Namespace).name),
        // `str`/`.toString` of a BigInt/BigDecimal drops the `N`/`M` reader
        // suffix that `pr`/`prn` keep — JVM `BigInteger`/`BigDecimal.toString`
        // emit plain digits (D-212). Ratio's `1/2` form is already suffix-free.
        .big_int => try w.print("{f}", .{big_int_mod.asManaged(v)}),
        .big_decimal => try writeBigDecimalDigits(w, v),
        // D-275: a deftype/reify `Object (toString [this] …)` impl supplies the
        // `str`/`.toString` representation — consulted like the `Seqable/-seq`
        // print coercion (`dispatchOrNull` so a type without the impl falls back
        // to the default `printResult` render, no raise mid-str). Covers both
        // deftype (`.typed_instance`) and reify (`.reified_instance`).
        .typed_instance, .reified_instance => {
            var cs: dispatch_mod.CallSite = .{};
            const noloc: SourceLocation = .{};
            if (try dispatch_mod.dispatchOrNull(rt, env, &cs, v, "Object", "toString", &.{v}, noloc)) |s| {
                return writeStrValue(rt, env, w, s);
            }
            try printResult(rt, env, w, v);
        },
        // A host surface that registers a `toString` method (java.net.URI) supplies
        // its `str`/`.toString` rendering — clj's `(str uri)` calls `.toString`.
        // A surface without one (java.util.Random) falls through to the opaque
        // `#<fqcn>` form (AD-020).
        .host_instance => {
            const inst = @import("host_instance.zig").asHostInstance(v);
            if (inst.descriptor.lookupMethod(null, "toString")) |entry| {
                if (rt.vtable) |vt| {
                    const noloc: SourceLocation = .{};
                    const s = try vt.callFn(rt, env, entry.method_val, &.{v}, noloc);
                    return writeStrValue(rt, env, w, s);
                }
            }
            try printResult(rt, env, w, v);
        },
        else => try printResult(rt, env, w, v),
    }
}

fn listFromItems(rt: *Runtime, items: []const Value) !Value {
    // Empty → the interned empty list `()` (D-164) so a realized empty seq
    // (e.g. `(filter even? [1 3])`) prints `()` not nil.
    if (items.len == 0) return try list_collection.emptyList(rt);
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
        // `.chunked_cons` is the bare seq view of a range (`(seq (range 3))`,
        // `(rest (range 5))`) — without this it fell through to the generic
        // `#<chunked_cons>` render instead of its elements (it already realizes
        // correctly in a `.list` tail, e.g. `(cons 0 (seq (range 3)))`).
        .lazy_seq, .list, .chunked_cons => return realizeSeqWalk(rt, env, v),
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
                    if (s.isNil()) return s; // empty Sequential → nil (prints "()")
                    // A self-returning ISeq (`-seq` → an instance, incl. `v` itself):
                    // walk the ISeq protocol, NOT deepRealize(s) which re-dispatches
                    // `-seq` on the same instance forever (D-422).
                    if (s.tag() == .typed_instance or s.tag() == .reified_instance)
                        return realizeInstanceSeq(rt, env, s);
                    return deepRealize(rt, env, s); // `-seq` → a lazy_seq/list (e.g. Eduction)
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
            // Carry metadata through the rebuild so `*print-meta*` sees it
            // (the realize pass must not strip `^meta`).
            const m = vector_collection.metaOf(v);
            return if (m.isNil()) out else try vector_collection.withMeta(rt, out, m);
        },
        // A MapEntry realizes its key/val (which may hold lazy seqs) while
        // staying a MapEntry (D-209), so it still prints `[k v]`.
        .map_entry => return try map_entry_collection.make(
            rt,
            try deepRealize(rt, env, map_entry_collection.keyOf(v)),
            try deepRealize(rt, env, map_entry_collection.valOf(v)),
        ),
        // Map values / set elements may hold lazy seqs too (potpuri's
        // build-tree assocs a lazy children seq). Re-assoc / re-conj ONLY the
        // entries a realize actually changed, so type / comparator / meta and
        // the untouched structure are preserved (assoc-on-the-original, not a
        // rebuild). Bit-identity (`@intFromEnum`) detects "realize was a
        // no-op" — deepRealize returns the same Value when nothing was lazy.
        .array_map, .hash_map => {
            var out = v;
            var ks = try map_collection.keys(rt, v);
            while (ks.tag() == .list and list_collection.countOf(ks) > 0) : (ks = list_collection.rest(ks)) {
                const k = list_collection.first(ks);
                const val = try map_collection.get(v, k);
                const rk = try deepRealize(rt, env, k);
                const rv = try deepRealize(rt, env, val);
                if (@intFromEnum(rk) != @intFromEnum(k)) {
                    out = try map_collection.dissoc(rt, out, k);
                    out = try map_collection.assoc(rt, out, rk, rv);
                } else if (@intFromEnum(rv) != @intFromEnum(val)) {
                    out = try map_collection.assoc(rt, out, k, rv);
                }
            }
            return out;
        },
        // Sorted variants ride the sorted module (comparator-aware assoc/
        // dissoc need env; a realized KEY is not re-keyed — the comparator
        // ordered it by value, and a lazy seq as a sorted key is pathological
        // — only VALUES are realized).
        .sorted_map => {
            var out = v;
            const noloc: SourceLocation = .{};
            var ks = try sorted_collection.keys(rt, v);
            while (ks.tag() == .list and list_collection.countOf(ks) > 0) : (ks = list_collection.rest(ks)) {
                const k = list_collection.first(ks);
                const val = try sorted_collection.get(rt, env, v, k, noloc);
                const rv = try deepRealize(rt, env, val);
                if (@intFromEnum(rv) != @intFromEnum(val)) {
                    out = try sorted_collection.assoc(rt, env, out, k, rv, noloc);
                }
            }
            return out;
        },
        .hash_set => {
            var out = v;
            var es = try set_collection.seq(rt, v);
            while (es.tag() == .list and list_collection.countOf(es) > 0) : (es = list_collection.rest(es)) {
                const e = list_collection.first(es);
                const re = try deepRealize(rt, env, e);
                if (@intFromEnum(re) != @intFromEnum(e)) {
                    out = try set_collection.disj(rt, out, e);
                    out = try set_collection.conj(rt, out, re);
                }
            }
            return out;
        },
        .sorted_set => {
            var out = v;
            const noloc: SourceLocation = .{};
            var es = try sorted_collection.seq(rt, v);
            while (es.tag() == .list and list_collection.countOf(es) > 0) : (es = list_collection.rest(es)) {
                const e = list_collection.first(es);
                const re = try deepRealize(rt, env, e);
                if (@intFromEnum(re) != @intFromEnum(e)) {
                    out = try sorted_collection.disjSet(rt, env, out, e, noloc);
                    out = try sorted_collection.conjSet(rt, env, out, re, noloc);
                }
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
    // GC-ROOT: D-253 — root the cursor (stack) + the accumulating realized items
    // (locals = the gpa ArrayList, refreshed each iter since append may realloc)
    // across seq/first/rest + the recursive `deepRealize` (all re-enter the VM to
    // force lazy layers) [ref: .dev/gc_rooting.md §C]. Without it a torture
    // collect sweeps a partly-realized nested seq -> garbage cons (D-253 the
    // partition-family / nested-lazy-print corruption). The C9 result-pin roots
    // only the outer Value; this covers the deep realize walk's own intermediates.
    var cur_root: [1]Value = .{cur};
    var cur_sp: u16 = 1;
    var gc_frame: root_set.EvalFrame = .{ .stack = &cur_root, .sp = &cur_sp, .locals = items.items, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;
    while (true) {
        cur_root[0] = cur;
        gc_frame.locals = items.items;
        // *print-length* (D-222 b): bound realization to limit+1 items so an
        // INFINITE lazy seq terminates under `*print-length*` (the +1 lets the
        // printer still emit "..." for "there is more"). Unbounded otherwise
        // (clj realizes the whole finite seq). Applies per seq, so nested seqs
        // are each bounded — matching clj's per-collection length.
        if (print_length_limit) |lim| {
            if (items.items.len > lim) break;
        }
        const s = try lazy_seq_mod.seq(rt, env, cur);
        if (s.tag() == .nil) break;
        cur_root[0] = s;
        try items.append(rt.gpa, try deepRealize(rt, env, try lazy_seq_mod.first(rt, env, s)));
        gc_frame.locals = items.items; // root the just-appended item across rest's force
        cur = try lazy_seq_mod.rest(rt, env, s);
    }
    const realized = try listFromItems(rt, items.items);
    // Carry the original collection's metadata onto the realized list so
    // `*print-meta*` sees a `^meta` list/seq (the realize must not strip it).
    const m = switch (v.tag()) {
        .list => list_collection.metaOf(v),
        .lazy_seq => lazy_seq_mod.metaOf(v),
        else => Value.nil_val,
    };
    return if (m.isNil() or realized.tag() != .list) realized else try list_collection.withMeta(rt, realized, m);
}

/// Realize an instance ISeq whose `-seq` returns ITSELF (the clj
/// ISeq-is-its-own-seq idiom — e.g. data.finger-tree's SingleTree/DoubleList
/// `(seq [this] this)`). Walk the ISeq protocol (`-first`/`-next`), NOT
/// `deepRealize(-seq …)` which would re-dispatch `-seq` → the same instance →
/// forever (D-422 segfault). `*print-length*`-bounded; deepRealizes each element;
/// GC-rooted like `realizeSeqWalk`. A `-next` that yields a non-instance seq
/// (lazy/list) hands off to `realizeSeqWalk` for the tail.
fn realizeInstanceSeq(rt: *Runtime, env: *env_mod.Env, start: Value) anyerror!Value {
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(rt.gpa);
    var cur = start;
    var cur_root: [1]Value = .{cur};
    var cur_sp: u16 = 1;
    var gc_frame: root_set.EvalFrame = .{ .stack = &cur_root, .sp = &cur_sp, .locals = items.items, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;
    const noloc: SourceLocation = .{};
    while (cur.tag() == .typed_instance or cur.tag() == .reified_instance) {
        if (print_length_limit) |lim| {
            if (items.items.len > lim) break;
        }
        cur_root[0] = cur;
        gc_frame.locals = items.items;
        var cs1: dispatch_mod.CallSite = .{};
        const f = (try dispatch_mod.dispatchOrNull(rt, env, &cs1, cur, "ISeq", "-first", &.{cur}, noloc)) orelse break;
        try items.append(rt.gpa, try deepRealize(rt, env, f));
        gc_frame.locals = items.items;
        var cs2: dispatch_mod.CallSite = .{};
        cur = (try dispatch_mod.dispatchOrNull(rt, env, &cs2, cur, "ISeq", "-next", &.{cur}, noloc)) orelse break;
    }
    // A `-next` that returned a non-instance seq (lazy_seq/list): realize its tail.
    if (!cur.isNil() and cur.tag() != .typed_instance and cur.tag() != .reified_instance) {
        cur_root[0] = cur;
        var t = try realizeSeqWalk(rt, env, cur);
        while (t.tag() == .list and list_collection.countOf(t) > 0) : (t = list_collection.rest(t)) {
            try items.append(rt.gpa, list_collection.first(t));
            gc_frame.locals = items.items;
        }
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

/// Render a char in readable (`pr`) form, clj-faithful (D-154/D-208): named
/// forms for the 6 standard whitespace chars, else `\` + the literal char
/// (printable ASCII, control chars, and non-ASCII alike — clj emits NO
/// `\uXXXX`; D-208 corrected D-154's mistaken belief). (The raw `str`/`print`
/// form emits the bare char —
/// see `lang/primitive/core.zig::writeArgsSpaced`.)
/// `print`-form of a char (D-185): the bare UTF-8 character, no `\` literal
/// prefix. Mirrors `writeArgsSpaced`'s top-level raw-char path (D-154) for
/// chars nested inside a collection printed under `print`/`println`.
pub fn printCharRaw(w: *Writer, cp: u21) anyerror!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch 0;
    try w.writeAll(buf[0..n]);
}

pub fn printCharReadable(w: *Writer, cp: u21) anyerror!void {
    switch (cp) {
        '\n' => try w.writeAll("\\newline"),
        '\t' => try w.writeAll("\\tab"),
        '\r' => try w.writeAll("\\return"),
        ' ' => try w.writeAll("\\space"),
        8 => try w.writeAll("\\backspace"),
        12 => try w.writeAll("\\formfeed"),
        else => {
            // clj prints `\` + the literal char for every non-named
            // codepoint: printable ASCII, control chars, and non-ASCII
            // alike. clj emits NO \uXXXX (verified: (char 7) -> `\`+BEL,
            // (char 233) -> `\`+the UTF-8 char). D-208 corrects D-154's
            // mistaken "JVM uses \uXXXX" belief.
            try w.writeByte('\\');
            try printCharRaw(w, cp);
        },
    }
}

/// A heap kind with no dedicated branch renders as a `#<tag>`
/// placeholder so the user always sees *something* instead of an
/// undecipherable address.
/// Clojure's `*print-readably*` (D-185), as a thread-local since the pure
/// `printValue` renderer carries no `rt`/`env`. `true` (default) = `pr`
/// form: strings quoted, chars as `\X` literals. `false` = `print` form:
/// strings raw, chars bare — set by `print`/`println` for the whole render
/// (incl. nested collection elements), restored after. `pr`/`prn`/`pr-str`/
/// `str`-collections keep the default.
pub threadlocal var print_readably: bool = true;

/// A callable value's qualified identity for printing (ADR-0121 / D-328). Both
/// fields are borrowed (analyzer-arena / interned), read only for immediate
/// formatting — no lifetime crosses the accessor boundary.
pub const FnIdentity = struct { ns: ?[]const u8 = null, name: ?[]const u8 = null };

/// Reads a `.fn_val`'s `{ns, name}` (ADR-0121). `.fn_val`'s `Function` struct is
/// a Layer-1 (eval) type Layer-0 `print.zig` must not import, so the eval layer
/// injects this accessor at startup (`tree_walk.registerGcHooks`), mirroring the
/// `info.context_provider` setter-injection. null until installed → `#<fn>`.
/// `.multi_fn` / `.protocol_fn` are Layer-0 structs read directly (no accessor).
var fn_name_accessor: ?*const fn (Value) FnIdentity = null;

pub fn setFnNameAccessor(f: *const fn (Value) FnIdentity) void {
    fn_name_accessor = f;
}

/// Write a callable in the `#<ns/name>` form (AD-025): the AD-002 `#<…>` envelope
/// filled with the qualified name instead of clj's munged `#object[class 0xHASH]`.
/// A null `name` (truly anonymous) renders `#<fn>`; a null `ns` drops the prefix.
fn printCallable(w: *Writer, ns: ?[]const u8, name: ?[]const u8) anyerror!void {
    try w.writeAll("#<");
    if (ns) |n| {
        try w.writeAll(n);
        try w.writeByte('/');
    }
    try w.writeAll(name orelse "fn");
    try w.writeByte('>');
}

/// Clojure's `*print-namespace-maps*` (D-219). When true and every key of a
/// map is a keyword/symbol sharing one namespace, the map prints in the compact
/// `#:ns{:a 1, :b 2}` form. Defaults to `true` to match `clojure.main` (which
/// binds it true for `-e`/REPL), so `cljw -e` mirrors `clj -M -e`. A thread-
/// local since the pure `printValue` renderer carries no `rt`/`env`.
pub threadlocal var print_namespace_maps: bool = true;

/// Cached `*const Var` pointers to `*print-length*` / `*print-level*`
/// (ADR-0088). The Var IDENTITY is fixed after intern, so these are
/// process-global; the user's current BINDING is read live via `Var.deref()`
/// (which reads the thread-local binding stack and needs no `rt`/`env`, so the
/// pure `printValue` renderer can honour `(binding [*print-length* …] …)`).
/// Installed by `bootstrap` after `core.clj` defines the vars.
var print_length_var: ?*const env_mod.Var = null;
var print_level_var: ?*const env_mod.Var = null;
/// `*print-namespace-maps*` cached Var (D-222 residual a). Unlike the limits it
/// has a non-nil root (true); a user `(binding [*print-namespace-maps* false] …)`
/// disables the compact `#:ns{…}` form.
var print_namespace_maps_var: ?*const env_mod.Var = null;
/// `*print-readably*` cached Var (D-222 residual a). Unlike the others it is
/// ALSO set imperatively by the pr/print surface (`writeArgsSpaced`), so the
/// snapshot only overrides `print_readably` when the var is EXPLICITLY thread-
/// bound — leaving the surface's pr-vs-print choice intact by default.
var print_readably_var: ?*const env_mod.Var = null;
/// `*print-meta*` cached Var — when truthy, every value carrying non-empty
/// metadata prints with a `^{meta} ` prefix. Pure snapshot (no surface set).
var print_meta_var: ?*const env_mod.Var = null;

/// Install the cached print-control Var pointers (called once at bootstrap).
pub fn initPrintLimitVars(len_v: ?*const env_mod.Var, lvl_v: ?*const env_mod.Var, nsmaps_v: ?*const env_mod.Var, readably_v: ?*const env_mod.Var, meta_v: ?*const env_mod.Var) void {
    print_length_var = len_v;
    print_level_var = lvl_v;
    print_namespace_maps_var = nsmaps_v;
    print_readably_var = readably_v;
    print_meta_var = meta_v;
}

// === print-method consult (D-370, ADR-0127) ===
// Cached `clojure.core/print-method` Var (nullable until bootstrap installs it, so
// `pr` during core load — before print-method is def'd — takes the native path).
// The consult derefs the MultiFn live each call (cheap; the multifn Value is
// defonce-stable per D-184).
var print_method_var: ?*const env_mod.Var = null;

/// Install the cached `print-method` Var (called once at bootstrap, after core.clj).
pub fn initPrintMethodVar(v: ?*const env_mod.Var) void {
    print_method_var = v;
}

/// The non-default `print-method` override for `(class v)`, or null when only the
/// `:default` matches (the common no-override case stays native). The
/// `method_table.count <= 1` guard is the dirty flag — with only `:default`
/// registered no value pays a classOf/getMethod. Any dispatch error (ambiguous)
/// degrades to null = native render: printing never raises a dispatch error.
fn printMethodOverride(rt: *Runtime, v: Value) ?Value {
    const varp = print_method_var orelse return null;
    const mfv = varp.deref();
    if (mfv.tag() != .multi_fn) return null;
    const mf = mfv.decodePtr(*multimethod.MultiFn);
    if (map_collection.count(mf.method_table) <= 1) return null; // only :default registered
    const cls = class_of.classOf(rt, v) catch return null;
    const default_m = map_collection.get(mf.method_table, mf.default_dispatch_val) catch return null;
    const m = multimethod.getMethod(rt, mf, cls, .{}) catch return null;
    if (m.tag() == .nil) return null;
    if (@intFromEnum(m) == @intFromEnum(default_m)) return null; // resolved to :default
    return m;
}

/// The active consult context for the current top-level print (ADR-0127 B2(b-ii)):
/// set by `printConsult` ONLY when a non-default `print-method` override is
/// registered (the dirty flag). While set, `printValue` consults `print-method`
/// per value — so an override-typed value nested inside a NATIVE collection (e.g.
/// `(pr [(->T)])`) renders via the user method, matching clj's per-element
/// recursion. Null otherwise ⇒ the pure native path, zero overhead (the common +
/// bootstrap case). Threadlocal so a concurrent print on another thread is unaffected.
threadlocal var active_consult: ?struct { rt: *Runtime, env: *env_mod.Env } = null;

/// Is ANY non-default `print-method` override registered? (The dirty flag — gates
/// whether `active_consult` is armed at all, so the no-override path never consults.)
fn anyPrintMethodOverride() bool {
    const varp = print_method_var orelse return false;
    const mfv = varp.deref();
    if (mfv.tag() != .multi_fn) return false;
    return map_collection.count(mfv.decodePtr(*multimethod.MultiFn).method_table) > 1;
}

/// Fire `v`'s `print-method` override into `w` (mints a single-print-scoped writer
/// handle, A2), or return false when `v` has no non-default override.
fn fireOverride(rt: *Runtime, env: *env_mod.Env, w: *Writer, v: Value) anyerror!bool {
    const method = printMethodOverride(rt, v) orelse return false;
    const vt = rt.vtable orelse return false;
    const wv = try writer_value.mint(rt, w);
    defer writer_value.invalidate(wv);
    _ = try vt.callFn(rt, env, method, &.{ v, wv }, .{});
    return true;
}

/// Print `v` to `w`, consulting `print-method` first (ADR-0127). A type with a
/// non-default override renders via the user method; every other value renders
/// natively. The pr/prn/print entry points call this; it arms `active_consult` (so
/// nested native-collection elements also consult — B2(b-ii)) ONLY when an override
/// exists. `printResult`/`printValueNative` stay native (they ARE the `:default`),
/// the recursion guard against an override re-firing on its own value.
pub fn printConsult(rt: *Runtime, env: *env_mod.Env, w: *Writer, v: Value) anyerror!void {
    if (!anyPrintMethodOverride()) {
        try printResult(rt, env, w, v); // no override anywhere → pure native fast path
        return;
    }
    const saved = active_consult;
    active_consult = .{ .rt = rt, .env = env };
    defer active_consult = saved;
    if (try fireOverride(rt, env, w, v)) return;
    try printResult(rt, env, w, v);
}

/// `(rt/__print-method-default o w)` — the `print-method` `:default` body. Unwraps
/// the writer handle and renders `o` NATIVELY via `printResult` (which does NOT
/// consult print-method), so a user method recursing `(print-method child w)` that
/// lands here terminates. Bypassing the consult on the same value is the ADR-0127
/// recursion invariant.
pub fn printMethodDefaultFn(rt: *Runtime, env: *env_mod.Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len != 2)
        return @import("error/catalog.zig").raise(.arity_not_expected, loc, .{ .got = args.len, .fn_name = "print-method", .expected = 2 });
    const w = writer_value.unwrap(args[1]) orelse
        return @import("error/catalog.zig").raise(.type_arg_invalid, loc, .{ .fn_name = "print-method", .expected = "a writer", .actual = @tagName(args[1].tag()) });
    // printValueNative (NOT printValue): render `o` itself WITHOUT re-consulting its
    // own override (which just dispatched here), the ADR-0127 recursion guard; its
    // child elements still consult via the printValue calls inside printValueNative.
    try printValueNative(w, try deepRealize(rt, env, args[0]));
    return .nil_val;
}

/// `*print-meta*` snapshot for the current top-level print (false default).
threadlocal var print_meta: bool = false;

/// The metadata map of `v` for `*print-meta*` printing, or nil when `v` carries
/// none / is not a meta-bearing type. Mirrors `metaFn`'s collection arms (cljw
/// symbols are not meta-bearing, so only collections matter here).
fn metaForPrint(v: Value) Value {
    return switch (v.tag()) {
        .vector => vector_collection.metaOf(v),
        .array_map, .hash_map => map_collection.metaOf(v),
        .hash_set => set_collection.metaOf(v),
        .list => list_collection.metaOf(v),
        else => Value.nil_val,
    };
}

/// Snapshot of the two limits for the duration of one top-level print
/// (ADR-0088 decision 3 — deref once at the surface, not per element). null =
/// unlimited (the var is unbound / nil / non-integer). `print_depth` is the
/// current collection-nesting depth (root collection = 0) used by
/// `*print-level*`.
threadlocal var print_length_limit: ?i64 = null;
threadlocal var print_level_limit: ?i64 = null;
threadlocal var print_depth: i64 = 0;

fn limitFromVar(maybe_v: ?*const env_mod.Var) ?i64 {
    const v = maybe_v orelse return null;
    const cur = v.deref();
    return if (cur.tag() == .integer) cur.asInteger() else null;
}

/// Read both limits from their Vars and reset depth — called once at each
/// top-level print entry (`printResult`). Runs inside the user's `binding`
/// extent, so the single deref reflects the current dynamic value.
fn snapshotPrintLimits() void {
    print_length_limit = limitFromVar(print_length_var);
    print_level_limit = limitFromVar(print_level_var);
    print_depth = 0;
    // *print-namespace-maps* (D-222 a): truthy → compact `#:ns{…}`. Root is
    // true, so the default snapshot keeps today's behaviour; only an explicit
    // false binding disables it.
    if (print_namespace_maps_var) |v| {
        const d = v.deref();
        print_namespace_maps = !(d.isNil() or (d.tag() == .boolean and !d.asBoolean()));
    }
    // *print-readably* (D-222 a): override the surface-set flag ONLY when the
    // user explicitly thread-bound the var (findBinding non-null) — otherwise the
    // pr/print surface owns it. nil/false → raw (un-readable) rendering.
    if (print_readably_var) |v| {
        if (env_mod.findBinding(v)) |bv| {
            print_readably = !(bv.isNil() or (bv.tag() == .boolean and !bv.asBoolean()));
        }
    }
    // *print-meta* (default false): truthy → prefix metadata-bearing values.
    print_meta = false;
    if (print_meta_var) |v| {
        const d = v.deref();
        print_meta = !(d.isNil() or (d.tag() == .boolean and !d.asBoolean()));
    }
}

/// True iff a `Value.Tag` nests for `*print-level*` purposes (every printed
/// collection, including a `.map_entry` which renders as the 2-vector `[k v]`).
fn isCollectionTag(t: Value.Tag) bool {
    return switch (t) {
        .list, .range, .vector, .map_entry, .persistent_queue, .hash_set, .sorted_set, .sorted_map, .array_map, .hash_map => true,
        else => false,
    };
}

/// `*print-length*` guard for index-driven collection loops: when the limit is
/// reached at element `i`, emit `sep` (only if not the first element) + `...`
/// and return true so the loop breaks. Returns false (no truncation) when the
/// limit is unset or not yet reached.
fn lengthTruncated(w: *Writer, i: i64, sep: []const u8) Writer.Error!bool {
    const lim = print_length_limit orelse return false;
    if (i < lim) return false;
    if (i > 0) try w.writeAll(sep);
    try w.writeAll("...");
    return true;
}

/// The shared namespace of an array_map's keys (D-219), or null when the map
/// is empty, any key is not a keyword/symbol, any key has no namespace, or the
/// namespaces differ. Scoped to `.array_map` (small, insertion-ordered maps —
/// the overwhelmingly common namespaced-map shape, and the one whose key order
/// matches clj). A `.hash_map` (>8 keys) already prints in cljw HAMT order, not
/// clj's (AD-001), so the compact form there gives no parity benefit and is
/// skipped. Used to decide the compact `#:ns{…}` print form.
fn mapCommonNs(v: Value) ?[]const u8 {
    if (v.tag() != .array_map) return null;
    const am = v.decodePtr(*const map_collection.ArrayMap);
    if (am.count == 0) return null;
    var common: ?[]const u8 = null;
    var i: u32 = 0;
    while (i < am.count) : (i += 1) {
        const key = am.entries[2 * i];
        const kns: ?[]const u8 = switch (key.tag()) {
            .keyword => keyword.asKeyword(key).ns,
            .symbol => symbol.asSymbol(key).ns,
            else => return null,
        };
        const n = kns orelse return null;
        if (common) |c| {
            if (!std.mem.eql(u8, c, n)) return null;
        } else common = n;
    }
    return common;
}

/// Print a map key, omitting its namespace when `strip` (the compact
/// `#:ns{…}` form already carries the shared namespace). Non-symbolic keys
/// are unaffected by `strip`.
fn printMapKey(w: *Writer, key: Value, strip: bool) anyerror!void {
    if (!strip) return printValue(w, key);
    switch (key.tag()) {
        .keyword => {
            try w.writeByte(':');
            try w.writeAll(keyword.asKeyword(key).name);
        },
        .symbol => try w.writeAll(symbol.asSymbol(key).name),
        else => try printValue(w, key),
    }
}

/// Print `v`, consulting `print-method` first when `active_consult` is armed (an
/// override is registered, ADR-0127 B2(b-ii)) — so a nested override-typed value
/// renders via the user method. Otherwise (the common case) a direct native render.
/// Collection printers recurse through THIS fn, so every element consults uniformly.
pub fn printValue(w: *Writer, v: Value) anyerror!void {
    if (active_consult) |ctx| {
        if (try fireOverride(ctx.rt, ctx.env, w, v)) return;
    }
    try printValueNative(w, v);
}

/// The native renderer (the `print-method` `:default`): the big tag `switch`, NO
/// top-level consult on `v` itself (the recursion guard — `__print-method-default`
/// and the no-override path land here). Child elements recurse via `printValue`,
/// which re-arms the consult per element.
fn printValueNative(w: *Writer, v: Value) anyerror!void {
    const vtag = v.tag();
    // *print-level* (ADR-0088): a collection at nesting depth `d` (root = 0)
    // renders as a bare `#` when `d >= level`. The check + depth bookkeeping is
    // centralised here (one site) for every collection tag; scalars never count.
    const is_coll = isCollectionTag(vtag);
    if (is_coll) {
        if (print_level_limit) |lvl| {
            if (print_depth >= lvl) return w.writeByte('#');
        }
        print_depth += 1;
    }
    defer if (is_coll) {
        print_depth -= 1;
    };
    // *print-meta* (ADR-0088 family): emit a `^{meta} ` prefix for any value
    // carrying non-empty metadata. The `if (print_meta)` guard short-circuits by
    // default so the common path is unchanged.
    if (print_meta) {
        const m = metaForPrint(v);
        if (!m.isNil() and map_collection.count(m) > 0) {
            try w.writeByte('^');
            try printValue(w, m);
            try w.writeByte(' ');
        }
    }
    switch (vtag) {
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
        // A MapEntry prints as the 2-vector `[k v]` (D-209 / ADR-0078).
        .map_entry => {
            try w.writeByte('[');
            try printValue(w, map_entry_collection.keyOf(v));
            try w.writeByte(' ');
            try printValue(w, map_entry_collection.valOf(v));
            try w.writeByte(']');
        },
        .persistent_queue => try printQueue(w, v),
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
        .ns => try printNamespace(w, v),
        .regex => {
            // `#"<source>"` for every printer that routes through `print-method`
            // — pr / prn / print / println all show the reader form (JVM
            // `print-method Pattern`). Only `str` (Pattern.toString → the raw
            // pattern) differs, and `strFn` special-cases regex before reaching
            // here. The source is shown verbatim (not re-escaped).
            try w.writeAll("#\"");
            try w.writeAll(regex_mod.asRegex(v).source());
            try w.writeByte('"');
        },
        .uuid => {
            // `#uuid "<canonical>"` for every print-method path (pr / prn /
            // print / println) — the reader form, so EDN round-trips. Only
            // `str` (UUID.toString → the bare canonical) differs, and `strFn`
            // special-cases `.uuid` before reaching here (ADR-0074).
            const canon = uuid_mod.canonicalOf(v);
            try w.writeAll("#uuid \"");
            try w.writeAll(&canon);
            try w.writeByte('"');
        },
        .tagged_literal => {
            // `#<tag> <form>` (ADR-0075) — EDN round-trips. tag is a symbol,
            // form any value; both via the same readable printer.
            const tl = tagged_literal_mod.asTaggedLiteral(v);
            try w.writeByte('#');
            try printValue(w, tl.tag);
            try w.writeByte(' ');
            try printValue(w, tl.form);
        },
        // ADR-0106 / AD-020: a stateful host object prints opaquely by its
        // surface fqcn (e.g. `#<java.util.Random>`) — clj prints an identity
        // hash cljw cannot mirror.
        .host_instance => try w.print("#<{s}>", .{@import("host_instance.zig").asHostInstance(v).descriptor.fqcn orelse "host_instance"}),
        // ADR-0121 / AD-025: callable values print `#<ns/name>`, not the leaked
        // internal tag (`#<fn_val>`). `.fn_val` is read via the eval-injected
        // accessor (its Function is Layer 1); `.multi_fn` / `.protocol_fn` are
        // Layer-0 structs read directly.
        .fn_val => {
            const id = if (fn_name_accessor) |acc| acc(v) else FnIdentity{};
            try printCallable(w, id.ns, id.name);
        },
        .multi_fn => {
            const sym = symbol.asSymbol(v.decodePtr(*const multimethod.MultiFn).name);
            try printCallable(w, sym.ns, sym.name);
        },
        .protocol_fn => {
            const pf = protocol.asProtocolFn(v);
            try printCallable(w, pf.descriptor.fqcn(), pf.methodName());
        },
        else => |t| try w.print("#<{s}>", .{@tagName(t)}),
    }
}

fn printBigInt(w: *Writer, v: Value) anyerror!void {
    // A heap integer's Managed renders just the digits; the `N` suffix
    // marks a genuine BigInt. A heap-boxed Long (D-165 / ADR-0080) prints
    // WITHOUT `N` (it is a primitive Long that merely overflowed cljw's i48
    // inline range), matching clj `(parse-long "999999999999999")`.
    const m = big_int_mod.asManaged(v);
    if (big_int_mod.originOf(v) == .long) {
        try w.print("{f}", .{m});
    } else {
        try w.print("{f}N", .{m});
    }
}

fn printRatio(w: *Writer, v: Value) anyerror!void {
    // Render numerator `/` denominator without a trailing `N` (ADR-0149: small =
    // inline i64s; big = the stored BigInt Manageds via `{f}`).
    switch (ratio_mod.parts(v)) {
        .small => |s| try w.print("{d}/{d}", .{ s.n, s.d }),
        .big => |b| try w.print("{f}/{f}", .{ b.n.m, b.d.m }),
    }
}

fn printBigDecimal(w: *Writer, v: Value) anyerror!void {
    try writeBigDecimalDigits(w, v);
    // The trailing `M` is the clj reader form (pr/prn). `str`/`.toString`
    // drop it (JVM `BigDecimal.toString` has no suffix) — D-212.
    try w.writeByte('M');
}

pub fn writeBigDecimalDigits(w: *Writer, v: Value) anyerror!void {
    // value = unscaled * 10^(-scale). Reproduces JVM `BigDecimal.toString`:
    // plain notation when `scale >= 0` AND the adjusted exponent
    // `(precision-1) - scale >= -6`, otherwise scientific `d.dddE±exp`.
    const bd = v.decodePtr(*const big_decimal_mod.BigDecimal);

    // Render unscaled digits into a scratch buffer; split off the sign.
    var buf: [1024]u8 = undefined;
    var sw: std.Io.Writer = .fixed(&buf);
    sw.print("{f}", .{bd.unscaled.m}) catch {
        // Unscaled wider than the buffer — fall back to the lossy form
        // (digits only; the caller appends `M` for the reader form).
        return w.print("{f}", .{bd.unscaled.m});
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
}

/// Render an IPersistentMap-declaring deftype map-style `{k v, …}` from its
/// `-seq`, in SEQ ORDER (clj: core_print's defmethod on the clojure.lang
/// interface class — data.priority-map prints in priority order). Needs
/// `realize_ctx` (rt/env for the -seq dispatch + entry realization); without
/// it the caller falls back to the default `#Name[…]` render. Returns false
/// when the type has no dispatchable `-seq`.
fn printMapLikeTypedInstance(rt: *Runtime, env: *env_mod.Env, w: *Writer, v: Value) anyerror!bool {
    var cs: dispatch_mod.CallSite = .{};
    const noloc: SourceLocation = .{};
    const s = (try dispatch_mod.dispatchOrNull(rt, env, &cs, v, "Seqable", "-seq", &.{v}, noloc)) orelse return false;
    const entries = try realizeSeqWalk(rt, env, s);
    try w.writeByte('{');
    var node = entries;
    var i: i64 = 0;
    while (node.tag() == .list and list_collection.countOf(node) > 0) : (node = list_collection.rest(node)) {
        if (try lengthTruncated(w, i, ", ")) break;
        if (i > 0) try w.writeAll(", ");
        const e = list_collection.first(node);
        const k = if (e.tag() == .map_entry) map_entry_collection.keyOf(e) else vector_collection.nth(e, 0);
        const val = if (e.tag() == .map_entry) map_entry_collection.valOf(e) else vector_collection.nth(e, 1);
        try printValue(w, try deepRealize(rt, env, k));
        try w.writeByte(' ');
        try printValue(w, try deepRealize(rt, env, val));
        i += 1;
    }
    try w.writeByte('}');
    return true;
}

/// `map.forEachEntry` accumulator for a record's extmap (D-086): print each
/// `<k> <v>` after the declared fields, comma-separated. `printed` tracks how
/// many entries (declared + prior extmap) are already out so the comma lands.
const ExtmapPrintCtx = struct {
    w: *Writer,
    printed: usize,
    fn cb(ctx: *ExtmapPrintCtx, k: Value, val: Value) anyerror!void {
        if (ctx.printed > 0) try ctx.w.writeAll(", ");
        try printValue(ctx.w, k);
        try ctx.w.writeByte(' ');
        try printValue(ctx.w, val);
        ctx.printed += 1;
    }
};

fn printTypedInstance(w: *Writer, v: Value) anyerror!void {
    const inst = v.decodePtr(*const td_mod.TypedInstance);
    // A deftype declaring clojure.lang.IPersistentMap prints map-style when a
    // realize context is available (printResult arms it; the pure printValue
    // paths keep the default render).
    if (inst.descriptor.kind != .defrecord and inst.descriptor.declaresProtocol("IPersistentMap")) {
        if (realize_ctx) |ctx| {
            if (try printMapLikeTypedInstance(ctx.rt, ctx.env, w, v)) return;
        }
    }
    // Reader-tag host value (ADR-0079): emit `#<tag> "<iso>"`. Today only
    // `#inst` (java.util.Date) — body = the epoch-ms field 0 as the
    // canonical ISO string. Descriptor-driven (no rt, no surface import).
    if (inst.descriptor.print_tag) |tag| {
        if (inst.field_count >= 1 and inst.fields()[0].tag() == .integer) {
            var buf: [48]u8 = undefined;
            const epoch_ms = inst.fields()[0].asInteger();
            // A 2-field inst value is a Timestamp (epoch-ms + nanos, D-382) →
            // 9-digit fraction; a 1-field one is a Date → 3-digit ms.
            const iso = if (inst.field_count >= 2 and inst.fields()[1].tag() == .integer)
                instant_mod.formatInstantNanos(&buf, epoch_ms, @intCast(inst.fields()[1].asInteger()))
            else
                instant_mod.formatInstantMillis(&buf, epoch_ms);
            try w.print("#{s} \"{s}\"", .{ tag, iso });
            return;
        }
    }
    const fqcn = inst.descriptor.fqcn orelse "<anonymous>";
    // A record prints map-style `#Name{:k v, …}` from its declared field
    // layout (D-190 / ADR-0068) + any extmap entries (D-086 / ADR-0154). The
    // SIMPLE name (no clj `user.` ns prefix) is the accepted divergence AD-035
    // (cljw carries only a simple `fqcn`, the AD-003 no-JVM-Class surface).
    if (inst.descriptor.kind == .defrecord) {
        if (inst.descriptor.field_layout) |layout| {
            const fs = inst.fields();
            try w.print("#{s}{{", .{fqcn});
            for (layout, 0..) |fe, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print(":{s} ", .{fe.name});
                try printValue(w, fs[fe.index]);
            }
            // D-086 / ADR-0154: non-declared keys (extmap) print after the
            // declared fields — `#R{:x 1, :y 2, :z 9}`. (The `#R` vs clj's
            // `#user.R` ns prefix is the accepted divergence AD-035.)
            if (!inst.extmap.isNil()) {
                var ctx = ExtmapPrintCtx{ .w = w, .printed = layout.len };
                try map_collection.forEachEntry(inst.extmap, &ctx, ExtmapPrintCtx.cb);
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
fn printTypeDescriptor(w: *Writer, v: Value) anyerror!void {
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
fn printVarRef(w: *Writer, v: Value) anyerror!void {
    const var_ptr = v.decodePtr(*const env_mod.Var);
    try w.print("#'{s}/{s}", .{ var_ptr.ns.name, var_ptr.name });
}

/// Render an `.ns` (Namespace) Value. clj prints `#object[clojure.lang.Namespace
/// 0x.. "user"]`; cljw is no-JVM and cannot mirror the identity hash, so it
/// emits `#object[Namespace "user"]` (AD-010, derives_from ADR-0059 + AD-002).
/// `(str *ns*)` → bare "user" is handled by `strFn`'s special-case (like regex /
/// uuid), so this readable form is only reached by pr / prn / print / println.
fn printNamespace(w: *Writer, v: Value) anyerror!void {
    const ns_ptr = v.decodePtr(*const env_mod.Namespace);
    try w.print("#object[Namespace \"{s}\"]", .{ns_ptr.name});
}

/// Render an `ex-info` Value in `#error{ :message "..." :data ... }`
/// form — the same shape Clojure JVM's pr-str emits, modulo ordering.
/// The data field is any Value, rendered via `printValue`.
pub fn printExInfo(w: *Writer, v: Value) anyerror!void {
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
/// `#queue (e1 e2 …)` — a reader-round-trippable form (ADR-0087). clj prints
/// the opaque non-reproducible `#object[…@hash]`; cljw ships a readable form +
/// a matching `queue` data-reader. Walks front (list) then rear (vector).
pub fn printQueue(w: *Writer, v: Value) anyerror!void {
    try w.writeAll("#queue (");
    var first_iter = true;
    var emitted: i64 = 0;
    var truncated = false;
    var cur = persistent_queue.frontOf(v);
    while (cur.tag() == .list and list_collection.countOf(cur) > 0) {
        if (try lengthTruncated(w, emitted, " ")) {
            truncated = true;
            break;
        }
        if (!first_iter) try w.writeByte(' ');
        first_iter = false;
        try printValue(w, list_collection.first(cur));
        cur = list_collection.rest(cur);
        emitted += 1;
    }
    if (!truncated) {
        const rear = persistent_queue.rearOf(v);
        if (!rear.isNil()) {
            var i: u32 = 0;
            const n = vector_collection.count(rear);
            while (i < n) : (i += 1) {
                if (try lengthTruncated(w, emitted, " ")) break;
                if (!first_iter) try w.writeByte(' ');
                first_iter = false;
                try printValue(w, vector_collection.nth(rear, i));
                emitted += 1;
            }
        }
    }
    try w.writeByte(')');
}

pub fn printList(w: *Writer, v: Value) anyerror!void {
    try w.writeByte('(');
    var cur = v;
    var first_iter = true;
    var emitted: i64 = 0;
    while (cur.tag() == .list and list_collection.countOf(cur) > 0) {
        if (try lengthTruncated(w, emitted, " ")) break;
        if (!first_iter) try w.writeByte(' ');
        first_iter = false;
        try printValue(w, list_collection.first(cur));
        cur = list_collection.rest(cur);
        emitted += 1;
    }
    try w.writeByte(')');
}

/// Render a compact `.range` as a list `(0 1 2 …)` (JVM parity). Computes
/// each element with pure scalar math (`start + i*step`) so it needs no
/// `rt` and allocates nothing — unlike a generic seq-walk. A huge range
/// prints every element (same as realizing a lazy seq).
pub fn printRange(w: *Writer, v: Value) anyerror!void {
    try w.writeByte('(');
    const n = range_collection.countOf(v);
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        if (try lengthTruncated(w, i, " ")) break;
        if (i > 0) try w.writeByte(' ');
        try printValue(w, range_collection.elementAt(v, i));
    }
    try w.writeByte(')');
}

/// Render a heap Vector in `[a b c]` form. Indexes via
/// `vector_collection.nth` so this stays decoupled from the HAMT
/// internals.
pub fn printVector(w: *Writer, v: Value) anyerror!void {
    try w.writeByte('[');
    const n = vector_collection.count(v);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (try lengthTruncated(w, @intCast(i), " ")) break;
        if (i > 0) try w.writeByte(' ');
        try printValue(w, vector_collection.nth(v, i));
    }
    try w.writeByte(']');
}

/// Render a map in `{k v k v ...}` form.
/// Walk a HAMT node pre-order, writing each entry. `kv` true → "k v"
/// pairs (map), false → bare elements (set). `first` threads the
/// separator across the recursion. Alloc-free — the printer has no
/// allocator, so it reads `slots` directly rather than materialising a
/// seq (front-loaded KV pairs, back-loaded children per map.zig).
fn printHamtEntries(w: *Writer, node: *const map_collection.HamtMapNode, first: *bool, count: *i64, stop: *bool, comptime kv: bool) anyerror!void {
    const data_count = @popCount(node.data_map);
    var i: u32 = 0;
    while (i < data_count) : (i += 1) {
        if (stop.*) return;
        // *print-length* (ADR-0088): emit `...` (with separator unless first)
        // once the entry count reaches the limit, then stop the recursion.
        if (print_length_limit) |lim| if (count.* >= lim) {
            if (!first.*) try w.writeAll(if (kv) ", " else " ");
            try w.writeAll("...");
            stop.* = true;
            return;
        };
        if (!first.*) try w.writeAll(if (kv) ", " else " ");
        first.* = false;
        try printValue(w, node.slots[2 * i]);
        if (kv) {
            try w.writeByte(' ');
            try printValue(w, node.slots[2 * i + 1]);
        }
        count.* += 1;
    }
    const child_count = @popCount(node.node_map);
    var j: u32 = 0;
    while (j < child_count) : (j += 1) {
        if (stop.*) return;
        try printHamtEntries(w, node.slots[63 - j].decodePtr(*const map_collection.HamtMapNode), first, count, stop, kv);
    }
}

pub fn printMap(w: *Writer, v: Value) anyerror!void {
    // Compact namespaced-map form `#:ns{:a 1, :b 2}` (D-219) when enabled and
    // all keys share one namespace (array_map only — see `mapCommonNs`).
    const compact_ns: ?[]const u8 = if (print_namespace_maps) mapCommonNs(v) else null;
    if (compact_ns) |ns| {
        try w.writeAll("#:");
        try w.writeAll(ns);
    }
    const strip = compact_ns != null;
    try w.writeByte('{');
    if (v.tag() == .array_map) {
        const am = v.decodePtr(*const map_collection.ArrayMap);
        var i: u32 = 0;
        while (i < am.count) : (i += 1) {
            if (try lengthTruncated(w, @intCast(i), ", ")) break;
            if (i > 0) try w.writeAll(", ");
            try printMapKey(w, am.entries[2 * i], strip);
            try w.writeByte(' ');
            try printValue(w, am.entries[2 * i + 1]);
        }
    } else {
        const phm = v.decodePtr(*const map_collection.PersistentHashMap);
        if (phm.root) |root| {
            var first = true;
            var count: i64 = 0;
            var stop = false;
            try printHamtEntries(w, root, &first, &count, &stop, true);
        }
    }
    try w.writeByte('}');
}

/// Render a PersistentHashSet in `#{a b c}` form. Walks the backing
/// map's keys directly: an `array_map`'s `entries` array (≤ 8
/// elements, insertion order) or the HAMT keys for a larger
/// `hash_map`-backed set.
pub fn printSet(w: *Writer, v: Value) anyerror!void {
    try w.writeAll("#{");
    const s = v.decodePtr(*const set_collection.PersistentHashSet);
    if (s.map.tag() == .array_map) {
        const am = s.map.decodePtr(*const map_collection.ArrayMap);
        var i: u32 = 0;
        while (i < am.count) : (i += 1) {
            if (try lengthTruncated(w, @intCast(i), " ")) break;
            if (i > 0) try w.writeByte(' ');
            try printValue(w, am.entries[2 * i]);
        }
    } else {
        // hash_map-backed set (> 8 elements): walk the backing map's HAMT
        // keys directly (the set stores each element as a map key).
        const phm = s.map.decodePtr(*const map_collection.PersistentHashMap);
        if (phm.root) |root| {
            var first = true;
            var count: i64 = 0;
            var stop = false;
            try printHamtEntries(w, root, &first, &count, &stop, false);
        }
    }
    try w.writeByte('}');
}

/// In-order (ascending) walk of an LLRB tree, alloc-free (the printer has
/// no allocator). `kv` true → "k v" pairs (map), false → bare keys (set).
fn printSortedEntries(w: *Writer, root: Value, first: *bool, count: *i64, stop: *bool, comptime kv: bool) anyerror!void {
    if (root.tag() != .rb_node) return;
    if (stop.*) return;
    const n = root.decodePtr(*const sorted_collection.RbNode);
    try printSortedEntries(w, n.left, first, count, stop, kv);
    if (stop.*) return;
    // *print-length* (ADR-0088): in ascending order, stop emitting once the
    // count reaches the limit (mark the cut with `...`).
    if (print_length_limit) |lim| if (count.* >= lim) {
        if (!first.*) try w.writeAll(if (kv) ", " else " ");
        try w.writeAll("...");
        stop.* = true;
        return;
    };
    if (!first.*) try w.writeAll(if (kv) ", " else " ");
    first.* = false;
    try printValue(w, n.key);
    if (kv) {
        try w.writeByte(' ');
        try printValue(w, n.val);
    }
    count.* += 1;
    try printSortedEntries(w, n.right, first, count, stop, kv);
}

pub fn printSortedMap(w: *Writer, v: Value) anyerror!void {
    try w.writeByte('{');
    const m = v.decodePtr(*const sorted_collection.SortedMap);
    var first = true;
    var count: i64 = 0;
    var stop = false;
    try printSortedEntries(w, m.root, &first, &count, &stop, true);
    try w.writeByte('}');
}

pub fn printSortedSet(w: *Writer, v: Value) anyerror!void {
    try w.writeAll("#{");
    const s = v.decodePtr(*const sorted_collection.SortedSet);
    const m = s.map.decodePtr(*const sorted_collection.SortedMap);
    var first = true;
    var count: i64 = 0;
    var stop = false;
    try printSortedEntries(w, m.root, &first, &count, &stop, false);
    try w.writeByte('}');
}

/// Render `s` in Clojure `pr-str` style: surrounding double quotes,
/// with `\n` / `\t` / `\r` / `\\` / `\"` escape sequences. Other
/// bytes are passed through as-is — `(read-string (pr-str s))` round-
/// trips for ASCII-clean inputs (matches the Reader's `unescapeString`
/// table at §9.4 / 1.9).
pub fn printString(w: *Writer, s: []const u8) anyerror!void {
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
    const inner = try list_collection.consHeap(&rt, Value.initInteger(2), try list_collection.consHeap(&rt, Value.initInteger(3), .nil_val));
    const nested = try list_collection.consHeap(&rt, Value.initInteger(1), try list_collection.consHeap(&rt, inner, .nil_val));
    try testing.expectEqualStrings("(1 (2 3))", try renderToBuf(&buf, nested));
}

test "unhandled heap tag falls back to #<tag>" {
    // Synthesise an `.rb_node` Value (an internal LLRB tree node, never
    // user-printed → no dedicated arm, stable `else`-routed stand-in). We use
    // the encodeHeapPtr API directly with a stack-allocated dummy that never
    // gets dereferenced — printValue's else-arm only reads the Value's tag,
    // never the pointee. (`.fn_val` was the prior stand-in; ADR-0121 gave it a
    // real arm, so it no longer exercises the fallback.)
    const Dummy = extern struct { _: u64 align(8) = 0 };
    var dummy: Dummy = .{};
    const v = Value.encodeHeapPtr(.rb_node, &dummy);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("#<rb_node>", try renderToBuf(&buf, v));
}

test "printCallable renders #<ns/name>, #<name>, and #<fn> (ADR-0121)" {
    var buf: [64]u8 = undefined;
    {
        var w: Writer = .fixed(&buf);
        try printCallable(&w, "user", "boom");
        try testing.expectEqualStrings("#<user/boom>", w.buffered());
    }
    {
        var w: Writer = .fixed(&buf);
        try printCallable(&w, null, "boom");
        try testing.expectEqualStrings("#<boom>", w.buffered());
    }
    {
        var w: Writer = .fixed(&buf);
        try printCallable(&w, "user", null);
        try testing.expectEqualStrings("#<user/fn>", w.buffered());
    }
    {
        var w: Writer = .fixed(&buf);
        try printCallable(&w, null, null);
        try testing.expectEqualStrings("#<fn>", w.buffered());
    }
}

test "a .fn_val with no accessor installed falls back to #<fn> (ADR-0121)" {
    // Mirrors the unhandled-tag stand-in but exercises the .fn_val arm's
    // null-accessor path: the arm reads only the tag + calls the accessor (null
    // here → FnIdentity{}), never the pointee.
    const prev = fn_name_accessor;
    fn_name_accessor = null;
    defer fn_name_accessor = prev;
    const Dummy = extern struct { _: u64 align(8) = 0 };
    var dummy: Dummy = .{};
    const v = Value.encodeHeapPtr(.fn_val, &dummy);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("#<fn>", try renderToBuf(&buf, v));
}
