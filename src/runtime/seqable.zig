// SPDX-License-Identifier: EPL-2.0
//! The Seqable / ISeq boundary: clj `RT.seq` / `RT.first` / `RT.more` /
//! `RT.next` as ONE Layer-0 definition (ADR-0197).
//!
//! `seq` maps every value to its seq (nil when empty); `first` / `rest` /
//! `next` read a value through that seq. The native tag set is closed, so it
//! is a switch; the open set (deftype / reify / host instance / `extend-type`
//! on a native tag) reaches user code through protocol dispatch
//! (`Seqable/-seq`, `ISeq/-first|-rest|-next`). An open value with no `-seq`
//! that is a CharSequence (java.lang.StringBuilder, instaparse's Segment)
//! seqs as its chars, RT.seqFrom's CharSequence arm (char_sequence.zig).
//!
//! Projections: `clojure.core/seq|first|rest|next` (`lang/primitive/
//! sequence.zig`) are arity checks over these; `lazy_seq.zig` realizes a lazy
//! body through `seq` (the `RT.seq` inside `LazySeq.realize`); `equal.zig`,
//! `print.zig`, `java.util.Iterator` and the sorted/csv primitives walk seqs
//! with the same three accessors.
//!
//! Contracts: `rest` never returns nil (the interned `()` stands in, JVM
//! `ISeq.more`); `next` is `seq(rest(v))`, so an empty lazy tail collapses to
//! nil; a value that is not seqable raises `protocol_no_satisfies`
//! (`Seqable/-seq`) from every accessor, the JVM `RT.seqFrom`
//! IllegalArgumentException.
//!
//! GC: incoming values are rooted by the caller. Native collection builders
//! retain their fabrication discipline; view construction can collect before
//! allocation. Fresh seq cursors returned by coercion are published in manual
//! frames before tail access allocates or invokes user code. A caller holding
//! other live values across these calls roots them itself.

const std = @import("std");
const Value = @import("value/value.zig").Value;
const Runtime = @import("runtime.zig").Runtime;
const Env = @import("env.zig").Env;
const SourceLocation = @import("error/info.zig").SourceLocation;
const error_catalog = @import("error/catalog.zig");
const dispatch = @import("dispatch.zig");
const class_name = @import("class_name.zig");
const root_set = @import("gc/root_set.zig");
const td_mod = @import("type_descriptor.zig");
const keyword_mod = @import("keyword.zig");
const charset = @import("charset.zig");
const lazy_seq = @import("lazy_seq.zig");
const list = @import("collection/list.zig");
const vector = @import("collection/vector.zig");
const sub_vector = @import("collection/sub_vector.zig");
const array_seq = @import("collection/array_seq.zig");
const string_seq = @import("collection/string_seq.zig");
const string_collection = @import("collection/string.zig");
const chunked_cons = @import("collection/chunked_cons.zig");
const range = @import("collection/range.zig");
const map = @import("collection/map.zig");
const map_entry = @import("collection/map_entry.zig");
const set = @import("collection/set.zig");
const sorted = @import("collection/sorted.zig");
const persistent_queue = @import("collection/persistent_queue.zig");
const char_sequence = @import("char_sequence.zig");

/// Protocol names the boundary dispatches on. Bootstrap declares each protocol
/// in `lang/clj/clojure/core.clj`, so the fqcn stored at extend-type time is
/// the bare symbol name. Every site that names these protocols reads them here.
pub const SEQABLE: []const u8 = "Seqable";
pub const ISEQ: []const u8 = "ISeq";

/// A location for callers that have none (equality, printing, iterators).
pub const noloc: SourceLocation = .{};

