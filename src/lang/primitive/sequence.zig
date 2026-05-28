// SPDX-License-Identifier: EPL-2.0
//! Core glue fundamentals — `count` / `seq` / `first` / `rest` /
//! `cons` / `empty` per ADR-0033 D6 + ROADMAP §9.8 row 6.16.a-1
//! + v5 §5.2.
//!
//! ## Pattern (v5 §6.1 hybrid polymorphism)
//!
//! Phase 6.16.a-1 ships **Zig Tag switch hardcode** (NaN-box Tag 0..15
//! comptime/runtime switch + inline). Phase 7 (D-069) opens a
//! Protocol extension point as an **additional** path; the fast-path
//! Tag arms stay, the slow-path `.protocol_extended` arm gets added
//! at that point. This is not a compromise — each Phase's best shape.
//!
//! ## Layer 2 wrapper, not Layer 0 re-implementation
//!
//! All six primitives dispatch to existing Layer 0 helpers
//! (`runtime/collection/{list,vector,map,set,chunked_cons}.zig` +
//! `runtime/lazy_seq.zig` + `runtime/charset.zig`). No new heap layout
//! is introduced. `cons` uses the day-1-reserved `.cons` Tag
//! (ADR-0004 + ADR-0012); Cons cell heap layout already lives in
//! `runtime/collection/list.zig`.
//!
//! ## Placement deviation note
//!
//! ROADMAP §9.8 row 6.16.a-1 wording uses `core/sequence.zig` subdir
//! shape, but cw v1's existing Layer 2 (uuid/file_io/regex/string/set/
//! walk/math/error/core, 9 files) is flat. This file lands flat at
//! `src/lang/primitive/sequence.zig`; subdir promotion deferred to
//! Phase 6.16.a-2/a-3 once primitive count grows past ~12.
//!
//! ## Backend: impl-only (no surface delegation)
//! Impl deps: list, vector, map, set, chunked_cons, lazy_seq, charset
//! Clojure peer: none (Pattern B1 direct intern, public surface)

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");

const list = @import("../../runtime/collection/list.zig");
const vector = @import("../../runtime/collection/vector.zig");
const map = @import("../../runtime/collection/map.zig");
const set = @import("../../runtime/collection/set.zig");
const string_collection = @import("../../runtime/collection/string.zig");
const chunked_cons = @import("../../runtime/collection/chunked_cons.zig");
const lazy_seq = @import("../../runtime/lazy_seq.zig");
const charset = @import("../../runtime/charset.zig");
const td_mod = @import("../../runtime/type_descriptor.zig");

/// Protocol fqcns the hybrid slow-paths match against `MethodEntry.protocol_name`.
/// Bootstrap declares each protocol in `lang/clj/clojure/core.clj` so the fqcn
/// `allocFqcn` stores at extend-type time is the bare symbol name (see
/// `lang/primitive/protocol.zig:41-51`). Per ADR-0008 amendment 4 (row 7.7).
const IPC_FQCN: []const u8 = "IPersistentCollection";
const SEQABLE_FQCN: []const u8 = "Seqable";
const ISEQ_FQCN: []const u8 = "ISeq";

// --- count ---

