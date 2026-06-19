// SPDX-License-Identifier: EPL-2.0
//! Multimethod dispatch — ADR-0008 amendment (Alt 1).
//!
//! `defmulti` / `defmethod` are Clojure-side macros expanding to
//! primitive constructor + `def` calls; multimethod dispatch lives
//! here, invoked through the
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
//! ### `getMethod` resolution
//!
//! Implements exact-match + default fallback + raise paths, the
//! isa? hierarchy walk, prefer-method conflict resolution, and
//! method-cache invalidation on hierarchy drift.

const std = @import("std");
const value = @import("value/value.zig");
const Value = value.Value;
const HeapHeader = value.HeapHeader;
const HeapTag = value.HeapTag;
const Runtime = @import("runtime.zig").Runtime;
const Env = @import("env.zig").Env;
const map_mod = @import("collection/map.zig");
const set_mod = @import("collection/set.zig");
const error_catalog = @import("error/catalog.zig");
const symbol = @import("symbol.zig");
const keyword = @import("keyword.zig");
const dispatch_mod = @import("dispatch.zig");
const td_mod = @import("type_descriptor.zig");
const class_name_mod = @import("class_name.zig");
const vector_mod = @import("collection/vector.zig");
const gc_heap_mod = @import("gc/gc_heap.zig");
const mark_sweep = @import("gc/mark_sweep.zig");
const tag_ops = @import("gc/tag_ops.zig");
const atom = @import("atom.zig");

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

/// Does `x` dominate `y` for multimethod resolution?
/// JVM `MultiFn.dominates(x, y) = prefers(x, y) || isA(x, y)`.
/// cw v1 calls these `isPreferred` and `isaCheck` respectively.
///
/// `prefer_table` shape: `{x #{y1 y2 ...}, ...}` where x is
/// preferred over each y in the set (matches JVM
/// `preferTable: IPersistentMap`). `isPreferred` resolves **direct**
/// preference; the isa? hierarchy walk in `isaCheck` covers
/// transitive ancestor relations.
pub fn dominates(
    prefer_table: Value,
    hierarchy_ancestors: Value,
    x: Value,
    y: Value,
) !bool {
    if (try isPreferred(prefer_table, x, y)) return true;
    return try isaCheck(hierarchy_ancestors, x, y);
}

/// Direct preference check. Returns true iff `prefer_table[x]`
/// contains `y` (i.e. `(prefer-method f x y)` was called).
/// Transitive ancestor relations are covered by the isa? walk.
pub fn isPreferred(prefer_table: Value, x: Value, y: Value) !bool {
    if (prefer_table.tag() == .nil) return false;
    const preferred_over = try map_mod.get(prefer_table, x);
    if (preferred_over.tag() != .hash_set) return false;
    return try set_mod.contains(preferred_over, y);
}