/// `(seq v)`: nil, or a seq over `v`'s elements. JVM `RT.seq`.
pub fn seq(rt: *Runtime, env: *Env, v: Value, loc: SourceLocation) anyerror!Value {
    return switch (v.tag()) {
        .nil => .nil_val,
        // PERF: views, not copies. A string / vector / Java array seq is two
        // words (backing + cursor); `make` answers nil when the view would be
        // empty. [refs: O-058, O-060, D-179]
        .string => try string_seq.make(rt, v, 0),
        .vector, .sub_vector, .array => try array_seq.make(rt, v, 0),
        // Already a seq.
        .string_seq, .array_seq, .chunked_cons => v,
        .list, .cons => list.seq(v),
        // A MapEntry seqs as `(key val)` (D-209 / ADR-0078).
        .map_entry => try list.consHeap(rt, map_entry.keyOf(v), try list.consHeap(rt, map_entry.valOf(v), .nil_val)),
        .array_map, .hash_map => if (map.count(v) > 0) try map.seq(rt, v) else .nil_val,
        .sorted_map, .sorted_set => if (sorted.count(v) > 0) try sorted.seq(rt, v) else .nil_val,
        .hash_set => if (set.count(v) > 0) try set.seq(rt, v) else .nil_val,
        .persistent_queue => try persistent_queue.seqOf(rt, v),
        // A range's seq view is a chunked_cons (<= 32 materialised + a smaller
        // `.range` tail); a live range is never empty.
        .range => try range.seqChunk(rt, v),
        .lazy_seq => try lazy_seq.seq(rt, env, v, loc),
        .typed_instance => try typedInstanceSeq(rt, env, v, loc),
        // Reified instances, host instances and `(extend-type NativeTag Seqable
        // …)` overrides resolve through the descriptor chain. A value with no
        // `-seq` of its own that is a CharSequence (java.lang.StringBuilder)
        // seqs as its chars; otherwise `dispatch` consults the protocol-target
        // and Object defaults, then raises `protocol_no_satisfies` (D-459:
        // `(seq 5)` is a value error).
        else => blk: {
            var cs: dispatch.CallSite = .{};
            if (try dispatch.dispatchOrNull(rt, env, &cs, v, SEQABLE, "-seq", &.{v}, loc)) |s| break :blk try checkedSeq(s, loc);
            if (try charSequenceSeq(rt, env, v)) |s| break :blk s;
            break :blk try checkedSeq(try dispatch.dispatch(rt, env, &cs, v, SEQABLE, "-seq", &.{v}, loc), loc);
        },
    };
}

/// `(first v)`: the head of `(seq v)`, nil when empty. JVM `RT.first`.
pub fn first(rt: *Runtime, env: *Env, v: Value, loc: SourceLocation) anyerror!Value {
    return switch (v.tag()) {
        .nil => .nil_val,
        .list, .cons => list.first(v),
        .chunked_cons => chunked_cons.first(v),
        // PERF: O(1) head (start), no chunk materialised for just first [refs: O-001]
        .range => try range.first(rt, v),
        // PERF: O(1) reads through the views [refs: O-058, D-179]
        .array_seq => try array_seq.first(rt, v),
        .string_seq => string_seq.first(v),
        // PERF: indexed collections answer without a view.
        .vector => if (vector.count(v) > 0) vector.nth(v, 0) else .nil_val,
        .sub_vector => sub_vector.first(v),
        .map_entry => map_entry.keyOf(v), // first of `[k v]` is k (D-209)
        .persistent_queue => persistent_queue.peek(v), // first = oldest = peek
        // JVM parity: `(first "abc")` is `\a`, a Character, not a String.
        .string => firstCodepoint(v),
        .lazy_seq => try first(rt, env, try lazy_seq.seq(rt, env, v, loc), loc),
        .array_map, .hash_map, .hash_set => try first(rt, env, try seq(rt, env, v, loc), loc),
        // D-089: a direct ISeq override wins for every open receiver,
        // including extend-type on a native tag, before Seqable coercion.
        else => try instanceFirst(rt, env, v, loc),
    };
}

/// `(rest v)`: the seq after the head, the interned `()` when there is none.
/// JVM `RT.more` (D-164: nil is lifted at ONE exit, `next` keeps nil).
pub fn rest(rt: *Runtime, env: *Env, v: Value, loc: SourceLocation) anyerror!Value {
    const raw: Value = switch (v.tag()) {
        .nil => .nil_val,
        .list, .cons => list.rest(v),
        .chunked_cons => try chunked_cons.rest(rt, v),
        .range => try chunked_cons.rest(rt, try range.seqChunk(rt, v)),
        // PERF: advance the view instead of copying the tail [refs: O-058, D-179]
        .array_seq => try array_seq.rest(rt, v),
        .string_seq => try string_seq.rest(rt, v),
        .vector, .sub_vector => try array_seq.make(rt, v, 1),
        .map_entry => try list.consHeap(rt, map_entry.valOf(v), .nil_val), // (rest [k v]) -> (v)
        .persistent_queue => blk: {
            const s = try persistent_queue.seqOf(rt, v);
            break :blk if (s.isNil()) .nil_val else list.rest(s);
        },
        // Native seqable fast paths keep their representation semantics.
        // A string's rest is a char seq, never a substring (D-174).
        .string, .lazy_seq, .array_map, .hash_map, .hash_set => blk: {
            var roots = [_]Value{try seq(rt, env, v, loc)};
            var sp: u16 = 1;
            // GC-ROOT: A9 — a coercion can return a fresh view whose backing is
            // reachable only through this cursor [ref: .dev/gc_rooting.md §A].
            var frame: root_set.EvalFrame = .{ .stack = &roots, .sp = &sp, .locals = &.{}, .parent = root_set.eval_frame_head };
            root_set.eval_frame_head = &frame;
            defer root_set.eval_frame_head = frame.parent;
            break :blk try rest(rt, env, roots[0], loc);
        },
        else => try instanceRest(rt, env, v, loc),
    };
    return if (raw.isNil()) try list.emptyList(rt) else raw;
}

