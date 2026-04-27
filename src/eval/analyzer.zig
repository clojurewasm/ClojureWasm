//! Analyzer — Form → Node (semantic analysis).
//!
//! Reads the Form tree the Reader produced and emits a typed Node
//! tree the backend executes directly. Responsibilities:
//!
//!   1. **Symbol resolution** — every symbol becomes either a
//!      `local_ref` (slot index, for let-bound and fn parameters)
//!      or a `var_ref` (resolved `*const Var` from a Namespace).
//!      The lookup chain is: locals → current ns mappings → current
//!      ns refers, mirroring Clojure semantics.
//!   2. **Special-form syntax checking** — shapes like `(if 1 2 3 4)`
//!      become `SyntaxError` here so the backend's hot path does not
//!      have to validate at every step.
//!   3. **Slot allocation** — every local gets a `u16` index
//!      assigned during analysis, so the backend never hits a
//!      HashMap at eval time.
//!   4. **Macro expansion** — Phase 2 *does not* expand macros yet;
//!      Phase 3+ wires the analyser↔macro_transforms loop.
//!
//! ### Phase-2 scope
//!
//! - Atoms: nil / bool / int / float / keyword (interned at analyse time).
//! - Special forms: `def` / `if` / `do` / `quote` / `fn*` / `let*`.
//! - References: symbol → LocalRef / VarRef.
//! - **Not yet**: string literals as expression values, vector / map as
//!   expression values, syntax-quote, `loop*` / `recur`, `try` / `throw`,
//!   named `fn` (Phase 3+).
//!
//! ### Memory ownership
//!
//! Every Node lands in the caller-supplied `arena` allocator. A single
//! `analyze` call drops the whole sub-tree into the same arena, so
//! eval ends by freeing the arena in one shot — no per-Node free.

const std = @import("std");
const Form = @import("form.zig").Form;
const FormData = @import("form.zig").FormData;
const SymbolRef = @import("form.zig").SymbolRef;
const node_mod = @import("node.zig");
const Node = node_mod.Node;
const Value = @import("../runtime/value.zig").Value;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const Var = env_mod.Var;
const keyword = @import("../runtime/keyword.zig");
const string_collection = @import("../runtime/collection/string.zig");
const list_collection = @import("../runtime/collection/list.zig");
const error_mod = @import("../runtime/error.zig");
const SourceLocation = error_mod.SourceLocation;
const macro_dispatch = @import("macro_dispatch.zig");

/// Analyser errors. Phase 2 covers syntax + name resolution only.
/// Aliases the wide `error_mod.Error` set so calls to `setErrorFmt`
/// type-check; the analyser still only **emits** SyntaxError /
/// NameError / NotImplemented / OutOfMemory in practice. See the
/// equivalent comment in `eval/reader.zig` for the design rationale.
pub const AnalyzeError = error_mod.Error;

// --- Scope (local-binding chain consulted during analysis) ---

/// Recur target metadata. Stamped on each Scope created by `fn*` /
/// `loop*`. `arity` is the number of bindings / parameters that a
/// matching `recur` must supply. `slot_base` is the first local-slot
/// index of the binding/parameter group — the future `evalRecur`
/// (Phase 3.11) will rebind `[slot_base, slot_base + arity)` and
/// re-enter the body.
pub const RecurTarget = struct {
    arity: u16,
    slot_base: u16,
    /// "loop" or "fn" — only used to pick the right error wording for
    /// arity mismatches. ROADMAP P6.
    kind: enum { loop_kw, fn_kw },
};

/// Lexical scope chain. `let*` and `fn*` push children; resolution
/// walks the chain linearly. `next_slot` is **inherited** from the
/// parent so the whole enclosing function shares one slot space —
/// the backend can then index a single flat locals array.
///
/// Phase 3.9 adds `recur_target` (the nearest enclosing `loop*` /
/// `fn*` target) and `recur_target_depth` (the distance in scope
/// links). 3.9 only inspects "depth ≠ 0" / "target present", but the
/// depth is preserved so future named-loop / labelled-break work can
/// reach across multiple levels without re-engineering the contract
/// (ROADMAP A2). See `private/notes/phase3-3.9-survey.md` §7.
pub const Scope = struct {
    parent: ?*const Scope = null,
    bindings: std.StringHashMapUnmanaged(u16) = .empty,
    next_slot: u16 = 0,
    /// Innermost recur target visible from this scope, or null if
    /// `recur` here is a syntax error.
    recur_target: ?RecurTarget = null,
    /// 0 when `recur_target` was set on this scope; otherwise the
    /// distance in parent links to the scope that owns the target.
    /// Stays ≤ u32 for headroom; 16-bit was felt too tight given that
    /// macroexpansion can produce deep `let*` chains.
    recur_target_depth: u32 = 0,

    pub fn deinit(self: *Scope, alloc: std.mem.Allocator) void {
        self.bindings.deinit(alloc);
    }

    /// Spawn a child scope. The child inherits `next_slot` and the
    /// nearest recur target — `recur_target_depth` is bumped so
    /// future code that needs to "skip outer targets" can count.
    pub fn child(parent: *const Scope) Scope {
        return .{
            .parent = parent,
            .next_slot = parent.next_slot,
            .recur_target = parent.recur_target,
            .recur_target_depth = parent.recur_target_depth + 1,
        };
    }

    /// Spawn a child scope and register `target` as the new recur
    /// destination. The depth resets to 0 because *this* scope owns
    /// the target. `fn*` and `loop*` analysis use this; `let*` does
    /// not (let body is **not** a recur target — Clojure semantic).
    pub fn childWithRecur(parent: *const Scope, target: RecurTarget) Scope {
        return .{
            .parent = parent,
            .next_slot = parent.next_slot,
            .recur_target = target,
            .recur_target_depth = 0,
        };
    }

    /// Declare a new local; returns its slot number.
    pub fn declare(self: *Scope, alloc: std.mem.Allocator, name: []const u8) !u16 {
        const slot = self.next_slot;
        try self.bindings.put(alloc, name, slot);
        self.next_slot += 1;
        return slot;
    }

    /// Walk the chain looking for `name`; returns null when the
    /// caller should fall back to global resolution.
    pub fn lookup(self: *const Scope, name: []const u8) ?u16 {
        if (self.bindings.get(name)) |idx| return idx;
        if (self.parent) |p| return p.lookup(name);
        return null;
    }
};

