//! Env — namespace graph + Var registry + dynamic-binding stack.
//!
//! Per-session container. The CLI allocates one Env; an nREPL server
//! gives each client its own (per-session isolation, fixing v1's
//! shared-mutable-namespace race). Multiple Envs can share a single
//! Runtime — the back-reference lives on `Env.rt`, never the other
//! way round.
//!
//! ### Three-tier architecture
//!
//! - **Runtime** (`runtime.zig`): process-wide. io / gpa / interner /
//!   vtable.
//! - **Env** (this file): per session. namespace graph + `current_ns`
//!   + `(def ...)` Var creation + `(refer ...)` view.
//! - **threadlocal** (this file + `error.zig` + `dispatch.zig`): the
//!   per-thread state Clojure dynamic-var semantics demand. Concretely
//!   here: the `BindingFrame` stack consulted by `Var.deref` when the
//!   Var carries `^:dynamic`.
//!
//! ### Dynamic binding
//!
//! `(binding [*foo* 42] body)` pushes a frame; `defer popFrame()` pops
//! it. `Var.deref` walks the threadlocal chain on dynamic Vars and
//! returns the first match, or falls back to `Var.root`. Non-dynamic
//! Vars ignore frames altogether — they always return `root` — so the
//! analyzer doesn't need to special-case `let` vs `binding`.

const std = @import("std");
const Value = @import("value/value.zig").Value;
const Runtime = @import("runtime.zig").Runtime;

// --- Var ---

/// Mirrors Clojure's `^:dynamic` / `^:macro` / `^:private` metadata.
/// Packed into one byte so `Var` stays small.
pub const VarFlags = packed struct(u8) {
    /// `^:dynamic true` — `binding` may rebind on a per-thread frame.
    dynamic: bool = false,
    /// `^:macro` — analyzer expands the call instead of evaluating it.
    macro_: bool = false,
    /// `^:private` — not reachable from other namespaces via refer/var.
    private: bool = false,
    /// `^:zig-leaf true` — Zig-implemented leaf primitive (B2 pattern
    /// per ADR-0033 D4). Used by tooling to distinguish hand-written
    /// Zig leaf intern from regular `(def ...)`-produced Vars; does
    /// not affect runtime dispatch.
    zig_leaf: bool = false,
    /// `^:unsupported true` — declare-only placeholder per ADR-0033 D8.
    /// Analyzer raises `feature_not_supported_unsupported_var` when the
    /// Var is used as a callable. Used for vars like
    /// `clojure.walk/macroexpand-all` that depend on later-Phase
    /// machinery (Phase 7 macroexpand) but need a symbol present today.
    unsupported: bool = false,
    _pad: u3 = 0,
};

/// Per-Var metadata bundle accepted by `Env.intern`. All fields
/// optional; the default `.{}` is equivalent to no metadata.
///
/// Phase 6.16.a-0 (ADR-0033 D8): introduced as the first-class path
/// for injecting `^:private` / `^:zig-leaf` / `^:unsupported` from
/// Zig-side `env.intern` calls. The `.clj`-side `^:private` reader
/// macro lands later (D-066, Phase 6.16.b).
pub const MetadataMap = struct {
    /// `^:private` — analyzer blocks cross-namespace symbol reference.
    private: bool = false,
    /// `^:zig-leaf` — marker for Zig-side leaf primitives (Pattern B2).
    zig_leaf: bool = false,
    /// `^:unsupported` — declare-only placeholder; raises on call.
    unsupported: bool = false,
    /// `^:doc` string. Stored on the Var for `(doc fn-name)`.
    doc: ?[]const u8 = null,
    /// `^:arglists` (human-readable summary). Stored on the Var
    /// for `(doc fn-name)`.
    arglists: ?[]const u8 = null,
};

