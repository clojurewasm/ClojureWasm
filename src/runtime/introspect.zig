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
/// completion annotation (`type` in the completions op reply; the wire
/// strings match cider-completion.el's annotation alist: `<s>` for
/// special-form, `<c>` class, `<sf>`/`<sm>` static members, …).
pub const Kind = enum {
    function,
    macro,
    variable,
    namespace,
    special_form,
    class,
    static_field,
    static_method,
    keyword,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .function => "function",
            .macro => "macro",
            .variable => "var",
            .namespace => "namespace",
            .special_form => "special-form",
            .class => "class",
            .static_field => "static-field",
            .static_method => "static-method",
            .keyword => "keyword",
        };
    }
};

/// nREPL util.completion `fuzzy-matches?`: `prefix` matches `symbol`
/// when prefix's separator-split parts prefix-match symbol's parts in
/// order (`m-i` → `map-indexed` with `-`; `clo.str` → `clojure.string`
/// with `.`). The first character must match exactly; an empty prefix
/// matches everything.
pub fn fuzzyMatches(prefix: []const u8, symbol: []const u8, separator: u8) bool {
    if (prefix.len == 0) return true;
    if (symbol.len == 0) return false;
    if (prefix[0] != symbol[0]) return false;
    var pi: usize = 1;
    var si: usize = 1;
    var skipping = false;
    while (true) {
        if (pi >= prefix.len) return true;
        if (si >= symbol.len) return false;
        const pc = prefix[pi];
        const sc = symbol[si];
        const match = pc == sc;
        if (sc == separator) {
            if (match) pi += 1;
            si += 1;
            skipping = false;
        } else if (skipping or !match) {
            si += 1;
            skipping = true;
        } else {
            pi += 1;
            si += 1;
            skipping = false;
        }
    }
}

/// nREPL util.completion `camel-case-matches?` (`fuzzy-matches-no-skip?`
/// over an uppercase-letter separator): `getDeF` → `getDeclaredFields`.
/// Used for Java member prefixes that contain an uppercase letter.
pub fn camelCaseMatches(prefix: []const u8, member: []const u8) bool {
    if (prefix.len == 0) return true;
    if (member.len == 0) return false;
    if (prefix[0] != member[0]) return false;
    var pi: usize = 1;
    var si: usize = 1;
    var skipping = false;
    while (true) {
        if (pi >= prefix.len) return true;
        if (si >= member.len) return false;
        if (skipping) {
            if (member[si] >= 'A' and member[si] <= 'Z') {
                skipping = false;
            } else {
                si += 1;
            }
        } else if (prefix[pi] == member[si]) {
            pi += 1;
            si += 1;
        } else {
            si += 1;
            skipping = true;
        }
    }
}

/// The Java member matcher: camelCase-aware when the prefix carries an
/// uppercase hump, plain prefix match otherwise (the nREPL built-in's
/// `inparts?` split).
fn memberMatches(prefix: []const u8, member: []const u8) bool {
    for (prefix) |c| {
        if (c >= 'A' and c <= 'Z') return camelCaseMatches(prefix, member);
    }
    return std.mem.startsWith(u8, member, prefix);
}

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

fn emitVarMap(map: *const env_mod.VarMap, prefix: []const u8, include_private: bool, ctx: anytype, comptime cb: fn (@TypeOf(ctx), Candidate) bool) bool {
    var it = map.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!fuzzyMatches(prefix, name, '-')) continue;
        const v = entry.value_ptr.*;
        if (v.flags.private and !include_private) continue;
        if (!cb(ctx, .{ .name = name, .ns = v.ns.name, .kind = varKind(v) })) return false;
    }
    return true;
}

/// The fixed special-form completion set — the nREPL built-in's
/// `special-forms` + the `true`/`false`/`nil` literals, all typed
/// "special-form" (nrepl/util/completion.clj; compliment's
/// sources/special_forms.clj is the upstream of that list).
const SPECIAL_FORM_CANDIDATES = [_][]const u8{
    "def",          "if",    "do",   "quote", "var",
    "recur",        "throw", "try",  "catch", "monitor-enter",
    "monitor-exit", "new",   "set!", "true",  "false",
    "nil",
};