/// cw v1 `isa?` check: equality + hierarchy ancestors-map lookup +
/// TypeDescriptor parent walk. Mirrors `clojure.core/isa?` steps
/// 1 + 3. Step 2 (`Class.isAssignableFrom`) and step 4 (`supers`
/// walk) have no JVM-direct equivalent in cw v1 per ADR-0007
/// Option β + `.claude/rules/no_jvm_specific_assumption.md` — the
/// `typeDescriptorIsa` walk is the cw-side replacement (DIVERGENCE
/// from JVM class hierarchy).
///
/// `hierarchy_ancestors` is the `:ancestors` sub-map of a
/// hierarchy struct: `{child #{ancestor1 ancestor2 ...}, ...}`.
/// `nil` means "no hierarchy" — falls back to equality only.
/// `getMethod` derefs the full hierarchy IRef and extracts the
/// `:ancestors` sub-map before calling here.
pub fn isaCheck(hierarchy_ancestors: Value, child: Value, parent: Value) !bool {
    if (@intFromEnum(child) == @intFromEnum(parent)) return true;

    // D-464: a VECTOR dispatch value matches a VECTOR method key ELEMENT-WISE
    // (clj `isa?` recurses `(every? isa? cs ps)` for equal-length vectors) — this
    // is what `(defmethod g [::a ::b] …)` / `[Number Number]` dispatch needs.
    // Terminal: equal-length vectors yield the element-wise verdict, mismatched
    // lengths are not `isa?` (clj parity). A non-vector pair falls through.
    if (child.tag() == .vector and parent.tag() == .vector) {
        const n = vector_mod.count(child);
        if (n != vector_mod.count(parent)) return false;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if (!(try isaCheck(hierarchy_ancestors, vector_mod.nth(child, i), vector_mod.nth(parent, i)))) return false;
        }
        return true;
    }

    // D-464: a class VALUE child isa? a class VALUE parent via the class hierarchy
    // (Long isa? Number, vector-class isa? Sequential), through the SAME shared
    // `class_name.classIsa` the `isa?` primitive uses. Only short-circuits on a
    // true match; a class can ALSO sit in an ad-hoc `derive` hierarchy, so a
    // non-match falls through to the ancestors lookup below.
    if (child.tag() == .type_descriptor and parent.tag() == .type_descriptor) {
        const child_fqcn = td_mod.asTypeDescriptorRef(child).fqcn orelse "";
        const parent_fqcn = td_mod.asTypeDescriptorRef(parent).fqcn orelse "";
        if (class_name_mod.classIsa(child_fqcn, parent_fqcn)) return true;
    }

    // Row 7.5 cycle 6 — D-082 discharge: typed_instance + reified_instance
    // children walk their descriptor chain. JVM `clojure.core/isa?` step 2
    // (`Class.isAssignableFrom`) + step 4 (`supers` walk) map onto:
    //   - `descriptor.fqcn` ≡ JVM Class.name
    //   - `descriptor.protocol_impls` ≡ JVM implementedInterfaces walk
    //   - `descriptor.parent` ≡ JVM superclass chain
    // Parent symbol/keyword name is matched against each. Triggered only
    // when child is a TypedInstance / ReifiedInstance and parent is
    // a Named (symbol or keyword) — the JVM analogue's input shape.
    if ((child.tag() == .typed_instance or child.tag() == .reified_instance) and
        (parent.tag() == .symbol or parent.tag() == .keyword))
    {
        const parent_name: []const u8 = if (parent.tag() == .symbol)
            symbol.asSymbol(parent).name
        else
            keyword.asKeyword(parent).name;
        const child_desc: *const td_mod.TypeDescriptor = if (child.tag() == .typed_instance)
            child.decodePtr(*const td_mod.TypedInstance).descriptor
        else
            child.decodePtr(*const td_mod.ReifiedInstance).descriptor;
        if (typeDescriptorIsa(child_desc, parent_name)) return true;
    }

    if (hierarchy_ancestors.tag() == .nil) return false;

    const child_ancestors = try map_mod.get(hierarchy_ancestors, child);
    if (child_ancestors.tag() != .hash_set) return false;
    return try set_mod.contains(child_ancestors, parent);
}

/// Walk a descriptor's `fqcn` + `protocol_impls` + `parent` chain
/// looking for a match against `parent_name`. Row 7.5 cycle 6 D-082
/// discharge — replaces JVM `Class.isAssignableFrom` + `supers` walk
/// per `.claude/rules/no_jvm_specific_assumption.md` (cw-side
/// equivalent of class hierarchy via TypeDescriptor).
fn typeDescriptorIsa(td: *const td_mod.TypeDescriptor, parent_name: []const u8) bool {
    if (td.fqcn) |fqcn| {
        if (std.mem.eql(u8, fqcn, parent_name)) return true;
    }
    for (td.protocol_impls) |impl| {
        if (std.mem.eql(u8, impl, parent_name)) return true;
    }
    if (td.parent) |p| return typeDescriptorIsa(p, parent_name);
    return false;
}

