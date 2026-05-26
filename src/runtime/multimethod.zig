// SPDX-License-Identifier: EPL-2.0
//! Multimethod dispatch — ADR-0008 Phase 7.2 amendment (Alt 1).
//!
//! Per the Phase 7.2 amendment, `defmulti` / `defmethod` are
//! Clojure-side macros expanding to primitive constructor + `def`
//! calls; multimethod dispatch lives here, invoked through the
//! `.multi_fn` arm of `vtable.callFn` (Group B slot 1, F-004).
//! No new analyzer Node variants; no new VM opcodes; both
//! backends share this single runtime body.
//!
//! ### Shape
//!
//! `MultiFn` carries the JVM-shape field set (per survey §5.1):
//! a dispatch fn + method table + prefer table + hierarchy ref +
//! method cache + last-snapshot of the hierarchy for cache-
//! validity comparison. The struct is `extern` so the HeapHeader
//! is guaranteed at offset 0 for `GcHeap.alloc`; the `name`
//! field is a Symbol Value (NaN-boxed u64) rather than a slice
//! because `extern struct` forbids fat pointers. Render the name
//! by dereferencing the Symbol Value through `symbol.asSymbol`.
//!
//! ### `getMethod` resolution (incremental landing)
//!
//! Cycle 1 (this commit) implements the exact-match + default
//! fallback + raise paths. isa? walk + prefer-method conflict
//! resolution + cache invalidation arrive in cycles 2-5 within
//! row 7.2 (each red-green-refactor before the next).

const std = @import("std");
const value = @import("value/value.zig");
const Value = value.Value;
const HeapHeader = value.HeapHeader;
const HeapTag = value.HeapTag;
const Runtime = @import("runtime.zig").Runtime;
const map_mod = @import("collection/map.zig");
const set_mod = @import("collection/set.zig");
const error_catalog = @import("error/catalog.zig");
const symbol = @import("symbol.zig");

const SourceLocation = error_catalog.SourceLocation;

/// Heap-allocated multimethod value. Sits on F-004 Group B slot 1
/// (`.multi_fn`). Mirrors `clojure.lang.MultiFn`'s field set: the
/// dispatch fn produces a dispatch-value from the call args; the
/// method table maps dispatch-values to method Values; the cache
/// memoises resolution per dispatch-value; the snapshot field is
/// the basis for cache invalidation when the hierarchy mutates.
pub const MultiFn = extern struct {
    header: HeapHeader,

    /// Multimethod name as an interned Symbol Value (e.g. the
    /// Symbol `clojure.core/print-method`). Stored as a Value
    /// rather than a slice so the layout stays C-ABI compatible.
    /// Render with `symbol.asSymbol(mf.name).name` for the bare
    /// name or `formatQualified` for the qualified form.
    name: Value,

    /// `(dispatch_fn args...) -> dispatch_val`. Usually a fn Value
    /// or a Keyword (the keyword-as-fn fast path, JVM-compatible).
    /// `nil` is reserved for synthetic test fixtures only — the
    /// Clojure `defmulti` macro always supplies a dispatch fn.
    dispatch_fn: Value,

    /// Dispatch-val used when no other method matches. Defaults
    /// to `:default` per `defmulti`'s `:default` option.
    default_dispatch_val: Value,

    /// `IRef` holding a hierarchy map `{:parents .. :descendants ..
    /// :ancestors ..}`. `nil` ⇒ uses `clojure.core/global-hierarchy`.
    /// Always an IRef (Var / Atom), never the hierarchy map directly
    /// — matches JVM (`MultiFn.hierarchy: IRef`).
    hierarchy_ref: Value,

    /// `PersistentArrayMap` mapping dispatch-val → method fn.
    /// Empty map at construction; `defmethod` `assoc`s entries.
    method_table: Value,

    /// `PersistentArrayMap` mapping dispatch-val → set of dispatch-
    /// vals it is preferred over (`prefer-method`). Empty map at
    /// construction.
    prefer_table: Value,

    /// `PersistentArrayMap` memoising resolved (dispatch_val →
    /// method) lookups. Invalidated on `defmethod` / `remove-method` /
    /// `prefer-method` / detected hierarchy drift.
    method_cache: Value,

    /// Snapshot of `hierarchy_ref.deref()` at last cache fill.
    /// Identity-compared (`==`) against fresh `hierarchy_ref.deref()`
    /// at each lookup — if it shifted, the cache is reset before the
    /// resolve walks. Matches JVM `cachedHierarchy` invalidation
    /// predicate.
    cached_hierarchy_snapshot: Value,
};

