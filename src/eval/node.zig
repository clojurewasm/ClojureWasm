//! Node — the analyser's typed AST.
//!
//! `Form` (`form.zig`) is the literal surface representation a Reader
//! produces. `Node` is the post-analysis tree where every symbol has
//! been resolved to a Var or a local slot index, and every special
//! form has its own struct so the backend can dispatch on it via
//! type-safe `switch`.
//!
//! ### Scope (this file)
//!
//! - Literal: `constant` (lifted Form atom — nil / bool / int / float /
//!   string / keyword reified into a `Value` at analyse time)
//! - References: `local_ref` (let-bound; carries a slot index), `var_ref`
//!   (resolved `*const Var`)
//! - Special forms: `def`, `if`, `do`, `quote`, `fn*`, `let*`,
//!   `loop*`, `recur`, `try`, `throw` (Phase 3.9 added the last four)
//! - Expressions: `call` — generic invocation
//!
//! ### `try` / `loop*` deliberate divergences from v1 / Clojure JVM
//!
//! - **Multi-catch**: stored as a flat `[]const CatchClause` in a single
//!   `try_node`, not as nested `try_node`s the way v1 builds them. This
//!   keeps the AST shape readable and matches the way Clojure JVM stores
//!   `catchExprs` as a `PersistentVector`.
//! - **`recur_target_depth: u32` on Scope** (in `analyzer.zig`) tracks
//!   the nesting depth of the nearest `loop*` / `fn*`. Dispatch only
//!   uses "≠ 0" (target present), but the depth is preserved so future
//!   work (named loops, labelled break) can reach across multiple
//!   levels without re-engineering the Scope contract (ROADMAP A2).
//!
//! ### Known limits
//!
//! - Tail-position enforcement of `recur` is checked at eval time:
//!   `recur` outside a target is a syntax error, but `recur` in a
//!   non-tail position inside a target compiles and raises at eval time.
//! - Multi-class catch (only `ExceptionInfo` is recognised; class name
//!   is stored as a string and compared at eval time).
//!
//! ### Memory ownership
//!
//! The Node tree lives in the Analyzer's per-eval arena (`runtime
//! /gc/arena.zig`). Child pointers all point inside the same arena so
//! lifetimes align — the whole tree is freed at once when the arena
//! is released. Nodes are **not** Values, so the Phase-5 GC does not
//! trace them; this is the structural reason map / vec literals lift
//! into `constant` Values rather than into Node sub-trees.

const std = @import("std");
const Value = @import("../runtime/value/value.zig").Value;
const SourceLocation = @import("../runtime/error/info.zig").SourceLocation;
const Var = @import("../runtime/env.zig").Var;
const TypeDescriptor = @import("../runtime/type_descriptor.zig").TypeDescriptor;

/// Analysed AST. `union(enum)` lets the backend `switch` exhaustively.
pub const Node = union(enum) {
    constant: ConstantNode,
    local_ref: LocalRef,
    var_ref: VarRef,
    def_node: DefNode,
    if_node: IfNode,
    do_node: DoNode,
    quote_node: QuoteNode,
    fn_node: FnNode,
    let_node: LetNode,
    letfn_node: LetfnNode,
    call_node: CallNode,
    loop_node: LoopNode,
    binding_node: BindingNode,
    recur_node: RecurNode,
    try_node: TryNode,
    throw_node: ThrowNode,
    interop_call_node: InteropCallNode,
    in_ns_node: InNsNode,
    require_node: RequireNode,
    ns_node: NsNode,
    vector_literal_node: VectorLiteralNode,
    map_literal_node: MapLiteralNode,
    set_literal_node: SetLiteralNode,
    set_node: SetNode,
    set_field_node: SetFieldNode,

    /// Source location of this Node. Returns the inner variant's `loc`
    /// — every variant carries one because Phase-2 errors must cite a
    /// position (ROADMAP P6).
    pub fn loc(self: Node) SourceLocation {
        return switch (self) {
            inline else => |n| n.loc,
        };
    }
};

/// A literal whose value is fixed at analyse time. The Form-atom →
/// Value lift happens in `analyzer.zig`.
pub const ConstantNode = struct {
    value: Value,
    loc: SourceLocation = .{},
};