// --- Special-form table ---

const SpecialFormKind = enum {
    def,
    if_form,
    do_form,
    quote_form,
    fn_star,
    let_star,
    loop_star,
    recur_form,
    try_form,
    throw_form,
};

const SPECIAL_FORMS = std.StaticStringMap(SpecialFormKind).initComptime(.{
    .{ "def", .def },
    .{ "if", .if_form },
    .{ "do", .do_form },
    .{ "quote", .quote_form },
    .{ "fn*", .fn_star },
    .{ "let*", .let_star },
    .{ "loop*", .loop_star },
    .{ "recur", .recur_form },
    .{ "try", .try_form },
    .{ "throw", .throw_form },
});

// --- Top-level entry ---

/// Analyse `form` and return the resulting Node tree. Top-level
/// callers pass `scope = null`; recursion threads a `Scope` chain
/// while inside a `let*` / `fn*`.
///
/// `macro_table` carries the bootstrap-macro Zig transforms; it is
/// populated once at startup by `lang.macro_transforms.registerInto`
/// and threaded through every recursive call so a macro produced by
/// expansion is itself expanded on the next pass. Callers that don't
/// need macros (early bootstrap, micro-tests) can pass an empty
/// Table — non-macro Vars short-circuit through `expandIfMacro`.
pub fn analyze(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    return switch (form.data) {
        .nil => try makeConstant(arena, .nil_val, form),
        .boolean => |b| try makeConstant(arena, if (b) .true_val else .false_val, form),
        .integer => |i| try makeConstant(arena, Value.initInteger(i), form),
        .float => |f| try makeConstant(arena, Value.initFloat(f), form),
        .keyword => |sym| {
            const v = try keyword.intern(rt, sym.ns, sym.name);
            return try makeConstant(arena, v, form);
        },
        .symbol => |sym| try analyzeSymbol(arena, env, scope, sym, form),
        .list => |items| try analyzeList(arena, rt, env, scope, items, form, macro_table),
        .string => |s| {
            const v = try string_collection.alloc(rt, s);
            return try makeConstant(arena, v, form);
        },
        // Vector / map as expression values land in later Phase 3
        // tasks once their heap shape ships. NotImplemented for now.
        .vector => error_mod.setErrorFmt(.analysis, .not_implemented, form.location, "Vector literal as expression value not yet supported (Phase 3+)", .{}),
        .map => error_mod.setErrorFmt(.analysis, .not_implemented, form.location, "Map literal as expression value not yet supported (Phase 3+)", .{}),
    };
}

// --- Helpers ---

fn makeConstant(arena: std.mem.Allocator, v: Value, form: Form) !*const Node {
    const n = try arena.create(Node);
    n.* = .{ .constant = .{ .value = v, .loc = form.location } };
    return n;
}

/// Render a symbol with its namespace prefix when present, e.g.
/// `clojure.core/map` or just `foo`.
fn symFullName(sym: SymbolRef) []const u8 {
    // The fast path keeps caller-friendly slices; namespace-qualified
    // names are concatenated into a small static buffer below — only
    // used in error messages, so a 256-byte threadlocal cache is fine.
    if (sym.ns == null) return sym.name;
    const total = sym.ns.?.len + 1 + sym.name.len;
    if (total > sym_name_buf.len) return sym.name; // give up; keep just the local name
    @memcpy(sym_name_buf[0..sym.ns.?.len], sym.ns.?);
    sym_name_buf[sym.ns.?.len] = '/';
    @memcpy(sym_name_buf[sym.ns.?.len + 1 ..][0..sym.name.len], sym.name);
    return sym_name_buf[0..total];
}

threadlocal var sym_name_buf: [256]u8 = undefined;

// --- Symbol resolution ---

fn analyzeSymbol(
    arena: std.mem.Allocator,
    env: *Env,
    scope: ?*const Scope,
    sym: SymbolRef,
    form: Form,
) AnalyzeError!*const Node {
    // Locals can only match unqualified symbols.
    if (sym.ns == null and scope != null) {
        if (scope.?.lookup(sym.name)) |slot| {
            const n = try arena.create(Node);
            n.* = .{ .local_ref = .{
                .name = sym.name,
                .index = slot,
                .loc = form.location,
            } };
            return n;
        }
    }
    // Global Var resolution.
    const ns = if (sym.ns) |ns_name|
        env.findNs(ns_name) orelse return error_mod.setErrorFmt(.analysis, .name_error, form.location, "No namespace: '{s}'", .{ns_name})
    else
        env.current_ns orelse return error_mod.setErrorFmt(.analysis, .name_error, form.location, "No current namespace; cannot resolve '{s}'", .{sym.name});
    const v_ptr = ns.resolve(sym.name) orelse return error_mod.setErrorFmt(.analysis, .name_error, form.location, "Unable to resolve symbol: '{s}'", .{symFullName(sym)});
    const n = try arena.create(Node);
    n.* = .{ .var_ref = .{ .var_ptr = v_ptr, .loc = form.location } };
    return n;
}

