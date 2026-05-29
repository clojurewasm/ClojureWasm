//! Zig-level Form→Form transforms for the bootstrap macros.
//!
//! Phase 3.7 ships nine syntactic-sugar macros: `let`, `when`,
//! `cond`, `->`, `->>`, `and`, `or`, `if-let`, `when-let`. Each is
//! implemented as a Zig function whose signature matches
//! `eval/macro_dispatch.zig::ZigExpandFn`. At startup `registerInto`
//! interns each name as a Var in the `rt` namespace with
//! `flags.macro_ = true`, refers them into `user`, and inserts the
//! transform into the analyzer's `MacroTable`.
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
    .{ .name = "when", .expand = expandWhen },
    .{ .name = "cond", .expand = expandCond },
    .{ .name = "->", .expand = expandThreadFirst },
    .{ .name = "->>", .expand = expandThreadLast },
    .{ .name = "and", .expand = expandAnd },
    .{ .name = "or", .expand = expandOr },
    .{ .name = "if-let", .expand = expandIfLet },
    .{ .name = "when-let", .expand = expandWhenLet },
    .{ .name = "fn", .expand = expandFn },
    .{ .name = "defn", .expand = expandDefn },
    .{ .name = "defmulti", .expand = expandDefmulti },
    .{ .name = "defmethod", .expand = expandDefmethod },
    .{ .name = "prefer-method", .expand = expandPreferMethod },
    .{ .name = "defprotocol", .expand = expandDefprotocol },
    .{ .name = "extend-type", .expand = expandExtendType },
    .{ .name = "extend-protocol", .expand = expandExtendProtocol },
    .{ .name = "defrecord", .expand = expandDefrecord },
    .{ .name = "reify", .expand = expandReify },
    .{ .name = "instance?", .expand = expandInstanceQ },
    .{ .name = "delay", .expand = expandDelay },
    .{ .name = "future", .expand = expandFuture },
    .{ .name = "lazy-seq", .expand = expandLazySeq },
};

// --- Form-construction conveniences ---

const list = macro_dispatch.makeList;
const vec = macro_dispatch.makeVector;
const sym = macro_dispatch.makeSymbol;
const nilForm = macro_dispatch.makeNil;

// --- let — for now, plain rename to let* ---
//
// Clojure's `let` adds destructuring on top of `let*`; we ship the
// rename today and revisit destructuring in a later phase. This keeps
// the macro dispatch path exercised even though the transform itself
// is trivial.