/// Clojure's `Var`: a named value holder produced by `def`.
pub const Var = struct {
    /// Owning namespace. Used to print the qualified `ns/name`.
    ns: *Namespace,
    /// Symbol name (the `name` portion of `ns/name`).
    name: []const u8,
    /// Global root binding (set by `def`). Visible whenever no dynamic
    /// binding is on the threadlocal chain.
    root: Value = .nil_val,
    /// True once a root VALUE has been assigned (`intern` with a value /
    /// `(def x v)`). A no-init `(def x)` / `internDeclare` placeholder leaves
    /// it false — the unbound sentinel `Var.root = nil` cannot distinguish.
    /// Powers `bound?` / `defonce` (clj's `.hasRoot`).
    bound: bool = false,
    /// `^{...}` metadata. Phase 3+ wires this; Phase 2 just stores it.
    meta: ?Value = null,
    /// dynamic / macro / private / zig_leaf / unsupported flags.
    flags: VarFlags = .{},
    /// `^:doc` — docstring for `(doc fn-name)`. Set via MetadataMap.
    doc: ?[]const u8 = null,
    /// `^:arglists` — human-readable signature for `(doc fn-name)`.
    arglists: ?[]const u8 = null,
    /// Watch map `{key -> fn}` (`add-watch` / `remove-watch`), or nil. Fires
    /// `(fn key var old new)` from `alter-var-root` only (a dynamic-binding
    /// `set!` does NOT notify, matching JVM `Var`). The Var is gpa-owned and
    /// `var_ref`-filtered from the GC membrane, so this map is reachable for the
    /// collector only via the `ns_vars` root walk (`root_set.zig` yields it
    /// alongside `Var.root` + `Var.meta`).
    watches: Value = .nil_val,

    /// Return the active value: dynamic binding (if any) for dynamic
    /// Vars, otherwise the root.
    pub fn deref(self: *const Var) Value {
        if (self.flags.dynamic) {
            if (findBinding(self)) |v| return v;
        }
        return self.root;
    }

    /// Overwrite the root binding directly. Used by `def` /
    /// `alter-var-root`. Dynamic bindings are intentionally ignored —
    /// `setRoot` is for the global slot.
    pub fn setRoot(self: *Var, v: Value) void {
        self.root = v;
    }
};

/// The Var's watch map (`nil` or a persistent `{key -> fn}`). IRef surface; `v`
/// is a `.var_ref`.
pub fn varWatchesOf(v: Value) Value {
    return v.decodePtr(*const Var).watches;
}

/// Replace the Var's watch map (`add-watch` / `remove-watch`). `v` is a `.var_ref`.
pub fn varSetWatches(v: Value, m: Value) void {
    @constCast(v.decodePtr(*const Var)).watches = m;
}

// --- Namespace ---

pub const VarMap = std.StringHashMapUnmanaged(*Var);
const NsAliasMap = std.StringHashMapUnmanaged(*Namespace);

