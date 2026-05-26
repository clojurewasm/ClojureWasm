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
const Form = @import("../form.zig").Form;
const FormData = @import("../form.zig").FormData;
const SymbolRef = @import("../form.zig").SymbolRef;
const node_mod = @import("../node.zig");
const Node = node_mod.Node;
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const Var = env_mod.Var;
const keyword = @import("../../runtime/keyword.zig");
const symbol_mod = @import("../../runtime/symbol.zig");
const string_collection = @import("../../runtime/collection/string.zig");
const list_collection = @import("../../runtime/collection/list.zig");
const big_int = @import("../../runtime/numeric/big_int.zig");
const big_decimal = @import("../../runtime/numeric/big_decimal.zig");
const regex_value = @import("../../runtime/regex/value.zig");
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const macro_dispatch = @import("../macro_dispatch.zig");

/// Analyser errors. Phase 2 covers syntax + name resolution only.
/// Aliases the wide `error_mod.ClojureWasmError` set so calls to
/// `error_catalog.raise(.code, loc, args)` type-check; the analyser
/// still only **emits** SyntaxError / NameError / NotImplemented /
/// ArityError / OutOfMemory in practice. See the equivalent comment
/// in `eval/reader.zig` for the design rationale.
pub const AnalyzeError = error_mod.ClojureWasmError;

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
    deftype_form,
    in_ns_form,
    require_form,
    ns_form,
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
    .{ "deftype", .deftype_form },
    .{ "in-ns", .in_ns_form },
    .{ "require", .require_form },
    .{ "ns", .ns_form },
});

/// Forms the analyser recognises but the runtime does not yet
/// support — landed at Phase 4 task 4.21 per ADR-0007 + ADR-0018
/// amendment 2. Each entry raises `unsupported_feature` with the
/// form name in the `.name` slot. Task 4.26.b later promotes these
/// to named per-form Codes (`deftype_not_supported`, etc.).
///
/// Row 7.4 cycle 1 retired `"defrecord"` — it now lowers via
/// `expandDefrecord` in `src/lang/macro_transforms.zig`. Row 7.5
/// cycle 1 retired `"reify"` — it now lowers via `expandReify`.
const STAGED_UNSUPPORTED_FORMS = std.StaticStringMap(void).initComptime(.{
    .{ "definterface", {} },
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
        .big_int_literal => |s| try makeConstant(arena, try parseBigIntLiteral(rt, s, form.location), form),
        .big_decimal_literal => |s| try makeConstant(arena, try parseBigDecimalLiteral(rt, s, form.location), form),
        .regex_literal => |s| try makeConstant(arena, try parseRegexLiteral(rt, s, form.location), form),
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
        // Vector literal in expression position — analyze each child
        // form, emit VectorLiteralNode (Phase 6.9 cycle 4).
        .vector => |items| try analyzeVectorLiteral(arena, rt, env, scope, items, form, macro_table),
        // `{...}` and `#{...}` literals (Phase 6.16.b-2 closes D-059
        // + D-061). Each emits its own LiteralNode shape; eval walks
        // the children and folds into an empty ArrayMap / HashSet.
        .map => |items| try analyzeMapLiteral(arena, rt, env, scope, items, form, macro_table),
        .set => |items| try analyzeSetLiteral(arena, rt, env, scope, items, form, macro_table),
    };
}

// --- Helpers ---

/// Parse `42N`-style digits into a BigInt Value via Managed.setString.
/// Used by both the atom-analyzer path and the quote-lift path.
pub fn parseBigIntLiteral(rt: *Runtime, digits: []const u8, loc: error_mod.SourceLocation) !Value {
    var m = try std.math.big.int.Managed.init(rt.gc.infra);
    defer m.deinit();
    m.setString(10, digits) catch
        return error_catalog.raise(.integer_literal_invalid, loc, .{ .text = digits });
    return try big_int.allocFromManaged(rt, &m);
}