/// Implements clojure.core/count.
/// Spec: `(count coll)` returns the number of items in `coll`.
///   - nil:         0
///   - string:      codepoint count (per ADR-0014, NOT UTF-16 unit
///                  count; DIVERGENCE D1 vs JVM)
///   - list/cons:   O(1) via cached count
///   - vector:      O(1)
///   - map/set:     O(1)
///   - lazy_seq:    force + walk O(n)
///   - chunked_cons: O(n)
/// JVM reference: clojure.lang.RT.count
/// cw v1 tier: A (Phase 6.16.a-1)
pub fn countFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("count", args, 1, loc);
    const coll = args[0];
    if (coll.isNil()) return Value.initInteger(0);
    return switch (coll.tag()) {
        .string => blk: {
            const n = charset.codepointCount(string_collection.asString(coll)) catch
                return error_catalog.raise(.type_arg_invalid, loc, .{
                    .fn_name = "count",
                    .expected = "valid UTF-8 string",
                    .actual = "invalid UTF-8 bytes",
                });
            break :blk Value.initInteger(@intCast(n));
        },
        .list, .cons => Value.initInteger(@intCast(list.countOf(coll))),
        .vector => Value.initInteger(@intCast(vector.count(coll))),
        .array_map, .hash_map => Value.initInteger(@intCast(map.count(coll))),
        .hash_set => Value.initInteger(@intCast(set.count(coll))),
        .chunked_cons => Value.initInteger(@intCast(chunked_cons.count(coll))),
        .typed_instance => blk: {
            // Row 7.7 R3a (ADR-0008 amendment 4): consult the protocol
            // method_table first; user `(extend-type X IPersistentCollection
            // (-count [_] …))` overrides the defrecord field_count default.
            // Falls back to field_count for defrecord without an override
            // (preserves row 7.4 cycle 3 semantics) and to
            // protocol_no_satisfies for deftype.
            var cs: dispatch.CallSite = .{};
            if (try dispatch.dispatchOrNull(rt, env, &cs, coll, IPC_FQCN, "-count", args, loc)) |v| break :blk v;
            const inst = coll.decodePtr(*const td_mod.TypedInstance);
            if (inst.descriptor.kind == .defrecord) break :blk Value.initInteger(@intCast(inst.field_count));
            return error_catalog.raise(.protocol_no_satisfies, loc, .{
                .protocol = IPC_FQCN,
                .method = "-count",
                .type_name = inst.descriptor.fqcn orelse "<anonymous>",
            });
        },
        .lazy_seq => {
            // O(n) walk: realize and count via seq chain.
            var n: i64 = 0;
            var cur = try lazy_seq.seq(rt, env, coll);
            while (!cur.isNil()) : (n += 1) {
                cur = try seqNext(rt, env, cur);
            }
            return Value.initInteger(n);
        },
        else => blk: {
            // Row 7.7 outer slow-path: route through dispatch against
            // `clojure.core/IPersistentCollection -count`. Reaches
            // `(extend-type LongTag IPersistentCollection -count …)` style
            // native-Tag overrides via the row 7.3 per-Tag descriptor
            // registry; raises protocol_no_satisfies when no MethodEntry
            // is registered (cleaner JVM-parity diagnostic than the
            // pre-7.7 type_arg_invalid).
            var cs: dispatch.CallSite = .{};
            break :blk try dispatch.dispatch(rt, env, &cs, coll, IPC_FQCN, "-count", args, loc);
        },
    };
}

// --- seq ---

/// Implements clojure.core/seq.
/// Spec: `(seq coll)` returns a seq view of `coll`, or `nil` if empty.
///   - nil:         nil
///   - empty coll:  nil (NOT empty seq)
///   - non-empty:   list-shape ISeq view
/// JVM reference: clojure.lang.RT.seq
/// cw v1 tier: A (Phase 6.16.a-1)
pub fn seqFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("seq", args, 1, loc);
    const coll = args[0];
    if (coll.isNil()) return .nil_val;
    return switch (coll.tag()) {
        .string => {
            // Empty string → nil; non-empty → codepoint seq (eager list build).
            const s = string_collection.asString(coll);
            if (s.len == 0) return .nil_val;
            return try stringToList(rt, s);
        },
        .list, .cons => list.seq(coll),
        .vector => if (vector.count(coll) > 0) try vectorToList(rt, coll) else .nil_val,
        .array_map, .hash_map => if (map.count(coll) > 0) try map.seq(rt, coll) else .nil_val,
        .hash_set => if (set.count(coll) > 0) try set.seq(rt, coll) else .nil_val,
        .chunked_cons => coll,
        .lazy_seq => try lazy_seq.seq(rt, env, coll),
        else => blk: {
            // Row 7.7 cycle 2: outer-else routes through dispatch against
            // `Seqable -seq`, reaching `(extend-type X Seqable -seq …)`
            // overrides on defrecord / reified_instance receivers via the
            // typed_instance descriptor + on native Tags via the row 7.3
            // per-Tag descriptor registry. Raises protocol_no_satisfies
            // when no MethodEntry is registered (supersedes the pre-7.7
            // type_arg_invalid raise for non-seqable receivers).
            var cs: dispatch.CallSite = .{};
            break :blk try dispatch.dispatch(rt, env, &cs, coll, SEQABLE_FQCN, "-seq", args, loc);
        },
    };
}