/// Clojure namespace — the unit `(in-ns 'my.ns)` switches between.
pub const Namespace = struct {
    name: []const u8,
    /// Vars defined in this namespace via `(def ...)`.
    mappings: VarMap = .empty,
    /// Vars pulled in via `(refer ...)`. Phase 4 makes this end-user
    /// reachable; Phase 2 uses it via `referAll(rt_ns, user_ns)` so
    /// primitives like `+` resolve unqualified inside `user/`.
    refers: VarMap = .empty,
    /// `(require '[other :as alias])` produces these. Wired in Phase 4.
    aliases: NsAliasMap = .empty,
    /// `(:import pkg.Class …)` simple-name → JVM-form FQCN map (D-235).
    /// Consulted by `resolveJavaSurface` so a bare `(Class. …)` resolves to
    /// the imported class. Keys + values are owned by this map.
    imports: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// Register `simple → fqcn` (idempotent; re-import overwrites the FQCN,
    /// matching JVM `(import …)` last-wins). Keys/values are duplicated on
    /// first insertion; re-import frees nothing (the map owns both).
    pub fn addImport(self: *Namespace, alloc: std.mem.Allocator, simple: []const u8, fqcn: []const u8) !void {
        const gop = try self.imports.getOrPut(alloc, simple);
        if (!gop.found_existing) {
            gop.key_ptr.* = try alloc.dupe(u8, simple);
        } else {
            alloc.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = try alloc.dupe(u8, fqcn);
    }

    /// Resolve `name`: own mappings first, then refers. Returns null if
    /// neither finds it (the analyzer/runtime decides whether that's a
    /// `name_error` or e.g. a special form).
    pub fn resolve(self: *Namespace, name: []const u8) ?*Var {
        if (self.mappings.get(name)) |v| return v;
        if (self.refers.get(name)) |v| return v;
        return null;
    }

    /// Resolve `name` for a FULLY-QUALIFIED reference `self/name`. clj treats a
    /// qualified symbol as a direct ns-var lookup that bypasses refers/aliases,
    /// so only `self`'s own interns satisfy it — a var merely *referred* into
    /// `self` does NOT (clj: "No such var: ns/name"). D-261.
    ///
    /// EXCEPTION: `clojure.core`. cljw splits the core surface across the
    /// internal `rt/` namespace and re-exports it into `clojure.core` via
    /// refers (only `clojure.core` receives rt's refers at bootstrap). In clj
    /// every core fn IS interned in `clojure.core`, so for `clojure.core/name`
    /// those rt-refers count as its own — otherwise `clojure.core/re-find`
    /// (an rt-origin var) would wrongly fail while `clojure.core/map` (a direct
    /// core.clj intern) succeeds. Non-core namespaces stay own-mappings-only.
    pub fn resolveQualified(self: *Namespace, name: []const u8) ?*Var {
        if (self.mappings.get(name)) |v| return v;
        if (std.mem.eql(u8, self.name, "clojure.core")) {
            if (self.refers.get(name)) |v| return v;
        }
        return null;
    }

    /// Internal: free everything this namespace owns. The `name` slice
    /// itself is **not** freed here — it is shared with the
    /// `Env.namespaces` map key, and `Env.deinit` frees it exactly once.
    fn deinit(self: *Namespace, alloc: std.mem.Allocator) void {
        // mappings owns its keys (= Var.name) and the Var bodies.
        var it = self.mappings.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.destroy(entry.value_ptr.*);
        }
        self.mappings.deinit(alloc);
        // refers / aliases own only their key strings; the Vars and
        // Namespaces they point at belong to the source namespace.
        var rit = self.refers.keyIterator();
        while (rit.next()) |k| alloc.free(k.*);
        self.refers.deinit(alloc);
        var ait = self.aliases.keyIterator();
        while (ait.next()) |k| alloc.free(k.*);
        self.aliases.deinit(alloc);
        // imports owns both its keys (simple names) and values (FQCNs).
        var iit = self.imports.iterator();
        while (iit.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        self.imports.deinit(alloc);
    }
};

// --- threadlocal dynamic-binding stack ---

pub const BindingMap = std.AutoHashMapUnmanaged(*const Var, Value);

/// One frame produced by a `(binding [*x* 1 *y* 2] ...)` form. Frames
/// chain via `parent` so nested `binding` forms see the innermost
/// shadowing first.
pub const BindingFrame = struct {
    parent: ?*BindingFrame = null,
    bindings: BindingMap = .empty,
    /// True only for frames `push-thread-bindings` heap-allocated, so
    /// `pop-thread-bindings` frees exactly those and never a form's
    /// `binding` frame (stack-allocated in TreeWalk, VM-owned in the VM).
    user_pushed: bool = false,
};

/// Top of this thread's dynamic-binding stack. `null` when no
/// `binding` is active. **threadlocal** because Clojure semantics
/// demand per-thread visibility — this is the one place
/// (`runtime/error.zig`'s `last_error` is the other) where a
/// threadlocal is actually load-bearing rather than incidental.
pub threadlocal var current_frame: ?*BindingFrame = null;

/// Optional teardown callback invoked at the START of `Env.deinit`,
/// before the Env's Vars are freed. Set by subsystems that cache a
/// process-global pointer into an Env's Vars so the pointer cannot
/// dangle past the Env (currently `runtime/error/context.zig`). Single
/// slot — chain here if a second consumer ever appears.
pub var on_deinit_hook: ?*const fn () void = null;

/// Push a frame at `binding` entry. Pair every push with `popFrame`,
/// typically via `defer` at the call site.
pub fn pushFrame(frame: *BindingFrame) void {
    frame.parent = current_frame;
    current_frame = frame;
}

pub fn popFrame() void {
    if (current_frame) |f| {
        current_frame = f.parent;
    }
}

/// Walk the chain looking for a value bound for `v`. Inner frames
/// shadow outer ones because the chain is consulted top-down.
pub fn findBinding(v: *const Var) ?Value {
    var f = current_frame;
    while (f) |frame| {
        if (frame.bindings.get(v)) |val| return val;
        f = frame.parent;
    }
    return null;
}

/// Update the innermost active thread binding for `v` in place. Returns
/// true if a frame held `v` (it was thread-bound), false otherwise — the
/// `set!` caller falls back to `Var.setRoot` in the false case.
pub fn setBinding(v: *const Var, val: Value) bool {
    var f = current_frame;
    while (f) |frame| {
        if (frame.bindings.getPtr(v)) |slot| {
            slot.* = val;
            return true;
        }
        f = frame.parent;
    }
    return false;
}

// --- Env ---

pub const NamespaceMap = std.StringHashMapUnmanaged(*Namespace);

/// Per-session namespace graph.
pub const Env = struct {
    /// Process-wide handle. Multiple Envs may share one Runtime.
    rt: *Runtime,
    /// Allocator alias for `rt.gpa`. Held as a field so call sites can
    /// pass `env.alloc` without reaching back to `rt`.
    alloc: std.mem.Allocator,
    /// All registered namespaces; key is the namespace name.
    namespaces: NamespaceMap = .empty,
    /// Current value of `*ns*`. Right after `init`, points at `user`.
    /// Mutate ONLY via `setCurrentNs` so the `*ns*` Var root stays in sync
    /// (ADR-0083).
    current_ns: ?*Namespace = null,
    /// The interned `clojure.core/*ns*` dynamic Var, cached at bootstrap so
    /// `setCurrentNs` can keep its root pointing at `current_ns` as an `.ns`
    /// Value (ADR-0083). `null` until bootstrap interns it (the few pre-bootstrap
    /// `findOrCreateNs` switches simply have no Var to update yet).
    ns_var: ?*Var = null,

    /// `with-local-vars` anonymous-Var support (ADR-0097). `local_var_ns` is a
    /// sentinel `__local` Namespace (NOT in `namespaces`, so never walked /
    /// printed as a real ns) that anon Vars point `.ns` at; `local_vars` owns
    /// every anon Var minted by `-create-local-var`. The Vars are NOT freed at
    /// their `with-local-vars` extent (an escaped `var_ref` must stay deref-safe
    /// — ADR-0097 Alt C); instead the session owns them and frees the lot in
    /// `deinit`. D-255 = per-extent reclamation (a generation-handle slotmap).
    local_var_ns: ?*Namespace = null,
    local_vars: std.ArrayList(*Var) = .empty,

    /// Initialise with the three startup namespaces:
    ///   - `rt`           → kernel primitives (`+`, `=`, `count`, …)
    ///   - `clojure.core` → public Clojure surface + private leaves
    ///                      (`-*-eager`) per ADR-0033 D4
    ///   - `user`         → default eval target; `current_ns` set here.
    ///
    /// Creating `clojure.core` at init time (rather than letting
    /// `(in-ns 'clojure.core)` in `core.clj` create it on demand) lets
    /// `primitive.registerAll` intern Pattern B2 private leaves into
    /// `clojure.core` before bootstrap runs, so the leaves are
    /// same-ns visible from `core.clj`'s wrappers and cross-ns
    /// `^:private`-blocked from `user/`. `findOrCreateNs` is
    /// idempotent so `(in-ns 'clojure.core)` later just switches.
    pub fn init(rt: *Runtime) !Env {
        var env = Env{ .rt = rt, .alloc = rt.gpa };
        _ = try env.findOrCreateNs("rt");
        _ = try env.findOrCreateNs("clojure.core");
        const user = try env.findOrCreateNs("user");
        env.current_ns = user;
        return env;
    }

    /// Switch the current namespace. The single mutator for `current_ns`
    /// (ADR-0083): also re-points the cached `*ns*` Var root at `ns` as an
    /// `.ns` Value, so `*ns*` / `(ns-name *ns*)` track the live ns. Route every
    /// ns switch (`in-ns` / `ns` / `require` / eval-target) through this.
    pub fn setCurrentNs(self: *Env, ns: *Namespace) void {
        if (self.ns_var) |nv| {
            const nsv = nsValue(ns);
            // set!-semantics (ADR-0085): update the innermost live `*ns*`
            // thread binding if one exists — so `(binding [*ns* *ns*]
            // (in-ns x) …)` rebinds the frame, not the root, and pops back
            // cleanly — else update the root. `current_ns` is then the
            // materialised view of `*ns*`.
            if (!setBinding(nv, nsv)) nv.setRoot(nsv);
        }
        self.current_ns = ns;
    }

    /// Re-derive `current_ns` from `*ns*`'s effective value (which respects
    /// thread bindings via `Var.deref`). `current_ns` is a materialised VIEW
    /// of `*ns*` (ADR-0085), refreshed at the `binding`-frame boundaries
    /// (push / pop) so a `(binding [*ns* …] …)` round-trips. No-op before
    /// bootstrap interns `ns_var` (the field is authoritative in that window).
    pub fn refreshCurrentNs(self: *Env) void {
        const nv = self.ns_var orelse return;
        const v = nv.deref();
        if (v.tag() == .ns) self.current_ns = v.decodePtr(*Namespace);
    }

    /// Wrap a `*Namespace` as a first-class `.ns` Value (ADR-0083). The pointer
    /// is Env-lifetime (not GC-allocated); `Value.heapHeader` skips `.ns` so the
    /// GC never traces it.
    pub fn nsValue(ns: *Namespace) Value {
        return Value.encodeHeapPtr(.ns, ns);
    }

    pub fn deinit(self: *Env) void {
        // Clear any process-global slot that points INTO this Env's
        // Vars before they are freed, so the slot can never dangle.
        // Currently the sole consumer is `runtime/error/context.zig`'s
        // `*error-context*` Var slot (ADR-0055 D3): a stale slot would
        // UAF on the next `setErrorFmt` (e.g. across `setupCore`-using
        // tests). Production runs one Env for the process lifetime, so
        // this fires only at exit.
        if (on_deinit_hook) |h| h();
        // ADR-0096: the baseline binding frame is arena-owned (freed by the
        // caller's arena), but `current_frame` is a threadlocal that would
        // otherwise outlive this session and dangle into the next setupCore-
        // using test. Null it here (no deref) so the frame chain never points
        // at freed arena memory across sessions.
        current_frame = null;
        // ADR-0097: free the session's `with-local-vars` anonymous Vars + the
        // sentinel ns (neither lives in `namespaces`, so the loop below misses
        // them). Freeing at session end (not at each extent) keeps an escaped
        // local var deref-safe for the whole session.
        for (self.local_vars.items) |v| self.alloc.destroy(v);
        self.local_vars.deinit(self.alloc);
        if (self.local_var_ns) |ns| self.alloc.destroy(ns);
        var it = self.namespaces.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.alloc);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.namespaces.deinit(self.alloc);
        self.namespaces = .empty;
        self.current_ns = null;
    }

    /// Get a namespace by name; create + register one if missing.
    pub fn findOrCreateNs(self: *Env, name: []const u8) !*Namespace {
        if (self.namespaces.get(name)) |ns| return ns;
        const owned_name = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(owned_name);
        const ns = try self.alloc.create(Namespace);
        errdefer self.alloc.destroy(ns);
        ns.* = .{ .name = owned_name };
        try self.namespaces.put(self.alloc, owned_name, ns);
        return ns;
    }

    /// Look up a namespace by name without side effects.
    pub fn findNs(self: *Env, name: []const u8) ?*Namespace {
        return self.namespaces.get(name);
    }

    /// Copy every **non-private** mapping in `from` into `to.refers`.
    /// Idempotent — duplicate names are silently skipped. ADR-0035 D4:
    /// `^:private` Vars are silently filtered (JVM `:refer :all`
    /// semantics). Use `referOne` for explicit `:refer [name ...]`
    /// where a private name should be a fail-fast error.
    pub fn referAll(self: *Env, from: *Namespace, to: *Namespace) !void {
        return self.referAllWithFilter(from, to, &.{}, null);
    }

    /// Row 14.7 (D-098): filtered variant of `referAll`. When `only`
    /// is non-null, ONLY names in that slice land (whitelist). The
    /// `exclude` slice is always honoured (names listed there never
    /// land). The `^:private` filter still applies regardless of the
    /// caller-supplied filters. Both slices are linear-scanned;
    /// typical N ≤ 10 so HashMap setup would cost more than it saves.
    /// Powers `(ns foo (:refer-clojure :exclude [+] :only [...]))`.
    pub fn referAllWithFilter(
        self: *Env,
        from: *Namespace,
        to: *Namespace,
        exclude: []const []const u8,
        only: ?[]const []const u8,
    ) !void {
        return self.referAllImpl(from, to, exclude, only, false);
    }

    /// Like `referAllWithFilter`, but an existing refer of the same name is
    /// REPLACED instead of skipped. Used for the `clojure.core` half of the
    /// `(:refer-clojure)` auto-refer pair (ADR-0035 D9 revision): `rt/` lands
    /// first (internal primitives), then clojure.core overrides any name it
    /// redefines — the public layer wins over the internal one, so a core.clj
    /// wrapper of an rt primitive (e.g. the matcher-arity `re-find`) is the
    /// one user code reaches unqualified.
    pub fn referAllOverriding(
        self: *Env,
        from: *Namespace,
        to: *Namespace,
        exclude: []const []const u8,
        only: ?[]const []const u8,
    ) !void {
        return self.referAllImpl(from, to, exclude, only, true);
    }

    fn referAllImpl(
        self: *Env,
        from: *Namespace,
        to: *Namespace,
        exclude: []const []const u8,
        only: ?[]const []const u8,
        override: bool,
    ) !void {
        var it = from.mappings.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (entry.value_ptr.*.flags.private) continue;
            if (only) |whitelist| {
                if (!containsName(whitelist, name)) continue;
            }
            if (containsName(exclude, name)) continue;
            if (to.refers.getPtr(name)) |slot| {
                if (override) slot.* = entry.value_ptr.*;
                continue;
            }
            const owned_key = try self.alloc.dupe(u8, name);
            errdefer self.alloc.free(owned_key);
            try to.refers.put(self.alloc, owned_key, entry.value_ptr.*);
        }
    }

    /// Outcome of a `referOne` call. The caller (typically the
    /// `require` fn handling `(:refer [a b c])`) maps each outcome to
    /// the appropriate `error_catalog` raise with its own source
    /// location — `env.zig` deliberately stays free of catalog
    /// dependencies. ADR-0035 D4.
    pub const ReferOneOutcome = enum {
        /// Refer installed (or already present — both treated as success).
        installed,
        /// Source Var exists but carries `^:private` — caller should
        /// raise `private_access_error`.
        private_blocked,
        /// `from.mappings` has no entry for `name` — caller should
        /// raise `symbol_unresolved`.
        not_found,
    };

    /// Install a single `from/name → to.refers/name` edge. Idempotent
    /// against re-installation. Returns `.private_blocked` /
    /// `.not_found` rather than raising so the caller can attach
    /// source location to the catalog raise. ADR-0035 D4.
    pub fn referOne(
        self: *Env,
        from: *Namespace,
        to: *Namespace,
        name: []const u8,
    ) !ReferOneOutcome {
        const src = from.mappings.get(name) orelse return .not_found;
        if (src.flags.private) return .private_blocked;
        if (to.refers.contains(name)) return .installed;
        const owned_key = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(owned_key);
        try to.refers.put(self.alloc, owned_key, src);
        return .installed;
    }

    /// Register `alias → target` in `ns.aliases`. ADR-0035 D3.
    /// REPL-time re-aliasing is supported: if `alias` already maps to
    /// some namespace, the target is silently overwritten (JVM
    /// `(alias ...)` semantics). The key string is duplicated on first
    /// insertion; re-aliasing reuses the existing key.
    pub fn setAlias(
        self: *Env,
        ns: *Namespace,
        alias_name: []const u8,
        target: *Namespace,
    ) !void {
        if (ns.aliases.getEntry(alias_name)) |existing| {
            existing.value_ptr.* = target;
            return;
        }
        const owned_key = try self.alloc.dupe(u8, alias_name);
        errdefer self.alloc.free(owned_key);
        try ns.aliases.put(self.alloc, owned_key, target);
    }

    /// `(def name root)` equivalent. Creates a new Var in `ns`, or
    /// updates the existing Var's `root` in place if `name` is already
    /// bound. Update-in-place is what makes `def` idempotent at the
    /// REPL — repeated `(def x ...)` shouldn't churn references.
    pub fn intern(
        self: *Env,
        ns: *Namespace,
        name: []const u8,
        root: Value,
        meta: ?MetadataMap,
    ) !*Var {
        if (ns.mappings.get(name)) |existing| {
            existing.root = root;
            existing.bound = true; // a value was assigned
            if (meta) |m| applyMetadata(existing, m);
            return existing;
        }
        const owned_name = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(owned_name);
        const v = try self.alloc.create(Var);
        errdefer self.alloc.destroy(v);
        v.* = .{ .ns = ns, .name = owned_name, .root = root, .bound = true };
        if (meta) |m| applyMetadata(v, m);
        try ns.mappings.put(self.alloc, owned_name, v);
        return v;
    }

    /// Register a placeholder Var for `name` if absent (root nil), returning
    /// the existing local Var UNTOUCHED if present (ADR-0038 amendment,
    /// D-184). The analyzer pre-registers a def target so recursive / forward
    /// references resolve — but resolvability only needs the Var to *exist*,
    /// not to be reset to nil. `evalDef` / op_def set the real value at eval
    /// time, so a throwing re-def must leave the old root intact (JVM parity:
    /// `(def x 5) (def x (/ 1 0)) x` → 5), and `defmulti`'s defonce-style
    /// no-op (D-184) can see the prior MultiFn. Checks `ns.mappings` (local
    /// only, NOT `resolve` — a refer'd name must not suppress a shadowing
    /// local def). The value-bearing `intern` keeps its eval-time overwrite
    /// contract.
    pub fn internDeclare(self: *Env, ns: *Namespace, name: []const u8) !*Var {
        if (ns.mappings.get(name)) |existing| return existing;
        const owned_name = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(owned_name);
        const v = try self.alloc.create(Var);
        errdefer self.alloc.destroy(v);
        v.* = .{ .ns = ns, .name = owned_name, .root = .nil_val };
        try ns.mappings.put(self.alloc, owned_name, v);
        return v;
    }
};

