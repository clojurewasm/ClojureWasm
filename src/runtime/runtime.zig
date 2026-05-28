//! Runtime — the process-wide handle every layer threads through.
//!
//! Three-tier architecture (see ROADMAP §4.3):
//!
//!   - **Runtime** (this file): one per process. `io`, `gpa`,
//!     interners, vtable. Lifetime = whole process.
//!   - **Env** (`env.zig`): one per CLI invocation / nREPL session;
//!     holds the namespace graph. Multiple Envs can share a Runtime
//!     (this fixes v1's nREPL session-sharing race condition).
//!   - **threadlocal** (`error.zig`, `dispatch.zig`, `env.zig`): only
//!     the per-thread state Clojure's dynamic-var semantics require.
//!
//! ### How `io` is threaded
//!
//! Runtime stores `std.Io` **by value** (it's a userdata + vtable
//! pair, ~16 bytes). The backing implementation (`std.Io.Threaded`,
//! `Io.Evented`, ...) is **not owned** by Runtime. Production code
//! threads `init.io` from `std.process.Init`; tests construct it via
//! `std.Io.Threaded.init(alloc, .{})`. We don't store the backing
//! type because `Threaded` is move-unsafe — `io()` returns a
//! `*Threaded`, and embedding `Threaded` in another struct would
//! leave the userdata pointer dangling after a copy.

const std = @import("std");
const KeywordInterner = @import("keyword.zig").KeywordInterner;
const SymbolInterner = @import("symbol.zig").SymbolInterner;
const dispatch = @import("dispatch.zig");
const gc_heap_mod = @import("gc/gc_heap.zig");
const td_mod = @import("type_descriptor.zig");
const print_mod = @import("error/print.zig");
const VTable = dispatch.VTable;
const GcHeap = gc_heap_mod.GcHeap;
const TypeDescriptor = td_mod.TypeDescriptor;
const SourceContext = print_mod.SourceContext;

/// Resolver signature for `require`. Given a namespace name like
/// `"clojure.set"`, return the namespace's source text or `null` if
/// the resolver cannot find it (= `lib_not_found` raise). Bootstrap
/// installs `embeddedResolver` which serves `@embedFile`'d
/// `clojure.core` / `clojure.set` / `clojure.string` / `clojure.walk`.
/// Phase 12+ swaps the slot for classpath / build-artifact resolvers;
/// Phase 16+ swaps for Wasm pod resolvers. ADR-0035 D8.
pub const RequireResolverFn = *const fn (rt: *Runtime, ns_name: []const u8) anyerror!?[]const u8;