/// Dereference an IRef-shape hierarchy reference to its held map.
/// `defmulti` threads the `-global-hierarchy` atom (D-161), so an
/// atom ref is deref'd to its current value — and crucially each
/// `derive` (`swap!`) yields a NEW immutable map, so the deref'd
/// value's identity changes, which is exactly what `getMethod`'s
/// `cached_hierarchy_snapshot` identity-compare needs to invalidate
/// the method cache. A non-atom ref (nil, or a hierarchy map passed
/// directly by a unit-test fixture) is returned unchanged.
pub fn derefHierarchy(rt: *Runtime, hierarchy_ref: Value) Value {
    _ = rt;
    if (atom.isAtom(hierarchy_ref)) return atom.current(hierarchy_ref);
    return hierarchy_ref;
}

/// Resolve `dispatch_val` to a method Value on `mf`.
///
/// Resolution order:
///   0a. If `cached_hierarchy_snapshot` differs from the current
///       `derefHierarchy(hierarchy_ref)` (identity), reset
///       `method_cache` and update the snapshot.
///   0b. `method_cache.get(dispatch_val)` → return.
///   1. Exact match in `method_table` → return.
///   2. Hierarchy walk via `isaCheck`. Zero matches → continue.
///      One match → return. >1 matches → `dominates` (prefer ∪
///      isa) selects best; no dominator → raise
///      `multimethod_ambiguous_dispatch`.
///   3. Default fallback (`default_dispatch_val`) → return.
///   4. No method anywhere → raise `multimethod_no_method`.
///
/// Steps 1-4 update `method_cache` via `assoc` before returning.
/// Cache invalidation on `defmethod` table mutation is the
/// responsibility of the mutating primitives (cycle 5's
/// `__add_method!` / `__remove_method!` reset `method_cache`
/// themselves — JVM Clojure's `MultiFn.addMethod` follows the
/// same pattern).
pub fn getMethod(
    rt: *Runtime,
    mf: *MultiFn,
    dispatch_val: Value,
    loc: SourceLocation,
) anyerror!Value {
    const current_hierarchy = derefHierarchy(rt, mf.hierarchy_ref);
    if (@intFromEnum(current_hierarchy) != @intFromEnum(mf.cached_hierarchy_snapshot)) {
        mf.method_cache = map_mod.empty();
        mf.cached_hierarchy_snapshot = current_hierarchy;
    }

    const cached = try map_mod.get(mf.method_cache, dispatch_val);
    if (cached.tag() != .nil) return cached;

    const direct = try map_mod.get(mf.method_table, dispatch_val);
    if (direct.tag() != .nil) {
        mf.method_cache = try map_mod.assoc(rt, mf.method_cache, dispatch_val, direct);
        return direct;
    }

    // The isa? walk consumes the `:ancestors` sub-map of the derefed
    // hierarchy `{:parents .. :ancestors .. :descendants ..}`; extract it
    // only here (the cache-hit / exact-match paths above never need it).
    // nil (no hierarchy) → nil ancestors → equality-only dispatch.
    const ancestors = if (current_hierarchy.tag() == .nil)
        Value.nil_val
    else
        try map_mod.get(current_hierarchy, try keyword.intern(rt, null, "ancestors"));

    // Cycle 2-3 hierarchy resolution: collect isa? candidates;
    // if ≥ 2 use `dominates` (prefer-method ∪ isa?) to pick the
    // best; if no dominator survives the walk → raise ambiguity.
    var best_key: ?Value = null;
    var best_method: ?Value = null;
    var ambiguous = false;
    if (mf.method_table.tag() == .array_map) {
        const am = mf.method_table.decodePtr(*const map_mod.ArrayMap);
        var i: u32 = 0;
        while (i < am.count) : (i += 1) {
            const key = am.entries[2 * i];
            if (@intFromEnum(key) == @intFromEnum(dispatch_val)) continue;
            if (!(try isaCheck(ancestors, dispatch_val, key))) continue;

            if (best_key) |bk| {
                if (try dominates(mf.prefer_table, ancestors, key, bk)) {
                    best_key = key;
                    best_method = am.entries[2 * i + 1];
                    ambiguous = false;
                } else if (!(try dominates(mf.prefer_table, ancestors, bk, key))) {
                    ambiguous = true;
                }
            } else {
                best_key = key;
                best_method = am.entries[2 * i + 1];
            }
        }
    }
    if (ambiguous) {
        const name_sym = symbol.asSymbol(mf.name);
        return error_catalog.raise(.multimethod_ambiguous_dispatch, loc, .{
            .name = name_sym.name,
        });
    }
    if (best_method) |c| {
        mf.method_cache = try map_mod.assoc(rt, mf.method_cache, dispatch_val, c);
        return c;
    }

    const fallback = try map_mod.get(mf.method_table, mf.default_dispatch_val);
    if (fallback.tag() != .nil) {
        mf.method_cache = try map_mod.assoc(rt, mf.method_cache, dispatch_val, fallback);
        return fallback;
    }

    const name_sym = symbol.asSymbol(mf.name);
    return error_catalog.raise(.multimethod_no_method, loc, .{
        .name = name_sym.name,
    });
}

