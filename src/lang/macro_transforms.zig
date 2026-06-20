//! Zig-level Form→Form transforms for the bootstrap macros.
//!
//! The `BOOTSTRAP` table maps each bootstrap macro name (binding /
//! flow-control / threading sugar through `defn` / `defprotocol` /
//! `defrecord` / `deftype` / `reify` / sequence comprehensions) to a
//! Zig function whose signature matches
//! `eval/macro_dispatch.zig::ZigExpandFn`. At startup `registerInto`
//! interns each name as a Var in the `rt` namespace with
//! `flags.macro_ = true`, refers them into `user`, and inserts the
//! transform into the analyzer's `MacroTable`. The table itself is
//! the authoritative inventory; consult it rather than this doc.
//!
//! ### Why Form→Form
//!
//! ADR 0001: macros operate on Forms (the analyzer's input AST), not
//! on Values. That keeps source-location attribution intact through
//! expansion and avoids any heap allocation for the static cases
//! (Zig transforms never traverse the runtime Value heap).
//!
//! ### Hygiene
//!
//! Auto-gensym is wired through `Runtime.gensym(arena, prefix)` —
//! see `runtime/runtime.zig`. The output names follow Clojure's
//! `<prefix>__<n>__auto__` convention so that the (eventual) user
//! `defmacro` path produces visually consistent symbols.

const std = @import("std");

const Form = @import("../eval/form.zig").Form;
const macro_dispatch = @import("../eval/macro_dispatch.zig");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../runtime/error/info.zig");
const error_catalog = @import("../runtime/error/catalog.zig");
const host_interface = @import("../runtime/host_interface.zig");
const SourceLocation = error_mod.SourceLocation;

pub const RegisterError = error{
    RtNamespaceMissing,
    UserNamespaceMissing,
    OutOfMemory,
};

/// Intern macro Vars in `rt`, refer into `user`, populate `table`
/// with the Zig transforms. Idempotent.
pub fn registerInto(env: *Env, table: *macro_dispatch.Table) !void {
    const rt_ns = env.findNs("rt") orelse return RegisterError.RtNamespaceMissing;
    const user_ns = env.findNs("user") orelse return RegisterError.UserNamespaceMissing;

    inline for (BOOTSTRAP) |entry| {
        const v = try env.intern(rt_ns, entry.name, .nil_val, null);
        v.flags.macro_ = true;
        try ensureRegistered(table, entry.name, entry.expand);
    }

    // ADR-0035 D9 (sub-cycle d): boot-time rt → user macro refer
    // mirrors the primitive-Var path so macros (`let`, `cond`, `->`,
    // ...) resolve unqualified at the REPL prompt. Per ADR-0035 the
    // `(ns ...)` macro does NOT auto-refer rt; macros stay rt-owned
    // and the user-ns convenience refer happens here at boot.
    try env.referAll(rt_ns, user_ns);
}

/// `register` asserts uniqueness; this wraps it so re-running
/// `registerInto` (e.g., after a clear in tests) is a no-op rather
/// than a debug-assert crash.
fn ensureRegistered(
    table: *macro_dispatch.Table,
    name: []const u8,
    expand: macro_dispatch.ZigExpandFn,
) !void {
    if (table.lookup(name) != null) return;
    try table.register(name, expand);
}

const Entry = struct {
    name: []const u8,
    expand: macro_dispatch.ZigExpandFn,
};

const BOOTSTRAP = [_]Entry{
    .{ .name = "let", .expand = expandLet },
    .{ .name = "loop", .expand = expandLoop },
    .{ .name = "when", .expand = expandWhen },
    .{ .name = "when-not", .expand = expandWhenNot },
    .{ .name = "cond", .expand = expandCond },
    .{ .name = "if-not", .expand = expandIfNot },
    .{ .name = "comment", .expand = expandComment },
    .{ .name = "assert", .expand = expandAssert },
    .{ .name = "lazy-cat", .expand = expandLazyCat },
    .{ .name = "..", .expand = expandDotDot },
    .{ .name = "->", .expand = expandThreadFirst },
    .{ .name = "->>", .expand = expandThreadLast },
    .{ .name = "as->", .expand = expandAsThread },
    .{ .name = "cond->", .expand = expandCondThreadFirst },
    .{ .name = "cond->>", .expand = expandCondThreadLast },
    .{ .name = "some->", .expand = expandSomeThreadFirst },
    .{ .name = "some->>", .expand = expandSomeThreadLast },
    .{ .name = "and", .expand = expandAnd },
    .{ .name = "or", .expand = expandOr },
    .{ .name = "if-let", .expand = expandIfLet },
    .{ .name = "when-let", .expand = expandWhenLet },
    .{ .name = "if-some", .expand = expandIfSome },
    .{ .name = "when-some", .expand = expandWhenSome },
    .{ .name = "doto", .expand = expandDoto },
    .{ .name = "dotimes", .expand = expandDotimes },
    .{ .name = "while", .expand = expandWhile },
    .{ .name = "when-first", .expand = expandWhenFirst },
    .{ .name = "doseq", .expand = expandDoseq },
    .{ .name = "for", .expand = expandFor },
    .{ .name = "case", .expand = expandCase },
    .{ .name = "condp", .expand = expandCondp },
    .{ .name = "fn", .expand = expandFn },
    .{ .name = "defn", .expand = expandDefn },
    .{ .name = "defn-", .expand = expandDefnPrivate },
    .{ .name = "declare", .expand = expandDeclare },
    .{ .name = "defonce", .expand = expandDefonce },
    .{ .name = "import", .expand = expandImport },
    .{ .name = "defmulti", .expand = expandDefmulti },
    .{ .name = "defmethod", .expand = expandDefmethod },
    .{ .name = "defprotocol", .expand = expandDefprotocol },
    .{ .name = "extend-type", .expand = expandExtendType },
    .{ .name = "extend-protocol", .expand = expandExtendProtocol },
    .{ .name = "defrecord", .expand = expandDefrecord },
    .{ .name = "deftype", .expand = expandDeftype },
    .{ .name = "reify", .expand = expandReify },
    .{ .name = "delay", .expand = expandDelay },
    .{ .name = "future", .expand = expandFuture },
    .{ .name = "dosync", .expand = expandDosync },
    .{ .name = "locking", .expand = expandLocking },
    .{ .name = "lazy-seq", .expand = expandLazySeq },
    .{ .name = "letfn", .expand = expandLetfn },
};

// --- Form-construction conveniences ---

const list = macro_dispatch.makeList;
const vec = macro_dispatch.makeVector;
const sym = macro_dispatch.makeSymbol;
const nilForm = macro_dispatch.makeNil;

/// Strip a `(quote X)` wrapper, returning `X`; otherwise the form unchanged.
/// `import` accepts quoted specs (`(import '(java.lang Boolean))`) and bare
/// ones (`(import java.util.Date)`) — both reduce to the same spec form.
fn unwrapQuote(form: Form) Form {
    if (form.data == .list) {
        const inner = form.data.list;
        if (inner.len == 2 and inner[0].data == .symbol and
            inner[0].data.symbol.ns == null and
            std.mem.eql(u8, inner[0].data.symbol.name, "quote"))
            return inner[1];
    }
    return form;
}

/// Build `(import* "fqcn")` — the runtime registration call.
fn importStarCall(arena: std.mem.Allocator, fqcn: []const u8, loc: SourceLocation) !Form {
    var call = try arena.alloc(Form, 2);
    call[0] = sym("import*", loc);
    call[1] = .{ .data = .{ .string = fqcn }, .location = loc };
    return list(arena, call, loc);
}

/// `(import & specs)` → `(do (import* "pkg.Class") …)`. Each spec is a
/// (optionally quoted) class symbol `pkg.Class` or a prefix list
/// `(pkg Class1 Class2 …)`. Mirrors clj's import → `clojure.core/import*`
/// expansion; the import* fn registers the simple-name → FQCN map (D-235).
fn expandImport(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    var items: std.ArrayList(Form) = .empty;
    try items.append(arena, sym("do", loc));
    for (args) |raw_spec| {
        const spec = unwrapQuote(raw_spec);
        switch (spec.data) {
            .symbol => |sy| {
                const fqcn = if (sy.ns) |p| try std.fmt.allocPrint(arena, "{s}.{s}", .{ p, sy.name }) else sy.name;
                try items.append(arena, try importStarCall(arena, fqcn, loc));
            },
            .list => |inner| {
                if (inner.len < 2 or inner[0].data != .symbol)
                    return error_catalog.raise(.feature_not_supported, spec.location, .{ .name = "import prefix form must be (package Class …)" });
                const pkg = inner[0].data.symbol.name;
                for (inner[1..]) |ce| {
                    if (ce.data != .symbol)
                        return error_catalog.raise(.feature_not_supported, ce.location, .{ .name = "import class entry must be a symbol" });
                    const fqcn = try std.fmt.allocPrint(arena, "{s}.{s}", .{ pkg, ce.data.symbol.name });
                    try items.append(arena, try importStarCall(arena, fqcn, loc));
                }
            },
            else => return error_catalog.raise(.feature_not_supported, spec.location, .{ .name = "import spec must be a symbol or (package Class …) list" }),
        }
    }
    return list(arena, items.items, loc);
}

/// `(defonce name expr)` → `(when-not (bound? (def name)) (def name expr))`:
/// define `name` only if not already bound (clj `.hasRoot`). The inner no-init
/// `(def name)` ENSURES the Var exists (unbound placeholder via internDeclare,
/// no-clobber if already defined) and returns it — mirroring clj's
/// `(let [v (def name)] (when-not (.hasRoot v) (def name expr)))`. `bound?`
/// checks `Var.bound` (false until a real init), so a fresh defonce runs and a
/// repeat skips; the analyze-time interning of `def` does not poison it.
fn expandDefonce(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len != 2 or args[0].data != .symbol)
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "defonce needs a symbol name and an init expr" });
    const name = args[0];
    var declform = try arena.alloc(Form, 2); // (def name)  — no-init, ensures existence
    declform[0] = sym("def", loc);
    declform[1] = name;
    var bform = try arena.alloc(Form, 2); // (bound? (def name))
    bform[0] = sym("bound?", loc);
    bform[1] = try list(arena, declform, loc);
    var dform = try arena.alloc(Form, 3); // (def name expr)
    dform[0] = sym("def", loc);
    dform[1] = name;
    dform[2] = args[1];
    var wform = try arena.alloc(Form, 3);
    wform[0] = sym("when-not", loc);
    wform[1] = try list(arena, bform, loc);
    wform[2] = try list(arena, dform, loc);
    return list(arena, wform, loc);
}

/// `(declare a b ...)` → `(do (def a) (def b) ...)`. Forward-declares
/// unbound vars. clj also tags each var `:declared true` via symbol meta;
/// cljw symbols are metadata-less (ADR-0037), so that marker is omitted
/// (accepted divergence) — the forward-declaration behaviour is identical.
/// A non-symbol name is left for `def` to reject (single error source).
fn expandDeclare(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    var items = try arena.alloc(Form, args.len + 1);
    items[0] = sym("do", loc);
    for (args, 0..) |name, i| {
        const def_items = try arena.alloc(Form, 2);
        def_items[0] = sym("def", loc);
        def_items[1] = name;
        items[i + 1] = try list(arena, def_items, loc);
    }
    return list(arena, items, loc);
}

// --- let — `let*` rename + destructuring lowering (D-076) ---
//
// Clojure's `let` adds destructuring on top of `let*`. Per the JVM
// `clojure.core/destructure` shape, patterns lower to plain-symbol
// `let*` bindings + `nth`/`nthnext` calls — but as a Layer-1 Form
// transform here (NOT a `.clj` macro: `let`/`fn` are already Zig macros,
// so a `.clj` destructure would hit bootstrap-order fragility).
// D-076: SEQUENTIAL vector patterns (`[a b]`, `[a b & rest]`,
// `[a b :as all]`, nested), associative `{:keys ...}` (see
// `associativeDestructure`), fn-param (`transformFnArity`), and
// `loop*` (`expandLoop`) destructuring are all supported.

fn expandLet(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    if (args.len < 2)
        return error_catalog.raise(.let_form_incomplete, loc, .{});
    if (args[0].data != .vector)
        return error_catalog.raise(.bindings_not_vector, args[0].location, .{ .form = "let" });

    const binds = args[0].data.vector;

    // Fast path: every binding target is already a plain symbol AND the
    // vector is well-formed (even) — keep the trivial `let` → `let*`
    // rename so non-destructuring code is byte-for-byte unchanged (zero
    // regression) and `let*` keeps ownership of the odd-bindings error.
    const needs_destructure = blk: {
        if (binds.len % 2 != 0) break :blk false;
        var k: usize = 0;
        while (k < binds.len) : (k += 2) {
            if (binds[k].data != .symbol) break :blk true;
        }
        break :blk false;
    };
    if (!needs_destructure) {
        var items = try arena.alloc(Form, args.len + 1);
        items[0] = sym("let*", loc);
        @memcpy(items[1..], args);
        return list(arena, items, loc);
    }

    // Destructure path: lower every pattern into plain-symbol bindings.
    var out: std.ArrayList(Form) = .empty;
    var k: usize = 0;
    while (k < binds.len) : (k += 2) {
        try destructureInto(&out, arena, rt, binds[k], binds[k + 1], loc);
    }
    const new_binds = try vec(arena, out.items, loc);

    var items = try arena.alloc(Form, args.len + 1);
    items[0] = sym("let*", loc);
    items[1] = new_binds;
    @memcpy(items[2..], args[1..]);
    return list(arena, items, loc);
}

/// Append flat `let*` bindings (`[name, value, ...]`) that bind `pat` to
/// `value_form`. Recursive for nested vector patterns. Dispatches
/// symbol, sequential-vector, and associative `{...}` (the latter via
/// `associativeDestructure`).
fn destructureInto(
    out: *std.ArrayList(Form),
    arena: std.mem.Allocator,
    rt: *Runtime,
    pat: Form,
    value_form: Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!void {
    switch (pat.data) {
        .symbol => {
            try out.append(arena, pat);
            try out.append(arena, value_form);
        },
        .vector => |elems| try sequentialDestructure(out, arena, rt, elems, value_form, loc),
        .map => |pairs| try associativeDestructure(out, arena, rt, pairs, value_form, loc),
        else => return error_catalog.raise(.binding_name_not_symbol, pat.location, .{ .form = "let" }),
    }
}

/// `[a b & rest :as all]` lowering: bind `value_form` once to a gensym,
/// then each positional element to `(nth g i nil)`, `& rest` to
/// `(nthnext g i)`, `:as all` to the gensym. Recurses for nested elems.
fn sequentialDestructure(
    out: *std.ArrayList(Form),
    arena: std.mem.Allocator,
    rt: *Runtime,
    elems: []const Form,
    value_form: Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!void {
    const g = sym(try rt.gensym(arena, "vec"), loc);
    try out.append(arena, g);
    try out.append(arena, value_form);

    var idx: i64 = 0;
    var i: usize = 0;
    while (i < elems.len) : (i += 1) {
        const e = elems[i];
        if (e.data == .symbol and e.data.symbol.ns == null and std.mem.eql(u8, e.data.symbol.name, "&")) {
            if (i + 1 >= elems.len)
                return error_catalog.raise(.feature_not_supported, loc, .{ .name = "destructuring `&` with no rest binding" });
            const rest_val = try makeCall(arena, "nthnext", &.{ g, intForm(idx, loc) }, loc);
            try destructureInto(out, arena, rt, elems[i + 1], rest_val, loc);
            i += 1;
            continue;
        }
        if (e.data == .keyword and e.data.keyword.ns == null and std.mem.eql(u8, e.data.keyword.name, "as")) {
            if (i + 1 >= elems.len or elems[i + 1].data != .symbol)
                return error_catalog.raise(.feature_not_supported, loc, .{ .name = "destructuring `:as` without a symbol binding" });
            try out.append(arena, elems[i + 1]);
            try out.append(arena, g);
            i += 1;
            continue;
        }
        const nth_val = try makeCall(arena, "nth", &.{ g, intForm(idx, loc), nilForm(loc) }, loc);
        try destructureInto(out, arena, rt, e, nth_val, loc);
        idx += 1;
    }
}

/// `{:keys [x y] :strs [s] :syms [q] :or {x 0} :as m, local kexpr}`
/// lowering: bind `value_form` once to a gensym, then each name to
/// `(get g <key> <default>)`. `:keys`→keyword key, `:strs`→string key,
/// `:syms`→quoted-symbol key; bare `{local kexpr}`→`(get g kexpr)` with
/// `local` recursable (nested); `:or` supplies the 3rd `get` arg keyed
/// by binding-symbol name; `:as`→the gensym. D-076 cycle 2.
fn associativeDestructure(
    out: *std.ArrayList(Form),
    arena: std.mem.Allocator,
    rt: *Runtime,
    pairs: []const Form,
    value_form: Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!void {
    const g = sym(try rt.gensym(arena, "map"), loc);
    try out.append(arena, g);
    try out.append(arena, value_form);
    // Map-destructuring of a SEQ operand (the kwargs idiom `& {:keys [...]}`,
    // where the rest args arrive as a seq) coerces it to a map so the
    // `(get g key)` lookups hit — mirrors Clojure's
    // `(if (seq? g) (apply hash-map g) g)`. value_form is evaluated once
    // (bound above); rebinding g in the same let* shadows the raw value.
    try out.append(arena, g);
    try out.append(arena, try makeCall(arena, "if", &.{
        try makeCall(arena, "seq?", &.{g}, loc),
        try makeCall(arena, "apply", &.{ sym("hash-map", loc), g }, loc),
        g,
    }, loc));

    // Pass 1: locate `:or` (a `{sym default}` map) so its defaults are
    // available regardless of key order.
    var or_pairs: ?[]const Form = null;
    var i: usize = 0;
    while (i + 1 < pairs.len) : (i += 2) {
        const k = pairs[i];
        if (k.data == .keyword and k.data.keyword.ns == null and std.mem.eql(u8, k.data.keyword.name, "or")) {
            if (pairs[i + 1].data != .map)
                return error_catalog.raise(.feature_not_supported, loc, .{ .name = "destructuring `:or` value must be a map" });
            or_pairs = pairs[i + 1].data.map;
        }
    }

    // Pass 2: emit bindings for each directive / bare entry.
    i = 0;
    while (i + 1 < pairs.len) : (i += 2) {
        const k = pairs[i];
        const v = pairs[i + 1];
        // Namespaced directive `:ns/keys` / `:ns/syms` (`{:a/keys [b c]}` ≡
        // `{:keys [:a/b :a/c]}`, clj parity): the directive's namespace becomes
        // each plain-symbol entry's key namespace.
        if (k.data == .keyword and k.data.keyword.ns != null and
            (std.mem.eql(u8, k.data.keyword.name, "keys") or std.mem.eql(u8, k.data.keyword.name, "syms")))
        {
            const dir_ns = k.data.keyword.ns.?;
            const is_keys = std.mem.eql(u8, k.data.keyword.name, "keys");
            if (v.data != .vector)
                return error_catalog.raise(.feature_not_supported, loc, .{ .name = "destructuring `:ns/keys`/`:ns/syms` needs a symbol vector" });
            for (v.data.vector) |s| {
                if (s.data != .symbol)
                    return error_catalog.raise(.feature_not_supported, loc, .{ .name = "destructuring `:ns/keys`/`:ns/syms` entries must be symbols" });
                const nm = s.data.symbol.name;
                const local: Form = .{ .data = .{ .symbol = .{ .ns = null, .name = nm } }, .location = loc };
                const key_form: Form = if (is_keys)
                    .{ .data = .{ .keyword = .{ .ns = dir_ns, .name = nm } }, .location = loc }
                else
                    try makeCall(arena, "quote", &.{.{ .data = .{ .symbol = .{ .ns = dir_ns, .name = nm } }, .location = loc }}, loc);
                try out.append(arena, local);
                try out.append(arena, try makeGet(arena, g, key_form, findOrDefault(or_pairs, nm), loc));
            }
            continue;
        }
        if (k.data == .keyword and k.data.keyword.ns == null) {
            const kn = k.data.keyword.name;
            if (std.mem.eql(u8, kn, "or")) continue;
            if (std.mem.eql(u8, kn, "as")) {
                if (v.data != .symbol)
                    return error_catalog.raise(.feature_not_supported, loc, .{ .name = "destructuring `:as` without a symbol binding" });
                try out.append(arena, v);
                try out.append(arena, g);
                continue;
            }
            if (std.mem.eql(u8, kn, "keys") or std.mem.eql(u8, kn, "strs") or std.mem.eql(u8, kn, "syms")) {
                if (v.data != .vector)
                    return error_catalog.raise(.feature_not_supported, loc, .{ .name = "destructuring `:keys`/`:strs`/`:syms` needs a symbol vector" });
                for (v.data.vector) |s| {
                    // An entry is a symbol OR (for :keys) a keyword — clj allows
                    // `{:keys [:a :b]}` / `{:keys [:a/b]}` (keyword entries) as
                    // well as `{:keys [a b]}`. Extract (ns, name) from either.
                    // An auto-resolved keyword entry (`::foo` / `::alias/foo`) carries
                    // `auto_resolve` — the reader is ns-unaware, so the analyzer resolves
                    // it. Propagate the flag to the :keys key below, else the key looks up
                    // the bare `:foo` instead of `:current-ns/foo` (clojure.spec's
                    // `{:keys [::cpred]}` opts pattern needs this).
                    const sym_ns: ?[]const u8, const nm: []const u8, const auto_res: bool = switch (s.data) {
                        .symbol => |sy| .{ sy.ns, sy.name, false },
                        .keyword => |kw| .{ kw.ns, kw.name, kw.auto_resolve },
                        else => return error_catalog.raise(.feature_not_supported, loc, .{ .name = "destructuring `:keys`/`:strs`/`:syms` entries must be symbols or keywords" }),
                    };
                    // A namespaced entry `a/b` binds the LOCAL `b` (the name
                    // part) to the namespaced KEY (`:a/b` for :keys, `"a/b"`
                    // for :strs, `'a/b` for :syms) — clj parity. Plain `b`
                    // keeps the un-namespaced key.
                    const local: Form = .{ .data = .{ .symbol = .{ .ns = null, .name = nm } }, .location = loc };
                    const key_form: Form = if (std.mem.eql(u8, kn, "keys"))
                        .{ .data = .{ .keyword = .{ .ns = sym_ns, .name = nm, .auto_resolve = auto_res } }, .location = loc }
                    else if (std.mem.eql(u8, kn, "strs"))
                        .{ .data = .{ .string = if (sym_ns) |ns_| try std.fmt.allocPrint(arena, "{s}/{s}", .{ ns_, nm }) else nm }, .location = loc }
                    else
                        try makeCall(arena, "quote", &.{.{ .data = .{ .symbol = .{ .ns = sym_ns, .name = nm } }, .location = loc }}, loc);
                    try out.append(arena, local);
                    try out.append(arena, try makeGet(arena, g, key_form, findOrDefault(or_pairs, nm), loc));
                }
                continue;
            }
            return error_catalog.raise(.feature_not_supported, loc, .{ .name = "unsupported map-destructuring directive keyword" });
        }
        // Bare `{local kexpr}`: bind `local` (recursable) to `(get g kexpr <default>)`.
        const default_form: ?Form = if (k.data == .symbol) findOrDefault(or_pairs, k.data.symbol.name) else null;
        try destructureInto(out, arena, rt, k, try makeGet(arena, g, v, default_form, loc), loc);
    }
}

/// `(get g key)` or `(get g key default)` when `default` is non-null.
fn makeGet(
    arena: std.mem.Allocator,
    g: Form,
    key: Form,
    default: ?Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    if (default) |d| return makeCall(arena, "get", &.{ g, key, d }, loc);
    return makeCall(arena, "get", &.{ g, key }, loc);
}

/// Look up a binding symbol's `:or` default by name. `null` if absent.
fn findOrDefault(or_pairs: ?[]const Form, name: []const u8) ?Form {
    const ps = or_pairs orelse return null;
    var i: usize = 0;
    while (i + 1 < ps.len) : (i += 2) {
        if (ps[i].data == .symbol and std.mem.eql(u8, ps[i].data.symbol.name, name)) return ps[i + 1];
    }
    return null;
}

fn intForm(i: i64, loc: SourceLocation) Form {
    return .{ .data = .{ .integer = i }, .location = loc };
}

/// Build a call Form `(fn_name args...)`.
fn makeCall(
    arena: std.mem.Allocator,
    fn_name: []const u8,
    call_args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    var items = try arena.alloc(Form, 1 + call_args.len);
    items[0] = sym(fn_name, loc);
    @memcpy(items[1..], call_args);
    return list(arena, items, loc);
}

// --- loop — `loop*` rename + destructuring (D-076 cycle 4) ---
//
// `(loop [bindings] body...)` → `(loop* [slots] (let [patterns] body))`.
// Each binding pair becomes exactly ONE loop* slot, so `recur` arity =
// binding-pair count (JVM-faithful): a plain-symbol binding stays a
// loop* slot directly; a destructuring pattern becomes a gensym slot
// with the pattern bound in a body-wrapping `let`. `recur` rebinds the
// gensym slots; the inner `let` re-destructures each iteration (`let*`
// is not a recur target). Until this macro, bare `(loop …)` was
// unresolved — `loop*` had to be written directly.
fn expandLoop(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    if (args.len < 1)
        return error_catalog.raise(.let_form_incomplete, loc, .{});
    if (args[0].data != .vector)
        return error_catalog.raise(.bindings_not_vector, args[0].location, .{ .form = "loop" });

    const binds = args[0].data.vector;
    const body = args[1..];

    const has_pattern = blk: {
        if (binds.len % 2 != 0) break :blk false;
        var k: usize = 0;
        while (k < binds.len) : (k += 2) {
            if (binds[k].data != .symbol) break :blk true;
        }
        break :blk false;
    };
    if (!has_pattern) {
        var items = try arena.alloc(Form, args.len + 1);
        items[0] = sym("loop*", loc);
        @memcpy(items[1..], args);
        return list(arena, items, loc);
    }

    var slots: std.ArrayList(Form) = .empty;
    var lets: std.ArrayList(Form) = .empty;
    var k: usize = 0;
    while (k < binds.len) : (k += 2) {
        const pat = binds[k];
        const init = binds[k + 1];
        if (pat.data == .symbol) {
            try slots.append(arena, pat);
            try slots.append(arena, init);
        } else {
            const g = sym(try rt.gensym(arena, "loop"), loc);
            try slots.append(arena, g);
            try slots.append(arena, init);
            try lets.append(arena, pat);
            try lets.append(arena, g);
        }
    }

    var let_items = try arena.alloc(Form, 2 + body.len);
    let_items[0] = sym("let", loc);
    let_items[1] = try vec(arena, lets.items, loc);
    @memcpy(let_items[2..], body);
    const wrapped = try list(arena, let_items, loc);

    var items = try arena.alloc(Form, 3);
    items[0] = sym("loop*", loc);
    items[1] = try vec(arena, slots.items, loc);
    items[2] = wrapped;
    return list(arena, items, loc);
}

// --- when — `(when c body...)` → `(if c (do body...) nil)` ---

fn expandWhen(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len < 1)
        return error_catalog.raise(.when_form_incomplete, loc, .{});

    const cond_form = args[0];
    const body = args[1..];

    // clj: `(when test body...)` → `(if test (do body...))` — ALWAYS a `(do …)`
    // wrap (even single-body) and a 2-arg `if` (no explicit `nil` else), so
    // `(macroexpand-1 '(when c x))` byte-matches clj. (2-arg `if` yields nil on
    // a false test, identical to a 3-arg `(if c then nil)`.)
    var do_items = try arena.alloc(Form, body.len + 1);
    do_items[0] = sym("do", loc);
    @memcpy(do_items[1..], body);
    const then_form = try list(arena, do_items, loc);

    const if_items = try arena.alloc(Form, 3);
    if_items[0] = sym("if", loc);
    if_items[1] = cond_form;
    if_items[2] = then_form;
    return list(arena, if_items, loc);
}

// --- cond — right-associative cascade of ifs ---

fn expandCond(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len == 0) return nilForm(loc);
    if (args.len % 2 != 0)
        return error_catalog.raise(.cond_clauses_arity_odd, loc, .{ .got = args.len });

    return buildCondTail(arena, args, loc);
}

fn buildCondTail(
    arena: std.mem.Allocator,
    pairs: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    if (pairs.len == 0) return nilForm(loc);
    const test_f = pairs[0];
    const then_f = pairs[1];
    const rest_pairs = pairs[2..];

    const else_f = if (rest_pairs.len == 0) nilForm(loc) else try buildCondTail(arena, rest_pairs, loc);

    const if_items = try arena.alloc(Form, 4);
    if_items[0] = sym("if", loc);
    if_items[1] = test_f;
    if_items[2] = then_f;
    if_items[3] = else_f;
    return list(arena, if_items, loc);
}

// --- -> / ->> — thread-first / thread-last ---

fn expandThreadFirst(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    return threadInto(arena, rt, args, loc, .first);
}

fn expandThreadLast(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    return threadInto(arena, rt, args, loc, .last);
}

/// `(.. x form …)` → nested `(. (. x form1) form2 …)` (JVM clojure.core `..`).
/// Each `form` is a bare member symbol or a `(method args…)` list; the `.`
/// special form handles both shapes. The analyzer's `.`-prefixed dot-arms
/// exclude the exact `..` head (analyzer.zig) so it reaches this macro instead
/// of being misparsed as a `.` member access. Surfaced by honeysql's
/// `(.. s toString (toUpperCase java.util.Locale/US))`.
fn expandDotDot(arena: std.mem.Allocator, rt: *Runtime, args: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len < 2)
        return error_catalog.raise(.thread_macro_arity_invalid, loc, .{ .op = ".." });
    var acc = args[0];
    for (args[1..]) |form| {
        const items = try arena.alloc(Form, 3);
        items[0] = sym(".", loc);
        items[1] = acc;
        items[2] = form;
        acc = try list(arena, items, loc);
    }
    return acc;
}