/// `let`-bound or `fn*`-parameter reference. `index` is the slot
/// number fixed during analysis — the shared key between TreeWalk and
/// the future VM, so emitter / interpreter can both index a flat
/// locals array.
pub const LocalRef = struct {
    /// Original symbol name (kept for debug + error messages).
    name: []const u8,
    /// Slot index within the enclosing local environment.
    index: u16,
    loc: SourceLocation = .{},
};

/// Global Var reference — analyser has already resolved the pointer.
/// `Var.deref` is consulted at eval time so dynamic bindings still
/// take effect.
pub const VarRef = struct {
    var_ptr: *const Var,
    loc: SourceLocation = .{},
};

/// `(set! var-symbol value)` — assign a dynamic Var's thread binding. The
/// analyser resolves the target to its `*Var` (it must already exist); it
/// does NOT check `^:dynamic` (that raced the eval-time flag — ADR-0096).
/// At eval, the innermost thread binding for the Var is updated; if the Var
/// is NOT thread-bound (dynamic-and-unbound OR non-dynamic) it RAISES (JVM
/// Var.set parity — set! never touches a root). Standard config vars
/// (`*warn-on-reflection*` …) are thread-bound by the bootstrap baseline
/// frame, so set! on them works at top level. The field-set form
/// `(set! (.f o) v)` is a separate, unsupported sub-case. Returns the value.
pub const SetNode = struct {
    var_ptr: *Var,
    value_expr: *const Node,
    loc: SourceLocation = .{},
};

/// `(set! field v)` on a deftype mutable field, inside one of the type's own
/// methods (ADR-0104 / D-288). The analyzer produces this ONLY for a bare
/// symbol that is a declared mutable field in the enclosing deftype-method
/// field context; `target` is the `this` local-ref, resolved at eval to the
/// receiver instance whose field slot (`field_name` → `field_layout` index) is
/// written in place. `set!` on a non-mutable field / external `(set! (.f o) v)`
/// is NOT this node (clj rejects both).
pub const SetFieldNode = struct {
    target: *const Node,
    field_name: []const u8,
    value_expr: *const Node,
    loc: SourceLocation = .{},
};

/// `(def name value)` (and `^:dynamic` / `^:macro` / `^:private`
/// variants once metadata reading lands).
pub const DefNode = struct {
    name: []const u8,
    value_expr: *const Node,
    /// Mirrors `env.zig`'s VarFlags — duplicated because the Node
    /// tree must not import the analyser's parsing context. The two
    /// will be unified once `^{...}` reader macros land in Phase 3+.
    is_dynamic: bool = false,
    is_macro: bool = false,
    is_private: bool = false,
    /// `(def x v)` (true) vs the no-init `(def x)` (false). A no-init def
    /// interns an UNBOUND placeholder (`internDeclare`) — it must not clobber
    /// an existing root (clj parity) and leaves `Var.bound` false for `bound?`.
    has_init: bool = true,
    /// The Var-meta map EXPRESSION (D-563b): user `^meta` + `:doc` merged
    /// under the analyzer-minted `:line`/`:column`/`:file` (compiler wins on
    /// collision, clj parity). Evaluated at def time and set as `Var.meta`
    /// by both backends (tree_walk evalDef / VM op_var_meta), so def meta
    /// survives the AOT wire. Null only for internal defs with no location.
    meta_expr: ?*const Node = null,
    loc: SourceLocation = .{},
};

/// `(if cond then else)`. The else branch is optional in Clojure.
pub const IfNode = struct {
    cond: *const Node,
    then_branch: *const Node,
    else_branch: ?*const Node = null,
    loc: SourceLocation = .{},
};

/// `(do form1 form2 ...)` — evaluate in order, return the last value.
/// An empty do returns nil.
pub const DoNode = struct {
    forms: []const Node,
    loc: SourceLocation = .{},
};

/// `(quote x)` — the analyser has already reified `x` into a Value
/// via Form-atom lifting, so the backend just returns `quoted` at
/// eval time.
pub const QuoteNode = struct {
    quoted: Value,
    loc: SourceLocation = .{},
};