// --- List dispatch (special form vs call) ---

fn analyzeList(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    if (items.len == 0) {
        // The empty-list literal `()` evaluates to () in Clojure, which
        // requires a heap List Value the analyser doesn't have yet
        // (Phase 5 collections). Defer cleanly.
        return error_mod.setErrorFmt(.analysis, .not_implemented, form.location, "Empty list as expression value not yet supported (Phase 5+)", .{});
    }
    if (items[0].data == .symbol) {
        const head = items[0].data.symbol;
        // Special forms win first — they cannot be macros even if a
        // user `def`s a `^:macro` Var with the same name.
        if (head.ns == null) {
            if (SPECIAL_FORMS.get(head.name)) |kind| {
                return analyzeSpecial(arena, rt, env, scope, kind, items, form, macro_table);
            }
        }
        // Macro path: only consult the table when we can actually
        // resolve `head` to a Var in the current ns. A failed lookup
        // here is **not** a name error — analyzeCall will produce
        // that with the correct location after we fall through.
        if (head.ns == null and scope != null and scope.?.lookup(head.name) != null) {
            // shadowed by a local: not a macro
        } else {
            if (resolveMaybe(env, head)) |v_ptr| {
                if (try macro_dispatch.expandIfMacro(
                    arena,
                    rt,
                    env,
                    macro_table,
                    v_ptr,
                    head.name,
                    items[1..],
                    form.location,
                )) |expanded| {
                    return analyze(arena, rt, env, scope, expanded, macro_table);
                }
            }
        }
    }
    return analyzeCall(arena, rt, env, scope, items, form, macro_table);
}

/// Best-effort symbol-to-Var resolution that swallows misses. Used by
/// the macro check in `analyzeList`; the genuine resolution-with-error
/// path is in `analyzeSymbol`. Returns null on miss so the caller can
/// fall through to a regular call (where the error will land with the
/// right `name_error` Kind).
fn resolveMaybe(env: *Env, sym: SymbolRef) ?*Var {
    const ns = if (sym.ns) |n| (env.findNs(n) orelse return null) else (env.current_ns orelse return null);
    return ns.resolve(sym.name);
}

fn analyzeCall(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    const callee = try analyze(arena, rt, env, scope, items[0], macro_table);
    var arg_nodes = try arena.alloc(Node, items.len - 1);
    for (items[1..], 0..) |arg_form, i| {
        const arg_node = try analyze(arena, rt, env, scope, arg_form, macro_table);
        arg_nodes[i] = arg_node.*;
    }
    const n = try arena.create(Node);
    n.* = .{ .call_node = .{
        .callee = callee,
        .args = arg_nodes,
        .loc = form.location,
    } };
    return n;
}

// --- Special forms ---

fn analyzeSpecial(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    kind: SpecialFormKind,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    return switch (kind) {
        .def => analyzeDef(arena, rt, env, scope, items, form, macro_table),
        .if_form => analyzeIf(arena, rt, env, scope, items, form, macro_table),
        .do_form => analyzeDo(arena, rt, env, scope, items, form, macro_table),
        .quote_form => analyzeQuote(arena, rt, items, form),
        .fn_star => analyzeFnStar(arena, rt, env, scope, items, form, macro_table),
        .let_star => analyzeLetStar(arena, rt, env, scope, items, form, macro_table),
        .loop_star => analyzeLoopStar(arena, rt, env, scope, items, form, macro_table),
        .recur_form => analyzeRecur(arena, rt, env, scope, items, form, macro_table),
        .try_form => analyzeTry(arena, rt, env, scope, items, form, macro_table),
        .throw_form => analyzeThrow(arena, rt, env, scope, items, form, macro_table),
    };
}

fn analyzeDef(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    // (def name) | (def name value)
    if (items.len < 2 or items.len > 3)
        return error_mod.setErrorFmt(.analysis, .syntax_error, form.location, "def expects 1 or 2 args, got {d}", .{items.len - 1});
    if (items[1].data != .symbol)
        return error_mod.setErrorFmt(.analysis, .syntax_error, items[1].location, "First argument to def must be a symbol", .{});
    const name_sym = items[1].data.symbol;
    if (name_sym.ns != null)
        return error_mod.setErrorFmt(.analysis, .syntax_error, items[1].location, "def name must not be namespace-qualified: '{s}/{s}'", .{ name_sym.ns.?, name_sym.name });
    const value_node = if (items.len == 3)
        try analyze(arena, rt, env, scope, items[2], macro_table)
    else
        try makeConstant(arena, .nil_val, items[1]);
    const n = try arena.create(Node);
    n.* = .{ .def_node = .{
        .name = name_sym.name,
        .value_expr = value_node,
        .loc = form.location,
    } };
    return n;
}

fn analyzeIf(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    if (items.len < 3 or items.len > 4)
        return error_mod.setErrorFmt(.analysis, .syntax_error, form.location, "if expects 2 or 3 args, got {d}", .{items.len - 1});
    const cond = try analyze(arena, rt, env, scope, items[1], macro_table);
    const then_b = try analyze(arena, rt, env, scope, items[2], macro_table);
    const else_b: ?*const Node = if (items.len == 4)
        try analyze(arena, rt, env, scope, items[3], macro_table)
    else
        null;
    const n = try arena.create(Node);
    n.* = .{ .if_node = .{
        .cond = cond,
        .then_branch = then_b,
        .else_branch = else_b,
        .loc = form.location,
    } };
    return n;
}