/// Invoke a multimethod Value as a callable. Routes via:
///   1. evaluate `mf.dispatch_fn(args)` → `dispatch_val`
///   2. `getMethod(rt, mf, dispatch_val, loc)` → `method`
///   3. evaluate `method(args)` → return
///
/// Both step-1 and step-3 go through `rt.vtable.callFn`, so the
/// dispatch fn and method can be any callable Value (`.fn_val`,
/// `.builtin_fn`, `.keyword` fast-path, even another `.multi_fn`).
/// This is the function `vtable.callFn`'s `.multi_fn` arm routes
/// to per ADR-0008 Phase 7.2 amendment (Alt 1).
pub fn callMultiFn(
    rt: *Runtime,
    env: *Env,
    multi: Value,
    args: []const Value,
    loc: SourceLocation,
) anyerror!Value {
    const mf: *MultiFn = multi.decodePtr(*MultiFn);
    const vt = rt.vtable orelse return error.NoVTable;
    const dispatch_val = try vt.callFn(rt, env, mf.dispatch_fn, args, loc);
    const method = try getMethod(rt, mf, dispatch_val, loc);
    return vt.callFn(rt, env, method, args, loc);
}

/// Per-tag GC trace for `.multi_fn` (D-253). A `MultiFn` is `gc.alloc`'d and
/// owns 8 GC-managed Value fields reachable ONLY through it — above all the
/// `method_table` (dispatch-val → method). Without this trace the multi_fn is
/// marked as a leaf and its method table is swept under a collect, so dispatch
/// finds "No method for dispatch value" (a torture-surfaced missing-trace gap).
pub fn traceGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const mf: *MultiFn = @ptrCast(@alignCast(header));
    inline for (.{ mf.name, mf.dispatch_fn, mf.default_dispatch_val, mf.hierarchy_ref, mf.method_table, mf.prefer_table, mf.method_cache, mf.cached_hierarchy_snapshot }) |field| {
        if (field.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    }
}

/// Register the `.multi_fn` trace. Called from `Runtime.init`.
pub fn registerGcHooks() void {
    tag_ops.registerTrace(.multi_fn, &traceGc);
}

// --- tests ---

const testing = std.testing;

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

test "isaCheck: typed_instance child matches descriptor.fqcn against Symbol parent (D-082)" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    // Synthetic descriptor with fqcn "Foo".
    const td = try testing.allocator.create(td_mod.TypeDescriptor);
    defer testing.allocator.destroy(td);
    td.* = .{
        .fqcn = "Foo",
        .kind = .defrecord,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = Value.nil_val,
    };
    const inst_val = try td_mod.allocInstance(&fix.rt, td, &.{});
    const foo_sym = try symbol.intern(&fix.rt, null, "Foo");
    const bar_sym = try symbol.intern(&fix.rt, null, "Bar");
    try testing.expect(try isaCheck(Value.nil_val, inst_val, foo_sym));
    try testing.expect(!(try isaCheck(Value.nil_val, inst_val, bar_sym)));
}