/// `(next v)`: `(seq (rest v))`, nil when the tail is empty. JVM `RT.next`.
/// Seq-ing the tail is what collapses an unrealized EMPTY lazy tail to nil,
/// so a walk advancing by `next` never appends a spurious trailing nil.
pub fn next(rt: *Runtime, env: *Env, v: Value, loc: SourceLocation) anyerror!Value {
    return switch (v.tag()) {
        .nil,
        .list,
        .cons,
        .vector,
        .sub_vector,
        .array_seq,
        .string_seq,
        .map_entry,
        .persistent_queue,
        .chunked_cons,
        .lazy_seq,
        .string,
        .array_map,
        .hash_map,
        .hash_set,
        .range,
        => try seq(rt, env, try rest(rt, env, v, loc), loc),
        // Preserve D-089 native-tag extension dispatch as well as instances.
        else => try instanceNext(rt, env, v, loc),
    };
}

inline fn isInstance(v: Value) bool {
    return v.tag() == .typed_instance or v.tag() == .reified_instance;
}

/// A deftype / record receiver: a `Seqable/-seq` override wins; otherwise a
/// defrecord is Seqable as its `[k v]` entry seq (JVM parity), a deftype
/// declaring CharSequence seqs as its chars (instaparse's Segment), and any
/// other deftype with no `-seq` raises.
fn typedInstanceSeq(rt: *Runtime, env: *Env, v: Value, loc: SourceLocation) anyerror!Value {
    var cs: dispatch.CallSite = .{};
    if (try dispatch.dispatchOrNull(rt, env, &cs, v, SEQABLE, "-seq", &.{v}, loc)) |s| return checkedSeq(s, loc);
    const inst = v.decodePtr(*const td_mod.TypedInstance);
    if (inst.descriptor.kind == .defrecord) {
        const m = try recordToMap(rt, inst);
        return if (map.count(m) > 0) try map.seq(rt, m) else .nil_val;
    }
    if (try charSequenceSeq(rt, env, v)) |s| return s;
    return error_catalog.raise(.protocol_no_satisfies, loc, .{
        .protocol = SEQABLE,
        .method = "-seq",
        .type_name = inst.descriptor.fqcn orelse "<anonymous>",
    });
}