/// cw v1 `isa?` check, cycle-2 scope: equality + hierarchy
/// ancestors-map lookup. Mirrors `clojure.core/isa?` steps 1 + 3.
/// Step 2 (`Class.isAssignableFrom`) and step 4 (`supers` walk)
/// have no JVM-direct equivalent in cw v1 per ADR-0007 Option β +
/// `.claude/rules/no_jvm_specific_assumption.md` — they will be
/// replaced by the TypeDescriptor walk DIVERGENCE in a later
/// cycle (cw-side replacement for JVM class hierarchy).
///
/// `hierarchy_ancestors` is the `:ancestors` sub-map of a
/// hierarchy struct: `{child #{ancestor1 ancestor2 ...}, ...}`.
/// `nil` means "no hierarchy" — falls back to equality only.
/// cycle 4 introduces the full-hierarchy IRef deref + `:ancestors`
/// extraction inside `getMethod`; until then the test fixture
/// passes the ancestors-map directly via `hierarchy_ref`.
pub fn isaCheck(hierarchy_ancestors: Value, child: Value, parent: Value) !bool {
    if (@intFromEnum(child) == @intFromEnum(parent)) return true;

    if (hierarchy_ancestors.tag() == .nil) return false;

    const child_ancestors = try map_mod.get(hierarchy_ancestors, child);
    if (child_ancestors.tag() != .hash_set) return false;
    return try set_mod.contains(child_ancestors, parent);
}

/// Resolve `dispatch_val` to a method Value on `mf`.
///
/// Resolution order:
///   1. Exact match in `method_table` → return.
///   2. Hierarchy walk via `isaCheck`. Zero matches → continue.
///      One match → return. >1 matches → raise
///      `multimethod_ambiguous_dispatch` (cycle 3 will use
///      `prefer-method` to resolve before raising).
///   3. Default fallback (`default_dispatch_val`) → return.
///   4. No method anywhere → raise `multimethod_no_method`.
///
/// `mf.hierarchy_ref` carries the ancestors-map for cycle 2 (no
/// IRef indirection yet — cycle 4 wires `deref()` and full
/// `:ancestors` extraction). `mf.method_cache` is unused until
/// cycle 4 lights it up.
pub fn getMethod(
    rt: *Runtime,
    mf: *const MultiFn,
    dispatch_val: Value,
    loc: SourceLocation,
) anyerror!Value {
    _ = rt;

    const direct = try map_mod.get(mf.method_table, dispatch_val);
    if (direct.tag() != .nil) return direct;

    var candidate: ?Value = null;
    var ambiguous = false;
    if (mf.method_table.tag() == .array_map) {
        const am = mf.method_table.decodePtr(*const map_mod.ArrayMap);
        var i: u32 = 0;
        while (i < am.count) : (i += 1) {
            const key = am.entries[2 * i];
            if (@intFromEnum(key) == @intFromEnum(dispatch_val)) continue;
            if (try isaCheck(mf.hierarchy_ref, dispatch_val, key)) {
                if (candidate != null) {
                    ambiguous = true;
                } else {
                    candidate = am.entries[2 * i + 1];
                }
            }
        }
    }
    if (ambiguous) {
        const name_sym = symbol.asSymbol(mf.name);
        return error_catalog.raise(.multimethod_ambiguous_dispatch, loc, .{
            .name = name_sym.name,
        });
    }
    if (candidate) |c| return c;

    const fallback = try map_mod.get(mf.method_table, mf.default_dispatch_val);
    if (fallback.tag() != .nil) return fallback;

    const name_sym = symbol.asSymbol(mf.name);
    return error_catalog.raise(.multimethod_no_method, loc, .{
        .name = name_sym.name,
    });
}

// --- tests ---

const testing = std.testing;
const keyword = @import("keyword.zig");

const TestFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,

    fn init(self: *TestFixture, alloc: std.mem.Allocator) void {
        self.threaded = std.Io.Threaded.init(alloc, .{});
        self.rt = Runtime.init(self.threaded.io(), alloc);
    }

    fn deinit(self: *TestFixture) void {
        self.rt.deinit();
        self.threaded.deinit();
    }
};