/// Parse `1.5M`-style digits into a BigDecimal Value. The unscaled
/// integer is the input with the decimal point removed; the scale is
/// the number of digits after the dot.
pub fn parseBigDecimalLiteral(rt: *Runtime, digits: []const u8, loc: error_mod.SourceLocation) !Value {
    // Locate the decimal point if any. JVM accepts `1M`, `1.5M`, and
    // exponent `1.5e3M` — the latter is left as a debt row.
    var dot_pos: ?usize = null;
    for (digits, 0..) |c, idx| {
        if (c == '.') {
            dot_pos = idx;
            break;
        }
    }

    // Build unscaled by concatenating the pre-dot and post-dot digit
    // runs into a scratch buffer, then setString.
    var buf: [256]u8 = undefined;
    var buf_len: usize = 0;
    var scale: i32 = 0;
    if (dot_pos) |p| {
        const pre = digits[0..p];
        const post = digits[p + 1 ..];
        if (pre.len + post.len > buf.len) {
            return error_catalog.raise(.float_literal_invalid, loc, .{ .text = digits });
        }
        std.mem.copyForwards(u8, buf[0..pre.len], pre);
        std.mem.copyForwards(u8, buf[pre.len .. pre.len + post.len], post);
        buf_len = pre.len + post.len;
        scale = @intCast(post.len);
    } else {
        if (digits.len > buf.len) {
            return error_catalog.raise(.float_literal_invalid, loc, .{ .text = digits });
        }
        std.mem.copyForwards(u8, buf[0..digits.len], digits);
        buf_len = digits.len;
    }

    var unscaled = try std.math.big.int.Managed.init(rt.gc.infra);
    defer unscaled.deinit();
    unscaled.setString(10, buf[0..buf_len]) catch
        return error_catalog.raise(.float_literal_invalid, loc, .{ .text = digits });

    return try big_decimal.allocFromManagedScale(rt, &unscaled, scale);
}

/// Compile a `#"..."` reader-literal body into a regex Value via
/// `runtime/regex/value.zig::alloc`. Cycle-1 compile errors surface
/// as `feature_not_supported`; cycle 5 wires the
/// `PatternSyntaxException`-aligned error messages (D-051).
///
/// Return type is pinned to `AnalyzeError` so the per-variant
/// CompileError set (UnexpectedToken / NotImplemented / etc.)
/// gets folded into the catalog-raised path; the analyzer
/// signature only knows `AnalyzeError`.
pub fn parseRegexLiteral(rt: *Runtime, body: []const u8, loc: error_mod.SourceLocation) AnalyzeError!Value {
    return regex_value.alloc(rt, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error_catalog.raise(.feature_not_supported, loc, .{
            .name = "regex literal (unsupported syntax in cycle 1)",
        }),
    };
}

pub fn makeConstant(arena: std.mem.Allocator, v: Value, form: Form) !*const Node {
    const n = try arena.create(Node);
    n.* = .{ .constant = .{ .value = v, .loc = form.location } };
    return n;
}