test "isaCheck: typed_instance child walks protocol_impls list (D-082)" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const impls = [_][]const u8{ "Drawable", "Serializable" };
    const td = try testing.allocator.create(td_mod.TypeDescriptor);
    defer testing.allocator.destroy(td);
    td.* = .{
        .fqcn = "Shape",
        .kind = .defrecord,
        .field_layout = null,
        .protocol_impls = &impls,
        .method_table = &.{},
        .parent = null,
        .meta = Value.nil_val,
    };
    const inst_val = try td_mod.allocInstance(&fix.rt, td, &.{});
    const drawable_sym = try symbol.intern(&fix.rt, null, "Drawable");
    const unknown_sym = try symbol.intern(&fix.rt, null, "Unknown");
    try testing.expect(try isaCheck(Value.nil_val, inst_val, drawable_sym));
    try testing.expect(!(try isaCheck(Value.nil_val, inst_val, unknown_sym)));
}

test "isaCheck: reified_instance child walks descriptor like typed_instance (D-082)" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const impls = [_][]const u8{"IProto"};
    const td = try testing.allocator.create(td_mod.TypeDescriptor);
    defer testing.allocator.destroy(td);
    td.* = .{
        .fqcn = null,
        .kind = .reify_anon,
        .field_layout = null,
        .protocol_impls = &impls,
        .method_table = &.{},
        .parent = null,
        .meta = Value.nil_val,
    };
    const inst_val = try td_mod.allocReifiedInstance(&fix.rt, td);
    const iproto_sym = try symbol.intern(&fix.rt, null, "IProto");
    try testing.expect(try isaCheck(Value.nil_val, inst_val, iproto_sym));
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

    const mf = try rt_gc_makeTestMultiFnWithHierarchy(&fix.rt, name_sym, mt, default_kw, try wrapAncestors(&fix.rt, hierarchy_anc));
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

    const mf = try rt_gc_makeTestMultiFnWithHierarchy(&fix.rt, name_sym, mt, default_kw, try wrapAncestors(&fix.rt, hierarchy_anc));
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

/// Wrap an `:ancestors` sub-map into a full hierarchy map
/// `{:ancestors <map>}` — the shape `getMethod` derefs and indexes
/// after D-161. Unit fixtures build the bare ancestors-map, then wrap.
fn wrapAncestors(rt: *Runtime, ancestors_map: Value) !Value {
    const anc_kw = try keyword.intern(rt, null, "ancestors");
    return map_mod.assoc(rt, map_mod.empty(), anc_kw, ancestors_map);
}

/// Like `makeTestMultiFn` but lets the caller supply a non-nil
/// `hierarchy_ref`. Fixtures wrap their ancestors-map via
/// `wrapAncestors` so the deref'd `:ancestors` extraction in
/// `getMethod` finds it (D-161).
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

// --- cycle 3: prefer-method + dominates() ---

test "isPreferred: direct preference recognised" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const a = try keyword.intern(&fix.rt, null, "a");
    const b = try keyword.intern(&fix.rt, null, "b");

    // (prefer-method f :a :b) → prefer_table[:a] = #{:b}
    const a_over = try set_mod.conj(&fix.rt, set_mod.empty(), b);
    const prefer = try map_mod.assoc(&fix.rt, map_mod.empty(), a, a_over);

    try testing.expect(try isPreferred(prefer, a, b));
    try testing.expect(!(try isPreferred(prefer, b, a)));
}