/// Process-wide execution context.
///
/// **Phase 2.1** carries `io` / `gpa` / `keywords` / `vtable` /
/// `heap_objects`. Phase 5+ adds `gc: ?*MarkSweepGc`; Phase 7 entry
/// T2 (ADR-0037) added `symbols: SymbolInterner` parallel to
/// `keywords`. Adding a field is OK; renaming or removing one is an
/// ADR-level change.
pub const Runtime = struct {
    /// IO hub. Every lock / unlock / file / net / sleep flows through
    /// this — Zig 0.16's mandatory IO DI.
    io: std.Io,

    /// Process-lifetime general allocator backing Var / Namespace /
    /// interner tables. Phase 5+ adds a separate GC allocator.
    gpa: std.mem.Allocator,

    /// Keyword interner. Tied to this Runtime, not a global, so
    /// independent Runtimes (parallel tests / future multi-tenant
    /// nREPL) coexist without sharing a table.
    keywords: KeywordInterner,

    /// Symbol interner. Parallel to `keywords` per ADR-0037 (F-004
    /// Group A slot 1 impl). Same lifetime + ownership discipline:
    /// interner-owned + gpa-allocated + pinned for Runtime lifetime.
    symbols: SymbolInterner,

    /// Layer-0 → Layer-1+ dispatch table. Populated by the TreeWalk
    /// backend in Phase 2.6. While `null`, callers that would invoke
    /// `callFn` simply don't exist yet — those sites are gated behind
    /// primitives that get registered alongside the vtable. Macro
    /// expansion is **not** on this table; see ADR 0001.
    vtable: ?VTable = null,

    /// Monotonic counter for `gensym` / auto-gensym (`foo#`). Lives on
    /// the Runtime so multiple macros within one analyse pass share a
    /// single sequence; per-Runtime so parallel tests don't collide.
    /// Phase 3.7 wires the first user (bootstrap macro `and` / `or`).
    gensym_counter: u64 = 0,

    /// Phase-2 heap-object pool. Until the Phase-5 mark-sweep GC, each
    /// Layer-1+ heap allocation registers a `(ptr, free_fn)` pair here
    /// so `Runtime.deinit` can release them. The list keeps Layer 0
    /// from needing to know concrete Layer-1 types like `tree_walk
    /// .Function`. 5.3.d migrates Phase 1-4 alloc sites to `gc.alloc`
    /// and shrinks this list to "Layer-1 closure_bindings + bytecode"
    /// scope (Function struct stays GC-managed but its side-tables
    /// remain gpa-owned until ADR-0028 §5 row 3 wires the trace).
    heap_objects: std.ArrayList(HeapEntry) = .empty,

    /// Phase 5 mark-sweep GC heap (ADR-0028 + F-006). Inline field —
    /// every Runtime carries one; the empty `GcHeap` is ~40 bytes of
    /// null pointers until first allocation. 5.3.d migrates Phase 1-4
    /// alloc sites from `gpa.create` to `gc.alloc`. The
    /// `mark_sweep.collect(gc, ctx)` entry point reaches this field
    /// via `&rt.gc`.
    gc: GcHeap,

    /// User type registry per ADR-0007 + ROADMAP §9.7 / 5.11. Maps
    /// the fully-qualified class name (e.g. `user.Point`) to a
    /// process-lifetime TypeDescriptor allocated on `gpa`. Populated
    /// by the deftype / defrecord analyzer (Phase 5.12). Read by the
    /// constructor (`Foo. args`) and method-dispatch (`(.m inst)`)
    /// eval paths.
    types: std.StringHashMap(*const TypeDescriptor) = undefined,

    /// Set of namespace names currently being loaded by `require`.
    /// ADR-0035 D5: `requireOne` adds the target before loading and
    /// removes it after (errdefer-safe). If the target is already in
    /// the set when `requireOne` is called, raise `circular_require`.
    /// Keys are gpa-owned slices duplicated on insertion.
    require_in_progress: std.StringHashMapUnmanaged(void) = .empty,

    /// Per-file source registry for the renderer. ADR-0035 D7 +
    /// D-058 closure. Bootstrap loader + `requireOne` populate
    /// entries keyed by file label (`<bootstrap>`, `<clojure.set>`,
    /// ...). `runtime/error/print.zig::render` looks up
    /// `info.location.file` here for the per-file source-line preview.
    /// Keys + SourceContext field slices are gpa-owned.
    source_registry: std.StringHashMapUnmanaged(SourceContext) = .empty,

    /// Swappable resolver fn for `require`. ADR-0035 D8. `null` at
    /// `init`; bootstrap installs the embedded resolver. Phase 12+
    /// can swap for classpath / build-artifact resolvers; Phase 16+
    /// for Wasm pod resolvers.
    require_resolver: ?RequireResolverFn = null,

    /// Monotonic counter bumped by `extend-type` / `extend-protocol`
    /// (cycle 5+ primitives) so live `CallSite` caches can detect
    /// stale `(TypeDescriptor, MethodEntry)` pointers. Per ADR-0008
    /// amendment 1 Alt 1, the field was deferred from row 7.1 to
    /// row 7.3 — extend-type is the consumer that gives the counter
    /// a meaningful invalidation contract. CallSite's
    /// `cached_generation` is checked against this on hit; the
    /// guard is wired by row 7.3 cycle 2+.
    protocol_generation: u32 = 0,

    /// Per-Tag default `TypeDescriptor` registry — survey §5.5 +
    /// ADR-0008 amendment 1 ("per-Tag default descriptor table is a
    /// Phase 7+ extension"). Indexed by `Value.Tag` integer. Lazy-
    /// initialised via `nativeDescriptor(tag)`; entries are allocated
    /// on `rt.gc.infra` (process-lifetime). `dispatch.zig::dispatch`
    /// consults this when the receiver is NOT a `.typed_instance` so
    /// `(extend-type Long P ...)` works on native types without
    /// requiring deftype-style typed_instance receivers.
    ///
    /// Slot count = `Value.Tag` max + 1 (= 70 today: heap tags 0..63
    /// + immediates 64..69). The static-size array keeps the lookup
    /// at a single indexed load; no hashing.
    native_descriptors: [70]?*TypeDescriptor = .{null} ** 70,

    /// Lazy-init access to the per-Tag default descriptor. On first
    /// call for a given tag, allocates a TypeDescriptor on
    /// `rt.gc.infra` with `fqcn = nativeFqcnFor(tag)` and empty
    /// method_table / protocol_impls. Subsequent calls return the
    /// cached pointer. cycle 8.5 (row 7.3) introduces this; the
    /// extend-type primitive mutates `method_table` once registered
    /// here.
    pub fn nativeDescriptor(self: *Runtime, tag: @import("value/value.zig").Value.Tag) !*TypeDescriptor {
        const idx: usize = @intFromEnum(tag);
        if (self.native_descriptors[idx]) |existing| return existing;
        const fqcn_str = nativeFqcnFor(tag);
        const fqcn_dup = try self.gc.infra.dupe(u8, fqcn_str);
        errdefer self.gc.infra.free(fqcn_dup);
        const td = try self.gc.infra.create(TypeDescriptor);
        td.* = .{
            .fqcn = fqcn_dup,
            .kind = .native,
            .field_layout = null,
            .protocol_impls = &.{},
            .method_table = &.{},
            .parent = null,
            .meta = @import("value/value.zig").Value.nil_val,
        };
        self.native_descriptors[idx] = td;
        return td;
    }

    /// Canonical user-facing class name for a native Tag. Mirrors JVM
    /// Clojure surface conventions: `.integer → "Long"`, `.float →
    /// "Double"`, `.string → "String"`, etc. Tags without a
    /// JVM-canonical name fall back to `@tagName(tag)`.
    fn nativeFqcnFor(tag: @import("value/value.zig").Value.Tag) []const u8 {
        return switch (tag) {
            .integer => "Long",
            .float => "Double",
            .boolean => "Boolean",
            .char => "Character",
            .nil => "nil",
            .string => "String",
            .symbol => "Symbol",
            .keyword => "Keyword",
            .list => "PersistentList",
            .vector => "PersistentVector",
            .array_map => "PersistentArrayMap",
            .hash_map => "PersistentHashMap",
            .hash_set => "PersistentHashSet",
            else => @tagName(tag),
        };
    }

    pub const HeapEntry = struct {
        ptr: *anyopaque,
        free: *const fn (gpa: std.mem.Allocator, ptr: *anyopaque) void,
    };

    /// Track a heap-allocated object so `Runtime.deinit` will free it.
    pub fn trackHeap(self: *Runtime, entry: HeapEntry) !void {
        try self.heap_objects.append(self.gpa, entry);
    }

    /// Allocate a fresh symbol name `<prefix>__<n>__auto__` in `arena`.
    /// Mirrors Clojure's `gensym` shape (the trailing `__auto__` is
    /// what syntax-quote's `foo#` uses; we keep it uniform). The
    /// counter is per-Runtime so parallel tests stay independent.
    pub fn gensym(self: *Runtime, arena: std.mem.Allocator, prefix: []const u8) ![]const u8 {
        const n = self.gensym_counter;
        self.gensym_counter += 1;
        return std.fmt.allocPrint(arena, "{s}__{d}__auto__", .{ prefix, n });
    }

    /// Production initializer. `io` typically comes from
    /// `std.process.Init.io`; in tests use `std.Io.Threaded`.
    ///
    /// Registers per-tag GC hooks for migrated heap types
    /// (`runtime/collection/*.zig`) before any allocation can land.
    /// `tag_ops.registerFinaliser` is idempotent at the same fn
    /// pointer so multi-Runtime test processes re-register the same
    /// Layer 0 finalisers without conflict. Migration to `gc.alloc`
    /// is per-type (5.3.d.4 = String; 5.3.d.5 = Cons; ...): each
    /// migration commit adds its `registerGcHooks` call here +
    /// switches its `alloc` body from `gpa.create` to `gc.alloc`.
    pub fn init(io: std.Io, gpa: std.mem.Allocator) Runtime {
        @import("collection/string.zig").registerGcHooks();
        @import("collection/list.zig").registerGcHooks();
        @import("collection/ex_info.zig").registerGcHooks();
        @import("collection/vector.zig").registerGcHooks();
        @import("collection/map.zig").registerGcHooks();
        @import("collection/set.zig").registerGcHooks();
        @import("lazy_seq.zig").registerGcHooks();
        @import("collection/chunked_cons.zig").registerGcHooks();
        @import("collection/reduced.zig").registerGcHooks();
        @import("stm/ref.zig").registerGcHooks();
        @import("collection/transient/transient_vector.zig").registerGcHooks();
        @import("collection/transient/transient_array_map.zig").registerGcHooks();
        @import("collection/transient/transient_hash_set.zig").registerGcHooks();
        @import("numeric/big_int.zig").registerGcHooks();
        @import("numeric/ratio.zig").registerGcHooks();
        @import("numeric/big_decimal.zig").registerGcHooks();
        @import("regex/value.zig").registerGcHooks();
        @import("type_descriptor.zig").registerGcHooks();
        return .{
            .io = io,
            .gpa = gpa,
            .keywords = KeywordInterner.init(gpa),
            .symbols = SymbolInterner.init(gpa),
            .gc = GcHeap.init(gpa),
            .types = std.StringHashMap(*const TypeDescriptor).init(gpa),
        };
    }

    pub fn deinit(self: *Runtime) void {
        // Free per-Tag native descriptors first (their method_table
        // slice was re-allocated on rt.gc.infra by extendTypeWithImpls
        // calls, plus each method-name dup, plus the fqcn dup). All
        // process-lifetime by policy; freeing here keeps testing
        // allocator quiet.
        for (&self.native_descriptors) |*slot| {
            if (slot.*) |td| {
                if (td.fqcn) |n| self.gc.infra.free(n);
                for (td.method_table) |entry| {
                    self.gc.infra.free(entry.method_name);
                }
                if (td.method_table.len > 0) self.gc.infra.free(td.method_table);
                self.gc.infra.destroy(td);
                slot.* = null;
            }
        }

        for (self.heap_objects.items) |entry| {
            entry.free(self.gpa, entry.ptr);
        }
        self.heap_objects.deinit(self.gpa);
        // Free each registered TypeDescriptor + its field_layout
        // (the analyzer dup'd the names onto gpa per allocator
        // strategy F-006).
        var it = self.types.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            const td = entry.value_ptr.*;
            if (td.field_layout) |layout| {
                for (layout) |fe| self.gpa.free(fe.name);
                self.gpa.free(layout);
            }
            if (td.fqcn) |n| self.gpa.free(n);
            // Row 7.7 cycle 5: user `(extend-type X P (m …))` populates
            // `method_table` via `__extend-type!` on `rt.gc.infra`
            // (same backing as gpa per F-006 / GcHeap), so free both
            // the per-entry method_name dup and the slice itself.
            // `protocol_name` is a borrowed slice from the
            // ProtocolDescriptor (process-lifetime via rt.trackHeap),
            // and `protocol_impls` stays empty for user-defined types
            // (no populator yet).
            for (td.method_table) |mentry| {
                self.gpa.free(mentry.method_name);
            }
            if (td.method_table.len > 0) self.gpa.free(td.method_table);
            self.gpa.destroy(@constCast(td));
        }
        self.types.deinit();

        // ADR-0035 D5: free any in-progress require entries.
        // Normally empty at process exit; non-empty here means a
        // require raised mid-load — clean up so leak detectors stay
        // quiet.
        var rp_it = self.require_in_progress.iterator();
        while (rp_it.next()) |entry| self.gpa.free(entry.key_ptr.*);
        self.require_in_progress.deinit(self.gpa);

        // ADR-0035 D7: free per-file source registry entries.
        var sr_it = self.source_registry.iterator();
        while (sr_it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.file);
            self.gpa.free(entry.value_ptr.text);
        }
        self.source_registry.deinit(self.gpa);

        self.gc.deinit();
        self.symbols.deinit();
        self.keywords.deinit();
    }

    /// Insert `(label, text)` into `source_registry`, duplicating
    /// strings onto `gpa`. Idempotent against existing entries —
    /// re-registration is silently ignored so bootstrap and
    /// `requireOne` can both populate without contention.
    /// ADR-0035 D7.
    pub fn registerSource(
        self: *Runtime,
        label: []const u8,
        text: []const u8,
    ) !void {
        if (self.source_registry.contains(label)) return;
        const owned_label = try self.gpa.dupe(u8, label);
        errdefer self.gpa.free(owned_label);
        const owned_file = try self.gpa.dupe(u8, label);
        errdefer self.gpa.free(owned_file);
        const owned_text = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(owned_text);
        try self.source_registry.put(self.gpa, owned_label, .{
            .file = owned_file,
            .text = owned_text,
        });
    }

    /// Look up a registered source. Returns `null` when `label` is
    /// not registered (= renderer should fall back to its default
    /// SourceContext).
    pub fn lookupSource(self: *Runtime, label: []const u8) ?SourceContext {
        return self.source_registry.get(label);
    }
};