/// Render a symbol with its namespace prefix when present, e.g.
/// `clojure.core/map` or just `foo`.
pub fn symFullName(sym: SymbolRef) []const u8 {
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
    // Global Var resolution. Qualified symbols `s/name` first
    // consult the current ns's alias table (ADR-0035 D3) — alias
    // names take precedence over real ns names (= JVM semantics:
    // `(alias 'str 'clojure.string)` shadows any literal `str` ns).
    const ns = if (sym.ns) |ns_name|
        (if (env.current_ns) |here| here.aliases.get(ns_name) else null) orelse
            env.findNs(ns_name) orelse
            return error_catalog.raise(.namespace_unknown, form.location, .{ .ns = ns_name })
    else
        env.current_ns orelse return error_catalog.raise(.current_namespace_missing, form.location, .{ .sym = sym.name });
    const v_ptr = ns.resolve(sym.name) orelse return error_catalog.raise(.symbol_unresolved, form.location, .{ .sym = symFullName(sym) });
    // ADR-0033 D4 + D8: `^:private` vars cannot be referenced as a
    // symbol from outside their owning namespace. The check fires only
    // when the resolution target is in a different namespace than the
    // currently-active `(in-ns)`. `(var ...)` / quote / macro paths
    // bypass this on purpose per v5 §3.3 — they go through their own
    // analyze arms and do not enter analyzeSymbol.
    if (v_ptr.flags.private) {
        const here = env.current_ns;
        if (here == null or here.? != v_ptr.ns) {
            return error_catalog.raise(.private_access_error, form.location, .{
                .sym = symFullName(sym),
                .ns = v_ptr.ns.name,
            });
        }
    }
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
        return error_catalog.raise(.feature_not_supported, form.location, .{ .name = "Empty list as expression value" });
    }
    if (items[0].data == .symbol) {
        const head = items[0].data.symbol;
        // Special forms win first — they cannot be macros even if a
        // user `def`s a `^:macro` Var with the same name.
        if (head.ns == null) {
            if (SPECIAL_FORMS.get(head.name)) |kind| {
                return analyzeSpecial(arena, rt, env, scope, kind, items, form, macro_table);
            }
            // 5.12.a: `Name.` (trailing dot) -> constructor call.
            if (head.name.len >= 2 and head.name[head.name.len - 1] == '.') {
                return try special_forms.analyzeCtorCall(arena, rt, env, scope, head.name[0 .. head.name.len - 1], items[1..], form, macro_table);
            }
            // 5.12.a: `.field` (leading dot, single arg) -> field access.
            // Arity 2 stays a struct field read per row 7.6 survey §4
            // Option A (finished-form decision).
            if (head.name.len >= 2 and head.name[0] == '.' and items.len == 2) {
                return try special_forms.analyzeFieldAccess(arena, rt, env, scope, head.name[1..], items[1], form, macro_table);
            }
            // Row 7.6 cycle 1: `.method` (leading dot, arity > 2) ->
            // method call dispatched via the row 7.3 dispatch ABI.
            if (head.name.len >= 2 and head.name[0] == '.' and items.len >= 3) {
                return try special_forms.analyzeMethodCall(arena, rt, env, scope, head.name[1..], items[1], items[2..], form, macro_table);
            }
            if (STAGED_UNSUPPORTED_FORMS.has(head.name)) {
                return error_catalog.raise(.feature_not_supported, form.location, .{ .name = head.name });
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
    // ADR-0033 D8: `^:unsupported` declare-only vars raise at the
    // callable position. Other usages (`(var foo)` / quote / passing
    // as data) are allowed — the marker says "calling me is not yet
    // supported", not "I do not exist".
    if (callee.* == .var_ref and callee.var_ref.var_ptr.flags.unsupported) {
        const vp = callee.var_ref.var_ptr;
        var name_buf: [256]u8 = undefined;
        const written = std.fmt.bufPrint(&name_buf, "{s}/{s}", .{ vp.ns.name, vp.name }) catch vp.name;
        return error_catalog.raise(.feature_not_supported_unsupported_var, form.location, .{
            .sym = written,
        });
    }
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

/// `[expr1 expr2 ...]` lift — analyze each element with the full
/// special-form / call-form pipeline, package into VectorLiteralNode.
fn analyzeVectorLiteral(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    const elt_nodes = try arena.alloc(Node, items.len);
    for (items, 0..) |elt_form, i| {
        const elt = try analyze(arena, rt, env, scope, elt_form, macro_table);
        elt_nodes[i] = elt.*;
    }
    const n = try arena.create(Node);
    n.* = .{ .vector_literal_node = .{ .elements = elt_nodes, .loc = form.location } };
    return n;
}

/// `{k1 v1 k2 v2 ...}` lift — analyze each k/v form, package into
/// MapLiteralNode (k0, v0, k1, v1, ...). Reader guarantees the
/// flat pair count is even.
fn analyzeMapLiteral(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    const elt_nodes = try arena.alloc(Node, items.len);
    for (items, 0..) |elt_form, i| {
        const elt = try analyze(arena, rt, env, scope, elt_form, macro_table);
        elt_nodes[i] = elt.*;
    }
    const n = try arena.create(Node);
    n.* = .{ .map_literal_node = .{ .elements = elt_nodes, .loc = form.location } };
    return n;
}

/// `#{e1 e2 ...}` lift — analyze each element, package into
/// SetLiteralNode. Eval conj-folds duplicates into a single entry
/// (set semantics).
fn analyzeSetLiteral(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    const elt_nodes = try arena.alloc(Node, items.len);
    for (items, 0..) |elt_form, i| {
        const elt = try analyze(arena, rt, env, scope, elt_form, macro_table);
        elt_nodes[i] = elt.*;
    }
    const n = try arena.create(Node);
    n.* = .{ .set_literal_node = .{ .elements = elt_nodes, .loc = form.location } };
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
        .def => special_forms.analyzeDef(arena, rt, env, scope, items, form, macro_table),
        .if_form => special_forms.analyzeIf(arena, rt, env, scope, items, form, macro_table),
        .do_form => special_forms.analyzeDo(arena, rt, env, scope, items, form, macro_table),
        .quote_form => special_forms.analyzeQuote(arena, rt, items, form),
        .fn_star => bindings.analyzeFnStar(arena, rt, env, scope, items, form, macro_table),
        .let_star => bindings.analyzeLetStar(arena, rt, env, scope, items, form, macro_table),
        .loop_star => bindings.analyzeLoopStar(arena, rt, env, scope, items, form, macro_table),
        .recur_form => recur.analyzeRecur(arena, rt, env, scope, items, form, macro_table),
        .try_form => try_form.analyzeTry(arena, rt, env, scope, items, form, macro_table),
        .throw_form => special_forms.analyzeThrow(arena, rt, env, scope, items, form, macro_table),
        .deftype_form => special_forms.analyzeDeftype(arena, items, form),
        .in_ns_form => special_forms.analyzeInNs(arena, items, form),
        .require_form => special_forms.analyzeRequire(arena, items, form),
        .ns_form => special_forms.analyzeNs(arena, items, form),
    };
}

const special_forms = @import("special_forms.zig");
const bindings = @import("bindings.zig");
const recur = @import("recur.zig");
const try_form = @import("try_form.zig");

/// `(deftype Name [field1 field2 ...])` per ADR-0007 Option β +
/// ROADMAP §9.7 / 5.12.a. Phase 5.12.a accepts declaration only —
/// protocol method bodies are silently dropped (the analyzer was
/// already raising on them via STAGED_UNSUPPORTED_FORMS prior to
/// this commit; the analyzer now treats trailing forms as no-op
/// until 5.12.d wires protocol method dispatch).
/// Form atom → Value lift (used by `quote` only in Phase 2). Symbols,
/// strings, and collection literals need heap support that lands in
/// later phases. **pub** so `analyzer/special_forms.zig::analyzeQuote`
/// can call back into it (cyclic-import contract).
pub fn formToValue(rt: *Runtime, form: Form) AnalyzeError!Value {
    return switch (form.data) {
        .nil => .nil_val,
        .boolean => |b| if (b) .true_val else .false_val,
        .integer => |i| Value.initInteger(i),
        .float => |f| Value.initFloat(f),
        .big_int_literal => |s| try parseBigIntLiteral(rt, s, form.location),
        .big_decimal_literal => |s| try parseBigDecimalLiteral(rt, s, form.location),
        .regex_literal => |s| try parseRegexLiteral(rt, s, form.location),
        .keyword => |sym| try keyword.intern(rt, sym.ns, sym.name),
        .string => |s| try string_collection.alloc(rt, s),
        .list => |items| try listFormToValue(rt, items),
        .symbol => |sym| try symbol_mod.intern(rt, sym.ns, sym.name),
        .vector => error_catalog.raise(.feature_not_supported, form.location, .{ .name = "Quoted vector as Value" }),
        .map => error_catalog.raise(.feature_not_supported, form.location, .{ .name = "Quoted map as Value" }),
        .set => error_catalog.raise(.feature_not_supported, form.location, .{ .name = "Quoted set as Value" }),
    };
}

/// Build a heap List Value by recursively lifting each element to a
/// Value. Empty list → nil (matches Clojure's `(quote ())` → `()` /
/// `()` is `nil`-equivalent on `rest`/`first`). Used by `quote`.
fn listFormToValue(rt: *Runtime, items: []const Form) AnalyzeError!Value {
    var i = items.len;
    var acc: Value = .nil_val;
    while (i > 0) {
        i -= 1;
        const head = try formToValue(rt, items[i]);
        acc = try list_collection.consHeap(rt, head, acc);
    }
    return acc;
}

// --- tests ---

const testing = std.testing;
const Reader = @import("../reader.zig").Reader;

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
    try testing.expect(std.mem.find(u8, info.message, "undefined-symbol") != null);
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
    try testing.expect(std.mem.find(u8, info.message, "if expects") != null);
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

test "vector-literal-as-expression analyzes into VectorLiteralNode (Phase 6.9 cycle 4)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const n = try fix.analyzeStr("[1 2 3]");
    try testing.expect(n.* == .vector_literal_node);
    try testing.expectEqual(@as(usize, 3), n.vector_literal_node.elements.len);
}

test "resolved symbol → var_ref pointing at the right Var.root" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "x", .true_val, null);
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