/// Linear-scan name match; used by `referAllWithFilter` to test
/// `exclude` / `only` membership without a HashMap setup cost.
fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Copy MetadataMap fields onto the Var. Idempotent — re-interning
/// with the same metadata is a no-op. Re-interning with a *different*
/// MetadataMap merges into the existing Var (last writer wins per
/// field). Used by both first-intern and re-intern paths in
/// `Env.intern`.
fn applyMetadata(v: *Var, m: MetadataMap) void {
    v.flags.private = m.private;
    v.flags.zig_leaf = m.zig_leaf;
    v.flags.unsupported = m.unsupported;
    v.doc = m.doc;
    v.arglists = m.arglists;
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

test "Env.init creates rt and user namespaces; current_ns = user" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    try testing.expect(env.findNs("rt") != null);
    try testing.expect(env.findNs("user") != null);
    try testing.expectEqualStrings("user", env.current_ns.?.name);
}

test "findOrCreateNs is idempotent" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const a = try env.findOrCreateNs("my.ns");
    const b = try env.findOrCreateNs("my.ns");
    try testing.expectEqual(a, b);
}

test "Env.intern creates a Var with root and back-reference to ns" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const user = env.findNs("user").?;
    const v = try env.intern(user, "x", .true_val, null);
    try testing.expectEqual(Value.true_val, v.root);
    try testing.expectEqual(user, v.ns);
    try testing.expectEqualStrings("x", v.name);
}

