// SPDX-License-Identifier: EPL-2.0
//! `clojure.lang.*` read/op method fallback on NATIVE collections (D-371,
//! F-013 definition-derived). clj's native collections implement clojure.lang
//! interfaces directly, so perf-tuned libraries call `(.valAt m k)` / `(.cons
//! coll x)` / `(.count coll)` etc. as Java-interop method calls on Clojure
//! collections (flatland.ordered's `ordered-set`/`ordered-map` constructors do
//! this on their array_map / vector backing stores). cljw routes `(.member recv
//! …)` through `<.member>` dispatch, which has no native-collection arm.
//!
//! This is a DISPATCH-LEVEL fallback both backends consult after a method-table
//! miss + the Object-method miss, mirroring `object_method.tryObjectMethod`:
//! it maps the clojure.lang method NAME to its `clojure.core` equivalent and
//! delegates (the receiver becomes the fn's first arg), so the polymorphism is
//! the core fn's (one source, all collection types). NOT a per-library shim — the
//! table is derived from the clojure.lang collection-interface DEFINITIONS
//! (IPersistentMap / IPersistentCollection / Associative / ILookup / Indexed /
//! Seqable / IPersistentStack / IPersistentSet), so any lib using these on a
//! native collection benefits (F-013 clause 2). Shared by tree_walk + vm so the
//! parity is one source (ADR-0036). Layer 1: imports runtime/ only.

const std = @import("std");
const value_mod = @import("../../runtime/value/value.zig");
const Value = value_mod.Value;
const equal = @import("../../runtime/equal.zig");
const sorted = @import("../../runtime/collection/sorted.zig");
const map_entry_mod = @import("../../runtime/collection/map_entry.zig");
const vector_mod = @import("../../runtime/collection/vector.zig");
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const Env = @import("../../runtime/env.zig").Env;
const SourceLocation = @import("../../runtime/error/info.zig").SourceLocation;

/// clojure.lang method name → its `clojure.core` equivalent (the receiver becomes
/// the core fn's first arg; arities line up: `.valAt m k` → `(get m k)`,
/// `.valAt m k nf` → `(get m k nf)`). Derived from the clojure.lang collection
/// interface definitions, not from any one library's usage.
const METHOD_MAP = std.StaticStringMap([]const u8).initComptime(.{
    .{ "valAt", "get" }, // ILookup
    .{ "cons", "conj" }, // IPersistentCollection
    .{ "count", "count" }, // Counted
    .{ "assoc", "assoc" }, // Associative
    .{ "assocN", "assoc" }, // IPersistentVector (index assoc = assoc)
    .{ "without", "dissoc" }, // IPersistentMap
    .{ "containsKey", "contains?" }, // Associative
    .{ "nth", "nth" }, // Indexed
    .{ "seq", "seq" }, // Seqable
    .{ "peek", "peek" }, // IPersistentStack
    .{ "pop", "pop" }, // IPersistentStack
    .{ "empty", "empty" }, // IPersistentCollection
    .{ "first", "first" }, // ISeq
    .{ "next", "next" }, // ISeq
    .{ "more", "rest" }, // ISeq (more ≈ rest, never nil — close enough for interop)
    .{ "equiv", "=" }, // IPersistentCollection value-equality
    .{ "disjoin", "disj" }, // IPersistentSet
    .{ "contains", "contains?" }, // IPersistentSet ONLY (sequentials take the value-search path; maps rejected before this map is consulted)
    .{ "size", "count" }, // java.util.Collection
    .{ "isEmpty", "empty?" }, // java.util.Collection
    // java.util.Map + Map.Entry read surface (D-379). clj's collections implement
    // java.util.Map/Map.Entry, so libs call these on native colls (flatland.ordered's
    // OrderedMap does `(.get ^Map backing-map k)` / `(.getKey e)` / `(.val e)`). The
    // canonical cljw equivalent (a seq, not a JVM view, per AD-009) is the core fn.
    .{ "get", "get" }, // java.util.Map/get (1-arg value-or-nil; +default = getOrDefault)
    .{ "getOrDefault", "get" }, // java.util.Map/getOrDefault(k, default)
    .{ "getKey", "key" }, // java.util.Map.Entry/getKey
    .{ "getValue", "val" }, // java.util.Map.Entry/getValue
    .{ "key", "key" }, // clojure.lang.IMapEntry/key
    .{ "val", "val" }, // clojure.lang.IMapEntry/val
    .{ "keySet", "keys" }, // java.util.Map/keySet → keys (cljw canonical: a seq)
    .{ "values", "vals" }, // java.util.Map/values → vals
    .{ "entrySet", "seq" }, // java.util.Map/entrySet → seq of entries
    .{ "entryAt", "find" }, // clojure.lang.Associative/entryAt → find (a MapEntry)
});