/// Emit the special-form / literal candidates matching `prefix`
/// (dash-fuzzy, like vars — the built-in uses one matcher for both).
pub fn forEachSpecialForm(prefix: []const u8, ctx: anytype, comptime cb: fn (@TypeOf(ctx), Candidate) bool) void {
    for (SPECIAL_FORM_CANDIDATES) |form| {
        if (!fuzzyMatches(prefix, form, '-')) continue;
        if (!cb(ctx, .{ .name = form, .ns = null, .kind = .special_form })) return;
    }
}

/// Enumerate the candidates an UNQUALIFIED `prefix` can complete to,
/// as seen from `context_ns` (may be null): the ns's own mappings +
/// refers + aliases, `clojure.core`'s mappings + refers, and full
/// namespace names. Vars match dash-fuzzy, namespaces dot-fuzzy (the
/// nREPL built-in's matchers). The callback returns `false` to stop
/// (cap reached). Mirrors the resolution surface `Namespace.resolve` +
/// the analyzer's symbol lookup actually search, so completion never
/// offers a symbol that would not resolve. Private vars are offered
/// only for the context ns's own interns (a cross-ns private neither
/// resolves nor completes — clj parity).
pub fn forEachUnqualified(env: *Env, context_ns: ?*Namespace, prefix: []const u8, ctx: anytype, comptime cb: fn (@TypeOf(ctx), Candidate) bool) void {
    if (context_ns) |ns| {
        if (!emitVarMap(&ns.mappings, prefix, true, ctx, cb)) return;
        if (!emitVarMap(&ns.refers, prefix, false, ctx, cb)) return;
        var al_it = ns.aliases.iterator();
        while (al_it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (!fuzzyMatches(prefix, name, '.')) continue;
            if (!cb(ctx, .{ .name = name, .ns = null, .kind = .namespace })) return;
        }
    }
    // clojure.core is visible from every ns (the analyzer's fallback) —
    // skip when it IS the context to avoid re-walking the same maps.
    if (env.findNs("clojure.core")) |core| {
        if (context_ns == null or context_ns.? != core) {
            if (!emitVarMap(&core.mappings, prefix, false, ctx, cb)) return;
            if (!emitVarMap(&core.refers, prefix, false, ctx, cb)) return;
        }
    }
    var ns_it = env.namespaces.iterator();
    while (ns_it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!fuzzyMatches(prefix, name, '.')) continue;
        if (!cb(ctx, .{ .name = name, .ns = null, .kind = .namespace })) return;
    }
}

/// Emit host-class candidates matching `prefix` (dot-fuzzy, like the
/// nREPL built-in's `nscl-matches?`) from the `rt.types` closed set —
/// cljw's class universe IS this registry, so completion offers exactly
/// what `resolveJavaSurface` resolves (no classpath scan, none of the
/// JVM-internal `CharacterDataXX` leak mainline shows — the AD-054
/// side of the completion-parity fixtures). Per key it offers the
/// JVM-visible FQN (`java.lang.Character`) and, when the key is
/// bare-reachable (java.lang/java.math defaults, a `(:import …)`
/// entry), the simple name. deftype/defrecord descriptors complete by
/// their registered name; anonymous reify descriptors are skipped.
pub fn forEachClass(rt_ptr: anytype, context_ns: ?*Namespace, prefix: []const u8, ctx: anytype, comptime cb: fn (@TypeOf(ctx), Candidate) bool) void {
    var it = rt_ptr.types.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const td = entry.value_ptr.*;
        switch (td.kind) {
            .reify_anon => continue,
            .deftype, .defrecord => {
                if (fuzzyMatches(prefix, key, '.')) {
                    if (!cb(ctx, .{ .name = key, .ns = null, .kind = .class })) return;
                }
                continue;
            },
            .native => {},
        }
        // Registry keys ARE the JVM-visible FQCNs (ADR-0174) — no translation.
        const display = key;
        const simple = if (std.mem.findScalarLast(u8, display, '.')) |dot| display[dot + 1 ..] else display;
        // FQN candidate: matched by the FQN (dot-fuzzy) OR by the bare
        // short name — the built-in's short-name→FQN index (`Character`
        // offers `java.lang.Character`).
        if (fuzzyMatches(prefix, display, '.') or
            (std.mem.findScalar(u8, prefix, '.') == null and fuzzyMatches(prefix, simple, '-')))
        {
            if (!cb(ctx, .{ .name = display, .ns = null, .kind = .class })) return;
        }
        if (host_class_resolve.bareName(context_ns, key)) |bare| {
            if (fuzzyMatches(prefix, bare, '.')) {
                if (!cb(ctx, .{ .name = bare, .ns = null, .kind = .class })) return;
            }
        }
    }
}