test "isPreferred: empty prefer table returns false" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const a = try keyword.intern(&fix.rt, null, "a");
    const b = try keyword.intern(&fix.rt, null, "b");
    try testing.expect(!(try isPreferred(Value.nil_val, a, b)));
    try testing.expect(!(try isPreferred(map_mod.empty(), a, b)));
}

test "dominates: prefer-method short-circuits over isa?" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const a = try keyword.intern(&fix.rt, null, "a");
    const b = try keyword.intern(&fix.rt, null, "b");

    const a_over = try set_mod.conj(&fix.rt, set_mod.empty(), b);
    const prefer = try map_mod.assoc(&fix.rt, map_mod.empty(), a, a_over);

    // No hierarchy relation, prefer wins.
    try testing.expect(try dominates(prefer, Value.nil_val, a, b));
}

test "getMethod: prefer-method resolves isa? ambiguity" {
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

    // (derive :dog :animal) (derive :dog :mammal) — both isa?.
    var dog_ancestors = set_mod.empty();
    dog_ancestors = try set_mod.conj(&fix.rt, dog_ancestors, animal);
    dog_ancestors = try set_mod.conj(&fix.rt, dog_ancestors, mammal);
    const hierarchy_anc = try map_mod.assoc(&fix.rt, map_mod.empty(), dog, dog_ancestors);

    var mt = map_mod.empty();
    mt = try map_mod.assoc(&fix.rt, mt, animal, animal_method);
    mt = try map_mod.assoc(&fix.rt, mt, mammal, mammal_method);

    // (prefer-method f :mammal :animal) — mammal beats animal.
    const mammal_over_animal = try set_mod.conj(&fix.rt, set_mod.empty(), animal);
    const prefer = try map_mod.assoc(&fix.rt, map_mod.empty(), mammal, mammal_over_animal);

    const mf = try fix.rt.gc.alloc(MultiFn);
    mf.* = .{
        .header = HeapHeader.init(.multi_fn),
        .name = name_sym,
        .dispatch_fn = Value.nil_val,
        .default_dispatch_val = default_kw,
        .hierarchy_ref = try wrapAncestors(&fix.rt, hierarchy_anc),
        .method_table = mt,
        .prefer_table = prefer,
        .method_cache = map_mod.empty(),
        .cached_hierarchy_snapshot = Value.nil_val,
    };

    const got = try getMethod(&fix.rt, mf, dog, .{});
    try testing.expectEqual(@intFromEnum(mammal_method), @intFromEnum(got));
}

// --- cycle 4a: method_cache fill + lookup ---

test "getMethod: first call fills method_cache" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const name_sym = try symbol.intern(&fix.rt, "test", "f");
    const default_kw = try keyword.intern(&fix.rt, null, "default");
    const kw_a = try keyword.intern(&fix.rt, null, "a");
    const m_a = try keyword.intern(&fix.rt, null, "method-a");
    const mt = try map_mod.assoc(&fix.rt, map_mod.empty(), kw_a, m_a);
    const mf = try makeTestMultiFn(&fix.rt, name_sym, mt, default_kw);

    _ = try getMethod(&fix.rt, mf, kw_a, .{});

    const cached = try map_mod.get(mf.method_cache, kw_a);
    try testing.expectEqual(@intFromEnum(m_a), @intFromEnum(cached));
}

test "getMethod: second call hits method_cache even after method_table is cleared" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const name_sym = try symbol.intern(&fix.rt, "test", "f");
    const default_kw = try keyword.intern(&fix.rt, null, "default");
    const kw_a = try keyword.intern(&fix.rt, null, "a");
    const m_a = try keyword.intern(&fix.rt, null, "method-a");
    const mt = try map_mod.assoc(&fix.rt, map_mod.empty(), kw_a, m_a);
    const mf = try makeTestMultiFn(&fix.rt, name_sym, mt, default_kw);

    const first = try getMethod(&fix.rt, mf, kw_a, .{});
    try testing.expectEqual(@intFromEnum(m_a), @intFromEnum(first));

    // Pull the rug — without the cache, this would raise
    // multimethod_no_method on the next call.
    mf.method_table = map_mod.empty();

    const second = try getMethod(&fix.rt, mf, kw_a, .{});
    try testing.expectEqual(@intFromEnum(m_a), @intFromEnum(second));
}