/// One arity body of a `fn*` form. Row 7.8 cycle 1 (ADR-0041)
/// lifted `FnNode`'s flat single-arity fields into a slice of these,
/// so JVM `(fn* ([x] body1) ([x y] body2))` parses cleanly. Variadic
/// parameters are represented by `has_rest = true`; the rest-parameter
/// is the last entry in `params` and is **not** counted in `arity`.
/// Bytecode lives on the runtime-side `Function.methods` per-arity
/// counterpart (`tree_walk.FunctionMethod`), not here — `node.zig`
/// stays VM-agnostic.
pub const FnMethod = struct {
    arity: u16,
    has_rest: bool = false,
    /// Parameter names (debug + error frames). Length equals `arity`
    /// when `has_rest` is false, `arity + 1` otherwise.
    params: []const []const u8,
    body: *const Node,
    /// ADR-0130 frame-rooting (O-014 follow-up): the exact number of local slots
    /// this method's frame uses (captures + params + body let*/loop high-water),
    /// computed by `analyzeFnMethod`. `callMethodImpl` inits + GC-roots only
    /// `locals[0..frame_slots]` instead of the full 256, cutting the per-call
    /// ~2 KB nil-init. **Sentinel 0 = "unknown" → fall back to the full
    /// MAX_LOCALS init** (safe for any FnMethod not produced by the analyzer; the
    /// only analyzer case that yields 0 is a no-arg / no-local / no-capture body,
    /// which has nothing to init anyway). MUST be ≥ every slot accessed at
    /// runtime — a too-low value is a GC UAF / slot_out_of_range (the O-005
    /// failure modes); verified under CLJW_GC_TORTURE.
    frame_slots: u16 = 0,
};

/// `(fn* [params] body)` or `(fn* ([params] body1) ([params] body2) ...)`.
/// Single-arity ships as `methods.len == 1`, `variadic == null` per
/// ADR-0041 Option B-extracted (uniform shape; no `single`/`multi`
/// discriminant). Variadic body (cycle 2) lives in the `variadic` slot
/// — JVM allows at most one variadic per fn (rule 1).
pub const FnNode = struct {
    methods: []const FnMethod,
    variadic: ?FnMethod = null,
    /// First local-slot index this fn's parameters occupy. Inherited
    /// from the enclosing scope so a fn nested inside `let*` / `fn*`
    /// captures slots `[0, slot_base)` from the caller's frame as its
    /// closure environment, and each method's params land at
    /// `[slot_base, slot_base + method.arity)`. Top-level fns have
    /// `slot_base == 0` and no closure (Phase 3.11; ROADMAP §9.5).
    slot_base: u16 = 0,
    /// Qualified name of this fn for traces / `pr` / metadata (ADR-0119).
    /// `(defn foo ..)` → `"foo"`; anonymous → a gensym `"fn__<id>"`;
    /// `letfn*` local → the binding name. Borrows the analyzer arena (same
    /// lifetime as `FnMethod.params`). `null` only on the AOT-deserialized
    /// path (dropped like `params`, ADR-0119 §2). Carried onto the runtime
    /// `Function` (and copied through the VM closure reconstruct).
    name: ?[]const u8 = null,
    /// Namespace the fn was defined in (display/metadata only — v1 resolves
    /// vars at analyze time, so this never restores `current_ns`, ADR-0119 §4).
    defining_ns: ?[]const u8 = null,
    loc: SourceLocation = .{},
};

/// `(let* [n1 e1 n2 e2 ...] body)`. The body is a single Node — the
/// analyser lowers a multi-form let body into an enclosing `do_node`
/// so let_node stays simple.
pub const LetNode = struct {
    bindings: []const Binding,
    body: *const Node,
    loc: SourceLocation = .{},

    pub const Binding = struct {
        name: []const u8,
        /// Local slot index this binding occupies.
        index: u16,
        value_expr: *const Node,
    };
};

