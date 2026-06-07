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
//!   4. **Macro expansion** — `analyzeList` runs `expandIfMacro`
//!      before dispatching, so macro Vars (incl. `defmacro`-defined
//!      and syntax-quoted bodies) expand during analysis.
//!
//! ### Coverage
//!
//! - Atoms: nil / bool / int / float / char / string / keyword
//!   (interned at analyse time).
//! - Collection literals (vector / map / set) as expression values,
//!   with constant-fold lift for fully-literal collections.
//! - Special forms: the ~20 entries in `SPECIAL_FORMS`
//!   (`def` / `defmacro` / `if` / `do` / `quote` / `var` / `fn*` /
//!   `let*` / `letfn*` / `loop*` / `recur` / `binding` / `try` /
//!   `throw` / `in-ns` / `require` / `ns` / `set!` / `.` / `new`),
//!   including multi-arity `fn*` and syntax-quote expansion.
//! - References: symbol → LocalRef / VarRef.
//! - Interop and `ns` / `require` namespace wiring.
//!
//! ### Memory ownership
//!
//! Every Node lands in the caller-supplied `arena` allocator. A single
//! `analyze` call drops the whole sub-tree into the same arena, so
//! eval ends by freeing the arena in one shot — no per-Node free.

const std = @import("std");
const Form = @import("../form.zig").Form;
const TaggedForm = @import("../form.zig").TaggedForm;
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
const lazy_seq_mod = @import("../../runtime/lazy_seq.zig");
const root_set = @import("../../runtime/gc/root_set.zig");
const vector_collection = @import("../../runtime/collection/vector.zig");
const map_collection = @import("../../runtime/collection/map.zig");
const set_collection = @import("../../runtime/collection/set.zig");
const big_int = @import("../../runtime/numeric/big_int.zig");
const big_decimal = @import("../../runtime/numeric/big_decimal.zig");
const ratio_mod = @import("../../runtime/numeric/ratio.zig");
const print_mod = @import("../../runtime/print.zig");
const regex_value = @import("../../runtime/regex/value.zig");
const class_name = @import("../../runtime/class_name.zig");
const host_class = @import("../../runtime/error/host_class.zig");
const type_descriptor = @import("../../runtime/type_descriptor.zig");
const dispatch = @import("../../runtime/dispatch.zig");
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const macro_dispatch = @import("../macro_dispatch.zig");
const syntax_quote = @import("syntax_quote.zig");

/// Analyser errors. Aliases the wide `error_mod.ClojureWasmError`
/// set so calls to `error_catalog.raise(.code, loc, args)`
/// type-check. The analyser emits a broad slice of that set —
/// syntax / name / arity errors plus private-access, unknown
/// namespace / catch-class, unsupported-feature, and reader-tag
/// codes. See the equivalent comment in `eval/reader.zig` for the
/// design rationale.
pub const AnalyzeError = error_mod.ClojureWasmError;

// --- Scope (local-binding chain consulted during analysis) ---

/// Recur target metadata. Stamped on each Scope created by `fn*` /
/// `loop*`. `arity` is the number of bindings / parameters that a
/// matching `recur` must supply. `slot_base` is the first local-slot
/// index of the binding/parameter group — `evalRecur` (TreeWalk) and
/// the VM `op_recur` rebind `[slot_base, slot_base + arity)` and
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
/// `recur_target` holds the nearest enclosing `loop*` / `fn*` target
/// and `recur_target_depth` the distance in scope links. Resolution
/// only inspects "depth != 0" / "target present", but the depth is
/// preserved so future named-loop / labelled-break work can reach
/// across multiple levels without re-engineering the contract
/// (ROADMAP A2).
/// Deftype-method mutable-field context (ADR-0104 / D-288). Carried on the
/// analyzer `Scope` chain (parallel to `recur_target`): inside a deftype
/// method body that declares ≥1 mutable field, a bare field symbol resolves to
/// a live `(.field this)` read and `(set! field v)` to a `set_field_node` over
/// `this`. The `__mut-fields*` transport form (emitted by the deftype macro)
/// establishes it; `this_slot` is the method's instance-param local slot.
pub const MutFieldCtx = struct {
    this_slot: u16,
    names: []const []const u8,

    pub fn contains(self: *const MutFieldCtx, name: []const u8) bool {
        for (self.names) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }
};

pub const Scope = struct {
    parent: ?*const Scope = null,
    bindings: std.StringHashMapUnmanaged(u16) = .empty,
    next_slot: u16 = 0,
    /// Innermost deftype-method mutable-field context, or null. Chain-inherited
    /// (copied in `child`/`childWithRecur`) like `recur_target`.
    mutable_fields: ?*const MutFieldCtx = null,
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
            .mutable_fields = parent.mutable_fields,
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
            .mutable_fields = parent.mutable_fields,
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
    defmacro_form,
    if_form,
    do_form,
    quote_form,
    var_form,
    fn_star,
    let_star,
    letfn_star,
    loop_star,
    recur_form,
    binding_form,
    try_form,
    throw_form,
    in_ns_form,
    require_form,
    ns_form,
    set_bang,
    dot_form,
    new_form,
    mut_fields,
};