fn analyzeDo(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    var forms = try arena.alloc(Node, items.len - 1);
    for (items[1..], 0..) |f, i| {
        const sub = try analyze(arena, rt, env, scope, f, macro_table);
        forms[i] = sub.*;
    }
    const n = try arena.create(Node);
    n.* = .{ .do_node = .{ .forms = forms, .loc = form.location } };
    return n;
}

fn analyzeQuote(
    arena: std.mem.Allocator,
    rt: *Runtime,
    items: []const Form,
    form: Form,
) AnalyzeError!*const Node {
    if (items.len != 2)
        return error_mod.setErrorFmt(.analysis, .syntax_error, form.location, "quote expects 1 arg, got {d}", .{items.len - 1});
    const v = try formToValue(rt, items[1]);
    const n = try arena.create(Node);
    n.* = .{ .quote_node = .{ .quoted = v, .loc = form.location } };
    return n;
}

/// Form atom → Value lift (used by `quote` only in Phase 2). Symbols,
/// strings, and collection literals need heap support that lands in
/// later phases.
fn formToValue(rt: *Runtime, form: Form) AnalyzeError!Value {
    return switch (form.data) {
        .nil => .nil_val,
        .boolean => |b| if (b) .true_val else .false_val,
        .integer => |i| Value.initInteger(i),
        .float => |f| Value.initFloat(f),
        .keyword => |sym| try keyword.intern(rt, sym.ns, sym.name),
        .string => |s| try string_collection.alloc(rt, s),
        .list => |items| try listFormToValue(rt, items, form.location),
        .symbol => error_mod.setErrorFmt(.analysis, .not_implemented, form.location, "Quoted symbol as Value not yet supported (Phase 3.7+)", .{}),
        .vector => error_mod.setErrorFmt(.analysis, .not_implemented, form.location, "Quoted vector as Value not yet supported (Phase 3+)", .{}),
        .map => error_mod.setErrorFmt(.analysis, .not_implemented, form.location, "Quoted map as Value not yet supported (Phase 3+)", .{}),
    };
}

/// Build a heap List Value by recursively lifting each element to a
/// Value. Empty list → nil (matches Clojure's `(quote ())` → `()` /
/// `()` is `nil`-equivalent on `rest`/`first`). Used by `quote`.
fn listFormToValue(rt: *Runtime, items: []const Form, loc: SourceLocation) AnalyzeError!Value {
    _ = loc;
    var i = items.len;
    var acc: Value = .nil_val;
    while (i > 0) {
        i -= 1;
        const head = try formToValue(rt, items[i]);
        acc = try list_collection.consHeap(rt, head, acc);
    }
    return acc;
}

fn analyzeFnStar(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    // (fn* [params] body...)
    if (items.len < 3)
        return error_mod.setErrorFmt(.analysis, .syntax_error, form.location, "fn* requires a parameter vector and a body", .{});
    if (items[1].data != .vector)
        return error_mod.setErrorFmt(.analysis, .syntax_error, items[1].location, "fn* parameter list must be a vector", .{});
    const params_form = items[1].data.vector;

    var has_rest = false;
    var arity: u16 = 0;
    var param_names: std.ArrayList([]const u8) = .empty;
    defer param_names.deinit(arena);

    var i: usize = 0;
    while (i < params_form.len) : (i += 1) {
        if (params_form[i].data != .symbol)
            return error_mod.setErrorFmt(.analysis, .syntax_error, params_form[i].location, "fn* parameter must be a symbol", .{});
        const ps = params_form[i].data.symbol;
        if (ps.ns != null)
            return error_mod.setErrorFmt(.analysis, .syntax_error, params_form[i].location, "fn* parameter must not be namespace-qualified", .{});
        if (std.mem.eql(u8, ps.name, "&")) {
            // `& rest`: the next symbol is the rest-parameter.
            if (i + 1 >= params_form.len)
                return error_mod.setErrorFmt(.analysis, .syntax_error, params_form[i].location, "fn* '&' must be followed by a rest-parameter symbol", .{});
            if (params_form[i + 1].data != .symbol)
                return error_mod.setErrorFmt(.analysis, .syntax_error, params_form[i + 1].location, "fn* rest-parameter must be a symbol", .{});
            try param_names.append(arena, params_form[i + 1].data.symbol.name);
            has_rest = true;
            break;
        }
        try param_names.append(arena, ps.name);
        arity += 1;
    }

    // `fn*` is a recur target: `recur` inside the body rebinds the
    // parameter slots and re-enters. arity counts mandatory params
    // only — Clojure's recur cannot rebind the rest-parameter as a
    // single arg, so we exclude `& rest` from the recur arity.
    const recur_arity = arity;
    const slot_base: u16 = if (scope) |s| s.next_slot else 0;
    var child_scope = if (scope) |s|
        Scope.childWithRecur(s, .{ .arity = recur_arity, .slot_base = slot_base, .kind = .fn_kw })
    else
        Scope{ .recur_target = .{ .arity = recur_arity, .slot_base = 0, .kind = .fn_kw } };
    defer child_scope.deinit(arena);
    for (param_names.items) |name| {
        _ = try child_scope.declare(arena, name);
    }

    const body_node = try analyzeBody(arena, rt, env, &child_scope, items[2..], form, macro_table);

    const n = try arena.create(Node);
    n.* = .{ .fn_node = .{
        .arity = arity,
        .has_rest = has_rest,
        .params = try arena.dupe([]const u8, param_names.items),
        .body = body_node,
        .slot_base = slot_base,
        .loc = form.location,
    } };
    return n;
}