// --- as-> / cond-> / cond->> / some-> / some->> (D-134 threading family) ---

/// `(let* [binds…] body)` from a flat binding slice + a body form.
fn buildLetStarBody(arena: std.mem.Allocator, binds: []const Form, body: Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    const items = try arena.alloc(Form, 3);
    items[0] = sym("let*", loc);
    items[1] = .{ .data = .{ .vector = binds }, .location = loc };
    items[2] = body;
    return list(arena, items, loc);
}

/// `(as-> expr name form*)` → `(let* [name expr, name form1, …] name)`.
/// The forms place `name` explicitly (not threaded).
fn expandAsThread(arena: std.mem.Allocator, rt: *Runtime, args: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len < 2)
        return error_catalog.raise(.thread_macro_arity_invalid, loc, .{ .op = "as->" });
    const name = args[1];
    if (name.data != .symbol or name.data.symbol.ns != null)
        return error_catalog.raise(.thread_macro_arity_invalid, args[1].location, .{ .op = "as->" });
    const forms = args[2..];
    const binds = try arena.alloc(Form, 2 * (1 + forms.len));
    binds[0] = name;
    binds[1] = args[0];
    for (forms, 0..) |f, i| {
        binds[2 + 2 * i] = name;
        binds[2 + 2 * i + 1] = f;
    }
    return buildLetStarBody(arena, binds, name, loc);
}

/// `(cond-> expr test form …)` → `(let* [g expr, g (if test1 (-> g f1) g) …] g)`
/// (`.last` ⇒ `(->> g f1)`). Each clause conditionally threads g through form.
fn condThread(arena: std.mem.Allocator, rt: *Runtime, args: []const Form, loc: SourceLocation, dir: ThreadDir) macro_dispatch.ExpandError!Form {
    const op = if (dir == .first) "cond->" else "cond->>";
    if (args.len == 0)
        return error_catalog.raise(.thread_macro_arity_invalid, loc, .{ .op = op });
    const clauses = args[1..];
    if (clauses.len % 2 != 0)
        return error_catalog.raise(.thread_macro_arity_invalid, loc, .{ .op = op });
    const g = sym(try rt.gensym(arena, "cond_thread"), loc);
    const binds = try arena.alloc(Form, 2 + clauses.len);
    binds[0] = g;
    binds[1] = args[0];
    var i: usize = 0;
    while (i < clauses.len) : (i += 2) {
        const threaded = try threadStep(arena, g, clauses[i + 1], dir);
        const if_items = try arena.alloc(Form, 4);
        if_items[0] = sym("if", loc);
        if_items[1] = clauses[i];
        if_items[2] = threaded;
        if_items[3] = g;
        binds[2 + i] = g;
        binds[2 + i + 1] = try list(arena, if_items, loc);
    }
    return buildLetStarBody(arena, binds, g, loc);
}
fn expandCondThreadFirst(arena: std.mem.Allocator, rt: *Runtime, args: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    return condThread(arena, rt, args, loc, .first);
}
fn expandCondThreadLast(arena: std.mem.Allocator, rt: *Runtime, args: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    return condThread(arena, rt, args, loc, .last);
}

/// `(some-> expr form …)` → `(let* [g expr, g (if (nil? g) nil (-> g f1)) …] g)`
/// (`.last` ⇒ `(->> g f1)`). Short-circuits to nil the moment a step yields nil.
fn someThread(arena: std.mem.Allocator, rt: *Runtime, args: []const Form, loc: SourceLocation, dir: ThreadDir) macro_dispatch.ExpandError!Form {
    const op = if (dir == .first) "some->" else "some->>";
    if (args.len == 0)
        return error_catalog.raise(.thread_macro_arity_invalid, loc, .{ .op = op });
    const forms = args[1..];
    const g = sym(try rt.gensym(arena, "some_thread"), loc);
    const binds = try arena.alloc(Form, 2 + 2 * forms.len);
    binds[0] = g;
    binds[1] = args[0];
    for (forms, 0..) |form, i| {
        const threaded = try threadStep(arena, g, form, dir);
        const nilq_items = try arena.alloc(Form, 2);
        nilq_items[0] = sym("nil?", loc);
        nilq_items[1] = g;
        const if_items = try arena.alloc(Form, 4);
        if_items[0] = sym("if", loc);
        if_items[1] = try list(arena, nilq_items, loc);
        if_items[2] = nilForm(loc);
        if_items[3] = threaded;
        binds[2 + 2 * i] = g;
        binds[2 + 2 * i + 1] = try list(arena, if_items, loc);
    }
    return buildLetStarBody(arena, binds, g, loc);
}
fn expandSomeThreadFirst(arena: std.mem.Allocator, rt: *Runtime, args: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    return someThread(arena, rt, args, loc, .first);
}
fn expandSomeThreadLast(arena: std.mem.Allocator, rt: *Runtime, args: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    return someThread(arena, rt, args, loc, .last);
}

// --- if-some / when-some / doto (D-134 conditional family) ---

/// `(do body…)` from a body slice, folded to the single form when len == 1.
fn foldBody(arena: std.mem.Allocator, body: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    if (body.len == 1) return body[0];
    const do_items = try arena.alloc(Form, body.len + 1);
    do_items[0] = sym("do", loc);
    @memcpy(do_items[1..], body);
    return list(arena, do_items, loc);
}

/// `(if-some [name expr] then else?)` →
/// `(let* [g expr] (if (nil? g) else (let* [name g] then)))`.
fn expandIfSome(arena: std.mem.Allocator, rt: *Runtime, args: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    if (args.len < 2 or args.len > 3)
        return error_catalog.raise(.if_some_form_incomplete, loc, .{});
    if (args[0].data != .vector or args[0].data.vector.len != 2)
        return error_catalog.raise(.if_some_bindings_invalid, args[0].location, .{});
    const binding_v = args[0].data.vector;
    // Binding target may be a symbol OR any destructure pattern (clj parity);
    // the nil? test is on the whole expr value, the pattern destructures in `then`.

    const name_form = binding_v[0];
    const expr_form = binding_v[1];
    const then_form = args[1];
    const else_form: Form = if (args.len == 3) args[2] else nilForm(loc);
    const gname = try rt.gensym(arena, "if_some");

    // inner: (let [pattern g] then) — `let` so a destructure pattern lowers
    // (plain symbol reduces to let*, no regression).
    const inner_binding = try arena.alloc(Form, 2);
    inner_binding[0] = name_form;
    inner_binding[1] = sym(gname, loc);
    const inner_let_items = try arena.alloc(Form, 3);
    inner_let_items[0] = sym("let", loc);
    inner_let_items[1] = .{ .data = .{ .vector = inner_binding }, .location = loc };
    inner_let_items[2] = then_form;
    const inner_let = try list(arena, inner_let_items, loc);

    // (nil? g)
    const nilq_items = try arena.alloc(Form, 2);
    nilq_items[0] = sym("nil?", loc);
    nilq_items[1] = sym(gname, loc);

    // (if (nil? g) else (let* [name g] then))
    const if_items = try arena.alloc(Form, 4);
    if_items[0] = sym("if", loc);
    if_items[1] = try list(arena, nilq_items, loc);
    if_items[2] = else_form;
    if_items[3] = inner_let;

    // (let* [g expr] (if …))
    const outer_binding = try arena.alloc(Form, 2);
    outer_binding[0] = sym(gname, loc);
    outer_binding[1] = expr_form;
    return buildLetStarBody(arena, outer_binding, try list(arena, if_items, loc), loc);
}

/// `(when-some [name expr] body…)` → `(if-some [name expr] (do body…) nil)`
/// (re-expands through expandIfSome for the gensym).
fn expandWhenSome(arena: std.mem.Allocator, rt: *Runtime, args: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len < 2)
        return error_catalog.raise(.when_some_form_incomplete, loc, .{});
    const body_form = try foldBody(arena, args[1..], loc);
    const items = try arena.alloc(Form, 4);
    items[0] = sym("if-some", loc);
    items[1] = args[0];
    items[2] = body_form;
    items[3] = nilForm(loc);
    return list(arena, items, loc);
}

/// `(doto x form…)` → `(let* [g x] (do (-> g form1) … g))`. Threads g into
/// each form (first position) for side effects, evaluates to g.
fn expandDoto(arena: std.mem.Allocator, rt: *Runtime, args: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    if (args.len == 0)
        return error_catalog.raise(.doto_form_incomplete, loc, .{});
    const g = sym(try rt.gensym(arena, "doto"), loc);
    const forms = args[1..];
    // body: (do <threaded forms…> g)
    const do_items = try arena.alloc(Form, forms.len + 2);
    do_items[0] = sym("do", loc);
    for (forms, 0..) |form, i| {
        do_items[1 + i] = try threadStep(arena, g, form, .first);
    }
    do_items[forms.len + 1] = g;
    const binding = try arena.alloc(Form, 2);
    binding[0] = g;
    binding[1] = args[0];
    return buildLetStarBody(arena, binding, try list(arena, do_items, loc), loc);
}

// --- dotimes / while / when-first (D-134 iteration/binding family) ---

/// `(dotimes [i n] body…)` →
/// `(let* [ng n] (loop [i 0] (when (< i ng) body… (recur (inc i)))))`.
/// Evaluates to nil; `ng` is hoisted so `n` is evaluated once.
fn expandDotimes(arena: std.mem.Allocator, rt: *Runtime, args: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    if (args.len < 1)
        return error_catalog.raise(.dotimes_form_incomplete, loc, .{});
    if (args[0].data != .vector or args[0].data.vector.len != 2)
        return error_catalog.raise(.dotimes_bindings_invalid, args[0].location, .{});
    const bv = args[0].data.vector;
    if (bv[0].data != .symbol or bv[0].data.symbol.ns != null)
        return error_catalog.raise(.dotimes_bindings_invalid, bv[0].location, .{});
    const i_sym = bv[0];
    const n_expr = bv[1];
    const body = args[1..];
    const ng = sym(try rt.gensym(arena, "dotimes_n"), loc);

    const recur_form = try makeCall(arena, "recur", &.{try makeCall(arena, "inc", &.{i_sym}, loc)}, loc);
    const lt_form = try makeCall(arena, "<", &.{ i_sym, ng }, loc);

    // (when (< i ng) body… (recur (inc i)))
    const when_items = try arena.alloc(Form, 3 + body.len);
    when_items[0] = sym("when", loc);
    when_items[1] = lt_form;
    @memcpy(when_items[2 .. 2 + body.len], body);
    when_items[2 + body.len] = recur_form;

    // (loop [i 0] (when …))
    const loop_binding = try arena.alloc(Form, 2);
    loop_binding[0] = i_sym;
    loop_binding[1] = intForm(0, loc);
    const loop_items = try arena.alloc(Form, 3);
    loop_items[0] = sym("loop", loc);
    loop_items[1] = .{ .data = .{ .vector = loop_binding }, .location = loc };
    loop_items[2] = try list(arena, when_items, loc);

    // (let* [ng n] (loop …))
    const outer_binding = try arena.alloc(Form, 2);
    outer_binding[0] = ng;
    outer_binding[1] = n_expr;
    return buildLetStarBody(arena, outer_binding, try list(arena, loop_items, loc), loc);
}

/// `(while test body…)` → `(loop [] (when test body… (recur)))`.
/// Evaluates to nil.
fn expandWhile(arena: std.mem.Allocator, rt: *Runtime, args: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len < 1)
        return error_catalog.raise(.while_form_incomplete, loc, .{});
    const test_form = args[0];
    const body = args[1..];
    const recur_form = try makeCall(arena, "recur", &.{}, loc);

    // (when test body… (recur))
    const when_items = try arena.alloc(Form, 3 + body.len);
    when_items[0] = sym("when", loc);
    when_items[1] = test_form;
    @memcpy(when_items[2 .. 2 + body.len], body);
    when_items[2 + body.len] = recur_form;

    // (loop [] (when …))
    const loop_items = try arena.alloc(Form, 3);
    loop_items[0] = sym("loop", loc);
    loop_items[1] = .{ .data = .{ .vector = try arena.alloc(Form, 0) }, .location = loc };
    loop_items[2] = try list(arena, when_items, loc);
    return list(arena, loop_items, loc);
}

/// `(when-first [x coll] body…)` →
/// `(when-let [g (seq coll)] (let* [x (first g)] (do body…)))`.
fn expandWhenFirst(arena: std.mem.Allocator, rt: *Runtime, args: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    if (args.len < 2)
        return error_catalog.raise(.when_first_form_incomplete, loc, .{});
    if (args[0].data != .vector or args[0].data.vector.len != 2)
        return error_catalog.raise(.when_first_bindings_invalid, args[0].location, .{});
    const bv = args[0].data.vector;
    // bv[0] may be a symbol OR any destructure pattern (clj parity): the
    // pattern binds `(first coll)` in the body.
    const x_sym = bv[0];
    const coll_expr = bv[1];
    const g = sym(try rt.gensym(arena, "when_first"), loc);

    // inner: (let [pattern (first g)] (do body…)) — `let` so a destructure
    // pattern lowers (plain symbol reduces to let*, no regression).
    const inner_binding = try arena.alloc(Form, 2);
    inner_binding[0] = x_sym;
    inner_binding[1] = try makeCall(arena, "first", &.{g}, loc);
    const inner_let_items = try arena.alloc(Form, 3);
    inner_let_items[0] = sym("let", loc);
    inner_let_items[1] = .{ .data = .{ .vector = inner_binding }, .location = loc };
    inner_let_items[2] = try foldBody(arena, args[1..], loc);
    const inner_let = try list(arena, inner_let_items, loc);

    // (when-let [g (seq coll)] inner_let)
    const wl_binding = try arena.alloc(Form, 2);
    wl_binding[0] = g;
    wl_binding[1] = try makeCall(arena, "seq", &.{coll_expr}, loc);
    const wl_items = try arena.alloc(Form, 3);
    wl_items[0] = sym("when-let", loc);
    wl_items[1] = .{ .data = .{ .vector = wl_binding }, .location = loc };
    wl_items[2] = inner_let;
    return list(arena, wl_items, loc);
}