fn expandLet(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len < 2)
        return error_catalog.raise(.let_form_incomplete, loc, .{});
    if (args[0].data != .vector)
        return error_catalog.raise(.bindings_not_vector, args[0].location, .{ .form = "let" });

    var items = try arena.alloc(Form, args.len + 1);
    items[0] = sym("let*", loc);
    @memcpy(items[1..], args);
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
    if (args.len < 2)
        return error_catalog.raise(.when_form_incomplete, loc, .{});

    const cond_form = args[0];
    const body = args[1..];

    // (do body...) -- but if there's a single body form, fold to it
    // directly so the expanded shape is simpler to read in error
    // messages.
    const then_form = if (body.len == 1) body[0] else blk: {
        var do_items = try arena.alloc(Form, body.len + 1);
        do_items[0] = sym("do", loc);
        @memcpy(do_items[1..], body);
        break :blk try list(arena, do_items, loc);
    };

    const if_items = try arena.alloc(Form, 4);
    if_items[0] = sym("if", loc);
    if_items[1] = cond_form;
    if_items[2] = then_form;
    if_items[3] = nilForm(loc);
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
    // Bare-symbol step: `(-> x f)` → `(f x)`.
    if (step.data == .symbol) {
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
    if (binding_v[0].data != .symbol or binding_v[0].data.symbol.ns != null)
        return error_catalog.raise(.if_let_binding_name_invalid, binding_v[0].location, .{});

    const name_form = binding_v[0];
    const expr_form = binding_v[1];
    const then_form = args[1];
    const else_form: Form = if (args.len == 3) args[2] else nilForm(loc);

    const gname = try rt.gensym(arena, "if_let");

    // Inner: (let* [name g] then)
    const inner_binding = try arena.alloc(Form, 2);
    inner_binding[0] = name_form;
    inner_binding[1] = sym(gname, loc);
    const inner_let_items = try arena.alloc(Form, 3);
    inner_let_items[0] = sym("let*", loc);
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
// Docstring + metadata-map deferred per survey §11 Q6 to a separate
// D-NNN follow-up row.
fn expandDefn(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len < 2)
        return error_catalog.raise(.defn_form_incomplete, loc, .{});
    if (args[0].data != .symbol or args[0].data.symbol.ns != null)
        return error_catalog.raise(.defn_name_invalid, args[0].location, .{});

    const name_form = args[0];

    // Two body shapes: vector ⇒ single-arity (existing); list ⇒ multi-arity.
    const fn_form = blk: {
        if (args[1].data == .vector) {
            if (args.len < 3)
                return error_catalog.raise(.defn_form_incomplete, loc, .{});
            const params_form = args[1];
            const body = args[2..];
            const body_form = try wrapBodyInDo(arena, body, loc);
            const fn_items = try arena.alloc(Form, 3);
            fn_items[0] = sym("fn*", loc);
            fn_items[1] = params_form;
            fn_items[2] = body_form;
            break :blk try list(arena, fn_items, loc);
        }
        // Multi-arity: every args[1..] must be a `([params] body...)` list.
        var fn_items = try arena.alloc(Form, args.len);
        fn_items[0] = sym("fn*", loc);
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (args[i].data != .list)
                return error_catalog.raise(.defn_params_not_vector, args[i].location, .{});
            const sub = args[i].data.list;
            if (sub.len < 2)
                return error_catalog.raise(.defn_form_incomplete, args[i].location, .{});
            if (sub[0].data != .vector)
                return error_catalog.raise(.defn_params_not_vector, sub[0].location, .{});
            const body_form = try wrapBodyInDo(arena, sub[1..], args[i].location);
            const method_items = try arena.alloc(Form, 2);
            method_items[0] = sub[0];
            method_items[1] = body_form;
            fn_items[i] = try list(arena, method_items, args[i].location);
        }
        break :blk try list(arena, fn_items, loc);
    };

    // (def name (fn* ...))
    const def_items = try arena.alloc(Form, 3);
    def_items[0] = sym("def", loc);
    def_items[1] = name_form;
    def_items[2] = fn_form;
    return list(arena, def_items, loc);
}

/// `fn` macro. The no-name forms are shape-identical to `fn*`, so the
/// transform just rewrites the head `fn` → `fn*` verbatim: `(fn [p]
/// body...)` → `(fn* [p] body...)`, `(fn ([p] b) ...)` → `(fn* ([p] b)
/// ...)`. Multi-arity / `& rest` / closures all ride fn* (ADR-0041).
/// A self-name `(fn name [p] body)` needs an fn* self-name slot (a
/// dual-backend extension, D-147) — raised as a clear transient error,
/// NOT silently dropped (provisional_marker.md). Destructured params
/// forward to fn*, which raises its existing not-supported path (D-076).
fn expandFn(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len >= 1 and args[0].data == .symbol)
        return error_catalog.raise(.fn_named_not_supported, args[0].location, .{});
    const fn_items = try arena.alloc(Form, args.len + 1);
    fn_items[0] = sym("fn*", loc);
    for (args, 0..) |a, i| fn_items[i + 1] = a;
    return list(arena, fn_items, loc);
}

fn wrapBodyInDo(arena: std.mem.Allocator, body: []const Form, loc: SourceLocation) macro_dispatch.ExpandError!Form {
    if (body.len == 1) return body[0];
    const do_items = try arena.alloc(Form, body.len + 1);
    do_items[0] = sym("do", loc);
    @memcpy(do_items[1..], body);
    return list(arena, do_items, loc);
}