/// Fold multiple body forms into a `do_node`; a single body form is
/// returned as-is. Used by `fn*` and `let*`.
fn analyzeBody(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: *const Scope,
    body_forms: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    if (body_forms.len == 1) {
        return analyze(arena, rt, env, scope, body_forms[0], macro_table);
    }
    var sub = try arena.alloc(Node, body_forms.len);
    for (body_forms, 0..) |f, i| {
        const n = try analyze(arena, rt, env, scope, f, macro_table);
        sub[i] = n.*;
    }
    const n = try arena.create(Node);
    n.* = .{ .do_node = .{ .forms = sub, .loc = form.location } };
    return n;
}

fn analyzeLetStar(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    // (let* [k1 v1 k2 v2 ...] body...)
    if (items.len < 3)
        return error_mod.setErrorFmt(.analysis, .syntax_error, form.location, "let* requires a binding vector and a body", .{});
    if (items[1].data != .vector)
        return error_mod.setErrorFmt(.analysis, .syntax_error, items[1].location, "let* bindings must be a vector", .{});
    const binding_forms = items[1].data.vector;
    if (binding_forms.len % 2 != 0)
        return error_mod.setErrorFmt(.analysis, .syntax_error, items[1].location, "let* bindings must have an even number of forms", .{});

    var child_scope = if (scope) |s| Scope.child(s) else Scope{};
    defer child_scope.deinit(arena);

    var bindings = try arena.alloc(node_mod.LetNode.Binding, binding_forms.len / 2);
    var bi: usize = 0;
    var fi: usize = 0;
    while (fi < binding_forms.len) : (fi += 2) {
        if (binding_forms[fi].data != .symbol)
            return error_mod.setErrorFmt(.analysis, .syntax_error, binding_forms[fi].location, "let* binding name must be a symbol", .{});
        const name_sym = binding_forms[fi].data.symbol;
        if (name_sym.ns != null)
            return error_mod.setErrorFmt(.analysis, .syntax_error, binding_forms[fi].location, "let* binding name must not be namespace-qualified", .{});
        // Analyse the value *before* declaring the name so each value
        // expression sees the pre-shadow scope (Clojure `let` semantics:
        // bindings are sequential; later bindings see earlier ones, but
        // each value is evaluated in the scope-before-its-own-binding).
        const value_node = try analyze(arena, rt, env, &child_scope, binding_forms[fi + 1], macro_table);
        const slot = try child_scope.declare(arena, name_sym.name);
        bindings[bi] = .{
            .name = name_sym.name,
            .index = slot,
            .value_expr = value_node,
        };
        bi += 1;
    }

    const body_node = try analyzeBody(arena, rt, env, &child_scope, items[2..], form, macro_table);

    const n = try arena.create(Node);
    n.* = .{ .let_node = .{
        .bindings = bindings,
        .body = body_node,
        .loc = form.location,
    } };
    return n;
}

// --- loop* / recur / throw / try ---

fn analyzeLoopStar(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    // (loop* [k1 v1 k2 v2 ...] body...)
    if (items.len < 3)
        return error_mod.setErrorFmt(.analysis, .syntax_error, form.location, "loop* requires a binding vector and a body", .{});
    if (items[1].data != .vector)
        return error_mod.setErrorFmt(.analysis, .syntax_error, items[1].location, "loop* bindings must be a vector", .{});
    const binding_forms = items[1].data.vector;
    if (binding_forms.len % 2 != 0)
        return error_mod.setErrorFmt(.analysis, .syntax_error, items[1].location, "loop* bindings must have an even number of forms", .{});

    const arity_u: u16 = @intCast(binding_forms.len / 2);
    const slot_base: u16 = if (scope) |s| s.next_slot else 0;

    // Pre-allocate the scope WITH the recur target so the binding
    // value-exprs cannot accidentally close over it. (Clojure's loop
    // values are evaluated in the parent scope; recur is only valid
    // *inside* the loop body. We mirror this by reusing the parent
    // scope for value analysis below.)
    var child_scope = if (scope) |s|
        Scope.childWithRecur(s, .{ .arity = arity_u, .slot_base = slot_base, .kind = .loop_kw })
    else
        Scope{ .recur_target = .{ .arity = arity_u, .slot_base = 0, .kind = .loop_kw } };
    defer child_scope.deinit(arena);

    var bindings = try arena.alloc(node_mod.LetNode.Binding, arity_u);
    var bi: usize = 0;
    var fi: usize = 0;
    while (fi < binding_forms.len) : (fi += 2) {
        if (binding_forms[fi].data != .symbol)
            return error_mod.setErrorFmt(.analysis, .syntax_error, binding_forms[fi].location, "loop* binding name must be a symbol", .{});
        const name_sym = binding_forms[fi].data.symbol;
        if (name_sym.ns != null)
            return error_mod.setErrorFmt(.analysis, .syntax_error, binding_forms[fi].location, "loop* binding name must not be namespace-qualified", .{});
        // Value is analysed in the *parent* scope (recur is scoped to
        // the body, not to siblings; matching Clojure's semantics for
        // initial values).
        const value_node = try analyze(arena, rt, env, scope, binding_forms[fi + 1], macro_table);
        const slot = try child_scope.declare(arena, name_sym.name);
        bindings[bi] = .{
            .name = name_sym.name,
            .index = slot,
            .value_expr = value_node,
        };
        bi += 1;
    }

    const body_node = try analyzeBody(arena, rt, env, &child_scope, items[2..], form, macro_table);

    const n = try arena.create(Node);
    n.* = .{ .loop_node = .{
        .bindings = bindings,
        .body = body_node,
        .loc = form.location,
    } };
    return n;
}

