// SPDX-License-Identifier: EPL-2.0
//! Universal value equality for `clojure.core/=` (= `clojure.lang.Util.equiv`).
//! ADR-0052.
//!
//! `valueEqual(rt, env, a, b)` is by-value across nil / bool / number / char /
//! keyword / symbol / string, structural for sequentials (vector / list,
//! cross-type) and array-maps / sets, and **numeric category-gated per
//! F-005** (`(= 1 1.0)` → false; `==` in `math.zig` is the widening
//! numeric-tower comparator). It NEVER raises on a type mismatch
//! (different/unhandled value → false); only real errors (OOM, a
//! collection accessor) propagate via the error union.
//!
//! Scope: sequential cursor covers vector + list + lazy_seq — the lazy
//! arm force-walks via the lazy_seq protocol (`env` threaded so a thunk
//! can read dynamic vars), ADR-0054 cycle 3. range / array_seq /
//! string_seq join when a producer mints those tags.
//! Map / set key matching rides the existing bit-pattern `keyEq`, so
//! collection-keyed lookup is correct only for by-identity keys
//! (keyword / int / symbol) — structural collection keys await D-092.
//! Cross-category `==` (e.g. `(== 1N 1.0)`) awaits the numeric combine
//! ladder (D-014a family); `=` never needs it (category gate → false).

const std = @import("std");
const Value = @import("value/value.zig").Value;
const Runtime = @import("runtime.zig").Runtime;
const Env = @import("env.zig").Env;
const lazy_seq = @import("lazy_seq.zig");
const string_mod = @import("collection/string.zig");
const hash = @import("hash.zig");
const uuid_mod = @import("uuid.zig");
const vector = @import("collection/vector.zig");
const list = @import("collection/list.zig");
const range = @import("collection/range.zig");
const map = @import("collection/map.zig");
const set = @import("collection/set.zig");
const big_int = @import("numeric/big_int.zig");
const ratio = @import("numeric/ratio.zig");
const big_decimal = @import("numeric/big_decimal.zig");
const td_mod = @import("type_descriptor.zig");

const NumCat = enum { integer, floating, ratio, decimal, none };

fn numCat(v: Value) NumCat {
    return switch (v.tag()) {
        .integer, .big_int => .integer,
        .float => .floating,
        .ratio => .ratio,
        .big_decimal => .decimal,
        else => .none,
    };
}

fn isSequential(v: Value) bool {
    const t = v.tag();
    return t == .vector or t == .list or t == .lazy_seq or t == .range;
}

/// O(1)-countable sequentials (length short-circuit eligible). A
/// lazy_seq has no cheap length (possibly infinite), so equality on a
/// lazy seq walks element-by-element instead of comparing lengths.
fn isCountable(v: Value) bool {
    const t = v.tag();
    return t == .vector or t == .list;
}

fn seqLen(v: Value) u32 {
    return switch (v.tag()) {
        .vector => vector.count(v),
        .list => list.countOf(v),
        else => 0,
    };
}

/// A tagged element cursor over a vector (index) or list (first/rest),
/// so the two can be compared element-wise regardless of concrete type.
const Cursor = union(enum) {
    vec: struct { v: Value, i: u32, n: u32 },
    /// A compact `.range` walked by index via `start + i*step` — O(1) per
    /// element, no allocation (the seq-walk would materialise chunks).
    rng: struct { v: Value, i: i64, n: i64 },
    lst: Value,
    /// A (possibly lazy) seq walked via the lazy_seq force protocol —
    /// handles `.lazy_seq` layers + the realized `.list` cons chain
    /// underneath (cons cells are `.list`-tagged per collection/list).
    lzy: Value,

    fn init(v: Value) Cursor {
        return switch (v.tag()) {
            .vector => .{ .vec = .{ .v = v, .i = 0, .n = vector.count(v) } },
            .range => .{ .rng = .{ .v = v, .i = 0, .n = range.countOf(v) } },
            .list => .{ .lst = v },
            else => .{ .lzy = v },
        };
    }

    fn next(self: *Cursor, rt: *Runtime, env: *Env) anyerror!?Value {
        switch (self.*) {
            .vec => |*s| {
                if (s.i >= s.n) return null;
                const e = vector.nth(s.v, s.i);
                s.i += 1;
                return e;
            },
            .rng => |*s| {
                if (s.i >= s.n) return null;
                const e = range.elementAt(s.v, s.i);
                s.i += 1;
                return e;
            },
            .lst => |*node| {
                if (node.tag() != .list or list.countOf(node.*) == 0) return null;
                const e = list.first(node.*);
                node.* = list.rest(node.*);
                return e;
            },
            .lzy => |*node| {
                const s = try lazy_seq.seq(rt, env, node.*);
                if (s.isNil()) return null;
                const e = try lazy_seq.first(rt, env, s);
                node.* = try lazy_seq.rest(rt, env, s);
                return e;
            },
        }
    }
};