test "Env.intern updates root in place on re-def" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const user = env.findNs("user").?;
    const v1 = try env.intern(user, "x", .nil_val, null);
    const v2 = try env.intern(user, "x", .true_val, null);
    try testing.expectEqual(v1, v2); // same Var pointer
    try testing.expectEqual(Value.true_val, v1.root);
}

test "Namespace.resolve hits mappings; misses unknown" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const user = env.findNs("user").?;
    _ = try env.intern(user, "y", .true_val, null);
    try testing.expect(user.resolve("y") != null);
    try testing.expect(user.resolve("nope") == null);
}

test "Var.deref returns root when no dynamic binding is active" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const user = env.findNs("user").?;
    const v = try env.intern(user, "x", .true_val, null);
    try testing.expectEqual(Value.true_val, v.deref());
}

test "Var.deref respects dynamic binding stack on dynamic Vars" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const user = env.findNs("user").?;
    const v = try env.intern(user, "*x*", .nil_val, null);
    v.flags.dynamic = true;

    try testing.expectEqual(Value.nil_val, v.deref()); // root visible

    var frame: BindingFrame = .{};
    defer frame.bindings.deinit(testing.allocator);
    try frame.bindings.put(testing.allocator, v, .true_val);
    pushFrame(&frame);
    defer popFrame();

    try testing.expectEqual(Value.true_val, v.deref());
}