/// `(letfn* [n1 e1 n2 e2 ...] body)`. Same binding layout as `LetNode`,
/// but ALL names are declared into the scope BEFORE any init-expr is
/// analysed, so the bound fns (each `e_i` is a `fn*`) can reference one
/// another — mutual recursion. Because cljw closures snapshot captured
/// slots by value at allocation, the backend evaluates every init, then
/// patches each resulting closure's captured letfn-slot range with the
/// real sibling fns (`evalLetfn` / `op_letfn_patch`).
pub const LetfnNode = struct {
    bindings: []const LetNode.Binding,
    body: *const Node,
    loc: SourceLocation = .{},
};

/// `(callee args...)` — generic invocation. `callee` is itself a
/// Node so a fn-literal can be invoked directly (`((fn* [x] x) 1)`).
pub const CallNode = struct {
    callee: *const Node,
    args: []const Node,
    loc: SourceLocation = .{},
};

/// `(loop* [n1 e1 n2 e2 ...] body)`. Same binding layout as `LetNode`
/// — the structural difference is that `recur` inside `body` jumps
/// back to the binding slots instead of returning. Body is folded into
/// a single Node (a `do_node` if multi-form), mirroring `LetNode`.
pub const LoopNode = struct {
    bindings: []const LetNode.Binding,
    body: *const Node,
    loc: SourceLocation = .{},
};

/// `(binding [*v1* e1 *v2* e2 ...] body)`. Unlike `LetNode`, the bound
/// names resolve to **existing dynamic Vars** (no lexical slots), so each
/// pair carries the resolved `*const Var` directly. Each `value_expr`
/// analyses in the OUTER scope (JVM parallel-eval: inits see the
/// surrounding bindings, not each other); the backend evaluates all
/// inits, pushes one `BindingFrame` for the body's dynamic extent, then
/// pops it (Zig `defer` / VM cleanup handler = JVM `finally`). A target
/// that is not `flags.dynamic` raises `binding_target_not_dynamic` at
/// push time (JVM-faithful site — dynamic-ness is a runtime Var flag).
pub const BindingNode = struct {
    pairs: []const Pair,
    body: *const Node,
    loc: SourceLocation = .{},

    pub const Pair = struct {
        var_ptr: *const Var,
        value_expr: *const Node,
    };
};

/// `(recur args...)`. The analyser has already verified that some
/// enclosing `loop*` / `fn*` exists and that `args.len` matches its
/// binding / parameter count; the backend just rebinds the slots and
/// re-enters the body. The recur target itself is implicit — it's
/// the innermost enclosing `loop_node` / `fn_node` at runtime, looked
/// up via the threadlocal `pending_recur` signal that 3.11 will wire.
pub const RecurNode = struct {
    args: []const Node,
    loc: SourceLocation = .{},
};

/// `(try body* (catch ExceptionInfo e catch-body*) (finally finally-body*))`.
/// `body` is a single Node (the analyser folds multi-form bodies into a
/// `do_node`). Multiple `catch` clauses live in `catch_clauses` as a
/// flat array — Phase 3.9 ships a single class (`ExceptionInfo`) and the
/// runtime simply walks the array linearly. `finally_body` is optional
/// and runs unconditionally; nil if no `finally` clause was supplied.
pub const TryNode = struct {
    body: *const Node,
    catch_clauses: []const CatchClause,
    finally_body: ?*const Node = null,
    loc: SourceLocation = .{},

    pub const CatchClause = struct {
        /// Discriminates the catch head shape: either an exception class
        /// name (matched against the thrown value's host-class chain) or
        /// a keyword (matched against the thrown ex-info's `:type` value).
        /// Row 14.5 (D-014b) introduces the keyword path; the class-name
        /// path retains Phase 7's `host_class.matches` semantics.
        target: CatchTarget,
        /// Local symbol the caught exception is bound to inside `body`.
        binding_name: []const u8,
        /// Slot index within the enclosing function's locals array.
        /// Allocated by the analyser at parse time, just like `LetNode`'s
        /// bindings.
        binding_index: u16,
        /// Catch body — already folded to a single Node.
        body: *const Node,
        loc: SourceLocation = .{},
    };

    /// What the catch clause matches against. JVM Clojure only supports
    /// class names; cw v1 promotes the `ex-info` `:type` keyword pattern
    /// to a 1st-class catch head per ADR-0007 + ADR-0018 + ADR-0036.
    /// Keyword Values are interned, so the runtime can identity-compare
    /// the catch keyword against the thrown ex-info's `:type` value.
    pub const CatchTarget = union(enum) {
        /// Fully-qualified exception class name (`"ExceptionInfo"`,
        /// `"java.lang.Throwable"`, …). Resolved via `host_class.matches`.
        class_name: []const u8,
        /// Interned keyword Value. Catch matches when the thrown is an
        /// ex-info whose data map carries `:type <kw>` equal to this.
        type_keyword: Value,
    };
};