/// Emit the static members of `class_head` (a `Class/member` prefix's
/// class half) matching `member_prefix`: `static_fields` as
/// static-field, the host surface's `method_table` as static-method
/// (instance methods live on the per-tag native descriptors, not
/// here). Member matching is camelCase-aware (`isD` → `isDigit`).
/// The candidate name is the bare member; the caller re-assembles the
/// `Class/member` completion text (the qualified-collector shape).
pub fn forEachStaticMember(rt_ptr: anytype, context_ns: ?*Namespace, class_head: []const u8, member_prefix: []const u8, ctx: anytype, comptime cb: fn (@TypeOf(ctx), Candidate) bool) void {
    const td = host_class_resolve.resolve(rt_ptr, context_ns, class_head) orelse return;
    if (td.kind != .native) return;
    for (td.static_fields) |sf| {
        if (!memberMatches(member_prefix, sf.name)) continue;
        if (!cb(ctx, .{ .name = sf.name, .ns = null, .kind = .static_field })) return;
    }
    for (td.method_table) |me| {
        if (!memberMatches(member_prefix, me.method_name)) continue;
        if (!cb(ctx, .{ .name = me.method_name, .ns = null, .kind = .static_method })) return;
    }
}

/// Emit interned-keyword candidates for a `:`-prefixed completion
/// (`prefix_after_colon` excludes the colon). The keyword interner is
/// process-unique, so — like the JVM's Keyword table the built-in
/// reflects over — this offers every keyword the program has interned
/// so far. Candidate names carry the leading `:`.
pub fn forEachKeyword(rt_ptr: anytype, allocator: std.mem.Allocator, prefix_after_colon: []const u8, ctx: anytype, comptime cb: fn (@TypeOf(ctx), Candidate) bool) void {
    for (rt_ptr.keywords.table.keys()) |key| {
        if (!std.mem.startsWith(u8, key, prefix_after_colon)) continue;
        const text = std.fmt.allocPrint(allocator, ":{s}", .{key}) catch return;
        if (!cb(ctx, .{ .name = text, .ns = null, .kind = .keyword })) return;
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

/// Enumerate var candidates inside `target` matching `var_prefix` (the
/// `jo` of `str/jo`; dash-fuzzy). Qualified access excludes privates —
/// mainline's scoped completion walks `ns-publics` (`cljw.internal` is
/// all-public by design, so its helpers stay reachable here).
pub fn forEachNsVar(target: *const Namespace, var_prefix: []const u8, ctx: anytype, comptime cb: fn (@TypeOf(ctx), Candidate) bool) void {
    _ = emitVarMap(&target.mappings, var_prefix, false, ctx, cb);
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
const host_class_resolve = @import("host_class_resolve.zig");

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

test "fuzzyMatches: the nREPL built-in's dash/dot part matcher" {
    try testing.expect(fuzzyMatches("m-i", "map-indexed", '-'));
    try testing.expect(fuzzyMatches("ma-i", "map-indexed", '-'));
    try testing.expect(fuzzyMatches("map", "map-indexed", '-'));
    try testing.expect(!fuzzyMatches("i-m", "map-indexed", '-'));
    try testing.expect(!fuzzyMatches("mx", "map-indexed", '-'));
    try testing.expect(fuzzyMatches("clo.str", "clojure.string", '.'));
    try testing.expect(fuzzyMatches("c.s", "clojure.string", '.'));
    try testing.expect(!fuzzyMatches("x.s", "clojure.string", '.'));
    try testing.expect(fuzzyMatches("", "anything", '-'));
}

test "camelCaseMatches: the Java member hump matcher" {
    try testing.expect(camelCaseMatches("isD", "isDigit"));
    try testing.expect(camelCaseMatches("isD", "isLetterOrDigit"));
    try testing.expect(camelCaseMatches("getDeF", "getDeclaredFields"));
    try testing.expect(!camelCaseMatches("isZ", "isDigit"));
    try testing.expect(!camelCaseMatches("xsD", "isDigit"));
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