/// Allocate a synthetic MultiFn for tests. `method_table` is the
/// caller's responsibility — empty / populated map as needed.
fn makeTestMultiFn(rt: *Runtime, name_sym: Value, method_table: Value, default_kw: Value) !*MultiFn {
    const mf = try rt.gc.alloc(MultiFn);
    mf.* = .{
        .header = HeapHeader.init(.multi_fn),
        .name = name_sym,
        .dispatch_fn = Value.nil_val,
        .default_dispatch_val = default_kw,
        .hierarchy_ref = Value.nil_val,
        .method_table = method_table,
        .prefer_table = map_mod.empty(),
        .method_cache = map_mod.empty(),
        .cached_hierarchy_snapshot = Value.nil_val,
    };
    return mf;
}

test "MultiFn header carries the multi_fn tag" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const name_sym = try symbol.intern(&fix.rt, "test", "f");
    const default_kw = try keyword.intern(&fix.rt, null, "default");
    const mf = try makeTestMultiFn(&fix.rt, name_sym, map_mod.empty(), default_kw);
    try testing.expectEqual(@as(u8, @intFromEnum(HeapTag.multi_fn)), mf.header.tag);
}

test "getMethod raises multimethod_no_method when method_table is empty and no default" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const name_sym = try symbol.intern(&fix.rt, "test", "f");
    const default_kw = try keyword.intern(&fix.rt, null, "default");
    const mf = try makeTestMultiFn(&fix.rt, name_sym, map_mod.empty(), default_kw);

    const missing = try keyword.intern(&fix.rt, null, "missing");
    try testing.expectError(
        error.ValueError,
        getMethod(&fix.rt, mf, missing, .{}),
    );
}

test "getMethod returns method on exact dispatch_val match" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const name_sym = try symbol.intern(&fix.rt, "test", "f");
    const default_kw = try keyword.intern(&fix.rt, null, "default");
    const kw_a = try keyword.intern(&fix.rt, null, "a");

    // Use a distinct keyword as the "method" so the equality check
    // is meaningful without yet wiring fn Values through GC.
    const sentinel_method = try keyword.intern(&fix.rt, null, "method-a");
    const mt = try map_mod.assoc(&fix.rt, map_mod.empty(), kw_a, sentinel_method);

    const mf = try makeTestMultiFn(&fix.rt, name_sym, mt, default_kw);

    const got = try getMethod(&fix.rt, mf, kw_a, .{});
    try testing.expectEqual(@intFromEnum(sentinel_method), @intFromEnum(got));
}

test "getMethod falls through to default when exact match misses" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const name_sym = try symbol.intern(&fix.rt, "test", "f");
    const default_kw = try keyword.intern(&fix.rt, null, "default");
    const default_method = try keyword.intern(&fix.rt, null, "method-default");
    const mt = try map_mod.assoc(&fix.rt, map_mod.empty(), default_kw, default_method);

    const mf = try makeTestMultiFn(&fix.rt, name_sym, mt, default_kw);

    const missing = try keyword.intern(&fix.rt, null, "missing");
    const got = try getMethod(&fix.rt, mf, missing, .{});
    try testing.expectEqual(@intFromEnum(default_method), @intFromEnum(got));
}

// --- cycle 2: isaCheck + hierarchy walk ---

test "isaCheck: equality short-circuits regardless of hierarchy" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const kw = try keyword.intern(&fix.rt, null, "x");
    try testing.expect(try isaCheck(Value.nil_val, kw, kw));
}

test "isaCheck: hierarchy ancestors lookup recognises (derive :dog :animal)" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const dog = try keyword.intern(&fix.rt, null, "dog");
    const animal = try keyword.intern(&fix.rt, null, "animal");

    // Hierarchy ancestors-map: {:dog #{:animal}}
    const dog_ancestors_set = try set_mod.conj(&fix.rt, set_mod.empty(), animal);
    const hierarchy_anc = try map_mod.assoc(&fix.rt, map_mod.empty(), dog, dog_ancestors_set);

    try testing.expect(try isaCheck(hierarchy_anc, dog, animal));
    try testing.expect(!(try isaCheck(hierarchy_anc, animal, dog)));
}

test "isaCheck: nil hierarchy falls back to equality only" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const a = try keyword.intern(&fix.rt, null, "a");
    const b = try keyword.intern(&fix.rt, null, "b");
    try testing.expect(!(try isaCheck(Value.nil_val, a, b)));
}

