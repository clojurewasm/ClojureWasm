// SPDX-License-Identifier: EPL-2.0
//! cw v1 class system — TypeDescriptor / TypedInstance / ReifiedInstance
//! per ADR-0007 Option β.
//!
//!   - `lookupMethod` (linear search) resolves a method on a
//!     descriptor or up its `.parent` chain.
//!   - `allocInstance` allocates a TypedInstance on `rt.gc.alloc`
//!     (extern struct shape) and wraps it as a typed_instance Value.
//!   - TypedInstance is an extern struct holding a back-pointer to
//!     the TypeDescriptor and a flat tail of field Values that the
//!     GC traces.
//!   - The trace fn marks each field Value's heap header.
//!
//! TypeDescriptor itself is NOT GC-managed — it is allocated on
//! `rt.gpa` (process-lifetime) by the deftype / defrecord analyzer.
//! This keeps the descriptor pointer stable for the CallSite cache
//! (`runtime/dispatch/method_table.zig`) without needing GC pinning.

const std = @import("std");
const atomics = @import("atomics.zig");
const value_mod = @import("value/value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const Runtime = @import("runtime.zig").Runtime;
const tag_ops = @import("gc/tag_ops.zig");
const gc_heap_mod = @import("gc/gc_heap.zig");
const mark_sweep = @import("gc/mark_sweep.zig");
const hash_mod = @import("hash.zig");

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

/// Bare-toString print form for a host temporal value (D-462). A descriptor
/// with a non-`.none` value drives `printTypedInstance` to emit the value's
/// ISO toString (NO `#tag`, no quotes — clj's `(str …)` form), branched by
/// kind. `.none` = the default `#Name[..]` / `print_tag` path.
pub const TemporalPrint = enum {
    none,
    /// `java.time.Instant` — variable-fraction ISO_INSTANT + `Z` (2 fields:
    /// second-aligned epoch-ms + nanos).
    iso_instant,
    /// `java.time.Duration` — ISO-8601 duration `PT…` (2 fields: seconds + nanos).
    iso_duration,
    /// `java.time.LocalDateTime` — bare ISO local date-time (2 fields:
    /// epoch_day + nano_of_day), conditional seconds + variable fraction.
    iso_local_date_time,
    /// `java.time.LocalDate` — bare ISO local date `yyyy-MM-dd` (1 field:
    /// epoch_day).
    iso_local_date,
    /// `java.time.LocalTime` — bare ISO local time `HH:mm[:ss[.fraction]]`
    /// (1 field: nano_of_day), conditional seconds + variable fraction.
    iso_local_time,
};

/// Descriptor for one type. Process-lifetime — allocated on
/// `rt.gpa` by the deftype / defrecord analyzer.
pub const TypeDescriptor = struct {
    fqcn: ?[]const u8,
    /// The defining namespace of a deftype/defrecord (clj's user types are
    /// ns-qualified: `user.Pt`) — drives the qualified record print
    /// (`#user.Pt{…}`), the record-literal reader, and the record hasheq.
    /// Null for host surfaces / reify. gpa-owned (duped at registerType).
    defining_ns: ?[]const u8 = null,
    /// Precomputed clj record type-hash: the hasheq of the qualified-name
    /// symbol (`'user.Pt`), XORed with the map hash in the record hasheq
    /// (kept here so the rt-free hash path needs no allocation). 0 when
    /// `defining_ns` is null.
    record_type_hash: u32 = 0,
    kind: TypeKind,
    /// Field name → slot index, in declaration order. `null` for
    /// `reify_anon` (which has no positional field layout).
    field_layout: ?[]const FieldEntry,
    /// Protocols this descriptor implements (by fully-qualified
    /// name); the CallSite cache memoises dispatch over them.
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
    /// Host SUPERTYPE class names (fully-qualified) this descriptor is an
    /// `instance?` of, beyond its own fqcn — e.g. `java.util.HashMap` lists
    /// `java.util.Map` so `(instance? java.util.Map hm)` is true (D-466).
    /// Consulted ONLY by `class_name.zig::matchUserType` (the instance? membership
    /// walk); distinct from `protocol_impls`, which ALSO drives the isa? /
    /// extend-protocol distribution. **Comptime-const** like `static_fields` (set
    /// directly in the descriptor literal as `&array`) — so, unlike
    /// `protocol_impls`, `deinit` must NOT free it (a comptime array is not
    /// gc.infra-owned; freeing it crashed cache_gen — D-466's reverted first attempt).
    host_supertypes: []const []const u8 = &.{},
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
    /// Temporal print form for a host time value (D-462): when not `.none`, the
    /// printer emits the value's bare toString (NO `#tag` wrapper, NO quotes —
    /// clj's `(str …)` form) instead of the default `#Name[..]`. Distinct from
    /// `print_tag` (which wraps `#inst "…"`). Set on the per-Runtime Instant /
    /// Duration value descriptors only; checked BEFORE `print_tag` in
    /// `printTypedInstance`. `.none` for every other type.
    temporal_print: TemporalPrint = .none,
    /// Host-enum identity (ADR-0161 / D-510): when non-null, this descriptor backs
    /// a `.host_instance` enum constant (RoundingMode/ChronoUnit/DayOfWeek/Month);
    /// the value is `@intFromEnum(host_enum.Idx)`. Drives the unified host-enum
    /// print (`pr` emits the bare `toString`, not `#<fqcn>`) + `compare` (by
    /// ordinal). `null` for every non-enum host type. Distinct from `temporal_print`
    /// (which drives the bare-ISO print of LocalDate/Instant/… date-time values).
    host_enum_idx: ?u8 = null,
    /// `.host_instance` finaliser hook (ADR-0106): when this descriptor backs a
    /// host instance that owns heap state (a gpa-duped string pointer in
    /// `state[0..1]`, e.g. java.net.URI), the shared `.host_instance` tag
    /// finaliser routes here to free it. `null` for descriptors whose `state` is
    /// pure inline words (java.util.Random's LCG seed) — nothing to free. The
    /// `[4]u64` matches `host_instance.STATE_WORDS` (kept literal to avoid a
    /// circular import; a comptime assert in host_instance.zig pins them equal).
    host_finalise: ?*const fn (infra: std.mem.Allocator, state: *[4]u64) void = null,
    /// `.host_instance` GC-trace hook (ADR-0106): when this descriptor backs a
    /// host instance that stores a live `Value` in `state` (java.util.Iterator's
    /// cursor seq), the shared `.host_instance` tag tracer routes here to mark
    /// it. `null` for leaf host types (Random / URI / StringBuilder store only
    /// non-Value words). `gc` is the type-erased `*GcHeap` the tracer forwards.
    host_trace: ?*const fn (gc: *anyopaque, state: *[4]u64) void = null,
    /// `.host_instance` print hook (D-468): a host collection (java.util.ArrayList
    /// / HashSet / TreeSet / HashMap / TreeMap) returns the native cljw collection
    /// Value to print INSTEAD of the opaque `#<fqcn>` form, so it renders by content
    /// like clj (`[1 2]` / `#{1 2}` / `{:a 1}`). The print pre-pass (print.zig
    /// `deepRealize`) calls this and recurses on the result. `null` for leaf host
    /// types with no printable content (Random / URI). Sets/maps return `state[0]`
    /// (already a native collection); ArrayList rebuilds a vector from its backing.
    print_content: ?*const fn (rt: *Runtime, recv: Value) anyerror!Value = null,

    pub const FieldEntry = struct {
        name: []const u8,
        index: u16,
        /// `^:volatile-mutable` (D-444 / ADR-0152): the field's read/write go
        /// through atomic acquire/release for cross-thread happens-before.
        /// `false` = a plain slot (an immutable field OR `^:unsynchronized-mutable`,
        /// which is JVM-faithfully a plain field — sharing it across threads is a
        /// data race on the JVM too).
        is_volatile: bool = false,
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

    /// A heap singleton a static field resolves to at analyze time. The
    /// pointer cannot be baked at module-comptime (it lives on a specific
    /// Runtime), so the field carries the enum tag and the resolver maps it
    /// to the live singleton (ADR-0087). The `time_*` tags (ADR-0174 D7b)
    /// are cheap immutable `=`-by-value time constants: each read mints a
    /// fresh value at analyze time (no per-Runtime cache needed — the
    /// analyzer's makeConstant roots the constant).
    pub const Singleton = enum {
        empty_queue,
        locale_us,
        locale_root,
        compiler_specials,
        system_in,
        system_out,
        system_err,
        time_instant_epoch,
        time_duration_zero,
        time_local_time_midnight, // 00:00 — also LocalTime/MIN
        time_local_time_noon,
        time_local_time_max,
        time_local_date_min,
        time_local_date_max,
        time_local_date_epoch,
        time_local_date_time_min,
        time_local_date_time_max,
        time_zone_offset_utc,
        time_zone_offset_min, // -18:00
        time_zone_offset_max, // +18:00
    };

    /// The shapes a static field can carry. `int` lifts via
    /// `integerLiteralToValue` (i48 → Long, beyond → BigInt); `float` via
    /// `Value.initFloat`; `singleton` resolves to a per-Runtime heap value
    /// (e.g. `clojure.lang.PersistentQueue/EMPTY`).
    pub const StaticFieldValue = union(enum) {
        int: i64,
        float: f64,
        bool: bool, // Boolean/TRUE, Boolean/FALSE (ADR-0061 amendment)
        char: u21, // Character/MIN_VALUE, MAX_VALUE, the surrogate bounds
        /// A comptime-const string constant (File/separator, …) — lifted to a
        /// cljw String Value at analyze time (ADR-0174 D7).
        string: []const u8,
        singleton: Singleton,
        /// A host-enum constant (ADR-0161 / D-510): `enum_idx` is `@intFromEnum`
        /// of `host_enum.Idx` (RoundingMode/ChronoUnit/DayOfWeek/Month), `ordinal`
        /// the 0-based JVM ordinal. Resolves to the interned `.host_instance`
        /// singleton via `host_enum.zig::singleton`. One arm for all four host
        /// enums (folds the former `.rounding_mode`/`.chrono_unit` one-offs).
        host_enum: struct { enum_idx: u8, ordinal: u8 },
        /// A `java.math.MathContext` standard constant (0-3 = DECIMAL32/64/128/
        /// UNLIMITED) → `math_context.zig::singleton` (D-511).
        math_context: u8,
        /// A `java.time.format.DateTimeFormatter` ISO constant: the index into
        /// `time/date_time_format.zig::ISO_CONSTANTS` → a fresh formatter.
        date_time_formatter: u8,
        /// A small-integer `java.math.BigDecimal` constant (ZERO/ONE/TWO/TEN) —
        /// lifted via the BigDecimal constructor at analyze time (ADR-0174 D7),
        /// scale 0.
        big_decimal: i64,
    };

    /// True iff this descriptor is a class the USER defined (`deftype`,
    /// `defrecord`, `reify`), as opposed to a native / host-surface class.
    /// A user class is identified by the descriptor itself, never by its
    /// display name (ADR-0201): two vintages of a redefined `R`, or `aaa.Point`
    /// and `bbb.Point`, share a simple name and are still different classes.
    pub fn isUserClass(self: *const TypeDescriptor) bool {
        return self.kind != .native;
    }

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
    /// typically ≤ 8 methods per protocol). The CallSite cache
    /// memoises hot paths so the linear scan is amortised.
    ///
    /// `protocol_name = null` is the `.method` syntactic-form shape
    /// — match by `method_name` only, returning the first matching
    /// entry across the descriptor's method_table + parent chain.
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
    /// method entry (D-190 / ADR-0068). An exact-name check: interface
    /// membership with clj's superinterface closure (`Indexed` is Counted) is
    /// `class_name.implementsInterface`.
    pub fn declaresProtocol(self: *const TypeDescriptor, protocol_name: []const u8) bool {
        for (self.protocol_impls) |p| {
            if (std.mem.eql(u8, p, protocol_name)) return true;
        }
        if (self.parent) |par| return par.declaresProtocol(protocol_name);
        return false;
    }

    /// The defrecord/deftype declared/extmap partition chokepoint (ADR-0154):
    /// the field-slot index for a declared field `name`, or null when `name`
    /// is not a declared field (= an extmap key on a record). Single source so
    /// `assoc`/`dissoc`/`get`/`contains?` cannot disagree on which keys are
    /// declared (the DA's hazard 2). nil layout → null (no declared fields).
    pub fn fieldSlotByName(self: *const TypeDescriptor, name: []const u8) ?u16 {
        const layout = self.field_layout orelse return null;
        for (layout) |fe| {
            if (std.mem.eql(u8, fe.name, name)) return fe.index;
        }
        return null;
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
    /// Instance metadata (D-312, the IObj record/deftype case). `nil` for a
    /// freshly-constructed instance; `with-meta` mints a fresh instance with
    /// this set (clj records store meta in a hidden `__meta` field). Ignored by
    /// equality/hash (those walk descriptor + fields), so `(= r (with-meta r m))`
    /// → true falls out by construction. GC-traced like the field Values.
    meta: Value = Value.nil_val,
    /// Non-declared keys assoc'd onto a defrecord (D-086 / ADR-0154 — clj's
    /// hidden `__extmap`). `nil` when the record carries no extras (the common
    /// case); otherwise a NON-EMPTY persistent map (the empty state normalizes
    /// back to nil on dissoc so `(= (assoc r :z 9 (dissoc :z)) r)`). Unlike
    /// `meta`, extmap IS part of record value identity — equality/hash include
    /// it (the map's content `=`/order-independent hash). GC-traced.
    extmap: Value = Value.nil_val,

    comptime {
        std.debug.assert(@alignOf(TypedInstance) >= 8);
        std.debug.assert(@offsetOf(TypedInstance, "header") == 0);
    }

    pub fn fields(self: *const TypedInstance) []const Value {
        return self.field_values_ptr[0..self.field_count];
    }

    /// In-place write of a single field slot (ADR-0104, deftype mutable
    /// fields). GC-safe under the non-moving mark-sweep collector: the slot is
    /// already traced, so no write barrier is needed. `*const` is sufficient —
    /// the pointee Values are mutable through the `[*]Value` field pointer.
    pub fn setField(self: *const TypedInstance, index: u32, v: Value) void {
        self.field_values_ptr[index] = v;
    }

    /// Atomic-release write of a `^:volatile-mutable` field slot (D-444 /
    /// ADR-0152). `Value` is an `enum(u64)`; a naturally-aligned 8-byte slot is
    /// already hardware-atomic on aarch64/x86_64, so the builtin is for the
    /// ORDERING fence (+ to stop the compiler reordering/coalescing) — the
    /// publish half of cross-thread happens-before. Pairs with `getFieldVolatile`.
    pub fn setFieldVolatile(self: *const TypedInstance, index: u32, v: Value) void {
        atomics.store(Value, &self.field_values_ptr[index], v, .release);
    }

    /// Atomic-acquire read of a `^:volatile-mutable` field slot (D-444 /
    /// ADR-0152) — the consume half; sees every write ordered-before the
    /// matching `setFieldVolatile`'s release.
    pub fn getFieldVolatile(self: *const TypedInstance, index: u32) Value {
        return atomics.load(Value, &self.field_values_ptr[index], .acquire);
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
/// recursion needed since `TypeDescriptor` itself lives on `rt.gpa`
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

/// Append host-surface method entries to `td.method_table`, growing the
/// gpa-owned slice (an empty table from a descriptor literal is `&.{}` —
/// not gpa-owned — and is replaced without a free). `specs` is a comptime
/// tuple of `.{ name, fn_ptr }` pairs; names are gpa-duped per the
/// `rt.types` deinit ownership contract. Idempotence is the CALLER's job
/// (guard on a sentinel entry via `lookupMethod` before calling). The
/// same-name assert is the ADR-0174 static/instance collision guard:
/// `method_table` is flat, so a static and an instance member of one name
/// on one descriptor would silently misdispatch — fail loudly instead
/// (escalation path: an `is_static` MethodEntry bit, not yet needed).
pub fn appendMethodEntries(td: *TypeDescriptor, gpa: std.mem.Allocator, comptime specs: anytype) !void {
    const old = td.method_table;
    const entries = try gpa.alloc(TypeDescriptor.MethodEntry, old.len + specs.len);
    @memcpy(entries[0..old.len], old);
    inline for (specs, 0..) |spec, i| {
        std.debug.assert(td.lookupMethod(null, spec[0]) == null);
        entries[old.len + i] = .{
            .protocol_name = "",
            .method_name = try gpa.dupe(u8, spec[0]),
            .method_val = Value.initBuiltinFn(spec[1]),
        };
    }
    if (old.len > 0) gpa.free(old);
    td.method_table = entries;
}

/// One canonical `rt.types` descriptor per host class (ADR-0174): return
/// the registered descriptor for `fqcn`, or mint + register it with
/// `configure` (print flags + instance methods). Ownership mirrors
/// `registerExtension` exactly (rt.gpa key/fqcn/method_name dups) so
/// `Runtime.deinit`'s rt.types pass frees it. Registration order is
/// two-way safe: in production the surface `registerExtension` runs first
/// and its `init` appends onto the copied literal; in a bare-Runtime unit
/// test this mints the descriptor and a later surface `init` (guarded by
/// its own sentinel) appends its statics/`<init>` onto the SAME
/// descriptor. Either order yields the one descriptor instances carry,
/// class symbols resolve to, and the AOT wire round-trips through.
pub fn ensureRegistered(
    rt: *Runtime,
    fqcn: []const u8,
    configure: *const fn (td: *TypeDescriptor, gpa: std.mem.Allocator) anyerror!void,
) !*const TypeDescriptor {
    if (rt.types.get(fqcn)) |td| return td;
    const gpa = rt.gpa;
    const td = try gpa.create(TypeDescriptor);
    errdefer gpa.destroy(td);
    const fqcn_dup = try gpa.dupe(u8, fqcn);
    errdefer gpa.free(fqcn_dup);
    td.* = .{
        .fqcn = fqcn_dup,
        .kind = .native,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = .nil_val,
    };
    try configure(td, gpa);
    const key = try gpa.dupe(u8, fqcn);
    errdefer gpa.free(key);
    try rt.types.put(key, td);
    return td;
}

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
    try rt.trackHeap(.{ .ptr = ref, .free = freeTypeDescriptorRef, .size = @sizeOf(TypeDescriptorRef) });
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
    /// Instance metadata (ADR-0134 IObj value-driven slice, reify pulled by
    /// clojure.spec.alpha — its `with-name` attaches `::name` to every spec
    /// object). clj's reify ALWAYS implements IObj (a plain deftype does not —
    /// that stays `.typed_instance` without this slot). `nil` for a fresh
    /// instance; `with-meta` mints a fresh instance with this set. Ignored by
    /// equality/hash (those walk descriptor + closure state).
    meta: Value = .nil_val,

    comptime {
        std.debug.assert(@alignOf(ReifiedInstance) >= 8);
        std.debug.assert(@offsetOf(ReifiedInstance, "header") == 0);
        std.debug.assert(@sizeOf(ReifiedInstance) == 24);
    }
};

/// Descriptor of a `.typed_instance` / `.reified_instance` Value — the two decode
/// to DIFFERENT structs (TypedInstance carries a field tail; ReifiedInstance is
/// header+descriptor only), both with a `.descriptor` at the same logical slot.
/// One SSOT so dispatch arms that treat deftype + reify uniformly (count, keys,
/// vals) don't each re-derive the tag switch. Asserts the tag is one of the two.
pub fn descriptorOfInstance(v: Value) *const TypeDescriptor {
    return switch (v.tag()) {
        .typed_instance => v.decodePtr(*const TypedInstance).descriptor,
        .reified_instance => v.decodePtr(*const ReifiedInstance).descriptor,
        else => unreachable,
    };
}

/// Allocate a ReifiedInstance on the GC heap with the given anonymous
/// descriptor. Returns a Value tagged `.reified_instance`. Row 7.5
/// cycle 2 (ADR-0039) — minimal layout, no field-tail allocation.
pub fn allocReifiedInstance(rt: *Runtime, descriptor: *const TypeDescriptor) !Value {
    const inst = try rt.gc.alloc(ReifiedInstance);
    inst.* = .{
        .header = HeapHeader.init(.reified_instance),
        .descriptor = descriptor,
        .meta = .nil_val,
    };
    return Value.encodeHeapPtr(.reified_instance, inst);
}

/// `(meta <reify>)` — the instance metadata slot (`nil` when none). ADR-0134.
pub fn reifiedInstMetaOf(v: Value) Value {
    return v.decodePtr(*const ReifiedInstance).meta;
}

/// `(with-meta <reify> m)` — mint a FRESH reified instance sharing the
/// descriptor (and thus the closure-captured method bindings, which live on
/// the descriptor's method Functions, not on the instance) with metadata = m.
/// `(identical? r (with-meta r m))` is false (distinct pointer), matching clj.
pub fn reifiedInstWithMeta(rt: *Runtime, v: Value, meta: Value) !Value {
    const base = v.decodePtr(*const ReifiedInstance);
    const inst = try rt.gc.alloc(ReifiedInstance);
    inst.* = .{
        .header = HeapHeader.init(.reified_instance),
        .descriptor = base.descriptor,
        .meta = meta,
    };
    return Value.encodeHeapPtr(.reified_instance, inst);
}

/// Mark every GC Value a descriptor (+ its defrecord parent chain) holds:
/// `method_table[].method_val` (deftype/reify method Functions — often
/// reachable ONLY through the descriptor) and `meta`. The descriptor struct
/// itself lives on `rt.gpa` and is never swept; its VALUES are ordinary GC
/// objects. Before this walk existed, a deftype method fn whose sole
/// reference was the descriptor was swept once the heap crossed the collect
/// threshold — its chunk constants then dangled (instaparse AutoFlattenSeq's
/// `cached-seq` field-name string read as garbage; the gc_rooting §C C8
/// class). Since ADR-0184 B the registries themselves are walked as roots
/// each collect (`markRegistryRoots`), so this is no longer instance-gated
/// for registered descriptors.
fn markDescriptorValues(gc: *gc_heap_mod.GcHeap, td_start: *const TypeDescriptor) void {
    var td: ?*const TypeDescriptor = td_start;
    while (td) |d| : (td = d.parent) {
        for (d.method_table) |me| {
            if (me.method_val.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
        }
        if (d.meta.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    }
}

/// ADR-0184 Precondition B: walk EVERY registered descriptor's method-table
/// + meta Values as GC ROOTS. The registries (`rt.types`,
/// `rt.native_descriptors` — where `(extend-type Long/nil …)` impls land —
/// and `rt.class_descriptors`) are gpa-side tables the mark phase cannot
/// otherwise see; before this walk an impl fn was reachable only through a
/// live instance/ref Value (the C8 strand class — dispatch still found it
/// via the table after its captures were swept). Called from `collect()`
/// via the `runtime_embedded` @fieldParentPtr bridge. Reify's anonymous
/// descriptors are deliberately NOT here — they stay instance-mediated
/// (`traceReifiedInstance`), so a reify whose instances all died is
/// collectable as a unit.
pub fn markRegistryRoots(rt: *Runtime, gc: *gc_heap_mod.GcHeap) void {
    var it = rt.types.valueIterator();
    while (it.next()) |tdp| markDescriptorValues(gc, tdp.*);
    for (rt.native_descriptors) |maybe_td| {
        if (maybe_td) |td| markDescriptorValues(gc, td);
    }
    var cit = rt.class_descriptors.valueIterator();
    while (cit.next()) |tdp| markDescriptorValues(gc, tdp.*);
}

/// Trace fn for `.type_descriptor` (the boxed ref `makeTypeDescriptorRef`
/// mints; a `trackHeap` persistent mark-waypoint). Walks the descriptor's
/// GC Values — see `markDescriptorValues`.
pub fn traceTypeDescriptorRef(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const ref: *const TypeDescriptorRef = @ptrCast(@alignCast(header));
    markDescriptorValues(gc, ref.td_ptr);
}

/// Trace fn for `.reified_instance`. Marks the metadata slot (ADR-0134) AND
/// the per-instance descriptor's method closures — a reify's method fns
/// (closures over the reify site's locals) are reachable ONLY through its
/// descriptor, so skipping them was the same C8 sweep as the deftype case.
pub fn traceReifiedInstance(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const inst: *ReifiedInstance = @ptrCast(@alignCast(header));
    if (inst.meta.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    markDescriptorValues(gc, inst.descriptor);
}

/// Finaliser for `.reified_instance`. No-op — no `gc.infra`-owned
/// tail array to release (mirrors the empty-tail case of
/// `TypedInstance` after the field-values slice is freed elsewhere).
pub fn finaliseReifiedInstance(gc_ptr: *anyopaque, header: *HeapHeader) void {
    _ = gc_ptr;
    _ = header;
}

/// Build a defrecord instance from map `m` — clj's `Record/create`:
/// declared fields pulled by keyword (nil when absent), every remaining
/// key held in the extmap (nil when empty, so the result `=`/hashes as a
/// plain record). Shared by the `__map->record` primitive (the generated
/// `map->Name` factory) and the `#ns.Name{…}` record-literal reader.
pub fn recordFromMap(rt: *Runtime, td: *const TypeDescriptor, m: Value) !Value {
    const keyword_mod = @import("keyword.zig");
    const map_mod = @import("collection/map.zig");
    const layout = td.field_layout orelse &[_]TypeDescriptor.FieldEntry{};
    const fields = try rt.gpa.alloc(Value, layout.len);
    defer rt.gpa.free(fields);
    for (layout, 0..) |fe, i| {
        const kw = try keyword_mod.intern(rt, null, fe.name);
        fields[i] = if (!m.isNil() and try map_mod.contains(m, kw)) try map_mod.get(m, kw) else Value.nil_val;
    }
    var ext: Value = Value.nil_val;
    if (!m.isNil()) {
        ext = m;
        for (layout) |fe| {
            const kw = try keyword_mod.intern(rt, null, fe.name);
            ext = try map_mod.dissoc(rt, ext, kw);
        }
        if (map_mod.count(ext) == 0) ext = Value.nil_val;
    }
    return allocInstanceFull(rt, td, fields, Value.nil_val, ext);
}

/// Allocate a TypeDescriptor on `rt.gpa` with the declared field layout and
/// register it in `rt.types` under its qualified key `<defining_ns>.<name>`
/// (ADR-0198). Re-registering the same key RETIRES the previous descriptor to
/// `rt.retired_types` rather than freeing it: instances, boxed class values
/// and CallSite caches still hold it, and the retired descriptor stays a
/// distinct class from its replacement (ADR-0201). `field_names` is borrowed;
/// each entry is `dupe`'d into the descriptor.
///
/// Shared by the `__deftype!` and `__defrecord!` Layer-2 primitives, which
/// lower to the same Layer-0 surface per F-009 (feature-impl neutrality) and
/// differ only in the `kind` argument. Since ADR-0066 both `deftype` and
/// `defrecord` are macros emitting their `__deftype!` / `__defrecord!`
/// registration call (no analyzer Node fork, no backend op).
pub fn registerType(
    rt: *Runtime,
    name: []const u8,
    /// The defining namespace's name (null in ns-less unit-test contexts).
    defining_ns: ?[]const u8,
    field_names: []const []const u8,
    /// Per-field `^:volatile-mutable` flag (D-444 / ADR-0152), aligned with
    /// `field_names`. Empty slice = all plain (the defrecord path + any deftype
    /// with no volatile fields). Length, when non-empty, equals `field_names`.
    field_volatile: []const bool,
    kind: TypeKind,
) !*const TypeDescriptor {
    const layout = try rt.gpa.alloc(TypeDescriptor.FieldEntry, field_names.len);
    errdefer rt.gpa.free(layout);
    for (field_names, 0..) |fname, i| {
        const dup = try rt.gpa.dupe(u8, fname);
        layout[i] = .{
            .name = dup,
            .index = @intCast(i),
            .is_volatile = i < field_volatile.len and field_volatile[i],
        };
    }

    const td = try rt.gpa.create(TypeDescriptor);
    errdefer rt.gpa.destroy(td);
    const fqcn = try rt.gpa.dupe(u8, name);
    var ns_dup: ?[]const u8 = null;
    var type_hash: u32 = 0;
    if (defining_ns) |dns| {
        ns_dup = try rt.gpa.dupe(u8, dns);
        // clj's record type-hash = (hash 'ns.Name) — the qualified-name
        // symbol hasheq, precomputed once so hashing stays alloc-free.
        const qualified = try std.fmt.allocPrint(rt.gpa, "{s}.{s}", .{ dns, name });
        defer rt.gpa.free(qualified);
        type_hash = hash_mod.hashCombine(hash_mod.hashUnencodedChars(qualified), 0);
    }
    td.* = .{
        .fqcn = fqcn,
        .defining_ns = ns_dup,
        .record_type_hash = type_hash,
        .kind = kind,
        .field_layout = layout,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = Value.nil_val,
    };

    // D-587 part 2 / ADR-0198: the registry key is the FULLY-QUALIFIED class
    // name, which is what `Runtime.types`'s own doc comment has always
    // promised. A host surface's fqcn is already qualified
    // (`java.util.UUID`); a user type's key is `<defining_ns>.<Name>`. A null
    // `defining_ns` (bare unit-test registration, `ensureRegistered`; reify
    // is not registered at all) keeps the bare name as its own qualified
    // form, so the rule is TOTAL with no null branch.
    //
    // `td.fqcn` deliberately stays the SIMPLE name: key and printed class
    // name are decoupled, so `(class x)` and the `#ns.Name{…}` print form are
    // unchanged (ADR-0059 / AD-003).
    //
    // Keying by the simple name made `aaa/Point` and `bbb/Point` ONE entry,
    // so a record name a second namespace already used silently displaced the
    // first with nobody intending a redefinition.
    const key = if (defining_ns) |dns|
        try std.fmt.allocPrint(rt.gpa, "{s}.{s}", .{ dns, name })
    else
        try rt.gpa.dupe(u8, name);
    errdefer rt.gpa.free(key);

    if (rt.types.fetchRemove(key)) |old| {
        // The displaced descriptor is RETIRED, never freed (D-587). Live
        // instances hold `inst.descriptor` raw; `makeTypeDescriptorRef`
        // hands out process-lifetime boxed refs that the GC traces via
        // `markDescriptorValues`; and `CallSite.last_type` compares
        // descriptors by ADDRESS from analyzer storage the GC cannot see.
        // Freeing dangled all three, and the address reuse that follows a
        // free let a stale call site hit on an ABA-matched pointer and
        // dispatch through a freed `method_table` -- a silent wrong answer
        // rather than a crash. Retiring removes that hazard by construction,
        // because the address is never handed back.
        //
        // The prior code freed here to avoid leaking on redefine. That trade
        // was wrong twice over: the struct's own doc comment declares it
        // process-lifetime, and clj keeps a superseded class alive for as
        // long as anything references it, so retention is the oracle's
        // behaviour (F-011), bounded by re-evaluation count.
        rt.gpa.free(old.key);
        try rt.retired_types.append(rt.gpa, old.value);
    }
    try rt.types.put(key, td);

    // Secondary simple-name index (ADR-0198). Last registration wins, which
    // is what EVERY lookup did before the key was qualified. It exists for
    // references that carry no namespace to qualify with, chiefly the VM's
    // `op_ctor_call`, which resolves a bare `type_name` at RUNTIME where the
    // current ns is the CALLER's, not the definer's.
    if (defining_ns != null) {
        const gop = try rt.types_by_simple.getOrPut(rt.gpa, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = rt.gpa.dupe(u8, name) catch |e| {
                _ = rt.types_by_simple.remove(name);
                return e;
            };
        }
        gop.value_ptr.* = td;
    }

    // A redefine changes what `(protocol, method)` resolves to, and the
    // CallSite cache hits on `last_type == td and cached_generation ==
    // current_generation`. Retiring already guarantees the cached pointer
    // stays valid, so this bump is what makes a stale slot MISS and refill
    // against the new descriptor instead of serving the retired one.
    rt.protocol_generation +%= 1;
    return td;
}

/// Allocate a TypedInstance on the GC heap with `field_values` copied
/// into a freshly-allocated `gc.infra` array. Returns a Value tagged
/// `.typed_instance`.
pub fn allocInstance(rt: *Runtime, descriptor: *const TypeDescriptor, field_values: []const Value) !Value {
    return allocInstanceFull(rt, descriptor, field_values, Value.nil_val, Value.nil_val);
}

/// Read a typed-instance's metadata (`nil` when unset). Distinct from
/// `TypeDescriptor.meta` (the type-level meta) — this is per-instance (D-312).
pub fn instMetaOf(v: Value) Value {
    return v.decodePtr(*const TypedInstance).meta;
}

/// Read a record's extmap (`nil` when no extra keys). The non-declared-key
/// store (D-086 / ADR-0154); a non-nil value is a non-empty persistent map.
pub fn instExtmapOf(v: Value) Value {
    return v.decodePtr(*const TypedInstance).extmap;
}

/// `with-meta` on a record/deftype instance (D-312): mint a FRESH instance
/// sharing the descriptor, carrying `meta` — and the source's extmap (D-086,
/// extmap survives with-meta). The field array MUST be copied, not shared — it
/// is `gc.infra`-owned and freed by `finaliseTypedInstance`, so two instances
/// sharing one `field_values_ptr` would double-free on sweep (the key
/// divergence from the symbol `withMeta`, which safely shares interner-owned
/// slices). `(identical? r (with-meta r m))` is false (distinct pointer).
pub fn instWithMeta(rt: *Runtime, v: Value, meta: Value) !Value {
    const base = v.decodePtr(*const TypedInstance);
    return allocInstanceFull(rt, base.descriptor, base.field_values_ptr[0..base.field_count], meta, base.extmap);
}

/// `allocInstance` + an explicit `meta` (extmap nil). Kept for callers that
/// only thread meta (the historic D-313 record `assoc` site name); new
/// extmap-bearing re-mints call `allocInstanceFull` directly.
pub fn allocInstanceMeta(rt: *Runtime, descriptor: *const TypeDescriptor, field_values: []const Value, meta: Value) !Value {
    return allocInstanceFull(rt, descriptor, field_values, meta, Value.nil_val);
}

/// The single TypedInstance mint: copies `field_values` into a fresh
/// `gc.infra` array (owned by the new instance) and threads both `meta`
/// (D-312) and `extmap` (D-086 / ADR-0154). All other ctors are thin wrappers.
pub fn allocInstanceFull(rt: *Runtime, descriptor: *const TypeDescriptor, field_values: []const Value, meta: Value, extmap: Value) !Value {
    const buf = try rt.gc.infra.alloc(Value, field_values.len);
    errdefer rt.gc.infra.free(buf);
    std.mem.copyForwards(Value, buf, field_values);
    const inst = try rt.gc.alloc(TypedInstance);
    inst.* = .{
        .header = HeapHeader.init(.typed_instance),
        .field_count = @intCast(field_values.len),
        .descriptor = descriptor,
        .field_values_ptr = buf.ptr,
        .meta = meta,
        .extmap = extmap,
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
    // D-312: the instance metadata map is a GC child (no-op when nil).
    if (inst.meta.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    // C8: the descriptor's method Functions + meta are GC children too
    // (the descriptor struct itself is gpa-owned, never swept).
    markDescriptorValues(gc, inst.descriptor);
    // D-086: the extmap (non-declared keys) is a GC child (no-op when nil).
    if (inst.extmap.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
}

/// Finaliser for `.typed_instance` — releases the `gc.infra`-owned
/// field array.
pub fn finaliseTypedInstance(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const inst: *TypedInstance = @ptrCast(@alignCast(header));
    gc.infra.free(inst.field_values_ptr[0..inst.field_count]);
}

/// D-573: the field-values slice finaliseTypedInstance frees.
fn typedInstanceOwnedBytes(header: *HeapHeader) usize {
    const inst: *TypedInstance = @ptrCast(@alignCast(header));
    return inst.field_count * @sizeOf(Value);
}

pub fn registerGcHooks() void {
    tag_ops.registerTrace(.typed_instance, &traceTypedInstance);
    tag_ops.registerOwnedBytes(.typed_instance, &typedInstanceOwnedBytes);
    tag_ops.registerTrace(.type_descriptor, &traceTypeDescriptorRef);
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

test "ADR-0184 B: a registered descriptor's method impl survives a collect with no live instance (registry roots)" {
    var fix = TdFixture.init();
    defer fix.deinit();
    const rt = &fix.rt;

    // A descriptor in rt.types whose method impl Value has NO other
    // reference — before the registry root walk, the collect swept it
    // (the C8 strand class) even though `(SomeType/m …)` could still
    // dispatch to it.
    const td = try registerType(rt, "user.RootedT", null, &.{}, &.{}, .deftype);
    const impl = try @import("collection/string.zig").alloc(rt, "impl-body-stand-in");
    // `method_name` must be a gpa dup — Runtime.deinit frees it per entry
    // (matching the production `__extend-type!` ownership).
    const entries = [_]TypeDescriptor.MethodEntry{
        .{ .protocol_name = "user/IP", .method_name = try rt.gpa.dupe(u8, "m"), .method_val = impl },
    };
    try @import("protocol.zig").extendTypeWithImpls(rt, @constCast(td), &entries);

    const impl_hdr = impl.heapHeader().?;
    mark_sweep.collectStopTheWorld(&rt.gc, .{ .envs = &.{}, .gc = &rt.gc }, false);
    var found = false;
    for (rt.gc.allocations.items) |rec| {
        if (rec.header == impl_hdr) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

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
    // ADR-0039 header+descriptor + ADR-0134 meta slot = 24 bytes.
    try testing.expectEqual(@as(usize, 24), @sizeOf(ReifiedInstance));
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

test "D-444 volatile field accessors round-trip + agree with plain access single-threaded" {
    var fix = TdFixture.init();
    defer fix.deinit();

    const td = try testing.allocator.create(TypeDescriptor);
    defer testing.allocator.destroy(td);
    td.* = .{
        .fqcn = "user.Vol",
        .kind = .deftype,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = .nil_val,
    };

    const fields = [_]Value{ Value.initInteger(10), Value.initInteger(20) };
    const v = try allocInstance(&fix.rt, td, &fields);
    const inst = v.decodePtr(*const TypedInstance);

    // Atomic release-store / acquire-load round-trips (the by-construction half
    // of D-444 — the cross-thread guarantee itself is not deterministically
    // testable; ADR-0152). Single-threaded, the atomic path observes the same
    // value as the plain path.
    inst.setFieldVolatile(0, Value.initInteger(99));
    try testing.expectEqual(@as(i48, 99), inst.getFieldVolatile(0).asInteger());
    try testing.expectEqual(@as(i48, 99), inst.fields()[0].asInteger()); // plain read sees the atomic write
    inst.setField(1, Value.initInteger(77));
    try testing.expectEqual(@as(i48, 77), inst.getFieldVolatile(1).asInteger()); // atomic read sees the plain write
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