// --- doseq (D-134 / phaseA26) ---
//
// `(doseq [bind coll | :let v | :when t | :while t …] body…)` → nested
// `loop`/`recur` over each binding pair, with :let / :when / :while injected
// as let / if / when. Always returns nil. A port of the JVM
// clojure.core/doseq `step` closure, dropping the chunked fast path (cw v1
// has no chunked-seq; the first/next slow path is semantically identical —
// see private/notes/phaseA26-doseq-for-survey.md §5.1). Binds go through the
// `let` macro so destructuring rides the existing let lowering.

const DoseqStep = struct { needrec: bool, form: Form };

/// `(let <binding-vector-form> <body>)` — used so doseq binds destructure.
fn makeLet(arena: std.mem.Allocator, binding: Form, body: Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    const items = try arena.alloc(Form, 3);
    items[0] = sym("let", loc);
    items[1] = binding;
    items[2] = body;
    return list(arena, items, loc);
}

/// Right-to-left recursion over the binding/modifier list. `recform` is the
/// recur form that continues the enclosing loop (null at top). `needrec=true`
/// means "the enclosing loop must append its recur after this subform" (the
/// subform did not itself emit a recur).
fn doseqStep(
    arena: std.mem.Allocator,
    rt: *Runtime,
    recform: ?Form,
    exprs: []const Form,
    body: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!DoseqStep {
    if (exprs.len == 0)
        return .{ .needrec = true, .form = try foldBody(arena, body, loc) };

    const k = exprs[0];
    const v = exprs[1];
    const rest = exprs[2..];

    if (k.data == .keyword and k.data.keyword.ns == null) {
        const kname = k.data.keyword.name;
        const inner = try doseqStep(arena, rt, recform, rest, body, loc);
        if (std.mem.eql(u8, kname, "let")) {
            if (v.data != .vector)
                return error_catalog.raise(.doseq_bindings_invalid, v.location, .{});
            return .{ .needrec = inner.needrec, .form = try makeLet(arena, v, inner.form, loc) };
        } else if (std.mem.eql(u8, kname, "while")) {
            // (when v inner.form [recform if inner.needrec])
            const append = inner.needrec and recform != null;
            const items = try arena.alloc(Form, if (append) 4 else 3);
            items[0] = sym("when", loc);
            items[1] = v;
            items[2] = inner.form;
            if (append) items[3] = recform.?;
            return .{ .needrec = false, .form = try list(arena, items, loc) };
        } else if (std.mem.eql(u8, kname, "when")) {
            // (if v (do inner.form [recform if needrec]) recform)
            const then_form = if (inner.needrec and recform != null) blk: {
                const do_items = try arena.alloc(Form, 3);
                do_items[0] = sym("do", loc);
                do_items[1] = inner.form;
                do_items[2] = recform.?;
                break :blk try list(arena, do_items, loc);
            } else inner.form;
            const if_items = try arena.alloc(Form, 4);
            if_items[0] = sym("if", loc);
            if_items[1] = v;
            if_items[2] = then_form;
            if_items[3] = recform orelse nilForm(loc);
            return .{ .needrec = false, .form = try list(arena, if_items, loc) };
        }
        return error_catalog.raise(.doseq_bindings_invalid, k.location, .{});
    }

    // A real `bind coll` pair → build a loop over (seq coll), slow path only.
    const gname = sym(try rt.gensym(arena, "doseq_seq"), loc);
    const recform_inner = try makeCall(arena, "recur", &.{try makeCall(arena, "next", &.{gname}, loc)}, loc);
    const inner = try doseqStep(arena, rt, recform_inner, rest, body, loc);

    // (let [bind (first g)] inner.form)
    const lb = try arena.alloc(Form, 2);
    lb[0] = k;
    lb[1] = try makeCall(arena, "first", &.{gname}, loc);
    const let_form = try makeLet(arena, .{ .data = .{ .vector = lb }, .location = loc }, inner.form, loc);

    // (when g <let_form> [recur (next g) if inner.needrec])
    const when_items = try arena.alloc(Form, if (inner.needrec) 4 else 3);
    when_items[0] = sym("when", loc);
    when_items[1] = gname;
    when_items[2] = let_form;
    if (inner.needrec) when_items[3] = recform_inner;

    // (loop [g (seq coll)] <when>)
    const loop_binding = try arena.alloc(Form, 2);
    loop_binding[0] = gname;
    loop_binding[1] = try makeCall(arena, "seq", &.{v}, loc);
    const loop_items = try arena.alloc(Form, 3);
    loop_items[0] = sym("loop", loc);
    loop_items[1] = .{ .data = .{ .vector = loop_binding }, .location = loc };
    loop_items[2] = try list(arena, when_items, loc);
    return .{ .needrec = true, .form = try list(arena, loop_items, loc) };
}

fn expandDoseq(arena: std.mem.Allocator, rt: *Runtime, args: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    if (args.len < 1)
        return error_catalog.raise(.doseq_form_incomplete, loc, .{});
    if (args[0].data != .vector or args[0].data.vector.len % 2 != 0)
        return error_catalog.raise(.doseq_bindings_invalid, args[0].location, .{});
    const result = try doseqStep(arena, rt, null, args[0].data.vector, args[1..], loc);
    return result.form;
}

// --- for (D-134 / D-234) - lazy list comprehension ---
//
// `(for [bind coll | :let v | :when t | :while t ...] expr)` -> a `letfn` +
// `lazy-seq` step chain, a port of clojure.core/for's `emit-bind` (dropping
// the chunked fast path; cw v1 has no chunked-seq). Each binding group gets
// a self-recursive iterator fn `(giter [gxs] (lazy-seq (loop* [gxs gxs]
// (when (seq gxs) (let [bind (first gxs)] <do-mod>)))))`; self-reference
// rides `letfn` (cljw has no named-`fn` self-ref). `do-mod` threads the
// modifiers in written order: `:let`->`(let v ...)`, `:while`->`(when t ...)`
// (false => nil => the seq terminates), `:when`->`(if t ... (recur (rest gxs)))`
// (false => skip this element). The innermost group emits `(cons body (giter
// (rest gxs)))`; a non-innermost group splices its child via `(let [fs (seq
// (child coll'))] (if fs (concat fs (giter (rest gxs))) (recur (rest gxs))))`.
// This gives clj's exact sequential semantics - crucially `:while` is
// evaluated AFTER `:when` per element, so `(for [a (range 5) :when (> a 0)
// :while (odd? a)] a)` -> `(1)` (a=0 is `:when`-skipped, never reaching
// `:while`). Replaces the old mapcat-of-singletons lowering (D-234), which
// could not express that post-filter short-circuit. `let` (not `let*`)
// carries destructuring binds. Survey: phaseA26-doseq-for-survey.md.
//
// `outer_cont` / `outer_recform` are the enclosing binding's lazy
// self-continuation `(giter (rest gxs))` and skip form `(recur (rest gxs))`;
// both null only at the top (where the first expr must be a binding pair).
fn forStep(
    arena: std.mem.Allocator,
    rt: *Runtime,
    outer_cont: ?Form,
    outer_recform: ?Form,
    exprs: []const Form,
    body: Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    if (exprs.len == 0)
        // Innermost: emit the body and lazily continue the enclosing iterator.
        return makeCall(arena, "cons", &.{ body, outer_cont.? }, loc);

    const k = exprs[0];
    const v = exprs[1];
    const rest = exprs[2..];

    if (k.data == .keyword and k.data.keyword.ns == null) {
        const kname = k.data.keyword.name;
        if (outer_recform == null) // a modifier with no preceding binding pair
            return error_catalog.raise(.for_bindings_invalid, k.location, .{});
        const inner = try forStep(arena, rt, outer_cont, outer_recform, rest, body, loc);
        if (std.mem.eql(u8, kname, "let")) {
            if (v.data != .vector)
                return error_catalog.raise(.for_bindings_invalid, v.location, .{});
            return makeLet(arena, v, inner, loc);
        } else if (std.mem.eql(u8, kname, "while")) {
            // (when v inner) - false => nil => the lazy-seq terminates.
            const items = try arena.alloc(Form, 3);
            items[0] = sym("when", loc);
            items[1] = v;
            items[2] = inner;
            return list(arena, items, loc);
        } else if (std.mem.eql(u8, kname, "when")) {
            // (if v inner (recur (rest gxs))) - false => skip this element.
            const items = try arena.alloc(Form, 4);
            items[0] = sym("if", loc);
            items[1] = v;
            items[2] = inner;
            items[3] = outer_recform.?;
            return list(arena, items, loc);
        }
        return error_catalog.raise(.for_bindings_invalid, k.location, .{});
    }

    // A real `bind coll` pair -> a self-recursive lazy iterator over (seq coll).
    const giter = sym(try rt.gensym(arena, "for_iter"), loc);
    const gxs = sym(try rt.gensym(arena, "for_s"), loc);
    const cont_form = try listOf(arena, &.{ giter, try makeCall(arena, "rest", &.{gxs}, loc) }, loc); // (giter (rest gxs))
    const recform = try makeCall(arena, "recur", &.{try makeCall(arena, "rest", &.{gxs}, loc)}, loc); // (recur (rest gxs))
    const inner = try forStep(arena, rt, cont_form, recform, rest, body, loc);

    // (let [bind (first gxs)] inner)
    const lb = try arena.alloc(Form, 2);
    lb[0] = k;
    lb[1] = try makeCall(arena, "first", &.{gxs}, loc);
    const let_form = try makeLet(arena, .{ .data = .{ .vector = lb }, .location = loc }, inner, loc);

    // (when (seq gxs) <let_form>)
    const when_items = try arena.alloc(Form, 3);
    when_items[0] = sym("when", loc);
    when_items[1] = try makeCall(arena, "seq", &.{gxs}, loc);
    when_items[2] = let_form;
    const when_form = try list(arena, when_items, loc);

    // (loop* [gxs gxs] <when>)
    const loop_binding = try arena.alloc(Form, 2);
    loop_binding[0] = gxs;
    loop_binding[1] = gxs;
    const loop_items = try arena.alloc(Form, 3);
    loop_items[0] = sym("loop*", loc);
    loop_items[1] = .{ .data = .{ .vector = loop_binding }, .location = loc };
    loop_items[2] = when_form;
    const loop_form = try list(arena, loop_items, loc);

    // (letfn [(giter [gxs] (lazy-seq <loop>))] (giter coll))
    const param_vec = try arena.alloc(Form, 1);
    param_vec[0] = gxs;
    const spec_items = try arena.alloc(Form, 3);
    spec_items[0] = giter;
    spec_items[1] = .{ .data = .{ .vector = param_vec }, .location = loc };
    spec_items[2] = try makeCall(arena, "lazy-seq", &.{loop_form}, loc);
    const spec_form = try list(arena, spec_items, loc);
    const letfn_bindings = try arena.alloc(Form, 1);
    letfn_bindings[0] = spec_form;
    const letfn_items = try arena.alloc(Form, 3);
    letfn_items[0] = sym("letfn", loc);
    letfn_items[1] = .{ .data = .{ .vector = letfn_bindings }, .location = loc };
    letfn_items[2] = try listOf(arena, &.{ giter, v }, loc); // (giter coll)
    const iter_expr = try list(arena, letfn_items, loc);

    if (outer_cont == null)
        return iter_expr; // top-level binding - the comprehension itself

    // Nested under an outer binding: splice this child seq into the outer
    // iteration. (let [fs (seq <iter_expr>)] (if fs (concat fs cont) recur))
    const gfs = sym(try rt.gensym(arena, "for_fs"), loc);
    const fb = try arena.alloc(Form, 2);
    fb[0] = gfs;
    fb[1] = try makeCall(arena, "seq", &.{iter_expr}, loc);
    const if_items = try arena.alloc(Form, 4);
    if_items[0] = sym("if", loc);
    if_items[1] = gfs;
    if_items[2] = try makeCall(arena, "concat", &.{ gfs, outer_cont.? }, loc);
    if_items[3] = outer_recform.?;
    return makeLet(arena, .{ .data = .{ .vector = fb }, .location = loc }, try list(arena, if_items, loc), loc);
}

/// `(head a b ...)` where `head` is an already-built Form (vs `makeCall`
/// which takes a string head). Used for `(giter (rest gxs))` etc.
fn listOf(arena: std.mem.Allocator, items: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    const buf = try arena.alloc(Form, items.len);
    @memcpy(buf, items);
    return list(arena, buf, loc);
}

fn expandFor(arena: std.mem.Allocator, rt: *Runtime, args: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    if (args.len < 2)
        return error_catalog.raise(.for_form_incomplete, loc, .{});
    if (args[0].data != .vector or args[0].data.vector.len % 2 != 0)
        return error_catalog.raise(.for_bindings_invalid, args[0].location, .{});
    return forStep(arena, rt, null, null, args[0].data.vector, try foldBody(arena, args[1..], loc), loc);
}

// --- case (D-134) ---

/// `(= g (quote const))` — value-equality against an unevaluated constant.
fn caseConstEq(arena: std.mem.Allocator, g: Form, const_form: Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    const quoted = try makeCall(arena, "quote", &.{const_form}, loc);
    return makeCall(arena, "=", &.{ g, quoted }, loc);
}

/// Test for one clause's test-constant: a list `(c1 c2 …)` →
/// `(rt/or (= g 'c1) (= g 'c2) …)`; a single constant → `(= g 'const)`.
/// The emitted `or` is the QUALIFIED builtin (`rt/or`), not a bare `or` —
/// otherwise, in a namespace that shadows `or` (clojure.spec.alpha excludes +
/// redefines it), the generated test would resolve to the user's `or` macro
/// (macro hygiene: a macro-expansion must not capture a user redefinition of a
/// core name it emits). D-476.
fn caseTest(arena: std.mem.Allocator, g: Form, test_const: Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    if (test_const.data == .list) {
        const elems = test_const.data.list;
        const or_items = try arena.alloc(Form, 1 + elems.len);
        or_items[0] = .{ .data = .{ .symbol = .{ .ns = "rt", .name = "or" } }, .location = loc };
        for (elems, 0..) |el, i| or_items[1 + i] = try caseConstEq(arena, g, el, loc);
        return list(arena, or_items, loc);
    }
    return caseConstEq(arena, g, test_const, loc);
}

/// `(throw (ex-info "No matching clause" {:value v}))` — the no-default
/// fallback shared by case and condp.
fn noMatchThrow(arena: std.mem.Allocator, g: Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    const map_items = try arena.alloc(Form, 2);
    map_items[0] = .{ .data = .{ .keyword = .{ .name = "value" } }, .location = loc };
    map_items[1] = g;
    const map_form: Form = .{ .data = .{ .map = map_items }, .location = loc };
    const msg: Form = .{ .data = .{ .string = "No matching clause" }, .location = loc };
    const exinfo = try makeCall(arena, "ex-info", &.{ msg, map_form }, loc);
    return makeCall(arena, "throw", &.{exinfo}, loc);
}

/// `(case e clause* default?)` →
/// `(let* [g e] (if test1 r1 (if test2 r2 … fallback)))`.
/// Constants are unevaluated (quoted); a list clause matches any element.
/// An odd trailing form is the default; without one, no match throws.
/// (Divergence from JVM case: dispatch is a linear `=` cascade, not a
/// constant-time jump table, and duplicate constants are not rejected.)
fn expandCase(arena: std.mem.Allocator, rt: *Runtime, args: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    if (args.len < 2)
        return error_catalog.raise(.case_form_incomplete, loc, .{});
    const clauses = args[1..];
    const has_default = (clauses.len % 2 == 1);
    const npairs = clauses.len / 2;
    const g = sym(try rt.gensym(arena, "case"), loc);

    var acc: Form = if (has_default) clauses[clauses.len - 1] else try noMatchThrow(arena, g, loc);
    var p: usize = npairs;
    while (p > 0) {
        p -= 1;
        const if_items = try arena.alloc(Form, 4);
        if_items[0] = sym("if", loc);
        if_items[1] = try caseTest(arena, g, clauses[2 * p], loc);
        if_items[2] = clauses[2 * p + 1];
        if_items[3] = acc;
        acc = try list(arena, if_items, loc);
    }
    const binding = try arena.alloc(Form, 2);
    binding[0] = g;
    binding[1] = args[0];
    return buildLetStarBody(arena, binding, acc, loc);
}

// --- condp (D-134) ---

/// `(head call_args…)` from an arbitrary head Form (vs makeCall's name string).
fn callForm(arena: std.mem.Allocator, head: Form, call_args: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    const items = try arena.alloc(Form, 1 + call_args.len);
    items[0] = head;
    @memcpy(items[1..], call_args);
    return list(arena, items, loc);
}

/// `(if test then else)`.
fn makeIf(arena: std.mem.Allocator, test_f: Form, then_f: Form, else_f: Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    const items = try arena.alloc(Form, 4);
    items[0] = sym("if", loc);
    items[1] = test_f;
    items[2] = then_f;
    items[3] = else_f;
    return list(arena, items, loc);
}

/// True when `f` is the ordinary keyword `:>>` used to mark a condp result-fn.
fn isCondpArrow(f: Form) bool {
    return f.data == .keyword and f.data.keyword.ns == null and std.mem.eql(u8, f.data.keyword.name, ">>");
}

/// Recursive emit mirroring JVM condp: a clause is 3 forms when its second
/// is `:>>` (result-fn applied to the predicate's truthy value), else 2; a
/// lone trailing form is the default; nothing left throws.
fn condpEmit(arena: std.mem.Allocator, rt: *Runtime, gpred: Form, gexpr: Form, args: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    if (args.len == 0) return noMatchThrow(arena, gexpr, loc);
    const take: usize = if (args.len >= 2 and isCondpArrow(args[1])) 3 else 2;
    const n = @min(take, args.len);
    if (n == 1) return args[0]; // trailing default
    const pred_call = try callForm(arena, gpred, &.{ args[0], gexpr }, loc);
    if (n == 2) {
        const more = try condpEmit(arena, rt, gpred, gexpr, args[2..], loc);
        return makeIf(arena, pred_call, args[1], more, loc);
    }
    // n == 3: (if-let [p (gpred a gexpr)] (result-fn p) <more>)
    const more = try condpEmit(arena, rt, gpred, gexpr, args[3..], loc);
    const p = sym(try rt.gensym(arena, "condp_p"), loc);
    const fn_call = try callForm(arena, args[2], &.{p}, loc);
    const binding = try arena.alloc(Form, 2);
    binding[0] = p;
    binding[1] = pred_call;
    const ifl = try arena.alloc(Form, 4);
    ifl[0] = sym("if-let", loc);
    ifl[1] = .{ .data = .{ .vector = binding }, .location = loc };
    ifl[2] = fn_call;
    ifl[3] = more;
    return list(arena, ifl, loc);
}

/// `(condp pred expr clause*)` → `(let* [gp pred ge expr] <emit clauses>)`.
/// pred + expr are each evaluated once; see condpEmit for the clause shapes.
fn expandCondp(arena: std.mem.Allocator, rt: *Runtime, args: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    if (args.len < 2)
        return error_catalog.raise(.condp_form_incomplete, loc, .{});
    const gpred = sym(try rt.gensym(arena, "condp_pred"), loc);
    const gexpr = sym(try rt.gensym(arena, "condp_expr"), loc);
    const body = try condpEmit(arena, rt, gpred, gexpr, args[2..], loc);

    const binds = try arena.alloc(Form, 4);
    binds[0] = gpred;
    binds[1] = args[0];
    binds[2] = gexpr;
    binds[3] = args[1];
    return buildLetStarBody(arena, binds, body, loc);
}

// --- when-not / if-not / comment (D-134 trivial control macros) ---

/// `(if-not test then else?)` → `(if test else then)` (branches swapped;
/// avoids a `not` call). `else` defaults to nil.
fn expandIfNot(arena: std.mem.Allocator, rt: *Runtime, args: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len < 2 or args.len > 3)
        return error_catalog.raise(.if_not_form_incomplete, loc, .{});
    const else_form: Form = if (args.len == 3) args[2] else nilForm(loc);
    return makeIf(arena, args[0], else_form, args[1], loc);
}

/// `(when-not test body…)` → `(if test nil (do body…))`.
fn expandWhenNot(arena: std.mem.Allocator, rt: *Runtime, args: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len < 1)
        return error_catalog.raise(.when_not_form_incomplete, loc, .{});
    // Empty body (`(when-not test)`) is nil (clj parity), like `when`.
    const body = if (args.len == 1) nilForm(loc) else try foldBody(arena, args[1..], loc);
    return makeIf(arena, args[0], nilForm(loc), body, loc);
}

/// `(comment …)` → nil. The body is read (must be well-formed s-exprs) but
/// never analyzed or evaluated, so it may reference undefined symbols.
fn expandComment(arena: std.mem.Allocator, rt: *Runtime, args: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    _ = arena;
    _ = rt;
    _ = args;
    return nilForm(loc);
}

/// `(assert expr)` / `(assert expr msg)` →
/// `(if expr nil (throw (__assertion-error MSG)))`. MSG includes the asserted
/// FORM (clj parity): `(str "Assert failed: " (pr-str 'expr))` for 1-arg, and
/// `(str "Assert failed: " msg "\n" (pr-str 'expr))` for 2-arg — built lazily
/// in the failure branch only. A failed assert throws an `AssertionError`
/// (D-192) — catchable as `AssertionError`/`Error`/`Throwable` but NOT
/// `Exception`, and with no ex-data, matching JVM `assert`.
fn expandAssert(arena: std.mem.Allocator, rt: *Runtime, args: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len < 1 or args.len > 2)
        return error_catalog.raise(.assert_form_incomplete, loc, .{});
    const expr = args[0];
    const prefix: Form = .{ .data = .{ .string = "Assert failed: " }, .location = loc };
    // (pr-str (quote <expr>)) — the asserted form, printed clj-style.
    const quoted = try makeCall(arena, "quote", &.{expr}, loc);
    const pr_form = try makeCall(arena, "pr-str", &.{quoted}, loc);
    const msg: Form = if (args.len == 2) blk: {
        const nl: Form = .{ .data = .{ .string = "\n" }, .location = loc };
        break :blk try makeCall(arena, "str", &.{ prefix, args[1], nl, pr_form }, loc);
    } else try makeCall(arena, "str", &.{ prefix, pr_form }, loc);
    const ae = try makeCall(arena, "__assertion-error", &.{msg}, loc);
    const throw_form = try makeCall(arena, "throw", &.{ae}, loc);
    return makeIf(arena, expr, nilForm(loc), throw_form, loc);
}