// --- defmulti — multimethod definition (ADR-0008 Phase 7.2 amendment, Alt 1) ---
//
// `(defmulti name dispatch-fn)` →
//   `(def name (rt/__make-multifn (quote name) dispatch-fn :default))`
//
// JVM Clojure's `defmulti` macro has additional re-eval-no-op
// semantics (preserves method_table across REPL reloads). cw v1
// cycle 5c omits this; re-eval clobbers. Restoring the no-op
// requires `resolved?` + `multi-fn?` predicates that arrive at a
// later cycle (D-NEW candidate).
fn expandDefmulti(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len != 2)
        return error_catalog.raise(.defmulti_form_incomplete, loc, .{});
    if (args[0].data != .symbol or args[0].data.symbol.ns != null)
        return error_catalog.raise(.defmulti_name_invalid, args[0].location, .{});

    const name_form = args[0];
    const dispatch_fn_form = args[1];

    // (quote name)
    var quote_items = try arena.alloc(Form, 2);
    quote_items[0] = sym("quote", loc);
    quote_items[1] = name_form;
    const quoted_name = try list(arena, quote_items, loc);

    // (rt/__make-multifn (quote name) dispatch-fn :default)
    var call_items = try arena.alloc(Form, 4);
    call_items[0] = .{ .data = .{ .symbol = .{ .ns = "rt", .name = "__make-multifn" } }, .location = loc };
    call_items[1] = quoted_name;
    call_items[2] = dispatch_fn_form;
    call_items[3] = .{ .data = .{ .keyword = .{ .ns = null, .name = "default" } }, .location = loc };
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
    if (args.len < 4)
        return error_catalog.raise(.defmethod_form_incomplete, loc, .{});
    if (args[2].data != .vector)
        return error_catalog.raise(.defmethod_params_not_vector, args[2].location, .{});

    const multi_form = args[0];
    const dispatch_val_form = args[1];
    const params_form = args[2];
    const body = args[3..];

    const body_form = if (body.len == 1) body[0] else blk: {
        var do_items = try arena.alloc(Form, body.len + 1);
        do_items[0] = sym("do", loc);
        @memcpy(do_items[1..], body);
        break :blk try list(arena, do_items, loc);
    };

    // (fn* params_form body_form)
    var fn_items = try arena.alloc(Form, 3);
    fn_items[0] = sym("fn*", loc);
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

// --- prefer-method — record preference on a multimethod ---
//
// `(prefer-method multifn x y)` → `(rt/__prefer-method! multifn x y)`
fn expandPreferMethod(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len != 3)
        return error_catalog.raise(.prefer_method_form_incomplete, loc, .{});

    var call_items = try arena.alloc(Form, 4);
    call_items[0] = .{ .data = .{ .symbol = .{ .ns = "rt", .name = "__prefer-method!" } }, .location = loc };
    call_items[1] = args[0];
    call_items[2] = args[1];
    call_items[3] = args[2];
    return list(arena, call_items, loc);
}

// --- defprotocol — declare a protocol name + its method dispatch fns ---
//
// `(defprotocol P (m1 [x]) (m2 [x y]))` lowers to:
//   (do
//     (def P (rt/__make-protocol! 'P ['m1 'm2]))
//     (def m1 (rt/__make-protocol-fn! P "m1"))
//     (def m2 (rt/__make-protocol-fn! P "m2")))
//
// Each method-sig is `(method-name [params...])` — arity defaults
// to 1 inside cycle 6 `__make-protocol!` (row 7.4 `definterface`
// will extend the surface for arity overload). The param vector
// is consumed for shape-validation only. ADR-0038 (analyzer
// pre-registers Var at analyze time) lets the second-and-subsequent
// `def` forms reference `P` cleanly — the cycle-7.1 truncation
// (single-def emission) is rolled back here.
fn expandDefprotocol(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len < 2)
        return error_catalog.raise(.defprotocol_form_incomplete, loc, .{});
    if (args[0].data != .symbol or args[0].data.symbol.ns != null)
        return error_catalog.raise(.defprotocol_name_invalid, args[0].location, .{});

    const name_form = args[0];
    const method_sigs = args[1..];

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

    // (rt/__make-protocol! 'name [method-quotes])
    var make_proto_items = try arena.alloc(Form, 3);
    make_proto_items[0] = .{ .data = .{ .symbol = .{ .ns = "rt", .name = "__make-protocol!" } }, .location = loc };
    make_proto_items[1] = quoted_name;
    make_proto_items[2] = methods_vec;
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

    // (do def-proto def-method-1 def-method-2 ...)
    var do_items = try arena.alloc(Form, 2 + method_defs.len);
    do_items[0] = sym("do", loc);
    do_items[1] = def_proto;
    @memcpy(do_items[2..], method_defs);
    return list(arena, do_items, loc);
}

