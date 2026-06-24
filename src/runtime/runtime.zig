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
const io_default = @import("concurrency/io_default.zig");
const eval_budget_mod = @import("concurrency/eval_budget.zig");
const KeywordInterner = @import("keyword.zig").KeywordInterner;
const SymbolInterner = @import("symbol.zig").SymbolInterner;
const dispatch = @import("dispatch.zig");
const gc_heap_mod = @import("gc/gc_heap.zig");
const td_mod = @import("type_descriptor.zig");
const class_name_mod = @import("class_name.zig");
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
/// A namespace's source bytes plus the SourceContext label to register them
/// under (ADR-0084). For an embedded ns the label is the `<ns-name>` sentinel;
/// for a filesystem ns it is the resolved path (so errors render `file:line`).
pub const ResolvedSource = struct {
    source: []const u8,
    label: []const u8,
    /// True when this source was read off the filesystem classpath (a user
    /// lib), false for a bootstrap-embedded ns. `cljw build`'s require-closure
    /// embedding captures ONLY filesystem nses — bootstrap nses are restored by
    /// `setupCoreAot` at run time (ADR-0034 amendment 3 A3-D3).
    from_filesystem: bool = false,
};

/// Build-time hook for `cljw build`'s require-closure embedding (ADR-0034
/// amendment 3 A3-D2). When set, `loader.loadNamespace` compiles each
/// filesystem-resolved lib form and pushes the chunk here, so the closure's
/// defining chunks can be embedded ahead of the entry's `(require …)` chunk.
/// Type-erased: the `BytecodeChunk` type lives in Layer 1 (eval/), so this
/// Layer-0 field cannot name it; the builder (Layer 3) casts back via
/// `@ptrCast`. Null on the production load path (the per-form guard skips the
/// compile).
pub const BuildChunkSink = struct {
    ctx: *anyopaque,
    /// `chunk_ptr` is a `*const BytecodeChunk` (Layer 1); the builder casts.
    push: *const fn (ctx: *anyopaque, chunk_ptr: *const anyopaque) anyerror!void,
};

pub const RequireResolverFn = *const fn (rt: *Runtime, ns_name: []const u8) anyerror!?ResolvedSource;

/// One Wasm component embedded into a `cljw build` single binary (ADR-0158):
/// the resolved logical path (the key the `:require` desugar passes to
/// `wasm/load-component` at run) + the raw `.wasm` bytes. Defined here in
/// Layer 0 so the Layer-1 envelope serializer and the Layer-0 component
/// surface (`runtime/cljw/wasm/component.zig`) share ONE type — a downward
/// import from each, zone-clean.
pub const EmbeddedComponent = struct {
    path: []const u8,
    bytes: []const u8,
};

