// SPDX-License-Identifier: EPL-2.0
//! Env introspection shared by every completion / lookup surface
//! (ADR-0170): the CLI line editor's TAB completion, the nREPL
//! `completions` / `lookup` / `info` / `eldoc` ops, and a future
//! `--list-vars`. Same-layer module (walks Env / Namespace / Var
//! only), so both app-layer consumers and a future Layer-2 surface
//! can reach it.
//!
//! Enumeration is visitor-shaped (`forEach*` + callback) so the
//! allocation policy stays with the caller: the raw-terminal line
//! editor fills a fixed 64-slot array with zero allocation; the
//! nREPL op accumulates into an arena list. Candidate names are
//! Env-owned slices (they live as long as the Env) — no copies are
//! made here. De-duplication (a name reachable via both `mappings`
//! and `refers`, e.g. the core refers) is the caller's concern; the
//! visitor never tracks a seen-set so it stays allocation-free.

const std = @import("std");
const env_mod = @import("env.zig");
const Env = env_mod.Env;
const Namespace = env_mod.Namespace;
const Var = env_mod.Var;
const Value = @import("value/value.zig").Value;

/// What a completion candidate names — CIDER renders this as the
/// completion annotation (`type` in the completions op reply).
pub const Kind = enum {
    function,
    macro,
    variable,
    namespace,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .function => "function",
            .macro => "macro",
            .variable => "var",
            .namespace => "namespace",
        };
    }
};

pub const Candidate = struct {
    /// Bare name (var name / alias / namespace name). For a qualified
    /// query (`str/jo`) this is the var name only — the caller owns
    /// re-assembling the `alias/name` completion text.
    name: []const u8,
    /// Home namespace name for var candidates, null for ns/alias ones.
    ns: ?[]const u8,
    kind: Kind,
};

/// Classify a Var for completion / lookup annotation.
pub fn varKind(v: *const Var) Kind {
    if (v.flags.macro_) return .macro;
    return switch (v.root.tag()) {
        .fn_val, .builtin_fn => .function,
        else => .variable,
    };
}

fn emitVarMap(map: *const env_mod.VarMap, prefix: []const u8, ctx: anytype, comptime cb: fn (@TypeOf(ctx), Candidate) bool) bool {
    var it = map.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        const v = entry.value_ptr.*;
        if (!cb(ctx, .{ .name = name, .ns = v.ns.name, .kind = varKind(v) })) return false;
    }
    return true;
}

/// Enumerate the candidates an UNQUALIFIED `prefix` can complete to,
/// as seen from `context_ns` (may be null): the ns's own mappings +
/// refers + aliases, `clojure.core`'s mappings + refers, and full
/// namespace names. The callback returns `false` to stop (cap
/// reached). Mirrors the resolution surface `Namespace.resolve` +
/// the analyzer's symbol lookup actually search, so completion never
/// offers a symbol that would not resolve.
pub fn forEachUnqualified(env: *Env, context_ns: ?*Namespace, prefix: []const u8, ctx: anytype, comptime cb: fn (@TypeOf(ctx), Candidate) bool) void {
    if (context_ns) |ns| {
        if (!emitVarMap(&ns.mappings, prefix, ctx, cb)) return;
        if (!emitVarMap(&ns.refers, prefix, ctx, cb)) return;
        var al_it = ns.aliases.iterator();
        while (al_it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            if (!cb(ctx, .{ .name = name, .ns = null, .kind = .namespace })) return;
        }
    }
    // clojure.core is visible from every ns (bootstrap refers) — skip
    // when it IS the context to avoid re-walking the same maps.
    if (env.findNs("clojure.core")) |core| {
        if (context_ns == null or context_ns.? != core) {
            if (!emitVarMap(&core.mappings, prefix, ctx, cb)) return;
            if (!emitVarMap(&core.refers, prefix, ctx, cb)) return;
        }
    }
    var ns_it = env.namespaces.iterator();
    while (ns_it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        if (!cb(ctx, .{ .name = name, .ns = null, .kind = .namespace })) return;
    }
}

/// Resolve the `ns` half of a qualified `alias-or-ns/name` query:
/// context aliases first, then real namespace names — the same order
/// qualified symbol resolution uses.
pub fn resolveQualifier(env: *Env, context_ns: ?*Namespace, alias_or_ns: []const u8) ?*Namespace {
    if (context_ns) |ns| {
        if (ns.aliases.get(alias_or_ns)) |target| return target;
    }
    return env.findNs(alias_or_ns);
}

/// Enumerate var candidates inside `target` whose name starts with
/// `var_prefix` (the `jo` of `str/jo`).
pub fn forEachNsVar(target: *const Namespace, var_prefix: []const u8, ctx: anytype, comptime cb: fn (@TypeOf(ctx), Candidate) bool) void {
    _ = emitVarMap(&target.mappings, var_prefix, ctx, cb);
}