const SPECIAL_FORMS = std.StaticStringMap(SpecialFormKind).initComptime(.{
    .{ "def", .def },
    // Row 14.6 (D-099): `(defmacro NAME [args...] body...)` lands as
    // a special form rather than a `.clj` lowering. Shape (a) of the
    // survey: analyzeDefmacro mirrors analyzeDef but wraps body in
    // `(fn* [args] body)` and emits DefNode.is_macro = true. Shape
    // (b) — lower via reader-recognised `^:macro` metadata — waits
    // on D-075 reader metadata path; arm stays after D-075 lands as
    // the canonical bootstrap entry per cw v0 precedent.
    .{ "defmacro", .defmacro_form },
    .{ "if", .if_form },
    .{ "do", .do_form },
    .{ "quote", .quote_form },
    .{ "var", .var_form },
    .{ "fn*", .fn_star },
    .{ "let*", .let_star },
    .{ "letfn*", .letfn_star },
    .{ "loop*", .loop_star },
    .{ "recur", .recur_form },
    .{ "binding", .binding_form },
    .{ "try", .try_form },
    .{ "throw", .throw_form },
    .{ "in-ns", .in_ns_form },
    .{ "require", .require_form },
    .{ "ns", .ns_form },
    .{ "set!", .set_bang },
    .{ ".", .dot_form },
    .{ "new", .new_form },
    // ADR-0104 internal transport: the deftype macro wraps a method body with
    // mutable fields in `(__mut-fields* this [mfield…] body)`; this form's
    // analyzer handler pushes the Scope mutable-field context.
    .{ "__mut-fields*", .mut_fields },
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

/// Resolve a `::name` / `::alias/name` auto-resolved keyword (D-195). `::name`
/// (sym.ns == null) takes the current namespace; `::alias/name` resolves the
/// require-alias to its target ns. The current ns is present during analysis;
/// an unknown alias raises (matches clj's read-time rejection). The
/// `formToValue` (read-string) path also resolves when its env carries a
/// current ns (D-221); a ns-less EDN parse falls back to unresolved intern.
fn resolveAutoKeyword(rt: *Runtime, env: *Env, sym: SymbolRef, loc: SourceLocation) AnalyzeError!Value {
    const cur = env.current_ns orelse
        return error_catalog.raise(.current_namespace_missing, loc, .{ .sym = sym.name });
    if (sym.ns) |alias| {
        const target = cur.aliases.get(alias) orelse
            return error_catalog.raise(.namespace_unknown, loc, .{ .ns = alias });
        return keyword.intern(rt, target.name, sym.name);
    }
    return keyword.intern(rt, cur.name, sym.name);
}

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
        .integer => |i| try makeConstant(arena, try integerLiteralToValue(rt, i), form),
        .float => |f| try makeConstant(arena, Value.initFloat(f), form),
        .char => |cp| try makeConstant(arena, Value.initChar(cp), form),
        .big_int_literal => |s| try makeConstant(arena, try parseBigIntLiteral(rt, s, form.location), form),
        .big_decimal_literal => |s| try makeConstant(arena, try parseBigDecimalLiteral(rt, s, form.location), form),
        .ratio_literal => |s| try makeConstant(arena, try parseRatioLiteral(rt, s, form.location), form),
        .regex_literal => |s| try makeConstant(arena, try parseRegexLiteral(rt, s, form.location), form),
        .keyword => |sym| {
            const v = if (sym.auto_resolve)
                try resolveAutoKeyword(rt, env, sym, form.location)
            else
                try keyword.intern(rt, sym.ns, sym.name);
            return try makeConstant(arena, v, form);
        },
        .symbol => |sym| try analyzeSymbol(arena, env, scope, sym, form),
        .list => |items| try analyzeList(arena, rt, env, scope, items, form, macro_table),
        .string => |s| {
            const v = try string_collection.alloc(rt, s);
            return try makeConstant(arena, v, form);
        },
        // Vector literal in expression position — analyze each child
        // form, emit VectorLiteralNode (Phase 6.9 cycle 4). A reader
        // `^meta` (D-186) lowers to `(with-meta <literal> <meta>)`.
        .vector => |items| if (form.meta) |mf|
            try analyzeMetaColl(arena, rt, env, scope, form, mf, macro_table)
        else
            try analyzeVectorLiteral(arena, rt, env, scope, items, form, macro_table),
        // `{...}` and `#{...}` literals (Phase 6.16.b-2 closes D-059
        // + D-061). Each emits its own LiteralNode shape; eval walks
        // the children and folds into an empty ArrayMap / HashSet.
        .map => |items| if (form.meta) |mf|
            try analyzeMetaColl(arena, rt, env, scope, form, mf, macro_table)
        else
            try analyzeMapLiteral(arena, rt, env, scope, items, form, macro_table),
        .set => |items| if (form.meta) |mf|
            try analyzeMetaColl(arena, rt, env, scope, form, mf, macro_table)
        else
            try analyzeSetLiteral(arena, rt, env, scope, items, form, macro_table),
        // `#tag form` in expression position (ADR-0073): apply the data
        // reader at analyze time (data is data) and emit the result as a
        // constant. Reuses the `formToValue` lift path.
        .tagged => |t| try makeConstant(arena, try liftTagged(rt, env, t, form.location), form),
        // `` `form `` (ADR-0082): expand the syntax-quote tree to its template
        // form, then analyze that (the analyzer has env.current_ns for the
        // future qualification pass; stage 1 is non-qualifying).
        .syntax_quote => |inner| try analyze(arena, rt, env, scope, try syntax_quote.expand(arena, rt, env, inner.*, form.location), macro_table),
        // `~`/`~@` are only meaningful inside a syntax-quote (handled by the
        // expander); reaching them here means they were used standalone.
        .unquote => error_catalog.raise(.token_invalid, form.location, .{ .token = "~ (unquote outside a syntax-quote)" }),
        .unquote_splicing => error_catalog.raise(.token_invalid, form.location, .{ .token = "~@ (unquote-splicing outside a syntax-quote)" }),
    };
}

// --- Helpers ---

/// Parse `42N`-style digits into a BigInt Value via Managed.setString.
/// Promote an i64 literal to a heap BigInt when it would otherwise
/// overflow the NaN-box int_48 inline range (Phase 14 row 14.4 gap (a)
/// — F-005 numeric-tower JVM-shape auto-promotion). `Value.initInteger`
/// silently promotes out-of-range values to Float, which loses
/// precision and routes `(* Long/MAX_VALUE 2)` through mulPromoting's
/// Float arm instead of the BigInt arm. Used at literal lift sites in
/// this file (analyze + quoteFormToValue) so source-typed integers
/// keep their precision through to arithmetic.
pub fn integerLiteralToValue(rt: *Runtime, i: i64) !Value {
    const nb = @import("../../runtime/value/nan_box.zig");
    if (i < nb.NB_I48_MIN or i > nb.NB_I48_MAX) {
        // A no-`N` integer literal past i48 (but ≤ i64, since the param is
        // i64) is a primitive Long (D-165): heap-boxed but `.long` origin →
        // prints without `N`, class Long. (Past-i64 literals route through
        // `parseBigIntLiteral` → `.bigint`.)
        return try big_int.allocFromI64(rt, i, .long);
    }
    return Value.initInteger(i);
}

/// Used by both the atom-analyzer path and the quote-lift path.
pub fn parseBigIntLiteral(rt: *Runtime, digits: []const u8, loc: error_mod.SourceLocation) !Value {
    var m = big_int.parseBase10(rt, digits) catch
        return error_catalog.raise(.integer_literal_invalid, loc, .{ .text = digits });
    defer m.deinit();
    // `5N` and a past-i64 no-`N` literal both reach here — both are genuine
    // BigInts (clj: `5N`→BigInt, `99999999999999999999`→BigInt `…N`). D-165.
    return try big_int.allocFromManaged(rt, &m, .bigint);
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

    var unscaled = big_int.parseBase10(rt, buf[0..buf_len]) catch
        return error_catalog.raise(.float_literal_invalid, loc, .{ .text = digits });
    defer unscaled.deinit();

    return try big_decimal.allocFromManagedScale(rt, &unscaled, scale);
}