test "Var.deref ignores binding when Var is not dynamic" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const user = env.findNs("user").?;
    const v = try env.intern(user, "x", .nil_val, null);
    // Leave flags.dynamic = false intentionally.

    var frame: BindingFrame = .{};
    defer frame.bindings.deinit(testing.allocator);
    try frame.bindings.put(testing.allocator, v, .true_val);
    pushFrame(&frame);
    defer popFrame();

    // Non-dynamic Vars ignore frames and always return root.
    try testing.expectEqual(Value.nil_val, v.deref());
}

test "BindingFrame: nested frames see innermost binding" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const user = env.findNs("user").?;
    const v = try env.intern(user, "*x*", .nil_val, null);
    v.flags.dynamic = true;

    var f1: BindingFrame = .{};
    defer f1.bindings.deinit(testing.allocator);
    try f1.bindings.put(testing.allocator, v, .true_val);
    pushFrame(&f1);
    defer popFrame();
    try testing.expectEqual(Value.true_val, v.deref());

    var f2: BindingFrame = .{};
    defer f2.bindings.deinit(testing.allocator);
    try f2.bindings.put(testing.allocator, v, .false_val);
    pushFrame(&f2);
    defer popFrame();
    // Inner frame wins.
    try testing.expectEqual(Value.false_val, v.deref());
}