/// True when `tag` is a native collection clojure.lang methods legitimately apply
/// to — guards the fallback so a `.member` miss on a NON-collection (e.g. a number)
/// still raises the caller's `<.member>` error, not a spurious core-fn coercion.
fn isNativeCollection(tag: Value.Tag) bool {
    return switch (tag) {
        .list, .vector, .array_map, .hash_map, .hash_set, .sorted_map, .sorted_set, .persistent_queue, .range, .map_entry, .cons, .lazy_seq => true,
        else => false,
    };
}

/// The java.util.List-implementing subset (clj's vectors, lists, seqs, queues,
/// MapEntry — everything ordered). Sets/maps are NOT Lists: on clj, `.indexOf`
/// on a set or `.contains` on a map throws, so they fall through to the
/// caller's `<.member>` error here.
fn isSequentialCollection(tag: Value.Tag) bool {
    return switch (tag) {
        .list, .vector, .persistent_queue, .range, .map_entry, .cons, .lazy_seq => true,
        else => false,
    };
}

/// If `name` is a clojure.lang read/op method AND `receiver` is a native
/// collection, delegate to the `clojure.core` equivalent via the vtable and
/// return its result; otherwise `null` so the caller raises its original error.
/// `args` EXCLUDES the receiver (it becomes the core fn's first arg).
pub fn tryClojureLangMethod(
    rt: *Runtime,
    env: *Env,
    receiver: Value,
    name: []const u8,
    args: []const Value,
    loc: SourceLocation,
) !?Value {
    // clojure.lang.AFunction implements java.util.Comparator: `(.compare f a b)`
    // invokes the fn with Comparator int-coercion (clj AFunction.compare —
    // a BOOLEAN comparator fn maps true→-1 / (f b a)→1 / else 0). `.invoke`
    // is the IFn surface itself. data.priority-map's mk-bound-fn does
    // `(.. sc comparator (compare ek key))` on whatever .comparator returned.
    switch (receiver.tag()) {
        .fn_val, .builtin_fn, .multi_fn, .protocol_fn => {
            const vt0 = rt.vtable orelse return null;
            if (std.mem.eql(u8, name, "compare") and args.len == 2) {
                const r = try vt0.callFn(rt, env, receiver, args, loc);
                if (r.tag() == .boolean) {
                    if (r.isTruthy()) return Value.initInteger(-1);
                    const back = try vt0.callFn(rt, env, receiver, &.{ args[1], args[0] }, loc);
                    return Value.initInteger(if (back.isTruthy()) 1 else 0);
                }
                return r;
            }
            if (std.mem.eql(u8, name, "invoke"))
                return try vt0.callFn(rt, env, receiver, args, loc);
            return null;
        },
        else => {},
    }
    if (!isNativeCollection(receiver.tag())) return null;
    // java.util.List value-search trio — no clojure.core equivalent fn exists
    // (clj `.contains` is VALUE membership; core contains? is KEY membership),
    // so these dispatch to the runtime scan instead of the METHOD_MAP delegate.
    if (std.mem.eql(u8, name, "indexOf") or std.mem.eql(u8, name, "lastIndexOf")) {
        if (args.len != 1 or !isSequentialCollection(receiver.tag())) return null;
        const idx = try equal.seqIndexOf(rt, env, receiver, args[0], name[0] == 'l');
        return Value.initInteger(idx);
    }
    // clojure.lang.Sorted method surface on the NATIVE sorted colls
    // (.seqFrom / 2-arity .seq / .entryKey): data.priority-map ships a
    // patched subseq/rsubseq (CLJ-428) that drives ANY Sorted — including a
    // backing PersistentTreeMap — via these dot-calls. Definition-derived
    // (the Sorted interface), not a per-library slot.
    if (receiver.tag() == .sorted_map or receiver.tag() == .sorted_set) {
        if (std.mem.eql(u8, name, "seqFrom") and args.len == 2) {
            // seqFrom(k, asc) = entries from k INCLUSIVE: (subseq sc >= k) /
            // (rsubseq sc <= k).
            const asc = args[1].isTruthy();
            const core_ns = env.findNs("clojure.core") orelse return null;
            const tv = core_ns.resolve(if (asc) ">=" else "<=") orelse return null;
            return try sorted.subseqRange(rt, env, receiver, asc, .{ .test1 = tv.deref(), .key1 = args[0] }, loc);
        }
        if (std.mem.eql(u8, name, "seq") and args.len == 1) {
            return if (args[0].isTruthy()) try sorted.seq(rt, receiver) else try sorted.rseq(rt, receiver);
        }
        if (std.mem.eql(u8, name, "entryKey") and args.len == 1 and receiver.tag() == .sorted_map) {
            const e = args[0];
            return if (e.tag() == .map_entry) map_entry_mod.keyOf(e) else vector_mod.nth(e, 0);
        }
    }
    // clojure.lang.Sorted/comparator on the native sorted colls: the custom
    // `-by` comparator fn when set, else clojure.core/compare (the callable
    // cljw analogue of clj's default Comparator). A Sorted deftype's
    // `(comparator [_] (.comparator backing-sorted-map))` chains through here.
    if (std.mem.eql(u8, name, "comparator") and args.len == 0) {
        const comp = switch (receiver.tag()) {
            .sorted_map => receiver.decodePtr(*const sorted.SortedMap).comparator,
            .sorted_set => receiver.decodePtr(*const sorted.SortedSet).map.decodePtr(*const sorted.SortedMap).comparator,
            else => return null,
        };
        if (!comp.isNil()) return comp;
        const core_ns = env.findNs("clojure.core") orelse return null;
        const v = core_ns.resolve("compare") orelse return null;
        return v.deref();
    }
    if (std.mem.eql(u8, name, "contains") and receiver.tag() != .hash_set and receiver.tag() != .sorted_set) {
        // Sets fall through to METHOD_MAP (Set membership == contains?); maps
        // return null (java.util.Map has no .contains — clj throws).
        if (args.len != 1 or !isSequentialCollection(receiver.tag())) return null;
        return Value.initBoolean(try equal.seqIndexOf(rt, env, receiver, args[0], false) >= 0);
    }
    const core_fn = METHOD_MAP.get(name) orelse return null;
    const core_ns = env.findNs("clojure.core") orelse return null;
    const fn_var = core_ns.resolve(core_fn) orelse return null;
    const vt = rt.vtable orelse return null;
    // Build (receiver, ...args) and call the core fn — its dispatch handles every
    // collection type, so the native-method polymorphism has ONE source.
    const call_args = try rt.gpa.alloc(Value, 1 + args.len);
    defer rt.gpa.free(call_args);
    call_args[0] = receiver;
    @memcpy(call_args[1..], args);
    return try vt.callFn(rt, env, fn_var.deref(), call_args, loc);
}