fn analyzeRecur(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    const target = if (scope) |s| s.recur_target else null;
    const tgt = target orelse return error_mod.setErrorFmt(.analysis, .syntax_error, form.location, "recur is only valid inside a loop* or fn*", .{});

    const supplied: u16 = @intCast(items.len - 1);
    if (supplied != tgt.arity) {
        const kind_str = switch (tgt.kind) {
            .loop_kw => "loop*",
            .fn_kw => "fn*",
        };
        return error_mod.setErrorFmt(.analysis, .arity_error, form.location, "recur of {s}: expected {d} arg(s), got {d}", .{ kind_str, tgt.arity, supplied });
    }

    var args = try arena.alloc(Node, supplied);
    for (items[1..], 0..) |arg_form, i| {
        const sub = try analyze(arena, rt, env, scope, arg_form, macro_table);
        args[i] = sub.*;
    }

    const n = try arena.create(Node);
    n.* = .{ .recur_node = .{ .args = args, .loc = form.location } };
    return n;
}

fn analyzeThrow(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    if (items.len != 2)
        return error_mod.setErrorFmt(.analysis, .syntax_error, form.location, "throw expects 1 arg, got {d}", .{items.len - 1});
    const expr = try analyze(arena, rt, env, scope, items[1], macro_table);

    const n = try arena.create(Node);
    n.* = .{ .throw_node = .{ .expr = expr, .loc = form.location } };
    return n;
}

fn analyzeTry(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    // Layout (Clojure-faithful):
    //   (try body* (catch Class binding catch-body*)* (finally fin-body*)?)
    //
    // body* and catch / finally clauses can interleave only in that
    // order: any plain expression must precede the first clause. We
    // walk the rest from the front, collecting body forms until we
    // see a leading-symbol catch/finally; from there on, only catch
    // clauses are accepted, with at most one trailing finally.

    const rest = items[1..];
    var split: usize = 0;
    while (split < rest.len) : (split += 1) {
        if (isClauseHead(rest[split])) break;
    }

    const body_forms = rest[0..split];
    const clause_forms = rest[split..];

    // Analyse body. Empty body is legal (`(try)` evaluates to nil).
    const body_node = if (body_forms.len == 0)
        try makeConstant(arena, .nil_val, form)
    else if (body_forms.len == 1)
        try analyze(arena, rt, env, scope, body_forms[0], macro_table)
    else blk: {
        var sub = try arena.alloc(Node, body_forms.len);
        for (body_forms, 0..) |f, i| {
            const n_b = try analyze(arena, rt, env, scope, f, macro_table);
            sub[i] = n_b.*;
        }
        const dn = try arena.create(Node);
        dn.* = .{ .do_node = .{ .forms = sub, .loc = form.location } };
        break :blk dn;
    };

    // Walk clauses.
    var clauses: std.ArrayList(node_mod.TryNode.CatchClause) = .empty;
    defer clauses.deinit(arena);
    var finally_node: ?*const Node = null;
    var seen_finally = false;

    for (clause_forms) |cf| {
        if (seen_finally)
            return error_mod.setErrorFmt(.analysis, .syntax_error, cf.location, "try: clauses must not appear after `finally`", .{});
        const head = cf.data.list[0].data.symbol.name;
        if (std.mem.eql(u8, head, "catch")) {
            const cc = try analyzeCatchClause(arena, rt, env, scope, cf, macro_table);
            try clauses.append(arena, cc);
        } else if (std.mem.eql(u8, head, "finally")) {
            const fn_b = try analyzeFinallyClause(arena, rt, env, scope, cf, macro_table);
            finally_node = fn_b;
            seen_finally = true;
        } else unreachable; // isClauseHead gated this
    }

    const n = try arena.create(Node);
    n.* = .{ .try_node = .{
        .body = body_node,
        .catch_clauses = try arena.dupe(node_mod.TryNode.CatchClause, clauses.items),
        .finally_body = finally_node,
        .loc = form.location,
    } };
    return n;
}

fn isClauseHead(f: Form) bool {
    if (f.data != .list) return false;
    const items = f.data.list;
    if (items.len == 0) return false;
    if (items[0].data != .symbol) return false;
    const head = items[0].data.symbol;
    if (head.ns != null) return false;
    return std.mem.eql(u8, head.name, "catch") or std.mem.eql(u8, head.name, "finally");
}