/// `(throw expr)` — evaluate `expr` and signal it as the exception.
/// Phase 3.10 ships `ex_info`; Phase 3.11's TreeWalk evaluator turns
/// `expr` into a thrown Value via `last_thrown_exception` + an
/// `error.ThrownValue` Zig error.
pub const ThrowNode = struct {
    expr: *const Node,
    loc: SourceLocation = .{},
};

/// `(Class/method args...)` / `(.member recv args...)` / `(.-field recv)` /
/// `(Name. args...)` — unified Java/host interop dispatch (ADR-0050, am1).
/// One Node carries every kind of interop call; the kind tag picks the
/// args layout at eval/compile time.
///
/// Field usage per kind:
///   - `.static_method`   : `descriptor` non-null (analyze-time resolved);
///                          `name` = method; `args` = user args (no
///                          receiver); `target` / `type_name` unused.
///   - `.instance_member` : `target` non-null (eval-time receiver);
///                          `name` = member; `args` = remaining args (empty
///                          for a bare `(.x recv)` read). Member-vs-field is
///                          resolved at eval from the receiver's descriptor
///                          shape (field-first, keyed on `field_layout`
///                          presence — am1 caveat 1), so the analyzer no
///                          longer splits on arity. `descriptor` /
///                          `type_name` unused.
///   - `.constructor`     : `type_name` non-null (eval-time lookup via
///                          `resolveJavaSurface`, allows forward refs to
///                          deftypes not yet registered at analyze time);
///                          `args` = ctor args; `name` / `target` /
///                          `descriptor` unused.
///
/// VM lowering: all three kinds ship on both backends. `.instance_member`
/// + `.constructor` compile via `op_method_call` / `op_ctor_call` (am1
/// retired the separate `op_field_access`; a field read folds into
/// `op_method_call`'s receiver-keyed resolver). `.static_method` lowers to
/// the sibling `op_static_method_call` (ADR-0050 am2 / D-130). The ctor
/// path delegates to the shared `special_forms.constructInstance` so
/// TreeWalk + VM construct identically incl. the java-surface `<init>`
/// case `(java.io.File. …)` (D-196).
pub const InteropCallNode = struct {
    pub const Kind = enum { static_method, instance_member, constructor };

    kind: Kind,
    /// `.static_method`: analyze-time resolved descriptor pointer.
    /// Other kinds: null.
    descriptor: ?*const TypeDescriptor = null,
    /// `.instance_member`: receiver expression. Other kinds: null.
    target: ?*const Node = null,
    /// `.constructor`: type name string for eval-time `resolveJavaSurface`
    /// lookup. Other kinds: empty string.
    type_name: []const u8 = "",
    /// `.static_method` / `.instance_member`: method or field name.
    /// `.constructor`: ignored.
    name: []const u8 = "",
    /// `.instance_member`: when true (the `(.-name recv)` reader form), the
    /// resolver reads a field only and never falls back to a method call.
    /// Default false. Other kinds: ignored.
    field_only: bool = false,
    /// Argument expressions. Empty for a field read.
    args: []const Node = &.{},
    loc: SourceLocation = .{},
};

/// `[expr1 expr2 ...]` — vector literal in expression position. The
/// analyzer recursively lifts each child Form to a Node; eval evaluates
/// each, conj-ing the results into an empty `vector` Value.
pub const VectorLiteralNode = struct {
    elements: []const Node,
    loc: SourceLocation = .{},
};