// --- first ---

/// Implements clojure.core/first.
/// Spec: `(first coll)` returns the first item, or `nil` if empty.
/// JVM reference: clojure.lang.RT.first → seq().first()
/// cw v1 tier: A (Phase 6.16.a-1)
pub fn firstFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("first", args, 1, loc);
    const coll = args[0];
    if (coll.isNil()) return .nil_val;
    return switch (coll.tag()) {
        .list, .cons => list.first(coll),
        .vector => if (vector.count(coll) > 0)
            try vector_nth_safe(coll, 0, loc)
        else
            .nil_val,
        .chunked_cons => chunked_cons.first(coll),
        .lazy_seq => try lazy_seq.first(rt, env, coll),
        .string => firstStringCodepoint(rt, coll),
        .array_map, .hash_map, .hash_set => blk: {
            const sv = try seqFn(rt, env, args, loc);
            if (sv.isNil()) break :blk .nil_val;
            break :blk try firstOfSeq(rt, env, sv, loc);
        },
        else => blk: {
            // D-089 row 8.6 cycle 1: route unknown receivers through
            // (extend-type X ISeq (-first [c] ...)) before raising.
            var cs: dispatch.CallSite = .{};
            break :blk try dispatch.dispatch(rt, env, &cs, coll, ISEQ_FQCN, "-first", args, loc);
        },
    };
}

// --- rest ---

/// Implements clojure.core/rest.
/// Spec: `(rest coll)` returns a possibly-empty seq of items after the
/// first. Always returns a seq (never nil for non-nil input where
/// JVM would also return `()`; R3 from survey).
/// JVM reference: clojure.lang.RT.more
/// cw v1 tier: A (Phase 6.16.a-1)
///
/// cw v1 deviation: an empty rest renders as `nil` because cw v1
/// list.zig does not expose an empty-PersistentList singleton
/// (tracked as D-101). `(rest '(1))` → `nil` matches v1_ref behaviour
/// and the JVM `(seq (rest '(1)))` round-trip; user code that
/// distinguishes `()` from `nil` is rare. Discharge route in D-101.
pub fn restFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("rest", args, 1, loc);
    const coll = args[0];
    if (coll.isNil()) return .nil_val;
    return switch (coll.tag()) {
        .list, .cons => list.rest(coll),
        .vector => if (vector.count(coll) > 1) try vectorTailAsList(rt, coll, 1) else .nil_val,
        .chunked_cons => try chunked_cons.rest(rt, coll),
        .lazy_seq => try lazy_seq.rest(rt, env, coll),
        .string => restStringCodepoint(rt, coll),
        .array_map, .hash_map, .hash_set => blk: {
            const sv = try seqFn(rt, env, args, loc);
            if (sv.isNil()) break :blk .nil_val;
            break :blk try restOfSeq(rt, env, sv, loc);
        },
        else => blk: {
            // D-089 row 8.6 cycle 1: ISeq -rest slow-path.
            var cs: dispatch.CallSite = .{};
            break :blk try dispatch.dispatch(rt, env, &cs, coll, ISEQ_FQCN, "-rest", args, loc);
        },
    };
}