fn analyzeCatchClause(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    clause: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!node_mod.TryNode.CatchClause {
    // (catch ClassName binding-sym body...)
    const items = clause.data.list;
    if (items.len < 4)
        return error_mod.setErrorFmt(.analysis, .syntax_error, clause.location, "catch requires (catch <Class> <binding> <body>...)", .{});
    if (items[1].data != .symbol)
        return error_mod.setErrorFmt(.analysis, .syntax_error, items[1].location, "catch class must be a symbol", .{});
    if (items[2].data != .symbol)
        return error_mod.setErrorFmt(.analysis, .syntax_error, items[2].location, "catch binding must be a symbol", .{});
    const class_sym = items[1].data.symbol;
    const bind_sym = items[2].data.symbol;
    if (bind_sym.ns != null)
        return error_mod.setErrorFmt(.analysis, .syntax_error, items[2].location, "catch binding must not be namespace-qualified", .{});

    // Analyse the catch body in a child scope that declares the binding.
    var child_scope = if (scope) |s| Scope.child(s) else Scope{};
    defer child_scope.deinit(arena);
    const slot = try child_scope.declare(arena, bind_sym.name);

    const body_forms = items[3..];
    const body_node = if (body_forms.len == 1)
        try analyze(arena, rt, env, &child_scope, body_forms[0], macro_table)
    else blk: {
        var sub = try arena.alloc(Node, body_forms.len);
        for (body_forms, 0..) |f, i| {
            const n_b = try analyze(arena, rt, env, &child_scope, f, macro_table);
            sub[i] = n_b.*;
        }
        const dn = try arena.create(Node);
        dn.* = .{ .do_node = .{ .forms = sub, .loc = clause.location } };
        break :blk dn;
    };

    return .{
        .class_name = symFullName(class_sym),
        .binding_name = bind_sym.name,
        .binding_index = slot,
        .body = body_node,
        .loc = clause.location,
    };
}

fn analyzeFinallyClause(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    clause: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    // (finally body...)
    const items = clause.data.list;
    const body_forms = items[1..];
    if (body_forms.len == 0)
        return makeConstant(arena, .nil_val, clause);
    if (body_forms.len == 1)
        return analyze(arena, rt, env, scope, body_forms[0], macro_table);
    var sub = try arena.alloc(Node, body_forms.len);
    for (body_forms, 0..) |f, i| {
        const n_b = try analyze(arena, rt, env, scope, f, macro_table);
        sub[i] = n_b.*;
    }
    const dn = try arena.create(Node);
    dn.* = .{ .do_node = .{ .forms = sub, .loc = clause.location } };
    return dn;
}

// --- tests ---

const testing = std.testing;
const Reader = @import("reader.zig").Reader;

const TestFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,
    env: Env,
    arena: std.heap.ArenaAllocator,
    macro_table: macro_dispatch.Table,

    fn init(self: *TestFixture, alloc: std.mem.Allocator) !void {
        self.threaded = std.Io.Threaded.init(alloc, .{});
        self.rt = Runtime.init(self.threaded.io(), alloc);
        self.env = try Env.init(&self.rt);
        self.arena = std.heap.ArenaAllocator.init(alloc);
        self.macro_table = macro_dispatch.Table.init(alloc);
    }

    fn deinit(self: *TestFixture) void {
        self.macro_table.deinit();
        self.arena.deinit();
        self.env.deinit();
        self.rt.deinit();
        self.threaded.deinit();
    }

    fn analyzeStr(self: *TestFixture, source: []const u8) !*const Node {
        var reader = Reader.init(self.arena.allocator(), source);
        const form_opt = try reader.read();
        const form = form_opt orelse return AnalyzeError.SyntaxError;
        return analyze(self.arena.allocator(), &self.rt, &self.env, null, form, &self.macro_table);
    }
};

test "analyse atoms: nil / int / keyword interned consistently" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectEqual(Value.nil_val, (try fix.analyzeStr("nil")).constant.value);
    try testing.expect((try fix.analyzeStr("42")).constant.value.tag() == .integer);

    const k1 = try fix.analyzeStr(":foo");
    const k2 = try fix.analyzeStr(":foo");
    try testing.expectEqual(k1.constant.value, k2.constant.value);
}

test "unbound symbol → NameError" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    try testing.expectError(AnalyzeError.NameError, fix.analyzeStr("undefined-symbol"));
}

test "name resolution failure populates last_error with symbol + analysis phase" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    error_mod.clearLastError();
    try testing.expectError(AnalyzeError.NameError, fix.analyzeStr("undefined-symbol"));
    const info = error_mod.getLastError() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(error_mod.Kind.name_error, info.kind);
    try testing.expectEqual(error_mod.Phase.analysis, info.phase);
    try testing.expect(std.mem.indexOf(u8, info.message, "undefined-symbol") != null);
}

test "syntax error on (if ...) carries form location" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    error_mod.clearLastError();
    try testing.expectError(AnalyzeError.SyntaxError, fix.analyzeStr("(if 1 2 3 4)"));
    const info = error_mod.getLastError() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(error_mod.Kind.syntax_error, info.kind);
    try testing.expectEqual(error_mod.Phase.analysis, info.phase);
    try testing.expect(std.mem.indexOf(u8, info.message, "if expects") != null);
}

test "string-literal-as-expression lifts to a .string Value (Phase 3.5)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const n = try fix.analyzeStr("\"hello\"");
    try testing.expect(n.* == .constant);
    try testing.expect(n.constant.value.tag() == .string);
    try testing.expectEqualStrings("hello", string_collection.asString(n.constant.value));
}

test "vector-literal-as-expression remains NotImplemented (Phase 3.6+)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    error_mod.clearLastError();
    try testing.expectError(AnalyzeError.NotImplemented, fix.analyzeStr("[1 2 3]"));
    const info = error_mod.getLastError() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(error_mod.Kind.not_implemented, info.kind);
}

test "resolved symbol → var_ref pointing at the right Var.root" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "x", .true_val);
    const n = try fix.analyzeStr("x");
    try testing.expect(n.* == .var_ref);
    try testing.expectEqual(Value.true_val, n.var_ref.var_ptr.root);
}

test "(if cond then else) shape; missing else stays null" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const with_else = try fix.analyzeStr("(if true 1 2)");
    try testing.expectEqual(Value.true_val, with_else.if_node.cond.constant.value);
    try testing.expect(with_else.if_node.else_branch != null);

    const no_else = try fix.analyzeStr("(if true 1)");
    try testing.expect(no_else.if_node.else_branch == null);
}

test "(do ...) gathers all sub-forms" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const n = try fix.analyzeStr("(do 1 2 3)");
    try testing.expectEqual(@as(usize, 3), n.do_node.forms.len);
}

test "(quote ...) lifts atoms; symbols still NotImplemented" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectEqual(Value.nil_val, (try fix.analyzeStr("(quote nil)")).quote_node.quoted);
    try testing.expectError(AnalyzeError.NotImplemented, fix.analyzeStr("(quote x)"));
}

