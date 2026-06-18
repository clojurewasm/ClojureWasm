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
//! Map / set key matching compares keys BY VALUE via `keyEqValue`:
//! interned keys (keyword / int / symbol) stay pointer-eq, and
//! structural collection keys (vector / list / map / set, cross-type
//! vector≡list) compare + hash by content (D-092, rt-free walks in the
//! collection modules). Lazy / range keys stay identity — cannot
//! realize rt-free, a documented residual.
//! Cross-category `==` (e.g. `(== 1N 1.0)`) awaits the numeric combine
//! ladder (D-014a family); `=` never needs it (category gate → false).

const std = @import("std");
const Value = @import("value/value.zig").Value;
const Runtime = @import("runtime.zig").Runtime;
const Env = @import("env.zig").Env;
const lazy_seq = @import("lazy_seq.zig");
const string_mod = @import("collection/string.zig");
const symbol_mod = @import("symbol.zig");
const keyword_mod = @import("keyword.zig");
const hash = @import("hash.zig");
const uuid_mod = @import("uuid.zig");
const tagged_literal_mod = @import("tagged_literal.zig");
const vector = @import("collection/vector.zig");
const list = @import("collection/list.zig");
const range = @import("collection/range.zig");
const persistent_queue = @import("collection/persistent_queue.zig");
const map = @import("collection/map.zig");
const map_entry_mod = @import("collection/map_entry.zig");
const set = @import("collection/set.zig");
const sorted = @import("collection/sorted.zig");
const big_int = @import("numeric/big_int.zig");
const ratio = @import("numeric/ratio.zig");
const big_decimal = @import("numeric/big_decimal.zig");
const td_mod = @import("type_descriptor.zig");
const date_mod = @import("time/date.zig");
const timestamp_mod = @import("time/timestamp.zig");
const instant_value_mod = @import("time/instant_value.zig");
const duration_value_mod = @import("time/duration_value.zig");
const dispatch_mod = @import("dispatch.zig");
const root_set = @import("gc/root_set.zig");
const ClojureWasmError = @import("error/info.zig").ClojureWasmError;
const SourceLocation = @import("error/info.zig").SourceLocation;

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
    // A MapEntry is a 2-vector (D-209), so `(= (first {:a 1}) [:a 1])`→true.
    // A queue is Sequential, so `(= (conj EMPTY 1 2) [1 2])`→true (ADR-0087).
    if (t == .vector or t == .list or t == .lazy_seq or t == .range or t == .map_entry or t == .persistent_queue)
        return true;
    // A deftype/reify declaring clojure.lang.Sequential (e.g. data.finger-tree's
    // double-list) compares element-wise like clj's `=` (Util.pcequiv over the
    // sequential operand), NOT by its own (often stub) `equiv` (D-427). seqEqual
    // realizes such an instance to a list before walking. Gated on `Sequential`
    // specifically — a map/set deftype is NOT Sequential and stays identity/equiv.
    if (t == .typed_instance or t == .reified_instance)
        return td_mod.descriptorOfInstance(v).declaresProtocol("Sequential");
    return false;
}

/// O(1)-countable sequentials (length short-circuit eligible). A
/// lazy_seq has no cheap length (possibly infinite), so equality on a
/// lazy seq walks element-by-element instead of comparing lengths.
fn isCountable(v: Value) bool {
    const t = v.tag();
    // `.list` is intentionally EXCLUDED: a Cons stores the count of its `.list`
    // PREFIX only — a Cons over a lazy/seq tail (`(cons 1 (lazy-seq …))`) has a
    // stored count smaller than its realized length, so trusting it for the
    // length short-circuit drops the lazy tail (`(= (cons 1 (lazy-seq [2 3]))
    // (list 1 2 3))` → wrongly false). The element walk early-outs at the first
    // length mismatch anyway. Vector / map_entry / queue counts ARE reliable.
    return t == .vector or t == .map_entry or t == .persistent_queue;
}