/// Resolve `sym` ("name" or "ns-or-alias/name") to its Var as seen
/// from `context_ns` — the lookup/info/eldoc ops' resolution. Returns
/// null when the symbol does not name a Var (the op replies its miss
/// status, e.g. `no-eldoc`).
pub fn lookupVar(env: *Env, context_ns: ?*Namespace, sym: []const u8) ?*Var {
    if (std.mem.findScalar(u8, sym, '/')) |slash| {
        if (slash == 0 or slash + 1 >= sym.len) return null;
        const target = resolveQualifier(env, context_ns, sym[0..slash]) orelse return null;
        return target.resolveQualified(sym[slash + 1 ..]);
    }
    if (context_ns) |ns| {
        if (ns.resolve(sym)) |v| return v;
    }
    if (env.findNs("clojure.core")) |core| {
        if (core.resolve(sym)) |v| return v;
    }
    return null;
}

/// Read a Var's docstring: the Zig-intern `doc` field, else the `.clj`
/// def's `^{:doc …}` meta map entry (a string Value).
pub fn varDoc(v: *const Var) ?[]const u8 {
    if (v.doc) |d| return d;
    const meta_v = metaGet(v.meta, "doc") orelse return null;
    if (meta_v.tag() != .string) return null;
    return string_mod.asString(meta_v);
}

/// A Var's `:arglists` as a Value (a list of vectors) from the def
/// meta, or null. Zig-intern Vars carry only the pre-rendered
/// `arglists` STRING field — callers wanting a display string should
/// try `v.arglists` first, then print this Value.
pub fn varArglistsValue(v: *const Var) ?Value {
    return metaGet(v.meta, "arglists");
}

/// Get a meta-map entry by keyword NAME (`"doc"`, `"arglists"`)
/// without allocating a keyword Value (keyword keys expose `.name`;
/// the map is walked, not hashed).
pub fn metaGet(meta_v: ?Value, name: []const u8) ?Value {
    const m = meta_v orelse return null;
    switch (m.tag()) {
        .array_map, .hash_map => {},
        else => return null,
    }
    var finder: MetaFinder = .{ .want = name };
    map_mod.forEachEntry(m, &finder, MetaFinder.cb) catch {};
    return finder.found;
}

const MetaFinder = struct {
    want: []const u8,
    found: ?Value = null,

    fn cb(self: *MetaFinder, k: Value, v: Value) anyerror!void {
        if (k.tag() != .keyword) return;
        if (std.mem.eql(u8, keyword_mod.asKeyword(k).name, self.want)) self.found = v;
    }
};

const map_mod = @import("collection/map.zig");
const keyword_mod = @import("keyword.zig");
const string_mod = @import("collection/string.zig");

// --- tests ---

const testing = std.testing;
const Runtime = @import("runtime.zig").Runtime;

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

const TestSink = struct {
    names: [128][]const u8 = undefined,
    kinds: [128]Kind = undefined,
    count: usize = 0,

    fn cb(self: *TestSink, c: Candidate) bool {
        if (self.count >= self.names.len) return false;
        // consumer-side dedup, as documented in the module header
        for (self.names[0..self.count]) |n| if (std.mem.eql(u8, n, c.name)) return true;
        self.names[self.count] = c.name;
        self.kinds[self.count] = c.kind;
        self.count += 1;
        return true;
    }

    fn has(self: *const TestSink, name: []const u8) bool {
        for (self.names[0..self.count]) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }
};

test "forEachUnqualified surfaces interned vars + namespace names, prefix-filtered" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();
    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const core = try env.findOrCreateNs("clojure.core");
    _ = try env.intern(core, "probe-alpha", Value.nil_val, null);
    _ = try env.intern(core, "probe-beta", Value.nil_val, null);
    _ = try env.intern(core, "other", Value.nil_val, null);
    _ = try env.findOrCreateNs("probe.nsname");

    var sink = TestSink{};
    forEachUnqualified(&env, null, "probe", &sink, TestSink.cb);
    try testing.expect(sink.has("probe-alpha"));
    try testing.expect(sink.has("probe-beta"));
    try testing.expect(sink.has("probe.nsname"));
    try testing.expect(!sink.has("other"));
}

test "varKind classifies macro flag over value tag" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();
    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const ns = try env.findOrCreateNs("k.ns");
    const plain = try env.intern(ns, "plain", Value.nil_val, null);
    try testing.expectEqual(Kind.variable, varKind(plain));
    const mac = try env.intern(ns, "mac", Value.nil_val, null);
    mac.flags.macro_ = true;
    try testing.expectEqual(Kind.macro, varKind(mac));
}

test "lookupVar resolves unqualified via context then core; misses return null" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();
    var env = try Env.init(&fix.rt);
    defer env.deinit();

    const core = try env.findOrCreateNs("clojure.core");
    const v = try env.intern(core, "lk-probe", Value.nil_val, null);
    const user = try env.findOrCreateNs("user");
    try testing.expectEqual(v, lookupVar(&env, user, "lk-probe").?);
    try testing.expectEqual(v, lookupVar(&env, user, "clojure.core/lk-probe").?);
    try testing.expectEqual(@as(?*Var, null), lookupVar(&env, user, "no-such-lk"));
    try testing.expectEqual(@as(?*Var, null), lookupVar(&env, user, "no.such.ns/x"));
    try testing.expectEqual(@as(?*Var, null), lookupVar(&env, user, "/"));
}