test "(let* [x 1] x) — single binding + body local_ref" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const n = try fix.analyzeStr("(let* [x 1] x)");
    try testing.expectEqual(@as(usize, 1), n.let_node.bindings.len);
    try testing.expectEqualStrings("x", n.let_node.bindings[0].name);
    try testing.expectEqual(@as(u16, 0), n.let_node.bindings[0].index);
    try testing.expectEqual(@as(u16, 0), n.let_node.body.local_ref.index);
}

test "(let* [x 1 y 2] (+ x y)) — slot indices increment; body is a call_node" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "+", .nil_val); // dummy so symbol resolves

    const n = try fix.analyzeStr("(let* [x 1 y 2] (+ x y))");
    try testing.expectEqual(@as(u16, 0), n.let_node.bindings[0].index);
    try testing.expectEqual(@as(u16, 1), n.let_node.bindings[1].index);
    try testing.expectEqual(@as(usize, 2), n.let_node.body.call_node.args.len);
}

test "nested let* — inner binding shadows outer with new slot" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const n = try fix.analyzeStr("(let* [x 1] (let* [x 2] x))");
    const inner = n.let_node.body;
    try testing.expectEqual(@as(u16, 1), inner.let_node.bindings[0].index);
    try testing.expectEqual(@as(u16, 1), inner.let_node.body.local_ref.index);
}

test "(fn* [x] x) — arity, params, body local_ref" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const n = try fix.analyzeStr("(fn* [x] x)");
    try testing.expectEqual(@as(u16, 1), n.fn_node.arity);
    try testing.expect(!n.fn_node.has_rest);
    try testing.expectEqualStrings("x", n.fn_node.params[0]);
    try testing.expectEqual(@as(u16, 0), n.fn_node.body.local_ref.index);
}

test "(fn* [x & rest] x) — has_rest is true; params include rest" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const n = try fix.analyzeStr("(fn* [x & rest] x)");
    try testing.expectEqual(@as(u16, 1), n.fn_node.arity);
    try testing.expect(n.fn_node.has_rest);
    try testing.expectEqual(@as(usize, 2), n.fn_node.params.len);
    try testing.expectEqualStrings("rest", n.fn_node.params[1]);
}

test "(def x 1) records name + value expr" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const n = try fix.analyzeStr("(def x 1)");
    try testing.expectEqualStrings("x", n.def_node.name);
    try testing.expect(n.def_node.value_expr.constant.value.tag() == .integer);
}

test "(if 1 2 3 4) — too many args is SyntaxError" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    try testing.expectError(AnalyzeError.SyntaxError, fix.analyzeStr("(if 1 2 3 4)"));
}

test "call to a Var-resolved function lands as a call_node with var_ref callee" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "f", .nil_val);
    const n = try fix.analyzeStr("(f 1 2)");
    try testing.expect(n.call_node.callee.* == .var_ref);
    try testing.expectEqual(@as(usize, 2), n.call_node.args.len);
}

test "((fn* [x] x) 41) — direct fn-literal call (Phase-2 exit shape)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const n = try fix.analyzeStr("((fn* [x] x) 41)");
    try testing.expect(n.* == .call_node);
    try testing.expect(n.call_node.callee.* == .fn_node);
    try testing.expectEqual(@as(usize, 1), n.call_node.args.len);
    try testing.expect(n.call_node.args[0].constant.value.tag() == .integer);
}

// --- Phase 3.9 — try / catch / throw / loop* / recur ---

test "(loop* [i 0] (recur 1)) builds a loop_node with a recur_node body" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const n = try fix.analyzeStr("(loop* [i 0] (recur 1))");
    try testing.expect(n.* == .loop_node);
    try testing.expectEqual(@as(usize, 1), n.loop_node.bindings.len);
    try testing.expectEqualStrings("i", n.loop_node.bindings[0].name);
    try testing.expect(n.loop_node.body.* == .recur_node);
    try testing.expectEqual(@as(usize, 1), n.loop_node.body.recur_node.args.len);
}

test "(try 1 (catch ExceptionInfo e 2)) builds a try_node with one catch" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const n = try fix.analyzeStr("(try 1 (catch ExceptionInfo e 2))");
    try testing.expect(n.* == .try_node);
    try testing.expect(n.try_node.body.* == .constant);
    try testing.expectEqual(@as(usize, 1), n.try_node.catch_clauses.len);
    try testing.expectEqualStrings("ExceptionInfo", n.try_node.catch_clauses[0].class_name);
    try testing.expectEqualStrings("e", n.try_node.catch_clauses[0].binding_name);
    try testing.expect(n.try_node.finally_body == null);
}

test "(try 1 (finally 2)) attaches a finally body" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const n = try fix.analyzeStr("(try 1 (finally 2))");
    try testing.expect(n.* == .try_node);
    try testing.expectEqual(@as(usize, 0), n.try_node.catch_clauses.len);
    try testing.expect(n.try_node.finally_body != null);
}

test "(throw 1) builds a throw_node carrying the expr" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const n = try fix.analyzeStr("(throw 1)");
    try testing.expect(n.* == .throw_node);
    try testing.expect(n.throw_node.expr.* == .constant);
}

test "recur outside any loop*/fn* is a syntax error" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectError(AnalyzeError.SyntaxError, fix.analyzeStr("(recur 1)"));
    const info = error_mod.peekLastError() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(error_mod.Phase.analysis, info.phase);
    try testing.expectEqual(error_mod.Kind.syntax_error, info.kind);
}

test "recur arity mismatch reports the loop's expected arity" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectError(AnalyzeError.ArityError, fix.analyzeStr("(loop* [i 0 j 0] (recur 1))"));
    const info = error_mod.peekLastError() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(error_mod.Kind.arity_error, info.kind);
}