// --- cycle 5a: callMultiFn end-to-end ---

fn testCallMultiFnDispatchFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    _ = loc;
    _ = rt;
    return args[0];
}

fn testCallMultiFnMockCallFn(
    rt: *Runtime,
    env: *Env,
    callee: Value,
    args: []const Value,
    loc: SourceLocation,
) anyerror!Value {
    if (callee.tag() == .builtin_fn) {
        const fn_ptr = callee.asBuiltinFn(dispatch_mod.BuiltinFn);
        return fn_ptr(rt, env, args, loc);
    }
    return callee;
}

fn testCallMultiFnTypeKey(val: Value) []const u8 {
    return @tagName(val.tag());
}

test "callMultiFn: routes dispatch_fn → getMethod → method via vtable.callFn" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    fix.rt.vtable = .{
        .callFn = &testCallMultiFnMockCallFn,
        .valueTypeKey = &testCallMultiFnTypeKey,
    };

    const name_sym = try symbol.intern(&fix.rt, "test", "f");
    const default_kw = try keyword.intern(&fix.rt, null, "default");
    const kw_a = try keyword.intern(&fix.rt, null, "a");
    const m_a = try keyword.intern(&fix.rt, null, "method-a");

    const dispatch_fn = Value.initBuiltinFn(&testCallMultiFnDispatchFn);
    const mt = try map_mod.assoc(&fix.rt, map_mod.empty(), kw_a, m_a);

    const mf = try fix.rt.gc.alloc(MultiFn);
    mf.* = .{
        .header = HeapHeader.init(.multi_fn),
        .name = name_sym,
        .dispatch_fn = dispatch_fn,
        .default_dispatch_val = default_kw,
        .hierarchy_ref = Value.nil_val,
        .method_table = mt,
        .prefer_table = map_mod.empty(),
        .method_cache = map_mod.empty(),
        .cached_hierarchy_snapshot = Value.nil_val,
    };
    const multi = Value.encodeHeapPtr(.multi_fn, mf);

    // Call with first arg = :a. dispatch_fn returns args[0] = :a;
    // getMethod(:a) = m_a; mock callFn(method) returns m_a (= the
    // "method" Value, since our mock returns non-builtin callees
    // as-is — stands in for "method was invoked and produced m_a").
    const result = try callMultiFn(&fix.rt, &env, multi, &[_]Value{kw_a}, .{});
    try testing.expectEqual(@intFromEnum(m_a), @intFromEnum(result));
}

test "getMethod: hierarchy change invalidates method_cache" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const name_sym = try symbol.intern(&fix.rt, "test", "f");
    const default_kw = try keyword.intern(&fix.rt, null, "default");
    const dog = try keyword.intern(&fix.rt, null, "dog");
    const animal = try keyword.intern(&fix.rt, null, "animal");
    const mammal = try keyword.intern(&fix.rt, null, "mammal");
    const m_animal = try keyword.intern(&fix.rt, null, "method-animal");
    const m_mammal = try keyword.intern(&fix.rt, null, "method-mammal");

    // hierarchy_1: {:dog #{:animal}}
    const anc1_set = try set_mod.conj(&fix.rt, set_mod.empty(), animal);
    const anc1 = try map_mod.assoc(&fix.rt, map_mod.empty(), dog, anc1_set);

    // hierarchy_2: {:dog #{:mammal}}
    const anc2_set = try set_mod.conj(&fix.rt, set_mod.empty(), mammal);
    const anc2 = try map_mod.assoc(&fix.rt, map_mod.empty(), dog, anc2_set);

    var mt = map_mod.empty();
    mt = try map_mod.assoc(&fix.rt, mt, animal, m_animal);
    mt = try map_mod.assoc(&fix.rt, mt, mammal, m_mammal);

    const mf = try rt_gc_makeTestMultiFnWithHierarchy(&fix.rt, name_sym, mt, default_kw, try wrapAncestors(&fix.rt, anc1));

    // First call resolves :dog via anc1 → :animal → m_animal, caches it.
    const first = try getMethod(&fix.rt, mf, dog, .{});
    try testing.expectEqual(@intFromEnum(m_animal), @intFromEnum(first));

    // Swap the hierarchy. JVM's cachedHierarchy != hierarchy.deref()
    // identity-compare must fire; cw v1's snapshot check is the same
    // shape at the multimethod level.
    mf.hierarchy_ref = try wrapAncestors(&fix.rt, anc2);
    const second = try getMethod(&fix.rt, mf, dog, .{});
    try testing.expectEqual(@intFromEnum(m_mammal), @intFromEnum(second));
}