fn seqLen(v: Value) u32 {
    return switch (v.tag()) {
        .vector => vector.count(v),
        .list => list.countOf(v),
        .map_entry => 2,
        .persistent_queue => @intCast(persistent_queue.count(v)),
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
    /// A MapEntry walked as the 2-vector `[key val]` (D-209).
    ment: struct { v: Value, i: u32 },
    /// A PersistentQueue walked front-list then rear-vector (ADR-0087).
    q: struct { front: Value, rear: Value, ri: u32 },
    lst: Value,
    /// A (possibly lazy) seq walked via the lazy_seq force protocol —
    /// handles `.lazy_seq` layers + the realized `.list` cons chain
    /// underneath (cons cells are `.list`-tagged per collection/list).
    lzy: Value,

    fn init(v: Value) Cursor {
        return switch (v.tag()) {
            .vector => .{ .vec = .{ .v = v, .i = 0, .n = vector.count(v) } },
            .range => .{ .rng = .{ .v = v, .i = 0, .n = range.countOf(v) } },
            .map_entry => .{ .ment = .{ .v = v, .i = 0 } },
            .persistent_queue => .{ .q = .{ .front = persistent_queue.frontOf(v), .rear = persistent_queue.rearOf(v), .ri = 0 } },
            // A `.list` cons may carry a NON-list seq as its rest (a "Cons over
            // a seq", e.g. `(cons 1 (lazy-seq …))` / `(cons 1 (map …))`), so the
            // lazy-aware cursor (which forces lazy layers AND routes `.list`
            // cells to the list ops) is needed — the plain `.lst` walk stops at
            // the first non-`.list` rest and drops the tail.
            .list => .{ .lzy = v },
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
            .ment => |*s| {
                if (s.i >= 2) return null;
                const e = map_entry_mod.nth(s.v, s.i);
                s.i += 1;
                return e;
            },
            .q => |*s| {
                if (s.front.tag() == .list and list.countOf(s.front) > 0) {
                    const e = list.first(s.front);
                    s.front = list.rest(s.front);
                    return e;
                }
                if (!s.rear.isNil() and s.ri < vector.count(s.rear)) {
                    const e = vector.nth(s.rear, s.ri);
                    s.ri += 1;
                    return e;
                }
                return null;
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

/// rt-free Ratio key equality (D-205). Ratios are gcd-reduced with a
/// strictly-positive denominator AND canonical (small IFF reduced fits i64,
/// ADR-0149), so two equal ratios have bit-identical fields and small-vs-big can
/// never be equal — a field compare matches the numeric `=` without `rt`.
/// Partner of the `.ratio` valueHash arm.
fn ratioKeyEq(a: Value, b: Value) bool {
    const ra = a.decodePtr(*const ratio.Ratio);
    const rb = b.decodePtr(*const ratio.Ratio);
    // Canonical invariant: a small `1/2` and a big `1/2` cannot coexist, so a
    // differing tier means differing value.
    if (ra.is_small != rb.is_small) return false;
    if (ra.is_small == 1) return ra.a == rb.a and ra.b == rb.b; // i64 bits (reduced/normalised → identical)
    return big_int.compareManaged(ra.bigNum().m, rb.bigNum().m) == .eq and
        big_int.compareManaged(ra.bigDen().m, rb.bigDen().m) == .eq;
}

/// BigDecimal map-key equality, rt-free + scale-INDEPENDENT (ADR-0077 /
/// D-205): compare the cached stripped projection so `1.5M` and `1.50M`
/// are interchangeable keys (clj parity). Mirrors `ratioKeyEq` — the
/// normalized fields are canonical, so equal value ⇒ equal fields.
fn decimalKeyEq(a: Value, b: Value) bool {
    return big_decimal.asNormScale(a) == big_decimal.asNormScale(b) and
        big_int.compareManaged(big_decimal.asNormUnscaled(a).m, big_decimal.asNormUnscaled(b).m) == .eq;
}

/// Realize a Sequential deftype/reify (D-427) to a native `.list` by walking the
/// ISeq protocol (`-first`/`-next`), GC-rooted (a `-next` builds a FRESH instance
/// not reachable from the original operand, so a collect mid-walk could free it —
/// the accumulator + cursor must be rooted). Returns a single `.list` value the
/// caller can then walk with the rt-free Cursor. Mirrors print.zig
/// realizeInstanceSeq; an instance whose `-next` hands off to a native seq tail
/// (lazy/list) folds that tail in too.
fn realizeSequentialInstance(rt: *Runtime, env: *Env, start: Value) anyerror!Value {
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(rt.gpa);
    var cur = start;
    var cur_root: [1]Value = .{cur};
    var cur_sp: u16 = 1;
    var gc_frame: root_set.EvalFrame = .{ .stack = &cur_root, .sp = &cur_sp, .locals = items.items, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;
    const noloc = SourceLocation{ .line = 0, .column = 0 };
    // RT.seq normalization: a self-ISeq -seq returns the instance (walked below);
    // a Seqable-only Sequential -seq returns a native seq (folded by the tail loop).
    {
        var cs0: dispatch_mod.CallSite = .{};
        cur = (try dispatch_mod.dispatchOrNull(rt, env, &cs0, cur, "Seqable", "-seq", &.{cur}, noloc)) orelse cur;
    }
    while (cur.tag() == .typed_instance or cur.tag() == .reified_instance) {
        cur_root[0] = cur;
        gc_frame.locals = items.items;
        var cs1: dispatch_mod.CallSite = .{};
        const f = (try dispatch_mod.dispatchOrNull(rt, env, &cs1, cur, "ISeq", "-first", &.{cur}, noloc)) orelse break;
        try items.append(rt.gpa, f);
        gc_frame.locals = items.items;
        var cs2: dispatch_mod.CallSite = .{};
        cur = (try dispatch_mod.dispatchOrNull(rt, env, &cs2, cur, "ISeq", "-next", &.{cur}, noloc)) orelse .nil_val;
    }
    // A `-next` that handed off to a native seq tail (lazy/list): fold it in.
    while (!cur.isNil()) {
        cur_root[0] = cur;
        gc_frame.locals = items.items;
        const s = try lazy_seq.seq(rt, env, cur);
        if (s.isNil()) break;
        try items.append(rt.gpa, try lazy_seq.first(rt, env, s));
        cur = try lazy_seq.rest(rt, env, s);
    }
    var result: Value = .nil_val;
    var i: usize = items.items.len;
    while (i > 0) {
        i -= 1;
        result = try list.consHeap(rt, items.items[i], result);
    }
    return result;
}

/// Realize a (possibly lazy / range / chunked / cons-over-lazy) NATIVE sequential
/// to a fully-realized `.list` so the rt-free `seqHash`/`seqKeyEq` give it the
/// content hash/eq of its `=`-equal vector/list (D-432/D-408 key path). Walks the
/// shared seq protocol (`lazy_seq.seq`/`first`/`rest` — handles lazy_seq / range /
/// chunked_cons / list, forcing thunks), GC-rooting the accumulator + cursor (a
/// forced thunk mints fresh values not reachable from the original key). Requires
/// `rt`/`env` (the thunk + range-chunk dispatch need them). NOT for vector / queue
/// (those already content-walk rt-free) or Sequential instances (use
/// `realizeSequentialInstance`). Mirrors realizeSequentialInstance's tail loop.
fn realizeSeqToList(rt: *Runtime, env: *Env, start: Value) anyerror!Value {
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(rt.gpa);
    var cur = start;
    var cur_root: [1]Value = .{cur};
    var cur_sp: u16 = 1;
    var gc_frame: root_set.EvalFrame = .{ .stack = &cur_root, .sp = &cur_sp, .locals = items.items, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;
    while (true) {
        cur_root[0] = cur;
        gc_frame.locals = items.items;
        const s = try lazy_seq.seq(rt, env, cur);
        if (s.isNil()) break;
        cur_root[0] = s;
        gc_frame.locals = items.items;
        const f = try lazy_seq.first(rt, env, s);
        try items.append(rt.gpa, f);
        cur_root[0] = s;
        gc_frame.locals = items.items;
        cur = try lazy_seq.rest(rt, env, s);
    }
    var result: Value = .nil_val;
    var i: usize = items.items.len;
    while (i > 0) {
        i -= 1;
        result = try list.consHeap(rt, items.items[i], result);
    }
    return result;
}

inline fn isInstanceTag(v: Value) bool {
    const t = v.tag();
    return t == .typed_instance or t == .reified_instance;
}

fn seqEqual(rt: *Runtime, env: *Env, a: Value, b: Value) anyerror!bool {
    // A Sequential deftype/reify operand (D-427) takes the rooted instance path;
    // the common (native-seq) case stays frame-free.
    if (isInstanceTag(a) or isInstanceTag(b)) return seqEqualInstance(rt, env, a, b);
    return seqEqualWalk(rt, env, a, b);
}

/// Realize any Sequential-instance operand to a native list (D-427), GC-rooting
/// both operands across the realize + walk (a realized list's cons cells, and the
/// other operand, must survive a collect the second realize / element compares
/// can trigger), then compare element-wise.
fn seqEqualInstance(rt: *Runtime, env: *Env, a0: Value, b0: Value) anyerror!bool {
    var roots: [2]Value = .{ a0, b0 };
    var sp: u16 = 2;
    var gc_frame: root_set.EvalFrame = .{ .stack = &roots, .sp = &sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;
    const a = if (isInstanceTag(a0)) try realizeSequentialInstance(rt, env, a0) else a0;
    roots[0] = a;
    const b = if (isInstanceTag(b0)) try realizeSequentialInstance(rt, env, b0) else b0;
    roots[1] = b;
    return seqEqualWalk(rt, env, a, b);
}

fn seqEqualWalk(rt: *Runtime, env: *Env, a: Value, b: Value) anyerror!bool {
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

/// Linear value-search over a sequential collection — the java.util.List
/// `.indexOf` / `.lastIndexOf` / `.contains` semantics on native colls
/// (value membership by `=`, NOT clojure.core/contains? key semantics).
/// Returns the first (or, when `find_last`, the last) index whose element
/// is `=` to `item`, or -1 when absent (the JVM List contract).
pub fn seqIndexOf(rt: *Runtime, env: *Env, coll: Value, item: Value, find_last: bool) anyerror!i64 {
    var c = Cursor.init(coll);
    var i: i64 = 0;
    var found: i64 = -1;
    while (try c.next(rt, env)) |e| : (i += 1) {
        if (try valueEqual(rt, env, e, item)) {
            found = i;
            if (!find_last) return found;
        }
    }
    return found;
}

// Count / key-seq / membership / value-get over any map impl. `.sorted_map`
// routes to the `sorted` module (its rb-tree); array/hash route to `map`
// (which deliberately does NOT handle sorted, map.zig:134). A null loc is fine
// — `compareKeys` only uses it for an error render that equal keys never hit.
const noloc_eq: SourceLocation = .{ .line = 0, .column = 0 };
inline fn mCount(v: Value) u32 {
    return if (v.tag() == .sorted_map) sorted.count(v) else map.count(v);
}
inline fn mKeys(rt: *Runtime, v: Value) anyerror!Value {
    return if (v.tag() == .sorted_map) sorted.keys(rt, v) else map.keys(rt, v);
}
inline fn mContains(rt: *Runtime, env: *Env, v: Value, k: Value) anyerror!bool {
    return if (v.tag() == .sorted_map) sorted.contains(rt, env, v, k, noloc_eq) else map.contains(v, k);
}
inline fn mGet(rt: *Runtime, env: *Env, v: Value, k: Value) anyerror!Value {
    return if (v.tag() == .sorted_map) sorted.get(rt, env, v, k, noloc_eq) else map.get(v, k);
}
inline fn sCount(v: Value) u32 {
    return if (v.tag() == .sorted_set) sorted.count(v) else set.count(v);
}
inline fn sSeq(rt: *Runtime, v: Value) anyerror!Value {
    return if (v.tag() == .sorted_set) sorted.seq(rt, v) else set.seq(rt, v);
}
inline fn sContains(rt: *Runtime, env: *Env, v: Value, x: Value) anyerror!bool {
    return if (v.tag() == .sorted_set) sorted.setContains(rt, env, v, x, noloc_eq) else set.contains(v, x);
}

fn mapEqual(rt: *Runtime, env: *Env, a: Value, b: Value) anyerror!bool {
    if (mCount(a) != mCount(b)) return false;
    var ks = try mKeys(rt, a);
    while (ks.tag() == .list and list.countOf(ks) > 0) {
        const k = list.first(ks);
        if (!try mContains(rt, env, b, k)) return false;
        if (!try valueEqual(rt, env, try mGet(rt, env, a, k), try mGet(rt, env, b, k))) return false;
        ks = list.rest(ks);
    }
    return true;
}

fn setEqual(rt: *Runtime, env: *Env, a: Value, b: Value) anyerror!bool {
    if (sCount(a) != sCount(b)) return false;
    var es = try sSeq(rt, a);
    while (es.tag() == .list and list.countOf(es) > 0) {
        if (!try sContains(rt, env, b, list.first(es))) return false;
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
    // NaN is never `=` to itself (clj `equiv`), so a NaN key can never be found
    // even when bit-identical: `(contains? #{##NaN} ##NaN)` → false. Mirrors the
    // valueEqual identity-fastpath exception. (The `.floating => {}` arm below
    // then also yields false for the rare `0.0`/`-0.0` non-identical case.)
    if (@intFromEnum(a) == @intFromEnum(b)) {
        if (a.tag() == .float and std.math.isNan(a.asFloat())) return false;
        return true;
    }
    const ta = a.tag();
    const tb = b.tag();
    // Numeric keys by value, category-gated (D-205, partner of the by-value
    // valueHash numeric arms + F-005's category-strict `=`). Without this a
    // heap numeric (`1N`/`1/2`/`1.5M`) failed the in-bucket compare and could
    // not be a map key / set element. `intEqual` covers int↔int, big_int↔
    // big_int AND cross int↔big_int, so `(get {1 :v} 1N)` → `:v` like clj.
    const ca = numCat(a);
    if (ca != .none and ca == numCat(b)) {
        switch (ca) {
            .integer => return intEqual(a, b),
            .ratio => return ratioKeyEq(a, b),
            // `.decimal`: BigDecimal `=` is NUMERIC (`(= 1.5M 1.50M)` → true)
            //   and clj scale-NORMALIZES the key/hash so `1.5M`/`1.50M` are
            //   interchangeable. The cached stripped projection (ADR-0077 /
            //   D-205) makes this a rt-free field compare, like Ratio.
            .decimal => return decimalKeyEq(a, b),
            // `.floating`: equal floats are bit-identical (caught by the
            //   identity check above); `0.0`/`-0.0` is a rare residual.
            .floating => {},
            .none => unreachable,
        }
    }
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
    // UUID / TaggedLiteral keys by value (partner of the valueEqual +
    // valueHash arms, ADR-0074/0075) — without these a uuid/tagged-literal
    // hashes into the right bucket but the in-bucket key compare returns
    // false, so it can never be a map key / set element (the bug the
    // hash+equal arms alone did NOT close).
    if (ta == .uuid and tb == .uuid)
        return std.mem.eql(u8, &uuid_mod.asUuid(a).bytes, &uuid_mod.asUuid(b).bytes);
    if (ta == .tagged_literal and tb == .tagged_literal) {
        const tla = tagged_literal_mod.asTaggedLiteral(a);
        const tlb = tagged_literal_mod.asTaggedLiteral(b);
        return keyEqValue(tla.tag, tlb.tag) and keyEqValue(tla.form, tlb.form);
    }
    // Symbol keys by ns+name (ADR-0110): a with-meta'd symbol key finds the
    // bare-symbol entry, so `(get {'a 1} (with-meta 'a m))` → 1. Partner of
    // the `.symbol` valueHash arm (both meta-ignored).
    if (ta == .symbol and tb == .symbol)
        return symbolStructEq(a, b);
    return false;
}

inline fn isSeqKeyTag(t: Value.Tag) bool {
    return t == .vector or t == .list or t == .map_entry;
}

/// Symbol equality (ADR-0110): ns+name structural, metadata IGNORED — symbol
/// identity is (ns, name) only, so `(= 'a (with-meta 'a m))` is true. Only
/// reached when the two symbols are NOT bit-identical (interned pairs hit the
/// identity fast-path); i.e. at least one is a with-meta'd non-interned symbol.
fn symbolStructEq(a: Value, b: Value) bool {
    const sa = symbol_mod.asSymbol(a);
    const sb = symbol_mod.asSymbol(b);
    const ns_eq = if (sa.ns) |an|
        (if (sb.ns) |bn| std.mem.eql(u8, an, bn) else false)
    else
        sb.ns == null;
    return ns_eq and std.mem.eql(u8, sa.name, sb.name);
}

inline fn isMapTag(t: Value.Tag) bool {
    return t == .array_map or t == .hash_map;
}

/// Any persistent-set / persistent-map representation, for value `=`: clj
/// compares sets (and maps) by their ELEMENTS regardless of impl, so a
/// sorted-set `=` a hash-set, and a sorted-map `=` an array-map `=` a hash-map,
/// with the same contents.
inline fn isAnySetTag(t: Value.Tag) bool {
    return t == .hash_set or t == .sorted_set;
}
inline fn isAnyMapTag(t: Value.Tag) bool {
    return t == .array_map or t == .hash_map or t == .sorted_map;
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
    // D-086 / ADR-0154: extmap is part of record value identity. keyEqValue
    // compares nil↔nil (identity), map↔map (content, order-independent), and
    // nil↔map → false. Empty extmap normalizes to nil so this stays correct.
    return keyEqValue(ia.extmap, ib.extmap);
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
        // Symbol hashes by its ns+name `hash_cache` (ADR-0110), meta-IGNORED.
        // Without this, symbol fell to the `else` pointer-bits hash, so an
        // interned `'a` and a with-meta'd `'a` (distinct pointers) hashed apart
        // — breaking `(get {'a 1} (with-meta 'a m))`. Partner of symbolStructEq.
        .symbol => symbol_mod.asSymbol(v).hash_cache,
        // Keyword hashes by its ns+name `hash_cache` + 0x9e3779b9 — clj's
        // `Keyword.hasheq = sym.hasheq + 0x9e3779b9` (the offset decorrelates a
        // keyword from the same-named symbol). Without this arm keyword fell to
        // the `else` pointer-bits hash, which is NON-DETERMINISTIC across
        // processes (keyword cells are ASLR-placed) — so a keyword-keyed map's
        // hash varied per run and `(hash {:a 1})` ≠ a fresh process's. Keywords
        // are interned, so `=` keywords share one cell ⇒ one hash_cache.
        .keyword => keyword_mod.asKeyword(v).hash_cache +% 0x9e3779b9,
        .integer => hash.hashLong(@as(i64, v.asInteger())),
        .float => hash.hashLong(@bitCast(v.asFloat())),
        .nil => 0,
        // Sequential keys (vector / list) hash by content, ordered +
        // recursive, via the SAME formula so an equal vector and list
        // collide into one bucket (Clojure's sequential =). Partner of
        // seqKeyEq (D-092).
        .vector, .list, .map_entry, .persistent_queue => seqHash(v),
        // Map / set keys hash by content (order-independent), rt-free via
        // the collection module's structure walk (D-092). Partner of
        // map.contentEq / set.contentEq.
        .array_map, .hash_map => map.contentHash(v),
        .hash_set => set.contentHash(v),
        // UUID hashes by its 128 bits so equal UUIDs share a bucket
        // (partner of the `.uuid` valueEqual arm, ADR-0074).
        .uuid => hash.hashString(&uuid_mod.asUuid(v).bytes),
        // TaggedLiteral: clj's `31*hash(tag)+hash(form)` (ADR-0075).
        .tagged_literal => blk: {
            const t = tagged_literal_mod.asTaggedLiteral(v);
            break :blk 31 *% valueHash(t.tag) +% valueHash(t.form);
        },
        // defrecord keys hash by descriptor + fields (partner of
        // typedInstanceKeyEq); deftype keeps the identity bit-hash.
        .typed_instance => blk: {
            const inst = v.decodePtr(*const td_mod.TypedInstance);
            if (inst.descriptor.kind == .defrecord) break :blk typedInstanceHash(inst);
            break :blk hash.hashLong(@bitCast(@intFromEnum(v)));
        },
        // Numeric heap types hash BY VALUE (D-205) — without these they fell
        // to the `else` pointer-bits hash, which is non-deterministic AND
        // breaks them as map keys / set elements (two equal `1N`s hashed
        // apart). `managedHash` returns `hashLong(i64)` for in-range integers
        // so `(hash 1N)` == `(hash 1)` (cross-representation key parity).
        .big_int => big_int.managedHash(big_int.asManaged(v)),
        .ratio => blk: {
            const r = v.decodePtr(*const ratio.Ratio);
            // Small: hash the inline i64s via `hashLong` — identical to what
            // `managedHash` yields for an i64-fitting Managed, so cross-rep hash
            // parity holds (a small `1/2` hashes as a big `1/2` would). The
            // canonical invariant means the big form of an i64-fitting ratio
            // never exists, but the formulas agree regardless (ADR-0149).
            if (r.is_small == 1) break :blk 31 *% hash.hashLong(r.smallNum()) +% hash.hashLong(r.smallDen());
            break :blk 31 *% big_int.managedHash(r.bigNum().m) +% big_int.managedHash(r.bigDen().m);
        },
        .big_decimal => blk: {
            // Hash the cached STRIPPED projection (ADR-0077 / D-205) so
            // `1.5M` / `1.50M` collide in one bucket (clj scale-independent
            // hasheq); keyEqValue's `.decimal` arm then confirms equality.
            const d = v.decodePtr(*const big_decimal.BigDecimal);
            break :blk 31 *% big_int.managedHash(d.norm_unscaled.m) +% hash.hashInt(d.norm_scale);
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
    h = hash.mixCollHash(h, @intCast(fields.len));
    // D-086 / ADR-0154: fold the extmap as ONE separate term — valueHash on a
    // map is the order-independent content hash, so `(hash (assoc r :a 1 :b 2))`
    // == `(hash (assoc r :b 2 :a 1))`. Only when present, so a no-extras record
    // hashes exactly as before (no churn for the common case).
    if (!inst.extmap.isNil()) h = h *% 31 +% valueHash(inst.extmap);
    return h;
}

/// An rt-free element cursor over an already-realized sequential
/// (vector by index, list by first/rest). Unlike the `Cursor` above it
/// takes no `rt`/`env`, so it can serve `valueHash` / `keyEqValue` (whose
/// call sites lack a Runtime). Lazy / range keys stay identity (cannot be
/// realized rt-free) — a documented residual shared with their hash.
const SeqKeyCursor = struct {
    inner: Inner,
    /// Set when the walk hit a tail it cannot realize rt-free — a Cons
    /// whose rest is a LAZY seq (syntax-quote builds these: `(collapse-strs
    /// \`(f ~@xs))`). The walked prefix is then NOT the whole key, so
    /// `seqHash`/`seqKeyEq` must fall back to IDENTITY (the same residual
    /// as a bare lazy key) — silently truncating made two lists differing
    /// only past the lazy tail hash/compare EQUAL (hiccup's compile-multi
    /// collapsed its per-mode branches into one).
    truncated: bool = false,

    const Inner = union(enum) {
        vec: struct { v: Value, i: u32, n: u32 },
        /// A MapEntry walked as the 2-vector `[key val]` (D-209) — rt-free.
        ment: struct { v: Value, i: u32 },
        /// A PersistentQueue walked front-list then rear-vector (ADR-0087).
        q: struct { front: Value, rear: Value, ri: u32 },
        lst: Value,
    };

    fn init(v: Value) SeqKeyCursor {
        return .{ .inner = switch (v.tag()) {
            .vector => .{ .vec = .{ .v = v, .i = 0, .n = vector.count(v) } },
            .map_entry => .{ .ment = .{ .v = v, .i = 0 } },
            .persistent_queue => .{ .q = .{ .front = persistent_queue.frontOf(v), .rear = persistent_queue.rearOf(v), .ri = 0 } },
            else => .{ .lst = v },
        } };
    }

    fn next(self: *SeqKeyCursor) ?Value {
        switch (self.inner) {
            .vec => |*s| {
                if (s.i >= s.n) return null;
                const e = vector.nth(s.v, s.i);
                s.i += 1;
                return e;
            },
            .ment => |*s| {
                if (s.i >= 2) return null;
                const e = map_entry_mod.nth(s.v, s.i);
                s.i += 1;
                return e;
            },
            .q => |*s| {
                if (s.front.tag() == .list and list.countOf(s.front) > 0) {
                    const e = list.first(s.front);
                    s.front = list.rest(s.front);
                    return e;
                }
                if (!s.rear.isNil() and s.ri < vector.count(s.rear)) {
                    const e = vector.nth(s.rear, s.ri);
                    s.ri += 1;
                    return e;
                }
                return null;
            },
            .lst => |*node| {
                if (node.tag() != .list) {
                    if (!node.isNil()) self.truncated = true;
                    return null;
                }
                if (list.countOf(node.*) == 0) return null;
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
/// `seqHash` core that returns null on an unrealizable (lazy) tail instead of
/// the identity fallback — so the rt-aware key path can detect a cons-over-lazy
/// `.list` and realize it (D-408) rather than silently identity-hashing.
fn seqHashChecked(v: Value) ?u32 {
    var h: u32 = 1;
    var n: u32 = 0;
    var c = SeqKeyCursor.init(v);
    while (c.next()) |e| {
        h = h *% 31 +% valueHash(e);
        n += 1;
    }
    if (c.truncated) return null;
    return hash.mixCollHash(h, n);
}

fn seqHash(v: Value) u32 {
    // An unrealizable (lazy) tail means the walked prefix is not the whole
    // key — identity hash, consistent with seqKeyEq's identity fallback. The
    // rt-aware key path (hashDispatch) realizes such a key first so this
    // fallback is unreachable during evaluation (D-432/D-408).
    return seqHashChecked(v) orelse hash.hashLong(@bitCast(@intFromEnum(v)));
}

/// Element-wise equality of two sequential keys (vector / list, any
/// cross-pairing), rt-free over `SeqKeyCursor`. Partner of `seqHash`.
/// `seqKeyEq` core returning null when either side hits an unrealizable lazy
/// tail — lets the rt-aware key path (eqConsult) realize both operands and retry
/// rather than falling to identity (D-432/D-408).
fn seqKeyEqChecked(a: Value, b: Value) ?bool {
    var ca = SeqKeyCursor.init(a);
    var cb = SeqKeyCursor.init(b);
    while (true) {
        const ea = ca.next();
        const eb = cb.next();
        if (ca.truncated or cb.truncated) return null;
        if (ea == null and eb == null) return true;
        if (ea == null or eb == null) return false;
        if (!keyEqValue(ea.?, eb.?)) return false;
    }
}

fn seqKeyEq(a: Value, b: Value) bool {
    // An unrealizable lazy tail ⇒ the prefix compare is inconclusive — fall back
    // to identity (the lazy-key residual). The rt-aware key path realizes both
    // operands first so this fallback is unreachable during evaluation.
    return seqKeyEqChecked(a, b) orelse (@intFromEnum(a) == @intFromEnum(b));
}

/// `(= a b)` semantics. See module docstring + ADR-0052.
pub fn valueEqual(rt: *Runtime, env: *Env, a: Value, b: Value) anyerror!bool {
    // 1. Identity fast path: nil / bool / int / char / builtin_fn /
    //    interned keyword·symbol / pointer-identical heap. EXCEPTION: a NaN is
    //    never `=` to itself (IEEE / clj `equiv`: `(= ##NaN ##NaN)` → false),
    //    even bit-identical — fall through to the IEEE float compare below.
    //    (Map/set KEY equality keeps NaN-equal via `keyEqValue`, matching clj's
    //    equals/hash split — `(contains? #{##NaN} ##NaN)` → true.)
    if (@intFromEnum(a) == @intFromEnum(b)) {
        if (a.tag() == .float and std.math.isNan(a.asFloat())) return false;
        return true;
    }

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

    // 3b. A deftype/reify (non-record) collection overriding `equiv` (clj
    // IPersistentCollection) — consult it even when the tags differ, so
    // `(= (ordered-map …) {…})` honours the custom collection's value equality
    // (D-377; the D-280d8 pre-tag-gate gap). clj's `=` is `Util.equiv(a, b)` =
    // the LEFT operand's `equiv` only (NOT symmetric): `(= box {…})` consults
    // box.equiv but `(= {…} box)` consults the map's equiv (→ false for a
    // non-native operand). So consult `a` (left) only, matching clj. A defrecord
    // keeps its type-sensitive `=` by exclusion; an impl-less deftype falls through.
    if (try instanceEquiv(rt, env, a, b)) |r| return r;

    // 4. Sets and maps are `=` by ELEMENTS across all impl tags (clj: a
    // sorted-set = a hash-set, a sorted-map = an array-/hash-map with the same
    // contents), so route any set-pair / map-pair BEFORE the same-tag gate.
    const ta = a.tag();
    const tb = b.tag();
    if (isAnySetTag(ta) and isAnySetTag(tb)) return setEqual(rt, env, a, b);
    if (isAnyMapTag(ta) and isAnyMapTag(tb)) return mapEqual(rt, env, a, b);
    // Other tags: same-tag content arms; any other tag pairing → false.
    if (ta != tb) return false;
    // keyword is interned, so equal ones already hit the identity fast path
    // above; a non-bit-identical keyword pair is unequal. symbol is the
    // exception (ADR-0110): a with-meta'd symbol is non-interned, so an
    // `=`-but-not-identical pair reaches here and compares ns+name structurally.
    return switch (ta) {
        .symbol => symbolStructEq(a, b),
        .string => std.mem.eql(u8, string_mod.asString(a), string_mod.asString(b)),
        // (set / map tags are routed above, across impls — not reachable here.)
        .typed_instance => typedInstanceEqual(rt, env, a, b),
        // UUID equality is by the 128 bits (ADR-0074): two distinct
        // allocations with the same bytes are `=` (clj UUID value equality).
        .uuid => std.mem.eql(u8, &uuid_mod.asUuid(a).bytes, &uuid_mod.asUuid(b).bytes),
        // TaggedLiteral `=` by (tag, form) both equal (ADR-0075, clj parity).
        .tagged_literal => blk: {
            const tla = tagged_literal_mod.asTaggedLiteral(a);
            const tlb = tagged_literal_mod.asTaggedLiteral(b);
            break :blk (try valueEqual(rt, env, tla.tag, tlb.tag)) and (try valueEqual(rt, env, tla.form, tlb.form));
        },
        else => false,
    };
}

/// If `x` is a deftype/reify (non-record) instance with an `equiv` impl, dispatch
/// `(equiv x other)` and return its truthiness — so a custom collection's value
/// equality is honoured even against a different-tagged operand (D-377). A
/// defrecord (type-sensitive `=`, never `=` a plain map) and a non-instance /
/// impl-less deftype return null (the caller falls through to the same-tag gate).
/// Lifts typedInstanceEqual's same-type equiv consult ahead of the tag gate.
fn instanceEquiv(rt: *Runtime, env: *Env, x: Value, other: Value) anyerror!?bool {
    const t = x.tag();
    if (t != .typed_instance and t != .reified_instance) return null;
    if (t == .typed_instance and x.decodePtr(*const td_mod.TypedInstance).descriptor.kind == .defrecord) return null;
    var cs: dispatch_mod.CallSite = .{};
    if (try dispatch_mod.dispatchOrNull(rt, env, &cs, x, "Object", "equiv", &.{ x, other }, .{ .line = 0, .column = 0 })) |r|
        return r.isTruthy();
    return null;
}

/// Shared rt-aware hash core (ADR-0129 / D-377 facet 2): a non-record
/// deftype/reify with an `Object/hasheq` impl hashes via that impl (then
/// `hashCode`); a defrecord and everything else fall to the rt-free
/// `valueHash`. The `(hash x)` primitive AND the HAMT key-bucketing sites
/// share this so a deftype key and `(hash deftype)` agree (F-011). clj's
/// `hasheq` is a 32-bit int, so the dispatched value is truncated to i32.
pub fn hashDispatch(rt: *Runtime, env: *Env, v: Value) ClojureWasmError!u32 {
    switch (v.tag()) {
        // A lazy / range / chunked seq hashes by its realized element content —
        // realize then `seqHash` so `(hash (map inc [0 1 2]))` == `(hash [1 2 3])`
        // and a lazy key buckets with its `=`-equal vector/list (D-432). clj
        // realizes a LazySeq to hash it (`LazySeq.hashCode` calls `seq()`).
        .lazy_seq, .range, .chunked_cons => {
            const realized = realizeSeqToList(rt, env, v) catch |e| return @errorCast(e);
            return seqHash(realized);
        },
        // A cons over a lazy tail (syntax-quote) hashes rt-free until the lazy
        // tail truncates the walk; realize + content-hash only then (D-408) so a
        // fully-realized list keeps the fast path.
        .list => return seqHashChecked(v) orelse blk: {
            const realized = realizeSeqToList(rt, env, v) catch |e| return @errorCast(e);
            break :blk seqHash(realized);
        },
        .typed_instance, .reified_instance => {
            // A Sequential deftype/reify (D-427) hashes element-wise like its
            // `=`-equal list (its `=` is element-wise too, ignoring a custom
            // equiv) — realize then `seqHash`. A non-record non-Sequential
            // deftype hashes via its custom hasheq/hashCode (ADR-0129).
            if (isSequential(v)) {
                const realized = realizeSequentialInstance(rt, env, v) catch |e| return @errorCast(e);
                return seqHash(realized);
            }
            const is_record = v.tag() == .typed_instance and
                v.decodePtr(*const td_mod.TypedInstance).descriptor.kind == .defrecord;
            if (!is_record) {
                var cs: dispatch_mod.CallSite = .{};
                // dispatchOrNull is typed `anyerror` (the vt.callFn fn-pointer), but
                // the runtime only raises ClojureWasmError variants — narrow at this
                // single boundary with @errorCast so map.assoc/get keep their error
                // set (no caller-wide ripple). Safe-checked in safe build modes.
                if (dispatch_mod.dispatchOrNull(rt, env, &cs, v, "Object", "hasheq", &.{v}, .{ .line = 0, .column = 0 }) catch |e| return @errorCast(e)) |h|
                    return @bitCast(@as(i32, @truncate(h.asInteger())));
                if (dispatch_mod.dispatchOrNull(rt, env, &cs, v, "Object", "hashCode", &.{v}, .{ .line = 0, .column = 0 }) catch |e| return @errorCast(e)) |h|
                    return @bitCast(@as(i32, @truncate(h.asInteger())));
            }
            return valueHash(v);
        },
        else => return valueHash(v),
    }
}

/// rt-aware key hash (ADR-0129 + Track D D1): a custom-hasheq deftype/reify key
/// hashes via its impl, and a lazy_seq / range / chunked / cons-over-lazy /
/// Sequential-instance key hashes by realized content — both via `hashDispatch`,
/// reading the ambient `dispatch.current_env` (→ its `rt`). Everything else, and
/// the UNARMED case (outside evaluation: bootstrap / host-init), falls to the
/// rt-free `valueHash`. The evaluator (evalForm + runEnvelope) arms current_env
/// around every top-level form, so a real user/AOT seq key is always armed; the
/// unarmed fallback is reachable only before the evaluator is up (no user assoc).
/// MUST stay paired with `eqConsult` so a key and its `=`-equal value co-bucket.
pub fn hashConsult(v: Value) ClojureWasmError!u32 {
    if (dispatch_mod.current_env) |env| {
        switch (v.tag()) {
            .typed_instance, .reified_instance, .lazy_seq, .range, .chunked_cons, .list =>
                return hashDispatch(env.rt, env, v),
            else => {},
        }
    }
    return valueHash(v);
}

/// Any value participating in sequential (ordered) KEY content equality: native
/// seqs (incl. lazy / range / chunked / queue) + a Sequential deftype/reify
/// (D-427). A seq key is only `=` to another seq key. Superset of `keyEqValue`'s
/// rt-free `isSeqKeyTag` (which can't reach lazy/range/instance), so the armed
/// eqConsult path also content-compares a queue key (matching the `valueHash`
/// `.persistent_queue => seqHash` arm — closes a hash/eq inconsistency).
fn isSeqKeyValue(v: Value) bool {
    return switch (v.tag()) {
        .vector, .list, .map_entry, .persistent_queue, .lazy_seq, .range, .chunked_cons => true,
        .typed_instance, .reified_instance => isSequential(v),
        else => false,
    };
}

/// A key that can never be a sequential key NOR a custom-equiv deftype/reify
/// instance, so `eqConsult`'s ambient-env block is a no-op for it. Used to take
/// the rt-free `keyEqValue` fast path WITHOUT reading `dispatch.current_env`
/// (the threadlocal cost the hot map-get / `:keys`-destructure path pays per
/// `keyEq`). Both operands must qualify (an instance on EITHER side could carry
/// a custom equiv matching a simple value).
fn isSimpleEqKey(v: Value) bool {
    return switch (v.tag()) {
        .keyword, .symbol, .string, .integer, .char, .boolean, .nil => true,
        else => false,
    };
}

/// Realize a sequential key to a form the rt-free `seqKeyEq` can walk: lazy /
/// range / chunked / cons-over-lazy → a fully-realized list; a Sequential
/// instance → its realized list; vector / map_entry / queue are returned as-is
/// (they already walk rt-free). Partner of `realizeKeyForCompare`'s callers.
fn realizeKeyForCompare(rt: *Runtime, env: *Env, v: Value) anyerror!Value {
    return switch (v.tag()) {
        .lazy_seq, .range, .chunked_cons, .list => try realizeSeqToList(rt, env, v),
        .typed_instance, .reified_instance => if (isSequential(v)) try realizeSequentialInstance(rt, env, v) else v,
        else => v,
    };
}

/// rt-aware key equality (ADR-0129 + Track D D1): reading the ambient
/// `dispatch.current_env`. Two sequential keys compare element-wise — the rt-free
/// walk first, then (on a lazy/range/chunked/cons-over-lazy/Sequential-instance
/// operand that truncates it) realize both and retry (D-432/D-408); this is ahead
/// of a custom equiv, mirroring valueEqual routing isSequential first. Otherwise a
/// non-record deftype/reify `equiv` is consulted (EITHER operand, so a custom-equiv
/// deftype dedups regardless of insertion order). Unarmed ⇒ the rt-free
/// `keyEqValue`. A user `equiv` that throws propagates (no silent swallow).
pub fn eqConsult(a: Value, b: Value) ClojureWasmError!bool {
    // PERF: both operands simple (keyword/symbol/string/number/char/bool/nil) →
    // neither a seq-key nor a custom-equiv instance, so the ambient-env block
    // below would just fall through to `keyEqValue` anyway. Take it directly and
    // skip the `dispatch.current_env` threadlocal read (~20% of destructure's
    // leaf self-time was this per-`keyEq` TLV). [refs: O-049]
    if (isSimpleEqKey(a) and isSimpleEqKey(b)) return keyEqValue(a, b);
    if (dispatch_mod.current_env) |env| {
        if (isSeqKeyValue(a) and isSeqKeyValue(b)) {
            if (seqKeyEqChecked(a, b)) |r| return r;
            // A lazy tail truncated the rt-free walk — realize both keys (GC-root
            // the first realized list while the second realizes) and compare.
            var roots: [2]Value = .{ a, b };
            var sp: u16 = 2;
            var gc_frame: root_set.EvalFrame = .{ .stack = &roots, .sp = &sp, .locals = &.{}, .parent = root_set.eval_frame_head };
            root_set.eval_frame_head = &gc_frame;
            defer root_set.eval_frame_head = gc_frame.parent;
            const ar = realizeKeyForCompare(env.rt, env, a) catch |e| return @errorCast(e);
            roots[0] = ar;
            const br = realizeKeyForCompare(env.rt, env, b) catch |e| return @errorCast(e);
            roots[1] = br;
            return seqKeyEq(ar, br);
        }
        // keyInstanceEq is typed `anyerror` (it calls dispatch); narrow with
        // @errorCast at this single boundary so map.keyEq keeps its error set.
        if (keyInstanceEq(env.rt, env, a, b) catch |e| return @errorCast(e)) |r| {
            if (r) return true;
        }
        if (keyInstanceEq(env.rt, env, b, a) catch |e| return @errorCast(e)) |r| {
            if (r) return true;
        }
    }
    return keyEqValue(a, b);
}

/// Key equality consult for a non-record deftype/reify `x`: dispatch its
/// `equiv` (clj IPersistentCollection) then `equals` (Object) — clj's
/// `Util.equiv` uses `pcequiv` for collections and `.equals` for a plain
/// deftype, so a deftype keying a map via either impl dedups. Returns the
/// impl's truthiness, or null when `x` is not a consultable instance (defrecord
/// / native / impl-less) — the caller then falls to the rt-free `keyEqValue`
/// (which already handles defrecord structural key equality).
fn keyInstanceEq(rt: *Runtime, env: *Env, x: Value, other: Value) anyerror!?bool {
    const t = x.tag();
    if (t != .typed_instance and t != .reified_instance) return null;
    if (t == .typed_instance and x.decodePtr(*const td_mod.TypedInstance).descriptor.kind == .defrecord) return null;
    var cs: dispatch_mod.CallSite = .{};
    if (try dispatch_mod.dispatchOrNull(rt, env, &cs, x, "Object", "equiv", &.{ x, other }, .{ .line = 0, .column = 0 })) |r|
        return r.isTruthy();
    if (try dispatch_mod.dispatchOrNull(rt, env, &cs, x, "Object", "equals", &.{ x, other }, .{ .line = 0, .column = 0 })) |r|
        return r.isTruthy();
    return null;
}

/// Record value equality (Clojure defrecord overrides equals): same
/// descriptor (type) + every declared field equal, recursively. deftype
/// keeps identity semantics (no auto equals) — two distinct deftype
/// instances reach here non-bit-identical, so `false` is correct. A
/// record is never `=` to a plain map: the caller's same-tag gate already
/// excludes the map tags before this arm.
fn typedInstanceEqual(rt: *Runtime, env: *Env, a: Value, b: Value) anyerror!bool {
    // Date values (D-200 / ADR-0079) compare by epoch-ms — a native
    // typed_instance otherwise defaults to identity `=` (the arm below),
    // which would make two equal `#inst` allocations unequal.
    if (date_mod.isDate(rt, a) and date_mod.isDate(rt, b)) {
        return date_mod.epochMsOf(a) == date_mod.epochMsOf(b);
    }
    // Timestamp values (D-382) compare by epoch-ms + nanos (the full
    // fractional second), else two equal-instant Timestamps would default to
    // identity `=`. A Timestamp is never `=` a Date here (distinct descriptor).
    if (timestamp_mod.isTimestamp(rt, a) and timestamp_mod.isTimestamp(rt, b)) {
        return timestamp_mod.epochMsOf(a) == timestamp_mod.epochMsOf(b) and
            timestamp_mod.nanosOf(a) == timestamp_mod.nanosOf(b);
    }
    // Instant values (D-462) compare by second-aligned epoch-ms + nanos, else
    // two equal-instant allocations would default to identity `=`. A distinct
    // descriptor keeps an Instant from being `=` a Date/Timestamp here.
    if (instant_value_mod.isInstant(rt, a) and instant_value_mod.isInstant(rt, b)) {
        return instant_value_mod.epochMsOf(a) == instant_value_mod.epochMsOf(b) and
            instant_value_mod.nanosOf(a) == instant_value_mod.nanosOf(b);
    }
    // Duration values (D-462) compare by NORMALIZED seconds + nanos, else two
    // equal-span allocations would default to identity `=`. A distinct
    // descriptor keeps a Duration from being `=` an Instant/Date/Timestamp.
    if (duration_value_mod.isDuration(rt, a) and duration_value_mod.isDuration(rt, b)) {
        return duration_value_mod.secondsOf(a) == duration_value_mod.secondsOf(b) and
            duration_value_mod.nanosOf(a) == duration_value_mod.nanosOf(b);
    }
    // D-280d1: a deftype/reify implementing Object `equals` overrides identity.
    // Consulted for the same-type case (both operands reached here past
    // valueEqual's tag gate, so a == b's tag); cross-type `(= inst other)` short-
    // circuits before this arm and is a tracked gap (D-280d8, IPersistentCollection
    // equiv / pre-tag-gate consult). Returns the impl's truthiness.
    {
        var cs: dispatch_mod.CallSite = .{};
        // clj collections override `equiv` (IPersistentCollection); `=` prefers it.
        // Fall back to `equals` (Object). Same-type only (D-280d8 cross-type residual).
        if (try dispatch_mod.dispatchOrNull(rt, env, &cs, a, "Object", "equiv", &.{ a, b }, .{ .line = 0, .column = 0 })) |r|
            return r.isTruthy();
        if (try dispatch_mod.dispatchOrNull(rt, env, &cs, a, "Object", "equals", &.{ a, b }, .{ .line = 0, .column = 0 })) |r|
            return r.isTruthy();
    }
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
    // D-086 / ADR-0154: extmap is part of record value identity (unlike meta).
    // valueEqual compares nil↔nil, map↔map (content), nil↔map → false; empty
    // extmap normalizes to nil so `(= (assoc r :z 9) (-> r (assoc :z 9)))` holds.
    return try valueEqual(rt, env, ia.extmap, ib.extmap);
}
