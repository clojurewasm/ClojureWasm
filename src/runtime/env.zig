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
const Value = @import("value.zig").Value;
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
    _pad: u5 = 0,
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
    /// `^{...}` metadata. Phase 3+ wires this; Phase 2 just stores it.
    meta: ?Value = null,
    /// dynamic / macro / private flags.
    flags: VarFlags = .{},

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

// --- Namespace ---

const VarMap = std.StringHashMapUnmanaged(*Var);
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

    /// Resolve `name`: own mappings first, then refers. Returns null if
    /// neither finds it (the analyzer/runtime decides whether that's a
    /// `name_error` or e.g. a special form).
    pub fn resolve(self: *Namespace, name: []const u8) ?*Var {
        if (self.mappings.get(name)) |v| return v;
        if (self.refers.get(name)) |v| return v;
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
    }
};

// --- threadlocal dynamic-binding stack ---

const BindingMap = std.AutoHashMapUnmanaged(*const Var, Value);

/// One frame produced by a `(binding [*x* 1 *y* 2] ...)` form. Frames
/// chain via `parent` so nested `binding` forms see the innermost
/// shadowing first.
pub const BindingFrame = struct {
    parent: ?*BindingFrame = null,
    bindings: BindingMap = .empty,
};

/// Top of this thread's dynamic-binding stack. `null` when no
/// `binding` is active. **threadlocal** because Clojure semantics
/// demand per-thread visibility — this is the one place
/// (`runtime/error.zig`'s `last_error` is the other) where a
/// threadlocal is actually load-bearing rather than incidental.
pub threadlocal var current_frame: ?*BindingFrame = null;

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

// --- Env ---

const NamespaceMap = std.StringHashMapUnmanaged(*Namespace);

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
    current_ns: ?*Namespace = null,

    /// Initialise with the two startup namespaces:
    ///   - `rt`   → kernel primitives (Phase 2.7 registers `+`, `*`, …)
    ///   - `user` → default eval target; `current_ns` set here.
    pub fn init(rt: *Runtime) !Env {
        var env = Env{ .rt = rt, .alloc = rt.gpa };
        _ = try env.findOrCreateNs("rt");
        const user = try env.findOrCreateNs("user");
        env.current_ns = user;
        return env;
    }

    pub fn deinit(self: *Env) void {
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

    /// Copy every mapping in `from` into `to.refers`. Idempotent —
    /// duplicate names are silently skipped. Phase-2 boot calls this
    /// against (rt → user) so primitives like `+` resolve unqualified
    /// at the user prompt. The real `(refer 'rt)` semantics arrive in
    /// Phase 4 alongside `(require ...)`.
    pub fn referAll(self: *Env, from: *Namespace, to: *Namespace) !void {
        var it = from.mappings.iterator();
        while (it.next()) |entry| {
            if (to.refers.contains(entry.key_ptr.*)) continue;
            const owned_key = try self.alloc.dupe(u8, entry.key_ptr.*);
            errdefer self.alloc.free(owned_key);
            try to.refers.put(self.alloc, owned_key, entry.value_ptr.*);
        }
    }

    /// `(def name root)` equivalent. Creates a new Var in `ns`, or
    /// updates the existing Var's `root` in place if `name` is already
    /// bound. Update-in-place is what makes `def` idempotent at the
    /// REPL — repeated `(def x ...)` shouldn't churn references.
    pub fn intern(self: *Env, ns: *Namespace, name: []const u8, root: Value) !*Var {
        if (ns.mappings.get(name)) |existing| {
            existing.root = root;
            return existing;
        }
        const owned_name = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(owned_name);
        const v = try self.alloc.create(Var);
        errdefer self.alloc.destroy(v);
        v.* = .{ .ns = ns, .name = owned_name, .root = root };
        try ns.mappings.put(self.alloc, owned_name, v);
        return v;
    }
};

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
    const v = try env.intern(user, "x", .true_val);
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
    const v1 = try env.intern(user, "x", .nil_val);
    const v2 = try env.intern(user, "x", .true_val);
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
    _ = try env.intern(user, "y", .true_val);
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
    const v = try env.intern(user, "x", .true_val);
    try testing.expectEqual(Value.true_val, v.deref());
}

test "Var.deref respects dynamic binding stack on dynamic Vars" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const user = env.findNs("user").?;
    const v = try env.intern(user, "*x*", .nil_val);
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
    const v = try env.intern(user, "x", .nil_val);
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
    const v = try env.intern(user, "*x*", .nil_val);
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
    _ = try env.intern(rt_ns, "+", .true_val);

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

test "Two Envs sharing a Runtime have isolated namespaces" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env1 = try Env.init(&fix.rt);
    defer env1.deinit();
    var env2 = try Env.init(&fix.rt);
    defer env2.deinit();

    const user1 = env1.findNs("user").?;
    _ = try env1.intern(user1, "x", .true_val);

    const user2 = env2.findNs("user").?;
    try testing.expect(user2.resolve("x") == null);
}

test "VarFlags packs into one byte" {
    try testing.expectEqual(@as(usize, 1), @sizeOf(VarFlags));
}