/// `(lazy-cat c0 c1 …)` → `(concat (lazy-seq c0) (lazy-seq c1) …)`. Each
/// coll expr is wrapped in `lazy-seq` so it isn't realized until consumed
/// (a fn would force all args eagerly — hence a macro). `(lazy-cat)` → `()`.
fn expandLazyCat(arena: std.mem.Allocator, rt: *Runtime, args: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    _ = rt;
    const items = try arena.alloc(Form, 1 + args.len);
    items[0] = sym("concat", loc);
    for (args, 0..) |a, i| items[1 + i] = try makeCall(arena, "lazy-seq", &.{a}, loc);
    return list(arena, items, loc);
}

const ThreadDir = enum { first, last };

fn threadInto(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
    dir: ThreadDir,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len == 0)
        return error_catalog.raise(.thread_macro_arity_invalid, loc, .{ .op = if (dir == .first) "->" else "->>" });

    var acc = args[0];
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const step = args[i];
        acc = try threadStep(arena, acc, step, dir);
    }
    return acc;
}

fn threadStep(
    arena: std.mem.Allocator,
    acc: Form,
    step: Form,
    dir: ThreadDir,
) macro_dispatch.ExpandError!Form {
    // Bare-symbol / bare-keyword step: `(-> x f)` → `(f x)`,
    // `(-> m :k)` → `(:k m)` (keyword-as-fn, D-085).
    if (step.data == .symbol or step.data == .keyword) {
        const items = try arena.alloc(Form, 2);
        items[0] = step;
        items[1] = acc;
        return list(arena, items, step.location);
    }
    if (step.data != .list)
        return error_catalog.raise(.thread_macro_step_invalid_type, step.location, .{ .actual = step.typeName() });

    const orig = step.data.list;
    if (orig.len == 0)
        return error_catalog.raise(.thread_macro_step_empty_list, step.location, .{});

    const new_items = try arena.alloc(Form, orig.len + 1);
    switch (dir) {
        .first => {
            // (f a b ...) → (f acc a b ...)
            new_items[0] = orig[0];
            new_items[1] = acc;
            @memcpy(new_items[2..], orig[1..]);
        },
        .last => {
            // (f a b ...) → (f a b ... acc)
            @memcpy(new_items[0..orig.len], orig);
            new_items[orig.len] = acc;
        },
    }
    return list(arena, new_items, step.location);
}

// --- and / or — short-circuit via gensym + let* + if ---

fn expandAnd(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    if (args.len == 0) return macro_dispatch.makeBool(true, loc);
    if (args.len == 1) return args[0];

    // Left-fold non-recursively: walk args right-to-left, wrapping the
    // accumulator with `(let* [g aᵢ] (if g acc g))`. Single expansion
    // pass; macro_dispatch is not re-entered per arg.
    var acc = args[args.len - 1];
    var i: usize = args.len - 1;
    while (i > 0) {
        i -= 1;
        const gname = try rt.gensym(arena, "and");
        acc = try buildShortCircuit(arena, gname, args[i], acc, sym(gname, loc), loc);
    }
    return acc;
}

fn expandOr(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    if (args.len == 0) return nilForm(loc);
    if (args.len == 1) return args[0];

    // Mirror of expandAnd; the truthy branch echoes the binding so the
    // value flows out unchanged.
    var acc = args[args.len - 1];
    var i: usize = args.len - 1;
    while (i > 0) {
        i -= 1;
        const gname = try rt.gensym(arena, "or");
        acc = try buildShortCircuit(arena, gname, args[i], sym(gname, loc), acc, loc);
    }
    return acc;
}

/// `(let* [g expr] (if g <then_when_truthy> <else_when_falsy>))`.
fn buildShortCircuit(
    arena: std.mem.Allocator,
    gname: []const u8,
    expr: Form,
    then_branch: Form,
    else_branch: Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    const binding = try arena.alloc(Form, 2);
    binding[0] = sym(gname, loc);
    binding[1] = expr;

    const if_items = try arena.alloc(Form, 4);
    if_items[0] = sym("if", loc);
    if_items[1] = sym(gname, loc);
    if_items[2] = then_branch;
    if_items[3] = else_branch;
    const if_form = try list(arena, if_items, loc);

    const let_items = try arena.alloc(Form, 3);
    let_items[0] = sym("let*", loc);
    let_items[1] = .{ .data = .{ .vector = binding }, .location = loc };
    let_items[2] = if_form;
    return list(arena, let_items, loc);
}

// --- if-let / when-let ---
//
// `(if-let [name expr] then else?)` →
//   `(let* [g expr] (if g (let* [name g] then) else))`
// `(when-let [name expr] body...)` →
//   `(if-let [name expr] (do body...) nil)`

fn expandIfLet(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    if (args.len < 2 or args.len > 3)
        return error_catalog.raise(.if_let_form_incomplete, loc, .{});
    if (args[0].data != .vector or args[0].data.vector.len != 2)
        return error_catalog.raise(.if_let_bindings_invalid, args[0].location, .{});

    const binding_v = args[0].data.vector;
    // The binding target may be a plain symbol OR any destructure pattern
    // (`(if-let [[a b] expr] …)` / `(if-let [{:keys [k]} expr] …)`, clj
    // parity): the truthiness test is on the WHOLE expr value (the gensym),
    // and the pattern is destructured only in the `then` branch.

    const name_form = binding_v[0];
    const expr_form = binding_v[1];
    const then_form = args[1];
    const else_form: Form = if (args.len == 3) args[2] else nilForm(loc);

    const gname = try rt.gensym(arena, "if_let");

    // Inner: (let [pattern g] then) — `let` (not `let*`) so a destructuring
    // pattern lowers; a plain-symbol pattern reduces to `let*` (no regression).
    const inner_binding = try arena.alloc(Form, 2);
    inner_binding[0] = name_form;
    inner_binding[1] = sym(gname, loc);
    const inner_let_items = try arena.alloc(Form, 3);
    inner_let_items[0] = sym("let", loc);
    inner_let_items[1] = .{ .data = .{ .vector = inner_binding }, .location = loc };
    inner_let_items[2] = then_form;
    const inner_let = try list(arena, inner_let_items, loc);

    // Outer: (let* [g expr] (if g <inner_let> else))
    return buildShortCircuit(arena, gname, expr_form, inner_let, else_form, loc);
}

// --- defn — top-level function definition ---
//
// `(defn name [params...] body...)` →
//   `(def name (fn* [params...] (do body...)))`
//
// Row 7.8 cycle 3 (ADR-0041) added multi-arity:
// `(defn name ([params...] body...) ([params...] body...) ...)` →
//   `(def name (fn* ([params...] (do body...)) ([params...] (do body...)) ...))`
//
fn expandDefn(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    if (args.len < 2)
        return error_catalog.raise(.defn_form_incomplete, loc, .{});
    if (args[0].data != .symbol or args[0].data.symbol.ns != null)
        return error_catalog.raise(.defn_name_invalid, args[0].location, .{});

    var name_form = args[0];

    // JVM defn: `(defn name doc-string? attr-map? [params] body)` (and the
    // multi-arity equivalent). A leading docstring (string) + attr-map (map)
    // immediately after the name are captured into the Var metadata below
    // (D-183 part d, closes D-091); they no longer drop. A string AFTER the
    // params is the body, not a docstring — this scan only fires at the
    // name+1 position.
    var head: usize = 1;
    var doc_form: ?Form = null;
    var attr_form: ?Form = null;
    if (head < args.len and args[head].data == .string) {
        doc_form = args[head];
        head += 1;
    }
    if (head < args.len and args[head].data == .map) {
        attr_form = args[head];
        head += 1;
    }
    if (head >= args.len)
        return error_catalog.raise(.defn_form_incomplete, loc, .{});
    const body_forms = args[head..];

    // Two body shapes: vector ⇒ single-arity (existing); list ⇒ multi-arity.
    const fn_form = blk: {
        if (body_forms[0].data == .vector) {
            // Empty body (`(defn f [])`) is valid → nil (clj parity);
            // wrapBodyInDo of an empty slice yields `(do)` → nil.
            if (body_forms.len < 1)
                return error_catalog.raise(.defn_form_incomplete, loc, .{});
            const body_form = try wrapBodyInDo(arena, try lowerPrePost(arena, body_forms[1..], loc), loc);
            // D-076 cycle 3: lower destructured params (gensym + body let).
            const r = try transformFnArity(arena, rt, body_forms[0], &.{body_form}, loc);
            var fn_items = try arena.alloc(Form, 2 + r.body.len);
            fn_items[0] = sym("fn*", loc);
            fn_items[1] = r.params;
            @memcpy(fn_items[2..], r.body);
            break :blk try list(arena, fn_items, loc);
        }
        // Multi-arity: every body_forms entry must be a `([params] body...)` list.
        var fn_items = try arena.alloc(Form, 1 + body_forms.len);
        fn_items[0] = sym("fn*", loc);
        for (body_forms, 0..) |arity_form, j| {
            if (arity_form.data != .list)
                return error_catalog.raise(.defn_params_not_vector, arity_form.location, .{});
            const sub = arity_form.data.list;
            // An arity with an empty body (`([])`) is valid → nil (clj parity).
            if (sub.len < 1)
                return error_catalog.raise(.defn_form_incomplete, arity_form.location, .{});
            if (sub[0].data != .vector)
                return error_catalog.raise(.defn_params_not_vector, sub[0].location, .{});
            const body_form = try wrapBodyInDo(arena, try lowerPrePost(arena, sub[1..], arity_form.location), arity_form.location);
            const r = try transformFnArity(arena, rt, sub[0], &.{body_form}, arity_form.location);
            var method_items = try arena.alloc(Form, 1 + r.body.len);
            method_items[0] = r.params;
            @memcpy(method_items[1..], r.body);
            fn_items[1 + j] = try list(arena, method_items, arity_form.location);
        }
        break :blk try list(arena, fn_items, loc);
    };

    // D-183 part (d): build the defn metadata map and park it on the name
    // Form's `.meta` side-channel so `analyzeDef` lifts it into `Var.meta`
    // (closes D-091's silent docstring/attr-map drop). Always carries
    // `:arglists` (the original param vectors); `:doc` when a docstring is
    // present; merges any explicit attr-map. Reader meta already on the
    // name (`(defn ^:private f ...)`) is preserved and merged first.
    name_form.meta = try buildDefnMeta(arena, name_form.meta, doc_form, attr_form, body_forms, loc);

    // (def name (fn* ...))
    const def_items = try arena.alloc(Form, 3);
    def_items[0] = sym("def", loc);
    def_items[1] = name_form;
    def_items[2] = fn_form;
    return list(arena, def_items, loc);
}

/// `(defn- name …)` = `defn` whose Var is `^:private`. Inject `:private true`
/// into the name's reader-meta (merging any existing name meta), then delegate
/// to `expandDefn` — `buildDefnMeta` carries it onto the Var (D-232).
fn expandDefnPrivate(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    if (args.len < 1 or args[0].data != .symbol or args[0].data.symbol.ns != null)
        return error_catalog.raise(.defn_name_invalid, loc, .{});
    var meta_items: std.ArrayList(Form) = .empty;
    if (args[0].meta) |m| try meta_items.appendSlice(arena, m.data.map);
    try meta_items.append(arena, .{ .data = .{ .keyword = .{ .name = "private" } }, .location = loc });
    try meta_items.append(arena, .{ .data = .{ .boolean = true }, .location = loc });
    const meta_form = try arena.create(Form);
    meta_form.* = .{ .data = .{ .map = try arena.dupe(Form, meta_items.items) }, .location = loc };
    const new_args = try arena.dupe(Form, args);
    new_args[0].meta = meta_form;
    return expandDefn(arena, rt, new_args, loc);
}