// --- next ---

/// Implements clojure.core/next.
/// Spec: `(next coll)` returns the seq of items after the first, or
///   nil if there are no more items. Distinct from `rest` only in
///   that JVM returns nil instead of an empty seq.
/// JVM reference: clojure.lang.RT.next → seq().next()
/// cw v1 tier: A (Phase 8 row 8.6 cycle 1)
pub fn nextFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("next", args, 1, loc);
    const coll = args[0];
    if (coll.isNil()) return .nil_val;
    return switch (coll.tag()) {
        .list, .cons => blk: {
            const r = list.rest(coll);
            // For cw v1, list rest already returns nil for the
            // singleton case, matching JVM's next-returns-nil contract.
            break :blk r;
        },
        .vector => if (vector.count(coll) > 1) try vectorTailAsList(rt, coll, 1) else .nil_val,
        .chunked_cons => blk: {
            const r = try chunked_cons.rest(rt, coll);
            // Match JVM next: nil for empty rest.
            if (r.isNil()) break :blk .nil_val;
            // If rest yields an empty chunked sequence, normalize to nil.
            break :blk r;
        },
        .lazy_seq => blk: {
            const r = try lazy_seq.rest(rt, env, coll);
            if (r.isNil()) break :blk .nil_val;
            break :blk r;
        },
        .string => restStringCodepoint(rt, coll),
        .array_map, .hash_map, .hash_set => blk: {
            const sv = try seqFn(rt, env, args, loc);
            if (sv.isNil()) break :blk .nil_val;
            break :blk try restOfSeq(rt, env, sv, loc);
        },
        else => blk: {
            // D-089 row 8.6 cycle 1: ISeq -next slow-path.
            var cs: dispatch.CallSite = .{};
            break :blk try dispatch.dispatch(rt, env, &cs, coll, ISEQ_FQCN, "-next", args, loc);
        },
    };
}

// --- cons ---

/// Implements clojure.core/cons.
/// Spec: `(cons x seq)` returns a new seq with x prepended.
///   - nil tail:    one-element list `(x)`
///   - list tail:   prepend (cheap)
///   - other coll:  prepend onto `(seq tail)` view (allocates Cons over
///                  a seq view of tail)
/// JVM reference: clojure.lang.RT.cons
/// cw v1 tier: A (Phase 6.16.a-1)
pub fn consFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("cons", args, 2, loc);
    const head = args[0];
    const tail = args[1];
    if (tail.isNil()) {
        // (cons x nil) → (x) — single-element list.
        return try list.consHeap(rt, head, .nil_val);
    }
    return switch (tail.tag()) {
        .list, .cons => try list.consHeap(rt, head, tail),
        else => blk: {
            // Cons over a seq view of the tail (JVM's RT.cons fallback).
            const sv = try seqFn(rt, env, args[1..2], loc);
            break :blk try list.consHeap(rt, head, sv);
        },
    };
}

// --- empty ---

/// Implements clojure.core/empty.
/// Spec: `(empty coll)` returns an empty collection of the same
/// category as `coll`, or `nil` if `coll` is nil.
/// JVM reference: clojure.core/empty
/// cw v1 tier: A (Phase 6.16.a-1)
pub fn emptyFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("empty", args, 1, loc);
    const coll = args[0];
    if (coll.isNil()) return .nil_val;
    return switch (coll.tag()) {
        .vector => vector.empty(),
        .array_map, .hash_map => map.empty(),
        .hash_set => set.empty(),
        .list, .cons => .nil_val, // empty list ≡ nil in cw v1 today
        // JVM Clojure: (empty "hi") → nil (String is not a Clojure
        // collection per IPersistentCollection contract). cw v1
        // follows the same semantic; a 0-length string is not what
        // empty returns for a string arg.
        .string => .nil_val,
        else => blk: {
            // D-089 row 8.6 cycle 1: IPC -empty slow-path.
            var cs: dispatch.CallSite = .{};
            break :blk try dispatch.dispatch(rt, env, &cs, coll, IPC_FQCN, "-empty", args, loc);
        },
    };
}