test "(quote ...) lifts atoms; symbols lift to interned Symbol Values" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectEqual(Value.nil_val, (try fix.analyzeStr("(quote nil)")).quote_node.quoted);

    // ADR-0037 (T2, 2026-05-26): (quote sym) now interns a Symbol
    // Value (F-004 Group A slot 1). The quoted slot carries a
    // Value with .symbol tag, not the prior NotImplemented raise.
    const sym_node = try fix.analyzeStr("(quote x)");
    try testing.expect(sym_node.quote_node.quoted.tag() == .symbol);
    const sym = symbol_mod.asSymbol(sym_node.quote_node.quoted);
    try testing.expect(sym.ns == null);
    try testing.expectEqualStrings("x", sym.name);
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
    _ = try fix.env.intern(user, "+", .nil_val, null); // dummy so symbol resolves

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
    _ = try fix.env.intern(user, "f", .nil_val, null);
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

test "loop* with 65537 bindings raises an analysis error before the @intCast" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "(loop* [\n");
    var i: usize = 0;
    // One binding pair per line; tokenizer column is u16, so a single
    // 262 KB line would overflow before reaching the analyzer.
    while (i < 65537) : (i += 1) try src.appendSlice(testing.allocator, "x 0\n");
    try src.appendSlice(testing.allocator, "] 1)");

    try testing.expectError(AnalyzeError.NotImplemented, fix.analyzeStr(src.items));
    const info = error_mod.peekLastError() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(error_mod.Phase.analysis, info.phase);
    try testing.expect(std.mem.find(u8, info.message, "loop*") != null);
    try testing.expect(std.mem.find(u8, info.message, "65537") != null);
}

