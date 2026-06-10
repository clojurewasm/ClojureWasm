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
    .{ "contains", "contains?" }, // IPersistentSet / java.util
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
    if (!isNativeCollection(receiver.tag())) return null;
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