// --- helpers ---

/// vector → eager list build (head-to-tail copy).
fn vectorToList(rt: *Runtime, vec: Value) !Value {
    return try vectorTailAsList(rt, vec, 0);
}

/// vector[start..] → list view, built eager (head-to-tail).
fn vectorTailAsList(rt: *Runtime, vec: Value, start: u32) !Value {
    const n = vector.count(vec);
    if (n <= start) return .nil_val;
    var acc: Value = .nil_val;
    var i = n;
    while (i > start) {
        i -= 1;
        const elt = try vector_nth_safe(vec, i, .{ .line = 0, .column = 0 });
        acc = try list.consHeap(rt, elt, acc);
    }
    return acc;
}

/// string → eager codepoint list build.
fn stringToList(rt: *Runtime, s: []const u8) !Value {
    const cp_count = try charset.codepointCount(s);
    if (cp_count == 0) return .nil_val;
    var i: usize = cp_count;
    var acc: Value = .nil_val;
    while (i > 0) {
        i -= 1;
        const cp = charset.codepointAt(s, i) catch return error.InvalidUtf8;
        var cp_buf: [4]u8 = undefined;
        const cp_len = std.unicode.utf8Encode(@intCast(cp), &cp_buf) catch return error.InvalidUtf8;
        const ch = try string_collection.alloc(rt, cp_buf[0..cp_len]);
        acc = try list.consHeap(rt, ch, acc);
    }
    return acc;
}

/// Helper: first codepoint of a string as a 1-char string Value.
fn firstStringCodepoint(rt: *Runtime, s: Value) Value {
    const bytes = string_collection.asString(s);
    if (bytes.len == 0) return .nil_val;
    const cp = charset.codepointAt(bytes, 0) catch return .nil_val;
    var cp_buf: [4]u8 = undefined;
    const cp_len = std.unicode.utf8Encode(@intCast(cp), &cp_buf) catch return .nil_val;
    return string_collection.alloc(rt, cp_buf[0..cp_len]) catch .nil_val;
}

/// Helper: rest of a string as a string Value (drop first codepoint).
fn restStringCodepoint(rt: *Runtime, s: Value) Value {
    const bytes = string_collection.asString(s);
    if (bytes.len == 0) return .nil_val;
    const first_len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return .nil_val;
    if (bytes.len <= first_len) return .nil_val;
    return string_collection.alloc(rt, bytes[first_len..]) catch .nil_val;
}

/// First-of-seq: assumes input is already a seq (list / cons / etc).
fn firstOfSeq(rt: *Runtime, env: *Env, sv: Value, loc: SourceLocation) anyerror!Value {
    return switch (sv.tag()) {
        .list, .cons => list.first(sv),
        .chunked_cons => chunked_cons.first(sv),
        .lazy_seq => try lazy_seq.first(rt, env, sv),
        else => return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "first",
            .expected = "seq",
            .actual = @tagName(sv.tag()),
        }),
    };
}

/// Rest-of-seq: assumes input is already a seq.
fn restOfSeq(rt: *Runtime, env: *Env, sv: Value, loc: SourceLocation) anyerror!Value {
    return switch (sv.tag()) {
        .list, .cons => list.rest(sv),
        .chunked_cons => try chunked_cons.rest(rt, sv),
        .lazy_seq => try lazy_seq.rest(rt, env, sv),
        else => return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "rest",
            .expected = "seq",
            .actual = @tagName(sv.tag()),
        }),
    };
}

/// Helper: walk seq one step (used in count for lazy_seq).
fn seqNext(rt: *Runtime, env: *Env, cur: Value) anyerror!Value {
    return switch (cur.tag()) {
        .list, .cons => list.rest(cur),
        .chunked_cons => try chunked_cons.rest(rt, cur),
        .lazy_seq => try lazy_seq.next(rt, env, cur),
        else => .nil_val,
    };
}