test "recur with 65537 args raises an analysis error before the @intCast" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    // Outer loop arity is 1; recur arity check would otherwise compare
    // 65537 != 1, but the @intCast bound-check fires first.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "(loop* [x 0] (recur\n");
    var i: usize = 0;
    while (i < 65537) : (i += 1) try src.appendSlice(testing.allocator, "0\n");
    try src.appendSlice(testing.allocator, "))");

    try testing.expectError(AnalyzeError.NotImplemented, fix.analyzeStr(src.items));
    const info = error_mod.peekLastError() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(error_mod.Phase.analysis, info.phase);
    try testing.expect(std.mem.find(u8, info.message, "recur") != null);
    try testing.expect(std.mem.find(u8, info.message, "65537") != null);
}

test "recur arity mismatch reports the loop's expected arity" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectError(AnalyzeError.ArityError, fix.analyzeStr("(loop* [i 0 j 0] (recur 1))"));
    const info = error_mod.peekLastError() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(error_mod.Kind.arity_error, info.kind);
}

test "deftype is now a real special form (5.12.a) — analyses without unsupported" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const n = try fix.analyzeStr("(deftype Foo [x y])");
    try testing.expect(n.* == .deftype_node);
    try testing.expectEqualStrings("Foo", n.deftype_node.name);
    try testing.expectEqual(@as(usize, 2), n.deftype_node.fields.len);
}