/// Within-category integer equality. Handles int↔int, big_int↔big_int,
/// and the int↔big_int cross-representation (`(= 1 1N)` → true) via
/// `Managed.toInt` (a big_int too large to fit an i48 int → false).
fn intEqual(a: Value, b: Value) bool {
    const ta = a.tag();
    const tb = b.tag();
    if (ta == .integer and tb == .integer) return a.asInteger() == b.asInteger();
    if (ta == .big_int and tb == .big_int)
        return big_int.compareManaged(big_int.asManaged(a), big_int.asManaged(b)) == .eq;
    // Mixed int / big_int.
    const small: Value = if (ta == .integer) a else b;
    const big: Value = if (ta == .big_int) a else b;
    const as_i = big_int.asManaged(big).toInt(i64) catch return false;
    return as_i == @as(i64, small.asInteger());
}

fn seqEqual(rt: *Runtime, env: *Env, a: Value, b: Value) anyerror!bool {
    // Length short-circuit only when BOTH are O(1)-countable (vector /
    // list); a lazy seq is walked element-by-element (no cheap length,
    // possibly infinite — the walk terminates as soon as the finite
    // side ends).
    if (isCountable(a) and isCountable(b) and seqLen(a) != seqLen(b)) return false;
    var ca = Cursor.init(a);
    var cb = Cursor.init(b);
    while (true) {
        const ea = try ca.next(rt, env);
        const eb = try cb.next(rt, env);
        if (ea == null and eb == null) return true;
        if (ea == null or eb == null) return false;
        if (!try valueEqual(rt, env, ea.?, eb.?)) return false;
    }
}

fn mapEqual(rt: *Runtime, env: *Env, a: Value, b: Value) anyerror!bool {
    if (map.count(a) != map.count(b)) return false;
    var ks = try map.keys(rt, a);
    while (ks.tag() == .list and list.countOf(ks) > 0) {
        const k = list.first(ks);
        if (!try map.contains(b, k)) return false;
        if (!try valueEqual(rt, env, try map.get(a, k), try map.get(b, k))) return false;
        ks = list.rest(ks);
    }
    return true;
}

fn setEqual(rt: *Runtime, a: Value, b: Value) anyerror!bool {
    if (set.count(a) != set.count(b)) return false;
    var es = try set.seq(rt, a);
    while (es.tag() == .list and list.countOf(es) > 0) {
        if (!try set.contains(b, list.first(es))) return false;
        es = list.rest(es);
    }
    return true;
}

/// Value equality for MAP KEYS (D-151). Deliberately takes NO `rt`/`env`:
/// `map.get`/`contains`/`assoc` have ~68 call sites, many without a
/// Runtime/Env (VM dispatch, multimethod), so threading `valueEqual`'s
/// signature down would ripple everywhere. This covers the
/// non-recursive key types by value:
///   - identity fast path — nil / bool / int / float / char /
///     builtin_fn / interned keyword·symbol / pointer-identical heap
///     (immediates + interns are already by-value under identity, and
///     cross-category like `{1 :a}` vs `1.0` stays unequal, matching
///     JVM's category-based `=` for keys);
///   - `.string` — byte-equality (the D-151 target: non-interned String
///     Values with equal bytes but distinct heap pointers).
/// VECTOR keys now compare + hash BY VALUE (D-092, recursive over
/// elements — fixes `(frequencies [[1] [1]])` & vector-keyed maps).
/// List / map / set keys and ratio/big_decimal/big_int keys still stay
/// identity-compared (residual: the recursive / category-aware
/// `valueEqual` needs `rt`; cross-type vec≡list keys also pending).
pub fn keyEqValue(a: Value, b: Value) bool {
    if (@intFromEnum(a) == @intFromEnum(b)) return true;
    const ta = a.tag();
    const tb = b.tag();
    if (ta == .string and tb == .string)
        return std.mem.eql(u8, string_mod.asString(a), string_mod.asString(b));
    // Sequential keys (vector / list) by value, element-wise + recursive,
    // any cross-pairing (a vector key is = a list key with equal elements,
    // matching Clojure's sequential =) (D-092). Lazy / range keys are a
    // residual (cannot realize rt-free).
    if (isSeqKeyTag(ta) and isSeqKeyTag(tb))
        return seqKeyEq(a, b);
    // Map / set keys by value, rt-free via the collection module (D-092).
    if (isMapTag(ta) and isMapTag(tb))
        return map.contentEq(a, b);
    if (ta == .hash_set and tb == .hash_set)
        return set.contentEq(a, b);
    // defrecord keys by value (partner of typedInstanceEqual): same
    // descriptor + each field keyEqValue. deftype stays identity (a
    // non-bit-identical pair already fell through the identity check).
    if (ta == .typed_instance and tb == .typed_instance)
        return typedInstanceKeyEq(a, b);
    return false;
}