/// clj `RT.seqFrom`'s CharSequence arm: a StringSeq over the chars of a
/// non-string CharSequence, nil when it is empty; null when `v` is not one.
/// The view backs onto a fresh String holding the content as `seq` found it
/// (char_sequence.zig on the snapshot).
fn charSequenceSeq(rt: *Runtime, env: *Env, v: Value) anyerror!?Value {
    var aw: std.Io.Writer.Allocating = .init(rt.gpa);
    defer aw.deinit();
    const text = (try char_sequence.textOrNull(rt, env, v, &aw)) orelse return null;
    var roots = [_]Value{try string_collection.alloc(rt, text)};
    var sp: u16 = 1;
    // GC-ROOT: A9 — the snapshot String is reachable only from here until the
    // view's single allocation stores it as `backing` [ref: .dev/gc_rooting.md §A].
    var frame: root_set.EvalFrame = .{ .stack = &roots, .sp = &sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &frame;
    defer root_set.eval_frame_head = frame.parent;
    return try string_seq.make(rt, roots[0], 0);
}

/// A user Seqable method has the JVM return type ISeq. Validate that contract
/// once at the dispatch boundary, using the runtime's membership oracle for
/// both native seqs and open user/host descriptors. No allocation or callback.
fn checkedSeq(s: Value, loc: SourceLocation) !Value {
    if (s.isNil() or class_name.isInstance(s, ISEQ)) return s;
    return error_catalog.raise(.type_arg_invalid, loc, .{
        .fn_name = "seq",
        .expected = "ISeq or nil",
        .actual = @tagName(s.tag()),
    });
}

/// ISeq accessor on an open receiver: its own `ISeq` method when present
/// (including native-tag extensions), else its `Seqable` coercion. The
/// coercion is consulted ONCE: a self-returning `(seq [this]
/// this)` without the accessor is a contract violation, not a loop.
fn instanceFirst(rt: *Runtime, env: *Env, v: Value, loc: SourceLocation) anyerror!Value {
    var cs: dispatch.CallSite = .{};
    if (try dispatch.dispatchOrNull(rt, env, &cs, v, ISEQ, "-first", &.{v}, loc)) |x| return x;
    const s = try seq(rt, env, v, loc);
    if (isInstance(s)) {
        var cs2: dispatch.CallSite = .{};
        return (try dispatch.dispatchOrNull(rt, env, &cs2, s, ISEQ, "-first", &.{s}, loc)) orelse noIseq(s, "-first", loc);
    }
    return first(rt, env, s, loc);
}

fn instanceRest(rt: *Runtime, env: *Env, v: Value, loc: SourceLocation) anyerror!Value {
    var cs: dispatch.CallSite = .{};
    // JVM `more`; host_interface remaps a deftype's `more` to `-rest`.
    if (try dispatch.dispatchOrNull(rt, env, &cs, v, ISEQ, "-rest", &.{v}, loc)) |x| return x;
    var roots = [_]Value{try seq(rt, env, v, loc)};
    var sp: u16 = 1;
    // GC-ROOT: A9 — retain a freshly dispatched seq through the tail accessor
    // and its allocation/callbacks [ref: .dev/gc_rooting.md §A].
    var frame: root_set.EvalFrame = .{ .stack = &roots, .sp = &sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &frame;
    defer root_set.eval_frame_head = frame.parent;
    const s = roots[0];
    if (isInstance(s)) {
        var cs2: dispatch.CallSite = .{};
        return (try dispatch.dispatchOrNull(rt, env, &cs2, s, ISEQ, "-rest", &.{s}, loc)) orelse noIseq(s, "-rest", loc);
    }
    return rest(rt, env, s, loc);
}

fn instanceNext(rt: *Runtime, env: *Env, v: Value, loc: SourceLocation) anyerror!Value {
    var cs: dispatch.CallSite = .{};
    if (try dispatch.dispatchOrNull(rt, env, &cs, v, ISEQ, "-next", &.{v}, loc)) |x| return x;
    var roots = [_]Value{try seq(rt, env, v, loc)};
    var sp: u16 = 1;
    // GC-ROOT: A9 — same cursor lifetime as instanceRest, including a fresh
    // ArraySeq backing during next's view allocation [ref: .dev/gc_rooting.md §A].
    var frame: root_set.EvalFrame = .{ .stack = &roots, .sp = &sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &frame;
    defer root_set.eval_frame_head = frame.parent;
    const s = roots[0];
    if (isInstance(s)) {
        var cs2: dispatch.CallSite = .{};
        return (try dispatch.dispatchOrNull(rt, env, &cs2, s, ISEQ, "-next", &.{s}, loc)) orelse noIseq(s, "-next", loc);
    }
    return next(rt, env, s, loc);
}

fn noIseq(v: Value, method: []const u8, loc: SourceLocation) anyerror!Value {
    return error_catalog.raise(.protocol_no_satisfies, loc, .{
        .protocol = ISEQ,
        .method = method,
        .type_name = td_mod.descriptorOfInstance(v).fqcn orelse "<anonymous>",
    });
}

/// First codepoint of a string as a `.char`, nil for the empty string.
fn firstCodepoint(s: Value) Value {
    const bytes = string_collection.asString(s);
    if (bytes.len == 0) return .nil_val;
    const cp = charset.codepointAt(bytes, 0) catch return .nil_val;
    return Value.initChar(@intCast(cp));
}

/// `map.forEachEntry` accumulator: assoc each extmap entry into the demoted
/// map (D-086: a record's associative view is declared fields, then extmap).
const RecordMapExtCtx = struct {
    rt: *Runtime,
    m: *Value,
    fn cb(ctx: *RecordMapExtCtx, k: Value, v: Value) anyerror!void {
        ctx.m.* = try map.assoc(ctx.rt, ctx.m.*, k, v);
    }
};

/// A defrecord's declared fields (declaration order) then its extmap entries
/// as an array_map, so `seq` / `into {}` / `vec` over a record yield `[k v]`
/// entries like a map (D-086 / ADR-0154).
fn recordToMap(rt: *Runtime, inst: *const td_mod.TypedInstance) !Value {
    const layout = inst.descriptor.field_layout orelse return map.empty();
    const vals = inst.fields();
    var m = map.empty();
    for (layout, 0..) |f, i| {
        const kw = try keyword_mod.intern(rt, null, f.name);
        m = try map.assoc(rt, m, kw, vals[i]);
    }
    if (!inst.extmap.isNil()) {
        var ctx = RecordMapExtCtx{ .rt = rt, .m = &m };
        try map.forEachEntry(inst.extmap, &ctx, RecordMapExtCtx.cb);
    }
    return m;
}

// --- tests ---

const testing = std.testing;

const Fixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,
    env: Env,

    fn init() !Fixture {
        var fix: Fixture = .{
            .threaded = std.Io.Threaded.init(testing.allocator, .{}),
            .rt = undefined,
            .env = undefined,
        };
        fix.rt = Runtime.init(fix.threaded.io(), testing.allocator);
        return fix;
    }
    fn deinit(self: *Fixture) void {
        self.env.deinit();
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "seq: nil and the empty list answer nil; a list answers itself" {
    var fix = try Fixture.init();
    fix.env = try Env.init(&fix.rt);
    defer fix.deinit();
    try testing.expect((try seq(&fix.rt, &fix.env, .nil_val, noloc)).isNil());
    const empty = try list.emptyList(&fix.rt);
    try testing.expect((try seq(&fix.rt, &fix.env, empty, noloc)).isNil());
    const l1 = try list.consHeap(&fix.rt, Value.initInteger(1), .nil_val);
    try testing.expectEqual(l1, try seq(&fix.rt, &fix.env, l1, noloc));
}

test "seq: a string answers a StringSeq view, an empty string nil" {
    var fix = try Fixture.init();
    fix.env = try Env.init(&fix.rt);
    defer fix.deinit();
    const s = try string_collection.alloc(&fix.rt, "hi");
    const sv = try seq(&fix.rt, &fix.env, s, noloc);
    try testing.expect(sv.tag() == .string_seq);
    try testing.expectEqual(@as(u32, 'h'), (try first(&fix.rt, &fix.env, sv, noloc)).asChar());
    const e = try string_collection.alloc(&fix.rt, "");
    try testing.expect((try seq(&fix.rt, &fix.env, e, noloc)).isNil());
}

test "seq: a vector answers an ArraySeq view; first/rest/next read through it" {
    var fix = try Fixture.init();
    fix.env = try Env.init(&fix.rt);
    defer fix.deinit();
    const v = try vector.fromSlice(&fix.rt, &.{ Value.initInteger(1), Value.initInteger(2) });
    const sv = try seq(&fix.rt, &fix.env, v, noloc);
    try testing.expect(sv.tag() == .array_seq);
    try testing.expectEqual(@as(i48, 1), (try first(&fix.rt, &fix.env, v, noloc)).asInteger());
    const r = try rest(&fix.rt, &fix.env, v, noloc);
    try testing.expectEqual(@as(i48, 2), (try first(&fix.rt, &fix.env, r, noloc)).asInteger());
    const n2 = try next(&fix.rt, &fix.env, r, noloc);
    try testing.expect(n2.isNil());
}

test "rest never answers nil: the interned () stands in; next answers nil" {
    var fix = try Fixture.init();
    fix.env = try Env.init(&fix.rt);
    defer fix.deinit();
    const r = try rest(&fix.rt, &fix.env, .nil_val, noloc);
    try testing.expect(list.isEmpty(r));
    const l1 = try list.consHeap(&fix.rt, Value.initInteger(42), .nil_val);
    try testing.expect(list.isEmpty(try rest(&fix.rt, &fix.env, l1, noloc)));
    try testing.expect((try next(&fix.rt, &fix.env, l1, noloc)).isNil());
    try testing.expect((try first(&fix.rt, &fix.env, .nil_val, noloc)).isNil());
}