/// Parse `1/3`-shape Ratio literal into a Value. Reads numerator and
/// denominator as i64 (Phase 14 row 14.4 gap (b) — wider numerators
/// fall to the same overflow path as gap (a) D-014a tracks). Collapse
/// to integer when the reduced denominator is 1 (the orelse branch
/// covers e.g. `6/2` → 3).
pub fn parseRatioLiteral(rt: *Runtime, digits: []const u8, loc: error_mod.SourceLocation) !Value {
    const slash = std.mem.findScalar(u8, digits, '/') orelse
        return error_catalog.raise(.float_literal_invalid, loc, .{ .text = digits });
    const num = std.fmt.parseInt(i64, digits[0..slash], 10) catch
        return error_catalog.raise(.float_literal_invalid, loc, .{ .text = digits });
    const den = std.fmt.parseInt(i64, digits[slash + 1 ..], 10) catch
        return error_catalog.raise(.float_literal_invalid, loc, .{ .text = digits });
    const r = ratio_mod.allocFromI64Pair(rt, num, den) catch |err| switch (err) {
        error.DivideByZero => return error_catalog.raise(.divide_by_zero, loc, .{}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    // Reduced denom == 1: the ratio collapses to a plain integer.
    return r orelse Value.initInteger(@divTrunc(num, den));
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
        // ADR-0104: a bare deftype mutable field (not shadowed by a local above)
        // reads live via `(.field this)` — reuse the instance_member dot-read so
        // a read-after-write in the same method body sees the new slot value.
        if (scope.?.mutable_fields) |ctx| {
            if (ctx.contains(sym.name)) {
                const target = try arena.create(Node);
                target.* = .{ .local_ref = .{ .name = "this", .index = ctx.this_slot, .loc = form.location } };
                const n = try arena.create(Node);
                n.* = .{ .interop_call_node = .{
                    .kind = .instance_member,
                    .target = target,
                    .name = sym.name,
                    .field_only = true,
                    .loc = form.location,
                } };
                return n;
            }
        }
    }
    // Global Var resolution. Qualified symbols `s/name` first
    // consult the current ns's alias table (ADR-0035 D3) — alias
    // names take precedence over real ns names (= JVM semantics:
    // `(alias 'str 'clojure.string)` shadows any literal `str` ns).
    const ns = if (sym.ns) |ns_name| ns_blk: {
        if (env.current_ns) |here| {
            if (here.aliases.get(ns_name)) |aliased| break :ns_blk aliased;
        }
        if (env.findNs(ns_name)) |found| break :ns_blk found;
        // ADR-0061: bare `Class/FIELD` static field read (no parens). The
        // ns head is not a Clojure ns/alias; resolve it as a Java surface
        // (same `resolveJavaSurface` the static-METHOD path uses) and, if
        // the descriptor carries a static field of this name, the symbol
        // IS that constant — emit it directly (no Var resolution follows).
        if (special_forms.resolveJavaSurface(env.rt, env, ns_name)) |td| {
            if (td.lookupStaticField(sym.name)) |sf| {
                const fv: Value = switch (sf.value) {
                    .int => |i| try integerLiteralToValue(env.rt, i),
                    .float => |f| Value.initFloat(f),
                    .bool => |b| Value.initBoolean(b),
                    // ADR-0087: a heap-singleton static field (e.g.
                    // PersistentQueue/EMPTY) resolves to the live per-Runtime
                    // value at analyze time.
                    .singleton => |s| switch (s) {
                        .empty_queue => try @import("../../runtime/collection/persistent_queue.zig").emptyQueue(env.rt),
                    },
                };
                return try makeConstant(arena, fv, form);
            }
        }
        return error_catalog.raise(.namespace_unknown, form.location, .{ .ns = ns_name });
    } else env.current_ns orelse return error_catalog.raise(.current_namespace_missing, form.location, .{ .sym = sym.name });
    // A qualified symbol `ns/name` is a direct ns-var lookup that bypasses
    // refers/aliases (JVM parity, D-261): only `ns`'s own interns count, so a
    // referred/core var visible in `ns` does NOT satisfy `ns/name`.
    const v_ptr = (if (sym.ns != null) ns.resolveQualified(sym.name) else ns.resolve(sym.name)) orelse {
        // A qualified miss (the ns exists but interns no `name`) is clj's
        // "No such var: ns/name" — a name_error on a var, not a bare symbol.
        // The native-class / exception fall-throughs below are unqualified-only.
        if (sym.ns != null)
            return error_catalog.raise(.var_unresolved, form.location, .{ .sym = symFullName(sym) });
        // ADR-0072: a bare native-class symbol (`Long`, `String`,
        // `java.lang.Long`) resolves to its native TypeDescriptor —
        // AFTER Var resolution so a user `(def String …)` /
        // `(deftype String …)` shadows. Registers on the same
        // `rt.nativeDescriptor(tag)` that a primitive receiver
        // dispatches through (so `extend-type` over a native class
        // lands where dispatch finds it), and makes a class symbol a
        // value (= `(class x)`). Interface-shaped names (Number/IFn)
        // span multiple tags → `nativeTagFor` returns null → they stay
        // unresolved-symbol errors (documented divergence).
        if (sym.ns == null) {
            if (class_name.nativeTagFor(sym.name)) |tag| {
                const td = try env.rt.nativeDescriptor(tag);
                const ref = try type_descriptor.makeTypeDescriptorRef(env.rt, td);
                return try makeConstant(arena, ref, form);
            }
            // A bare host/exception class symbol (`Exception`, `ExceptionInfo`,
            // `clojure.lang.ExceptionInfo`) resolves to the same TypeDescriptor
            // `(class e)` returns — so `(= (class e) ExceptionInfo)` works (clj
            // parity). After native + Var resolution so a user def shadows.
            if (host_class.isKnownException(sym.name)) {
                const td = try env.rt.exceptionDescriptor(host_class.normalizeClassName(sym.name));
                const ref = try type_descriptor.makeTypeDescriptorRef(env.rt, td);
                return try makeConstant(arena, ref, form);
            }
            // ADR-0109: a recognised OPAQUE host class (java.math.BigInteger,
            // Integer, …) — a JVM numeric class cljw collapses away (F-005) —
            // resolves to a distinct class VALUE keyed by its name (reusing the
            // named-descriptor cache). No cljw value has this type, so instance?
            // is false and extend-type is a load-only no-op (handled at those
            // consumers); the descriptor exists only so `(= (type x) Integer)`
            // and class-dispatch branches resolve clj-faithfully.
            if (host_class.isKnownOpaqueClass(sym.name)) {
                const td = try env.rt.exceptionDescriptor(sym.name);
                const ref = try type_descriptor.makeTypeDescriptorRef(env.rt, td);
                return try makeConstant(arena, ref, form);
            }
            // ADR-0109: java.lang.Object is the universal supertype, resolved as a
            // class VALUE so `(derive Object …)` works; isa?/instance? special-case
            // it (every class isa? Object; every non-nil value instance? Object).
            if (host_class.isUniversalClass(sym.name)) {
                const td = try env.rt.exceptionDescriptor("Object");
                const ref = try type_descriptor.makeTypeDescriptorRef(env.rt, td);
                return try makeConstant(arena, ref, form);
            }
            // ADR-0109: java.lang.Number — the numeric-tower supertype marker as a
            // class VALUE (defmethod dispatch in algo.generic.arithmetic). isa?/
            // instance? special-case it (every numeric class isa? Number).
            if (host_class.isNumberClass(sym.name)) {
                const td = try env.rt.exceptionDescriptor("Number");
                const ref = try type_descriptor.makeTypeDescriptorRef(env.rt, td);
                return try makeConstant(arena, ref, form);
            }
            // ADR-0109: clojure.lang.IFn — the callable marker as a class VALUE
            // (defmethod dispatch in core.contracts). instance? already works
            // (class_name.matchInterface = ifn?); isa? uses isCallableClassName.
            if (host_class.isIFnClass(sym.name)) {
                const td = try env.rt.exceptionDescriptor("IFn");
                const ref = try type_descriptor.makeTypeDescriptorRef(env.rt, td);
                return try makeConstant(arena, ref, form);
            }
        }
        return error_catalog.raise(.symbol_unresolved, form.location, .{ .sym = symFullName(sym) });
    };
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
        // `()` self-evaluates to the interned empty list `()` (JVM
        // `PersistentList.EMPTY`), distinct from nil (D-164 / clj-parity
        // C1). The constant is baked into the Node so both backends return
        // the same process-lifetime value (dual-backend parity, ADR-0036).
        return makeConstant(arena, try list_collection.emptyList(rt), form);
    }
    if (items[0].data == .symbol) {
        const head = items[0].data.symbol;
        // Special forms win first — they cannot be macros even if a
        // user `def`s a `^:macro` Var with the same name.
        if (head.ns == null) {
            if (SPECIAL_FORMS.get(head.name)) |kind| {
                return analyzeSpecial(arena, rt, env, scope, kind, items, form, macro_table);
            }
            // 5.12.a: `Name.` (trailing dot) -> constructor call. Exclude the
            // exact `..` head — it is the clojure.core threading macro, not a
            // ctor of class `.` (let it fall through to the macro path).
            if (head.name.len >= 2 and head.name[head.name.len - 1] == '.' and !std.mem.eql(u8, head.name, "..")) {
                return try special_forms.analyzeCtorCall(arena, rt, env, scope, head.name[0 .. head.name.len - 1], items[1..], form, macro_table);
            }
            // ADR-0050 am1: `(.-field recv)` -> field-only instance member
            // read. Checked before the general `.member` arm because `.-x`
            // also begins with `.`. Needs `.` + `-` + ≥1 name char.
            if (head.name.len >= 3 and head.name[0] == '.' and head.name[1] == '-' and items.len == 2) {
                return try special_forms.analyzeInstanceMember(arena, rt, env, scope, head.name[2..], items[1], items[2..], form, macro_table, true);
            }
            // ADR-0050 am1: `(.member recv args...)` -> instance member
            // access (arity ≥ 1). Member-vs-field resolves at eval from the
            // receiver's descriptor shape (field-first), collapsing the
            // former arity-1-field / arity-≥2-method split into one kind.
            if (head.name.len >= 2 and head.name[0] == '.' and items.len >= 2 and !std.mem.eql(u8, head.name, "..")) {
                return try special_forms.analyzeInstanceMember(arena, rt, env, scope, head.name[1..], items[1], items[2..], form, macro_table, false);
            }
            if (STAGED_UNSUPPORTED_FORMS.has(head.name)) {
                return error_catalog.raise(.feature_not_supported, form.location, .{ .name = head.name });
            }
        }
        // D-121 + ADR-0050: qualified head `(Class/method args...)` —
        // resolve the namespace head against `rt.types` (with cljw-prefix
        // translation per ADR-0029 D5) and, if a method of the given
        // name exists in the descriptor's method_table, build an
        // InteropCallNode { .kind = .static_method }. If the class
        // resolves but the method is absent, fall through to analyzeCall
        // which will produce a `symbol_unresolved` error citing the
        // full Class/method symbol — better than masking it with a
        // class-resolves-but-method-missing intermediate diagnostic.
        if (head.ns) |ns_head| {
            if (special_forms.resolveJavaSurface(rt, env, ns_head)) |td| {
                if (td.lookupMethod(null, head.name) != null) {
                    return try special_forms.analyzeStaticMethodCall(
                        arena,
                        rt,
                        env,
                        scope,
                        td,
                        head.name,
                        items[1..],
                        form,
                        macro_table,
                    );
                }
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
                    form,
                    scope,
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
    // Mirror `analyzeSymbol`'s ns resolution so the macro-detection path and
    // the symbol-resolution path agree on a qualified head. A qualified
    // `alias/name` first consults the current ns's alias table (ADR-0035 D3 —
    // an `:as`/`alias` shadows a literal ns name), then resolves own-interns-
    // only (D-261: a merely-referred macro does NOT satisfy `alias/name`). An
    // unqualified head keeps refer-inclusive `resolve` so a `:refer`'d macro
    // expands. (Without the alias translation, `(m/some-macro …)` fell through
    // to a plain call and its raw args were analyzed as symbols — found via
    // verified_projects/qbits.ex's `ex/try+`.)
    if (sym.ns) |ns_name| {
        const ns = ns_blk: {
            if (env.current_ns) |here| {
                if (here.aliases.get(ns_name)) |aliased| break :ns_blk aliased;
            }
            break :ns_blk env.findNs(ns_name) orelse return null;
        };
        return ns.resolveQualified(sym.name);
    }
    const ns = env.current_ns orelse return null;
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
/// D-186: a collection literal carrying reader `^meta` lowers to
/// `(with-meta <bare-literal> <meta-map>)` and re-analyzes — reusing the
/// `with-meta` primitive on the shared call path, so BOTH backends attach
/// the metadata with no per-literal-Node meta field (the dual-backend
/// parity contract stays unengaged). Quoted / data collection meta rides
/// `formToValue` instead. `bare.meta` is cleared so the re-analysis of the
/// literal does not loop.
fn analyzeMetaColl(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    form: Form,
    meta_form: *const Form,
    macro_table: *const macro_dispatch.Table,
) AnalyzeError!*const Node {
    var bare = form;
    bare.meta = null;
    const items = try arena.alloc(Form, 3);
    items[0] = macro_dispatch.makeSymbol("with-meta", form.location);
    items[1] = bare;
    items[2] = meta_form.*;
    const call_form = Form{ .data = .{ .list = items }, .location = form.location };
    return analyze(arena, rt, env, scope, call_form, macro_table);
}

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

/// True when an `in-ns` arg is a literal namespace symbol or `(quote sym)` —
/// the compile-time fast path. Anything else (a computed expr) routes to the
/// `in-ns` runtime Var instead (ADR-0085).
/// True when a `require` arg is a compile-time literal libspec — a quoted form
/// `(quote …)` or a bare vector `[ns …]`. A bare unquoted symbol or a computed
/// expr routes to the `require` runtime Var instead (ADR-0085).
fn isRequireLiteral(form: Form) bool {
    return switch (form.data) {
        .vector => true,
        .list => |inner| inner.len == 2 and inner[0].data == .symbol and
            inner[0].data.symbol.ns == null and
            std.mem.eql(u8, inner[0].data.symbol.name, "quote"),
        else => false,
    };
}

fn isInNsLiteral(form: Form) bool {
    return switch (form.data) {
        .symbol => true,
        .list => |inner| inner.len == 2 and inner[0].data == .symbol and
            inner[0].data.symbol.ns == null and
            std.mem.eql(u8, inner[0].data.symbol.name, "quote") and
            inner[1].data == .symbol,
        else => false,
    };
}

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
        .defmacro_form => special_forms.analyzeDefmacro(arena, rt, env, scope, items, form, macro_table),
        .if_form => special_forms.analyzeIf(arena, rt, env, scope, items, form, macro_table),
        .do_form => special_forms.analyzeDo(arena, rt, env, scope, items, form, macro_table),
        .quote_form => special_forms.analyzeQuote(arena, rt, env, items, form),
        .var_form => special_forms.analyzeVar(arena, rt, env, items, form),
        .fn_star => bindings.analyzeFnStar(arena, rt, env, scope, items, form, macro_table),
        .let_star => bindings.analyzeLetStar(arena, rt, env, scope, items, form, macro_table),
        .letfn_star => bindings.analyzeLetfnStar(arena, rt, env, scope, items, form, macro_table),
        .loop_star => bindings.analyzeLoopStar(arena, rt, env, scope, items, form, macro_table),
        .recur_form => recur.analyzeRecur(arena, rt, env, scope, items, form, macro_table),
        .binding_form => bindings.analyzeBinding(arena, rt, env, scope, items, form, macro_table),
        .try_form => try_form.analyzeTry(arena, rt, env, scope, items, form, macro_table),
        .throw_form => special_forms.analyzeThrow(arena, rt, env, scope, items, form, macro_table),
        .in_ns_form => blk: {
            // Literal / quoted-symbol arg → fast-path `in_ns_node` (the
            // compile-time ns switch). A computed arg (`(in-ns (gensym))`)
            // or wrong arity falls through to a normal call on the `in-ns`
            // runtime Var (ADR-0085) — clj treats in-ns as a function.
            if (items.len == 2 and isInNsLiteral(items[1]))
                break :blk special_forms.analyzeInNs(arena, items, form);
            break :blk analyzeCall(arena, rt, env, scope, items, form, macro_table);
        },
        .require_form => blk: {
            // A quoted-symbol / quoted-or-bare-vector libspec is a compile-time
            // require (the special form, so `:as` aliases resolve during the
            // next form's analysis). A bare unquoted symbol or a computed expr
            // (`(require ns)` with `ns` a local) routes to the require runtime
            // Var instead (ADR-0085) — clj treats require as a function.
            if (items.len == 2 and isRequireLiteral(items[1]))
                break :blk special_forms.analyzeRequire(arena, items, form);
            break :blk analyzeCall(arena, rt, env, scope, items, form, macro_table);
        },
        .ns_form => special_forms.analyzeNs(arena, items, form),
        .set_bang => special_forms.analyzeSetBang(arena, rt, env, scope, items, form, macro_table),
        .dot_form => special_forms.analyzeDot(arena, rt, env, scope, items, form, macro_table),
        .new_form => special_forms.analyzeNew(arena, rt, env, scope, items, form, macro_table),
        .mut_fields => special_forms.analyzeMutFields(arena, rt, env, scope, items, form, macro_table),
    };
}

const special_forms = @import("special_forms.zig");
const bindings = @import("bindings.zig");
const recur = @import("recur.zig");
const try_form = @import("try_form.zig");

/// Form atom → Value lift. Handles nil / bool / int / float / char /
/// string / keyword / symbol and the collection literals, interning
/// or heap-allocating as needed. **pub** so
/// `analyzer/special_forms.zig::analyzeQuote` can call back into it
/// (cyclic-import contract).
pub fn formToValue(rt: *Runtime, env: *Env, form: Form) AnalyzeError!Value {
    const base: Value = switch (form.data) {
        .nil => .nil_val,
        .boolean => |b| if (b) .true_val else .false_val,
        .integer => |i| try integerLiteralToValue(rt, i),
        .float => |f| Value.initFloat(f),
        .char => |cp| Value.initChar(cp),
        .big_int_literal => |s| try parseBigIntLiteral(rt, s, form.location),
        .big_decimal_literal => |s| try parseBigDecimalLiteral(rt, s, form.location),
        .ratio_literal => |s| try parseRatioLiteral(rt, s, form.location),
        .regex_literal => |s| try parseRegexLiteral(rt, s, form.location),
        // `::name` / `::alias/name` auto-keyword resolves against the current
        // ns when read-string is invoked from running code (env has a current
        // ns), matching the eval path (D-221). A ns-less formToValue context
        // (bare EDN parse) has no current ns → fall back to unresolved intern.
        .keyword => |sym| if (sym.auto_resolve and env.current_ns != null)
            try resolveAutoKeyword(rt, env, sym, form.location)
        else
            try keyword.intern(rt, sym.ns, sym.name),
        .string => |s| try string_collection.alloc(rt, s),
        .list => |items| try listFormToValue(rt, env, items),
        .symbol => |sym| try symbol_mod.intern(rt, sym.ns, sym.name),
        .vector => |items| try vectorFormToValue(rt, env, items),
        .map => |entries| try mapFormToValue(rt, env, entries, form.location),
        .set => |items| try setFormToValue(rt, env, items),
        .tagged => |t| return try liftTagged(rt, env, t, form.location),
        // `` `form `` as DATA (read-string / quoted): expand to the template,
        // then lift the template as data (clj `` '`(a ~b) `` → the
        // `(seq (concat …))` form). ADR-0082.
        .syntax_quote => |inner| blk: {
            var sq_arena = std.heap.ArenaAllocator.init(rt.gpa);
            defer sq_arena.deinit();
            const template = try syntax_quote.expand(sq_arena.allocator(), rt, env, inner.*, form.location);
            break :blk try formToValue(rt, env, template);
        },
        .unquote, .unquote_splicing => return error_catalog.raise(.token_invalid, form.location, .{ .token = "~ / ~@ outside a syntax-quote" }),
    };
    // D-186: honour a reader `^meta` map on a collection literal. The reader
    // (readMeta) parks normalised meta on `Form.meta`; lift + attach it to an
    // IObj value (vector/map/set/list). Non-IObj values (numbers, keywords,
    // strings, …) cannot carry metadata in cljw — matching JVM — so the meta
    // is dropped there rather than erroring.
    if (form.meta) |meta_form| {
        const m = try formToValue(rt, env, meta_form.*);
        return switch (base.tag()) {
            .vector => try vector_collection.withMeta(rt, base, m),
            .array_map, .hash_map => try map_collection.withMeta(rt, base, m),
            .hash_set => try set_collection.withMeta(rt, base, m),
            .list => try list_collection.withMeta(rt, base, m),
            else => base,
        };
    }
    return base;
}

/// Build a persistent vector Value by recursively lifting each form
/// element. §9.11 row 9.2: powers `clojure.edn/read-string "[1 2 3]"`
/// + JVM-parity `(quote [1 2 3])` round-trip.
fn vectorFormToValue(rt: *Runtime, env: *Env, items: []const Form) AnalyzeError!Value {
    var out = vector_collection.empty();
    for (items) |item| {
        const v = try formToValue(rt, env, item);
        out = try vector_collection.conj(rt, out, v);
    }
    return out;
}

/// Apply the data-reader for a `#tag form` literal (ADR-0073). The tag is
/// looked up in `*data-readers*` (live dynamic binding, else the Var root);
/// a hit lifts the inner form to a Value and invokes the reader fn with it.
/// A miss consults `*default-data-reader-fn*` (invoked with the tag symbol +
/// lifted value); still nothing → raise `reader_tag_unknown` (clj parity —
/// `read-string` with no reader for a tag throws, NOT a placeholder value).
fn liftTagged(rt: *Runtime, env: *Env, t: TaggedForm, loc: SourceLocation) AnalyzeError!Value {
    const inner = try formToValue(rt, env, t.form.*);

    if (rt.data_readers_var) |dr_opaque| {
        const dr_var: *const env_mod.Var = @ptrCast(@alignCast(dr_opaque));
        const table = dr_var.deref();
        const tag_sym = try symbol_mod.intern(rt, t.tag.ns, t.tag.name);
        const reader_fn = try map_collection.get(table, tag_sym);
        if (reader_fn.tag() != .nil)
            return try invokeReaderFn(rt, env, reader_fn, &.{inner}, loc);
    }

    if (rt.default_data_reader_fn_var) |df_opaque| {
        const df_var: *const env_mod.Var = @ptrCast(@alignCast(df_opaque));
        const default_fn = df_var.deref();
        if (default_fn.tag() != .nil) {
            const tag_sym = try symbol_mod.intern(rt, t.tag.ns, t.tag.name);
            return try invokeReaderFn(rt, env, default_fn, &.{ tag_sym, inner }, loc);
        }
    }

    return error_catalog.raise(.reader_tag_unknown, loc, .{ .tag = symFullName(t.tag) });
}

/// Invoke a data-reader fn (builtin or backend-vtable) from analyze-time.
/// Mirrors `higher_order.invokeCallable` but stays Layer-1 (analyzer cannot
/// import Layer-2 `lang/`): builtin → call directly; else route through the
/// runtime vtable, narrowing its `anyerror` to the analyzer envelope via the
/// shared `macro_dispatch.narrowCallFnError`.
fn invokeReaderFn(rt: *Runtime, env: *Env, f: Value, args: []const Value, loc: SourceLocation) AnalyzeError!Value {
    if (f.tag() == .builtin_fn) {
        const fn_ptr = f.asBuiltinFn(dispatch.BuiltinFn);
        return fn_ptr(rt, env, args, loc) catch |e| return macro_dispatch.narrowCallFnError(e, loc);
    }
    const vt = rt.vtable orelse
        return error_catalog.raiseInternal(loc, "data-reader fn invoked before vtable install");
    return vt.callFn(rt, env, f, args, loc) catch |e| return macro_dispatch.narrowCallFnError(e, loc);
}

/// Build a persistent map Value by recursively lifting key/value pairs.
fn mapFormToValue(rt: *Runtime, env: *Env, entries: []const Form, loc: SourceLocation) AnalyzeError!Value {
    if (entries.len % 2 != 0) {
        return error_catalog.raise(.map_literal_arity_odd, loc, .{});
    }
    var out = map_collection.empty();
    var i: usize = 0;
    while (i < entries.len) : (i += 2) {
        const k = try formToValue(rt, env, entries[i]);
        const val = try formToValue(rt, env, entries[i + 1]);
        out = map_collection.assoc(rt, out, k, val) catch |err| switch (err) {
            // Astronomically rare: two literal keys share a full 32-bit
            // hash (collision-bucket handling is unimplemented). Convert
            // the internal error so the AnalyzeError envelope holds.
            error.HashCollision => return error_catalog.raise(.feature_not_supported, loc, .{
                .name = "a map with hash-colliding keys",
            }),
            error.AssocOnNonMap => unreachable, // out always starts at .array_map
            else => |e| return e,
        };
    }
    return out;
}

/// Build a persistent set Value by recursively lifting elements.
fn setFormToValue(rt: *Runtime, env: *Env, items: []const Form) AnalyzeError!Value {
    var out = set_collection.empty();
    for (items) |item| {
        const v = try formToValue(rt, env, item);
        out = set_collection.conj(rt, out, v) catch |err| switch (err) {
            error.HashCollision => return error_catalog.raise(.feature_not_supported, .{}, .{
                .name = "a set with hash-colliding elements",
            }),
            error.AssocOnNonMap => unreachable, // out always starts at .hash_set
            else => |e| return e,
        };
    }
    return out;
}

/// Build a heap List Value by recursively lifting each element to a
/// Value. Empty list → nil (matches Clojure's `(quote ())` → `()` /
/// `()` is `nil`-equivalent on `rest`/`first`). Used by `quote`.
fn listFormToValue(rt: *Runtime, env: *Env, items: []const Form) AnalyzeError!Value {
    // Quoted `'()` lifts to the interned empty list, not nil (D-164).
    if (items.len == 0) return try list_collection.emptyList(rt);
    var i = items.len;
    var acc: Value = .nil_val;
    while (i > 0) {
        i -= 1;
        const head = try formToValue(rt, env, items[i]);
        acc = try list_collection.consHeap(rt, head, acc);
    }
    return acc;
}

/// Row 14.6 (D-099): inverse of `formToValue`. Converts a runtime
/// Value back into an analyzer Form so user-fn macro return values
/// can be re-fed into the analyzer. Allocations happen in `arena`
/// (the per-analysis arena, freed in bulk). The constructed Form's
/// `location` inherits `call_loc` — the macro call site — which
/// matches JVM Clojure's "macroexpand1 returns a form whose meta
/// inherits the call site" convention.
///
/// Fn / multimethod / Var / heap-mutable Values cannot round-trip
/// (no Form encoding exists), so the conversion raises
/// `macro_return_not_data` for those tags.
pub fn valueToForm(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    v: Value,
    call_loc: SourceLocation,
) anyerror!Form {
    return switch (v.tag()) {
        .nil => .{ .data = .nil, .location = call_loc },
        .boolean => .{ .data = .{ .boolean = v == .true_val }, .location = call_loc },
        .integer => .{ .data = .{ .integer = @as(i64, v.asInteger()) }, .location = call_loc },
        .float => .{ .data = .{ .float = v.asFloat() }, .location = call_loc },
        .symbol => blk: {
            const sym = symbol_mod.asSymbol(v);
            break :blk .{ .data = .{ .symbol = .{ .ns = sym.ns, .name = sym.name } }, .location = call_loc };
        },
        .keyword => blk: {
            const kw = keyword.asKeyword(v);
            break :blk .{ .data = .{ .keyword = .{ .ns = kw.ns, .name = kw.name } }, .location = call_loc };
        },
        .string => .{ .data = .{ .string = string_collection.asString(v) }, .location = call_loc },
        .char => .{ .data = .{ .char = v.asChar() }, .location = call_loc },
        // Numeric literals in a macro expansion round-trip through their reader
        // forms (e.g. a macro returning `(/ 1 2)`'s value, or a bigint literal).
        // big_decimal is deferred (needs a print-helper export; rare in macros).
        .ratio => blk: {
            const r = v.decodePtr(*const ratio_mod.Ratio);
            break :blk .{ .data = .{ .ratio_literal = try std.fmt.allocPrint(arena, "{f}/{f}", .{ r.numer.m, r.denom.m }) }, .location = call_loc };
        },
        .big_int => .{ .data = .{ .big_int_literal = try std.fmt.allocPrint(arena, "{f}", .{big_int.asManaged(v)}) }, .location = call_loc },
        .big_decimal => blk: {
            var aw: std.Io.Writer.Allocating = .init(arena);
            print_mod.writeBigDecimalDigits(&aw.writer, v) catch return error.OutOfMemory;
            break :blk .{ .data = .{ .big_decimal_literal = try aw.toOwnedSlice() }, .location = call_loc };
        },
        // A regex in a macro expansion (e.g. `(is (thrown-with-msg? E #"…" …))`)
        // round-trips through its reader-literal source.
        .regex => .{ .data = .{ .regex_literal = regex_value.asRegex(v).source() }, .location = call_loc },
        // Any seq tag — FORCE lazy layers so a macro's `(seq (concat …))`
        // syntax-quote expansion (and its lazy tail) realizes into a concrete
        // list Form. A plain `list_collection.rest` would not force the lazy
        // tail → dropped/`nil` elements (ADR-0082).
        .list, .cons, .lazy_seq, .chunked_cons, .range => try valueSeqToForm(arena, rt, env, v, call_loc),
        .vector => try valueVectorToForm(arena, rt, env, v, call_loc),
        .array_map => try valueMapToForm(arena, rt, env, v, call_loc),
        .hash_set => try valueSetToForm(arena, rt, env, v, call_loc),
        else => error_catalog.raise(.macro_return_not_data, call_loc, .{ .tag = @tagName(v.tag()) }),
    };
}

fn valueSeqToForm(arena: std.mem.Allocator, rt: *Runtime, env: *Env, seq_val: Value, call_loc: SourceLocation) anyerror!Form {
    var items: std.ArrayList(Form) = .empty;
    defer items.deinit(arena);
    var cur = try lazy_seq_mod.seq(rt, env, seq_val);
    // GC-ROOT: D-253 — the seq cursor lives in a Zig local across seq/first/rest
    // (force lazy layers) + the recursive `valueToForm` (nested seqs re-enter),
    // all re-entering the VM. A torture collect during a macro-expansion's
    // Value->Form round-trip sweeps `cur`, so the macro's lazy `(seq (concat …))`
    // realizes garbage elements -> e.g. `(var <list>)` (with-redefs, D-253) [ref:
    // .dev/gc_rooting.md §C]. `items` is arena Forms (not GC), so only `cur`
    // (+ the source) needs rooting.
    var seq_roots: [2]Value = .{ seq_val, cur };
    var seq_sp: u16 = 2;
    var seq_frame: root_set.EvalFrame = .{ .stack = &seq_roots, .sp = &seq_sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &seq_frame;
    defer root_set.eval_frame_head = seq_frame.parent;
    while (!cur.isNil()) {
        seq_roots[1] = cur;
        const head = try lazy_seq_mod.first(rt, env, cur);
        try items.append(arena, try valueToForm(arena, rt, env, head, call_loc));
        cur = try lazy_seq_mod.seq(rt, env, try lazy_seq_mod.rest(rt, env, cur));
    }
    const owned = try arena.dupe(Form, items.items);
    return .{ .data = .{ .list = owned }, .location = call_loc };
}

fn valueVectorToForm(arena: std.mem.Allocator, rt: *Runtime, env: *Env, vec_val: Value, call_loc: SourceLocation) anyerror!Form {
    const n = vector_collection.count(vec_val);
    var items = try arena.alloc(Form, n);
    // GC-ROOT: D-253 — root the source across the recursive valueToForm (a nested
    // seq/map element re-enters the VM) [ref: .dev/gc_rooting.md §C].
    var vroots: [1]Value = .{vec_val};
    var vsp: u16 = 1;
    var vframe: root_set.EvalFrame = .{ .stack = &vroots, .sp = &vsp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &vframe;
    defer root_set.eval_frame_head = vframe.parent;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        items[i] = try valueToForm(arena, rt, env, vector_collection.nth(vec_val, i), call_loc);
    }
    return .{ .data = .{ .vector = items }, .location = call_loc };
}

fn valueMapToForm(arena: std.mem.Allocator, rt: *Runtime, env: *Env, map_val: Value, call_loc: SourceLocation) anyerror!Form {
    // ArrayMap-only iteration today (D-045 still gates HamtMap path).
    // The decode is direct because `.array_map` tag was already
    // matched in `valueToForm`.
    // GC-ROOT: D-253 — root `map_val` (the raw `am` pointer aliases it) across the
    // recursive valueToForm re-entries [ref: .dev/gc_rooting.md §C].
    var mroots: [1]Value = .{map_val};
    var msp: u16 = 1;
    var mframe: root_set.EvalFrame = .{ .stack = &mroots, .sp = &msp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &mframe;
    defer root_set.eval_frame_head = mframe.parent;
    const am = map_val.decodePtr(*const map_collection.ArrayMap);
    var entries = try arena.alloc(Form, @as(usize, am.count) * 2);
    var i: u32 = 0;
    while (i < am.count) : (i += 1) {
        entries[2 * i] = try valueToForm(arena, rt, env, am.entries[2 * i], call_loc);
        entries[2 * i + 1] = try valueToForm(arena, rt, env, am.entries[2 * i + 1], call_loc);
    }
    return .{ .data = .{ .map = entries }, .location = call_loc };
}

fn valueSetToForm(arena: std.mem.Allocator, rt: *Runtime, env: *Env, set_val: Value, call_loc: SourceLocation) anyerror!Form {
    // PersistentHashSet wraps an ArrayMap-backed Value at its `map`
    // field; iterate the map's keys, ignore the sentinel values.
    // GC-ROOT: D-253 — root `set_val` (the raw `am` aliases its backing map)
    // across the recursive valueToForm re-entries [ref: .dev/gc_rooting.md §C].
    var sroots: [1]Value = .{set_val};
    var ssp: u16 = 1;
    var sframe: root_set.EvalFrame = .{ .stack = &sroots, .sp = &ssp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &sframe;
    defer root_set.eval_frame_head = sframe.parent;
    const ps = set_val.decodePtr(*const set_collection.PersistentHashSet);
    const am = ps.map.decodePtr(*const map_collection.ArrayMap);
    var items = try arena.alloc(Form, am.count);
    var i: u32 = 0;
    while (i < am.count) : (i += 1) {
        items[i] = try valueToForm(arena, rt, env, am.entries[2 * i], call_loc);
    }
    return .{ .data = .{ .set = items }, .location = call_loc };
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
    try testing.expectEqual(@as(usize, 1), n.fn_node.methods.len);
    try testing.expect(n.fn_node.variadic == null);
    const m = n.fn_node.methods[0];
    try testing.expectEqual(@as(u16, 1), m.arity);
    try testing.expect(!m.has_rest);
    try testing.expectEqualStrings("x", m.params[0]);
    try testing.expectEqual(@as(u16, 0), m.body.local_ref.index);
}

test "(fn* [x & rest] x) — has_rest is true; params include rest" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const n = try fix.analyzeStr("(fn* [x & rest] x)");
    // Variadic single-arity lives in the `variadic` slot per ADR-0041.
    try testing.expectEqual(@as(usize, 0), n.fn_node.methods.len);
    const v = n.fn_node.variadic.?;
    try testing.expectEqual(@as(u16, 1), v.arity);
    try testing.expect(v.has_rest);
    try testing.expectEqual(@as(usize, 2), v.params.len);
    try testing.expectEqualStrings("rest", v.params[1]);
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
    const target = n.try_node.catch_clauses[0].target;
    try testing.expect(target == .class_name);
    try testing.expectEqualStrings("ExceptionInfo", target.class_name);
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

// ADR-0066 retired the deftype special form (now a macro lowering to
// rt/__deftype!), so the former analyzer-level deftype_node test is gone —
// macro-expansion behaviour is covered at the e2e + differential layers
// (phase14_deftype, diff_test.zig) where the full runtime resolves rt/.

test "ctor call (Foo. ...) analyses into interop_call_node .constructor" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const n = try fix.analyzeStr("(Foo. 1 2)");
    try testing.expect(n.* == .interop_call_node);
    try testing.expect(n.interop_call_node.kind == .constructor);
    try testing.expectEqualStrings("Foo", n.interop_call_node.type_name);
    try testing.expectEqual(@as(usize, 2), n.interop_call_node.args.len);
}

test "member access (.x inst) analyses into interop_call_node .instance_member" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    // The target needs to be analyzable. Use a constant integer here
    // because member-vs-field resolution happens at eval, not analyse.
    const n = try fix.analyzeStr("(.x 1)");
    try testing.expect(n.* == .interop_call_node);
    try testing.expect(n.interop_call_node.kind == .instance_member);
    try testing.expect(!n.interop_call_node.field_only);
    try testing.expectEqualStrings("x", n.interop_call_node.name);
}

test "field-only access (.-x inst) sets field_only" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const n = try fix.analyzeStr("(.-x 1)");
    try testing.expect(n.* == .interop_call_node);
    try testing.expect(n.interop_call_node.kind == .instance_member);
    try testing.expect(n.interop_call_node.field_only);
    try testing.expectEqualStrings("x", n.interop_call_node.name);
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
