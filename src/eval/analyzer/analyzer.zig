// SPDX-License-Identifier: EPL-2.0
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
const meta_mod = @import("../../runtime/meta.zig");
const string_collection = @import("../../runtime/collection/string.zig");
const list_collection = @import("../../runtime/collection/list.zig");
const seqable = @import("../../runtime/seqable.zig");
const root_set = @import("../../runtime/gc/root_set.zig");
const vector_collection = @import("../../runtime/collection/vector.zig");
const sub_vector_collection = @import("../../runtime/collection/sub_vector.zig");
const map_collection = @import("../../runtime/collection/map.zig");
const set_collection = @import("../../runtime/collection/set.zig");
const literal = @import("../../runtime/collection/literal.zig");
const big_int = @import("../../runtime/numeric/big_int.zig");
const decimal_text = @import("../../runtime/numeric/decimal_text.zig");
const promote = @import("../../runtime/numeric/promote.zig");
const big_decimal = @import("../../runtime/numeric/big_decimal.zig");
const ratio_mod = @import("../../runtime/numeric/ratio.zig");
const print_mod = @import("../../runtime/print.zig");
const regex_value = @import("../../runtime/regex/value.zig");
const uuid_mod = @import("../../runtime/uuid.zig");
const class_name = @import("../../runtime/class_name.zig");
const host_class = @import("../../runtime/error/host_class.zig");
const host_interface = @import("../../runtime/host_interface.zig");
const host_class_resolve = @import("../../runtime/host_class_resolve.zig");
const type_descriptor = @import("../../runtime/type_descriptor.zig");
const class_form = @import("class_form.zig");
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
pub const AnalyzeError = error_mod.ClojureWasmError || error{ThrownValue};

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
    /// ADR-0130 frame-rooting (O-014 follow-up): the enclosing fn-method's
    /// running max slot high-water. Chain-inherited (let*/loop share it); a
    /// nested `fn*` gets a FRESH one (its slots live in its own frame). Every
    /// `declare` bumps `*frame_max` to the post-increment `next_slot`, so it
    /// captures the peak across sibling `let*`s (which reuse slots). The
    /// fn-method root sets it; `analyzeFnMethod` reads it back as the exact
    /// frame size so `callMethodImpl` inits + GC-roots only the used slots.
    frame_max: ?*u16 = null,
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
            .frame_max = parent.frame_max,
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
            // Inherited by default (loop* shares the enclosing fn-method's frame);
            // `analyzeFnMethod` OVERRIDES this with a fresh counter for an fn body
            // (a nested fn*'s slots live in its own frame, not the outer's).
            .frame_max = parent.frame_max,
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
        // ADR-0130 frame-rooting: track the fn-method's peak slot use (used by
        // sibling let*s reuse slots, so the max — not the final next_slot — is
        // the frame size). Bump the shared counter to the post-increment value.
        if (self.frame_max) |fm| {
            if (self.next_slot > fm.*) fm.* = self.next_slot;
        }
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