/// `{k1 v1 k2 v2 ...}` — map literal in expression position. The
/// elements slice is flat `[k0, v0, k1, v1, ...]`; the reader
/// guarantees even length. Eval evaluates each child, assoc-ing the
/// k/v pairs into an empty ArrayMap (D-059).
pub const MapLiteralNode = struct {
    elements: []const Node,
    loc: SourceLocation = .{},
};

/// `#{e1 e2 ...}` — set literal in expression position. Eval evaluates
/// each child, conj-ing into an empty HashSet (duplicates collapse, D-061).
pub const SetLiteralNode = struct {
    elements: []const Node,
    loc: SourceLocation = .{},
};

/// `(in-ns 'foo.bar)` — switch `env.current_ns` to the named namespace,
/// creating it if absent. Per ADR-0032 this is a special form (not a
/// primitive Value-arg fn) because quoted-symbol-as-Value has no heap
/// representation in cw v1 yet (F-004 Group A slot 1 reserved for
/// future symbol intern table). The form accepts either a bare symbol
/// (`(in-ns foo)`) or a quoted symbol (`(in-ns 'foo)`); the analyzer
/// flattens both to `ns_name` here. Eval returns `nil` (JVM returns
/// the namespace value — a documented divergence pending the `ns`
/// heap Value landing).
pub const InNsNode = struct {
    ns_name: []const u8,
    loc: SourceLocation = .{},
};

/// `(ns foo)` / `(ns foo (:refer-clojure))` analyser node. ADR-0035
/// D1: cw v1 ships `(ns ...)` as an analyzer special form (not a
/// macro) per the Devil's-advocate finished-form Alt 2. Supports the
/// bare ns name, `(:refer-clojure)` with `:exclude` / `:only` filters
/// (D-098), `(:require ...)` (D-098, see `libspecs`), and
/// `(:import ...)` (D-235, see `imports`). `(:use ...)` /
/// `(:gen-class ...)` are not supported. The arena-owned `name` slice
/// is what `evalNs` passes to `findOrCreateNs`.
pub const NsNode = struct {
    name: []const u8,
    /// `(ns name "docstring" …)` — lands as `{:doc "…"}` on the namespace's
    /// meta at execution (clj parity, D-239 sibling). Null = no docstring.
    doc: ?[]const u8 = null,
    /// `(ns ^{…} name {:attr …})` — the name-symbol reader meta merged with
    /// the attr-map (attr wins), lifted to a map Value at analysis (D-554).
    /// GC-safe in the node: the lift is pushed to the AnalysisFrame, which
    /// production seams persist for the arena's lifetime (D-556). nil = none.
    attr_meta: Value = Value.nil_val,
    /// User wrote `(:refer-clojure)`. When false the auto-refer step is
    /// skipped entirely (cljw-shell-only mode).
    refer_clojure: bool = true,
    /// `(:refer-clojure :exclude [name ...])` filter (D-098)
    /// — names listed here are dropped from the auto-refer pass. Empty
    /// slice = no exclusion. Arena-owned slices.
    refer_clojure_exclude: []const []const u8 = &.{},
    /// `(:refer-clojure :only [name ...])` whitelist (D-098)
    /// — when `null`, all (non-private, non-excluded) names refer; when
    /// non-null, ONLY the listed names refer. Arena-owned.
    refer_clojure_only: ?[]const []const u8 = null,
    /// `(:require [ns ...])` arms collected from the ns directive (D-098).
    /// Each libspec mirrors a top-level `(require ...)`
    /// shape and is materialised by `evalNs` after the refer-clojure
    /// step. Arena-owned.
    libspecs: []const RequireNode = &.{},
    /// `(:import pkg.Class | [pkg C1 C2] …)` (D-235): each entry maps a
    /// simple class name to its fully-qualified (JVM-form) name, so a bare
    /// `(Class. …)` / `Class/method` resolves via the ns import map. Empty
    /// when no `:import` directive is present. Arena-owned.
    imports: []const ImportEntry = &.{},
    loc: SourceLocation = .{},
};