inline fn isSeqKeyTag(t: Value.Tag) bool {
    return t == .vector or t == .list;
}

inline fn isMapTag(t: Value.Tag) bool {
    return t == .array_map or t == .hash_map;
}

fn typedInstanceKeyEq(a: Value, b: Value) bool {
    const ia = a.decodePtr(*const td_mod.TypedInstance);
    const ib = b.decodePtr(*const td_mod.TypedInstance);
    if (ia.descriptor != ib.descriptor) return false;
    if (ia.descriptor.kind != .defrecord) return false;
    const fa = ia.fields();
    const fb = ib.fields();
    if (fa.len != fb.len) return false;
    var i: usize = 0;
    while (i < fa.len) : (i += 1) {
        if (!keyEqValue(fa[i], fb[i])) return false;
    }
    return true;
}

/// HAMT key hash — also the user-facing `(hash x)` (core.hashFn delegates
/// here). MUST satisfy `keyEqValue(a,b) ⇒ valueHash(a) == valueHash(b)`.
/// By-value branches mirror keyEqValue's by-value arms: strings hash by
/// BYTES; sequentials (vector / list) by ordered content (one shared
/// formula → vec≡list collide); maps / sets by order-independent content;
/// defrecords by descriptor + fields. int/float use the numeric hash so
/// `{1 :a}` and `1.0` stay distinct. Everything else (immediates, interned
/// keyword·symbol, lazy / range, deftype) is identity-compared in
/// keyEqValue, so hashing the raw NaN-box bits is contract-consistent.
/// nil → 0. cljw's value is internally consistent, not bit-identical to
/// the JVM Murmur output.
pub fn valueHash(v: Value) u32 {
    return switch (v.tag()) {
        .string => hash.hashString(string_mod.asString(v)),
        .integer => hash.hashLong(@as(i64, v.asInteger())),
        .float => hash.hashLong(@bitCast(v.asFloat())),
        .nil => 0,
        // Sequential keys (vector / list) hash by content, ordered +
        // recursive, via the SAME formula so an equal vector and list
        // collide into one bucket (Clojure's sequential =). Partner of
        // seqKeyEq (D-092).
        .vector, .list => seqHash(v),
        // Map / set keys hash by content (order-independent), rt-free via
        // the collection module's structure walk (D-092). Partner of
        // map.contentEq / set.contentEq.
        .array_map, .hash_map => map.contentHash(v),
        .hash_set => set.contentHash(v),
        // UUID hashes by its 128 bits so equal UUIDs share a bucket
        // (partner of the `.uuid` valueEqual arm, ADR-0074).
        .uuid => hash.hashString(&uuid_mod.asUuid(v).bytes),
        // defrecord keys hash by descriptor + fields (partner of
        // typedInstanceKeyEq); deftype keeps the identity bit-hash.
        .typed_instance => blk: {
            const inst = v.decodePtr(*const td_mod.TypedInstance);
            if (inst.descriptor.kind == .defrecord) break :blk typedInstanceHash(inst);
            break :blk hash.hashLong(@bitCast(@intFromEnum(v)));
        },
        else => hash.hashLong(@bitCast(@intFromEnum(v))),
    };
}

/// Content hash of a defrecord instance: seed with the descriptor pointer
/// (so distinct record types with equal fields hash apart) then fold each
/// field through `valueHash`. Partner of `typedInstanceKeyEq`.
fn typedInstanceHash(inst: *const td_mod.TypedInstance) u32 {
    const fields = inst.fields();
    var h: u32 = @truncate(@intFromPtr(inst.descriptor));
    for (fields) |fv| {
        h = h *% 31 +% valueHash(fv);
    }
    return hash.mixCollHash(h, @intCast(fields.len));
}