test "getMethod: default-fallback result also fills method_cache" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const name_sym = try symbol.intern(&fix.rt, "test", "f");
    const default_kw = try keyword.intern(&fix.rt, null, "default");
    const default_method = try keyword.intern(&fix.rt, null, "method-default");
    const mt = try map_mod.assoc(&fix.rt, map_mod.empty(), default_kw, default_method);
    const mf = try makeTestMultiFn(&fix.rt, name_sym, mt, default_kw);

    const missing = try keyword.intern(&fix.rt, null, "missing");
    _ = try getMethod(&fix.rt, mf, missing, .{});

    const cached = try map_mod.get(mf.method_cache, missing);
    try testing.expectEqual(@intFromEnum(default_method), @intFromEnum(cached));
}

test "getMethod: ambiguity persists when prefer-method goes the wrong way" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const name_sym = try symbol.intern(&fix.rt, "test", "f");
    const default_kw = try keyword.intern(&fix.rt, null, "default");
    const dog = try keyword.intern(&fix.rt, null, "dog");
    const animal = try keyword.intern(&fix.rt, null, "animal");
    const mammal = try keyword.intern(&fix.rt, null, "mammal");
    const carnivore = try keyword.intern(&fix.rt, null, "carnivore");
    const animal_method = try keyword.intern(&fix.rt, null, "method-animal");
    const mammal_method = try keyword.intern(&fix.rt, null, "method-mammal");

    // (derive :dog :animal) (derive :dog :mammal); prefer :carnivore
    // over something irrelevant → does NOT resolve animal/mammal.
    var dog_ancestors = set_mod.empty();
    dog_ancestors = try set_mod.conj(&fix.rt, dog_ancestors, animal);
    dog_ancestors = try set_mod.conj(&fix.rt, dog_ancestors, mammal);
    const hierarchy_anc = try map_mod.assoc(&fix.rt, map_mod.empty(), dog, dog_ancestors);

    var mt = map_mod.empty();
    mt = try map_mod.assoc(&fix.rt, mt, animal, animal_method);
    mt = try map_mod.assoc(&fix.rt, mt, mammal, mammal_method);

    const carn_over = try set_mod.conj(&fix.rt, set_mod.empty(), animal);
    const prefer = try map_mod.assoc(&fix.rt, map_mod.empty(), carnivore, carn_over);

    const mf = try fix.rt.gc.alloc(MultiFn);
    mf.* = .{
        .header = HeapHeader.init(.multi_fn),
        .name = name_sym,
        .dispatch_fn = Value.nil_val,
        .default_dispatch_val = default_kw,
        .hierarchy_ref = try wrapAncestors(&fix.rt, hierarchy_anc),
        .method_table = mt,
        .prefer_table = prefer,
        .method_cache = map_mod.empty(),
        .cached_hierarchy_snapshot = Value.nil_val,
    };

    try testing.expectError(
        error.ValueError,
        getMethod(&fix.rt, mf, dog, .{}),
    );
}