/// The SPECIAL_FORMS entries that are clojure.core macros on the JVM, so a
/// `clojure.core/`-qualified head (common in macro output and in code that
/// guards against a local `defmacro`) must reach the same analyzer arm.
const QUALIFIABLE_CORE_SPECIALS = std.StaticStringMap(SpecialFormKind).initComptime(.{
    .{ "defmacro", .defmacro_form },
    .{ "binding", .binding_form },
    .{ "ns", .ns_form },
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
        .symbol => |sym| try analyzeSymbol(arena, env, scope, sym, form, macro_table),
        .list => |items| try analyzeList(arena, rt, env, scope, items, form, macro_table),
        .string => |s| {
            const v = try string_collection.alloc(rt, s);
            return try makeConstant(arena, v, form);
        },
        // Collection literals in expression position: a constant when every
        // element is one, else a literal Node (analyzeCollLiteral). A reader
        // `^meta` (D-186) lowers to `(with-meta <literal> <meta>)`, which is
        // rebuilt per evaluation, as in clj.
        .vector => |items| if (form.meta) |mf|
            try analyzeMetaColl(arena, rt, env, scope, form, mf, macro_table)
        else
            try analyzeCollLiteral(arena, rt, env, scope, items, form, macro_table, .vector),
        .map => |items| if (form.meta) |mf|
            try analyzeMetaColl(arena, rt, env, scope, form, mf, macro_table)
        else
            try analyzeCollLiteral(arena, rt, env, scope, items, form, macro_table, .map),
        .set => |items| if (form.meta) |mf|
            try analyzeMetaColl(arena, rt, env, scope, form, mf, macro_table)
        else
            try analyzeCollLiteral(arena, rt, env, scope, items, form, macro_table, .set),
        // `#tag form` in expression position (ADR-0073): apply the data
        // reader at analyze time (data is data) and emit the result as a
        // constant. The whole literal is data, so it takes the strict lift:
        // a `^meta` on it attaches, or raises when the value cannot carry
        // meta, as clj's reader does (ADR-0200).
        .tagged => try makeConstant(arena, try lift(rt, env, form, .strict), form),
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

/// Resolve a static-field descriptor to its analyze-time Value. Shared by the
/// bare `Class/FIELD` symbol path and the parenthesized `(Class/FIELD)` call
/// path (both are field reads — ADR-0061 + clj `(Math/PI)` parity).
fn staticFieldValue(rt: *Runtime, sf: *const @import("../../runtime/type_descriptor.zig").TypeDescriptor.StaticField) !Value {
    return switch (sf.value) {
        .int => |i| try integerLiteralToValue(rt, i),
        .float => |f| Value.initFloat(f),
        .bool => |b| Value.initBoolean(b),
        .char => |c| Value.initChar(c),
        .string => |s| try string_collection.alloc(rt, s),
        .singleton => |s| switch (s) {
            .empty_queue => try @import("../../runtime/collection/persistent_queue.zig").emptyQueue(rt),
            .locale_us => try @import("../../runtime/locale.zig").singleton(rt, .us),
            .locale_root => try @import("../../runtime/locale.zig").singleton(rt, .root),
            .compiler_specials => try buildCompilerSpecials(rt),
            .system_in => try @import("../../runtime/io/host_stream.zig").systemStream(rt, 0),
            .system_out => try @import("../../runtime/io/host_stream.zig").systemStream(rt, 1),
            .system_err => try @import("../../runtime/io/host_stream.zig").systemStream(rt, 2),
            // java.time constants (ADR-0174 D7b): cheap immutable `=`-by-value
            // time values — a fresh mint per read is faithful (no cache). The
            // `catch` coerces the constructors' anyerror-inferred sets (via
            // ensureRegistered's configure callback) into AnalyzeError.
            .time_instant_epoch => @import("../../runtime/time/instant_value.zig").make(rt, 0, 0) catch |e| return coerceConstErr(e),
            .time_duration_zero => @import("../../runtime/time/duration_value.zig").make(rt, 0, 0) catch |e| return coerceConstErr(e),
            .time_local_time_midnight => @import("../../runtime/time/local_time_value.zig").make(rt, 0) catch |e| return coerceConstErr(e),
            .time_local_time_noon => @import("../../runtime/time/local_time_value.zig").make(rt, 43_200_000_000_000) catch |e| return coerceConstErr(e),
            .time_local_time_max => @import("../../runtime/time/local_time_value.zig").make(rt, 86_399_999_999_999) catch |e| return coerceConstErr(e),
            .time_local_date_min => @import("../../runtime/time/local_date_value.zig").make(rt, MIN_EPOCH_DAY) catch |e| return coerceConstErr(e),
            .time_local_date_max => @import("../../runtime/time/local_date_value.zig").make(rt, MAX_EPOCH_DAY) catch |e| return coerceConstErr(e),
            .time_local_date_epoch => @import("../../runtime/time/local_date_value.zig").make(rt, 0) catch |e| return coerceConstErr(e),
            .time_local_date_time_min => @import("../../runtime/time/local_date_time_value.zig").make(rt, MIN_EPOCH_DAY, 0) catch |e| return coerceConstErr(e),
            .time_local_date_time_max => @import("../../runtime/time/local_date_time_value.zig").make(rt, MAX_EPOCH_DAY, 86_399_999_999_999) catch |e| return coerceConstErr(e),
            .time_zone_offset_utc => @import("../../runtime/time/zone_offset.zig").make(rt, .{ .seconds = 0 }) catch |e| return coerceConstErr(e),
            .time_zone_offset_min => @import("../../runtime/time/zone_offset.zig").make(rt, .{ .seconds = -18 * 3600 }) catch |e| return coerceConstErr(e),
            .time_zone_offset_max => @import("../../runtime/time/zone_offset.zig").make(rt, .{ .seconds = 18 * 3600 }) catch |e| return coerceConstErr(e),
        },
        .host_enum => |he| try @import("../../runtime/host_enum.zig").singleton(rt, @enumFromInt(he.enum_idx), he.ordinal),
        .math_context => |which| try @import("../../runtime/math_context.zig").singleton(rt, which),
        .date_time_formatter => |idx| @import("../../runtime/time/date_time_formatter_value.zig").isoConstant(rt, idx) catch |e| return coerceConstErr(e),
        // BigDecimal ZERO/ONE/TWO/TEN (ADR-0174 D7): a scale-0 BigDecimal
        // lifted via the constructor at analyze time.
        .big_decimal => |i| @import("../../runtime/numeric/big_decimal.zig").allocFromI64Scale(rt, i, 0) catch |e| return coerceConstErr(e),
    };
}

/// Coerce a constant-constructor's anyerror-inferred failure into the
/// analyzer's error set: OOM passes through; anything else is an internal
/// invariant break (the constructors only really allocate).
fn coerceConstErr(e: anyerror) AnalyzeError {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InternalError,
    };
}

/// JVM `LocalDate.MIN` (`-999999999-01-01`) / `LocalDate.MAX`
/// (`+999999999-12-31`) as epoch days (also LocalDateTime MIN/MAX's date
/// half). Comptime-folded from the shared civil↔epoch-day SSOT.
const MIN_EPOCH_DAY: i64 = @import("../../runtime/time/instant.zig").daysFromCivil(-999_999_999, 1, 1);
const MAX_EPOCH_DAY: i64 = @import("../../runtime/time/instant.zig").daysFromCivil(999_999_999, 12, 31);

/// Build (once, then cache) `clojure.lang.Compiler/specials` — a map whose keys
/// are cljw's special-form symbols (derived from `SPECIAL_FORMS`, the analyzer's
/// SSOT, so the surface can never drift from the real set) and whose values are
/// `nil`. The only known consumer (`tools.macro`) does `(keys …)` only, so `nil`
/// values are faithful. Lives in the analyzer (the eval layer) because the
/// runtime/ zone may not import eval/ — only the `.compiler_specials` Singleton
/// TAG lives in `type_descriptor.zig`.
///
/// GC: a map is a HAMT, not a leaf, so rather than hand-build one on
/// `gc.infra` (which every leaf singleton uses) it is assembled on the managed
/// `gc` heap via the normal `assoc` API and pinned with `gc.pin`. The
/// `permanent_roots` walker yields the pinned root every collect, so the map +
/// all its HAMT nodes are re-traced and survive sweep; the symbol keys are
/// owned by the never-swept symbol interner. The pin is process-lifetime (a
/// genuine singleton) and is released by `gc.deinit`.
fn buildCompilerSpecials(rt: *Runtime) AnalyzeError!Value {
    if (!rt.compiler_specials.isNil()) return rt.compiler_specials;
    var m = map_collection.empty();
    for (SPECIAL_FORMS.keys()) |name| {
        const sym = try symbol_mod.intern(rt, null, name);
        // `assoc`'s `AssocOnNonMap` cannot fire here (`m` is always a map) —
        // collapse it into the AnalyzeError set as InternalError so the
        // resolver's error set stays unchanged.
        m = map_collection.assoc(rt, m, sym, .nil_val) catch |e| switch (e) {
            error.AssocOnNonMap => return error.InternalError,
            else => |other| return other,
        };
    }
    try rt.gc.pin(m);
    rt.compiler_specials = m;
    return m;
}

/// Used by both the atom-analyzer path and the quote-lift path.
pub fn parseBigIntLiteral(rt: *Runtime, digits: []const u8, loc: error_mod.SourceLocation) !Value {
    var m = big_int.parseBase10(rt, digits) catch
        return error_catalog.raise(.number_literal_invalid, loc, .{ .text = digits });
    defer m.deinit();
    // `5N` and a past-i64 no-`N` literal both reach here — both are genuine
    // BigInts (clj: `5N`→BigInt, `99999999999999999999`→BigInt `…N`). D-165.
    return try big_int.allocFromManaged(rt, &m, .bigint);
}

/// Parse `1.5M`-style digits into a BigDecimal Value. The unscaled
/// integer is the input with the decimal point removed; the scale is
/// the number of digits after the dot.
pub fn parseBigDecimalLiteral(rt: *Runtime, digits: []const u8, loc: error_mod.SourceLocation) !Value {
    // JVM accepts `1M`, `1.5M`, and exponent `1.5e3M`. The exponent is not a
    // separate representation — a BigDecimal is (unscaled, scale), and
    // `× 10^exp` is exactly `scale -= exp`. Split it off first so the
    // mantissa below is the plain `[-]ddd[.ddd]` shape.
    var mantissa = digits;
    var exponent: i32 = 0;
    if (std.mem.findAny(u8, digits, "eE")) |e_pos| {
        mantissa = digits[0..e_pos];
        const exp_txt = digits[e_pos + 1 ..];
        if (exp_txt.len == 0) return error_catalog.raise(.number_literal_invalid, loc, .{ .text = digits });
        exponent = std.fmt.parseInt(i32, exp_txt, 10) catch
            return error_catalog.raise(.number_literal_invalid, loc, .{ .text = digits });
    }

    // Locate the decimal point if any.
    var dot_pos: ?usize = null;
    for (mantissa, 0..) |c, idx| {
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
        const pre = mantissa[0..p];
        const post = mantissa[p + 1 ..];
        if (pre.len + post.len > buf.len) {
            return error_catalog.raise(.number_literal_invalid, loc, .{ .text = digits });
        }
        std.mem.copyForwards(u8, buf[0..pre.len], pre);
        std.mem.copyForwards(u8, buf[pre.len .. pre.len + post.len], post);
        buf_len = pre.len + post.len;
        scale = @intCast(post.len);
    } else {
        if (mantissa.len > buf.len) {
            return error_catalog.raise(.number_literal_invalid, loc, .{ .text = digits });
        }
        std.mem.copyForwards(u8, buf[0..mantissa.len], mantissa);
        buf_len = mantissa.len;
    }
    // `× 10^exponent` on a (unscaled, scale) pair is a scale shift, so a
    // literal exponent never touches the digits.
    scale = std.math.sub(i32, scale, exponent) catch
        return error_catalog.raise(.number_literal_invalid, loc, .{ .text = digits });

    var unscaled = big_int.parseBase10(rt, buf[0..buf_len]) catch
        return error_catalog.raise(.number_literal_invalid, loc, .{ .text = digits });
    defer unscaled.deinit();

    return try big_decimal.allocFromManagedScale(rt, &unscaled, scale);
}

/// Parse an `n/d` Ratio literal into a Value, as clj's reader does: each side
/// is an exact integer of any width, a Long when it fits i64 and a BigInt
/// otherwise, and the value is `promote.divideIntegers` of the two, which is
/// what `/` answers on the same operands (`6/2` is 3, `24691357802469135781/2`
/// a Ratio, `123456789012345678901234567890/7` a BigInt).
pub fn parseRatioLiteral(rt: *Runtime, digits: []const u8, loc: error_mod.SourceLocation) !Value {
    const slash = std.mem.findScalar(u8, digits, '/') orelse
        return error_catalog.raise(.number_literal_invalid, loc, .{ .text = digits });
    var num = big_int.parseBase10(rt, digits[0..slash]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error_catalog.raise(.number_literal_invalid, loc, .{ .text = digits }),
    };
    defer num.deinit();
    var den = big_int.parseBase10(rt, digits[slash + 1 ..]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error_catalog.raise(.number_literal_invalid, loc, .{ .text = digits }),
    };
    defer den.deinit();
    const bigint_operand = !num.fits(i64) or !den.fits(i64);
    return promote.divideIntegers(rt, &num, &den, bigint_operand) catch |err| switch (err) {
        error.DivideByZero => return error_catalog.raise(.divide_by_zero, loc, .{}),
        else => |e| return e,
    };
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
        else => return regex_value.raiseCompileError(err, loc),
    };
}