/// vector_nth — wraps vector.nth with a type-safe loc-less error path
/// when called from helpers that don't have a SourceLocation.
fn vector_nth_safe(vec: Value, i: u32, loc: SourceLocation) anyerror!Value {
    _ = loc;
    return vector.nth(vec, i);
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "count", .f = &countFn },
    .{ .name = "seq", .f = &seqFn },
    .{ .name = "first", .f = &firstFn },
    .{ .name = "rest", .f = &restFn },
    .{ .name = "next", .f = &nextFn },
    .{ .name = "cons", .f = &consFn },
    .{ .name = "empty", .f = &emptyFn },
};

pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}

// --- tests ---

const testing = std.testing;

const TestFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,
    env: Env,

    fn init(self: *TestFixture, alloc: std.mem.Allocator) !void {
        self.threaded = std.Io.Threaded.init(alloc, .{});
        self.rt = Runtime.init(self.threaded.io(), alloc);
        self.env = try Env.init(&self.rt);
    }

    fn deinit(self: *TestFixture) void {
        self.env.deinit();
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "count: nil returns 0" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const r = try countFn(&fix.rt, &fix.env, &.{Value.nil_val}, .{ .line = 0, .column = 0 });
    try testing.expectEqual(@as(i64, 0), r.asInteger());
}

test "count: vector returns element count" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    var v = vector.empty();
    v = try vector.conj(&fix.rt, v, Value.initInteger(1));
    v = try vector.conj(&fix.rt, v, Value.initInteger(2));
    v = try vector.conj(&fix.rt, v, Value.initInteger(3));
    const r = try countFn(&fix.rt, &fix.env, &.{v}, .{ .line = 0, .column = 0 });
    try testing.expectEqual(@as(i64, 3), r.asInteger());
}

test "count: string returns codepoint count (not byte count) — DIVERGENCE D1" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const s = try string_collection.alloc(&fix.rt, "café");
    const r = try countFn(&fix.rt, &fix.env, &.{s}, .{ .line = 0, .column = 0 });
    try testing.expectEqual(@as(i64, 4), r.asInteger()); // 4 codepoints (NOT 5 bytes)
}

test "seq: empty vector returns nil" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const r = try seqFn(&fix.rt, &fix.env, &.{vector.empty()}, .{ .line = 0, .column = 0 });
    try testing.expect(r.isNil());
}

test "first: nil returns nil" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const r = try firstFn(&fix.rt, &fix.env, &.{Value.nil_val}, .{ .line = 0, .column = 0 });
    try testing.expect(r.isNil());
}

test "first: list returns head" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const lst = try list.consHeap(&fix.rt, Value.initInteger(1), .nil_val);
    const lst2 = try list.consHeap(&fix.rt, Value.initInteger(0), lst);
    const r = try firstFn(&fix.rt, &fix.env, &.{lst2}, .{ .line = 0, .column = 0 });
    try testing.expectEqual(@as(i64, 0), r.asInteger());
}

test "cons: prepend onto nil yields one-element list" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const r = try consFn(&fix.rt, &fix.env, &.{ Value.initInteger(42), Value.nil_val }, .{ .line = 0, .column = 0 });
    try testing.expect(r.tag() == .list or r.tag() == .cons);
    try testing.expectEqual(@as(i64, 42), list.first(r).asInteger());
}

test "empty: vector returns empty vector" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    var v = vector.empty();
    v = try vector.conj(&fix.rt, v, Value.initInteger(1));
    const r = try emptyFn(&fix.rt, &fix.env, &.{v}, .{ .line = 0, .column = 0 });
    try testing.expect(r.tag() == .vector);
    try testing.expectEqual(@as(u32, 0), vector.count(r));
}