test "referAll exposes source mappings under target.refers" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const rt_ns = env.findNs("rt").?;
    const user = env.findNs("user").?;
    _ = try env.intern(rt_ns, "+", .true_val, null);

    try env.referAll(rt_ns, user);
    // user/+ now resolves through refers.
    try testing.expect(user.resolve("+") != null);
    // user does not own the Var — it lives in rt's mappings.
    try testing.expect(!user.mappings.contains("+"));
    try testing.expect(user.refers.contains("+"));

    // Idempotent — second call doesn't double-insert or leak.
    try env.referAll(rt_ns, user);
    try testing.expectEqual(@as(usize, 1), user.refers.count());
}

test "referAllOverriding replaces an existing refer; referAll keeps it (ADR-0035 D9 rev)" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const rt_ns = env.findNs("rt").?;
    const user = env.findNs("user").?;
    const core = try env.findOrCreateNs("clojure.core");
    const rt_var = try env.intern(rt_ns, "re-find", .true_val, null);
    const core_var = try env.intern(core, "re-find", .false_val, null);

    // rt refers first (boot fan-out order).
    try env.referAll(rt_ns, user);
    try testing.expectEqual(rt_var, user.refers.get("re-find").?);

    // Plain referAll skips the collision — rt would win (the latent bug).
    try env.referAll(core, user);
    try testing.expectEqual(rt_var, user.refers.get("re-find").?);

    // The overriding variant replaces it — the public layer wins.
    try env.referAllOverriding(core, user, &.{}, null);
    try testing.expectEqual(core_var, user.refers.get("re-find").?);
    try testing.expectEqual(@as(usize, 1), user.refers.count());
}