pub fn makeConstant(arena: std.mem.Allocator, v: Value, form: Form) !*const Node {
    // D-430: the constant lives only in this arena Node until execution —
    // publish it on the analysis-roots frame so a collect during the rest
    // of analysis (macro-expansion eval reentry, D-519 alloc-boundary
    // auto-collect) cannot sweep it.
    try root_set.pushAnalysisRoot(v);
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

/// ADR-0128 (D-293 unify): the SSOT mapping a recognised NON-native class name
/// to the key its class-VALUE descriptor (`rt.classDescriptor`) is cached under.
/// Replaces the formerly-scattered analyzer arms (exception / opaque / Object /
/// Number / IFn / interface marker / host_inert / stream), so a class symbol in
/// value position resolves uniformly — which is what lets `instance?` be a
/// higher-order fn. Native exact names (String/Long/…) are NOT here: they keep
/// their tag-keyed `nativeDescriptor` (handled before this is consulted) so
/// `(class x)` identity holds. Returns null for an unrecognised name.
fn classValueKeyFor(name: []const u8) ?[]const u8 {
    if (host_class.isKnownOpaqueClass(name)) return name; // Integer / java.math.BigInteger
    if (host_class.isUniversalClass(name)) return "Object";
    // isKnown covers exception + interface markers + Number + IFn + java.io stream
    // classes; normalize to the simple key `class_name.isInstance` matches on.
    if (class_name.isKnown(name)) return class_name.normalizeClassName(name);
    if (host_interface.isHostInert(name)) return host_interface.canonicalName(name);
    return null;
}

/// Clojure 1.12 qualified method values (D-563 a2): `Class/.member` is the
/// INSTANCE method as a receiver-first fn (`(map String/.length xs)`), and
/// `Class/new` is the constructor as a fn (`(map java.util.Date/new ms)`).
/// cljw's method ABI already takes the receiver as args[0], so the entry's
/// `method_val` IS the fn value — no wrapper. For a native-backed class
/// (String/Long/… — instance methods live on the tag-keyed native
/// descriptor, not the static surface) fall back there. Returns null when
/// the name is not one of the two forms or the member is absent (the
/// caller's member-miss diagnostic then names the dotted spelling).
fn qualifiedMemberValue(rt: *Runtime, td: *const type_descriptor.TypeDescriptor, class_head: []const u8, name: []const u8) ?Value {
    if (std.mem.eql(u8, name, "new")) {
        if (td.lookupMethod(null, "<init>")) |me| return me.method_val;
        return null;
    }
    if (name.len > 1 and name[0] == '.') {
        const mname = name[1..];
        if (td.lookupMethod(null, mname)) |me| return me.method_val;
        if (class_name.nativeTagFor(class_head)) |tag| {
            const ntd = rt.nativeDescriptor(tag) catch return null;
            if (ntd.lookupMethod(null, mname)) |me| return me.method_val;
        }
    }
    return null;
}

/// Resolve a bare (dot-free) class name through the current ns's `(:import …)`
/// map to its FQCN; qualified + unimported names pass through unchanged. Reuses
/// `ns.imports` (D-235) — the same map `(Class. …)` consults — so an imported
/// class symbol resolves to a class VALUE uniformly (ADR-0128: needed since
/// `instance?` is now a fn whose class arg evaluates here, e.g. flatland.ordered's
/// `(:import (java.util Map$Entry))` then bare `Map$Entry`).
fn resolveClassImport(env: *Env, name: []const u8) []const u8 {
    if (std.mem.findScalar(u8, name, '.') != null) return name;
    const ns = env.current_ns orelse return name;
    return ns.imports.get(name) orelse name;
}

/// Resolve a class symbol to its class VALUE — the same `TypeDescriptor` ref a
/// bare class symbol resolves to in `analyzeSymbol`'s var-miss arm. Extracted
/// (D-421) so `core.resolvePrim` shares the exact same resolution: `(resolve
/// 'String)` / `(resolve 'clojure.lang.BigInt)` must return the class (clj
/// returns the Class), not nil — which is what unblocks the `(when-available
/// SomeClass …)` reflection guard numeric-tower gates an `extend-type` on.
/// A bare name resolves through the ns `(:import …)` map; a qualified `pkg.Class`
/// is rebuilt into its dotted FQCN (what `nativeTagFor` / `classValueKeyFor` /
/// `rt.types` key on). Covers native + opaque + exception + interface-marker +
/// host-surface + user-deftype classes uniformly. Returns null for an
/// unrecognised name (so the caller falls back to nil / its own error).
/// Resolve a CANONICAL class key — a native class name, a class-value key, or a
/// user-deftype `rt.types` key — directly to its descriptor. NO ns-import
/// resolution and NO simple-name fallback: the key is taken verbatim.
///
/// This is the single dispatch-order SSOT shared by `resolveClassValue` (the
/// import-aware analyze-time path) and the AOT deserializer
/// (`serialize.readValue`'s `type_descriptor` arm). The wire carries the
/// descriptor's `fqcn` — already a canonical key — so the load path MUST NOT
/// route it back through import resolution: an import shadowing the bare name
/// at deserialize time would mis-resolve a baked class-value constant
/// (ADR-0034 am5; the import-blind lookup is what makes the AOT round-trip
/// shadow-proof).
pub fn resolveDescriptorByKey(rt: *Runtime, key: []const u8) !?*const type_descriptor.TypeDescriptor {
    if (class_name.nativeTagFor(key)) |tag| return try rt.nativeDescriptor(tag);
    if (classValueKeyFor(key)) |k| return try rt.classDescriptor(k);
    return rt.types.get(key);
}

pub fn resolveClassValue(rt: *Runtime, env: *Env, sym_ns: ?[]const u8, sym_name: []const u8) !?Value {
    var buf: [256]u8 = undefined;
    const cname = if (sym_ns) |nsn|
        (std.fmt.bufPrint(&buf, "{s}.{s}", .{ nsn, sym_name }) catch return null)
    else
        resolveClassImport(env, sym_name);
    if (try resolveDescriptorByKey(rt, cname)) |td|
        return try type_descriptor.makeTypeDescriptorRef(rt, td);
    // ADR-0174 D2: a Java-surface-backed class resolves as a value through
    // the SAME host_class_resolve rules the `(Class/method)` / `(Class. …)`
    // forms use — bare `System`/`Math`/`Thread` via the java.lang
    // auto-import, `BigDecimal` via the java.math default, an `(:import …)`ed
    // simple name via the ns map. The descriptor is the ONE canonical
    // rt.types entry (statics + instance methods merged), so `=` with
    // `(class instance)` is identity and the AOT wire round-trips.
    // (`resolveClassImport` above already rewrote an imported bare name to
    // its FQCN, so the exact-key step usually hits; this adds the java.lang /
    // java.math auto-import breadth.)
    if (host_class_resolve.resolve(rt, env.current_ns, cname)) |td|
        return try type_descriptor.makeTypeDescriptorRef(rt, td);
    // rt.types keys host-surface classes by FQCN but a USER deftype/record by its
    // SIMPLE name (AD-003: cljw class names are simple, ADR-0059). So a deftype
    // `Failure` in ns `instaparse.gll` is registered as `Failure`, and a reference
    // by its qualified `instaparse.gll.Failure` form (cfg.cljc:312
    // `(instance? instaparse.gll.Failure x)`) must fall back to the simple name —
    // host classes are already resolved above, so by here a qualified miss is a
    // user-deftype reference (D-428/D-391). Consistent with cljw's simple-name
    // deftype model: `a.b.T` and bare `T` are the same type.
    // ADR-0198 inverted this fallback. User types are now keyed by
    // `<defining_ns>.<Name>`, so a QUALIFIED reference (`instaparse.gll.Failure`,
    // D-428/D-391) hits the exact-key probe above and never reaches here. What
    // still needs promoting is the opposite case: a BARE name referring to a
    // type defined in the current namespace, which used to hit the exact-key
    // probe when keys were simple and no longer does.
    if (sym_ns == null and std.mem.findScalar(u8, cname, '.') == null) {
        if (env.current_ns) |cur_ns| {
            var qbuf: [512]u8 = undefined;
            if (std.fmt.bufPrint(&qbuf, "{s}.{s}", .{ cur_ns.name, cname })) |qualified| {
                if (rt.types.get(qualified)) |td| return try type_descriptor.makeTypeDescriptorRef(rt, td);
            } else |_| {
                // Namespace + name longer than the buffer: no registered key
                // could match it either, so fall through to the steps below.
            }
        }
    }
    // A qualified spelling of a user type whose namespace is not its defining
    // one, plus the null-`defining_ns` registrations whose key IS the simple
    // name. ADR-0198 keeps this as a last resort behind both the exact key and
    // the current-ns qualification above.
    const simple = if (std.mem.findScalarLast(u8, cname, '.')) |dot| cname[dot + 1 ..] else sym_name;
    if (!std.mem.eql(u8, simple, cname)) {
        if (rt.types.get(simple)) |td| return try type_descriptor.makeTypeDescriptorRef(rt, td);
        if (rt.types_by_simple.get(simple)) |td| return try type_descriptor.makeTypeDescriptorRef(rt, td);
    }
    if (rt.types_by_simple.get(cname)) |td| return try type_descriptor.makeTypeDescriptorRef(rt, td);
    // A protocol under its clj interface name: `(defprotocol P)` in ns `a.b` is
    // referenced as `a.b.P`.
    if (std.mem.findScalarLast(u8, cname, '.')) |dot| {
        if (protocolByInterfaceName(env, cname[0..dot], cname[dot + 1 ..])) |pv| return pv;
    }
    return null;
}

/// The protocol value `pname` names in namespace `ns_name`, retried with `_`
/// read back as `-` (clj munges the package segment). Null when the namespace
/// or the Var is absent, or the Var holds a non-protocol.
fn protocolByInterfaceName(env: *Env, ns_name: []const u8, pname: []const u8) ?Value {
    if (protocolVarIn(env, ns_name, pname)) |v| return v;
    if (std.mem.findScalar(u8, ns_name, '_') == null) return null;
    var buf: [256]u8 = undefined;
    if (ns_name.len > buf.len) return null;
    @memcpy(buf[0..ns_name.len], ns_name);
    for (buf[0..ns_name.len]) |*c| {
        if (c.* == '_') c.* = '-';
    }
    return protocolVarIn(env, buf[0..ns_name.len], pname);
}

fn protocolVarIn(env: *Env, ns_name: []const u8, pname: []const u8) ?Value {
    const ns = env.findNs(ns_name) orelse return null;
    const v = ns.resolve(pname) orelse return null;
    const val = v.deref();
    return if (val.tag() == .protocol) val else null;
}

// --- Symbol resolution ---

fn analyzeSymbol(
    arena: std.mem.Allocator,
    env: *Env,
    scope: ?*const Scope,
    sym: SymbolRef,
    form: Form,
    macro_table: *const macro_dispatch.Table,
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
    // Global Var resolution. Qualified symbols `s/name` resolve via
    // alias-then-real-ns (ADR-0035 D3 — alias names take precedence over
    // real ns names, = JVM semantics: `(alias 'str 'clojure.string)`
    // shadows any literal `str` ns).
    const ns = if (sym.ns) |ns_name| ns_blk: {
        if (env.findNsOrAlias(ns_name)) |found| break :ns_blk found;
        // ADR-0061: bare `Class/FIELD` static field read (no parens). The
        // ns head is not a Clojure ns/alias; resolve it as a Java surface
        // (same `resolveJavaSurface` the static-METHOD path uses) and, if
        // the descriptor carries a static field of this name, the symbol
        // IS that constant — emit it directly (no Var resolution follows).
        if (special_forms.resolveJavaSurface(env.rt, env, ns_name)) |td| {
            // 1.12 qualified method values: `Class/.member` (instance method
            // as receiver-first fn) + `Class/new` (ctor as fn) — D-563 a2.
            if (qualifiedMemberValue(env.rt, td, ns_name, sym.name)) |mv| {
                return try makeConstant(arena, mv, form);
            }
            if (td.lookupStaticField(sym.name)) |sf| {
                // ADR-0087: a heap-singleton static field resolves to the live
                // per-Runtime value at analyze time (handled inside the helper).
                return try makeConstant(arena, try staticFieldValue(env.rt, sf), form);
            }
            // Clojure 1.12 METHOD VALUES: a bare `Class/method` in value
            // position is the static method as a first-class fn —
            // `(every? Character/isWhitespace s)`. The host surface's
            // method_val already IS a callable builtin Value, so the
            // symbol lifts to that constant directly.
            if (td.lookupMethod(null, sym.name)) |me| {
                return try makeConstant(arena, me.method_val, form);
            }
            // ADR-0174 D3: the class RESOLVED but has no such member — a
            // member-level diagnostic, not the misleading namespace miss
            // this used to fall through to. clojure.lang.* heads skip this
            // (the AD-008 deferred rewrite below must keep lib loads alive).
            if (!isDeferredHostNs(ns_name)) {
                return error_catalog.raise(.static_member_unknown, form.location, .{
                    .member = sym.name,
                    .class = td.fqcn orelse ns_name,
                });
            }
        }
        // ADR-0113: an unresolved `clojure.lang.*` / `clojure.asm.*` qualified
        // reference is a JVM-internal class cljw has no value for (ADR-0059) —
        // never a user alias typo. Rather than failing the WHOLE namespace at
        // analysis (which blocks a lib whose CORE is pure but a peripheral fn
        // touches such a class — e.g. integrant's `(clojure.lang.RT/baseLoader)`
        // in its optional hierarchy loader), rewrite it to a loud runtime
        // `(cljw.internal/__unsupported-host-ref "ns/name")`. The enclosing fn DEFINES, the
        // namespace LOADS, and the ref errors only if actually evaluated. Covers
        // both call-head and value positions (both reach analyzeSymbol). AD-008.
        if (isDeferredHostNs(ns_name)) {
            const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ ns_name, sym.name });
            const items = try arena.alloc(Form, 2);
            items[0] = .{ .data = .{ .symbol = .{ .ns = "cljw.internal", .name = "__unsupported-host-ref" } }, .location = form.location };
            items[1] = .{ .data = .{ .string = full }, .location = form.location };
            const call_form: Form = .{ .data = .{ .list = items }, .location = form.location };
            return analyze(arena, env.rt, env, scope, call_form, macro_table);
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
        // ADR-0128 / ADR-0072 (D-293 unify): a bare class symbol resolves to its
        // class VALUE — native (tag-keyed `nativeDescriptor`, so `(class x)`
        // identity holds) → recognised non-native name (one `classDescriptor`
        // call via the `classValueKeyFor` SSOT — exception / opaque / Object /
        // Number / IFn / interface-marker / host_inert) → registered Java
        // host-surface / user deftype (`rt.types`). This is what makes a class
        // symbol a value (so `instance?` is a higher-order fn). Shared with
        // `core.resolvePrim` via `resolveClassValue` (D-421). AFTER Var
        // resolution so a user `(def String …)` / `(deftype String …)` shadows.
        if (sym.ns == null) {
            if (try resolveClassValue(env.rt, env, null, sym.name)) |ref| {
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
        }
        // `(clojure.core/defmacro …)` (or via a `clojure.core` alias): the
        // names cljw implements as analyzer special forms but mainline ships
        // as clojure.core MACROS stay special when qualified. Their marker
        // Vars have a nil root, so the macro path below would fail with
        // "root binding is not callable". True JVM specials (`if`, `let*` …)
        // are not clojure.core Vars and keep failing when qualified.
        if (head.ns) |ns_head| {
            if (QUALIFIABLE_CORE_SPECIALS.get(head.name)) |kind| {
                const core = env.findNs("clojure.core");
                if (core != null and env.findNsOrAlias(ns_head) == core)
                    return analyzeSpecial(arena, rt, env, scope, kind, items, form, macro_table);
            }
        }
        // D-121 + ADR-0050: qualified head `(Class/method args...)` —
        // resolve the namespace head against `rt.types` and, if a method
        // of the given name exists in the descriptor's method_table, build
        // an InteropCallNode { .kind = .static_method }.
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
                // clj parity: `(Class/FIELD)` with NO args is a static field READ,
                // not a call — `(Math/PI)` / `(Integer/MAX_VALUE)` return the field
                // value (same as the bare `Class/FIELD` symbol path). A static
                // field called WITH args falls through to analyzeCall (the field
                // value is not callable — a genuine runtime error).
                if (td.lookupStaticField(head.name)) |sf| {
                    if (items.len == 1)
                        return try makeConstant(arena, try staticFieldValue(rt, sf), form);
                } else if (qualifiedMemberValue(rt, td, ns_head, head.name) != null) {
                    // 1.12 `(Class/.member recv …)` / `(Class/new …)` call
                    // head: resolvable as a method value — fall through to
                    // analyzeCall, whose head analysis (analyzeSymbol) lifts
                    // the fn constant and the call applies it (D-563 a2).
                } else if (!isDeferredHostNs(ns_head) and env.findNsOrAlias(ns_head) == null) {
                    // ADR-0174 D3: the class RESOLVED but has neither a method
                    // nor a static field of this name — raise the call-position
                    // member diagnostic here (clj's "No matching method" shape)
                    // instead of falling through to the misleading
                    // `No namespace:` path. Guards: clojure.lang.* keeps the
                    // AD-008 deferred rewrite (lib loads must survive an
                    // unmodeled member in dead code), and a REAL ns/alias of
                    // the same name keeps its var-call resolution.
                    return error_catalog.raise(.static_method_unknown, form.location, .{
                        .member = head.name,
                        .class = td.fqcn orelse ns_head,
                    });
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
                // *unchecked-math*: rewrite a pristine core +/-/*/inc/dec to
                // nested wrapping unchecked-* ops while the flag is truthy
                // (CLJW-UNCHECKED-MATH). Before macro dispatch (these are not
                // macros) so the wrapping form is what gets analyzed.
                if (uncheckedArithOp(rt, env, v_ptr, head)) |uop| {
                    if (try uncheckedArithRewrite(arena, uop, items[1..], form.location)) |rewritten|
                        return analyze(arena, rt, env, scope, rewritten, macro_table);
                }
                // instance?'s class name is a lexical class reference (like the
                // (Class. …) / Class/method branches above): resolve an imported
                // simple name to its FQCN here, at analyze time, so a fn closing
                // over an (:import …) resolves when called from another ns. The
                // runtime importer in __instance? still covers a class imported
                // after analysis (REPL (import …) then use).
                const macro_args = if (head.ns == null and std.mem.eql(u8, head.name, "instance?"))
                    try special_forms.resolveInstanceClassArg(arena, env, items[1..])
                else
                    items[1..];
                if (try macro_dispatch.expandIfMacro(
                    arena,
                    rt,
                    env,
                    macro_table,
                    v_ptr,
                    head.name,
                    macro_args,
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
/// ADR-0113: is `ns` an unambiguously JVM-internal class namespace whose
/// unresolved reference should defer to a runtime error rather than fail
/// analysis? Strictly `clojure.lang.*` / `clojure.asm.*` — these are JVM
/// implementation classes cljw will never represent as a value (ADR-0059), so
/// the deferral cannot mask a user alias typo (the discriminator the
/// Devil's-advocate fork required). `java.*` is intentionally EXCLUDED: those
/// may be real host surfaces cljw should implement, so they stay loud.
pub fn isDeferredHostNs(ns: []const u8) bool {
    return std.mem.startsWith(u8, ns, "clojure.lang.") or
        std.mem.startsWith(u8, ns, "clojure.asm.");
}

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
        const ns = env.findNsOrAlias(ns_name) orelse return null;
        return ns.resolveQualified(sym.name);
    }
    const ns = env.current_ns orelse return null;
    return ns.resolve(sym.name);
}

// --- *unchecked-math* honoring (CLJW-UNCHECKED-MATH) ------------------------
// cljw's checked +/-/*/inc/dec AUTO-PROMOTE i64 overflow to BigInt; JVM Clojure
// instead WRAPS when `*unchecked-math*` is truthy at COMPILE time. We reproduce
// that here at analyze time: while the flag is truthy, a call to a pristine core
// arith op is rewritten to nested wrapping unchecked-* ops (which cljw already
// has). Analyze-time only — no runtime cost when the flag is off, and the rare
// flag-on read happens once per form (compile), not per execution.

/// True iff `*unchecked-math*` is currently bound truthy (`true` or the
/// `:warn-on-boxed` keyword, both truthy). Reads the live value so a
/// `(set! *unchecked-math* …)` earlier in the same load scopes the rewrite.
fn uncheckedMathActive(rt: *Runtime) bool {
    const p = rt.unchecked_math_var orelse return false;
    const v: *const Var = @ptrCast(@alignCast(p));
    return v.deref().isTruthy();
}

/// If `*unchecked-math*` is active and `head` names the canonical `clojure.core`
/// +/-/*/inc/dec (not a user redef; for the intrinsic ops the arith cache must
/// be pristine so an `alter-var-root` deopt is honoured), return the op name;
/// else null.
fn uncheckedArithOp(rt: *Runtime, env: *Env, v_ptr: *const Var, head: SymbolRef) ?[]const u8 {
    if (!uncheckedMathActive(rt)) return null;
    const core = env.findNs("clojure.core") orelse return null;
    const names = [_][]const u8{ "+", "-", "*", "inc", "dec" };
    for (names) |nm| {
        if (!std.mem.eql(u8, head.name, nm)) continue;
        const canon = core.resolve(nm) orelse return null;
        if (canon != v_ptr) return null;
        const is_intrinsic = std.mem.eql(u8, nm, "+") or std.mem.eql(u8, nm, "-") or std.mem.eql(u8, nm, "*");
        if (is_intrinsic and !rt.core_arith_pristine) return null;
        return nm;
    }
    return null;
}

/// `(clojure.core/<name> args...)` — a hygienic qualified-head call Form.
fn coreCallForm(arena: std.mem.Allocator, name: []const u8, call_args: []const Form, loc: SourceLocation) !Form {
    const items = try arena.alloc(Form, 1 + call_args.len);
    items[0] = .{ .data = .{ .symbol = .{ .ns = "clojure.core", .name = name } }, .location = loc };
    @memcpy(items[1..], call_args);
    return .{ .data = .{ .list = items }, .location = loc };
}

/// Rewrite `(op args…)` into nested WRAPPING unchecked-* ops (JVM's unchecked
/// compile mode). Emitted heads are clojure.core-qualified and are NOT remapped,
/// so re-analysis cannot loop. Returns null for an arity the binary/unary
/// unchecked builtins cannot express (`(-)`, `(inc a b)`), leaving the checked
/// path to run and raise its own arity error.
fn uncheckedArithRewrite(arena: std.mem.Allocator, op: []const u8, args: []const Form, loc: SourceLocation) !?Form {
    const eq = std.mem.eql;
    if (eq(u8, op, "+") or eq(u8, op, "*")) {
        const bin: []const u8 = if (eq(u8, op, "+")) "unchecked-add" else "unchecked-multiply";
        if (args.len == 0) {
            const ident: i64 = if (eq(u8, op, "+")) 0 else 1;
            return Form{ .data = .{ .integer = ident }, .location = loc };
        }
        if (args.len == 1) return args[0];
        var acc = try coreCallForm(arena, bin, args[0..2], loc);
        for (args[2..]) |a| acc = try coreCallForm(arena, bin, &.{ acc, a }, loc);
        return acc;
    }
    if (eq(u8, op, "-")) {
        if (args.len == 0) return null;
        if (args.len == 1) return try coreCallForm(arena, "unchecked-negate", args[0..1], loc);
        var acc = try coreCallForm(arena, "unchecked-subtract", args[0..2], loc);
        for (args[2..]) |a| acc = try coreCallForm(arena, "unchecked-subtract", &.{ acc, a }, loc);
        return acc;
    }
    if (eq(u8, op, "inc")) return if (args.len == 1) try coreCallForm(arena, "unchecked-inc", args[0..1], loc) else null;
    if (eq(u8, op, "dec")) return if (args.len == 1) try coreCallForm(arena, "unchecked-dec", args[0..1], loc) else null;
    return null;
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

/// `[e ...]`, `{k v ...}` and `#{e ...}` in expression position: analyze each
/// element with the full special-form / call-form pipeline.
///
/// When every element analyzed to a constant, the literal IS a constant, built
/// here once (clj `ConstantExpr`, D-346): both backends yield the identical
/// collection on every evaluation, and no operand stack is involved at any
/// size. Otherwise the elements package into the literal Node (a map's flat
/// k0 v0 k1 v1 ..., even by the reader's guarantee), which each backend
/// builds per evaluation, a map keeping a repeated key's last value and a set
/// collapsing duplicates.
fn analyzeCollLiteral(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    items: []const Form,
    form: Form,
    macro_table: *const macro_dispatch.Table,
    comptime kind: literal.Kind,
) AnalyzeError!*const Node {
    const elt_nodes = try arena.alloc(Node, items.len);
    var all_constant = true;
    for (items, elt_nodes) |elt_form, *slot| {
        slot.* = (try analyze(arena, rt, env, scope, elt_form, macro_table)).*;
        if (constantValue(slot.*) == null) all_constant = false;
    }
    if (all_constant) return makeConstant(arena, try foldConstantLiteral(arena, rt, elt_nodes, kind), form);
    const n = try arena.create(Node);
    n.* = switch (kind) {
        .vector => .{ .vector_literal_node = .{ .elements = elt_nodes, .loc = form.location } },
        .map => .{ .map_literal_node = .{ .elements = elt_nodes, .loc = form.location } },
        .set => .{ .set_literal_node = .{ .elements = elt_nodes, .loc = form.location } },
    };
    return n;
}

/// The value an element contributes to a constant literal, or null when it
/// must be evaluated. A quoted form is a constant, as in clj.
fn constantValue(n: Node) ?Value {
    return switch (n) {
        .constant => |c| c.value,
        .quote_node => |q| q.quoted,
        else => null,
    };
}

/// Build an all-constant literal's collection with the construction the VM
/// uses per evaluation (`literal.build`), so the folded value equals the one a
/// backend would build. The element values stay analysis-rooted by the
/// constant Nodes that hold them.
fn foldConstantLiteral(arena: std.mem.Allocator, rt: *Runtime, elt_nodes: []const Node, comptime kind: literal.Kind) AnalyzeError!Value {
    const values = try arena.alloc(Value, elt_nodes.len);
    for (elt_nodes, values) |n, *v| v.* = constantValue(n).?;
    return literal.build(rt, kind, values);
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
        .ns_form => special_forms.analyzeNs(arena, rt, env, scope, items, form, macro_table),
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

/// Whether a Form→Value lift also checks for duplicate map keys and set
/// elements by value (ADR-0200), and in which order it lifts. A DATA read
/// (`read-string`) and a tagged literal in code are `.strict`: their values
/// skipped the reader's Form-level check, and they lift in source order so
/// the first error in the text is the one raised. Every other lift (quote,
/// macro arguments, metadata) is `.lenient`: code was already checked as it
/// was read.
/// `.edn` is `.strict` for `clojure.edn` reads (ADR-0200 Layer B): a
/// `#ns.Record{...}` tag is NOT a record constructor there, clj's EdnReader
/// resolves every tag through `:readers` / `:default` only.
const LiftChecks = enum {
    lenient,
    strict,
    edn,

    fn checksDuplicates(self: LiftChecks) bool {
        return self != .lenient;
    }
};

/// Form atom → Value lift. Handles nil / bool / int / float / char /
/// string / keyword / symbol and the collection literals, interning
/// or heap-allocating as needed. **pub** so
/// `analyzer/special_forms.zig::analyzeQuote` can call back into it
/// (cyclic-import contract).
pub fn formToValue(rt: *Runtime, env: *Env, form: Form) AnalyzeError!Value {
    return lift(rt, env, form, .lenient);
}

/// `formToValue` for a DATA read (`read-string`, `clojure.edn/read-string`):
/// it also raises on a duplicate map key or set element, in source order.
pub fn formToValueStrict(rt: *Runtime, env: *Env, form: Form) AnalyzeError!Value {
    return lift(rt, env, form, .strict);
}

/// `formToValueStrict` for a `clojure.edn` read: additionally, a
/// `#ns.Name{...}` tag is resolved only through `*data-readers*` /
/// `*default-data-reader-fn*`, never as a record literal (clj EdnReader).
pub fn formToValueEdn(rt: *Runtime, env: *Env, form: Form) AnalyzeError!Value {
    return lift(rt, env, form, .edn);
}

/// D-186: honour a reader `^meta` map on a literal. The reader (readMeta)
/// parks normalised meta on `Form.meta`; lift it and attach it as clj's
/// MetaReader does (`meta_mod.readerAttachOrNull`: reset on a reference,
/// merge onto an IObj's existing meta). A target that cannot carry metadata
/// (a tagged literal read to a number, a string or a Date) is clj's
/// IllegalArgumentException in every lift (ADR-0200); the reader already
/// rejected the syntactic cases in code. The meta is lifted BEFORE its
/// target, as clj reads it, so a strict lift raises the meta's own error
/// first.
fn lift(rt: *Runtime, env: *Env, form: Form, checks: LiftChecks) AnalyzeError!Value {
    const meta_form = form.meta orelse return liftBase(rt, env, form, checks);
    // GC-ROOT: C — the lifted meta lives in a Zig local across the target's
    // lift, and `base` across the attach (a big literal can trigger a
    // collect that would sweep either). [ref: .dev/gc_rooting.md §C]
    var roots = [_]Value{ .nil_val, .nil_val };
    var sp: u16 = 2;
    var frame: root_set.EvalFrame = .{ .stack = &roots, .sp = &sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &frame;
    defer root_set.eval_frame_head = frame.parent;
    const m = try lift(rt, env, meta_form.*, checks);
    roots[1] = m;
    const base = try liftBase(rt, env, form, checks);
    roots[0] = base;
    const attached = meta_mod.readerAttachOrNull(rt, env, base, m, form.location) catch |e|
        return macro_dispatch.narrowCallFnError(e, form.location);
    return attached orelse error_catalog.raise(.metadata_target_not_imeta, meta_form.location, .{});
}

/// The value of `form` itself, ignoring its `^meta`.
fn liftBase(rt: *Runtime, env: *Env, form: Form, checks: LiftChecks) AnalyzeError!Value {
    return switch (form.data) {
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
        .list => |items| try listFormToValue(rt, env, items, checks),
        .symbol => |sym| try symbol_mod.intern(rt, sym.ns, sym.name),
        .vector => |items| try vectorFormToValue(rt, env, items, checks),
        .map => |entries| try mapFormToValue(rt, env, entries, form.location, checks),
        .set => |items| try setFormToValue(rt, env, items, checks),
        .tagged => |t| try liftTagged(rt, env, t, form.location, checks),
        // `` `form `` as DATA (read-string / quoted): expand to the template,
        // then lift the template as data (clj `` '`(a ~b) `` → the
        // `(seq (concat …))` form). ADR-0082.
        .syntax_quote => |inner| blk: {
            var sq_arena = std.heap.ArenaAllocator.init(rt.gpa);
            defer sq_arena.deinit();
            const template = try syntax_quote.expand(sq_arena.allocator(), rt, env, inner.*, form.location);
            break :blk try lift(rt, env, template, checks);
        },
        // `~x` / `~@x` outside a syntax-quote is DATA to the reader: clj reads
        // it as `(clojure.core/unquote x)` / `(clojure.core/unquote-splicing
        // x)`, so read-string and quote lift that list rather than raising.
        .unquote => |inner| try wrappedToValue(rt, env, "unquote", inner.*, form.location, checks),
        .unquote_splicing => |inner| try wrappedToValue(rt, env, "unquote-splicing", inner.*, form.location, checks),
    };
}

/// Build a persistent vector Value by recursively lifting each form
/// element. §9.11 row 9.2: powers `clojure.edn/read-string "[1 2 3]"`
/// + JVM-parity `(quote [1 2 3])` round-trip.
fn vectorFormToValue(rt: *Runtime, env: *Env, items: []const Form, checks: LiftChecks) AnalyzeError!Value {
    var out = vector_collection.empty();
    // GC-ROOT: C — `out` + the current element live in Zig locals across the
    // per-element formToValue/conj allocs (each can auto-collect / alloc-
    // torture-collect; a swept `out` tail gets recycled → "@memcpy arguments
    // alias" panic, the ADR-0169 verification's residual finding). The
    // formToValue builders mirror valueToForm's D-253 frames — this is the
    // Form→Value direction of the same asymmetry. [ref: .dev/gc_rooting.md §C]
    var roots = [_]Value{ .nil_val, .nil_val };
    var sp: u16 = 2;
    var frame: root_set.EvalFrame = .{ .stack = &roots, .sp = &sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &frame;
    defer root_set.eval_frame_head = frame.parent;
    for (items) |item| {
        const v = try lift(rt, env, item, checks);
        roots[1] = v;
        out = try vector_collection.conj(rt, out, v);
        roots[0] = out;
    }
    return out;
}

/// Apply the data-reader for a `#tag form` literal (ADR-0073). The tag is
/// looked up in `*data-readers*` (live dynamic binding, else the Var root);
/// a hit lifts the inner form to a Value and invokes the reader fn with it.
/// A miss consults `*default-data-reader-fn*` (invoked with the tag symbol +
/// lifted value); still nothing → raise `reader_tag_unknown` (clj parity —
/// `read-string` with no reader for a tag throws, NOT a placeholder value).
fn liftTagged(rt: *Runtime, env: *Env, t: TaggedForm, loc: SourceLocation, checks: LiftChecks) AnalyzeError!Value {
    const inner = try lift(rt, env, t.form.*, checks);

    // clj reads `#ns.Name{…}` as a RECORD constructor (the qualified
    // record print form round-trips through the reader). ADR-0198: the tag
    // IS the registry key now, so this is a direct lookup. It used to probe
    // by simple name and then re-check `defining_ns`, which silently
    // rejected a legitimate `#aaa.Point{…}` as soon as some other namespace
    // defined a record also called `Point` and displaced the entry.
    if (t.tag.ns == null and checks != .edn) {
        if (std.mem.findScalar(u8, t.tag.name, '.') != null) {
            if (rt.types.get(t.tag.name)) |td| {
                const map_arg = inner.tag() == .array_map or inner.tag() == .hash_map;
                if (td.kind == .defrecord and map_arg) {
                    return type_descriptor.recordFromMap(rt, td, inner) catch |e| switch (e) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => error_catalog.raise(.reader_tag_unknown, loc, .{ .tag = symFullName(t.tag) }),
                    };
                }
            }
        }
    }

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

/// JVM ##NaN is one shared boxed reader constant: strict literal duplicate
/// detection sees its identity, although runtime key equality never matches
/// NaN. Check Forms, not lifted (unboxed) Values. `stride` is 2 for map
/// keys and 1 for set elements.
fn repeatedReaderConstantNan(prior: []const Form, candidate: Form, stride: usize) bool {
    if (candidate.data != .float or !std.math.isNan(candidate.data.float)) return false;
    var i: usize = 0;
    while (i < prior.len) : (i += stride) {
        const form = prior[i];
        if (form.data == .float and std.math.isNan(form.data.float)) return true;
    }
    return false;
}

/// Build a persistent map Value by recursively lifting key/value pairs.
/// ADR-0200: a strict lift raises "Duplicate key" on an equal key twice,
/// decided by the map's own key equality (an assoc that does not grow the
/// map). The raise waits until every entry is lifted, because clj reads the
/// whole map before building it: in `{:a 1 :a 2 :b #foo 1}` the missing tag
/// reader fails first.
fn mapFormToValue(rt: *Runtime, env: *Env, entries: []const Form, loc: SourceLocation, checks: LiftChecks) AnalyzeError!Value {
    if (entries.len % 2 != 0) {
        return error_catalog.raise(.map_literal_arity_odd, loc, .{});
    }
    var out = map_collection.empty();
    // GC-ROOT: C — `out` + the in-flight key/value across per-entry allocs
    // (see vectorFormToValue's note). [ref: .dev/gc_rooting.md §C]
    var roots = [_]Value{ .nil_val, .nil_val, .nil_val };
    var sp: u16 = 3;
    var frame: root_set.EvalFrame = .{ .stack = &roots, .sp = &sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &frame;
    defer root_set.eval_frame_head = frame.parent;
    var duplicate: ?Form = null;
    var i: usize = 0;
    while (i < entries.len) : (i += 2) {
        const k = try lift(rt, env, entries[i], checks);
        roots[1] = k;
        const val = try lift(rt, env, entries[i + 1], checks);
        roots[2] = val;
        const before = map_collection.count(out);
        out = map_collection.assoc(rt, out, k, val) catch |err| switch (err) {
            // Hash-colliding literal keys land in the D-155 collision bucket
            // inside assoc — no analyzer-level error remains.
            error.AssocOnNonMap => unreachable, // out always starts at .array_map
            else => |e| return e,
        };
        roots[0] = out;
        if (checks.checksDuplicates() and duplicate == null) {
            if (map_collection.count(out) == before) {
                duplicate = entries[i];
            } else if (repeatedReaderConstantNan(entries[0..i], entries[i], 2)) {
                duplicate = entries[i];
            }
        }
    }
    if (duplicate) |d| return raiseDuplicate(d);
    return out;
}

/// Build a persistent set Value by recursively lifting elements. A strict
/// lift raises on an equal element twice, after the whole set is lifted,
/// as in `mapFormToValue`.
fn setFormToValue(rt: *Runtime, env: *Env, items: []const Form, checks: LiftChecks) AnalyzeError!Value {
    var out = set_collection.empty();
    // GC-ROOT: C — `out` + the current element across per-element allocs
    // (see vectorFormToValue's note). [ref: .dev/gc_rooting.md §C]
    var roots = [_]Value{ .nil_val, .nil_val };
    var sp: u16 = 2;
    var frame: root_set.EvalFrame = .{ .stack = &roots, .sp = &sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &frame;
    defer root_set.eval_frame_head = frame.parent;
    var duplicate: ?Form = null;
    for (items, 0..) |item, idx| {
        const v = try lift(rt, env, item, checks);
        roots[1] = v;
        const before = set_collection.count(out);
        out = set_collection.conj(rt, out, v) catch |err| switch (err) {
            // Hash-colliding elements land in the D-155 collision bucket.
            error.AssocOnNonMap => unreachable, // out always starts at .hash_set
            else => |e| return e,
        };
        roots[0] = out;
        if (checks.checksDuplicates() and duplicate == null) {
            if (set_collection.count(out) == before) {
                duplicate = item;
            } else if (repeatedReaderConstantNan(items[0..idx], item, 1)) {
                duplicate = item;
            }
        }
    }
    if (duplicate) |d| return raiseDuplicate(d);
    return out;
}

fn raiseDuplicate(f: Form) AnalyzeError {
    var buf: [128]u8 = undefined;
    return error_catalog.raise(.literal_key_duplicate, f.location, .{ .key = f.prStrBounded(&buf) });
}

/// `(clojure.core/<name> inner)` as data: the value of a reader wrapper
/// (`~x`, `~@x`) read outside a syntax-quote.
fn wrappedToValue(rt: *Runtime, env: *Env, name: []const u8, inner: Form, loc: SourceLocation, checks: LiftChecks) AnalyzeError!Value {
    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = "clojure.core", .name = name } }, .location = loc },
        inner,
    };
    return listFormToValue(rt, env, &items, checks);
}

/// Build a heap List Value by recursively lifting each element to a
/// Value. Empty list → nil (matches Clojure's `(quote ())` → `()` /
/// `()` is `nil`-equivalent on `rest`/`first`). Used by `quote`.
fn listFormToValue(rt: *Runtime, env: *Env, items: []const Form, checks: LiftChecks) AnalyzeError!Value {
    // Quoted `'()` lifts to the interned empty list, not nil (D-164).
    if (items.len == 0) return try list_collection.emptyList(rt);
    var i = items.len;
    var acc: Value = .nil_val;
    // GC-ROOT: C — `acc` + the current head across per-element allocs, and
    // a strict lift's element vector. consHeap's own fabrication region only
    // brackets each single cell; the partial chain between iterations lives
    // in a Zig local (see vectorFormToValue's note). [ref: .dev/gc_rooting.md §C]
    var roots = [_]Value{ .nil_val, .nil_val, .nil_val };
    var sp: u16 = 3;
    var frame: root_set.EvalFrame = .{ .stack = &roots, .sp = &sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &frame;
    defer root_set.eval_frame_head = frame.parent;
    // The chain is consed from the end. A strict (data) lift must still
    // LIFT left to right, so the first error in the text is the one raised,
    // as clj reads it: it lifts into a vector first.
    const lifted: ?Value = if (checks.checksDuplicates()) try vectorFormToValue(rt, env, items, checks) else null;
    if (lifted) |v| roots[2] = v;
    while (i > 0) {
        i -= 1;
        const head = if (lifted) |v| vector_collection.nth(v, @intCast(i)) else try lift(rt, env, items[i], checks);
        roots[1] = head;
        acc = try list_collection.consHeap(rt, head, acc);
        roots[0] = acc;
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
            var form: Form = .{ .data = .{ .symbol = .{ .ns = sym.ns, .name = sym.name } }, .location = call_loc };
            // The Form→Value direction attaches a symbol's `^meta` (ADR-0110);
            // carry it back so a macro that passes a metadata-bearing symbol
            // through — a type hint, `^:private`, a deftype field's
            // `^:volatile-mutable` — does not silently shed it.
            const m = symbol_mod.metaOf(v);
            if (m != .nil_val) {
                const meta_form = try arena.create(Form);
                meta_form.* = try valueToForm(arena, rt, env, m, call_loc);
                form.meta = meta_form;
            }
            break :blk form;
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
            const lit = switch (ratio_mod.parts(v)) {
                .small => |s| try std.fmt.allocPrint(arena, "{d}/{d}", .{ s.n, s.d }),
                .big => |b| try decimal_text.fractionAlloc(arena, b.n.m, b.d.m),
            };
            break :blk .{ .data = .{ .ratio_literal = lit }, .location = call_loc };
        },
        // A heap-boxed Long (origin .long, D-165) must round-trip as a Long, not
        // a BigInt: valueToForm feeds macroexpansion, and a macro returning a
        // large-magnitude i64 (e.g. test.check's `longify`) would otherwise come
        // back as a BigInt literal and break downstream i64-only ops
        // (unsigned-bit-shift-right et al.).
        .big_int => if (big_int.originOf(v) == .long) blk: {
            const n = promote.exactI64(v) catch break :blk Form{ .data = .{ .big_int_literal = try decimal_text.decimalAlloc(arena, big_int.asManaged(v)) }, .location = call_loc };
            break :blk Form{ .data = .{ .integer = n }, .location = call_loc };
        } else .{ .data = .{ .big_int_literal = try decimal_text.decimalAlloc(arena, big_int.asManaged(v)) }, .location = call_loc },
        .big_decimal => blk: {
            var aw: std.Io.Writer.Allocating = .init(arena);
            print_mod.writeBigDecimalDigits(&aw.writer, v) catch return error.OutOfMemory;
            break :blk .{ .data = .{ .big_decimal_literal = try aw.toOwnedSlice() }, .location = call_loc };
        },
        // A regex in a macro expansion (e.g. `(is (thrown-with-msg? E #"…" …))`)
        // round-trips through its reader-literal source.
        .regex => .{ .data = .{ .regex_literal = regex_value.asRegex(v).source() }, .location = call_loc },
        // A uuid has no literal Form of its own, but it round-trips exactly
        // through the `#uuid "…"` tagged literal that produced it —
        // `formToValue` applies the `uuid` data-reader to rebuild the value.
        // A macro whose argument or expansion contains a `#uuid` literal
        // reaches here, which is any `(when-var-exists uuid? …)`-shaped body.
        .uuid => blk: {
            const canonical = uuid_mod.canonicalOf(v);
            const inner = try arena.create(Form);
            inner.* = .{ .data = .{ .string = try arena.dupe(u8, &canonical) }, .location = call_loc };
            break :blk .{
                .data = .{ .tagged = .{ .tag = .{ .name = "uuid" }, .form = inner } },
                .location = call_loc,
            };
        },
        // `#inst "…"` — same round-trip as `.uuid`, via the descriptor's
        // reader tag. `readerTagParts` is the printer's own rule, shared so a
        // value cannot print as one literal and re-analyse as another. A
        // typed_instance with no reader tag (a deftype / defrecord instance,
        // or a bare-toString time value) has no literal to return to and
        // falls through to the error below.
        .typed_instance => blk: {
            var buf: [48]u8 = undefined;
            const parts = print_mod.readerTagParts(v, &buf) orelse
                return error_catalog.raise(.macro_return_not_data, call_loc, .{ .tag = @tagName(v.tag()) });
            const inner = try arena.create(Form);
            inner.* = .{ .data = .{ .string = try arena.dupe(u8, parts.body) }, .location = call_loc };
            break :blk .{
                .data = .{ .tagged = .{ .tag = .{ .name = parts.tag }, .form = inner } },
                .location = call_loc,
            };
        },
        // Any seq tag — FORCE lazy layers so a macro's `(seq (concat …))`
        // syntax-quote expansion (and its lazy tail) realizes into a concrete
        // list Form. A plain `list_collection.rest` would not force the lazy
        // tail → dropped/`nil` elements (ADR-0082).
        .list, .cons, .lazy_seq, .chunked_cons, .range => try withValueMeta(arena, rt, env, v, try valueSeqToForm(arena, rt, env, v, call_loc), call_loc),
        .vector, .sub_vector => try withValueMeta(arena, rt, env, v, try valueVectorToForm(arena, rt, env, v, call_loc), call_loc),
        .array_map, .hash_map => try withValueMeta(arena, rt, env, v, try valueMapToForm(arena, rt, env, v, call_loc), call_loc),
        .hash_set => try withValueMeta(arena, rt, env, v, try valueSetToForm(arena, rt, env, v, call_loc), call_loc),
        // A class object (`(defmacro m [] [String])`, `` `(f ~Keyword) ``):
        // re-form it as the class-name symbol that resolves back to it.
        .type_descriptor => try class_form.classValueToForm(arena, rt, env, v, call_loc),
        else => error_catalog.raise(.macro_return_not_data, call_loc, .{ .tag = @tagName(v.tag()) }),
    };
}

/// Carry a COLLECTION Value's metadata onto the Form it converted to.
///
/// The `.symbol` arm of `valueToForm` already does this inline for ADR-0110
/// symbol meta, with the same reasoning: a macro that passes a
/// metadata-bearing value through must not silently shed it. Collections were
/// missed, so `(defmacro m [& body] `(do ~@body))` around a `^:a []` literal
/// returned it stripped, while the un-macroed form kept its meta and clj kept
/// it in both cases. Every `clojure.test` assertion lives inside a
/// `deftest`/`testing` body, so this made correct fns fail their own suite
/// (`clojure.core-test.group-by`, whose expressions all pass outside the
/// harness).
///
/// Attaching `Form.meta` is all that is needed: D-186 already lowers a
/// meta-bearing collection literal to `(with-meta <bare> <meta-map>)` and
/// re-analyzes, so both backends attach it on the shared `with-meta` path.
///
/// `meta_mod.metaOf` is the SSOT meta-read switch and answers `nil` for any
/// tag without meta, so an arm that cannot carry meta (`.chunked_cons`,
/// `.range`) costs one comparison and is left untouched.
fn withValueMeta(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    v: Value,
    form_in: Form,
    call_loc: SourceLocation,
) anyerror!Form {
    var form = form_in;
    // GC-ROOT: the recursive valueToForm below re-enters the VM to convert the
    // meta MAP, so a collect there would otherwise sweep `v` (still the only
    // reference to the source collection) and `m` [ref: .dev/gc_rooting.md §C].
    var mroots: [2]Value = .{ v, Value.nil_val };
    var msp: u16 = 2;
    var mframe: root_set.EvalFrame = .{ .stack = &mroots, .sp = &msp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &mframe;
    defer root_set.eval_frame_head = mframe.parent;
    const m = try meta_mod.metaOf(rt, env, v, call_loc);
    if (m != .nil_val) {
        mroots[1] = m;
        const meta_form = try arena.create(Form);
        meta_form.* = try valueToForm(arena, rt, env, m, call_loc);
        form.meta = meta_form;
    }
    return form;
}

fn valueSeqToForm(arena: std.mem.Allocator, rt: *Runtime, env: *Env, seq_val: Value, call_loc: SourceLocation) anyerror!Form {
    var items: std.ArrayList(Form) = .empty;
    defer items.deinit(arena);
    var cur = try seqable.seq(rt, env, seq_val, call_loc);
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
        const head = try seqable.first(rt, env, cur, call_loc);
        try items.append(arena, try valueToForm(arena, rt, env, head, call_loc));
        cur = try seqable.next(rt, env, cur, call_loc);
    }
    const owned = try arena.dupe(Form, items.items);
    return .{ .data = .{ .list = owned }, .location = call_loc };
}

fn valueVectorToForm(arena: std.mem.Allocator, rt: *Runtime, env: *Env, vec_val: Value, call_loc: SourceLocation) anyerror!Form {
    const is_sub = vec_val.tag() == .sub_vector;
    const n = if (is_sub) sub_vector_collection.count(vec_val) else vector_collection.count(vec_val);
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
        items[i] = try valueToForm(arena, rt, env, if (is_sub) sub_vector_collection.nth(vec_val, i) else vector_collection.nth(vec_val, i), call_loc);
    }
    return .{ .data = .{ .vector = items }, .location = call_loc };
}

/// `map.forEachEntry` accumulator: each entry's k/v is re-formed via valueToForm.
const MapToFormCtx = struct {
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    entries: []Form,
    i: usize,
    loc: SourceLocation,
    fn cb(ctx: *MapToFormCtx, k: Value, val: Value) anyerror!void {
        ctx.entries[2 * ctx.i] = try valueToForm(ctx.arena, ctx.rt, ctx.env, k, ctx.loc);
        ctx.entries[2 * ctx.i + 1] = try valueToForm(ctx.arena, ctx.rt, ctx.env, val, ctx.loc);
        ctx.i += 1;
    }
};

fn valueMapToForm(arena: std.mem.Allocator, rt: *Runtime, env: *Env, map_val: Value, call_loc: SourceLocation) anyerror!Form {
    // Iterate via the generic `forEachEntry` so BOTH `.array_map` and `.hash_map`
    // are handled — a macro returning a form with a >8-key map (clojure.spec.alpha's
    // s/keys builds a 12-key `(map-spec-impl {…})`) yields a `.hash_map`, which the
    // old ArrayMap-only decode rejected as "cannot be re-analysed as a form".
    // GC-ROOT: D-253 — root `map_val` across the recursive valueToForm re-entries
    // [ref: .dev/gc_rooting.md §C].
    var mroots: [1]Value = .{map_val};
    var msp: u16 = 1;
    var mframe: root_set.EvalFrame = .{ .stack = &mroots, .sp = &msp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &mframe;
    defer root_set.eval_frame_head = mframe.parent;
    const n = map_collection.count(map_val);
    const entries = try arena.alloc(Form, @as(usize, n) * 2);
    var ctx = MapToFormCtx{ .arena = arena, .rt = rt, .env = env, .entries = entries, .i = 0, .loc = call_loc };
    try map_collection.forEachEntry(map_val, &ctx, MapToFormCtx.cb);
    return .{ .data = .{ .map = entries }, .location = call_loc };
}

/// `set.forEachElem` accumulator: each element is re-formed via valueToForm.
const SetToFormCtx = struct {
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    items: []Form,
    i: usize,
    loc: SourceLocation,
    fn cb(ctx: *SetToFormCtx, e: Value) anyerror!void {
        ctx.items[ctx.i] = try valueToForm(ctx.arena, ctx.rt, ctx.env, e, ctx.loc);
        ctx.i += 1;
    }
};

fn valueSetToForm(arena: std.mem.Allocator, rt: *Runtime, env: *Env, set_val: Value, call_loc: SourceLocation) anyerror!Form {
    // Iterate via the generic `forEachElem` so a set whose backing map has
    // promoted past the ArrayMap ceiling is handled too — decoding the backing
    // map as an ArrayMap unconditionally read a HashMap's fields as `count` /
    // `entries` and indexed off the end. Same fix, and the same reason, as
    // `valueMapToForm` above.
    // GC-ROOT: D-253 — root `set_val` across the recursive valueToForm
    // re-entries [ref: .dev/gc_rooting.md §C].
    var sroots: [1]Value = .{set_val};
    var ssp: u16 = 1;
    var sframe: root_set.EvalFrame = .{ .stack = &sroots, .sp = &ssp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &sframe;
    defer root_set.eval_frame_head = sframe.parent;
    const n = set_collection.count(set_val);
    const items = try arena.alloc(Form, n);
    var ctx = SetToFormCtx{ .arena = arena, .rt = rt, .env = env, .items = items, .i = 0, .loc = call_loc };
    try set_collection.forEachElem(set_val, &ctx, SetToFormCtx.cb);
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
        // ADR-0169: tests own the analysis bracket like every seam does.
        // No collect runs here, so closing at return is safe.
        var af: root_set.AnalysisFrame = undefined;
        root_set.beginAnalysis(&af, self.rt.gc.infra);
        defer root_set.endAnalysis(&af);
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

test "vector literal with an evaluated element analyzes into VectorLiteralNode" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const n = try fix.analyzeStr("(let* [x 1] [x 2 3])");
    const body = n.let_node.body;
    try testing.expect(body.* == .vector_literal_node);
    try testing.expectEqual(@as(usize, 3), body.vector_literal_node.elements.len);
}

test "D-346: an all-constant collection literal folds into one constant" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const v = try fix.analyzeStr("[1 [2 3] (quote a)]");
    try testing.expect(v.* == .constant);
    try testing.expectEqual(@as(u32, 3), vector_collection.count(v.constant.value));
    const inner = vector_collection.nth(v.constant.value, 1);
    try testing.expectEqual(@as(u32, 2), vector_collection.count(inner));

    // Ten simple keys exceed the array-map threshold: the fold assocs into a
    // hash map, as the backends do.
    const m = try fix.analyzeStr("{0 0 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8 9 9}");
    try testing.expect(m.* == .constant);
    try testing.expect(m.constant.value.tag() == .hash_map);
    try testing.expectEqual(@as(u32, 10), map_collection.count(m.constant.value));

    const s = try fix.analyzeStr("#{:a :b}");
    try testing.expect(s.* == .constant);
    try testing.expectEqual(@as(u32, 2), set_collection.count(s.constant.value));
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

    // ADR-0037: (quote sym) interns a Symbol Value (F-004 Group A
    // slot 1). The quoted slot carries a Value with .symbol tag.
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

test "(def x 1) captures the declared Var + value expr" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const n = try fix.analyzeStr("(def x 1)");
    try testing.expectEqualStrings("x", n.def_node.var_ptr.name);
    try testing.expectEqual(fix.env.current_ns.?, n.def_node.var_ptr.ns);
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
    // [CLJW-CTOR-ANALYZE-TIME]: a bare type name carries the namespace it was
    // analyzed in, so eval-time lookup qualifies it lexically.
    try testing.expectEqualStrings(fix.env.current_ns.?.name, n.interop_call_node.definer_ns);
}

test "constructInstance resolves <definer_ns>.<Name> before the last-wins simple name" {
    const td_mod = @import("../../runtime/type_descriptor.zig");
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    // aaa.Point has two fields; bbb.Point, registered later, has one, so a
    // simple-name lookup would pick bbb's and reject two arguments.
    const aaa = try td_mod.registerType(&fix.rt, "Point", "aaa", &.{ "x", "y" }, &.{}, .defrecord);
    const bbb = try td_mod.registerType(&fix.rt, "Point", "bbb", &.{"q"}, &.{}, .defrecord);
    const two = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    const a = try special_forms.constructInstance(&fix.rt, &fix.env, "Point", "aaa", &two, .{});
    try testing.expect(a.tag() == .typed_instance);
    try testing.expect(a.decodePtr(*const td_mod.TypedInstance).descriptor == aaa);
    const one = [_]Value{Value.initInteger(9)};
    const b = try special_forms.constructInstance(&fix.rt, &fix.env, "Point", "bbb", &one, .{});
    try testing.expect(b.decodePtr(*const td_mod.TypedInstance).descriptor == bbb);
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

// `defrecord`/`reify`/`definterface` are retired from the
// staged-unsupported wedge — each lowers via a Layer-2 macro
// (expandDefrecord / expandReify / expandDefinterface→defprotocol). The wedge is
// empty and removed. definterface lowering is covered by `test/e2e/phase7_definterface.sh`
// (the analyzer TestFixture cannot register Layer-2 macros without an upward
// zone import — see `.claude/rules/zone_deps.md`).

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