/// Build the `^meta` map Form for a `defn` target (D-183 part d). Merges,
/// in precedence order (last wins at `mapFormToValue`): existing reader
/// meta on the name → explicit attr-map → `:doc` (docstring) → `:arglists`
/// (the original param vectors, always added — single-arity `([params])`,
/// multi-arity `([p0] [p1] ...)`). `body_forms` is the post-head slice and
/// is already arity-validated by the caller, so `.list`/`[0]` are safe.
fn buildDefnMeta(
    arena: std.mem.Allocator,
    existing: ?*const Form,
    doc_form: ?Form,
    attr_form: ?Form,
    body_forms: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!*const Form {
    var arglist_vecs: std.ArrayList(Form) = .empty;
    if (body_forms[0].data == .vector) {
        try arglist_vecs.append(arena, body_forms[0]);
    } else {
        for (body_forms) |af| try arglist_vecs.append(arena, af.data.list[0]);
    }
    const arglists = try list(arena, arglist_vecs.items, loc);

    var meta_items: std.ArrayList(Form) = .empty;
    if (existing) |m| try meta_items.appendSlice(arena, m.data.map);
    if (attr_form) |a| try meta_items.appendSlice(arena, a.data.map);
    if (doc_form) |d| {
        try meta_items.append(arena, .{ .data = .{ .keyword = .{ .name = "doc" } }, .location = loc });
        try meta_items.append(arena, d);
    }
    try meta_items.append(arena, .{ .data = .{ .keyword = .{ .name = "arglists" } }, .location = loc });
    try meta_items.append(arena, arglists);

    const mp = try arena.create(Form);
    mp.* = .{ .data = .{ .map = try arena.dupe(Form, meta_items.items) }, .location = loc };
    return mp;
}

/// One arity's param-destructuring lowering (D-076 cycle 3, shared by
/// `fn` and `defn`). Pattern params (`[..]` / `{..}`) are replaced by a
/// gensym and the body is wrapped in `(let [pattern gensym ...] body)`,
/// reusing the `let` destructure (cycle 1+2) via recursive macroexpansion
/// — the JVM `fn` shape. Plain-symbol params (incl. `&`) pass through;
/// if no pattern is present the params + body are returned unchanged
/// (zero regression). Caller guarantees `params_vec.data == .vector`.
const ArityLowering = struct { params: Form, body: []const Form };
fn transformFnArity(
    arena: std.mem.Allocator,
    rt: *Runtime,
    params_vec: Form,
    body: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!ArityLowering {
    const params = params_vec.data.vector;
    var new_params: std.ArrayList(Form) = .empty;
    var lets: std.ArrayList(Form) = .empty;
    for (params) |p| {
        switch (p.data) {
            .vector, .map => {
                const g = sym(try rt.gensym(arena, "p"), loc);
                try new_params.append(arena, g);
                try lets.append(arena, p);
                try lets.append(arena, g);
            },
            // Plain symbols (incl. `&`) and anything else pass through —
            // a genuinely-invalid param keeps fn*'s existing error path.
            else => try new_params.append(arena, p),
        }
    }
    if (lets.items.len == 0) return .{ .params = params_vec, .body = body };

    const new_params_vec = try vec(arena, new_params.items, loc);
    var let_items = try arena.alloc(Form, 2 + body.len);
    let_items[0] = sym("let", loc);
    let_items[1] = try vec(arena, lets.items, loc);
    @memcpy(let_items[2..], body);
    const wrapped = try arena.alloc(Form, 1);
    wrapped[0] = try list(arena, let_items, loc);
    return .{ .params = new_params_vec, .body = wrapped };
}

/// `fn` macro: `fn` → `fn*` + param destructuring (D-076 cycle 3). A
/// self-name `(fn name [p] body)` needs an fn* self-name slot (D-147) —
/// raised as a clear transient error, NOT silently dropped. Multi-arity
/// / `& rest` / closures ride fn* (ADR-0041); each arity's pattern params
/// lower via `transformFnArity`.
fn expandFn(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    // Named fn `(fn name [params] body…)` — bind `name` in scope so the body
    // can self-recurse, via letfn*: `(letfn* [name (fn <rest>)] name)`. The
    // inner `(fn …)` re-expands to the anonymous lowering below.
    if (args.len >= 2 and args[0].data == .symbol) {
        const name = args[0];
        var inner_items = try arena.alloc(Form, args.len);
        inner_items[0] = sym("fn", loc);
        @memcpy(inner_items[1..], args[1..]);
        var binding = try arena.alloc(Form, 2);
        binding[0] = name;
        binding[1] = try list(arena, inner_items, loc);
        var letfn_items = try arena.alloc(Form, 3);
        letfn_items[0] = sym("letfn*", loc);
        letfn_items[1] = .{ .data = .{ .vector = binding }, .location = loc };
        letfn_items[2] = name;
        return list(arena, letfn_items, loc);
    }
    if (args.len >= 1 and args[0].data == .symbol)
        return error_catalog.raise(.fn_named_not_supported, args[0].location, .{});

    // Single-arity: `(fn [params] body...)`.
    if (args.len >= 1 and args[0].data == .vector) {
        const r = try transformFnArity(arena, rt, args[0], try lowerPrePost(arena, args[1..], loc), loc);
        var items = try arena.alloc(Form, 2 + r.body.len);
        items[0] = sym("fn*", loc);
        items[1] = r.params;
        @memcpy(items[2..], r.body);
        return list(arena, items, loc);
    }

    // Multi-arity: each `([params] body...)` arity lowered independently.
    var items = try arena.alloc(Form, args.len + 1);
    items[0] = sym("fn*", loc);
    for (args, 0..) |a, i| {
        if (a.data == .list and a.data.list.len >= 1 and a.data.list[0].data == .vector) {
            const sub = a.data.list;
            const r = try transformFnArity(arena, rt, sub[0], try lowerPrePost(arena, sub[1..], a.location), a.location);
            var m = try arena.alloc(Form, 1 + r.body.len);
            m[0] = r.params;
            @memcpy(m[1..], r.body);
            items[i + 1] = try list(arena, m, a.location);
        } else {
            items[i + 1] = a;
        }
    }
    return list(arena, items, loc);
}

fn wrapBodyInDo(arena: std.mem.Allocator, body: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    if (body.len == 1) return body[0];
    const do_items = try arena.alloc(Form, body.len + 1);
    do_items[0] = sym("do", loc);
    @memcpy(do_items[1..], body);
    return list(arena, do_items, loc);
}

/// `(assert cond)` form.
fn assertForm(arena: std.mem.Allocator, cond: Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    var items = try arena.alloc(Form, 2);
    items[0] = sym("assert", loc);
    items[1] = cond;
    return list(arena, items, loc);
}

/// defn/fn `:pre`/`:post` condition-map lowering (clj parity). When an arity's
/// first body form is a MAP literal AND more body follows, that map is a
/// condition map: each `:pre` expr asserts before the body; each `:post` expr
/// asserts after, with `%` bound to the return value. A LONE map body is a
/// return value (clj: only a condition map when more body follows), and a
/// leading map with neither `:pre` nor `:post` is left as an ordinary body
/// expression. Applied to every fn arity (fn / defn / defmacro) so the feature
/// is uniform. Returns the (possibly rewritten) body forms.
fn lowerPrePost(arena: std.mem.Allocator, body: []const Form, loc: SourceLocation) macro_dispatch.ExpandError![]const Form {
    if (body.len < 2 or body[0].data != .map) return body;
    const kvs = body[0].data.map;
    var pre: ?[]const Form = null;
    var post: ?[]const Form = null;
    var i: usize = 0;
    while (i + 1 < kvs.len) : (i += 2) {
        if (kvs[i].data != .keyword or kvs[i + 1].data != .vector) continue;
        const kn = kvs[i].data.keyword.name;
        if (std.mem.eql(u8, kn, "pre")) pre = kvs[i + 1].data.vector;
        if (std.mem.eql(u8, kn, "post")) post = kvs[i + 1].data.vector;
    }
    if (pre == null and post == null) return body; // not a condition map

    const rest = body[1..];
    var out: std.ArrayList(Form) = .empty;
    if (pre) |conds| for (conds) |c| try out.append(arena, try assertForm(arena, c, loc));
    if (post) |conds| {
        // (let* [% (do rest...)] (assert post0) ... %)
        const pct = sym("%", loc);
        var binding = try arena.alloc(Form, 2);
        binding[0] = pct;
        binding[1] = try wrapBodyInDo(arena, rest, loc);
        var let_items: std.ArrayList(Form) = .empty;
        try let_items.append(arena, sym("let*", loc));
        try let_items.append(arena, .{ .data = .{ .vector = binding }, .location = loc });
        for (conds) |c| try let_items.append(arena, try assertForm(arena, c, loc));
        try let_items.append(arena, pct);
        try out.append(arena, try list(arena, let_items.items, loc));
    } else {
        try out.appendSlice(arena, rest);
    }
    return out.items;
}

// --- defmulti — multimethod definition (ADR-0008 Phase 7.2 amendment, Alt 1) ---
//
// `(defmulti name dispatch-fn)` →
//   `(def name (rt/__make-multifn (quote name) dispatch-fn :default -global-hierarchy))`
//
// JVM Clojure's `defmulti` macro has additional re-eval-no-op
// semantics (preserves method_table across REPL reloads). cw v1
// omits this; re-eval clobbers. Restoring the no-op requires
// `resolved?` + `multi-fn?` predicates (D-184).
fn expandDefmulti(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len < 2)
        return error_catalog.raise(.defmulti_form_incomplete, loc, .{});
    if (args[0].data != .symbol or args[0].data.symbol.ns != null)
        return error_catalog.raise(.defmulti_name_invalid, args[0].location, .{});

    var name_form = args[0];
    // clj grammar: `(defmulti name docstring? attr-map? dispatch-fn & options)`.
    // Consume an optional leading docstring (string) then attr-map (map) before
    // the dispatch fn — else the docstring is mistaken for the dispatch fn and a
    // dispatch call raises "Cannot call value of type 'string'" (integrant's
    // `assert-key` has both a docstring and an `{:arglists …}` attr-map). The
    // docstring + attr-map are ATTACHED to the Var's metadata (not discarded),
    // so `(:doc (meta (var m)))` / `(:arglists …)` match clj.
    var di: usize = 1;
    var doc_form: ?Form = null;
    var attr_form: ?Form = null;
    if (di < args.len and args[di].data == .string) {
        doc_form = args[di];
        di += 1;
    }
    if (di < args.len and args[di].data == .map) {
        attr_form = args[di];
        di += 1;
    }
    if (di >= args.len)
        return error_catalog.raise(.defmulti_form_incomplete, loc, .{});
    const dispatch_fn_form = args[di];

    // Park the docstring + attr-map onto the name Form's `.meta` side-channel so
    // `analyzeDef` lifts them into `Var.meta` (same path `defn` uses). clj's
    // defmulti does NOT synthesize `:arglists` (unlike defn), so we only carry
    // the explicit attr-map + `:doc`.
    if (doc_form != null or attr_form != null or name_form.meta != null) {
        var meta_items: std.ArrayList(Form) = .empty;
        if (name_form.meta) |m| try meta_items.appendSlice(arena, m.data.map);
        if (attr_form) |a| try meta_items.appendSlice(arena, a.data.map);
        if (doc_form) |d| {
            try meta_items.append(arena, .{ .data = .{ .keyword = .{ .name = "doc" } }, .location = loc });
            try meta_items.append(arena, d);
        }
        const mp = try arena.create(Form);
        mp.* = .{ .data = .{ .map = try arena.dupe(Form, meta_items.items) }, .location = loc };
        name_form.meta = mp;
    }

    // Trailing options after the dispatch fn (clj: `:default <val>` overrides
    // the no-match dispatch value, `:hierarchy <h>` swaps the hierarchy var).
    // Inline key/value pairs; unknown keys are ignored (forward-compatible).
    var default_form: Form = .{ .data = .{ .keyword = .{ .ns = null, .name = "default" } }, .location = loc };
    var hierarchy_form: Form = sym("-global-hierarchy", loc);
    var oi: usize = di + 1;
    while (oi + 1 < args.len) : (oi += 2) {
        const opt = args[oi];
        if (opt.data == .keyword and opt.data.keyword.ns == null) {
            if (std.mem.eql(u8, opt.data.keyword.name, "default")) {
                default_form = args[oi + 1];
            } else if (std.mem.eql(u8, opt.data.keyword.name, "hierarchy")) {
                hierarchy_form = args[oi + 1];
            }
        }
    }

    // (quote name)
    var quote_items = try arena.alloc(Form, 2);
    quote_items[0] = sym("quote", loc);
    quote_items[1] = name_form;
    const quoted_name = try list(arena, quote_items, loc);

    // (rt/__make-multifn (quote name) dispatch-fn <default> <hierarchy>)
    // The bare `-global-hierarchy` symbol resolves to the public atom in the
    // calling ns (referred from clojure.core at boot) so dispatch consults the
    // live, mutable hierarchy — `derive` after `defmulti` is seen (D-161).
    var call_items = try arena.alloc(Form, 5);
    call_items[0] = .{ .data = .{ .symbol = .{ .ns = "rt", .name = "__make-multifn" } }, .location = loc };
    call_items[1] = quoted_name;
    call_items[2] = dispatch_fn_form;
    call_items[3] = default_form;
    call_items[4] = hierarchy_form;
    const call_form = try list(arena, call_items, loc);

    // (def name call_form)
    var def_items = try arena.alloc(Form, 3);
    def_items[0] = sym("def", loc);
    def_items[1] = name_form;
    def_items[2] = call_form;
    return list(arena, def_items, loc);
}

// --- defmethod — register a method on a multimethod ---
//
// `(defmethod multifn dispatch-val [params...] body...)` →
//   `(rt/__add-method! multifn dispatch-val (fn* [params...] body...))`
//
// Multi-form body wraps in `(do ...)` per the defn pattern.
fn expandDefmethod(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    // multifn + dispatch-val + params vector are required; the body is OPTIONAL
    // (clj: `(defmethod m dv [params])` defines a method returning nil).
    if (args.len < 3)
        return error_catalog.raise(.defmethod_form_incomplete, loc, .{});
    if (args[2].data != .vector)
        return error_catalog.raise(.defmethod_params_not_vector, args[2].location, .{});

    const multi_form = args[0];
    const dispatch_val_form = args[1];
    const params_form = args[2];
    const body = args[3..];

    const body_form = if (body.len == 0) nilForm(loc) else if (body.len == 1) body[0] else blk: {
        var do_items = try arena.alloc(Form, body.len + 1);
        do_items[0] = sym("do", loc);
        @memcpy(do_items[1..], body);
        break :blk try list(arena, do_items, loc);
    };

    // (fn params_form body_form) — `fn` (not `fn*`) so a destructuring
    // method param (`(defmethod m :k [a [b c]] …)`) is lowered (clj parity;
    // clojure.test-helper's `assert-expr` methods destructure their args).
    var fn_items = try arena.alloc(Form, 3);
    fn_items[0] = sym("fn", loc);
    fn_items[1] = params_form;
    fn_items[2] = body_form;
    const fn_form = try list(arena, fn_items, loc);

    // (rt/__add-method! multi dispatch-val fn_form)
    var call_items = try arena.alloc(Form, 4);
    call_items[0] = .{ .data = .{ .symbol = .{ .ns = "rt", .name = "__add-method!" } }, .location = loc };
    call_items[1] = multi_form;
    call_items[2] = dispatch_val_form;
    call_items[3] = fn_form;
    return list(arena, call_items, loc);
}

// (prefer-method was a needless macro — it auto-quoted nothing, just forwarded to
// `rt/__prefer-method!`. D-373 made it a clj-faithful FN in core.clj so it is
// passable in higher-order position, matching clj. The macro is retired.)

// --- defprotocol — declare a protocol name + its method dispatch fns ---
//
// `(defprotocol P (m1 [x]) (m2 [x y]))` lowers to:
//   (do
//     (def P (rt/__make-protocol! 'P ['m1 'm2]))
//     (def m1 (rt/__make-protocol-fn! P "m1"))
//     (def m2 (rt/__make-protocol-fn! P "m2")))
//
// Each method-sig is `(method-name [params...])` — arity defaults
// to 1 inside `__make-protocol!`; the param vector is consumed for
// shape-validation only. ADR-0038 (analyzer pre-registers Var at
// analyze time) lets the second-and-subsequent `def` forms
// reference `P` cleanly.
fn expandDefprotocol(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    // A name suffices; method signatures are optional so a zero-method
    // marker protocol — `(defprotocol Sequential)` — is definable, matching
    // JVM (`(defprotocol Marker)` → `(satisfies? Marker x)` true). The empty
    // `method_sigs` expands to `(rt/__make-protocol! 'name [])` (D-190/ADR-0068).
    if (args.len < 1)
        return error_catalog.raise(.defprotocol_form_incomplete, loc, .{});
    if (args[0].data != .symbol or args[0].data.symbol.ns != null)
        return error_catalog.raise(.defprotocol_name_invalid, args[0].location, .{});

    const name_form = args[0];
    // Optional protocol-level docstring, then optional `:keyword value` option
    // pairs (clj parity): `(defprotocol P "doc" :extend-via-metadata true (m [a])
    // …)`. Method sigs are lists, options are keywords, so skip a leading string
    // then consume keyword/value pairs before reading sigs. `:extend-via-metadata
    // true` is captured and threaded to the descriptor so receiver-metadata
    // dispatch is honored (ADR-0144 / D-314); other options are parsed-to-load.
    var sig_start: usize = 1;
    if (sig_start < args.len and args[sig_start].data == .string) sig_start += 1;
    var extend_via_metadata = false;
    while (sig_start + 1 < args.len and args[sig_start].data == .keyword) : (sig_start += 2) {
        const opt = args[sig_start];
        if (opt.data.keyword.ns == null and std.mem.eql(u8, opt.data.keyword.name, "extend-via-metadata")) {
            const val = args[sig_start + 1];
            extend_via_metadata = if (val.data == .boolean) val.data.boolean else true;
        }
    }
    const method_sigs = args[sig_start..];

    // Collect each method-name Symbol from `(method-name [params])`.
    const method_names = try arena.alloc(Form, method_sigs.len);
    for (method_sigs, 0..) |sig, i| {
        if (sig.data != .list or sig.data.list.len < 1 or sig.data.list[0].data != .symbol)
            return error_catalog.raise(.defprotocol_method_invalid, sig.location, .{});
        method_names[i] = sig.data.list[0];
    }

    // Build `['m1 'm2 ...]` — each entry is (quote method-name) so
    // it evaluates to a Symbol Value at runtime (the cycle 6
    // `__make-protocol!` primitive iterates a Vector of method-name
    // Symbols).
    const quoted_methods = try arena.alloc(Form, method_names.len);
    for (method_names, 0..) |m, i| {
        var q = try arena.alloc(Form, 2);
        q[0] = sym("quote", loc);
        q[1] = m;
        quoted_methods[i] = try list(arena, q, loc);
    }
    const methods_vec = try vec(arena, quoted_methods, loc);

    // (quote name)
    var quoted_name_items = try arena.alloc(Form, 2);
    quoted_name_items[0] = sym("quote", loc);
    quoted_name_items[1] = name_form;
    const quoted_name = try list(arena, quoted_name_items, loc);

    // (rt/__make-protocol! 'name [method-quotes] <extend-via-metadata?>) — the
    // 3rd arg is emitted only when the flag is set; the primitive defaults it to
    // false for the 2-arg bootstrap forms (ADR-0144 / D-314).
    const make_proto_len: usize = if (extend_via_metadata) 4 else 3;
    var make_proto_items = try arena.alloc(Form, make_proto_len);
    make_proto_items[0] = .{ .data = .{ .symbol = .{ .ns = "rt", .name = "__make-protocol!" } }, .location = loc };
    make_proto_items[1] = quoted_name;
    make_proto_items[2] = methods_vec;
    if (extend_via_metadata) make_proto_items[3] = .{ .data = .{ .boolean = true }, .location = loc };
    const make_proto_call = try list(arena, make_proto_items, loc);

    // (def name (rt/__make-protocol! ...))
    var def_proto_items = try arena.alloc(Form, 3);
    def_proto_items[0] = sym("def", loc);
    def_proto_items[1] = name_form;
    def_proto_items[2] = make_proto_call;
    const def_proto = try list(arena, def_proto_items, loc);

    // For each method: (def m-name (rt/__make-protocol-fn! name "m-name"))
    const method_defs = try arena.alloc(Form, method_names.len);
    for (method_names, 0..) |m, i| {
        var make_fn_items = try arena.alloc(Form, 3);
        make_fn_items[0] = .{ .data = .{ .symbol = .{ .ns = "rt", .name = "__make-protocol-fn!" } }, .location = loc };
        make_fn_items[1] = name_form;
        make_fn_items[2] = .{ .data = .{ .string = m.data.symbol.name }, .location = loc };
        const make_fn_call = try list(arena, make_fn_items, loc);

        var def_fn_items = try arena.alloc(Form, 3);
        def_fn_items[0] = sym("def", loc);
        def_fn_items[1] = m;
        def_fn_items[2] = make_fn_call;
        method_defs[i] = try list(arena, def_fn_items, loc);
    }

    // (do def-proto def-method-1 def-method-2 ... 'Name) — clj's defprotocol
    // RETURNS the protocol-name symbol (D-456), so the do's trailing form is
    // `(quote Name)`. Without it the do returned the last method's `def` (a
    // var, `#'ns/m`); the return value is rarely consumed but this is clj parity.
    var do_items = try arena.alloc(Form, 3 + method_defs.len);
    do_items[0] = sym("do", loc);
    do_items[1] = def_proto;
    @memcpy(do_items[2 .. 2 + method_defs.len], method_defs);
    var ret_quote_items = try arena.alloc(Form, 2);
    ret_quote_items[0] = sym("quote", loc);
    ret_quote_items[1] = name_form;
    do_items[do_items.len - 1] = try list(arena, ret_quote_items, loc);
    return list(arena, do_items, loc);
}

// --- extend-type — install one or more method impls on a TypeDescriptor ---
//
// `(extend-type Foo P (m1 [x] body1) (m2 [x] body2))` lowers to:
//   (rt/__extend-type! Foo P [["m1" (fn* [x] body1)] ["m2" (fn* [x] body2)]])
//
// Each method-impl is `(method-name [params...] body...)` — same
// shape as defmethod's clauses.
/// Rewrite a `protocol_remap` interface section (D-280) into bare cljw-protocol
/// section(s). Each declared clj method is translated to its (cljw-protocol,
/// cljw-method) target and the impls are regrouped by target protocol — clj
/// groups methods by interface, but cljw dispatch matches (protocol, method)
/// strictly, so e.g. clj `IPersistentMap`'s `count` must register under cljw
/// `IPersistentCollection`/`-count`. Emits a single `(extend-type Name <proto>
/// ...)` (one target) or `(do ...)` of several; each re-expands through
/// `expandExtendType` (arity-grouped + registered) on the next pass. Shared by
/// the deftype/defrecord/extend-type paths.
fn rewriteProtocolRemap(
    arena: std.mem.Allocator,
    hi: host_interface.HostInterface,
    declared_name: []const u8,
    target_form: Form,
    impls: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    // Zero impls = a marker-style "implements X" under the declared name
    // (a recognised MARKERS key by construction; `hi.canonical` may be a
    // bare spelling that is NOT a key, e.g. Counted). Quote-wrapped like the
    // D-275 marker path — a bare symbol would Var-resolve to the interface's
    // CLASS value and fail __extend-type!'s "expected protocol" check.
    if (impls.len == 0) {
        var ext_items = try arena.alloc(Form, 3);
        ext_items[0] = sym("extend-type", loc);
        ext_items[1] = target_form;
        ext_items[2] = try quoteWrap(arena, sym(declared_name, loc));
        return list(arena, ext_items, loc);
    }

    // Validate + collect distinct target cljw protocols in first-seen order.
    var protos: std.ArrayList([]const u8) = .empty;
    defer protos.deinit(arena);
    for (impls) |impl| {
        // len < 2 (no name+params) is malformed; an EMPTY body (len == 2) is
        // valid clj — the method returns nil (body lowers to `(do)` → nil).
        if (impl.data != .list or impl.data.list.len < 2 or
            impl.data.list[0].data != .symbol or impl.data.list[1].data != .vector)
        {
            return error_catalog.raise(.extend_type_method_invalid, impl.location, .{});
        }
        const clj_m = impl.data.list[0].data.symbol.name;
        const r = hi.remapMethod(clj_m) orelse {
            // A java.util.Map/Iterable method grouped under this clojure.lang section
            // (D-372): cljw has no java dispatch, so accept-and-DROP it (load-level,
            // the ADR-0103 host_inert principle applied to the grouped-method case)
            // instead of feature_not_supported. ordered.map groups iterator/entrySet
            // under IPersistentMap. A genuinely-unwired clojure.lang method still raises.
            if (host_interface.isJavaUtilMethod(clj_m)) continue;
            return error_catalog.raise(.feature_not_supported, impl.location, .{ .name = "deftype/reify clojure.lang.* method not yet wired" });
        };
        var seen = false;
        for (protos.items) |p| {
            if (std.mem.eql(u8, p, r.protocol)) {
                seen = true;
                break;
            }
        }
        if (!seen) try protos.append(arena, r.protocol);
    }

    // One bare-protocol section per target protocol, plus a trailing
    // zero-method marker registration of the DECLARED canonical name — the
    // remapped methods register under OTHER protocol names (IPersistentMap's
    // count → IPersistentCollection/-count), so without this the descriptor
    // never records "implements IPersistentMap" and `(instance?
    // clojure.lang.IPersistentMap inst)` is false (data.priority-map's
    // class facet; clj-faithful: the deftype implements the interface).
    var sections = try arena.alloc(Form, protos.items.len + 1);
    {
        var decl_items = try arena.alloc(Form, 3);
        decl_items[0] = sym("extend-type", loc);
        decl_items[1] = target_form;
        decl_items[2] = try quoteWrap(arena, sym(declared_name, loc));
        sections[protos.items.len] = try list(arena, decl_items, loc);
    }
    for (protos.items, 0..) |proto, si| {
        var sec: std.ArrayList(Form) = .empty;
        defer sec.deinit(arena);
        try sec.append(arena, sym("extend-type", loc));
        try sec.append(arena, target_form);
        try sec.append(arena, sym(proto, loc));
        for (impls) |impl| {
            // A dropped java.util method (loop above) has no remap → skip it here too.
            const r = hi.remapMethod(impl.data.list[0].data.symbol.name) orelse continue;
            if (!std.mem.eql(u8, r.protocol, proto)) continue;
            // Translate the method head (clj → cljw); keep params + body verbatim.
            var timpl_items = try arena.alloc(Form, impl.data.list.len);
            @memcpy(timpl_items, impl.data.list);
            timpl_items[0] = sym(r.method, impl.location);
            try sec.append(arena, try list(arena, timpl_items, impl.location));
            // D-283: when the clj name was translated (assoc→-assoc), ALSO register
            // the impl under the ORIGINAL clj name so a `.cljname` dot-call resolves
            // it — `(.member recv)` looks up by BARE name (lookupMethod(null, name)),
            // and a deftype's own body calls `.assoc`/`.valAt` on itself (priority-map
            // does). Core fns find the cljw name; dot-calls find the clj name; the two
            // entries don't cross (different names). Skip when no translation happened
            // (Object method-family keeps its clj name → already dot-callable).
            if (!std.mem.eql(u8, impl.data.list[0].data.symbol.name, r.method)) {
                try sec.append(arena, impl);
            }
        }
        sections[si] = try list(arena, sec.items, loc);
    }

    if (sections.len == 1) return sections[0];
    var do_items = try arena.alloc(Form, 1 + sections.len);
    do_items[0] = sym("do", loc);
    @memcpy(do_items[1..], sections);
    return list(arena, do_items, loc);
}

/// Strip a namespace qualifier from each simple-symbol param in a deftype /
/// reify / extend-type method param vector. Inside a syntax-quote the reader
/// qualifies a bare param symbol like `_` to `user/_`; clj's deftype / reify
/// strip the ns for method params (a raw `fn*` still rejects a qualified param
/// — that parity is preserved, this only relaxes the host-method lowering).
/// Common in macros that emit deftype methods via backtick (e.g.
/// data.finger-tree's `defdigit`). Returns the input unchanged when no param
/// is qualified (the overwhelming common case — no allocation).
fn stripMethodParamNs(arena: std.mem.Allocator, params_form: Form) macro_dispatch.ExpandError!Form {
    if (params_form.data != .vector) return params_form;
    const params = params_form.data.vector;
    var needs_copy = false;
    for (params) |p| {
        if (p.data == .symbol and p.data.symbol.ns != null) {
            needs_copy = true;
            break;
        }
    }
    if (!needs_copy) return params_form;
    const out = try arena.alloc(Form, params.len);
    for (params, 0..) |p, i| {
        out[i] = if (p.data == .symbol and p.data.symbol.ns != null)
            .{ .data = .{ .symbol = .{ .ns = null, .name = p.data.symbol.name } }, .location = p.location }
        else
            p;
    }
    return .{ .data = .{ .vector = out }, .location = params_form.location };
}

/// Whether a `protocol_remap` section is a FIRST pass (declared clj methods that
/// still need translation) vs the SECOND pass over a SELF-targeting section the
/// rewrite already emitted. Routing the second pass back through the rewrite would
/// loop forever: the rewrite translates `disjoin`→`-disjoin` AND (D-283) dual-emits
/// the original `disjoin` for `.dot` calls, so a self-targeting section
/// (IPersistentSet/ITransient*) comes back carrying BOTH `-disjoin` (identity) and
/// `disjoin` (re-translatable) → infinite recursion / stack-overflow segfault.
/// Rule: if the section carries ANY already-cljw (identity) method, it is the
/// rewrite's own output → do NOT re-route; the bare-protocol-Var arm registers both
/// spellings directly. Only an all-clj-names section (no identity) is a first pass.
/// An unknown method (no remap entry) routes so `rewriteProtocolRemap` raises the
/// precise `feature_not_supported`. (D-286b)
fn sectionNeedsRemap(hi: host_interface.HostInterface, impls: []const Form) bool {
    // A ZERO-method section must route: the rewrite emits the quote-wrapped
    // marker registration (a bare protocol_remap symbol would Var-resolve to
    // the interface's class value and fail __extend-type!).
    if (impls.len == 0) return true;
    var any_translate = false;
    for (impls) |impl| {
        if (impl.data != .list or impl.data.list.len < 1 or impl.data.list[0].data != .symbol) continue;
        const m = impl.data.list[0].data.symbol.name;
        // A cljw-direct method spelling (`-seq`, `-cons`, `-peek`) is cljw core's
        // own protocol-Var impl declared under a bare name that ALSO carries a
        // protocol_remap row (Seqable / IPersistentCollection / IPersistentStack /
        // … — the D-416 bare aliases). The remap table only keys clj names
        // (`seq`/`cons`/`peek`), so a `-`-prefixed method is already in target
        // form ⇒ do NOT route; fall through to the bare protocol-Var arm exactly
        // as before the aliases existed. clj/Java interface method names never
        // start with `-`, so the prefix is an unambiguous clj-vs-cljw signal. This
        // is what lets core's `(extend-type X Seqable (-seq …))` and a lib's
        // `(deftype Y … Seqable (seq …))` share the one bare `Seqable`. (D-286b)
        if (m.len > 0 and m[0] == '-') return false;
        const r = hi.remapMethod(m) orelse return true;
        // Identity = unchanged method name AND already under the interface's OWN
        // protocol (a self-targeting method the rewrite emitted) ⇒ second pass, skip.
        // A same-NAME-but-different-PROTOCOL remap (IHashEq `hasheq`→Object/hasheq,
        // IPersistentSet `equiv`→Object/equiv) is NOT identity — it still retargets,
        // so the section is a first pass that must route.
        if (std.mem.eql(u8, r.method, m) and std.mem.eql(u8, r.protocol, hi.canonical)) return false;
        any_translate = true;
    }
    return any_translate;
}

/// True iff `impl` is a GROUPED multi-arity method form `(name ([p] b) ([p] b) …)`:
/// a list whose 2nd element is itself a list starting with a params VECTOR. The
/// single-arity form `(name [p] b)` has a params vector DIRECTLY as the 2nd
/// element, so the two are distinguishable by the 2nd element's tag.
fn isGroupedArity(impl: Form) bool {
    return impl.data == .list and impl.data.list.len >= 2 and
        impl.data.list[0].data == .symbol and impl.data.list[1].data == .list and
        impl.data.list[1].data.list.len >= 1 and impl.data.list[1].data.list[0].data == .vector;
}

/// clj's `extend-type`/`extend-protocol` accept a GROUPED multi-arity method
/// spelling — `(g ([x] b1) ([x y] b2))` — in addition to the repeated single-arity
/// `(g [x] b1) (g [x y] b2)`. Expand each grouped impl into one repeated impl per
/// arity-clause so `expandExtendType`'s multi-arity-`fn*` grouping (D-279) folds
/// both spellings identically (D-469). Non-grouped impls pass through untouched.
fn expandGroupedArities(arena: std.mem.Allocator, impls: []const Form) macro_dispatch.ExpandError![]const Form {
    var any = false;
    for (impls) |impl| {
        if (isGroupedArity(impl)) {
            any = true;
            break;
        }
    }
    if (!any) return impls;
    var out: std.ArrayList(Form) = .empty;
    for (impls) |impl| {
        if (!isGroupedArity(impl)) {
            try out.append(arena, impl);
            continue;
        }
        const name_sym = impl.data.list[0];
        for (impl.data.list[1..]) |clause| {
            // clause = ([params] body...) → (name [params] body...)
            var items = try arena.alloc(Form, 1 + clause.data.list.len);
            items[0] = name_sym;
            @memcpy(items[1..], clause.data.list);
            try out.append(arena, try list(arena, items, impl.location));
        }
    }
    return try out.toOwnedSlice(arena);
}

fn expandExtendType(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    // target + protocol minimum; zero method-impls is a MARKER protocol
    // extension (e.g. `Sequential`), recorded into `protocol_impls` by
    // `__extend-type!` (D-190 / ADR-0068).
    if (args.len < 2)
        return error_catalog.raise(.extend_type_form_incomplete, loc, .{});

    const target_form = args[0];

    // Extending a protocol TO a host_inert java interface (`(extend-protocol P
    // java.util.Map …)`, as hiccup.util does) is a load-only NO-OP: no cljw value
    // has that host type (ADR-0103 / ADR-0059), so the impl could never dispatch —
    // F-011-faithful for a never-instantiated target, and the documented AD (cljw
    // does not implement java.util.Map dispatch). Mirrors __extend-type!'s
    // isKnownOpaqueClass early-return, applied at the TARGET position (where the
    // marker is NOT quote-wrapped, unlike the PROTOCOL position below).
    if (target_form.data == .symbol and host_interface.isHostInert(target_form.data.symbol.name)) {
        return Form{ .data = .nil, .location = loc };
    }

    // A clj interface whose cljw implementors are NATIVE values
    // (`clojure.lang.IPersistentVector` → vector, `ISeq` → the seq family,
    // `Named` → keyword/symbol) distributes the impl over each native tag's
    // descriptor via `rt/__native-type`, so a cljw vector/seq/named value
    // dispatches the protocol (the core hiccup `(html [:p …])` path). Only a
    // single-protocol section reaches here (the multi-section split is below and
    // requires a symbol target), so `args[1..]` is `proto impls…`.
    if (target_form.data == .symbol) {
        if (host_interface.nativeExtendTags(target_form.data.symbol.name)) |tags| {
            var sections = try arena.alloc(Form, tags.len + 1);
            sections[0] = sym("do", loc);
            for (tags, 0..) |tag, ti| {
                var nt_items = try arena.alloc(Form, 2);
                nt_items[0] = .{ .data = .{ .symbol = .{ .ns = "rt", .name = "__native-type" } }, .location = loc };
                nt_items[1] = .{ .data = .{ .keyword = .{ .name = tag } }, .location = loc };
                const nt = try list(arena, nt_items, loc);
                var ext_items = try arena.alloc(Form, 3 + (args.len - 2));
                ext_items[0] = sym("extend-type", loc);
                ext_items[1] = nt;
                ext_items[2] = args[1];
                @memcpy(ext_items[3..], args[2..]);
                sections[ti + 1] = try list(arena, ext_items, loc);
            }
            return list(arena, sections, loc);
        }
    }

    // D-292: multiple protocol sections in ONE extend-type
    // (`(extend-type T P1 (m..) P2 (m..))`, as clj allows + tools.reader uses).
    // Split into per-protocol `(extend-type T Pi impls...)` forms under a `do`;
    // each re-expands through this fn as a single-protocol section (deftype
    // lowering + extend-protocol already split this way). Detect by a second
    // protocol symbol after the first section's method-impl lists.
    if (args.len > 2 and args[1].data == .symbol) {
        var k: usize = 2;
        while (k < args.len and args[k].data == .list) : (k += 1) {}
        if (k < args.len) {
            var sections: std.ArrayList(Form) = .empty;
            defer sections.deinit(arena);
            var i: usize = 1;
            while (i < args.len) {
                if (args[i].data != .symbol)
                    return error_catalog.raise(.extend_type_method_invalid, args[i].location, .{});
                const proto = args[i];
                i += 1;
                const start = i;
                while (i < args.len and args[i].data == .list) : (i += 1) {}
                const impls = args[start..i];
                var ext_items = try arena.alloc(Form, 3 + impls.len);
                ext_items[0] = sym("extend-type", proto.location);
                ext_items[1] = target_form;
                ext_items[2] = proto;
                @memcpy(ext_items[3..], impls);
                try sections.append(arena, try list(arena, ext_items, proto.location));
            }
            var do_items = try arena.alloc(Form, sections.items.len + 1);
            do_items[0] = sym("do", loc);
            @memcpy(do_items[1..], sections.items);
            return list(arena, do_items, loc);
        }
    }

    // protocol_remap (D-280): a `clojure.lang.*` interface whose methods route to
    // cljw protocols (e.g. ILookup `valAt` → ILookup/`-lookup`; clj groups methods
    // by interface but cljw splits them across protocols). Rewrite the section into
    // bare cljw-protocol section(s): translate each clj method to its (protocol,
    // method) target, regroup by target protocol, emit `(do (extend-type Name
    // <cljw-proto> <translated-impls>) ...)`. Those re-expand through this fn
    // (arity-grouped there); the primitive never sees the qualified name.
    if (args[1].data == .symbol and host_interface.isProtocolRemap(args[1].data.symbol.name)) {
        const hi = host_interface.lookup(args[1].data.symbol.name).?;
        // Only rewrite when a method actually translates (clj-name → a DIFFERENT
        // cljw -method). When every impl is ALREADY in cljw target form, this is the
        // SECOND pass over a section the rewrite itself emitted for a SELF-targeting
        // interface (D-286b: IPersistentSet's `disjoin` → IPersistentSet/`-disjoin`,
        // ITransientSet's `disjoin` → ITransientSet/`-disjoin!`). The interface's bare
        // name is in the remap table (so the deftype-supertype position routes here),
        // so without this guard the emitted `(extend-type Name IPersistentSet
        // (-disjoin …))` would re-route and translate `-disjoin` → `-disjoin` forever
        // (the segfault-by-stack-overflow this guard fixes). Falling through lets the
        // already-cljw method register under the bare protocol Var directly.
        if (sectionNeedsRemap(hi, args[2..])) {
            return try rewriteProtocolRemap(arena, hi, args[1].data.symbol.name, target_form, args[2..], loc);
        }
    }

    // A host-supertype marker (`Object`, D-275) is quote-wrapped so the analyzer
    // never Var-resolves it (Path A, the `instance?` / `reify` precedent). This
    // arm also covers the `deftype`/`defrecord` paths, whose protocol sections
    // re-expand through `expandExtendType`. A cljw protocol name stays bare.
    const protocol_form = if (args[1].data == .symbol and host_interface.isMarker(args[1].data.symbol.name))
        try quoteWrap(arena, args[1])
    else
        args[1];
    // D-469: normalise the grouped multi-arity spelling `(g ([x] b1) ([x y] b2))`
    // into repeated single-arity impls before validation, so the multi-arity-fn*
    // grouping below folds both spellings identically.
    const method_impls = try expandGroupedArities(arena, args[2..]);

    // Validate every impl + collect distinct method names in first-seen order.
    // A clj interface section may declare ONE method at multiple arities
    // (e.g. ILookup `(valAt [this k]) (valAt [this k nf])`, D-279); these are
    // grouped into a single multi-arity `fn*` below so they coexist under one
    // (protocol, method) method_table entry and dispatch by arg count.
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(arena);
    for (method_impls) |impl| {
        // EMPTY body (len == 2) is valid clj (method → nil); only < 2 is malformed.
        if (impl.data != .list or impl.data.list.len < 2 or
            impl.data.list[0].data != .symbol or
            impl.data.list[1].data != .vector)
        {
            return error_catalog.raise(.extend_type_method_invalid, impl.location, .{});
        }
        const method_name = impl.data.list[0].data.symbol.name;
        var seen = false;
        for (names.items) |n| {
            if (std.mem.eql(u8, n, method_name)) {
                seen = true;
                break;
            }
        }
        if (!seen) try names.append(arena, method_name);
    }

    const impl_pairs = try arena.alloc(Form, names.items.len);
    for (names.items, 0..) |method_name, gi| {
        // Gather every impl for this method name as a `([params] body)` clause.
        var clauses: std.ArrayList(Form) = .empty;
        defer clauses.deinit(arena);
        var name_loc = loc;
        for (method_impls) |impl| {
            if (!std.mem.eql(u8, impl.data.list[0].data.symbol.name, method_name)) continue;
            const stripped = try stripMethodParamNs(arena, impl.data.list[1]);
            // Lower destructured method params (clj parity) — see expandReify.
            const lowered = try transformFnArity(arena, rt, stripped, impl.data.list[2..], impl.location);
            const params_form = lowered.params;
            const body = lowered.body;
            const body_form = if (body.len == 1) body[0] else blk: {
                var do_items = try arena.alloc(Form, body.len + 1);
                do_items[0] = sym("do", impl.location);
                @memcpy(do_items[1..], body);
                break :blk try list(arena, do_items, impl.location);
            };
            if (clauses.items.len == 0) name_loc = impl.location;
            // ([params] body) — a single multi-arity clause
            var clause_items = try arena.alloc(Form, 2);
            clause_items[0] = params_form;
            clause_items[1] = body_form;
            try clauses.append(arena, try list(arena, clause_items, impl.location));
        }

        const fn_form = if (clauses.items.len == 1) blk: {
            // (fn* params body) — single arity (the common case, unchanged shape)
            const cl = clauses.items[0].data.list;
            var fn_items = try arena.alloc(Form, 3);
            fn_items[0] = sym("fn*", name_loc);
            fn_items[1] = cl[0];
            fn_items[2] = cl[1];
            break :blk try list(arena, fn_items, name_loc);
        } else blk: {
            // (fn* ([p1] b1) ([p2] b2) ...) — multi-arity (D-279)
            var fn_items = try arena.alloc(Form, 1 + clauses.items.len);
            fn_items[0] = sym("fn*", name_loc);
            @memcpy(fn_items[1..], clauses.items);
            break :blk try list(arena, fn_items, name_loc);
        };

        // ["method-name" fn-form]
        var pair_items = try arena.alloc(Form, 2);
        pair_items[0] = .{ .data = .{ .string = method_name }, .location = name_loc };
        pair_items[1] = fn_form;
        impl_pairs[gi] = try vec(arena, pair_items, name_loc);
    }
    const impls_vec = try vec(arena, impl_pairs, loc);

    // (rt/__extend-type! target protocol impls_vec)
    var call_items = try arena.alloc(Form, 4);
    call_items[0] = .{ .data = .{ .symbol = .{ .ns = "rt", .name = "__extend-type!" } }, .location = loc };
    call_items[1] = target_form;
    call_items[2] = protocol_form;
    call_items[3] = impls_vec;
    return list(arena, call_items, loc);
}

// --- extend-protocol — distribute one protocol over many types ---
//
// `(extend-protocol P
//    Foo (m1 [x] ...) (m2 [x] ...)
//    Bar (m1 [y] ...))`
// lowers to:
//   (do
//     (extend-type Foo P (m1 [x] ...) (m2 [x] ...))
//     (extend-type Bar P (m1 [y] ...)))
//
// Sections are grouped by leading type-symbol; method-impl lists
// belong to the most-recent type-symbol section.
fn expandExtendProtocol(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len < 3)
        return error_catalog.raise(.extend_protocol_form_incomplete, loc, .{});

    const protocol_form = args[0];

    // Walk args[1..]; a type head (symbol, OR a `nil` literal for the nil type
    // per clj nil-punning) opens a new section, list forms append method-impls
    // to the current section. The generated `(extend-type <head> …)` re-expands
    // through expandExtendType, which already passes a nil target to
    // __extend-type! (resolved to the nil descriptor there).
    if (args[1].data != .symbol and args[1].data != .nil)
        return error_catalog.raise(.extend_protocol_section_invalid, args[1].location, .{});

    var sections: std.ArrayList(Form) = .empty;
    defer sections.deinit(arena);

    var i: usize = 1;
    while (i < args.len) {
        if (args[i].data != .symbol and args[i].data != .nil)
            return error_catalog.raise(.extend_protocol_section_invalid, args[i].location, .{});
        const type_form = args[i];
        i += 1;
        const impls_start = i;
        while (i < args.len and args[i].data == .list) : (i += 1) {}
        const impls = args[impls_start..i];
        if (impls.len == 0)
            return error_catalog.raise(.extend_protocol_section_invalid, type_form.location, .{});

        // Build `(extend-type type-form protocol-form impls...)` —
        // the analyzer re-expands this through expandExtendType on
        // the next macro pass, so no need to duplicate the
        // method-impl normalisation here.
        var ext_items = try arena.alloc(Form, 3 + impls.len);
        ext_items[0] = sym("extend-type", type_form.location);
        ext_items[1] = type_form;
        ext_items[2] = protocol_form;
        @memcpy(ext_items[3..], impls);
        try sections.append(arena, try list(arena, ext_items, type_form.location));
    }

    if (sections.items.len == 1) return sections.items[0];

    var do_items = try arena.alloc(Form, sections.items.len + 1);
    do_items[0] = sym("do", loc);
    @memcpy(do_items[1..], sections.items);
    return list(arena, do_items, loc);
}

