// SPDX-License-Identifier: EPL-2.0
//! cw v1 class system — TypeDescriptor / TypedInstance / ReifiedInstance
//! per ADR-0007 Option β.
//!
//! Phase 5.11 activation per ROADMAP §9.7 / 5.11:
//!   - `lookupMethod` (linear search) is now operational.
//!   - `allocInstance` allocates a TypedInstance on `rt.gc.alloc`
//!     (extern struct shape) and wraps it as a typed_instance Value.
//!   - TypedInstance is an extern struct holding a back-pointer to
//!     the TypeDescriptor (process-lifetime; lives on `rt.gc.infra`)
//!     and a flat tail of field Values that the GC traces.
//!   - The trace fn marks each field Value's heap header.
//!
//! TypeDescriptor itself is NOT GC-managed — it is allocated on
//! `rt.gc.infra` (process-lifetime) by the deftype / defrecord
//! analyzer (Phase 5.12). This keeps the descriptor pointer stable
//! for the CallSite cache (`runtime/dispatch/method_table.zig`)
//! without needing GC pinning.

const std = @import("std");
const value_mod = @import("value/value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const Runtime = @import("runtime.zig").Runtime;
const tag_ops = @import("gc/tag_ops.zig");
const gc_heap_mod = @import("gc/gc_heap.zig");
const mark_sweep = @import("gc/mark_sweep.zig");

/// Discriminates `TypeDescriptor`'s origin so dispatch can fast-path
/// the common cases. `native` covers the cw primitive types (String,
/// List, Keyword, ...); `deftype` / `defrecord` cover user
/// `(deftype …)` / `(defrecord …)` forms; `reify_anon` is the
/// anonymous descriptor a `reify` form produces.
pub const TypeKind = enum {
    native,
    deftype,
    defrecord,
    reify_anon,
};

/// Descriptor for one type. Process-lifetime — allocated on
/// `rt.gc.infra` by the deftype / defrecord analyzer.
pub const TypeDescriptor = struct {
    fqcn: ?[]const u8,
    kind: TypeKind,
    /// Field name → slot index, in declaration order. `null` for
    /// `reify_anon` (which has no positional field layout).
    field_layout: ?[]const FieldEntry,
    /// Protocols this descriptor implements (Phase 7 wires the
    /// dispatch cache; Phase 5 declares the names).
    protocol_impls: []const []const u8,
    /// Method table populated at deftype / defrecord / reify analyse
    /// time. `lookupMethod` searches this slice linearly.
    method_table: []const MethodEntry,
    /// Static fields for host-class surfaces — Java `Integer/MAX_VALUE`
    /// etc. (ADR-0061). Resolved by `analyzeSymbol` via the same
    /// `resolveJavaSurface` the static-METHOD path (`analyzeList`) uses,
    /// so a `Class/FIELD` read and a `(Class/method …)` call share one
    /// descriptor-keyed lookup. **Comptime-const** (scalar value +
    /// literal name, no fn pointer) — so, UNLIKE `method_table` (whose
    /// `Value.initBuiltinFn(&fn)` is not comptime on Mac, forcing an
    /// `init`-time alloc + `deinit` free), it needs NEITHER: each surface
    /// sets `.static_fields = &array` directly in its descriptor literal
    /// and `installAll`'s `td.* = ext.descriptor.*` duplicates the slice
    /// pointer to the process-lifetime comptime array. Do NOT move it
    /// into `init` or free it in `deinit`.
    static_fields: []const StaticField = &.{},
    /// Parent descriptor, when `kind == .defrecord` extends another
    /// record (rare but valid in Clojure). `null` otherwise.
    parent: ?*const TypeDescriptor,
    /// User-attached metadata Value (Clojure `meta` map). `nil_val`
    /// when none.
    meta: Value,
    /// Interned boxed identity of this descriptor — the single canonical
    /// `.type_descriptor` Value `makeTypeDescriptorRef` hands out (ADR-0059).
    /// Filled on first wrap, returned on every subsequent call, so two
    /// `(class x)` results are bit-identical and identity equality
    /// (valueEqual / keyEqValue / valueHash) holds without a per-tag arm.
    /// The ref is `rt.gc.infra`-allocated (process-lifetime, never
    /// GC-collected) and the descriptor is per-Runtime, so this never
    /// dangles and needs no GC trace edge.
    ref_cache: ?Value = null,
    /// Reader-tag print form for a host value type (ADR-0079): when
    /// non-null, the printer emits `#<print_tag> "<body>"` instead of the
    /// default `#Name[..]`. Today only `java.util.Date` (`print_tag =
    /// "inst"`, body = the epoch-ms field formatted as the canonical
    /// `#inst` ISO string). `null` for every other type.
    print_tag: ?[]const u8 = null,

    pub const FieldEntry = struct {
        name: []const u8,
        index: u16,
    };

    pub const MethodEntry = struct {
        protocol_name: []const u8,
        method_name: []const u8,
        /// Method body as a callable Value. Tag determines dispatch
        /// path inside `vtable.callFn`:
        ///   - `.builtin_fn` — native Zig BuiltinFn (deftype-inline,
        ///     host extension); wrap via `Value.initBuiltinFn(&zigFn)`.
        ///   - `.fn_val` — user `(fn* [x] body)` from `extend-type`.
        ///   - `.multi_fn` / `.keyword` / `.fn_val` closures — also
        ///     reachable through `vtable.callFn`'s dispatch arms.
        ///   - `.nil_val` — declared-but-not-implemented (definterface-
        ///     style protocol declarations; `dispatch` raises
        ///     `feature_not_supported`).
        /// Per ADR-0008 amendment 3 (cycle 6.6): the prior
        /// `fn_ptr: ?*const anyopaque` shape is retired; one storage
        /// shape per logical concept matches row 7.2's `vtable.callFn`
        /// convergence.
        method_val: Value = Value.nil_val,
    };

    /// A host-class static field: a constant name → scalar value. The
    /// value is kept as a raw scalar (not a `Value`) because a heap
    /// `Value` (BigInt for `Long/MAX_VALUE`) cannot be comptime-const;
    /// `analyzeSymbol` lifts it to a `Value` at analyse time via the
    /// existing literal path (`integerLiteralToValue` / `initFloat`).
    pub const StaticField = struct {
        name: []const u8,
        value: StaticFieldValue,
    };

    /// The two scalar shapes a static field can carry. `int` lifts via
    /// `integerLiteralToValue` (i48 → Long, beyond → BigInt); `float`
    /// via `Value.initFloat`.
    pub const StaticFieldValue = union(enum) {
        int: i64,
        float: f64,
        bool: bool, // Boolean/TRUE, Boolean/FALSE (ADR-0061 am 2026-05-31)
    };

    /// Find a static field by name (ADR-0061). Linear — field tables are
    /// tiny (≤ 2 today). Parallel to `lookupMethod`; walks the parent
    /// chain for symmetry though host surfaces have no parent.
    pub fn lookupStaticField(
        self: *const TypeDescriptor,
        name: []const u8,
    ) ?*const StaticField {
        for (self.static_fields) |*sf| {
            if (std.mem.eql(u8, sf.name, name)) return sf;
        }
        if (self.parent) |p| return p.lookupStaticField(name);
        return null;
    }

    /// Find the method record for `(protocol, method)` on this
    /// descriptor. Linear search — method tables are small (Clojure
    /// typically ≤ 8 methods per protocol). Phase 7's CallSite cache
    /// memoises hot paths so the linear scan is amortised.
    ///
    /// `protocol_name = null` is the row 7.6 cycle 1 (`.method`
    /// syntactic form) shape — match by `method_name` only, returning
    /// the first matching entry across the descriptor's method_table
    /// + parent chain. Survey §3 Path A2.
    pub fn lookupMethod(
        self: *const TypeDescriptor,
        protocol_name: ?[]const u8,
        method_name: []const u8,
    ) ?*const MethodEntry {
        for (self.method_table) |*entry| {
            if (!std.mem.eql(u8, entry.method_name, method_name)) continue;
            if (protocol_name) |pn| {
                if (!std.mem.eql(u8, entry.protocol_name, pn)) continue;
            }
            return entry;
        }
        if (self.parent) |p| return p.lookupMethod(protocol_name, method_name);
        return null;
    }

    /// True iff this descriptor (or a parent) declares `protocol_name` in
    /// its `protocol_impls`. Unlike `protocol.satisfies` (which checks the
    /// `method_table`), this consults the declared-interface list, so it
    /// detects a zero-method MARKER protocol (`Sequential`) that has no
    /// method entry (D-190 / ADR-0068). Shared by the printer's seq-print
    /// discriminator and `sequential?` — one SSOT for both.
    pub fn declaresProtocol(self: *const TypeDescriptor, protocol_name: []const u8) bool {
        for (self.protocol_impls) |p| {
            if (std.mem.eql(u8, p, protocol_name)) return true;
        }
        if (self.parent) |par| return par.declaresProtocol(protocol_name);
        return false;
    }
};

/// A `deftype` / `defrecord` runtime value. **Extern struct** so
/// `rt.gc.alloc` accepts it and the GC walker treats the head as a
/// HeapHeader. The flat field tail is sized at allocation time; the
/// trace fn walks `field_count` entries from `field_values_ptr`.
pub const TypedInstance = extern struct {
    header: HeapHeader,
    field_count: u32,
    _pad: [4]u8 = .{ 0, 0, 0, 0 },
    /// Back-pointer to the (process-lifetime) descriptor. Stable for
    /// the CallSite cache.
    descriptor: *const TypeDescriptor,
    /// Pointer to a `gc.infra`-owned `[]Value` slice. Owned by this
    /// TypedInstance; finaliser releases it.
    field_values_ptr: [*]Value,

    comptime {
        std.debug.assert(@alignOf(TypedInstance) >= 8);
        std.debug.assert(@offsetOf(TypedInstance, "header") == 0);
    }

    pub fn fields(self: *const TypedInstance) []const Value {
        return self.field_values_ptr[0..self.field_count];
    }
};

/// Value handle to a process-lifetime `TypeDescriptor`. Sits on the
/// F-004 Group C slot 12 (`.type_descriptor`, already reserved in
/// `heap_tag.zig`). Cycle 6.5 introduces this thin wrapper rather
/// than migrating `TypeDescriptor` itself to an extern struct — the
/// finished form keeps `TypeDescriptor`'s rich field types (incl.
/// `protocol_impls: []const []const u8` slice-of-slices) and
/// reserves Value-handle semantics for `TypeDescriptorRef`, mirroring
/// the Java `Class` (static type info) vs `Class<T>` (handle) split.
///
/// Allocated on `rt.gc.infra` per descriptor (one ref per `TypeDescriptor`).
/// The held pointer is stable for the runtime's lifetime; no GC trace
/// recursion needed since `TypeDescriptor` itself lives on `rt.gc.infra`
/// (the pre-existing `td.meta` Value field is currently always `nil`
/// in practice — landing real meta tracing arrives with D-075 metadata
/// layer, same row as Symbol/Keyword meta).
pub const TypeDescriptorRef = extern struct {
    header: HeapHeader,
    _pad: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    td_ptr: *const TypeDescriptor,

    comptime {
        std.debug.assert(@alignOf(TypeDescriptorRef) >= 8);
        std.debug.assert(@offsetOf(TypeDescriptorRef, "header") == 0);
    }
};

/// Allocate a `TypeDescriptorRef` on `rt.gc.infra` that points at
/// the given descriptor. Returns a `.type_descriptor`-tagged Value.
/// The ref itself is process-lifetime (rt.gc.infra-allocated); rt
/// tracks it via `trackHeap` so `rt.deinit` frees it without
/// emitting a DebugAllocator leak diagnostic — row 7.7 cycle 1
/// surfaced this latent gap when `(rt/__native-type :integer)` got
/// exercised on every bootstrap-defprotocol-using path.
pub fn makeTypeDescriptorRef(rt: *Runtime, td: *const TypeDescriptor) !Value {
    // INVARIANT (ADR-0059): one canonical boxed Value per descriptor, so
    // two `.type_descriptor` Values are bit-equal iff same descriptor and
    // identity equality/hash holds with no equal.zig arm. Do NOT add a
    // path that mints a fresh ref for an already-wrapped descriptor.
    if (td.ref_cache) |cached| return cached;
    const ref = try rt.gc.infra.create(TypeDescriptorRef);
    ref.* = .{
        .header = HeapHeader.init(.type_descriptor),
        .td_ptr = td,
    };
    try rt.trackHeap(.{ .ptr = ref, .free = freeTypeDescriptorRef });
    const val = Value.encodeHeapPtr(.type_descriptor, ref);
    // Logical-const memoization (mirrors extendType's @constCast); the
    // descriptor is per-Runtime + process-lifetime so this is safe.
    @constCast(td).ref_cache = val;
    return val;
}

fn freeTypeDescriptorRef(gpa: std.mem.Allocator, ptr: *anyopaque) void {
    const ref: *TypeDescriptorRef = @ptrCast(@alignCast(ptr));
    gpa.destroy(ref);
}

/// Decode a `.type_descriptor`-tagged Value back to its
/// `*const TypeDescriptor`. Asserts the tag.
pub fn asTypeDescriptorRef(val: Value) *const TypeDescriptor {
    std.debug.assert(val.tag() == .type_descriptor);
    return val.decodePtr(*const TypeDescriptorRef).td_ptr;
}

/// A `reify` runtime value. Two-cache-word extern struct carrying
/// only a back-pointer to the anonymous TypeDescriptor (which lives
/// on `rt.gpa`, process lifetime, never traced). Closed-over locals
/// live where they are produced — on each method's `Function`
/// `closure_bindings` slot, snapshotted at the reify-form's call
/// site by `allocFunction` (eval/backend/tree_walk.zig). Per
/// ADR-0039, the row 7.5 reservation table's `closure_count` +
/// `_pad` + `closure_bindings_ptr` fields were deleted as a memo
/// against a need that does not materialise.
pub const ReifiedInstance = extern struct {
    header: HeapHeader,
    descriptor: *const TypeDescriptor,

    comptime {
        std.debug.assert(@alignOf(ReifiedInstance) >= 8);
        std.debug.assert(@offsetOf(ReifiedInstance, "header") == 0);
        std.debug.assert(@sizeOf(ReifiedInstance) == 16);
    }
};

/// Allocate a ReifiedInstance on the GC heap with the given anonymous
/// descriptor. Returns a Value tagged `.reified_instance`. Row 7.5
/// cycle 2 (ADR-0039) — minimal layout, no field-tail allocation.
pub fn allocReifiedInstance(rt: *Runtime, descriptor: *const TypeDescriptor) !Value {
    const inst = try rt.gc.alloc(ReifiedInstance);
    inst.* = .{
        .header = HeapHeader.init(.reified_instance),
        .descriptor = descriptor,
    };
    return Value.encodeHeapPtr(.reified_instance, inst);
}

/// Trace fn for `.reified_instance`. No-op — the struct carries no
/// Value fields; the descriptor lives on `rt.gpa` and is not GC-reachable.
pub fn traceReifiedInstance(gc_ptr: *anyopaque, header: *HeapHeader) void {
    _ = gc_ptr;
    _ = header;
}

/// Finaliser for `.reified_instance`. No-op — no `gc.infra`-owned
/// tail array to release (mirrors the empty-tail case of
/// `TypedInstance` after the field-values slice is freed elsewhere).
pub fn finaliseReifiedInstance(gc_ptr: *anyopaque, header: *HeapHeader) void {
    _ = gc_ptr;
    _ = header;
}

/// Allocate a TypeDescriptor on `rt.gpa` with the declared field
/// layout and register it in `rt.types` under `name`. Re-registering
/// the same name frees the previous descriptor (keeps the REPL
/// re-`def` path clean). `field_names` is borrowed; each entry is
/// `dupe`'d into the descriptor.
///
/// Shared by the `__deftype!` and `__defrecord!` Layer-2 primitives —
/// both lower to the same Layer-0 surface per F-009 (feature-impl
/// neutrality), differing only in the `kind` argument. Since ADR-0066
/// both `deftype` and `defrecord` are macros emitting their respective
/// `rt/__…!` registration call (no analyzer Node fork, no backend op).
pub fn registerType(
    rt: *Runtime,
    name: []const u8,
    field_names: []const []const u8,
    kind: TypeKind,
) !*const TypeDescriptor {
    const layout = try rt.gpa.alloc(TypeDescriptor.FieldEntry, field_names.len);
    errdefer rt.gpa.free(layout);
    for (field_names, 0..) |fname, i| {
        const dup = try rt.gpa.dupe(u8, fname);
        layout[i] = .{ .name = dup, .index = @intCast(i) };
    }

    const td = try rt.gpa.create(TypeDescriptor);
    errdefer rt.gpa.destroy(td);
    const fqcn = try rt.gpa.dupe(u8, name);
    td.* = .{
        .fqcn = fqcn,
        .kind = kind,
        .field_layout = layout,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = Value.nil_val,
    };

    if (rt.types.fetchRemove(name)) |old| {
        rt.gpa.free(old.key);
        if (old.value.field_layout) |old_layout| {
            for (old_layout) |fe| rt.gpa.free(fe.name);
            rt.gpa.free(old_layout);
        }
        if (old.value.fqcn) |o_n| rt.gpa.free(o_n);
        // Row 7.7 cycle 5: free the old TD's `method_table` slice and
        // each entry's `method_name` dup (populated by `extend-type`
        // between the prior `registerType` and now). Mirrors the
        // equivalent cleanup in `Runtime.deinit`'s rt.types iteration.
        for (old.value.method_table) |mentry| {
            rt.gpa.free(mentry.method_name);
        }
        if (old.value.method_table.len > 0) rt.gpa.free(old.value.method_table);
        // `protocol_impls` (D-190 / ADR-0068): borrowed fqcn slices, free
        // the slice only (mirrors the Runtime.deinit cleanup).
        if (old.value.protocol_impls.len > 0) rt.gpa.free(old.value.protocol_impls);
        rt.gpa.destroy(@constCast(old.value));
    }
    const key = try rt.gpa.dupe(u8, name);
    errdefer rt.gpa.free(key);
    try rt.types.put(key, td);
    return td;
}

/// Allocate a TypedInstance on the GC heap with `field_values` copied
/// into a freshly-allocated `gc.infra` array. Returns a Value tagged
/// `.typed_instance`.
pub fn allocInstance(rt: *Runtime, descriptor: *const TypeDescriptor, field_values: []const Value) !Value {
    const buf = try rt.gc.infra.alloc(Value, field_values.len);
    errdefer rt.gc.infra.free(buf);
    std.mem.copyForwards(Value, buf, field_values);

    const inst = try rt.gc.alloc(TypedInstance);
    inst.* = .{
        .header = HeapHeader.init(.typed_instance),
        .field_count = @intCast(field_values.len),
        .descriptor = descriptor,
        .field_values_ptr = buf.ptr,
    };
    return Value.encodeHeapPtr(.typed_instance, inst);
}

/// Trace fn for `.typed_instance`. Walks every field Value and marks
/// any heap reference it contains.
pub fn traceTypedInstance(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const inst: *TypedInstance = @ptrCast(@alignCast(header));
    var i: u32 = 0;
    while (i < inst.field_count) : (i += 1) {
        if (inst.field_values_ptr[i].heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    }
}

/// Finaliser for `.typed_instance` — releases the `gc.infra`-owned
/// field array.
pub fn finaliseTypedInstance(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const inst: *TypedInstance = @ptrCast(@alignCast(header));
    gc.infra.free(inst.field_values_ptr[0..inst.field_count]);
}

pub fn registerGcHooks() void {
    tag_ops.registerTrace(.typed_instance, &traceTypedInstance);
    tag_ops.registerFinaliser(.typed_instance, &finaliseTypedInstance);
    tag_ops.registerTrace(.reified_instance, &traceReifiedInstance);
    tag_ops.registerFinaliser(.reified_instance, &finaliseReifiedInstance);
}

// --- tests ---

const testing = std.testing;

const TdFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,

    fn init() TdFixture {
        var fix: TdFixture = .{
            .threaded = std.Io.Threaded.init(testing.allocator, .{}),
            .rt = undefined,
        };
        fix.rt = Runtime.init(fix.threaded.io(), testing.allocator);
        return fix;
    }
    fn deinit(self: *TdFixture) void {
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "TypeDescriptor struct layout: fqcn is optional, kind is required" {
    const td: TypeDescriptor = .{
        .fqcn = "user.MyType",
        .kind = .deftype,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = .nil_val,
    };
    try testing.expect(td.fqcn != null);
    try testing.expectEqualStrings("user.MyType", td.fqcn.?);
    try testing.expectEqual(TypeKind.deftype, td.kind);
}

test "TypeDescriptor: reify_anon variant carries no fqcn" {
    const td: TypeDescriptor = .{
        .fqcn = null,
        .kind = .reify_anon,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = .nil_val,
    };
    try testing.expect(td.fqcn == null);
    try testing.expectEqual(TypeKind.reify_anon, td.kind);
}

test "lookupMethod finds matching protocol + method, returns null when missing" {
    const entries = [_]TypeDescriptor.MethodEntry{
        .{ .protocol_name = "ISeq", .method_name = "first", .method_val = Value.nil_val },
        .{ .protocol_name = "ISeq", .method_name = "rest", .method_val = Value.nil_val },
    };
    const td: TypeDescriptor = .{
        .fqcn = "user.Foo",
        .kind = .deftype,
        .field_layout = null,
        .protocol_impls = &.{"ISeq"},
        .method_table = &entries,
        .parent = null,
        .meta = .nil_val,
    };
    const m = td.lookupMethod("ISeq", "first");
    try testing.expect(m != null);
    try testing.expectEqualStrings("first", m.?.method_name);
    try testing.expect(td.lookupMethod("ISeq", "nope") == null);
}

test "lookupMethod walks parent chain for defrecord inheritance" {
    const parent_entries = [_]TypeDescriptor.MethodEntry{
        .{ .protocol_name = "IBase", .method_name = "base_method", .method_val = Value.nil_val },
    };
    const parent_td: TypeDescriptor = .{
        .fqcn = "user.BaseRecord",
        .kind = .defrecord,
        .field_layout = null,
        .protocol_impls = &.{"IBase"},
        .method_table = &parent_entries,
        .parent = null,
        .meta = .nil_val,
    };
    const child_td: TypeDescriptor = .{
        .fqcn = "user.ChildRecord",
        .kind = .defrecord,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = &parent_td,
        .meta = .nil_val,
    };
    const m = child_td.lookupMethod("IBase", "base_method");
    try testing.expect(m != null);
    try testing.expectEqualStrings("base_method", m.?.method_name);
}

test "allocReifiedInstance allocates ReifiedInstance with descriptor + tag .reified_instance (row 7.5 cycle 2)" {
    var fix = TdFixture.init();
    defer fix.deinit();

    const td = try testing.allocator.create(TypeDescriptor);
    defer testing.allocator.destroy(td);
    td.* = .{
        .fqcn = null,
        .kind = .reify_anon,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = .nil_val,
    };

    const v = try allocReifiedInstance(&fix.rt, td);
    try testing.expect(v.tag() == .reified_instance);
    const inst = v.decodePtr(*const ReifiedInstance);
    try testing.expect(inst.descriptor == td);
    // ADR-0039: 16-byte two-cache-word struct.
    try testing.expectEqual(@as(usize, 16), @sizeOf(ReifiedInstance));
}

test "allocInstance allocates TypedInstance with field copy + tag .typed_instance" {
    var fix = TdFixture.init();
    defer fix.deinit();

    const td = try testing.allocator.create(TypeDescriptor);
    defer testing.allocator.destroy(td);
    td.* = .{
        .fqcn = "user.Point",
        .kind = .deftype,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = .nil_val,
    };

    const fields = [_]Value{ Value.initInteger(3), Value.initInteger(4) };
    const v = try allocInstance(&fix.rt, td, &fields);
    try testing.expect(v.tag() == .typed_instance);
    const inst = v.decodePtr(*const TypedInstance);
    try testing.expectEqual(@as(u32, 2), inst.field_count);
    try testing.expectEqual(@as(i48, 3), inst.fields()[0].asInteger());
    try testing.expectEqual(@as(i48, 4), inst.fields()[1].asInteger());
    try testing.expect(inst.descriptor == td);
}

test "TypeDescriptorRef round-trips a TypeDescriptor pointer through .type_descriptor Value" {
    var fix = TdFixture.init();
    defer fix.deinit();

    const td = try fix.rt.gc.infra.create(TypeDescriptor);
    defer fix.rt.gc.infra.destroy(td);
    td.* = .{
        .fqcn = "user.Bar",
        .kind = .deftype,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = Value.nil_val,
    };

    const v = try makeTypeDescriptorRef(&fix.rt, td);
    // makeTypeDescriptorRef registers the ref via rt.trackHeap (row 7.7
    // cycle 1) — rt.deinit owns the destroy; no manual defer here.
    try testing.expect(v.tag() == .type_descriptor);
    try testing.expect(asTypeDescriptorRef(v) == td);
}

test "Runtime.deinit releases TypedInstance + its field array (no leak)" {
    var fix = TdFixture.init();

    const td = try testing.allocator.create(TypeDescriptor);
    defer testing.allocator.destroy(td);
    td.* = .{
        .fqcn = "user.Leakcheck",
        .kind = .deftype,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = .nil_val,
    };

    const fields = [_]Value{ Value.initInteger(1), Value.initInteger(2), Value.initInteger(3) };
    _ = try allocInstance(&fix.rt, td, &fields);
    fix.deinit();
}