// --- extend-type — install one or more method impls on a TypeDescriptor ---
//
// `(extend-type Foo P (m1 [x] body1) (m2 [x] body2))` lowers to:
//   (rt/__extend-type! Foo P [["m1" (fn* [x] body1)] ["m2" (fn* [x] body2)]])
//
// Each method-impl is `(method-name [params...] body...)` — same
// shape as defmethod's clauses.
fn expandExtendType(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len < 3)
        return error_catalog.raise(.extend_type_form_incomplete, loc, .{});

    const target_form = args[0];
    const protocol_form = args[1];
    const method_impls = args[2..];

    const impl_pairs = try arena.alloc(Form, method_impls.len);
    for (method_impls, 0..) |impl, i| {
        if (impl.data != .list or impl.data.list.len < 3 or
            impl.data.list[0].data != .symbol or
            impl.data.list[1].data != .vector)
        {
            return error_catalog.raise(.extend_type_method_invalid, impl.location, .{});
        }
        const method_name = impl.data.list[0].data.symbol.name;
        const params_form = impl.data.list[1];
        const body = impl.data.list[2..];

        const body_form = if (body.len == 1) body[0] else blk: {
            var do_items = try arena.alloc(Form, body.len + 1);
            do_items[0] = sym("do", impl.location);
            @memcpy(do_items[1..], body);
            break :blk try list(arena, do_items, impl.location);
        };

        // (fn* params body)
        var fn_items = try arena.alloc(Form, 3);
        fn_items[0] = sym("fn*", impl.location);
        fn_items[1] = params_form;
        fn_items[2] = body_form;
        const fn_form = try list(arena, fn_items, impl.location);

        // ["method-name" fn-form]
        var pair_items = try arena.alloc(Form, 2);
        pair_items[0] = .{ .data = .{ .string = method_name }, .location = impl.location };
        pair_items[1] = fn_form;
        impl_pairs[i] = try vec(arena, pair_items, impl.location);
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

    // Walk args[1..]; symbol forms open a new section, list forms
    // append method-impls to the current section. First non-protocol
    // arg must be a type symbol.
    if (args[1].data != .symbol)
        return error_catalog.raise(.extend_protocol_section_invalid, args[1].location, .{});

    var sections: std.ArrayList(Form) = .empty;
    defer sections.deinit(arena);

    var i: usize = 1;
    while (i < args.len) {
        if (args[i].data != .symbol)
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

// --- defrecord — §9.9 row 7.4 cycles 1-2 macro lowering ---
//
// `(defrecord Name [f1 f2 ...])` lowers to
//   `(do (rt/__defrecord! 'Name ['f1 'f2 ...]))`.
//
// Row 7.4 cycle 2 swapped the cycle-1 `(deftype ...)` placeholder for
// the `rt/__defrecord!` Layer-2 primitive so the resulting
// TypeDescriptor carries `.kind = .defrecord` (cycle 1 produced
// `.kind = .deftype`). The primitive shares
// `runtime/type_descriptor.zig::registerType` with `evalDeftype`.
//
// Cycles 3-5 grow the factory `->Name`, the protocol-method body
// surface, and the implicit IPersistentMap arms in
// `lang/primitive/collection.zig`; the `(do ...)` wrapper reserves
// room for those additional forms.
fn expandDefrecord(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
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
    for (fields_in, 0..) |field_form, i| {
        if (field_form.data != .symbol or field_form.data.symbol.ns != null)
            return error_catalog.raise(.defrecord_field_invalid, field_form.location, .{});
        var q = try arena.alloc(Form, 2);
        q[0] = sym("quote", loc);
        q[1] = field_form;
        quoted_fields[i] = try list(arena, q, loc);
    }
    const fields_vec_form = try vec(arena, quoted_fields, loc);

    // (quote Name)
    var quoted_name_items = try arena.alloc(Form, 2);
    quoted_name_items[0] = sym("quote", loc);
    quoted_name_items[1] = args[0];
    const quoted_name = try list(arena, quoted_name_items, loc);

    // (rt/__defrecord! 'Name ['f1 'f2 ...])
    var call_items = try arena.alloc(Form, 3);
    call_items[0] = .{ .data = .{ .symbol = .{ .ns = "rt", .name = "__defrecord!" } }, .location = loc };
    call_items[1] = quoted_name;
    call_items[2] = fields_vec_form;
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
        if (impls.len == 0)
            return error_catalog.raise(.extend_protocol_section_invalid, proto_form.location, .{});

        var ext_items = try arena.alloc(Form, 3 + impls.len);
        ext_items[0] = sym("extend-type", proto_form.location);
        ext_items[1] = args[0];
        ext_items[2] = proto_form;
        @memcpy(ext_items[3..], impls);
        try sections.append(arena, try list(arena, ext_items, proto_form.location));
    }

    // (do (def Name (rt/__defrecord! ...)) (def ->Name ...) extend-type-sections...)
    var do_items = try arena.alloc(Form, 3 + sections.items.len);
    do_items[0] = sym("do", loc);
    do_items[1] = def_name;
    do_items[2] = def_arrow;
    @memcpy(do_items[3..], sections.items);
    return list(arena, do_items, loc);
}

// --- reify — §9.9 row 7.5 cycle 1 macro skeleton ---
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
// Cycle 1 ships a thin `__reify!` primitive that raises
// `feature_not_supported` (transient stub per
// `provisional_marker.md` row 2). Cycle 3 implements the happy
// path; cycle 4 wires the dispatch arm for `.reified_instance`.
// --- delay — `(delay expr...)` → `(__delay-create (fn* [] expr...))` ---
//
// Row 14.8 (D-098 follow-up). Wraps the body in a zero-arity thunk
// that the `__delay-create` primitive (lang/primitive/stm.zig)
// stashes in a Delay heap struct. `(deref d)` invokes the thunk on
// first call and caches the result. Mirrors JVM `clojure.core/delay`
// (which lowers to `(new clojure.lang.Delay (^{:once true} fn* []
// body))` — the `:once` metadata is a JVM bytecode hint cw v1
// doesn't need at Phase 14).
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
// Row 14.8 (D-098 follow-up). On the Phase 14 single-thread runtime,
// `__future-call` evaluates the thunk eagerly at construction time
// and caches the result; the cached value is returned by `(deref
// f)`. Phase 15.1 swaps the primitive's body for `std.Thread.spawn`
// + a synchronisation primitive — the macro surface is unchanged.
fn expandFuture(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    return expandThunkWrapper(arena, "__future-call", args, loc);
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

fn expandReify(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
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
        const proto_form = args[i];
        // Push 'Proto into interfaces vec (as the bare Symbol Value).
        try interfaces.append(arena, proto_form);
        i += 1;

        const impls_start = i;
        while (i < args.len and args[i].data == .list) : (i += 1) {}
        const impls = args[impls_start..i];
        if (impls.len == 0)
            return error_catalog.raise(.reify_section_invalid, proto_form.location, .{});

        for (impls) |impl| {
            if (impl.data != .list or impl.data.list.len < 3 or
                impl.data.list[0].data != .symbol or
                impl.data.list[1].data != .vector)
            {
                return error_catalog.raise(.reify_method_invalid, impl.location, .{});
            }
            const method_name = impl.data.list[0].data.symbol.name;
            const params_form = impl.data.list[1];
            const body = impl.data.list[2..];

            const body_form = if (body.len == 1) body[0] else blk: {
                var do_items_local = try arena.alloc(Form, body.len + 1);
                do_items_local[0] = sym("do", impl.location);
                @memcpy(do_items_local[1..], body);
                break :blk try list(arena, do_items_local, impl.location);
            };

            // (fn* params body)
            var fn_items = try arena.alloc(Form, 3);
            fn_items[0] = sym("fn*", impl.location);
            fn_items[1] = params_form;
            fn_items[2] = body_form;
            const fn_form = try list(arena, fn_items, impl.location);

            // ["m-name" Proto fn-form]
            var row_items = try arena.alloc(Form, 3);
            row_items[0] = .{ .data = .{ .string = method_name }, .location = impl.location };
            row_items[1] = proto_form;
            row_items[2] = fn_form;
            try method_rows.append(arena, try vec(arena, row_items, impl.location));
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

// --- instance? — row 7.12 cycle 1: `(instance? Class x)` →
//     `(__instance? (quote Class) x)` so the analyzer never tries to
//     resolve `Class` as a Var. Path A (Symbol-based primitive-side
//     lookup) per the row 7.12 survey Q1 decision; the primitive
//     receives the Class as a Symbol Value through the wrapped
//     `quote` and consults `runtime/class_name.zig`'s registry. ---

fn expandInstanceQ(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len != 2)
        return error_catalog.raise(.arity_not_expected, loc, .{
            .fn_name = "instance?",
            .got = args.len,
            .expected = 2,
        });
    const class_form = args[0];
    if (class_form.data != .symbol)
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "instance?",
            .expected = "symbol (class name)",
            .actual = @tagName(class_form.data),
        });

    // (quote ClassSym)
    const quote_items = try arena.alloc(Form, 2);
    quote_items[0] = sym("quote", class_form.location);
    quote_items[1] = class_form;
    const quoted = try list(arena, quote_items, class_form.location);

    // (__instance? <quoted-class> x)
    const call_items = try arena.alloc(Form, 3);
    call_items[0] = sym("__instance?", loc);
    call_items[1] = quoted;
    call_items[2] = args[1];
    return list(arena, call_items, loc);
}

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

test "expandWhen builds (if c (do body...) nil)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const arena = fix.arena.allocator();
    const cond_f = Form{ .data = .{ .boolean = true }, .location = .{} };
    const body_f = Form{ .data = .{ .integer = 42 }, .location = .{} };
    const args = [_]Form{ cond_f, body_f };

    const out = try expandWhen(arena, &fix.rt, &args, .{});
    try testing.expect(out.data == .list);
    try testing.expectEqualStrings("if", out.data.list[0].data.symbol.name);
    try testing.expectEqual(@as(usize, 4), out.data.list.len);
    try testing.expect(out.data.list[3].data == .nil);
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
    try testing.expectEqual(@as(usize, 3), out.data.list.len); // (do def-proto def-m1)

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

test "expandDefprotocol rejects 0-method form via defprotocol_form_incomplete" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const arena = fix.arena.allocator();
    const args = [_]Form{sym("P", .{})};
    try testing.expectError(error.SyntaxError, expandDefprotocol(arena, &fix.rt, &args, .{}));
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
    // (do (def Foo (rt/__defrecord! ...)) (def ->Foo (fn* [x y] (Foo. x y))))
    try testing.expectEqual(@as(usize, 3), out.data.list.len);

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
    // (do __defrecord! def->Foo (extend-type Foo P impl))
    try testing.expect(out.data == .list);
    try testing.expectEqual(@as(usize, 4), out.data.list.len);

    const ext = out.data.list[3];
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