test "getMethod: hierarchy walk returns ancestor's method on isa? match" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const name_sym = try symbol.intern(&fix.rt, "test", "f");
    const default_kw = try keyword.intern(&fix.rt, null, "default");
    const dog = try keyword.intern(&fix.rt, null, "dog");
    const animal = try keyword.intern(&fix.rt, null, "animal");
    const animal_method = try keyword.intern(&fix.rt, null, "method-animal");

    const dog_ancestors_set = try set_mod.conj(&fix.rt, set_mod.empty(), animal);
    const hierarchy_anc = try map_mod.assoc(&fix.rt, map_mod.empty(), dog, dog_ancestors_set);
    const mt = try map_mod.assoc(&fix.rt, map_mod.empty(), animal, animal_method);

    const mf = try rt_gc_makeTestMultiFnWithHierarchy(&fix.rt, name_sym, mt, default_kw, hierarchy_anc);
    const got = try getMethod(&fix.rt, mf, dog, .{});
    try testing.expectEqual(@intFromEnum(animal_method), @intFromEnum(got));
}

test "getMethod: hierarchy walk raises multimethod_ambiguous_dispatch on multiple matches" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const name_sym = try symbol.intern(&fix.rt, "test", "f");
    const default_kw = try keyword.intern(&fix.rt, null, "default");
    const dog = try keyword.intern(&fix.rt, null, "dog");
    const animal = try keyword.intern(&fix.rt, null, "animal");
    const mammal = try keyword.intern(&fix.rt, null, "mammal");
    const animal_method = try keyword.intern(&fix.rt, null, "method-animal");
    const mammal_method = try keyword.intern(&fix.rt, null, "method-mammal");

    // (derive :dog :animal) (derive :dog :mammal) — two ancestors,
    // no prefer-method declared (cycle 3 adds resolution). cw v1
    // raises ambiguity; matches JVM Clojure semantics.
    var dog_ancestors = set_mod.empty();
    dog_ancestors = try set_mod.conj(&fix.rt, dog_ancestors, animal);
    dog_ancestors = try set_mod.conj(&fix.rt, dog_ancestors, mammal);
    const hierarchy_anc = try map_mod.assoc(&fix.rt, map_mod.empty(), dog, dog_ancestors);

    var mt = map_mod.empty();
    mt = try map_mod.assoc(&fix.rt, mt, animal, animal_method);
    mt = try map_mod.assoc(&fix.rt, mt, mammal, mammal_method);

    const mf = try rt_gc_makeTestMultiFnWithHierarchy(&fix.rt, name_sym, mt, default_kw, hierarchy_anc);
    try testing.expectError(
        error.ValueError,
        getMethod(&fix.rt, mf, dog, .{}),
    );
}

test "getMethod: hierarchy walk falls through to default when no isa? match" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const name_sym = try symbol.intern(&fix.rt, "test", "f");
    const default_kw = try keyword.intern(&fix.rt, null, "default");
    const default_method = try keyword.intern(&fix.rt, null, "method-default");
    const dog = try keyword.intern(&fix.rt, null, "dog");
    const animal = try keyword.intern(&fix.rt, null, "animal");

    // method_table = {:animal → method, :default → default-method}
    // No hierarchy ancestors for :dog → no isa? match → default returned.
    var mt = map_mod.empty();
    mt = try map_mod.assoc(&fix.rt, mt, animal, try keyword.intern(&fix.rt, null, "ignored"));
    mt = try map_mod.assoc(&fix.rt, mt, default_kw, default_method);

    const mf = try rt_gc_makeTestMultiFnWithHierarchy(&fix.rt, name_sym, mt, default_kw, Value.nil_val);
    const got = try getMethod(&fix.rt, mf, dog, .{});
    try testing.expectEqual(@intFromEnum(default_method), @intFromEnum(got));
}

/// Like `makeTestMultiFn` but lets the caller supply a non-nil
/// `hierarchy_ref`. cycle 2 test fixtures pass the ancestors-map
/// directly via this arg (no IRef indirection yet).
fn rt_gc_makeTestMultiFnWithHierarchy(
    rt: *Runtime,
    name_sym: Value,
    method_table: Value,
    default_kw: Value,
    hierarchy_ref: Value,
) !*MultiFn {
    const mf = try rt.gc.alloc(MultiFn);
    mf.* = .{
        .header = HeapHeader.init(.multi_fn),
        .name = name_sym,
        .dispatch_fn = Value.nil_val,
        .default_dispatch_val = default_kw,
        .hierarchy_ref = hierarchy_ref,
        .method_table = method_table,
        .prefer_table = map_mod.empty(),
        .method_cache = map_mod.empty(),
        .cached_hierarchy_snapshot = Value.nil_val,
    };
    return mf;
}