/// An rt-free element cursor over an already-realized sequential
/// (vector by index, list by first/rest). Unlike the `Cursor` above it
/// takes no `rt`/`env`, so it can serve `valueHash` / `keyEqValue` (whose
/// call sites lack a Runtime). Lazy / range keys stay identity (cannot be
/// realized rt-free) — a documented residual shared with their hash.
const SeqKeyCursor = union(enum) {
    vec: struct { v: Value, i: u32, n: u32 },
    lst: Value,

    fn init(v: Value) SeqKeyCursor {
        return switch (v.tag()) {
            .vector => .{ .vec = .{ .v = v, .i = 0, .n = vector.count(v) } },
            else => .{ .lst = v },
        };
    }

    fn next(self: *SeqKeyCursor) ?Value {
        switch (self.*) {
            .vec => |*s| {
                if (s.i >= s.n) return null;
                const e = vector.nth(s.v, s.i);
                s.i += 1;
                return e;
            },
            .lst => |*node| {
                if (node.tag() != .list or list.countOf(node.*) == 0) return null;
                const e = list.first(node.*);
                node.* = list.rest(node.*);
                return e;
            },
        }
    }
};

/// Order-dependent content hash of a sequential (vector / list), the
/// `hash.hashOrdered` formula inlined over a `SeqKeyCursor` so vectors and
/// lists with equal elements produce one hash; recurses through
/// `valueHash` so nested collections hash by content too.
fn seqHash(v: Value) u32 {
    var h: u32 = 1;
    var n: u32 = 0;
    var c = SeqKeyCursor.init(v);
    while (c.next()) |e| {
        h = h *% 31 +% valueHash(e);
        n += 1;
    }
    return hash.mixCollHash(h, n);
}

/// Element-wise equality of two sequential keys (vector / list, any
/// cross-pairing), rt-free over `SeqKeyCursor`. Partner of `seqHash`.
fn seqKeyEq(a: Value, b: Value) bool {
    var ca = SeqKeyCursor.init(a);
    var cb = SeqKeyCursor.init(b);
    while (true) {
        const ea = ca.next();
        const eb = cb.next();
        if (ea == null and eb == null) return true;
        if (ea == null or eb == null) return false;
        if (!keyEqValue(ea.?, eb.?)) return false;
    }
}

/// `(= a b)` semantics. See module docstring + ADR-0052.
pub fn valueEqual(rt: *Runtime, env: *Env, a: Value, b: Value) anyerror!bool {
    // 1. Identity fast path: nil / bool / int / char / builtin_fn /
    //    interned keyword·symbol / pointer-identical heap.
    if (@intFromEnum(a) == @intFromEnum(b)) return true;

    // 2. Numeric arm, category-gated (F-005).
    const ca = numCat(a);
    const cb = numCat(b);
    if (ca != .none or cb != .none) {
        if (ca != cb) return false; // cross-category (incl. number vs non-number) → false
        return switch (ca) {
            .integer => intEqual(a, b),
            .floating => a.asFloat() == b.asFloat(),
            .ratio => (try ratio.compareValue(rt, a, b)) == .eq,
            .decimal => (try big_decimal.compareValue(rt, a, b)) == .eq,
            .none => unreachable,
        };
    }

    // 3. Sequential cross-type (vector / list).
    if (isSequential(a) and isSequential(b)) return seqEqual(rt, env, a, b);

    // 4. Same-tag content arms; any other tag pairing → false.
    const ta = a.tag();
    if (ta != b.tag()) return false;
    // keyword / symbol are interned, so equal ones already hit the
    // identity fast path above; a non-bit-identical pair is unequal.
    return switch (ta) {
        .string => std.mem.eql(u8, string_mod.asString(a), string_mod.asString(b)),
        .array_map, .hash_map => mapEqual(rt, env, a, b),
        .hash_set => setEqual(rt, a, b),
        .typed_instance => typedInstanceEqual(rt, env, a, b),
        // UUID equality is by the 128 bits (ADR-0074): two distinct
        // allocations with the same bytes are `=` (clj UUID value equality).
        .uuid => std.mem.eql(u8, &uuid_mod.asUuid(a).bytes, &uuid_mod.asUuid(b).bytes),
        else => false,
    };
}

/// Record value equality (Clojure defrecord overrides equals): same
/// descriptor (type) + every declared field equal, recursively. deftype
/// keeps identity semantics (no auto equals) — two distinct deftype
/// instances reach here non-bit-identical, so `false` is correct. A
/// record is never `=` to a plain map: the caller's same-tag gate already
/// excludes the map tags before this arm.
fn typedInstanceEqual(rt: *Runtime, env: *Env, a: Value, b: Value) anyerror!bool {
    const ia = a.decodePtr(*const td_mod.TypedInstance);
    const ib = b.decodePtr(*const td_mod.TypedInstance);
    if (ia.descriptor != ib.descriptor) return false;
    if (ia.descriptor.kind != .defrecord) return false; // deftype = identity
    const fa = ia.fields();
    const fb = ib.fields();
    if (fa.len != fb.len) return false;
    for (fa, fb) |va, vb| {
        if (!try valueEqual(rt, env, va, vb)) return false;
    }
    return true;
}