// --- tests ---

const testing = std.testing;

test "Runtime.init/deinit roundtrips with std.Io.Threaded" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();

    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    try testing.expect(rt.gpa.ptr == testing.allocator.ptr);
    // io.userdata points at our Threaded — sanity check on wiring.
    try testing.expect(rt.io.userdata == @as(*anyopaque, @ptrCast(&th)));
}

test "Runtime owns an empty KeywordInterner at init" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();

    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    try testing.expectEqual(@as(usize, 0), rt.keywords.table.count());
}

test "Runtime.trackHeap frees registered objects on deinit" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();

    var rt = Runtime.init(th.io(), testing.allocator);

    const Box = struct {
        var freed: bool = false;
        fn free(gpa: std.mem.Allocator, ptr: *anyopaque) void {
            const p: *u32 = @ptrCast(@alignCast(ptr));
            gpa.destroy(p);
            freed = true;
        }
    };

    const p = try testing.allocator.create(u32);
    p.* = 42;
    try rt.trackHeap(.{ .ptr = p, .free = Box.free });

    Box.freed = false;
    rt.deinit();
    try testing.expect(Box.freed);
}

test "Runtime.vtable defaults to null and accepts assignment" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();

    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    try testing.expect(rt.vtable == null);
}

test "Runtime ADR-0035 fields default to empty / null" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();

    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    try testing.expectEqual(@as(u32, 0), rt.require_in_progress.count());
    try testing.expectEqual(@as(u32, 0), rt.source_registry.count());
    try testing.expect(rt.require_resolver == null);
}

test "Runtime.registerSource roundtrips a label/text pair" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();

    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    try rt.registerSource("<clojure.set>", "(in-ns 'clojure.set)\n");
    const ctx = rt.lookupSource("<clojure.set>") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("<clojure.set>", ctx.file);
    try testing.expectEqualStrings("(in-ns 'clojure.set)\n", ctx.text);
}

test "Runtime.registerSource is idempotent against duplicate labels" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();

    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    try rt.registerSource("<dup>", "first");
    try rt.registerSource("<dup>", "second");
    const ctx = rt.lookupSource("<dup>") orelse return error.TestUnexpectedResult;
    // First-writer-wins (silent skip on re-registration).
    try testing.expectEqualStrings("first", ctx.text);
}

test "Runtime.lookupSource returns null for unknown labels" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();

    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    try testing.expect(rt.lookupSource("<missing>") == null);
}