/// Process-wide execution context.
///
/// Carries `io` / `gpa` / `keywords` / `vtable` / `heap_objects`,
/// the inline mark-sweep `gc: GcHeap` (ADR-0028 + F-006), and
/// `symbols: SymbolInterner` (ADR-0037) parallel to `keywords`.
/// Adding a field is OK; renaming or removing one is an ADR-level
/// change.
pub const Runtime = struct {
    /// IO hub. Every lock / unlock / file / net / sleep flows through
    /// this — Zig 0.16's mandatory IO DI.
    io: std.Io,

    /// Process-lifetime general allocator backing Var / Namespace /
    /// interner tables. Phase 5+ adds a separate GC allocator.
    gpa: std.mem.Allocator,

    /// Process-shared stdout writer. Set by the app entry points
    /// (runSource / repl / nrepl) to the SINGLE writer that owns the
    /// process's stdout buffer, so println / print / prn write through
    /// the same offset-tracking writer as the runner's result-print.
    /// Two independent `std.Io.File.stdout().writer(...)` instances each
    /// flush from offset 0 and clobber each other (D-096); routing all
    /// stdout through one writer fixes it. `null` only for test-init
    /// Runtimes with no real terminal — those fall back to a private
    /// writer (correct in isolation, where nothing competes). Superseded
    /// by the `*out*` dynamic var when that lands (D-232).
    stdout: ?*std.Io.Writer = null,

    /// Deploy-mode filesystem jail root (ADR-0123 / SE-6/7). When non-null, the
    /// FS surfaces (slurp / spit / wasm/load) confine every path to this subtree
    /// via `file_io.enforceJail`. `null` (default) = unconfined (local CLI). Set
    /// by `runSource` from `CLJW_FS_ROOT`; the env string lives in the process
    /// arena, so this borrowed slice is valid for the Runtime's lifetime.
    fs_jail_root: ?[]const u8 = null,

    /// In-process eval execution budget (ADR-0125, isolation dim (a)). When
    /// non-null, the back-edge safe points of both backends charge a step (and,
    /// throttled, check the wall-clock deadline) and raise an UNCATCHABLE
    /// `resource_exhausted` error on expiry. `null` (default) = unmetered. Set
    /// by `runSource` from `CLJW_EVAL_MAX_STEPS` / `CLJW_EVAL_DEADLINE_MS`.
    eval_budget: ?eval_budget_mod.EvalBudget = null,

    /// Keyword interner. Tied to this Runtime, not a global, so
    /// independent Runtimes (parallel tests / future multi-tenant
    /// nREPL) coexist without sharing a table.
    keywords: KeywordInterner,

    /// Symbol interner. Parallel to `keywords` per ADR-0037 (F-004
    /// Group A slot 1 impl). Same lifetime + ownership discipline:
    /// interner-owned + gpa-allocated + pinned for Runtime lifetime.
    symbols: SymbolInterner,

    /// Layer-0 → Layer-1+ dispatch table. Populated by the backend
    /// at startup. While `null`, callers that would invoke `callFn`
    /// simply don't exist yet — those sites are gated behind
    /// primitives that get registered alongside the vtable. Macro
    /// expansion is **not** on this table; see ADR 0001.
    vtable: ?VTable = null,

    /// Borrowed pointer to the built-in macro-expansion table
    /// (`eval/macro_dispatch.Table`, a Layer-1 type). Type-erased to
    /// `?*const anyopaque` because Layer 0 must not import Layer 1
    /// (`zone_deps.md`) — the same concession `VTable.evalChunk` makes
    /// for a `BytecodeChunk` pointer. Set once in
    /// `bootstrap.setupCorePrefix` after `registerInto`; the runtime
    /// `eval` primitive reads it back behind the typed
    /// `driver.evalValue` verb (ADR-0058). The table is a process
    /// constant (always `macro_transforms.registerInto`'s output);
    /// user macros resolve via env Vars and need no table. NOTE: this
    /// is a BORROW of the entry point's stack-owned table — valid for
    /// the setup frame's lifetime (the whole session for
    /// repl/runner/builder). Do not heap-promote a Runtime past that
    /// frame without revisiting this borrow.
    macro_table: ?*const anyopaque = null,

    /// Cached `*Var` for `clojure.core/*data-readers*` (root `{}`) and
    /// `*default-data-reader-fn*` (root `nil`), interned `^:dynamic` at
    /// bootstrap (ADR-0073). Type-erased to `?*anyopaque` (mirroring
    /// `macro_table`) so this Layer-0 struct need not name `env.Var`; the
    /// `formToValue` `.tagged` arm casts back and `Var.deref()`s, so a
    /// `(binding [*data-readers* …] …)` frame is honoured for free. `null`
    /// until bootstrap runs (an unknown-tag literal then raises directly).
    data_readers_var: ?*anyopaque = null,
    default_data_reader_fn_var: ?*anyopaque = null,

    /// Cached `*Var` for `clojure.core/*agent*` (root `nil`), interned
    /// `^:dynamic` at bootstrap (ADR-0155 / D-442). Type-erased to `?*anyopaque`
    /// (mirroring the data-reader vars) so this Layer-0 struct need not name
    /// `env.Var`; the agent drainer (`runtime/agent.zig`) casts it back and binds
    /// it to the running agent for the duration of each action body, so
    /// `*agent*` derefs to the agent inside its own action (clj `binding [*agent*
    /// a]`). `null` until bootstrap runs (the drainer then binds nothing).
    agent_var: ?*anyopaque = null,

    /// Cached `*Var` for `clojure.core/*math-context*` (root nil), interned
    /// `^:dynamic` at bootstrap (D-467). `with-precision` binds it to an integer
    /// precision; BigDecimal division (`promote.divPromoting`) reads it and, when
    /// set, rounds the quotient to that many significant figures (HALF_UP) instead
    /// of raising on a non-terminating expansion. Type-erased (mirrors `agent_var`).
    math_context_var: ?*anyopaque = null,

    /// ADR-0130: cached canonical `clojure.core` arith/comparison Vars
    /// (+ - * < <= > >= =), indexed by `intrinsic.ArithOp` (type-erased like the
    /// data-reader vars; cast back to `*const env.Var` at the compiler gate + VM
    /// dispatch). Populated at bootstrap; a null slot (pre-bootstrap or an absent
    /// op) means the compiler never emits that intrinsic opcode.
    /// `core_arith_pristine` starts true and is cleared when ANY of these Vars is
    /// redefined via `alter-var-root`, deopting the intrinsic opcodes to the
    /// builtin so a redefed op is honoured (F-011). Size 12 = intrinsic.arith_count
    /// (add/sub/mul/lt/le/gt/ge/eq + mod/rem/quot + ne(not=); runtime/ is Layer 0 and
    /// cannot import the Layer-1 intrinsic module).
    arith_vars: [12]?*anyopaque = .{ null, null, null, null, null, null, null, null, null, null, null, null },
    core_arith_pristine: bool = true,

    /// Cached canonical `clojure.core/get` + `nth` Vars for the collection-accessor
    /// intrinsics (op_get / op_nth; ADR-0130 extended, O-043). Same lifecycle as
    /// `arith_vars`: populated at bootstrap, `core_coll_pristine` cleared on
    /// `alter-var-root` of either so a redefed `get`/`nth` is honoured. Index 0=get,
    /// 1=nth (= intrinsic.CollOp order; runtime/ cannot import the Layer-1 module).
    coll_vars: [2]?*anyopaque = .{ null, null },
    core_coll_pristine: bool = true,

    /// Monotonic counter for `gensym` / auto-gensym (`foo#`). Lives on
    /// the Runtime so multiple macros within one analyse pass share a
    /// single sequence; per-Runtime so parallel tests don't collide.
    /// Phase 3.7 wires the first user (bootstrap macro `and` / `or`).
    gensym_counter: u64 = 0,

    /// Separate monotonic counter for anonymous-fn names `fn__<n>`
    /// (ADR-0119). Kept distinct from `gensym_counter` so naming every
    /// `fn*` does NOT perturb syntax-quote / `foo#` gensym numbers (which
    /// some macro tests pin). Per-Runtime, like `gensym_counter`.
    fn_name_counter: u64 = 0,

    /// Non-GC heap-object pool. Each registered Layer-1+ allocation
    /// adds a `(ptr, free_fn)` pair here so `Runtime.deinit` can
    /// release it. The list keeps Layer 0 from needing to know
    /// concrete Layer-1 types like `tree_walk.Function`. Most alloc
    /// sites migrated to `gc.alloc`; the residual scope is Layer-1
    /// closure_bindings + bytecode side-tables that stay gpa-owned
    /// (the Function struct itself is GC-managed).
    heap_objects: std.ArrayList(HeapEntry) = .empty,
    /// Guards `heap_objects` appends — Phase-B worker threads allocate Functions
    /// (e.g. `dosync`/`future` thunk closures) concurrently, and the backing
    /// ArrayList grow is not thread-safe without this (D-244 real-threading).
    heap_objects_mutex: std.Io.Mutex = .init,

    /// Mark-sweep GC heap (ADR-0028 + F-006). Inline field — every
    /// Runtime carries one; the empty `GcHeap` is ~40 bytes of null
    /// pointers until first allocation. Heap alloc sites use
    /// `gc.alloc` rather than `gpa.create`. The
    /// `mark_sweep.collect(gc, ctx)` entry point reaches this field
    /// via `&rt.gc`.
    gc: GcHeap,

    /// Interned distinct empty list `()` — the cljw analogue of JVM's
    /// `PersistentList.EMPTY` (D-164 / clj-parity C1). A count-0 `.list`
    /// Value distinct from `nil`, so `(seq? '())`/`(list? '())`→true,
    /// `(= '() nil)`→false, `(pr-str '())`→"()", and `(rest …)` of any
    /// empty seq yields `()` not nil (JVM `RT.more`). Lazily allocated on
    /// `gc.infra` (process-lifetime, not GC-swept — same discipline as
    /// `native_descriptors`); `nil` until first `emptyList()` call. The
    /// single instance gives `(identical? '() '())` via the `valueEqual`
    /// pointer fast-path, mirroring JVM's single static EMPTY. Built in
    /// `collection/list.zig::emptyList` (keeps Cons construction in the
    /// list module).
    empty_list: @import("value/value.zig").Value = .nil_val,

    /// The `clojure.lang.PersistentQueue/EMPTY` singleton (ADR-0087), built
    /// on `gc.infra` by `collection/persistent_queue.zig::emptyQueue`; `nil`
    /// until first use. Same process-lifetime discipline as `empty_list`.
    empty_queue: @import("value/value.zig").Value = .nil_val,
    /// `java.util.Locale/US` and `/ROOT` process-lifetime host_instance
    /// singletons (gc.infra-allocated, never swept), lazily filled by
    /// `java/util/Locale.zig::singleton`; freed in `deinit`.
    locale_us: @import("value/value.zig").Value = .nil_val,
    locale_root: @import("value/value.zig").Value = .nil_val,
    /// The flat host-enum constant cache (ADR-0161 / D-510): one interned
    /// `.host_instance` singleton per (enum, ordinal) for RoundingMode (8) +
    /// ChronoUnit (16) + DayOfWeek (7) + Month (12), indexed by
    /// `host_enum.defs[idx].cache_base + ordinal` (size = `host_enum.TOTAL` = 43).
    /// gc.infra-allocated, lazily filled by `host_enum.zig::singleton` (the sole
    /// minting point → `=` / `identical?` parity is structural); freed in `deinit`.
    host_enum_consts: [@import("host_enum.zig").TOTAL]@import("value/value.zig").Value = @splat(.nil_val),
    /// The 4 `java.math.MathContext` standard constants (DECIMAL32/64/128/
    /// UNLIMITED), gc.infra-allocated host_instances lazily filled by
    /// `math_context.zig::singleton`; freed in `deinit`.
    math_contexts: [4]@import("value/value.zig").Value = @splat(.nil_val),

    /// User-set Java system properties (`(System/setProperty k v)`). Keys +
    /// values are `gpa`-owned dupes; consulted by `getProperty` BEFORE the
    /// OS-truthful static table (JVM: a set property overrides). Freed in
    /// `deinit`. Empty until the first `setProperty`.
    system_properties: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// `(Thread/currentThread)` / `(Runtime/getRuntime)` process-lifetime
    /// host_instance singletons (gc.infra-allocated, never swept — the locale
    /// pattern), lazily filled by the Thread / Runtime surfaces; identity holds
    /// across calls (`(identical? (Thread/currentThread) (Thread/currentThread))`
    /// → true, clj-faithful). Freed in `deinit`. Carry no user Values (no trace).
    thread_current: @import("value/value.zig").Value = .nil_val,
    runtime_instance: @import("value/value.zig").Value = .nil_val,

    /// User type registry per ADR-0007 + ROADMAP §9.7 / 5.11. Maps
    /// the fully-qualified class name (e.g. `user.Point`) to a
    /// process-lifetime TypeDescriptor allocated on `gpa`. Populated
    /// by the deftype / defrecord analyzer. Read by the constructor
    /// (`Foo. args`) and method-dispatch (`(.m inst)`) eval paths.
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

    /// Build-time require-closure capture sink (ADR-0034 amendment 3). Set by
    /// `cljw build`; null on every other path (production load, REPL, tests).
    build_chunk_sink: ?BuildChunkSink = null,

    /// Build-time collection sink for the resolved paths of `:require`d Wasm
    /// components (ADR-0158, D-404 Impl D). `analyzeNs` appends each component
    /// libspec's resolved path here (gpa-duped) so the builder can harvest +
    /// embed the `.wasm` bytes into the binary. Set by `cljw build`; null on
    /// every other path (REPL / production run never collect). Distinct from
    /// `embedded_components` (the run-side lookup table below).
    component_sink: ?*std.ArrayList([]const u8) = null,

    /// Run-side embedded Wasm component table (ADR-0158, D-404 Impl D). In a
    /// `cljw build` binary the `:require`d components' bytes are baked into the
    /// envelope; `tryRunEmbedded` installs them here so `readComponentBytes`
    /// serves them from memory before any filesystem read — the binary is
    /// self-contained. Empty (default) on every non-embedded path; a genuinely
    /// dynamic `(wasm/load runtime-path)` whose path is not in the table falls
    /// through to the FS jail load.
    embedded_components: []const EmbeddedComponent = &.{},

    /// Filesystem classpath roots searched by the filesystem require resolver
    /// (ADR-0084). Colon-separated `--classpath`/`CLJW_PATH`, default `["."]`,
    /// set by the CLI. Empty in the test/embedded path (embedded-only).
    load_paths: []const []const u8 = &.{},

    /// Set of namespace names that have FULLY loaded (ADR-0084). Distinct from
    /// `require_in_progress` (in-flight) and from `findNs` (an ns exists with
    /// partial mappings mid-load): a require skips only when the lib is in this
    /// completed set. Keys are gpa-owned, freed in `deinit`.
    loaded_libs: std.StringHashMapUnmanaged(void) = .empty,

    /// Session-lifetime arena for `require`-loaded namespace Forms/Nodes
    /// (ADR-0084). Loaded fns/macros capture their analyzer Nodes, so the
    /// storage must outlive the load (as the bootstrap arena does); freed at
    /// `deinit`.
    load_arena: std.heap.ArenaAllocator,

    /// Monotonic counter bumped by `extend-type` / `extend-protocol`
    /// so live `CallSite` caches can detect stale
    /// `(TypeDescriptor, MethodEntry)` pointers (ADR-0008 amendment
    /// 1 Alt 1). CallSite's `cached_generation` is checked against
    /// this on a cache hit; a mismatch forces re-resolution.
    protocol_generation: u32 = 0,

    /// Per-Tag default `TypeDescriptor` registry — survey §5.5 +
    /// ADR-0008 amendment 1 (per-Tag default descriptor table).
    /// Indexed by `Value.Tag` integer. Lazy-
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

    /// Synthetic `(class e)` descriptors for exception values, keyed by the
    /// per-value class name (D-213). An `.ex_info` Value carries its specific
    /// class (`ExInfo.class_name`: "ArithmeticException", "Exception", …;
    /// `null` → "ExceptionInfo") that catch-matching already consults, so a
    /// single shared `.ex_info` native descriptor would collapse every
    /// exception to one class. Each distinct class name gets one descriptor,
    /// lazily built on `gc.infra` by `classDescriptor`, freed in `deinit`.
    class_descriptors: std.StringHashMapUnmanaged(*TypeDescriptor) = .empty,

    /// Per-Runtime `java.util.Date` value descriptor (D-200 / ADR-0079;
    /// `#inst` / Date is a no-slot `.typed_instance`). Lazily allocated on
    /// `gc.infra` by `runtime/time/date.zig::descriptorOf`, freed in
    /// `deinit`. `null` until the first Date value is built.
    date_descriptor: ?*TypeDescriptor = null,

    /// The per-Runtime `java.sql.Timestamp` descriptor (D-382) — a
    /// nanosecond-precision instant, a 2-field no-slot `.typed_instance`.
    /// Lazily allocated by `runtime/time/timestamp.zig::descriptorOf`, freed
    /// in `deinit`. `null` until the first Timestamp value is built.
    timestamp_descriptor: ?*TypeDescriptor = null,

    /// Per-Runtime `java.time.Instant` value descriptor (D-462) — a
    /// nanosecond-precision instant, a 2-field no-slot `.typed_instance` with
    /// `iso_instant = true` (bare ISO_INSTANT print form). Lazily allocated on
    /// `gc.infra` by `runtime/time/instant_value.zig::descriptorOf`, freed in
    /// `deinit`. `null` until the first Instant value is built.
    instant_descriptor: ?*TypeDescriptor = null,

    /// Per-Runtime `java.time.Duration` value descriptor (D-462) — a signed
    /// time span, a 2-field no-slot `.typed_instance` with `temporal_print =
    /// .iso_duration` (bare `PT…` print form). Lazily allocated on `gc.infra`
    /// by `runtime/time/duration_value.zig::descriptorOf`, freed in `deinit`.
    /// `null` until the first Duration value is built.
    duration_descriptor: ?*TypeDescriptor = null,

    /// Per-Runtime `java.time.LocalDateTime` value descriptor (D-462) — a
    /// timezone-agnostic date+time, a 2-field no-slot `.typed_instance` with
    /// `temporal_print = .iso_local_date_time` (bare ISO-local print form).
    /// Lazily allocated on `gc.infra` by
    /// `runtime/time/local_date_time_value.zig::descriptorOf`, freed in
    /// `deinit`. `null` until the first LocalDateTime value is built.
    local_date_time_descriptor: ?*TypeDescriptor = null,

    /// Per-Runtime `java.time.LocalDate` value descriptor (D-462) — a
    /// timezone-agnostic calendar date, a 1-field no-slot `.typed_instance`
    /// with `temporal_print = .iso_local_date` (bare `yyyy-MM-dd` print form).
    /// Lazily allocated on `gc.infra` by
    /// `runtime/time/local_date_value.zig::descriptorOf`, freed in `deinit`.
    /// `null` until the first LocalDate value is built.
    local_date_descriptor: ?*TypeDescriptor = null,

    /// Per-Runtime `java.time.LocalTime` value descriptor (D-462) — a
    /// timezone-agnostic time-of-day, a 1-field no-slot `.typed_instance` with
    /// `temporal_print = .iso_local_time` (bare ISO local-time print form).
    /// Lazily allocated on `gc.infra` by
    /// `runtime/time/local_time_value.zig::descriptorOf`, freed in `deinit`.
    /// `null` until the first LocalTime value is built.
    local_time_descriptor: ?*TypeDescriptor = null,

    // DayOfWeek/Month are host-enum constants (ADR-0161) — interned in the shared
    // `host_enum_consts` cache via their surface descriptors, so they need no
    // per-Runtime value descriptor (the former D-462 typed_instance ones).

    /// Lazy-init access to the per-Tag default descriptor. On first
    /// call for a given tag, allocates a TypeDescriptor on
    /// `rt.gc.infra` with `fqcn = nativeFqcnFor(tag)` and empty
    /// method_table / protocol_impls. Subsequent calls return the
    /// cached pointer. The extend-type primitive mutates
    /// `method_table` once a descriptor is registered here.
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

    /// Canonical user-facing class name for a native Tag. Derives from the
    /// single name↔Tag SSOT in `class_name.fqcnForTag` (D-204), so `(class x)`
    /// (this fqcn) and `(instance? Name x)` (the same table) cannot drift.
    /// `.nil` is special-cased (not a heap class, absent from the table);
    /// anything else with no canonical name falls back to `@tagName`.
    fn nativeFqcnFor(tag: @import("value/value.zig").Value.Tag) []const u8 {
        if (tag == .nil) return "nil";
        if (class_name_mod.fqcnForTag(tag)) |name| return name;
        // Callables / seq views / refs / transients get a stable clj-faithful
        // simple name instead of the leaked internal heap-tag name (D-337 /
        // AD-044). @tagName remains only for genuinely-internal tags as a canary.
        if (class_name_mod.displayClassName(tag)) |name| return name;
        return @tagName(tag);
    }

    /// A name-keyed class-VALUE descriptor (ADR-0128 — was `exceptionDescriptor`,
    /// renamed since it is NOT exception-specific). Mints one `kind=.native`
    /// descriptor per distinct class name, cached in `class_descriptors` (D-213).
    /// Used for: exception classes (`(class e)` → "ArithmeticException", simple
    /// per AD-003), opaque collapsed classes (Integer / BigInteger), the
    /// universal Object / Number / IFn markers, the `clojure.lang.*` interface
    /// markers, host_inert + java.io stream class names — every class symbol the
    /// analyzer resolves to a value that is not a native exact tag or a
    /// registered host surface. The cache key aliases the descriptor's `fqcn`
    /// dup, so both share one lifetime freed in `deinit`.
    pub fn classDescriptor(self: *Runtime, class_name: []const u8) !*TypeDescriptor {
        if (self.class_descriptors.get(class_name)) |existing| return existing;
        const fqcn_dup = try self.gc.infra.dupe(u8, class_name);
        errdefer self.gc.infra.free(fqcn_dup);
        const td = try self.gc.infra.create(TypeDescriptor);
        errdefer self.gc.infra.destroy(td);
        td.* = .{
            .fqcn = fqcn_dup,
            .kind = .native,
            .field_layout = null,
            .protocol_impls = &.{},
            .method_table = &.{},
            .parent = null,
            .meta = @import("value/value.zig").Value.nil_val,
        };
        try self.class_descriptors.put(self.gc.infra, fqcn_dup, td);
        return td;
    }

    pub const HeapEntry = struct {
        ptr: *anyopaque,
        free: *const fn (gpa: std.mem.Allocator, ptr: *anyopaque) void,
    };

    /// Track a heap-allocated object so `Runtime.deinit` will free it.
    /// Thread-safe: concurrent worker threads append here (closure allocation).
    ///
    /// Precondition: `entry.ptr` points at an object whose `HeapHeader` is at
    /// offset 0 (every production caller — `Function` / `ProtocolDescriptor` /
    /// `ProtocolFn` / `TypeDescriptorRef` — is an extern struct that satisfies
    /// this). The header is registered as a GC mark-waypoint (D-251) so
    /// `collect()` re-clears its mark bit each cycle: these objects live outside
    /// `gc.allocations` (never swept), so a never-cleared bit would short-
    /// circuit `mark()` from the 2nd collect on and strand any GC child
    /// reachable only through the object (a `Function`'s `closure_bindings`).
    pub fn trackHeap(self: *Runtime, entry: HeapEntry) !void {
        io_default.lockMutex(&self.heap_objects_mutex);
        defer io_default.unlockMutex(&self.heap_objects_mutex);
        // Register the GC mark-waypoint first, then the free-list entry. If the
        // second append OOMs, roll the waypoint back so the two lists stay 1:1
        // and `persistent_marks` never holds a header the caller's errdefer is
        // about to free (the dual-list atomicity contract — no swallowed OOM).
        try self.gc.registerPersistentMark(entry.ptr);
        errdefer self.gc.unregisterLastPersistentMark();
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

    /// Mint an anonymous-fn name `fn__<n>` — clj's `fn__<id>` shape (no
    /// `__auto__` suffix; that belongs to syntax-quote's `foo#`, not a fn
    /// name). Uses the dedicated `fn_name_counter` (NOT `gensym_counter`) so
    /// naming fns does not shift syntax-quote gensym numbers. ADR-0119
    /// (anonymous fns carry a name on the value for traces / `pr` / metadata).
    pub fn gensymFn(self: *Runtime, arena: std.mem.Allocator) ![]const u8 {
        const n = self.fn_name_counter;
        self.fn_name_counter += 1;
        return std.fmt.allocPrint(arena, "fn__{d}", .{n});
    }

    /// Production initializer. `io` typically comes from
    /// `std.process.Init.io`; in tests use `std.Io.Threaded`.
    ///
    /// Registers per-tag GC hooks for every GC-managed heap type
    /// before any allocation can land. `tag_ops.registerFinaliser`
    /// is idempotent at the same fn pointer so multi-Runtime test
    /// processes re-register the same Layer 0 finalisers without
    /// conflict. Each GC-managed type's `alloc` body uses `gc.alloc`
    /// and contributes one `registerGcHooks` call below.
    pub fn init(io: std.Io, gpa: std.mem.Allocator) Runtime {
        @import("symbol.zig").registerGcHooks();
        @import("collection/string.zig").registerGcHooks();
        @import("collection/list.zig").registerGcHooks();
        @import("collection/ex_info.zig").registerGcHooks();
        @import("collection/vector.zig").registerGcHooks();
        @import("collection/map.zig").registerGcHooks();
        @import("collection/map_entry.zig").registerGcHooks();
        @import("collection/persistent_queue.zig").registerGcHooks();
        @import("collection/java_array.zig").registerGcHooks();
        @import("collection/set.zig").registerGcHooks();
        @import("lazy_seq.zig").registerGcHooks();
        @import("collection/chunked_cons.zig").registerGcHooks();
        @import("collection/reduced.zig").registerGcHooks();
        @import("collection/sorted.zig").registerGcHooks();
        @import("atom.zig").registerGcHooks();
        @import("volatile.zig").registerGcHooks();
        @import("stm/tval.zig").registerGcHooks();
        @import("stm/ref.zig").registerGcHooks();
        @import("delay.zig").registerGcHooks();
        @import("promise.zig").registerGcHooks();
        @import("future.zig").registerGcHooks();
        @import("agent.zig").registerGcHooks();
        @import("collection/transient/transient_vector.zig").registerGcHooks();
        @import("collection/transient/transient_array_map.zig").registerGcHooks();
        @import("collection/transient/transient_hash_set.zig").registerGcHooks();
        @import("numeric/big_int.zig").registerGcHooks();
        @import("numeric/ratio.zig").registerGcHooks();
        @import("numeric/big_decimal.zig").registerGcHooks();
        @import("regex/value.zig").registerGcHooks();
        @import("uuid.zig").registerGcHooks();
        @import("host_instance.zig").registerGcHooks();
        @import("tagged_literal.zig").registerGcHooks();
        @import("type_descriptor.zig").registerGcHooks();
        @import("multimethod.zig").registerGcHooks();
        // D-251 / ADR-0095 Alt D consistency guard: the isGcManaged membrane
        // (heap_tag.zig SSOT) must agree with GC-hook registration — any tag
        // carrying a trace or finaliser is a mark-phase-visited object, so it
        // MUST be GcManaged. Catches a future gc.alloc'd type misclassified as
        // non-GC (which would sweep it while live). Once per Runtime.init.
        {
            const tag_ops_mod = @import("gc/tag_ops.zig");
            const heap_tag_mod = @import("value/heap_tag.zig");
            var t: u8 = 0;
            while (t < 64) : (t += 1) {
                if (tag_ops_mod.tag_trace_table[t] != null or tag_ops_mod.tag_finaliser_table[t] != null) {
                    std.debug.assert(heap_tag_mod.isGcManaged(@enumFromInt(t)));
                }
            }
        }
        return .{
            .io = io,
            .gpa = gpa,
            .keywords = KeywordInterner.init(gpa),
            .symbols = SymbolInterner.init(gpa),
            .gc = GcHeap.init(gpa),
            .types = std.StringHashMap(*const TypeDescriptor).init(gpa),
            .load_arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *Runtime) void {
        // Free the interned empty-list singleton (gc.infra-allocated, not
        // GC-swept — D-164). Idempotent / no-op if never materialised.
        @import("collection/list.zig").deinitEmptyList(self);
        @import("collection/persistent_queue.zig").deinitEmptyQueue(self);
        @import("locale.zig").deinitSingletons(self);
        @import("host_enum.zig").deinitConsts(self);
        @import("math_context.zig").deinitSingletons(self);
        // Free the per-Runtime Date descriptor (gc.infra — D-200/ADR-0079).
        @import("time/date.zig").deinitDescriptor(self);
        @import("time/timestamp.zig").deinitDescriptor(self);
        @import("time/instant_value.zig").deinitDescriptor(self);
        @import("time/duration_value.zig").deinitDescriptor(self);
        @import("time/local_date_time_value.zig").deinitDescriptor(self);
        @import("time/local_date_value.zig").deinitDescriptor(self);
        @import("time/local_time_value.zig").deinitDescriptor(self);

        // User-set system properties (gpa-owned key+value dupes).
        {
            var it = self.system_properties.iterator();
            while (it.next()) |e| {
                self.gpa.free(e.key_ptr.*);
                self.gpa.free(e.value_ptr.*);
            }
            self.system_properties.deinit(self.gpa);
        }
        // Thread/Runtime host_instance singletons (gc.infra-allocated, no user
        // Values inside — a plain destroy, the locale-singleton pattern).
        for ([_]*@import("value/value.zig").Value{ &self.thread_current, &self.runtime_instance }) |slot| {
            if (slot.isNil()) continue;
            self.gc.infra.destroy(@constCast(@import("host_instance.zig").asHostInstance(slot.*)));
            slot.* = .nil_val;
        }

        // D-481: finalise the GC heap BEFORE freeing the native/class/user
        // TypeDescriptors below. A `.host_instance` finaliser (host_instance.zig
        // finaliseGc) reads `inst.descriptor.host_finalise`, so the descriptor
        // must outlive finalisation. The descriptor frees use `gc.infra` (a
        // passed-in allocator FIELD that gc.deinit never tears down), so they are
        // valid AFTER this; `heap_objects` (gpa) is a separate list. Surfaced by a
        // host_instance whose descriptor was a native/class descriptor — extend a
        // protocol to Object + a host-native tag, then deinit (clojure.datafy).
        self.gc.deinit();

        // Free per-Tag native descriptors (their method_table slice was
        // re-allocated on rt.gc.infra by extendTypeWithImpls calls, plus each
        // method-name dup, plus the fqcn dup). All process-lifetime by policy;
        // freeing here keeps testing
        // allocator quiet.
        for (&self.native_descriptors) |*slot| {
            if (slot.*) |td| {
                if (td.fqcn) |n| self.gc.infra.free(n);
                for (td.method_table) |entry| {
                    self.gc.infra.free(entry.method_name);
                }
                if (td.method_table.len > 0) self.gc.infra.free(td.method_table);
                if (td.protocol_impls.len > 0) self.gc.infra.free(td.protocol_impls);
                self.gc.infra.destroy(td);
                slot.* = null;
            }
        }

        // Free synthetic exception / named `(class e)` descriptors (D-213). The
        // map key aliases each descriptor's fqcn dup, so freeing the fqcn frees
        // the key too. A user `(extend-protocol P Object …)` / extend onto a
        // host-class value (java.net.URI via rt.types is separate) reallocates
        // this descriptor's method_table / protocol_impls on rt.gc.infra via
        // __extend-type!, so free those too (mirrors the native_descriptors pass);
        // hiccup extends HtmlRenderer to Object, which first exercised this leak.
        {
            var it = self.class_descriptors.valueIterator();
            while (it.next()) |td_ptr| {
                const td = td_ptr.*;
                if (td.fqcn) |n| self.gc.infra.free(n);
                for (td.method_table) |entry| self.gc.infra.free(entry.method_name);
                if (td.method_table.len > 0) self.gc.infra.free(td.method_table);
                if (td.protocol_impls.len > 0) self.gc.infra.free(td.protocol_impls);
                self.gc.infra.destroy(td);
            }
            self.class_descriptors.deinit(self.gc.infra);
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
            // ProtocolDescriptor (process-lifetime via rt.trackHeap).
            // `protocol_impls` (D-190 / ADR-0068) is populated by
            // `addProtocolImpl` (`__extend-type!`) with borrowed
            // ProtocolDescriptor fqcn slices — free the slice only, not
            // the entries.
            for (td.method_table) |mentry| {
                self.gpa.free(mentry.method_name);
            }
            if (td.method_table.len > 0) self.gpa.free(td.method_table);
            if (td.protocol_impls.len > 0) self.gpa.free(td.protocol_impls);
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

        // ADR-0084: free fully-loaded-lib name keys + the require load arena.
        var ll_it = self.loaded_libs.iterator();
        while (ll_it.next()) |entry| self.gpa.free(entry.key_ptr.*);
        self.loaded_libs.deinit(self.gpa);
        self.load_arena.deinit();

        // ADR-0035 D7: free per-file source registry entries.
        var sr_it = self.source_registry.iterator();
        while (sr_it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.file);
            self.gpa.free(entry.value_ptr.text);
        }
        self.source_registry.deinit(self.gpa);

        // (gc.deinit moved up — D-481: it must run before the descriptor frees.)
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