test "Two Envs sharing a Runtime have isolated namespaces" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env1 = try Env.init(&fix.rt);
    defer env1.deinit();
    var env2 = try Env.init(&fix.rt);
    defer env2.deinit();

    const user1 = env1.findNs("user").?;
    _ = try env1.intern(user1, "x", .true_val, null);

    const user2 = env2.findNs("user").?;
    try testing.expect(user2.resolve("x") == null);
}

test "VarFlags packs into one byte" {
    try testing.expectEqual(@as(usize, 1), @sizeOf(VarFlags));
}

test "Env.intern with null metadata leaves flags + doc default" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const ns = try env.findOrCreateNs("my.ns");
    const v = try env.intern(ns, "x", Value.nil_val, null);
    try testing.expect(!v.flags.private);
    try testing.expect(!v.flags.zig_leaf);
    try testing.expect(!v.flags.unsupported);
    try testing.expect(v.doc == null);
    try testing.expect(v.arglists == null);
}

test "Env.intern with MetadataMap sets all fields" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const ns = try env.findOrCreateNs("my.ns");
    const v = try env.intern(ns, "-secret", Value.nil_val, .{
        .private = true,
        .zig_leaf = true,
        .unsupported = false,
        .doc = "a private leaf",
        .arglists = "([x])",
    });
    try testing.expect(v.flags.private);
    try testing.expect(v.flags.zig_leaf);
    try testing.expect(!v.flags.unsupported);
    try testing.expectEqualStrings("a private leaf", v.doc.?);
    try testing.expectEqualStrings("([x])", v.arglists.?);
}

test "Env.intern re-intern with new metadata overwrites previous metadata" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const ns = try env.findOrCreateNs("my.ns");
    _ = try env.intern(ns, "x", Value.nil_val, .{ .private = true });
    const v2 = try env.intern(ns, "x", Value.true_val, .{ .private = false, .unsupported = true });
    try testing.expect(!v2.flags.private);
    try testing.expect(v2.flags.unsupported);
    try testing.expectEqual(Value.true_val, v2.root);
}

test "Env.intern with ^:unsupported marker stores flag" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const ns = try env.findOrCreateNs("clojure.walk");
    const v = try env.intern(ns, "macroexpand-all", Value.nil_val, .{
        .private = false,
        .unsupported = true,
    });
    try testing.expect(v.flags.unsupported);
    try testing.expect(!v.flags.private);
}

test "Env.init creates clojure.core namespace (ADR-0035 prereq)" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    try testing.expect(env.findNs("clojure.core") != null);
}

test "referAll skips ^:private Vars (ADR-0035 D4)" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const src = try env.findOrCreateNs("src.ns");
    const dst = try env.findOrCreateNs("dst.ns");
    _ = try env.intern(src, "public", Value.initInteger(1), null);
    _ = try env.intern(src, "private", Value.initInteger(2), .{ .private = true });

    try env.referAll(src, dst);

    try testing.expect(dst.refers.contains("public"));
    try testing.expect(!dst.refers.contains("private"));
}

test "referOne returns .installed for public, .private_blocked for private, .not_found otherwise" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const src = try env.findOrCreateNs("src.ns");
    const dst = try env.findOrCreateNs("dst.ns");
    _ = try env.intern(src, "public", Value.initInteger(1), null);
    _ = try env.intern(src, "private", Value.initInteger(2), .{ .private = true });

    try testing.expectEqual(Env.ReferOneOutcome.installed, try env.referOne(src, dst, "public"));
    try testing.expect(dst.refers.contains("public"));

    try testing.expectEqual(Env.ReferOneOutcome.private_blocked, try env.referOne(src, dst, "private"));
    try testing.expect(!dst.refers.contains("private"));

    try testing.expectEqual(Env.ReferOneOutcome.not_found, try env.referOne(src, dst, "missing"));

    // Re-installing an already-referred name is idempotent.
    try testing.expectEqual(Env.ReferOneOutcome.installed, try env.referOne(src, dst, "public"));
}

test "setAlias registers an alias and supports REPL-time re-aliasing" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const here = try env.findOrCreateNs("here.ns");
    const first = try env.findOrCreateNs("first.target");
    const second = try env.findOrCreateNs("second.target");

    try env.setAlias(here, "t", first);
    try testing.expectEqual(first, here.aliases.get("t").?);

    // Re-aliasing the same name overwrites the target without
    // leaking the previous key (key is reused; value is overwritten).
    try env.setAlias(here, "t", second);
    try testing.expectEqual(second, here.aliases.get("t").?);
    try testing.expectEqual(@as(u32, 1), here.aliases.count());
}