fn expandWhenLet(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len < 2)
        return error_catalog.raise(.when_let_form_incomplete, loc, .{});

    const binding_form = args[0];
    const body = args[1..];

    // Build (do body...) (or single body form).
    const body_form = if (body.len == 1) body[0] else blk: {
        var do_items = try arena.alloc(Form, body.len + 1);
        do_items[0] = sym("do", loc);
        @memcpy(do_items[1..], body);
        break :blk try list(arena, do_items, loc);
    };

    // Wrap in (if-let [name expr] body nil) -- analyzer re-expands
    // through expandIfLet on the next pass, so we get the gensym for
    // free.
    const if_let_items = try arena.alloc(Form, 4);
    if_let_items[0] = sym("if-let", loc);
    if_let_items[1] = binding_form;
    if_let_items[2] = body_form;
    if_let_items[3] = nilForm(loc);
    return list(arena, if_let_items, loc);
}

// --- defrecord — record type definition ---
//
// `(defrecord Name [f1 f2 ...] Proto (m [this] body) ...)` lowers via
// `lowerDefType` to a `(do ...)` of:
//   (def Name (rt/__defrecord! 'Name ['f1 'f2 ...]))   ; .kind = .defrecord
//   (def ->Name (fn* [f1 f2 ...] (Name. f1 f2 ...)))   ; positional factory
//   (def map->Name (fn* [m] (Name. (get m :f1) ...)))  ; map factory
//   <extend-type sections for each protocol's method bodies>
// Per ADR-0066 `deftype` is a sibling macro (`expandDeftype`) sharing
// `lowerDefType`; its `rt/__deftype!` primitive shares `registerType`
// (kind = .deftype). Record IPersistentMap arms live in
// `lang/primitive/collection.zig`.
fn expandDefrecord(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    return lowerDefType(arena, rt, args, loc, "__defrecord!");
}

/// `(deftype Name [fields] Proto (m [..] ..)...)` — ADR-0066. deftype and
/// defrecord lower identically (same Name + ->Name + extend-type sections);
/// they differ only in the registration primitive (`__deftype!` registers
/// `.kind = .deftype`, so no implicit IPersistentMap semantics). Shares
/// `lowerDefType` (F-011 commonization). Retires the former special form.
fn expandDeftype(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    return lowerDefType(arena, rt, args, loc, "__deftype!");
}

/// True iff a deftype/defrecord field symbol carries `^:unsynchronized-mutable`
/// or `^:volatile-mutable` reader metadata. The two keywords are unified into a
/// single "assignable" flag while the runtime is single-threaded (ADR-0104,
/// AD-018); the cross-thread visibility distinction is dormant until Phase 15+.
/// A `^long`/primitive type hint alongside (`^:unsynchronized-mutable ^long
/// s-pos`) is ignored (AD-017; NaN-box uniform Value slot).
fn fieldIsMutable(field_form: Form) bool {
    const m = field_form.meta orelse return false;
    if (m.data != .map) return false;
    const kvs = m.data.map;
    var i: usize = 0;
    while (i + 1 < kvs.len) : (i += 2) {
        if (kvs[i].data != .keyword) continue;
        const kn = kvs[i].data.keyword.name;
        if (std.mem.eql(u8, kn, "unsynchronized-mutable") or
            std.mem.eql(u8, kn, "volatile-mutable"))
        {
            const v = kvs[i + 1];
            return if (v.data == .boolean) v.data.boolean else true;
        }
    }
    return false;
}

/// True iff a deftype field symbol carries `^:volatile-mutable` (D-444 /
/// ADR-0152) — the subset of `fieldIsMutable` that needs atomic acquire/release
/// field access for cross-thread happens-before. `^:unsynchronized-mutable`
/// returns false (a plain slot, JVM-faithful: a plain field shared across
/// threads is a data race on the JVM too).
fn fieldIsVolatile(field_form: Form) bool {
    const m = field_form.meta orelse return false;
    if (m.data != .map) return false;
    const kvs = m.data.map;
    var i: usize = 0;
    while (i + 1 < kvs.len) : (i += 2) {
        if (kvs[i].data != .keyword) continue;
        if (std.mem.eql(u8, kvs[i].data.keyword.name, "volatile-mutable")) {
            const v = kvs[i + 1];
            return if (v.data == .boolean) v.data.boolean else true;
        }
    }
    return false;
}

/// Bring a defrecord/deftype's declared fields into scope as implicit locals
/// inside a protocol method body (D-202 gap 1), matching Clojure: a method
/// `(m [this] (* v 2))` sees the bare field `v` without an explicit
/// `(:v this)` / `(.v this)`. Wraps the body in
/// `(let* [<field> (.<field> <instance>) ...] <body>)` over the dot-field
/// accessor — `(.v inst)` works for BOTH defrecord and deftype, whereas
/// `(:v inst)` returns nil on a deftype (it is not map-like).
///
/// A field whose name collides with a method param is OMITTED so the param
/// shadows the field — verified against clj: `(m [this v] v)` returns the
/// param, not the field. `<instance>` is the method's first param (the
/// instance, possibly `_` — still a bound local). A malformed impl is
/// returned untouched so `expandExtendType` raises the precise error.
fn wrapMethodBodyWithFields(
    arena: std.mem.Allocator,
    impl: Form,
    fields: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    if (impl.data != .list or impl.data.list.len < 3 or
        impl.data.list[0].data != .symbol or
        impl.data.list[1].data != .vector)
        return impl;
    const items = impl.data.list;
    const params = items[1].data.vector;
    const body = items[2..];
    if (params.len == 0) return impl;
    if (params[0].data != .symbol) return impl;
    // The receiver feeds `(.field instance)` in the wrapped body; strip a
    // syntax-quote-qualified `user/_`-style ns so the body references the bound
    // param, not an unresolvable var (matches the fn*-param strip at the
    // extend-type lowering — see stripMethodParamNs).
    const instance: Form = if (params[0].data.symbol.ns != null)
        .{ .data = .{ .symbol = .{ .ns = null, .name = params[0].data.symbol.name } }, .location = params[0].location }
    else
        params[0];

    // ADR-0104: immutable fields ride a `let*` value-copy (a snapshot is correct
    // — they never change); MUTABLE fields must read the live slot, so they are
    // NOT bound here. Instead the body is wrapped in `(__mut-fields* instance
    // [mfield…] …)` whose analyzer handler resolves bare mutable-field reads to
    // a live `(.field instance)` and `(set! field v)` to a slot write.
    var binds: std.ArrayList(Form) = .empty;
    defer binds.deinit(arena);
    var mut_names: std.ArrayList(Form) = .empty;
    defer mut_names.deinit(arena);
    for (fields) |f| {
        if (f.data != .symbol) continue;
        const fname = f.data.symbol.name;
        var shadowed = false;
        for (params) |p| {
            if (p.data == .symbol and std.mem.eql(u8, p.data.symbol.name, fname)) {
                shadowed = true;
                break;
            }
        }
        if (shadowed) continue;
        if (fieldIsMutable(f)) {
            try mut_names.append(arena, sym(fname, loc));
            continue;
        }
        // (.<fname> instance)
        const dot_sym = blk: {
            const buf = try arena.alloc(u8, 1 + fname.len);
            buf[0] = '.';
            @memcpy(buf[1..], fname);
            break :blk sym(buf, loc);
        };
        var acc = try arena.alloc(Form, 2);
        acc[0] = dot_sym;
        acc[1] = instance;
        try binds.append(arena, f);
        try binds.append(arena, try list(arena, acc, loc));
    }
    if (binds.items.len == 0 and mut_names.items.len == 0) return impl;

    // Inner body: the raw method body, wrapped in a `let*` over the immutable
    // fields when any exist.
    var inner: []const Form = body;
    if (binds.items.len != 0) {
        var let_items = try arena.alloc(Form, 2 + body.len);
        let_items[0] = sym("let*", loc);
        let_items[1] = try vec(arena, binds.items, loc);
        @memcpy(let_items[2..], body);
        const one = try arena.alloc(Form, 1);
        one[0] = try list(arena, let_items, loc);
        inner = one;
    }

    // Outer body: wrap in `(__mut-fields* instance [mfield…] inner…)` when any
    // mutable field is in scope.
    var method_body: Form = undefined;
    if (mut_names.items.len != 0) {
        var mf_items = try arena.alloc(Form, 3 + inner.len);
        mf_items[0] = sym("__mut-fields*", loc);
        mf_items[1] = instance;
        mf_items[2] = try vec(arena, mut_names.items, loc);
        @memcpy(mf_items[3..], inner);
        method_body = try list(arena, mf_items, loc);
    } else {
        // immutable-only: `inner` is the single let* form.
        method_body = inner[0];
    }

    var new_items = try arena.alloc(Form, 3);
    new_items[0] = items[0];
    new_items[1] = items[1];
    new_items[2] = method_body;
    return list(arena, new_items, impl.location);
}