/// One `(:import …)` class entry: `simple` is the bare class name written in
/// code, `fqcn` is the JVM-form fully-qualified name it resolves to.
pub const ImportEntry = struct {
    simple: []const u8,
    fqcn: []const u8,
};

/// `(require 'ns.name)` / `(require '[ns.name :as a :refer [x y]])`
/// analyser node. Phase 6.16.b-4 sub-cycle c.5 lifts beyond the
/// bare-symbol shape to support `:as` (alias install via
/// `env.setAlias`) and `:refer` (per-name refer install via
/// `env.referOne`). `:reload` / `:as-alias` / `:refer :all` and
/// multi-libspec land later within ADR-0035 scope. All slices are
/// arena-owned.
pub const RequireNode = struct {
    ns_name: []const u8,
    /// `:as <alias>` — registered in the calling ns's alias table
    /// when set. `null` = no alias requested.
    alias: ?[]const u8 = null,
    /// `:refer [a b c]` — explicit name list to refer. Empty slice
    /// when not requested. Each element is an arena-owned slice.
    refers: []const []const u8 = &.{},
    /// `:refer :all` (or a `:use` directive) — refer ALL public vars of the
    /// required ns (env.referAll). Mutually exclusive with `refers`.
    refer_all: bool = false,
    /// `:exclude [a b]` (a `:use` blacklist) — when `refer_all` is set, these
    /// names are withheld via `env.referAllWithFilter`. Empty = no blacklist.
    exclude: []const []const u8 = &.{},
    loc: SourceLocation = .{},
};

// --- tests ---

const testing = std.testing;

test "Node.loc dispatches to inner variant" {
    const c = Node{ .constant = .{
        .value = .nil_val,
        .loc = .{ .line = 10, .column = 5 },
    } };
    try testing.expectEqual(@as(u32, 10), c.loc().line);
    try testing.expectEqual(@as(u16, 5), c.loc().column);
}

test "ConstantNode holds primitive Values" {
    const c1 = Node{ .constant = .{ .value = .nil_val } };
    const c2 = Node{ .constant = .{ .value = .true_val } };
    try testing.expectEqual(Value.nil_val, c1.constant.value);
    try testing.expectEqual(Value.true_val, c2.constant.value);
}

test "IfNode supports optional else branch" {
    const cond = Node{ .constant = .{ .value = .true_val } };
    const then_b = Node{ .constant = .{ .value = .nil_val } };
    const else_b = Node{ .constant = .{ .value = .false_val } };

    const with_else = Node{ .if_node = .{
        .cond = &cond,
        .then_branch = &then_b,
        .else_branch = &else_b,
    } };
    try testing.expect(with_else.if_node.else_branch != null);

    const no_else = Node{ .if_node = .{
        .cond = &cond,
        .then_branch = &then_b,
    } };
    try testing.expect(no_else.if_node.else_branch == null);
}

test "FnNode default has_rest is false" {
    const body = Node{ .constant = .{ .value = .nil_val } };
    const params = [_][]const u8{"x"};
    const methods = [_]FnMethod{.{
        .arity = 1,
        .params = &params,
        .body = &body,
    }};
    const fn_node = Node{ .fn_node = .{
        .methods = &methods,
    } };
    try testing.expectEqual(@as(usize, 1), fn_node.fn_node.methods.len);
    try testing.expect(!fn_node.fn_node.methods[0].has_rest);
    try testing.expectEqual(@as(u16, 1), fn_node.fn_node.methods[0].arity);
    try testing.expect(fn_node.fn_node.variadic == null);
}

test "DoNode accepts empty forms" {
    const empty = [_]Node{};
    const do_node = Node{ .do_node = .{ .forms = &empty } };
    try testing.expectEqual(@as(usize, 0), do_node.do_node.forms.len);
}

test "LetNode binding carries name / index / value_expr" {
    const expr = Node{ .constant = .{ .value = .true_val } };
    const body = Node{ .constant = .{ .value = .nil_val } };
    const bindings = [_]LetNode.Binding{
        .{ .name = "x", .index = 0, .value_expr = &expr },
    };
    const let_node = Node{ .let_node = .{
        .bindings = &bindings,
        .body = &body,
    } };
    try testing.expectEqualStrings("x", let_node.let_node.bindings[0].name);
    try testing.expectEqual(@as(u16, 0), let_node.let_node.bindings[0].index);
}