test "ctor call (Foo. ...) analyses into ctor_call_node" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const n = try fix.analyzeStr("(Foo. 1 2)");
    try testing.expect(n.* == .ctor_call_node);
    try testing.expectEqualStrings("Foo", n.ctor_call_node.type_name);
    try testing.expectEqual(@as(usize, 2), n.ctor_call_node.args.len);
}

test "field access (.x inst) analyses into field_access_node" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    // The target needs to be analyzable. Use a constant integer here
    // because field-access type-checking happens at eval, not analyse.
    const n = try fix.analyzeStr("(.x 1)");
    try testing.expect(n.* == .field_access_node);
    try testing.expectEqualStrings("x", n.field_access_node.field_name);
}

test "definterface still raises unsupported_feature" {
    // Row 7.4 cycle 1: `defrecord` retired (expandDefrecord macro).
    // Row 7.5 cycle 1: `reify` retired (expandReify macro). Only
    // `definterface` remains in the staged wedge.
    inline for ([_][]const u8{"definterface"}) |form_name| {
        var fix: TestFixture = undefined;
        try fix.init(testing.allocator);
        defer fix.deinit();

        const src = "(" ++ form_name ++ " Foo [x])";
        try testing.expectError(AnalyzeError.NotImplemented, fix.analyzeStr(src));
        const info = error_mod.peekLastError() orelse return error.TestUnexpectedResult;
        try testing.expectEqual(error_mod.Kind.not_implemented, info.kind);
        try testing.expect(std.mem.find(u8, info.message, form_name) != null);
        try testing.expect(std.mem.find(u8, info.message, "not supported in ClojureWasm") != null);
    }
}

// Row 7.4 cycle 1: `defrecord` parses cleanly via `expandDefrecord`
// (covered by `test/e2e/phase7_defrecord.sh` since the analyzer
// TestFixture cannot register Layer-2 macros without an upward zone
// import — see `.claude/rules/zone_deps.md`).

// --- ADR-0033 D4 + D8: private + unsupported metadata checks ---

test "analyzeSymbol: same-ns private var resolves successfully" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "-secret", .true_val, .{ .private = true });
    // user is current_ns by default
    const n = try fix.analyzeStr("-secret");
    try testing.expect(n.* == .var_ref);
    try testing.expectEqual(Value.true_val, n.var_ref.var_ptr.root);
    try testing.expect(n.var_ref.var_ptr.flags.private);
}

test "analyzeSymbol: cross-ns private var raises private_access_error" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const other = try fix.env.findOrCreateNs("other.ns");
    _ = try fix.env.intern(other, "-secret", .true_val, .{ .private = true });
    // current_ns is still user
    try testing.expectError(AnalyzeError.NameError, fix.analyzeStr("other.ns/-secret"));
    const info = error_mod.peekLastError() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(error_mod.Kind.name_error, info.kind);
    try testing.expect(std.mem.find(u8, info.message, "private") != null);
    try testing.expect(std.mem.find(u8, info.message, "other.ns") != null);
}

test "analyzeSymbol: cross-ns public var resolves successfully" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const other = try fix.env.findOrCreateNs("other.ns");
    _ = try fix.env.intern(other, "open-name", .true_val, .{ .private = false });
    const n = try fix.analyzeStr("other.ns/open-name");
    try testing.expect(n.* == .var_ref);
    try testing.expectEqual(Value.true_val, n.var_ref.var_ptr.root);
}

test "analyzeCall: unsupported var at callable position raises feature_not_supported_unsupported_var" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const user = fix.env.findNs("user").?;
    _ = try fix.env.intern(user, "todo-fn", .nil_val, .{ .unsupported = true });
    try testing.expectError(AnalyzeError.NotImplemented, fix.analyzeStr("(todo-fn)"));
    const info = error_mod.peekLastError() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(error_mod.Kind.not_implemented, info.kind);
    try testing.expect(std.mem.find(u8, info.message, "todo-fn") != null);
    try testing.expect(std.mem.find(u8, info.message, "declared but not yet supported") != null);
}