/// Shared `defrecord`/`deftype` lowering. `ctor_prim` is the `rt/`-namespaced
/// registration primitive (`__defrecord!` | `__deftype!`). Emits
/// `(do (def Name (rt/<ctor_prim> 'Name ['fields])) (def ->Name (fn* [..]
/// (Name. ..))) extend-type-sections...)`.
fn lowerDefType(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
    comptime ctor_prim: []const u8,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len < 2)
        return error_catalog.raise(.defrecord_form_incomplete, loc, .{});
    if (args[0].data != .symbol or args[0].data.symbol.ns != null)
        return error_catalog.raise(.defrecord_name_invalid, args[0].location, .{});
    if (args[1].data != .vector)
        return error_catalog.raise(.defrecord_fields_not_vector, args[1].location, .{});

    const fields_in = args[1].data.vector;
    const quoted_fields = try arena.alloc(Form, fields_in.len);
    // D-444 / ADR-0152: collect the `^:volatile-mutable` field names so the
    // registration primitive can flag them for atomic acquire/release access.
    // defrecord forbids mutable fields (below), so this stays empty there.
    const quoted_volatile = try arena.alloc(Form, fields_in.len);
    var n_volatile: usize = 0;
    for (fields_in, 0..) |field_form, i| {
        if (field_form.data != .symbol or field_form.data.symbol.ns != null)
            return error_catalog.raise(.defrecord_field_invalid, field_form.location, .{});
        // clj parity: records forbid mutable fields (core_deftype.clj:165-166).
        if (comptime std.mem.eql(u8, ctor_prim, "__defrecord!")) {
            if (fieldIsMutable(field_form))
                return error_catalog.raise(.defrecord_mutable_field, field_form.location, .{});
        }
        var q = try arena.alloc(Form, 2);
        q[0] = sym("quote", loc);
        q[1] = field_form;
        quoted_fields[i] = try list(arena, q, loc);
        if (fieldIsVolatile(field_form)) {
            var qv = try arena.alloc(Form, 2);
            qv[0] = sym("quote", loc);
            qv[1] = field_form;
            quoted_volatile[n_volatile] = try list(arena, qv, loc);
            n_volatile += 1;
        }
    }
    const fields_vec_form = try vec(arena, quoted_fields, loc);
    const volatile_vec_form = try vec(arena, quoted_volatile[0..n_volatile], loc);

    // (quote Name)
    var quoted_name_items = try arena.alloc(Form, 2);
    quoted_name_items[0] = sym("quote", loc);
    quoted_name_items[1] = args[0];
    const quoted_name = try list(arena, quoted_name_items, loc);

    // (rt/<ctor_prim> 'Name ['f1 'f2 ...] ['vol-field ...])  — arg 3 = the
    // `^:volatile-mutable` field names (D-444; empty for defrecord / no-volatile).
    var call_items = try arena.alloc(Form, 4);
    call_items[0] = .{ .data = .{ .symbol = .{ .ns = "rt", .name = ctor_prim } }, .location = loc };
    call_items[1] = quoted_name;
    call_items[2] = fields_vec_form;
    call_items[3] = volatile_vec_form;
    const defrecord_call = try list(arena, call_items, loc);

    // (def Name (rt/__defrecord! ...)) — binds Name to a
    // TypeDescriptorRef Value so downstream `extend-type Name P ...`
    // forms (in this defrecord's body OR in user code following the
    // form) resolve Name as a usable target.
    var def_name_items = try arena.alloc(Form, 3);
    def_name_items[0] = sym("def", loc);
    def_name_items[1] = args[0];
    def_name_items[2] = defrecord_call;
    const def_name = try list(arena, def_name_items, loc);

    // (def ->Name (fn* [f1 f2 ...] (Name. f1 f2 ...)))
    const arrow_name = blk: {
        const buf = try arena.alloc(u8, args[0].data.symbol.name.len + 2);
        buf[0] = '-';
        buf[1] = '>';
        @memcpy(buf[2..], args[0].data.symbol.name);
        break :blk sym(buf, loc);
    };
    const params_vec_form = blk: {
        const params_copy = try arena.dupe(Form, fields_in);
        break :blk Form{ .data = .{ .vector = params_copy }, .location = loc };
    };
    const ctor_sym = blk: {
        const buf = try arena.alloc(u8, args[0].data.symbol.name.len + 1);
        @memcpy(buf[0 .. buf.len - 1], args[0].data.symbol.name);
        buf[buf.len - 1] = '.';
        break :blk sym(buf, loc);
    };
    const ctor_args = try arena.alloc(Form, fields_in.len + 1);
    ctor_args[0] = ctor_sym;
    @memcpy(ctor_args[1..], fields_in);
    const ctor_call = try list(arena, ctor_args, loc);

    var fn_items = try arena.alloc(Form, 3);
    fn_items[0] = sym("fn*", loc);
    fn_items[1] = params_vec_form;
    fn_items[2] = ctor_call;
    const factory_fn = try list(arena, fn_items, loc);

    var def_arrow_items = try arena.alloc(Form, 3);
    def_arrow_items[0] = sym("def", loc);
    def_arrow_items[1] = arrow_name;
    def_arrow_items[2] = factory_fn;
    const def_arrow = try list(arena, def_arrow_items, loc);

    // (def map->Name (fn* [m] (rt/__map->record Name m))) — the map factory clj
    // generates for every DEFRECORD (not deftype). `rt/__map->record` (D-086 /
    // ADR-0154) pulls each declared field from `m` by keyword (nil if absent)
    // and holds the remaining keys in the record's extmap (clj's `__extmap`).
    // It is a PRIMITIVE (not core.clj `reduce-kv`/`assoc`) so the generated
    // factory stays bootstrap-safe — analyzable in a core-less environment (the
    // F-012 diff fixture), exactly as the prior `(get …)`-only body was. Gated
    // on the record ctor_prim (comptime).
    const is_record = comptime std.mem.eql(u8, ctor_prim, "__defrecord!");
    const def_map_arrow: ?Form = if (is_record) blk: {
        const map_arrow_name = mblk: {
            const nm = args[0].data.symbol.name;
            const buf = try arena.alloc(u8, nm.len + 5);
            @memcpy(buf[0..5], "map->");
            @memcpy(buf[5..], nm);
            break :mblk sym(buf, loc);
        };
        const m_param = sym("m", loc);
        const m_params_vec = Form{ .data = .{ .vector = try arena.dupe(Form, &[_]Form{m_param}) }, .location = loc };
        // (rt/__map->record Name m)
        const body_args = try arena.alloc(Form, 3);
        body_args[0] = .{ .data = .{ .symbol = .{ .ns = "rt", .name = "__map->record" } }, .location = loc };
        body_args[1] = args[0];
        body_args[2] = m_param;
        var map_fn_items = try arena.alloc(Form, 3);
        map_fn_items[0] = sym("fn*", loc);
        map_fn_items[1] = m_params_vec;
        map_fn_items[2] = try list(arena, body_args, loc);
        var def_map_arrow_items = try arena.alloc(Form, 3);
        def_map_arrow_items[0] = sym("def", loc);
        def_map_arrow_items[1] = map_arrow_name;
        def_map_arrow_items[2] = try list(arena, map_fn_items, loc);
        break :blk try list(arena, def_map_arrow_items, loc);
    } else null;

    // Protocol-section parsing — mirror expandExtendProtocol's
    // section walker. args[2..] alternates between a protocol-name
    // Symbol and one-or-more method-impl lists belonging to it; each
    // section lowers to `(extend-type Name Proto impl1 impl2 ...)`.
    var sections: std.ArrayList(Form) = .empty;
    defer sections.deinit(arena);

    var i: usize = 2;
    while (i < args.len) {
        if (args[i].data != .symbol)
            return error_catalog.raise(.extend_protocol_section_invalid, args[i].location, .{});
        const proto_form = args[i];
        i += 1;
        const impls_start = i;
        while (i < args.len and args[i].data == .list) : (i += 1) {}
        const impls = args[impls_start..i];
        // A zero-impl section is a MARKER protocol (e.g. `Sequential`):
        // it lowers to `(extend-type Name Marker)` with no method forms,
        // which `__extend-type!` records into `protocol_impls` (D-190/ADR-0068).

        var ext_items = try arena.alloc(Form, 3 + impls.len);
        ext_items[0] = sym("extend-type", proto_form.location);
        ext_items[1] = args[0];
        ext_items[2] = proto_form;
        // Each method body gets the record fields as implicit locals (D-202
        // gap 1); a marker section (zero impls) skips the loop entirely.
        for (impls, 0..) |impl, k|
            ext_items[3 + k] = try wrapMethodBodyWithFields(arena, impl, fields_in, loc);
        try sections.append(arena, try list(arena, ext_items, proto_form.location));
    }

    // (do (def Name (rt/__defrecord! ...)) (def ->Name ...) extend-type-sections...)
    const extra: usize = if (def_map_arrow != null) 1 else 0;
    var do_items = try arena.alloc(Form, 3 + extra + sections.items.len);
    do_items[0] = sym("do", loc);
    do_items[1] = def_name;
    do_items[2] = def_arrow;
    var di: usize = 3;
    if (def_map_arrow) |dma| {
        do_items[di] = dma;
        di += 1;
    }
    @memcpy(do_items[di..], sections.items);
    return list(arena, do_items, loc);
}

// --- reify — protocol/interface anonymous instance ---
//
// `(reify Proto1 (m1 [this] body) (m2 [this] body) Proto2 (m3 [this]
// body))` lowers to:
//
//   (rt/__reify!
//     ['Proto1 'Proto2]
//     [["m1" Proto1 (fn* [this] body)]
//      ["m2" Proto1 (fn* [this] body)]
//      ["m3" Proto2 (fn* [this] body)]])
//
// The protocol-symbols flow through bare so `__reify!` resolves them
// to `.protocol`-tagged Values at eval time (same shape as
// `extend-type`'s target argument). Method bodies become `fn*`
// expressions so the existing closure-capture machinery snapshots
// outer locals into the resulting Function Value automatically
// (survey §4 Option A — closure capture is free; no
// `closure_bindings_ptr` on ReifiedInstance).
//
// --- delay — `(delay expr...)` → `(__delay-create (fn* [] expr...))` ---
//
// Row 14.8 (D-098 follow-up). Wraps the body in a zero-arity thunk
// that the `__delay-create` primitive (lang/primitive/stm.zig)
// stashes in a Delay heap struct. `(deref d)` invokes the thunk on
// first call and caches the result. Mirrors JVM `clojure.core/delay`
// (which lowers to `(new clojure.lang.Delay (^{:once true} fn* []
// body))` — the `:once` metadata is a JVM bytecode hint cw v1
// doesn't need).
fn expandDelay(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    return expandThunkWrapper(arena, "__delay-create", args, loc);
}

// --- future — `(future expr...)` → `(__future-call (fn* [] expr...))` ---
//
// Row 14.8 (D-098 follow-up). On the single-thread runtime,
// `__future-call` evaluates the thunk eagerly at construction time
// and caches the result; the cached value is returned by `(deref
// f)`. Phase B swaps the primitive's body for real async execution
// — the macro surface is unchanged.
fn expandFuture(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    return expandThunkWrapper(arena, "__future-call", args, loc);
}

/// `(dosync body...)` → `(__run-in-transaction (fn* [] body...))` (Phase B #5).
/// Same thunk-wrap as future/delay; the body runs in an STM transaction on the
/// calling thread (NOT a spawned worker).
fn expandDosync(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    return expandThunkWrapper(arena, "__run-in-transaction", args, loc);
}

/// `(locking obj body...)` → `(__locking obj (fn* [] body...))` (Phase B #6).
/// obj is evaluated once; its heap-value monitor (ADR-0009 lock_state bits, NOT
/// a JVM monitor) is held while the body thunk runs on the calling thread.
/// Reentrant; released on normal or error exit (defer in the primitive).
fn expandLocking(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len < 2)
        return error_catalog.raise(.locking_form_incomplete, loc, .{});
    const empty_params = try arena.dupe(Form, &.{});
    const params_form: Form = .{ .data = .{ .vector = empty_params }, .location = loc };
    var fn_items = try arena.alloc(Form, 2 + (args.len - 1));
    fn_items[0] = sym("fn*", loc);
    fn_items[1] = params_form;
    @memcpy(fn_items[2..], args[1..]);
    const fn_form: Form = .{ .data = .{ .list = fn_items }, .location = loc };
    var call_items = try arena.alloc(Form, 3);
    call_items[0] = sym("__locking", loc);
    call_items[1] = args[0];
    call_items[2] = fn_form;
    return list(arena, call_items, loc);
}

// --- lazy-seq — `(lazy-seq body...)` → `(__lazy-seq-create (fn* [] body...))` ---
//
// ADR-0054 cycle 1. Wraps the body in a zero-arity thunk that the
// `__lazy-seq-create` primitive (lang/primitive/sequence.zig) stashes
// in a LazySeq heap struct; the thunk is forced on first access via
// the seq protocol (`first`/`rest`/`seq` route `.lazy_seq` through
// `runtime/lazy_seq.zig::force`). Same triad shape as delay/future.
fn expandLazySeq(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    return expandThunkWrapper(arena, "__lazy-seq-create", args, loc);
}

/// Shared shape: `(MACRO body...)` → `(PRIMITIVE (fn* [] body...))`.
/// The body forms are folded into the `fn*` body slice; an empty
/// body raises with the macro name so the error attributes to the
/// call site.
fn expandThunkWrapper(
    arena: std.mem.Allocator,
    primitive_name: []const u8,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    if (args.len == 0)
        return error_catalog.raise(.feature_not_supported, loc, .{ .name = "delay/future requires at least one body form" });
    const empty_params = try arena.dupe(Form, &.{});
    const params_form: Form = .{ .data = .{ .vector = empty_params }, .location = loc };
    var fn_items = try arena.alloc(Form, 2 + args.len);
    fn_items[0] = sym("fn*", loc);
    fn_items[1] = params_form;
    @memcpy(fn_items[2..], args);
    const fn_form: Form = .{ .data = .{ .list = fn_items }, .location = loc };
    var call_items = try arena.alloc(Form, 2);
    call_items[0] = sym(primitive_name, loc);
    call_items[1] = fn_form;
    return list(arena, call_items, loc);
}

// --- letfn — mutually-recursive local fns (D-201) ---
//
// `(letfn [(f [..] ..) (g [..] ..)] body...)` →
//   `(letfn* [f (fn [..] ..) g (fn [..] ..)] body...)`
//
// Each fn-spec `(name params... body...)` becomes a `name (fn params...
// body...)` pair. The self-name is dropped (cljw `fn` rejects a named
// fn, D-147) — recursion resolves through the `letfn*` slot, not an fn
// self-name. `fn` (not `fn*`) so the fn bodies get param destructuring.
fn expandLetfn(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len < 2 or args[0].data != .vector)
        return error_catalog.raise(.letfn_form_incomplete, loc, .{});
    const fnspecs = args[0].data.vector;
    const body = args[1..];

    var binds = try arena.alloc(Form, fnspecs.len * 2);
    for (fnspecs, 0..) |spec, i| {
        if (spec.data != .list or spec.data.list.len < 1 or spec.data.list[0].data != .symbol)
            return error_catalog.raise(.letfn_spec_invalid, spec.location, .{});
        const spec_items = spec.data.list;
        // (fn params... body...)
        var fn_items = try arena.alloc(Form, spec_items.len);
        fn_items[0] = sym("fn", spec.location);
        @memcpy(fn_items[1..], spec_items[1..]);
        binds[i * 2] = spec_items[0];
        binds[i * 2 + 1] = try list(arena, fn_items, spec.location);
    }
    const binds_vec = try vec(arena, binds, args[0].location);

    var items = try arena.alloc(Form, 2 + body.len);
    items[0] = sym("letfn*", loc);
    items[1] = binds_vec;
    @memcpy(items[2..], body);
    return list(arena, items, loc);
}

/// `(quote form)` — wrap a form so the analyzer treats it as a literal value
/// (a Symbol) instead of resolving it. Mirrors `expandInstanceQ`'s wrap.
fn quoteWrap(arena: std.mem.Allocator, form: Form) !Form {
    const items = try arena.alloc(Form, 2);
    items[0] = sym("quote", form.location);
    items[1] = form;
    return list(arena, items, form.location);
}

/// Build one reify method-table row `["name" proto fn]` (consumed by `__reify!`).
fn reifyMethodRow(arena: std.mem.Allocator, name: []const u8, proto_form: Form, fn_form: Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    var row_items = try arena.alloc(Form, 3);
    row_items[0] = .{ .data = .{ .string = name }, .location = loc };
    row_items[1] = proto_form;
    row_items[2] = fn_form;
    return vec(arena, row_items, loc);
}