test "DefNode flag defaults are all false" {
    const v = Node{ .constant = .{ .value = .nil_val } };
    const d = DefNode{ .name = "x", .value_expr = &v };
    try testing.expect(!d.is_dynamic);
    try testing.expect(!d.is_macro);
    try testing.expect(!d.is_private);
}

test "QuoteNode stores a reified Value" {
    const q = Node{ .quote_node = .{ .quoted = .true_val } };
    try testing.expectEqual(Value.true_val, q.quote_node.quoted);
}

test "CallNode holds callee + arg list" {
    const callee = Node{ .constant = .{ .value = .nil_val } };
    const args = [_]Node{
        .{ .constant = .{ .value = .true_val } },
        .{ .constant = .{ .value = .false_val } },
    };
    const c = Node{ .call_node = .{
        .callee = &callee,
        .args = &args,
    } };
    try testing.expectEqual(@as(usize, 2), c.call_node.args.len);
}

test "LocalRef.index distinguishes slots with the same name" {
    const a = LocalRef{ .name = "x", .index = 0 };
    const b = LocalRef{ .name = "x", .index = 1 };
    try testing.expectEqualStrings(a.name, b.name);
    try testing.expect(a.index != b.index);
}

test "LoopNode mirrors LetNode binding layout" {
    const expr = Node{ .constant = .{ .value = .nil_val } };
    const body = Node{ .constant = .{ .value = .true_val } };
    const bindings = [_]LetNode.Binding{
        .{ .name = "i", .index = 0, .value_expr = &expr },
    };
    const loop = Node{ .loop_node = .{
        .bindings = &bindings,
        .body = &body,
    } };
    try testing.expectEqual(@as(usize, 1), loop.loop_node.bindings.len);
    try testing.expectEqualStrings("i", loop.loop_node.bindings[0].name);
}

test "RecurNode carries arg list" {
    const args = [_]Node{
        .{ .constant = .{ .value = Value.initInteger(1) } },
        .{ .constant = .{ .value = Value.initInteger(2) } },
    };
    const r = Node{ .recur_node = .{ .args = &args } };
    try testing.expectEqual(@as(usize, 2), r.recur_node.args.len);
}

test "TryNode carries body, catch_clauses (possibly empty), optional finally" {
    const body = Node{ .constant = .{ .value = Value.initInteger(7) } };
    const catch_body = Node{ .constant = .{ .value = .nil_val } };
    const clauses = [_]TryNode.CatchClause{
        .{
            .target = .{ .class_name = "ExceptionInfo" },
            .binding_name = "e",
            .binding_index = 0,
            .body = &catch_body,
        },
    };

    // try with catch, no finally
    const t1 = Node{ .try_node = .{
        .body = &body,
        .catch_clauses = &clauses,
    } };
    try testing.expect(t1.try_node.finally_body == null);
    try testing.expectEqual(@as(usize, 1), t1.try_node.catch_clauses.len);

    // try with finally
    const finally_b = Node{ .constant = .{ .value = .true_val } };
    const t2 = Node{ .try_node = .{
        .body = &body,
        .catch_clauses = &.{},
        .finally_body = &finally_b,
    } };
    try testing.expect(t2.try_node.finally_body != null);
    try testing.expectEqual(@as(usize, 0), t2.try_node.catch_clauses.len);
}

test "ThrowNode carries one expr" {
    const expr = Node{ .constant = .{ .value = .nil_val } };
    const t = Node{ .throw_node = .{ .expr = &expr } };
    try testing.expect(t.throw_node.expr == &expr);
}

test "Node.loc dispatches for new variants" {
    const expr = Node{ .constant = .{ .value = .nil_val } };
    const loop = Node{ .loop_node = .{
        .bindings = &.{},
        .body = &expr,
        .loc = .{ .file = "<t>", .line = 5, .column = 0 },
    } };
    try testing.expectEqual(@as(u32, 5), loop.loc().line);
}