fn expandReify(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    if (args.len == 0)
        return error_catalog.raise(.reify_form_incomplete, loc, .{});

    // Parse interfaces + methods: Symbol opens new section, List
    // forms append method-impls to current section. Mirrors
    // `expandExtendProtocol`.
    if (args[0].data != .symbol)
        return error_catalog.raise(.reify_section_invalid, args[0].location, .{});

    var interfaces: std.ArrayList(Form) = .empty;
    defer interfaces.deinit(arena);
    var method_rows: std.ArrayList(Form) = .empty;
    defer method_rows.deinit(arena);

    var i: usize = 0;
    while (i < args.len) {
        if (args[i].data != .symbol)
            return error_catalog.raise(.reify_section_invalid, args[i].location, .{});
        // A host-supertype marker (`Object`, D-275) is quote-wrapped so the
        // analyzer never Var-resolves it (Path A, the `instance?` precedent);
        // the primitive recognises the Symbol Value. A protocol name stays bare
        // (resolves to its protocol Var, the existing path).
        const sec_name = args[i].data.symbol.name;
        // Host-supertype markers (`Object`, D-275) AND protocol_remap interfaces
        // (`clojure.lang.*`, D-423) go into the interfaces vector quote-wrapped, so
        // `__reify!` records the NAME as a `protocol_impls` marker. A BARE
        // protocol_remap name (`ILookup`) would also resolve to its cljw protocol
        // Var, but a QUALIFIED one (`clojure.lang.ILookup`) resolves to a class
        // VALUE which `__reify!` rejects ("expected protocol, got type_descriptor");
        // quote-wrapping normalizes both spellings (and `Counted`, whose canonical
        // has no protocol Var), mirroring `rewriteProtocolRemap`'s declared-name
        // marker registration on the deftype/extend-type path. A plain cljw
        // protocol (user `defprotocol`) is neither, so it stays bare → its Var.
        const proto_form = if (host_interface.isMarker(sec_name) or host_interface.isProtocolRemap(sec_name))
            try quoteWrap(arena, args[i])
        else
            args[i];
        try interfaces.append(arena, proto_form);
        i += 1;

        const impls_start = i;
        while (i < args.len and args[i].data == .list) : (i += 1) {}
        const impls = args[impls_start..i];
        if (impls.len == 0)
            return error_catalog.raise(.reify_section_invalid, proto_form.location, .{});

        // A protocol_remap interface (clojure.lang.*) routes its clj method names
        // to cljw (protocol, method) targets — the SAME translation deftype /
        // extend-type get via rewriteProtocolRemap (D-280/286/417/419). reify
        // formerly skipped this entirely: a method written under a foreign interface
        // header (e.g. `valAt` under `Associative`, which clj allows since Associative
        // extends ILookup) registered verbatim under (Associative, valAt) and
        // silently never dispatched (the (ILookup, -lookup) dispatch found nothing).
        // `null` = a plain protocol / marker section (register the method verbatim).
        const remap_hi: ?host_interface.HostInterface = blk: {
            if (host_interface.isProtocolRemap(sec_name)) {
                const hi = host_interface.lookup(sec_name).?;
                if (sectionNeedsRemap(hi, impls)) break :blk hi;
            }
            break :blk null;
        };

        // Validate + collect distinct method names (first-seen order); one method
        // may appear at multiple arities (D-279), grouped into a multi-arity fn*.
        var section_names: std.ArrayList([]const u8) = .empty;
        defer section_names.deinit(arena);
        for (impls) |impl| {
            // EMPTY body (len == 2) is valid clj (method → nil); only < 2 is malformed.
            if (impl.data != .list or impl.data.list.len < 2 or
                impl.data.list[0].data != .symbol or
                impl.data.list[1].data != .vector)
            {
                return error_catalog.raise(.reify_method_invalid, impl.location, .{});
            }
            const mname = impl.data.list[0].data.symbol.name;
            var seen = false;
            for (section_names.items) |n| {
                if (std.mem.eql(u8, n, mname)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try section_names.append(arena, mname);
        }

        for (section_names.items) |method_name| {
            var clauses: std.ArrayList(Form) = .empty;
            defer clauses.deinit(arena);
            var name_loc = proto_form.location;
            for (impls) |impl| {
                if (!std.mem.eql(u8, impl.data.list[0].data.symbol.name, method_name)) continue;
                const stripped = try stripMethodParamNs(arena, impl.data.list[1]);
                // Lower destructured method params (`[_ [k x]]`) the same way fn
                // does — gensym the pattern param + wrap the body in a `let`.
                // No-op for all-symbol params (clj parity; spec.alpha unform*).
                const lowered = try transformFnArity(arena, rt, stripped, impl.data.list[2..], impl.location);
                const params_form = lowered.params;
                const body = lowered.body;
                const body_form = if (body.len == 1) body[0] else blk: {
                    var do_items_local = try arena.alloc(Form, body.len + 1);
                    do_items_local[0] = sym("do", impl.location);
                    @memcpy(do_items_local[1..], body);
                    break :blk try list(arena, do_items_local, impl.location);
                };
                if (clauses.items.len == 0) name_loc = impl.location;
                var clause_items = try arena.alloc(Form, 2);
                clause_items[0] = params_form;
                clause_items[1] = body_form;
                try clauses.append(arena, try list(arena, clause_items, impl.location));
            }

            const fn_form = if (clauses.items.len == 1) blk: {
                const cl = clauses.items[0].data.list;
                var fn_items = try arena.alloc(Form, 3);
                fn_items[0] = sym("fn*", name_loc);
                fn_items[1] = cl[0];
                fn_items[2] = cl[1];
                break :blk try list(arena, fn_items, name_loc);
            } else blk: {
                var fn_items = try arena.alloc(Form, 1 + clauses.items.len);
                fn_items[0] = sym("fn*", name_loc);
                @memcpy(fn_items[1..], clauses.items);
                break :blk try list(arena, fn_items, name_loc);
            };

            if (remap_hi) |hi| {
                const r = hi.remapMethod(method_name) orelse {
                    // A java.util method grouped under a clojure.lang remap section:
                    // cljw has no java dispatch → accept-and-drop (D-372). A genuinely
                    // unwired clojure.lang method is an explicit error, never silent.
                    if (host_interface.isJavaUtilMethod(method_name)) continue;
                    return error_catalog.raise(.feature_not_supported, name_loc, .{ .name = "deftype/reify clojure.lang.* method not yet wired" });
                };
                // A remap target that is a host-supertype MARKER (`equiv`/`hashCode`/
                // `equals` → Object/…, the method_family) must be quote-wrapped, like
                // the interfaces-vector path (D-423): a bare `Object` symbol resolves
                // to the Object CLASS VALUE which __reify! rejects ("expected protocol,
                // got type_descriptor"). A real cljw protocol target (ILookup, …) stays
                // bare → its protocol Var. D-426(A).
                const proto_sym = if (host_interface.isMarker(r.protocol))
                    try quoteWrap(arena, sym(r.protocol, name_loc))
                else
                    sym(r.protocol, name_loc);
                try method_rows.append(arena, try reifyMethodRow(arena, r.method, proto_sym, fn_form, name_loc));
                // D-283: also register the original clj name under the same protocol
                // so a `.cljname` dot-call on the reified instance resolves.
                if (!std.mem.eql(u8, method_name, r.method))
                    try method_rows.append(arena, try reifyMethodRow(arena, method_name, proto_sym, fn_form, name_loc));
            } else {
                // ["m-name" Proto fn-form] — verbatim (plain protocol / marker).
                try method_rows.append(arena, try reifyMethodRow(arena, method_name, proto_form, fn_form, name_loc));
            }
        }
    }

    const interfaces_vec = try vec(arena, interfaces.items, loc);
    const methods_vec = try vec(arena, method_rows.items, loc);

    // (rt/__reify! interfaces-vec methods-vec)
    var call_items = try arena.alloc(Form, 3);
    call_items[0] = .{ .data = .{ .symbol = .{ .ns = "rt", .name = "__reify!" } }, .location = loc };
    call_items[1] = interfaces_vec;
    call_items[2] = methods_vec;
    return list(arena, call_items, loc);
}

// `instance?` is no longer a macro — ADR-0128 made it a real fn over a class
// VALUE (`(def instance? (fn* [c x] (rt/-instance-of? c x)))` in core.clj), so it
// is passable higher-order (condp / map / partial). The old `expandInstanceQ`
// (auto-quote the class symbol → `(__instance? (quote Class) x)`) is retired.

// --- tests ---

const testing = std.testing;

const TestFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,
    env: Env,
    arena: std.heap.ArenaAllocator,
    table: macro_dispatch.Table,

    fn init(self: *TestFixture, alloc: std.mem.Allocator) !void {
        self.threaded = std.Io.Threaded.init(alloc, .{});
        self.rt = Runtime.init(self.threaded.io(), alloc);
        self.env = try Env.init(&self.rt);
        self.arena = std.heap.ArenaAllocator.init(alloc);
        self.table = macro_dispatch.Table.init(alloc);
    }

    fn deinit(self: *TestFixture) void {
        self.table.deinit();
        self.arena.deinit();
        self.env.deinit();
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "registerInto wires every bootstrap macro into rt and the Table" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try registerInto(&fix.env, &fix.table);

    const rt_ns = fix.env.findNs("rt").?;
    inline for (BOOTSTRAP) |e| {
        const v = rt_ns.resolve(e.name) orelse return error.TestUnexpectedResult;
        try testing.expect(v.flags.macro_);
        try testing.expect(fix.table.lookup(e.name) != null);
    }
}

test "expandLet renames head to let*" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const arena = fix.arena.allocator();
    const x_sym = sym("x", .{});
    const one = Form{ .data = .{ .integer = 1 }, .location = .{} };
    const binding_v = try arena.dupe(Form, &.{ x_sym, one });
    const bindings_form = Form{ .data = .{ .vector = binding_v }, .location = .{} };
    const body_form = x_sym;

    const args = [_]Form{ bindings_form, body_form };
    const out = try expandLet(arena, &fix.rt, &args, .{});
    try testing.expect(out.data == .list);
    try testing.expect(out.data.list.len == 3);
    try testing.expectEqualStrings("let*", out.data.list[0].data.symbol.name);
}

test "expandWhen builds (if c (do body...)) — clj parity (always-do, 2-arg if)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const arena = fix.arena.allocator();
    const cond_f = Form{ .data = .{ .boolean = true }, .location = .{} };
    const body_f = Form{ .data = .{ .integer = 42 }, .location = .{} };
    const args = [_]Form{ cond_f, body_f };

    const out = try expandWhen(arena, &fix.rt, &args, .{});
    try testing.expect(out.data == .list);
    // (if c (do 42)) — 3-element 2-arg if (no explicit nil else), matching clj.
    try testing.expectEqualStrings("if", out.data.list[0].data.symbol.name);
    try testing.expectEqual(@as(usize, 3), out.data.list.len);
    // Then-branch is ALWAYS a (do ...), even for a single body form.
    const then_f = out.data.list[2];
    try testing.expect(then_f.data == .list);
    try testing.expectEqualStrings("do", then_f.data.list[0].data.symbol.name);
    try testing.expectEqual(@as(i64, 42), then_f.data.list[1].data.integer);
}

test "expandThreadFirst produces (* (+ 1 2) 3) for (-> 1 (+ 2) (* 3))" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const arena = fix.arena.allocator();
    const one = Form{ .data = .{ .integer = 1 }, .location = .{} };
    const two = Form{ .data = .{ .integer = 2 }, .location = .{} };
    const three = Form{ .data = .{ .integer = 3 }, .location = .{} };

    // (+ 2)
    const plus_items = try arena.dupe(Form, &.{ sym("+", .{}), two });
    const plus_call = Form{ .data = .{ .list = plus_items }, .location = .{} };
    // (* 3)
    const mul_items = try arena.dupe(Form, &.{ sym("*", .{}), three });
    const mul_call = Form{ .data = .{ .list = mul_items }, .location = .{} };

    const args = [_]Form{ one, plus_call, mul_call };
    const out = try expandThreadFirst(arena, &fix.rt, &args, .{});

    // Outermost: (* (+ 1 2) 3)
    try testing.expect(out.data == .list);
    try testing.expectEqualStrings("*", out.data.list[0].data.symbol.name);
    try testing.expectEqual(@as(usize, 3), out.data.list.len);
    // Second arg: 3 literal
    try testing.expectEqual(@as(i64, 3), out.data.list[2].data.integer);
    // First arg: (+ 1 2)
    const inner = out.data.list[1];
    try testing.expect(inner.data == .list);
    try testing.expectEqualStrings("+", inner.data.list[0].data.symbol.name);
    try testing.expectEqual(@as(i64, 1), inner.data.list[1].data.integer);
    try testing.expectEqual(@as(i64, 2), inner.data.list[2].data.integer);
}

test "expandCond empty → nil; odd-arity → syntax error" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const arena = fix.arena.allocator();
    const empty = try expandCond(arena, &fix.rt, &.{}, .{});
    try testing.expect(empty.data == .nil);

    const single = [_]Form{Form{ .data = .{ .boolean = true }, .location = .{} }};
    const got = expandCond(arena, &fix.rt, &single, .{ .file = "<t>", .line = 1, .column = 0 });
    try testing.expectError(error.SyntaxError, got);
}

test "expandAnd / expandOr cover empty / single / multi" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const arena = fix.arena.allocator();
    const true_f = Form{ .data = .{ .boolean = true }, .location = .{} };

    // (and) -> true
    const a0 = try expandAnd(arena, &fix.rt, &.{}, .{});
    try testing.expect(a0.data == .boolean and a0.data.boolean);
    // (or) -> nil
    const o0 = try expandOr(arena, &fix.rt, &.{}, .{});
    try testing.expect(o0.data == .nil);
    // (and x) -> x
    const a1 = try expandAnd(arena, &fix.rt, &.{true_f}, .{});
    try testing.expect(a1.data == .boolean and a1.data.boolean);
    // (and x y) -> (let* [g x] (if g y g)) — single-pass expansion, no
    // nested (and y) form to re-dispatch.
    const a2 = try expandAnd(arena, &fix.rt, &.{ true_f, true_f }, .{});
    try testing.expectEqualStrings("let*", a2.data.list[0].data.symbol.name);
    const if_form = a2.data.list[2];
    try testing.expectEqualStrings("if", if_form.data.list[0].data.symbol.name);
    // Then-branch should be the literal `true`, not an `(and ...)` call.
    try testing.expect(if_form.data.list[2].data == .boolean);
}

test "expandAnd handles 10000 args without StackOverflow (4.3 regression)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const arena = fix.arena.allocator();
    var args: std.ArrayList(Form) = .empty;
    defer args.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        try args.append(testing.allocator, .{ .data = .{ .boolean = true }, .location = .{} });
    }
    // Pre-refactor this recursed 10000 times via macro_dispatch and
    // crashed; now it's a single linear pass.
    const expanded = try expandAnd(arena, &fix.rt, args.items, .{});
    try testing.expectEqualStrings("let*", expanded.data.list[0].data.symbol.name);
}

test "expandOr handles 10000 args without StackOverflow (4.3 regression)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const arena = fix.arena.allocator();
    var args: std.ArrayList(Form) = .empty;
    defer args.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        try args.append(testing.allocator, .{ .data = .{ .boolean = false }, .location = .{} });
    }
    const expanded = try expandOr(arena, &fix.rt, args.items, .{});
    try testing.expectEqualStrings("let*", expanded.data.list[0].data.symbol.name);
}

// --- row 7.3 cycle 7 macro tests ---

fn expectSymbolEq(form: Form, expected: []const u8) !void {
    try testing.expect(form.data == .symbol);
    try testing.expectEqualStrings(expected, form.data.symbol.name);
}

test "expandDefprotocol lowers to (do (def P ...) (def m1 ...))" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const arena = fix.arena.allocator();
    const p_sym = sym("P", .{});
    const m1_sym = sym("m1", .{});
    const this_sym = sym("this", .{});
    const params_v = try arena.dupe(Form, &.{this_sym});
    const params_form = Form{ .data = .{ .vector = params_v }, .location = .{} };
    const sig_list = try arena.dupe(Form, &.{ m1_sym, params_form });
    const sig_form = Form{ .data = .{ .list = sig_list }, .location = .{} };

    const args = [_]Form{ p_sym, sig_form };
    const out = try expandDefprotocol(arena, &fix.rt, &args, .{});
    try testing.expect(out.data == .list);
    try expectSymbolEq(out.data.list[0], "do");
    try testing.expectEqual(@as(usize, 4), out.data.list.len); // (do def-proto def-m1 'P) — D-456 return symbol
    // Trailing form is `(quote P)` — defprotocol returns the protocol name symbol.
    const ret_form = out.data.list[3];
    try testing.expect(ret_form.data == .list);
    try expectSymbolEq(ret_form.data.list[0], "quote");
    try expectSymbolEq(ret_form.data.list[1], "P");

    const def_proto = out.data.list[1];
    try testing.expect(def_proto.data == .list);
    try expectSymbolEq(def_proto.data.list[0], "def");
    try expectSymbolEq(def_proto.data.list[1], "P");

    const make_proto_call = def_proto.data.list[2];
    try testing.expect(make_proto_call.data == .list);
    try testing.expectEqualStrings("__make-protocol!", make_proto_call.data.list[0].data.symbol.name);

    const def_m1 = out.data.list[2];
    try testing.expect(def_m1.data == .list);
    try expectSymbolEq(def_m1.data.list[0], "def");
    try expectSymbolEq(def_m1.data.list[1], "m1");

    const make_fn_call = def_m1.data.list[2];
    try testing.expect(make_fn_call.data == .list);
    try testing.expectEqualStrings("__make-protocol-fn!", make_fn_call.data.list[0].data.symbol.name);
    // Second arg is the protocol-Var symbol (bare, resolves to the
    // just-interned P at runtime via ADR-0038's analyze-time intern).
    try expectSymbolEq(make_fn_call.data.list[1], "P");
    // Third arg is the method name as a string literal.
    try testing.expect(make_fn_call.data.list[2].data == .string);
    try testing.expectEqualStrings("m1", make_fn_call.data.list[2].data.string);
}

test "expandDefprotocol accepts a 0-method MARKER protocol (D-190/ADR-0068)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const arena = fix.arena.allocator();
    // `(defprotocol P)` — name only — is a marker; expands to
    // `(do (def P (rt/__make-protocol! 'P [])) 'P)`, no method defs (the
    // trailing `'P` is the D-456 return-symbol).
    const args = [_]Form{sym("P", .{})};
    const out = try expandDefprotocol(arena, &fix.rt, &args, .{});
    try testing.expect(out.data == .list);
    try testing.expectEqualStrings("do", out.data.list[0].data.symbol.name);
    // do = the proto-def + the trailing `(quote P)` return form (no method defs).
    try testing.expectEqual(@as(usize, 3), out.data.list.len);
    try testing.expectEqualStrings("def", out.data.list[1].data.list[0].data.symbol.name);
    try expectSymbolEq(out.data.list[2].data.list[0], "quote");
    try expectSymbolEq(out.data.list[2].data.list[1], "P");
}

test "expandExtendType lowers to (rt/__extend-type! target proto [[\"m\" (fn* ...)]])" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const arena = fix.arena.allocator();
    const foo_sym = sym("Foo", .{});
    const p_sym = sym("P", .{});
    const m_sym = sym("m", .{});
    const this_sym = sym("this", .{});
    const params_v = try arena.dupe(Form, &.{this_sym});
    const params_form = Form{ .data = .{ .vector = params_v }, .location = .{} };
    const body = Form{ .data = .{ .integer = 99 }, .location = .{} };
    const impl_list = try arena.dupe(Form, &.{ m_sym, params_form, body });
    const impl_form = Form{ .data = .{ .list = impl_list }, .location = .{} };

    const args = [_]Form{ foo_sym, p_sym, impl_form };
    const out = try expandExtendType(arena, &fix.rt, &args, .{});
    try testing.expect(out.data == .list);
    try testing.expectEqualStrings("__extend-type!", out.data.list[0].data.symbol.name);
    try expectSymbolEq(out.data.list[1], "Foo");
    try expectSymbolEq(out.data.list[2], "P");

    const impls_vec = out.data.list[3];
    try testing.expect(impls_vec.data == .vector);
    try testing.expectEqual(@as(usize, 1), impls_vec.data.vector.len);
    const pair = impls_vec.data.vector[0];
    try testing.expect(pair.data == .vector);
    try testing.expect(pair.data.vector[0].data == .string);
    try testing.expectEqualStrings("m", pair.data.vector[0].data.string);

    const fn_form = pair.data.vector[1];
    try testing.expect(fn_form.data == .list);
    try expectSymbolEq(fn_form.data.list[0], "fn*");
}

test "expandExtendProtocol distributes one protocol over multiple types" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const arena = fix.arena.allocator();
    const p_sym = sym("P", .{});
    const long_sym = sym("Long", .{});
    const string_sym = sym("String", .{});
    const m_sym = sym("m", .{});
    const this_sym = sym("this", .{});
    const params_v = try arena.dupe(Form, &.{this_sym});
    const params_form = Form{ .data = .{ .vector = params_v }, .location = .{} };
    const body_long = Form{ .data = .{ .keyword = .{ .ns = null, .name = "long" } }, .location = .{} };
    const body_str = Form{ .data = .{ .keyword = .{ .ns = null, .name = "str" } }, .location = .{} };
    const long_impl_list = try arena.dupe(Form, &.{ m_sym, params_form, body_long });
    const str_impl_list = try arena.dupe(Form, &.{ m_sym, params_form, body_str });
    const long_impl = Form{ .data = .{ .list = long_impl_list }, .location = .{} };
    const str_impl = Form{ .data = .{ .list = str_impl_list }, .location = .{} };

    const args = [_]Form{ p_sym, long_sym, long_impl, string_sym, str_impl };
    const out = try expandExtendProtocol(arena, &fix.rt, &args, .{});
    try testing.expect(out.data == .list);
    try expectSymbolEq(out.data.list[0], "do");
    try testing.expectEqual(@as(usize, 3), out.data.list.len);
    try expectSymbolEq(out.data.list[1].data.list[0], "extend-type");
    try expectSymbolEq(out.data.list[1].data.list[1], "Long");
    try expectSymbolEq(out.data.list[2].data.list[0], "extend-type");
    try expectSymbolEq(out.data.list[2].data.list[1], "String");
}

test "expandExtendProtocol single section drops the (do ...) wrapper" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const arena = fix.arena.allocator();
    const p_sym = sym("P", .{});
    const long_sym = sym("Long", .{});
    const m_sym = sym("m", .{});
    const this_sym = sym("this", .{});
    const params_v = try arena.dupe(Form, &.{this_sym});
    const params_form = Form{ .data = .{ .vector = params_v }, .location = .{} };
    const body = Form{ .data = .{ .keyword = .{ .ns = null, .name = "ok" } }, .location = .{} };
    const impl_list = try arena.dupe(Form, &.{ m_sym, params_form, body });
    const impl_form = Form{ .data = .{ .list = impl_list }, .location = .{} };

    const args = [_]Form{ p_sym, long_sym, impl_form };
    const out = try expandExtendProtocol(arena, &fix.rt, &args, .{});
    try testing.expect(out.data == .list);
    try expectSymbolEq(out.data.list[0], "extend-type");
}

// --- row 7.4 cycle 1 — `expandDefrecord` ---

test "expandDefrecord lowers (defrecord Name [f1 f2]) to (do (def Name __defrecord!) (def ->Name fn*))" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const arena = fix.arena.allocator();
    const name_sym = sym("Foo", .{});
    const f1_sym = sym("x", .{});
    const f2_sym = sym("y", .{});
    const fields_v = try arena.dupe(Form, &.{ f1_sym, f2_sym });
    const fields_form = Form{ .data = .{ .vector = fields_v }, .location = .{} };

    const args = [_]Form{ name_sym, fields_form };
    const out = try expandDefrecord(arena, &fix.rt, &args, .{});
    try testing.expect(out.data == .list);
    try expectSymbolEq(out.data.list[0], "do");
    // (do (def Foo (rt/__defrecord! ...)) (def ->Foo (fn* [x y] (Foo. x y)))
    //     (def map->Foo (fn* [m] (Foo. (get m :x) (get m :y))))) — D-232 map factory.
    try testing.expectEqual(@as(usize, 4), out.data.list.len);
    const def_map_arrow = out.data.list[3];
    try testing.expect(def_map_arrow.data == .list);
    try expectSymbolEq(def_map_arrow.data.list[0], "def");
    try expectSymbolEq(def_map_arrow.data.list[1], "map->Foo");

    const def_name = out.data.list[1];
    try testing.expect(def_name.data == .list);
    try expectSymbolEq(def_name.data.list[0], "def");
    try expectSymbolEq(def_name.data.list[1], "Foo");
    const call_form = def_name.data.list[2];
    try testing.expect(call_form.data == .list);
    try testing.expectEqualStrings("rt", call_form.data.list[0].data.symbol.ns.?);
    try testing.expectEqualStrings("__defrecord!", call_form.data.list[0].data.symbol.name);

    const def_arrow = out.data.list[2];
    try testing.expect(def_arrow.data == .list);
    try expectSymbolEq(def_arrow.data.list[0], "def");
    try expectSymbolEq(def_arrow.data.list[1], "->Foo");
}

test "expandDefrecord parses inline protocol-method sections into extend-type" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const arena = fix.arena.allocator();
    const name_sym = sym("Foo", .{});
    const f1_sym = sym("x", .{});
    const fields_v = try arena.dupe(Form, &.{f1_sym});
    const fields_form = Form{ .data = .{ .vector = fields_v }, .location = .{} };

    const proto_sym = sym("P", .{});
    const m_sym = sym("m", .{});
    const this_sym = sym("this", .{});
    const params_v = try arena.dupe(Form, &.{this_sym});
    const params_form = Form{ .data = .{ .vector = params_v }, .location = .{} };
    const body = Form{ .data = .{ .integer = 42 }, .location = .{} };
    const impl_list = try arena.dupe(Form, &.{ m_sym, params_form, body });
    const impl_form = Form{ .data = .{ .list = impl_list }, .location = .{} };

    const args = [_]Form{ name_sym, fields_form, proto_sym, impl_form };
    const out = try expandDefrecord(arena, &fix.rt, &args, .{});
    // (do __defrecord! def->Foo def-map->Foo (extend-type Foo P impl))
    try testing.expect(out.data == .list);
    try testing.expectEqual(@as(usize, 5), out.data.list.len);

    const ext = out.data.list[4];
    try testing.expect(ext.data == .list);
    try expectSymbolEq(ext.data.list[0], "extend-type");
    try expectSymbolEq(ext.data.list[1], "Foo");
    try expectSymbolEq(ext.data.list[2], "P");
}

test "expandDefrecord rejects missing field-vector via defrecord_form_incomplete" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const arena = fix.arena.allocator();
    const args = [_]Form{sym("Foo", .{})};
    try testing.expectError(error.SyntaxError, expandDefrecord(arena, &fix.rt, &args, .{}));
}
