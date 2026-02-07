// Value type — Runtime value representation for ClojureWasm.
//
// Three-phase architecture:
//   Form (Reader) -> Node (Analyzer) -> Value (Runtime)
//
// Started as tagged union (ADR-0001). NaN boxing deferred to Phase 4.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const collections = @import("collections.zig");
const bootstrap = @import("bootstrap.zig");
const var_mod = @import("var.zig");
pub const Var = var_mod.Var;

pub const PersistentList = collections.PersistentList;
pub const PersistentVector = collections.PersistentVector;
pub const PersistentArrayMap = collections.PersistentArrayMap;
pub const PersistentHashMap = collections.PersistentHashMap;
pub const PersistentHashSet = collections.PersistentHashSet;
pub const TransientVector = collections.TransientVector;
pub const TransientArrayMap = collections.TransientArrayMap;
pub const TransientHashSet = collections.TransientHashSet;
pub const ArrayChunk = collections.ArrayChunk;
pub const ChunkBuffer = collections.ChunkBuffer;
pub const ChunkedCons = collections.ChunkedCons;

const testing = std.testing;

// --- Print state (threadlocal for *print-length*, *print-level*, lazy-seq realization) ---
var print_length_var: ?*const Var = null;
var print_level_var: ?*const Var = null;
threadlocal var print_depth: u32 = 0;
threadlocal var print_allocator: ?Allocator = null;
threadlocal var print_readably: bool = true;

/// Initialize cached Var pointers for print settings. Call once after bootstrap.
pub fn initPrintVars(length_v: *const Var, level_v: *const Var) void {
    print_length_var = length_v;
    print_level_var = level_v;
}

/// Set the allocator used for realizing lazy-seqs during printing.
/// Call before print operations, clear with null after.
pub fn setPrintAllocator(alloc: ?Allocator) void {
    print_allocator = alloc;
}

/// Set readable mode for printing. false = print (unquoted strings), true = pr (quoted).
pub fn setPrintReadably(readably: bool) void {
    print_readably = readably;
}

/// Check *print-level*: if current depth >= level, write "#" and return true.
fn checkPrintLevel(w: *Writer) Writer.Error!bool {
    const level = getPrintLevel() orelse return false;
    if (print_depth >= level) {
        try w.writeAll("#");
        return true;
    }
    return false;
}

/// Print remaining elements of a seq (cons chain, list tail, lazy-seq tail).
/// Used by cons and chunked_cons printers.
fn printSeqRest(w: *Writer, start: Value, length: ?i64, count: *usize) Writer.Error!void {
    var rest = start;
    while (true) {
        switch (rest.tag()) {
            .cons => {
                const rc = rest.asCons();
                if (length) |len| {
                    if (count.* >= @as(usize, @intCast(len))) {
                        try w.writeAll(" ...");
                        return;
                    }
                }
                try w.writeAll(" ");
                try rc.first.formatPrStr(w);
                count.* += 1;
                rest = rc.rest;
            },
            .nil => return,
            .list => {
                const lst = rest.asList();
                for (lst.items) |item| {
                    if (length) |len| {
                        if (count.* >= @as(usize, @intCast(len))) {
                            try w.writeAll(" ...");
                            return;
                        }
                    }
                    try w.writeAll(" ");
                    try item.formatPrStr(w);
                    count.* += 1;
                }
                return;
            },
            .lazy_seq => {
                const ls = rest.asLazySeq();
                if (ls.realized) |r| {
                    rest = r;
                    continue;
                } else if (print_allocator) |alloc| {
                    const realized = ls.realize(alloc) catch {
                        try w.writeAll(" ...");
                        return;
                    };
                    rest = realized;
                    continue;
                } else {
                    try w.writeAll(" ...");
                    return;
                }
            },
            .chunked_cons => {
                const cc = rest.asChunkedCons();
                var i: usize = 0;
                while (i < cc.chunk.count()) : (i += 1) {
                    if (length) |len| {
                        if (count.* >= @as(usize, @intCast(len))) {
                            try w.writeAll(" ...");
                            return;
                        }
                    }
                    try w.writeAll(" ");
                    const elem = cc.chunk.nth(i) orelse Value.nil_val;
                    try elem.formatPrStr(w);
                    count.* += 1;
                }
                if (cc.more.tag() == .nil) return;
                rest = cc.more;
            },
            else => {
                try w.writeAll(" . ");
                try rest.formatPrStr(w);
                return;
            },
        }
    }
}

fn getPrintLength() ?i64 {
    const v = (print_length_var orelse return null).deref();
    return if (v.tag() == .integer) v.asInteger() else null;
}

fn getPrintLevel() ?u32 {
    const v = (print_level_var orelse return null).deref();
    if (v.tag() == .integer and v.asInteger() >= 0) return @intCast(v.asInteger());
    return null;
}

/// Builtin function signature: allocator + args -> Value.
///
/// Core functions (first, rest, cons, conj, nth, count, etc.) are registered
/// as BuiltinFn — a direct Zig function pointer. The VM calls these without
/// var resolution or call frame setup, making them significantly faster than
/// Clojure-defined functions for hot-path operations. ~60 core builtins use
/// this mechanism.
pub const BuiltinFn = *const fn (allocator: std.mem.Allocator, args: []const Value) anyerror!Value;

/// Interned symbol reference.
pub const Symbol = struct {
    ns: ?[]const u8,
    name: []const u8,
    meta: ?*const Value = null,
};

/// Interned keyword reference.
pub const Keyword = struct {
    ns: ?[]const u8,
    name: []const u8,
};

/// Atom — mutable reference type.
pub const Atom = struct {
    value: Value,
    /// Metadata map (mutable via alter-meta! / reset-meta!).
    meta: ?*Value = null,
    /// Validator function (called on swap!/reset!, must return truthy or throw).
    validator: ?Value = null,
    /// Watcher map: key → [key atom old new] callback fn.
    /// Stored as parallel arrays of keys and fns for simplicity.
    watch_keys: ?[]Value = null,
    watch_fns: ?[]Value = null,
    watch_count: usize = 0,
};

/// Volatile — non-atomic mutable reference type.
/// Like Atom but without CAS semantics. Used for thread-local mutation.
pub const Volatile = struct {
    value: Value,
};

/// Reduced — wrapper for early termination in reduce.
/// (reduced x) wraps x; reduce checks for Reduced to stop iteration.
pub const Reduced = struct {
    value: Value,
};

/// Delay — lazy thunk with cached result. Force to evaluate.
pub const Delay = struct {
    fn_val: ?Value, // thunk (null after realization)
    cached: ?Value, // cached result
    error_cached: ?Value, // cached exception (re-thrown on subsequent force)
    realized: bool,
};

/// Compiled regex pattern.
pub const Pattern = struct {
    source: []const u8, // original pattern string
    compiled: *const anyopaque, // *regex.CompiledRegex (opaque to avoid circular deps)
    group_count: u16,
};

/// Discriminator for Fn.proto — bytecode (VM) vs treewalk (Node-based).
pub const FnKind = enum {
    bytecode, // proto points to FnProto (bytecode/chunk.zig)
    treewalk, // proto points to TreeWalk.Closure
};

/// Protocol method signature.
pub const MethodSig = struct {
    name: []const u8,
    arity: u8, // including 'this'
};

/// Protocol — polymorphic dispatch via type-keyed implementation map.
pub const Protocol = struct {
    name: []const u8,
    method_sigs: []const MethodSig,
    /// Maps type_key (string) -> method_map (PersistentArrayMap of method_name -> fn)
    impls: *PersistentArrayMap,
};

/// Protocol method reference — dispatches on first arg's type key.
///
/// Monomorphic inline cache (24A.5): stores the last dispatched (type_key ->
/// method) pair. When the same type is dispatched again (common in loops
/// processing homogeneous collections), the full protocol resolution
/// (impls map lookup + method_name lookup) is bypassed entirely.
/// Cache check: pointer equality first (O(1)), string equality fallback.
pub const ProtocolFn = struct {
    protocol: *Protocol,
    method_name: []const u8,
    cached_type_key: ?[]const u8 = null,
    cached_method: Value = Value.nil_val,
};

/// MultiFn — multimethod with dispatch function and 2-level cache.
///
/// Clojure multimethods dispatch by calling a dispatch function on the args,
/// then looking up the result in the method table (with isa? hierarchy search).
///
/// Two-level monomorphic cache (24C.2):
///   L1 (arg identity): If the first argument is the same object (pointer
///       equality for heap types, value equality for primitives), the dispatch
///       value hasn't changed — skip both dispatch fn call AND method lookup.
///   L2 (dispatch value): If L1 misses but the computed dispatch value
///       equals the cached one, skip findBestMethod + isa? search.
///
/// Also includes a keyword dispatch fast path: when dispatch_fn is a keyword
/// (e.g. (defmulti foo :type)), map lookup is inlined instead of calling it
/// as a function through the VM.
///
/// Impact: multimethod_dispatch 2053ms -> 14ms (147x).
pub const MultiFn = struct {
    name: []const u8,
    dispatch_fn: Value,
    /// Maps dispatch_value -> method function (Value).
    methods: *PersistentArrayMap,
    /// Maps preferred_value -> set of values it is preferred over.
    prefer_table: ?*PersistentArrayMap = null,
    /// Optional custom hierarchy Var (from :hierarchy option).
    /// When set, deref'd to get the hierarchy map instead of global-hierarchy.
    hierarchy_var: ?*Var = null,
    // Level 1 cache: arg identity (pointer/value hash)
    cached_arg_key: usize = 0,
    cached_arg_valid: bool = false,
    // Level 2 cache: dispatch value -> method
    cached_dispatch_val: ?Value = null,
    cached_method: Value = Value.nil_val,

    /// Invalidate the dispatch cache (call after method table changes).
    pub fn invalidateCache(self: *MultiFn) void {
        self.cached_arg_valid = false;
        self.cached_arg_key = 0;
        self.cached_dispatch_val = null;
        self.cached_method = Value.nil_val;
    }

    /// Get identity key for a Value (pointer for heap types, hash for value types).
    /// Returns null for types that shouldn't be identity-cached.
    pub fn argIdentityKey(val: Value) ?usize {
        return switch (val.tag()) {
            .map => @intFromPtr(val.asMap()),
            .hash_map => @intFromPtr(val.asHashMap()),
            .vector => @intFromPtr(val.asVector()),
            .set => @intFromPtr(val.asSet()),
            .keyword => @intFromPtr(val.asKeyword().name.ptr),
            .integer => @as(usize, @bitCast(@as(i64, val.asInteger()))),
            .boolean => @intFromBool(val.asBoolean()),
            .nil => 0xDEAD, // sentinel for nil
            .string => @intFromPtr(val.asString().ptr) ^ val.asString().len,
            .symbol => @intFromPtr(val.asSymbol().name.ptr),
            else => null,
        };
    }
};

/// Cons cell — a pair of (first, rest) forming a linked sequence (24C.4).
///
/// Before this optimization, (cons x seq) copied the entire source sequence
/// into a new PersistentList (ArrayList-backed, O(n) copy). With true cons
/// cells, (cons x seq) allocates just this 2-field struct — O(1) regardless
/// of the sequence length. rest can be list, vector, lazy_seq, cons, or nil.
///
/// Impact: list_build 178ms -> 13ms (14x), along with vector COW.
pub const Cons = struct {
    first: Value,
    rest: Value,
};

/// Lazy sequence — thunk-based deferred evaluation with caching.
///
/// A lazy-seq wraps either a thunk (zero-arg function) or structural metadata.
/// On first realization, the thunk is called (or metadata is computed), and
/// the result is cached. Subsequent accesses return the cached value.
///
/// The optional `meta` field is the key to the fused reduce optimization
/// (24A.3, 24C.1, 24C.7). When core.clj's map/filter/take/range create
/// lazy-seqs, they attach Meta describing the operation and its source.
/// This forms a chain: take(N, filter(pred, map(f, range(M)))). The fused
/// reduce walks this chain at reduce-time and iterates the base source
/// directly, applying all transforms inline — zero intermediate allocations.
pub const LazySeq = struct {
    thunk: ?Value, // fn of 0 args, null after realization
    realized: ?Value, // cached result, null before realization
    meta: ?*const Meta = null, // structural metadata for fused reduce

    /// Structural metadata for lazy-seq chain fusion.
    ///
    /// Each variant describes a lazy operation and its source collection.
    /// fusedReduce (sequences.zig) walks the chain from outermost to innermost,
    /// extracts transforms, and iterates the base source (range/iterate) directly.
    ///
    /// lazy_filter_chain (24C.7): Flattened representation of nested filters.
    /// Instead of filter(p3, filter(p2, filter(p1, src))) creating 3 nested
    /// lazy_filter nodes, the chain is collapsed into a single node with
    /// preds=[p1,p2,p3]. Critical for sieve (168 nested filters → flat array).
    pub const Meta = union(enum) {
        lazy_map: struct { f: Value, source: Value },
        lazy_filter: struct { pred: Value, source: Value },
        lazy_filter_chain: struct { preds: []const Value, source: Value },
        lazy_take: struct { n: usize, source: Value },
        range: struct { current: i64, end: i64, step: i64 },
        iterate: struct { f: Value, current: Value },
    };

    /// Realize this lazy seq by calling the thunk via bootstrap.callFnVal,
    /// or by computing from structural metadata.
    pub fn realize(self: *LazySeq, allocator: std.mem.Allocator) anyerror!Value {
        if (self.realized) |r| return r;

        if (self.meta) |m| {
            const result = try realizeMeta(allocator, m);
            self.realized = result;
            return result;
        }

        const thunk = self.thunk orelse return Value.nil_val;
        const result = try bootstrap.callFnVal(allocator, thunk, &.{});
        self.realized = result;
        self.thunk = null;
        return result;
    }

    /// Compute the realized value from structural metadata.
    /// Returns a cons cell (first + rest lazy-seq) or nil.
    fn realizeMeta(allocator: std.mem.Allocator, m: *const Meta) anyerror!Value {
        const coll_builtins = @import("builtin/collections.zig");
        switch (m.*) {
            .lazy_map => |lm| {
                const seq_val = try coll_builtins.seqFn(allocator, &[1]Value{lm.source});
                if (seq_val.tag() == .nil) return Value.nil_val;
                const first_elem = try coll_builtins.firstFn(allocator, &[1]Value{seq_val});
                const mapped = try bootstrap.callFnVal(allocator, lm.f, &[1]Value{first_elem});
                const rest_source = try coll_builtins.restFn(allocator, &[1]Value{seq_val});
                const rest_meta = try allocator.create(Meta);
                rest_meta.* = .{ .lazy_map = .{ .f = lm.f, .source = rest_source } };
                const rest_ls = try allocator.create(LazySeq);
                rest_ls.* = .{ .thunk = null, .realized = null, .meta = rest_meta };
                const cons_cell = try allocator.create(Cons);
                cons_cell.* = .{ .first = mapped, .rest = Value.initLazySeq(rest_ls) };
                return Value.initCons(cons_cell);
            },
            .lazy_filter => |lf| {
                var current = lf.source;
                while (true) {
                    const seq_val = try coll_builtins.seqFn(allocator, &[1]Value{current});
                    if (seq_val.tag() == .nil) return Value.nil_val;
                    const elem = try coll_builtins.firstFn(allocator, &[1]Value{seq_val});
                    const pred_result = try bootstrap.callFnVal(allocator, lf.pred, &[1]Value{elem});
                    if (pred_result.isTruthy()) {
                        const rest_source = try coll_builtins.restFn(allocator, &[1]Value{seq_val});
                        const rest_meta = try allocator.create(Meta);
                        rest_meta.* = .{ .lazy_filter = .{ .pred = lf.pred, .source = rest_source } };
                        const rest_ls = try allocator.create(LazySeq);
                        rest_ls.* = .{ .thunk = null, .realized = null, .meta = rest_meta };
                        const cons_cell = try allocator.create(Cons);
                        cons_cell.* = .{ .first = elem, .rest = Value.initLazySeq(rest_ls) };
                        return Value.initCons(cons_cell);
                    }
                    current = try coll_builtins.restFn(allocator, &[1]Value{seq_val});
                }
            },
            .lazy_filter_chain => |lfc| {
                // Flat iteration: check ALL predicates on each element, no deep recursion.
                // This collapses N nested filters into a single-level loop.
                var current = lfc.source;
                outer: while (true) {
                    const seq_val = try coll_builtins.seqFn(allocator, &[1]Value{current});
                    if (seq_val.tag() == .nil) return Value.nil_val;
                    const elem = try coll_builtins.firstFn(allocator, &[1]Value{seq_val});
                    // Check all predicates (innermost first)
                    for (lfc.preds) |pred| {
                        const pred_result = try bootstrap.callFnVal(allocator, pred, &[1]Value{elem});
                        if (!pred_result.isTruthy()) {
                            current = try coll_builtins.restFn(allocator, &[1]Value{seq_val});
                            continue :outer;
                        }
                    }
                    // All predicates passed — create cons cell with rest chain
                    const rest_source = try coll_builtins.restFn(allocator, &[1]Value{seq_val});
                    const rest_meta = try allocator.create(Meta);
                    rest_meta.* = .{ .lazy_filter_chain = .{ .preds = lfc.preds, .source = rest_source } };
                    const rest_ls = try allocator.create(LazySeq);
                    rest_ls.* = .{ .thunk = null, .realized = null, .meta = rest_meta };
                    const cons_cell = try allocator.create(Cons);
                    cons_cell.* = .{ .first = elem, .rest = Value.initLazySeq(rest_ls) };
                    return Value.initCons(cons_cell);
                }
            },
            .lazy_take => |lt| {
                if (lt.n == 0) return Value.nil_val;
                const seq_val = try coll_builtins.seqFn(allocator, &[1]Value{lt.source});
                if (seq_val.tag() == .nil) return Value.nil_val;
                const first_elem = try coll_builtins.firstFn(allocator, &[1]Value{seq_val});
                const rest_source = try coll_builtins.restFn(allocator, &[1]Value{seq_val});
                const rest_meta = try allocator.create(Meta);
                rest_meta.* = .{ .lazy_take = .{ .n = lt.n - 1, .source = rest_source } };
                const rest_ls = try allocator.create(LazySeq);
                rest_ls.* = .{ .thunk = null, .realized = null, .meta = rest_meta };
                const cons_cell = try allocator.create(Cons);
                cons_cell.* = .{ .first = first_elem, .rest = Value.initLazySeq(rest_ls) };
                return Value.initCons(cons_cell);
            },
            .range => |r| {
                if ((r.step > 0 and r.current >= r.end) or
                    (r.step < 0 and r.current <= r.end) or
                    (r.step == 0)) return Value.nil_val;
                const rest_meta = try allocator.create(Meta);
                rest_meta.* = .{ .range = .{ .current = r.current + r.step, .end = r.end, .step = r.step } };
                const rest_ls = try allocator.create(LazySeq);
                rest_ls.* = .{ .thunk = null, .realized = null, .meta = rest_meta };
                const cons_cell = try allocator.create(Cons);
                cons_cell.* = .{ .first = Value.initInteger(r.current), .rest = Value.initLazySeq(rest_ls) };
                return Value.initCons(cons_cell);
            },
            .iterate => |it| {
                const next_val = try bootstrap.callFnVal(allocator, it.f, &[1]Value{it.current});
                const rest_meta = try allocator.create(Meta);
                rest_meta.* = .{ .iterate = .{ .f = it.f, .current = next_val } };
                const rest_ls = try allocator.create(LazySeq);
                rest_ls.* = .{ .thunk = null, .realized = null, .meta = rest_meta };
                const cons_cell = try allocator.create(Cons);
                cons_cell.* = .{ .first = it.current, .rest = Value.initLazySeq(rest_ls) };
                return Value.initCons(cons_cell);
            },
        }
    }
};

/// Runtime function (closure). Proto is stored as opaque pointer
/// to avoid circular dependency with bytecode/chunk.zig.
pub const Fn = struct {
    proto: *const anyopaque,
    kind: FnKind = .bytecode,
    closure_bindings: ?[]const Value = null,
    /// Additional arity protos for multi-arity functions.
    /// Each entry is a *const FnProto (opaque to avoid circular import).
    /// Null for single-arity functions (common case — no overhead).
    extra_arities: ?[]const *const anyopaque = null,
    /// Metadata map (Clojure IMeta protocol).
    meta: ?*const Value = null,
    /// Namespace name where this function was defined (D68).
    /// Used by TreeWalk to restore current_ns during execution so that
    /// unqualified var references resolve in the defining namespace.
    defining_ns: ?[]const u8 = null,
};

/// Runtime value — tagged union representation.
/// Minimal variants for Phase 1a. More added incrementally.
pub const Value = union(enum) {
    // Primitives
    nil,
    boolean: bool,
    integer: i64,
    float: f64,
    char: u21,

    // String / identifiers
    string: []const u8,
    symbol: Symbol,
    keyword: Keyword,

    // Collections
    list: *const PersistentList,
    vector: *const PersistentVector,
    map: *const PersistentArrayMap,
    hash_map: *const PersistentHashMap,
    set: *const PersistentHashSet,

    // Functions
    fn_val: *const Fn,
    builtin_fn: *const fn (std.mem.Allocator, []const Value) anyerror!Value,

    // Reference types
    atom: *Atom,
    volatile_ref: *Volatile,

    // Regex pattern
    regex: *Pattern,

    // Protocol types
    protocol: *Protocol,
    protocol_fn: *const ProtocolFn,

    // Multimethod
    multi_fn: *MultiFn,

    // Lazy sequence / cons cell
    lazy_seq: *LazySeq,
    cons: *Cons,

    // Var reference — first-class Var value (#'foo)
    var_ref: *Var,

    // Delay — lazy thunk with cached result
    delay: *Delay,

    // Reduced — early termination wrapper for reduce
    reduced: *const Reduced,

    // Transient collections — mutable builders
    transient_vector: *TransientVector,
    transient_map: *TransientArrayMap,
    transient_set: *TransientHashSet,

    // Chunked sequences
    chunked_cons: *const ChunkedCons,
    chunk_buffer: *ChunkBuffer,
    array_chunk: *const ArrayChunk,

    // Wasm InterOp (Phase 25)
    wasm_module: *@import("../wasm/types.zig").WasmModule,
    wasm_fn: *const @import("../wasm/types.zig").WasmFn,

    // === Value Accessor API (Phase 27 — NaN boxing preparation) ===
    //
    // All code outside value.zig should use these methods instead of
    // direct union field access. This enables future representation
    // changes (NaN boxing: union(enum) -> packed u64) without
    // touching call sites.

    pub const Tag = std.meta.Tag(@This());

    // --- Constants ---

    pub const nil_val: Value = .nil;
    pub const true_val: Value = .{ .boolean = true };
    pub const false_val: Value = .{ .boolean = false };

    // --- Tag query ---

    pub fn tag(self: Value) Tag {
        return std.meta.activeTag(self);
    }

    // --- Constructors ---

    pub fn initBoolean(b: bool) Value {
        return .{ .boolean = b };
    }

    pub fn initInteger(i: i64) Value {
        return .{ .integer = i };
    }

    pub fn initFloat(f: f64) Value {
        return .{ .float = f };
    }

    pub fn initChar(c: u21) Value {
        return .{ .char = c };
    }

    pub fn initString(_: Allocator, s: []const u8) Value {
        return .{ .string = s };
    }

    pub fn initSymbol(_: Allocator, s: Symbol) Value {
        return .{ .symbol = s };
    }

    pub fn initKeyword(_: Allocator, k: Keyword) Value {
        return .{ .keyword = k };
    }

    pub fn initList(l: *const PersistentList) Value {
        return .{ .list = l };
    }

    pub fn initVector(v: *const PersistentVector) Value {
        return .{ .vector = v };
    }

    pub fn initMap(m: *const PersistentArrayMap) Value {
        return .{ .map = m };
    }

    pub fn initHashMap(m: *const PersistentHashMap) Value {
        return .{ .hash_map = m };
    }

    pub fn initSet(s: *const PersistentHashSet) Value {
        return .{ .set = s };
    }

    pub fn initFn(f: *const Fn) Value {
        return .{ .fn_val = f };
    }

    pub fn initBuiltinFn(f: BuiltinFn) Value {
        return .{ .builtin_fn = f };
    }

    pub fn initAtom(a: *Atom) Value {
        return .{ .atom = a };
    }

    pub fn initVolatile(v: *Volatile) Value {
        return .{ .volatile_ref = v };
    }

    pub fn initRegex(r: *Pattern) Value {
        return .{ .regex = r };
    }

    pub fn initProtocol(p: *Protocol) Value {
        return .{ .protocol = p };
    }

    pub fn initProtocolFn(pf: *const ProtocolFn) Value {
        return .{ .protocol_fn = pf };
    }

    pub fn initMultiFn(m: *MultiFn) Value {
        return .{ .multi_fn = m };
    }

    pub fn initLazySeq(ls: *LazySeq) Value {
        return .{ .lazy_seq = ls };
    }

    pub fn initCons(c: *Cons) Value {
        return .{ .cons = c };
    }

    pub fn initVarRef(v: *Var) Value {
        return .{ .var_ref = v };
    }

    pub fn initDelay(d: *Delay) Value {
        return .{ .delay = d };
    }

    pub fn initReduced(r: *const Reduced) Value {
        return .{ .reduced = r };
    }

    pub fn initTransientVector(tv: *TransientVector) Value {
        return .{ .transient_vector = tv };
    }

    pub fn initTransientMap(tm: *TransientArrayMap) Value {
        return .{ .transient_map = tm };
    }

    pub fn initTransientSet(ts: *TransientHashSet) Value {
        return .{ .transient_set = ts };
    }

    pub fn initChunkedCons(cc: *const ChunkedCons) Value {
        return .{ .chunked_cons = cc };
    }

    pub fn initChunkBuffer(cb: *ChunkBuffer) Value {
        return .{ .chunk_buffer = cb };
    }

    pub fn initArrayChunk(ac: *const ArrayChunk) Value {
        return .{ .array_chunk = ac };
    }

    pub fn initWasmModule(m: *@import("../wasm/types.zig").WasmModule) Value {
        return .{ .wasm_module = m };
    }

    pub fn initWasmFn(f: *const @import("../wasm/types.zig").WasmFn) Value {
        return .{ .wasm_fn = f };
    }

    // --- Extractors ---

    pub fn asBoolean(self: Value) bool {
        return self.boolean;
    }

    pub fn asInteger(self: Value) i64 {
        return self.integer;
    }

    pub fn asFloat(self: Value) f64 {
        return self.float;
    }

    pub fn asChar(self: Value) u21 {
        return self.char;
    }

    pub fn asString(self: Value) []const u8 {
        return self.string;
    }

    pub fn asSymbol(self: Value) Symbol {
        return self.symbol;
    }

    pub fn asKeyword(self: Value) Keyword {
        return self.keyword;
    }

    pub fn asList(self: Value) *const PersistentList {
        return self.list;
    }

    pub fn asVector(self: Value) *const PersistentVector {
        return self.vector;
    }

    pub fn asMap(self: Value) *const PersistentArrayMap {
        return self.map;
    }

    pub fn asHashMap(self: Value) *const PersistentHashMap {
        return self.hash_map;
    }

    pub fn asSet(self: Value) *const PersistentHashSet {
        return self.set;
    }

    pub fn asFn(self: Value) *const Fn {
        return self.fn_val;
    }

    pub fn asBuiltinFn(self: Value) BuiltinFn {
        return self.builtin_fn;
    }

    pub fn asAtom(self: Value) *Atom {
        return self.atom;
    }

    pub fn asVolatile(self: Value) *Volatile {
        return self.volatile_ref;
    }

    pub fn asRegex(self: Value) *Pattern {
        return self.regex;
    }

    pub fn asProtocol(self: Value) *Protocol {
        return self.protocol;
    }

    pub fn asProtocolFn(self: Value) *const ProtocolFn {
        return self.protocol_fn;
    }

    pub fn asMultiFn(self: Value) *MultiFn {
        return self.multi_fn;
    }

    pub fn asLazySeq(self: Value) *LazySeq {
        return self.lazy_seq;
    }

    pub fn asCons(self: Value) *Cons {
        return self.cons;
    }

    pub fn asVarRef(self: Value) *Var {
        return self.var_ref;
    }

    pub fn asDelay(self: Value) *Delay {
        return self.delay;
    }

    pub fn asReduced(self: Value) *const Reduced {
        return self.reduced;
    }

    pub fn asTransientVector(self: Value) *TransientVector {
        return self.transient_vector;
    }

    pub fn asTransientMap(self: Value) *TransientArrayMap {
        return self.transient_map;
    }

    pub fn asTransientSet(self: Value) *TransientHashSet {
        return self.transient_set;
    }

    pub fn asChunkedCons(self: Value) *const ChunkedCons {
        return self.chunked_cons;
    }

    pub fn asChunkBuffer(self: Value) *ChunkBuffer {
        return self.chunk_buffer;
    }

    pub fn asArrayChunk(self: Value) *const ArrayChunk {
        return self.array_chunk;
    }

    pub fn asWasmModule(self: Value) *@import("../wasm/types.zig").WasmModule {
        return self.wasm_module;
    }

    pub fn asWasmFn(self: Value) *const @import("../wasm/types.zig").WasmFn {
        return self.wasm_fn;
    }

    // === End Value Accessor API ===

    /// Clojure pr-str semantics: format value for printing.
    pub fn formatPrStr(self: Value, w: *Writer) Writer.Error!void {
        switch (self.tag()) {
            .nil => {
                if (print_readably) try w.writeAll("nil");
                // Non-readable: nil => "" (empty), matching Clojure str/print semantics
            },
            .boolean => {
                const b = self.asBoolean();
                try w.writeAll(if (b) "true" else "false");
            },
            .integer => {
                const n = self.asInteger();
                try w.print("{d}", .{n});
            },
            .float => {
                const n = self.asFloat();
                // Handle special float values
                if (std.math.isNan(n)) {
                    try w.writeAll("##NaN");
                } else if (std.math.isPositiveInf(n)) {
                    try w.writeAll("##Inf");
                } else if (std.math.isNegativeInf(n)) {
                    try w.writeAll("##-Inf");
                } else {
                    // Try decimal format first (works for normal-range numbers)
                    var dec_buf: [32]u8 = undefined;
                    const dec_result = std.fmt.bufPrint(&dec_buf, "{d}", .{n});
                    if (dec_result) |s| {
                        try w.writeAll(s);
                        var has_dot = false;
                        for (s) |ch| {
                            if (ch == '.' or ch == 'e' or ch == 'E') {
                                has_dot = true;
                                break;
                            }
                        }
                        if (!has_dot) try w.writeAll(".0");
                    } else |_| {
                        // Decimal overflows buffer — use scientific notation
                        var sci_buf: [32]u8 = undefined;
                        const s = std.fmt.bufPrint(&sci_buf, "{e}", .{n}) catch "0.0";
                        // Convert lowercase 'e' to uppercase 'E' for Clojure compatibility
                        // and ensure mantissa has a decimal point
                        var wrote_mantissa = false;
                        var has_dot = false;
                        for (s) |ch| {
                            if (ch == 'e' or ch == 'E') {
                                if (!has_dot) try w.writeAll(".0");
                                try w.writeByte('E');
                                wrote_mantissa = true;
                            } else {
                                if (ch == '.') has_dot = true;
                                try w.writeByte(ch);
                            }
                        }
                        if (!wrote_mantissa and !has_dot) try w.writeAll(".0");
                    }
                }
            },
            .char => {
                const c = self.asChar();
                if (!print_readably) {
                    // Non-readable: literal character
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(c, &buf) catch 0;
                    try w.writeAll(buf[0..len]);
                } else switch (c) {
                    '\n' => try w.writeAll("\\newline"),
                    '\r' => try w.writeAll("\\return"),
                    ' ' => try w.writeAll("\\space"),
                    '\t' => try w.writeAll("\\tab"),
                    else => {
                        try w.writeAll("\\");
                        var buf2: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(c, &buf2) catch 0;
                        try w.writeAll(buf2[0..len]);
                    },
                }
            },
            .string => {
                const s = self.asString();
                if (print_readably) {
                    try w.writeByte('"');
                    for (s) |c| {
                        switch (c) {
                            '"' => try w.writeAll("\\\""),
                            '\\' => try w.writeAll("\\\\"),
                            '\n' => try w.writeAll("\\n"),
                            '\t' => try w.writeAll("\\t"),
                            '\r' => try w.writeAll("\\r"),
                            else => try w.writeByte(c),
                        }
                    }
                    try w.writeByte('"');
                } else {
                    try w.writeAll(s);
                }
            },
            .symbol => {
                const sym = self.asSymbol();
                if (sym.ns) |ns| {
                    try w.print("{s}/{s}", .{ ns, sym.name });
                } else {
                    try w.writeAll(sym.name);
                }
            },
            .keyword => {
                const k = self.asKeyword();
                if (k.ns) |ns| {
                    try w.print(":{s}/{s}", .{ ns, k.name });
                } else {
                    try w.print(":{s}", .{k.name});
                }
            },
            .list => {
                const lst = self.asList();
                if (try checkPrintLevel(w)) return;
                const length = getPrintLength();
                try w.writeAll("(");
                print_depth += 1;
                for (lst.items, 0..) |item, i| {
                    if (i > 0) try w.writeAll(" ");
                    if (length) |len| {
                        if (i >= @as(usize, @intCast(len))) {
                            try w.writeAll("...");
                            break;
                        }
                    }
                    try item.formatPrStr(w);
                }
                print_depth -= 1;
                try w.writeAll(")");
            },
            .vector => {
                const vec = self.asVector();
                if (try checkPrintLevel(w)) return;
                const length = getPrintLength();
                try w.writeAll("[");
                print_depth += 1;
                for (vec.items, 0..) |item, i| {
                    if (i > 0) try w.writeAll(" ");
                    if (length) |len| {
                        if (i >= @as(usize, @intCast(len))) {
                            try w.writeAll("...");
                            break;
                        }
                    }
                    try item.formatPrStr(w);
                }
                print_depth -= 1;
                try w.writeAll("]");
            },
            .map => {
                const m = self.asMap();
                if (try checkPrintLevel(w)) return;
                const length = getPrintLength();
                try w.writeAll("{");
                print_depth += 1;
                var i: usize = 0;
                var pair_idx: usize = 0;
                var is_first = true;
                while (i < m.entries.len) : (i += 2) {
                    if (length) |len| {
                        if (pair_idx >= @as(usize, @intCast(len))) {
                            if (!is_first) try w.writeAll(", ");
                            try w.writeAll("...");
                            break;
                        }
                    }
                    if (!is_first) try w.writeAll(", ");
                    is_first = false;
                    try m.entries[i].formatPrStr(w);
                    try w.writeAll(" ");
                    try m.entries[i + 1].formatPrStr(w);
                    pair_idx += 1;
                }
                print_depth -= 1;
                try w.writeAll("}");
            },
            .hash_map => {
                const hm = self.asHashMap();
                if (try checkPrintLevel(w)) return;
                const length = getPrintLength();
                try w.writeAll("{");
                print_depth += 1;
                // Collect entries for printing
                const alloc = print_allocator orelse std.heap.page_allocator;
                const entries = hm.toEntries(alloc) catch &[_]Value{};
                var i: usize = 0;
                var pair_idx: usize = 0;
                var is_first = true;
                while (i < entries.len) : (i += 2) {
                    if (length) |len| {
                        if (pair_idx >= @as(usize, @intCast(len))) {
                            if (!is_first) try w.writeAll(", ");
                            try w.writeAll("...");
                            break;
                        }
                    }
                    if (!is_first) try w.writeAll(", ");
                    is_first = false;
                    try entries[i].formatPrStr(w);
                    try w.writeAll(" ");
                    try entries[i + 1].formatPrStr(w);
                    pair_idx += 1;
                }
                print_depth -= 1;
                try w.writeAll("}");
            },
            .set => {
                const s = self.asSet();
                if (try checkPrintLevel(w)) return;
                const length = getPrintLength();
                try w.writeAll("#{");
                print_depth += 1;
                for (s.items, 0..) |item, i| {
                    if (i > 0) try w.writeAll(" ");
                    if (length) |len| {
                        if (i >= @as(usize, @intCast(len))) {
                            try w.writeAll("...");
                            break;
                        }
                    }
                    try item.formatPrStr(w);
                }
                print_depth -= 1;
                try w.writeAll("}");
            },
            .fn_val => try w.writeAll("#<fn>"),
            .builtin_fn => try w.writeAll("#<builtin-fn>"),
            .atom => {
                const a = self.asAtom();
                try w.writeAll("#<atom ");
                try a.value.formatPrStr(w);
                try w.writeAll(">");
            },
            .volatile_ref => {
                const v = self.asVolatile();
                try w.writeAll("#<volatile ");
                try v.value.formatPrStr(w);
                try w.writeAll(">");
            },
            .regex => {
                const p = self.asRegex();
                try w.writeAll("#\"");
                try w.writeAll(p.source);
                try w.writeAll("\"");
            },
            .protocol => {
                const p = self.asProtocol();
                try w.writeAll("#<protocol ");
                try w.writeAll(p.name);
                try w.writeAll(">");
            },
            .protocol_fn => {
                const pf = self.asProtocolFn();
                try w.writeAll("#<protocol-fn ");
                try w.writeAll(pf.protocol.name);
                try w.writeAll("/");
                try w.writeAll(pf.method_name);
                try w.writeAll(">");
            },
            .multi_fn => {
                const mf = self.asMultiFn();
                try w.writeAll("#<multifn ");
                try w.writeAll(mf.name);
                try w.writeAll(">");
            },
            .lazy_seq => {
                const ls = self.asLazySeq();
                if (ls.realized) |r| {
                    try r.formatPrStr(w);
                } else if (print_allocator) |alloc| {
                    // Realize lazy-seq for printing (like JVM Clojure)
                    const realized = ls.realize(alloc) catch {
                        try w.writeAll("#<lazy-seq>");
                        return;
                    };
                    try realized.formatPrStr(w);
                } else {
                    try w.writeAll("#<lazy-seq>");
                }
            },
            .var_ref => {
                const v = self.asVarRef();
                try w.writeAll("#'");
                try w.writeAll(v.ns_name);
                try w.writeAll("/");
                try w.writeAll(v.sym.name);
            },
            .delay => {
                const d = self.asDelay();
                if (d.realized) {
                    try w.writeAll("#delay[");
                    if (d.cached) |v| try v.formatPrStr(w) else try w.writeAll("nil");
                    try w.writeAll("]");
                } else {
                    try w.writeAll("#delay[pending]");
                }
            },
            .reduced => {
                const r = self.asReduced();
                try r.value.formatPrStr(w);
            },
            .transient_vector => try w.writeAll("#<TransientVector>"),
            .transient_map => try w.writeAll("#<TransientMap>"),
            .transient_set => try w.writeAll("#<TransientSet>"),
            .chunked_cons => {
                const cc = self.asChunkedCons();
                if (try checkPrintLevel(w)) return;
                const length = getPrintLength();
                try w.writeAll("(");
                print_depth += 1;
                var count: usize = 0;
                var i: usize = 0;
                var truncated = false;
                while (i < cc.chunk.count()) : (i += 1) {
                    if (length) |len| {
                        if (count >= @as(usize, @intCast(len))) {
                            truncated = true;
                            break;
                        }
                    }
                    if (count > 0) try w.writeAll(" ");
                    const elem = cc.chunk.nth(i) orelse Value.nil_val;
                    try elem.formatPrStr(w);
                    count += 1;
                }
                if (!truncated and cc.more.tag() != .nil) {
                    // Print elements from rest chunks
                    try printSeqRest(w, cc.more, length, &count);
                }
                print_depth -= 1;
                try w.writeAll(")");
            },
            .chunk_buffer => try w.writeAll("#<ChunkBuffer>"),
            .array_chunk => try w.writeAll("#<ArrayChunk>"),
            .wasm_module => try w.writeAll("#<WasmModule>"),
            .wasm_fn => {
                const wf = self.asWasmFn();
                try w.print("#<WasmFn {s}>", .{wf.name});
            },
            .cons => {
                const c = self.asCons();
                if (try checkPrintLevel(w)) return;
                const length = getPrintLength();
                try w.writeAll("(");
                print_depth += 1;
                var count: usize = 0;
                // Check print-length for first element
                if (length) |len| {
                    if (count >= @as(usize, @intCast(len))) {
                        try w.writeAll("...");
                        print_depth -= 1;
                        try w.writeAll(")");
                        return;
                    }
                }
                try c.first.formatPrStr(w);
                count += 1;
                // Print rest elements
                try printSeqRest(w, c.rest, length, &count);
                print_depth -= 1;
                try w.writeAll(")");
            },
        }
    }

    /// Clojure str semantics: non-readable string conversion.
    /// Differs from formatPrStr: nil => "", strings unquoted, chars as literal.
    pub fn formatStr(self: Value, w: *Writer) Writer.Error!void {
        switch (self.tag()) {
            .nil => {}, // nil => "" (empty)
            .char => {
                const c = self.asChar();
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c, &buf) catch 0;
                try w.writeAll(buf[0..len]);
            },
            .string => try w.writeAll(self.asString()),
            else => try self.formatPrStr(w),
        }
    }

    /// Clojure = semantics: structural equality.
    /// For contexts without an allocator (cannot realize lazy-seqs).
    pub fn eql(self: Value, other: Value) bool {
        return self.eqlImpl(other, null);
    }

    /// Clojure = semantics with allocator: can realize lazy-seqs for comparison.
    /// Use this from builtin `=` and other contexts that have an allocator.
    pub fn eqlAlloc(self: Value, other: Value, allocator: Allocator) bool {
        return self.eqlImpl(other, allocator);
    }

    fn eqlImpl(self: Value, other: Value, allocator: ?Allocator) bool {
        const self_tag = self.tag();
        const other_tag = other.tag();

        // Cross-type numeric equality: (= 1 1.0) => true
        if ((self_tag == .integer and other_tag == .float) or
            (self_tag == .float and other_tag == .integer))
        {
            const a: f64 = if (self_tag == .integer) @floatFromInt(self.asInteger()) else self.asFloat();
            const b: f64 = if (other_tag == .integer) @floatFromInt(other.asInteger()) else other.asFloat();
            return a == b;
        }

        // Lazy seqs: realize and compare using JVM LazySeq.equiv() semantics.
        // A realized-nil lazy-seq is an empty sequence (equals () or [], but NOT nil).
        if (self_tag == .lazy_seq) {
            return eqlLazySide(self.asLazySeq(), other, other_tag, allocator);
        }
        if (other_tag == .lazy_seq) {
            return eqlLazySide(other.asLazySeq(), self, self_tag, allocator);
        }

        // Cons cells and chunked cons: compare as sequences
        if (self_tag == .cons or other_tag == .cons or self_tag == .chunked_cons or other_tag == .chunked_cons) {
            return eqlConsSeq(self, other, allocator);
        }

        // Sequential equality: (= '(1 2) [1 2]) => true
        if (isSequential(self_tag) and isSequential(other_tag)) {
            const a_items = sequentialItems(self);
            const b_items = sequentialItems(other);
            if (a_items.len != b_items.len) return false;
            for (a_items, b_items) |ai, bi| {
                if (!ai.eqlImpl(bi, allocator)) return false;
            }
            return true;
        }

        // Cross-type map equality: ArrayMap and HashMap compare by entries
        if ((self_tag == .map or self_tag == .hash_map) and
            (other_tag == .map or other_tag == .hash_map))
        {
            return eqlMaps(self, self_tag, other, other_tag, allocator);
        }

        if (self_tag != other_tag) return false;

        return switch (self.tag()) {
            .nil => true,
            .boolean => self.asBoolean() == other.asBoolean(),
            .integer => self.asInteger() == other.asInteger(),
            .float => self.asFloat() == other.asFloat(),
            .char => self.asChar() == other.asChar(),
            .string => std.mem.eql(u8, self.asString(), other.asString()),
            .symbol => eqlOptionalStr(self.asSymbol().ns, other.asSymbol().ns) and std.mem.eql(u8, self.asSymbol().name, other.asSymbol().name),
            .keyword => eqlOptionalStr(self.asKeyword().ns, other.asKeyword().ns) and std.mem.eql(u8, self.asKeyword().name, other.asKeyword().name),
            .list, .vector => unreachable, // handled by sequential equality above
            .fn_val => self.asFn() == other.asFn(),
            .builtin_fn => self.asBuiltinFn() == other.asBuiltinFn(),
            .atom => self.asAtom() == other.asAtom(), // identity equality
            .volatile_ref => self.asVolatile() == other.asVolatile(), // identity equality
            .regex => std.mem.eql(u8, self.asRegex().source, other.asRegex().source), // pattern string equality
            .protocol => self.asProtocol() == other.asProtocol(), // identity equality
            .protocol_fn => self.asProtocolFn() == other.asProtocolFn(), // identity equality
            .multi_fn => self.asMultiFn() == other.asMultiFn(), // identity equality
            .lazy_seq => unreachable, // handled by early return above
            .var_ref => self.asVarRef() == other.asVarRef(), // identity equality
            .cons => unreachable, // handled by eqlConsSeq above
            .delay => self.asDelay() == other.asDelay(), // identity equality
            .reduced => self.asReduced().value.eqlImpl(other.asReduced().value, allocator),
            .map, .hash_map => unreachable, // handled by eqlMaps above
            .set => {
                const a = self.asSet();
                const b = other.asSet();
                if (a.count() != b.count()) return false;
                for (a.items) |item| {
                    if (!b.contains(item)) return false;
                }
                return true;
            },
            .transient_vector => self.asTransientVector() == other.asTransientVector(), // identity equality
            .transient_map => self.asTransientMap() == other.asTransientMap(), // identity equality
            .transient_set => self.asTransientSet() == other.asTransientSet(), // identity equality
            .chunked_cons => unreachable, // handled by eqlConsSeq above
            .chunk_buffer => self.asChunkBuffer() == other.asChunkBuffer(), // identity equality
            .array_chunk => self.asArrayChunk() == other.asArrayChunk(), // identity equality
            .wasm_module => self.asWasmModule() == other.asWasmModule(), // identity equality
            .wasm_fn => self.asWasmFn() == other.asWasmFn(), // identity equality
        };
    }

    /// Returns true if this value is nil.
    pub fn isNil(self: Value) bool {
        return self.tag() == .nil;
    }

    /// Clojure truthiness: everything is truthy except nil and false.
    pub fn isTruthy(self: Value) bool {
        return switch (self.tag()) {
            .nil => false,
            .boolean => self.asBoolean(),
            else => true,
        };
    }
};

fn isSequential(t: Value.Tag) bool {
    return t == .list or t == .vector;
}

fn sequentialItems(v: Value) []const Value {
    return switch (v.tag()) {
        .list => v.asList().items,
        .vector => v.asVector().items,
        else => unreachable,
    };
}

/// Lazy-seq equality following JVM LazySeq.equiv() semantics:
/// - Realize the lazy-seq
/// - If nil: it's an empty sequence — equal to other empty sequentials, NOT to nil
/// - If non-nil: delegate to the realized value's equality
fn eqlLazySide(lazy: *LazySeq, other: Value, other_tag: Value.Tag, allocator: ?Allocator) bool {
    const realized = blk: {
        if (allocator) |alloc| {
            break :blk lazy.realize(alloc) catch return false;
        }
        break :blk lazy.realized orelse return false;
    };
    if (realized.tag() == .nil) {
        // Empty lazy-seq: equal only to empty sequential types
        if (other_tag == .nil) return false; // (= nil (lazy-seq nil)) => false
        if (isSequential(other_tag)) {
            return sequentialItems(other).len == 0;
        }
        if (other_tag == .cons) return false; // cons is never empty
        if (other_tag == .lazy_seq) {
            // Compare two lazy-seqs: both must realize to empty
            if (allocator) |alloc| {
                const other_realized = other.asLazySeq().realize(alloc) catch return false;
                return other_realized.tag() == .nil;
            }
            if (other.asLazySeq().realized) |r| return r.tag() == .nil;
            return false;
        }
        return false;
    }
    return realized.eqlImpl(other, allocator);
}

/// Compare a cons/chunked_cons with another sequential value element-by-element.
/// Handles cons vs cons, cons vs list/vector, chunked_cons vs list/vector, etc.
fn eqlConsSeq(a: Value, b: Value, allocator: ?Allocator) bool {
    const a_tag = a.tag();
    const b_tag = b.tag();

    // Fast path: both cons
    if (a_tag == .cons and b_tag == .cons) {
        if (!a.asCons().first.eqlImpl(b.asCons().first, allocator)) return false;
        return a.asCons().rest.eqlImpl(b.asCons().rest, allocator);
    }

    const is_a_walker = (a_tag == .cons or a_tag == .chunked_cons);
    const is_b_walker = (b_tag == .cons or b_tag == .chunked_cons);

    // One walker, one sequential (or nil)
    if (is_a_walker and !is_b_walker) {
        if (b_tag == .nil) return false;
        if (!isSequential(b_tag)) return false;
        return eqlWalkVsItems(a, sequentialItems(b), allocator);
    }
    if (is_b_walker and !is_a_walker) {
        return eqlConsSeq(b, a, allocator);
    }

    // Both walkers (cons/chunked_cons mix): flatten b then walk vs items
    const alloc = allocator orelse return false;
    var b_items: std.ArrayListUnmanaged(Value) = .empty;
    var cur = b;
    while (true) {
        const cur_tag = cur.tag();
        if (cur_tag == .nil) break;
        if (cur_tag == .cons) {
            b_items.append(alloc, cur.asCons().first) catch return false;
            cur = cur.asCons().rest;
        } else if (cur_tag == .chunked_cons) {
            const cc = cur.asChunkedCons();
            var j: usize = 0;
            while (j < cc.chunk.count()) : (j += 1) {
                b_items.append(alloc, cc.chunk.nth(j) orelse Value.nil_val) catch return false;
            }
            cur = cc.more;
        } else if (isSequential(cur_tag)) {
            for (sequentialItems(cur)) |item| {
                b_items.append(alloc, item) catch return false;
            }
            break;
        } else if (cur_tag == .lazy_seq) {
            cur = cur.asLazySeq().realize(alloc) catch return false;
        } else {
            return false;
        }
    }
    return eqlWalkVsItems(a, b_items.items, allocator);
}

/// Walk a cons/chunked_cons sequence and compare element-by-element against items.
fn eqlWalkVsItems(seq: Value, items: []const Value, allocator: ?Allocator) bool {
    var i: usize = 0;
    var cur = seq;
    while (true) {
        const cur_tag = cur.tag();
        if (cur_tag == .cons) {
            if (i >= items.len) return false;
            if (!cur.asCons().first.eqlImpl(items[i], allocator)) return false;
            cur = cur.asCons().rest;
            i += 1;
        } else if (cur_tag == .chunked_cons) {
            const cc = cur.asChunkedCons();
            var j: usize = 0;
            while (j < cc.chunk.count()) : (j += 1) {
                if (i >= items.len) return false;
                const elem = cc.chunk.nth(j) orelse Value.nil_val;
                if (!elem.eqlImpl(items[i], allocator)) return false;
                i += 1;
            }
            cur = cc.more;
        } else if (cur_tag == .nil) {
            return i == items.len;
        } else if (isSequential(cur_tag)) {
            const rest_items = sequentialItems(cur);
            if (i + rest_items.len != items.len) return false;
            for (rest_items, 0..) |ri, j| {
                if (!ri.eqlImpl(items[i + j], allocator)) return false;
            }
            return true;
        } else if (cur_tag == .lazy_seq) {
            if (allocator) |alloc| {
                cur = cur.asLazySeq().realize(alloc) catch return false;
            } else if (cur.asLazySeq().realized) |r| {
                cur = r;
            } else {
                return false;
            }
        } else {
            return false;
        }
    }
}

/// Cross-type map equality: handles ArrayMap vs HashMap comparisons.
fn eqlMaps(self: Value, self_tag: Value.Tag, other: Value, other_tag: Value.Tag, allocator: ?Allocator) bool {
    // Get count from both sides
    const self_count: usize = if (self_tag == .map) self.asMap().count() else self.asHashMap().getCount();
    const other_count: usize = if (other_tag == .map) other.asMap().count() else other.asHashMap().getCount();
    if (self_count != other_count) return false;

    // Iterate self's entries and look up in other
    if (self_tag == .map) {
        const a = self.asMap();
        var i: usize = 0;
        while (i < a.entries.len) : (i += 2) {
            const key = a.entries[i];
            const val = a.entries[i + 1];
            const bval = if (other_tag == .map) other.asMap().get(key) else other.asHashMap().get(key);
            if (bval) |bv| {
                if (!val.eqlImpl(bv, allocator)) return false;
            } else {
                return false;
            }
        }
        return true;
    } else {
        // self is hash_map — collect entries and iterate
        const alloc = allocator orelse return false;
        const entries = self.asHashMap().toEntries(alloc) catch return false;
        var i: usize = 0;
        while (i < entries.len) : (i += 2) {
            const key = entries[i];
            const val = entries[i + 1];
            const bval = if (other_tag == .map) other.asMap().get(key) else other.asHashMap().get(key);
            if (bval) |bv| {
                if (!val.eqlImpl(bv, allocator)) return false;
            } else {
                return false;
            }
        }
        return true;
    }
}

fn eqlOptionalStr(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |av| {
        if (b) |bv| return std.mem.eql(u8, av, bv);
        return false;
    }
    return b == null;
}

// === Tests ===

test "Value - nil creation" {
    const v = Value.nil_val;
    try testing.expect(v.isNil());
}

test "Value - bool creation" {
    const t = Value.true_val;
    const f = Value.false_val;
    try testing.expect(!t.isNil());
    try testing.expect(!f.isNil());
}

test "Value - integer creation" {
    const v = Value.initInteger(42);
    try testing.expect(!v.isNil());
}

test "Value - float creation" {
    const v = Value.initFloat(3.14);
    try testing.expect(!v.isNil());
}

test "Value - string creation" {
    const v = Value.initString(testing.allocator,"hello");
    try testing.expect(!v.isNil());
}

test "Value - symbol creation" {
    const v = Value.initSymbol(testing.allocator,.{ .name = "foo", .ns = null });
    try testing.expect(!v.isNil());
}

test "Value - keyword creation" {
    const v = Value.initKeyword(testing.allocator,.{ .name = "bar", .ns = null });
    try testing.expect(!v.isNil());
}

test "Value - char creation" {
    const v = Value.initChar('A');
    try testing.expect(!v.isNil());
    try testing.expect(v.isTruthy());
}

test "Value - namespaced symbol" {
    const v = Value.initSymbol(testing.allocator,.{ .name = "inc", .ns = "clojure.core" });
    try testing.expect(!v.isNil());
}

test "Value - namespaced keyword" {
    const v = Value.initKeyword(testing.allocator,.{ .name = "keys", .ns = "clojure.core" });
    try testing.expect(!v.isNil());
}

fn expectFormat(expected: []const u8, v: Value) !void {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try v.formatPrStr(&w);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "Value.formatPrStr - nil" {
    try expectFormat("nil", Value.nil_val);
}

test "Value.formatPrStr - boolean" {
    try expectFormat("true", Value.true_val);
    try expectFormat("false", Value.false_val);
}

test "Value.formatPrStr - integer" {
    try expectFormat("42", Value.initInteger(42));
    try expectFormat("-1", Value.initInteger(-1));
    try expectFormat("0", Value.initInteger(0));
}

test "Value.formatPrStr - float" {
    try expectFormat("3.14", Value.initFloat(3.14));
    try expectFormat("0.0", Value.initFloat(0.0));
    try expectFormat("-1.5", Value.initFloat(-1.5));
    try expectFormat("1.0", Value.initFloat(1.0));
}

test "Value.formatPrStr - char" {
    try expectFormat("\\A", Value.initChar('A'));
    try expectFormat("\\newline", Value.initChar('\n'));
    try expectFormat("\\space", Value.initChar(' '));
    try expectFormat("\\tab", Value.initChar('\t'));
}

test "Value.formatPrStr - string" {
    try expectFormat("\"hello\"", Value.initString(testing.allocator,"hello"));
    try expectFormat("\"\"", Value.initString(testing.allocator,""));
}

test "Value.formatPrStr - symbol" {
    try expectFormat("foo", Value.initSymbol(testing.allocator,.{ .name = "foo", .ns = null }));
    try expectFormat("clojure.core/inc", Value.initSymbol(testing.allocator,.{ .name = "inc", .ns = "clojure.core" }));
}

test "Value.formatPrStr - keyword" {
    try expectFormat(":bar", Value.initKeyword(testing.allocator,.{ .name = "bar", .ns = null }));
    try expectFormat(":clojure.core/keys", Value.initKeyword(testing.allocator,.{ .name = "keys", .ns = "clojure.core" }));
}

test "Value.formatPrStr - list" {
    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2), Value.initInteger(3) };
    const list = PersistentList{ .items = &items };
    try expectFormat("(1 2 3)", Value.initList(&list));
}

test "Value.formatPrStr - empty list" {
    const list = PersistentList{ .items = &.{} };
    try expectFormat("()", Value.initList(&list));
}

test "Value.formatPrStr - vector" {
    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    const vec = PersistentVector{ .items = &items };
    try expectFormat("[1 2]", Value.initVector(&vec));
}

test "Value.formatPrStr - empty vector" {
    const vec = PersistentVector{ .items = &.{} };
    try expectFormat("[]", Value.initVector(&vec));
}

test "Value.formatPrStr - map" {
    const entries = [_]Value{
        Value.initKeyword(testing.allocator,.{ .name = "a", .ns = null }), Value.initInteger(1),
        Value.initKeyword(testing.allocator,.{ .name = "b", .ns = null }), Value.initInteger(2),
    };
    const m = PersistentArrayMap{ .entries = &entries };
    try expectFormat("{:a 1, :b 2}", Value.initMap(&m));
}

test "Value.formatPrStr - empty map" {
    const m = PersistentArrayMap{ .entries = &.{} };
    try expectFormat("{}", Value.initMap(&m));
}

test "Value.formatPrStr - set" {
    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    const s = PersistentHashSet{ .items = &items };
    try expectFormat("#{1 2}", Value.initSet(&s));
}

test "Value.formatPrStr - empty set" {
    const s = PersistentHashSet{ .items = &.{} };
    try expectFormat("#{}", Value.initSet(&s));
}

test "Value.eql - nil" {
    try testing.expect(Value.nil_val.eql(Value.nil_val));
}

test "Value.eql - boolean" {
    const t = Value.true_val;
    const f = Value.false_val;
    try testing.expect(t.eql(Value.true_val));
    try testing.expect(f.eql(Value.false_val));
    try testing.expect(!t.eql(f));
}

test "Value.eql - integer" {
    const a = Value.initInteger(42);
    try testing.expect(a.eql(Value.initInteger(42)));
    try testing.expect(!a.eql(Value.initInteger(43)));
}

test "Value.eql - float" {
    const a = Value.initFloat(3.14);
    try testing.expect(a.eql(Value.initFloat(3.14)));
    try testing.expect(!a.eql(Value.initFloat(2.71)));
}

test "Value.eql - cross-type numeric" {
    // Clojure: (= 1 1.0) => true
    const i = Value.initInteger(1);
    const f = Value.initFloat(1.0);
    try testing.expect(i.eql(f));
    try testing.expect(f.eql(i));
    // (= 1 1.5) => false
    try testing.expect(!i.eql(Value.initFloat(1.5)));
}

test "Value.eql - char" {
    const a = Value.initChar('A');
    try testing.expect(a.eql(Value.initChar('A')));
    try testing.expect(!a.eql(Value.initChar('B')));
}

test "Value.eql - string" {
    const a = Value.initString(testing.allocator,"hello");
    try testing.expect(a.eql(Value.initString(testing.allocator,"hello")));
    try testing.expect(!a.eql(Value.initString(testing.allocator,"world")));
}

test "Value.eql - symbol" {
    const a = Value.initSymbol(testing.allocator,.{ .name = "foo", .ns = null });
    try testing.expect(a.eql(Value.initSymbol(testing.allocator,.{ .name = "foo", .ns = null })));
    try testing.expect(!a.eql(Value.initSymbol(testing.allocator,.{ .name = "bar", .ns = null })));
    // Namespaced vs non-namespaced
    try testing.expect(!a.eql(Value.initSymbol(testing.allocator,.{ .name = "foo", .ns = "x" })));
}

test "Value.eql - keyword" {
    const a = Value.initKeyword(testing.allocator,.{ .name = "k", .ns = "ns" });
    try testing.expect(a.eql(Value.initKeyword(testing.allocator,.{ .name = "k", .ns = "ns" })));
    try testing.expect(!a.eql(Value.initKeyword(testing.allocator,.{ .name = "k", .ns = null })));
    try testing.expect(!a.eql(Value.initKeyword(testing.allocator,.{ .name = "other", .ns = "ns" })));
}

test "Value.eql - list" {
    const items_a = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    const items_b = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    const items_c = [_]Value{ Value.initInteger(1), Value.initInteger(3) };
    const la = PersistentList{ .items = &items_a };
    const lb = PersistentList{ .items = &items_b };
    const lc = PersistentList{ .items = &items_c };
    try testing.expect(Value.initList(&la).eql(Value.initList(&lb)));
    try testing.expect(!Value.initList(&la).eql(Value.initList(&lc)));
}

test "Value.eql - list/vector sequential equality" {
    // Clojure: (= '(1 2) [1 2]) => true
    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    const lst = PersistentList{ .items = &items };
    const vec = PersistentVector{ .items = &items };
    try testing.expect(Value.initList(&lst).eql(Value.initVector(&vec)));
    try testing.expect(Value.initVector(&vec).eql(Value.initList(&lst)));
}

test "Value.eql - vector" {
    const items_a = [_]Value{Value.initInteger(1)};
    const items_b = [_]Value{Value.initInteger(1)};
    const empty = [_]Value{};
    const va = PersistentVector{ .items = &items_a };
    const vb = PersistentVector{ .items = &items_b };
    const ve = PersistentVector{ .items = &empty };
    try testing.expect(Value.initVector(&va).eql(Value.initVector(&vb)));
    try testing.expect(!Value.initVector(&va).eql(Value.initVector(&ve)));
}

test "Value.eql - map" {
    const entries_a = [_]Value{ Value.initKeyword(testing.allocator,.{ .name = "a", .ns = null }), Value.initInteger(1) };
    const entries_b = [_]Value{ Value.initKeyword(testing.allocator,.{ .name = "a", .ns = null }), Value.initInteger(1) };
    const entries_c = [_]Value{ Value.initKeyword(testing.allocator,.{ .name = "a", .ns = null }), Value.initInteger(2) };
    const ma = PersistentArrayMap{ .entries = &entries_a };
    const mb = PersistentArrayMap{ .entries = &entries_b };
    const mc = PersistentArrayMap{ .entries = &entries_c };
    try testing.expect(Value.initMap(&ma).eql(Value.initMap(&mb)));
    try testing.expect(!Value.initMap(&ma).eql(Value.initMap(&mc)));
}

test "Value.eql - set" {
    const items_a = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    const items_b = [_]Value{ Value.initInteger(2), Value.initInteger(1) };
    const items_c = [_]Value{ Value.initInteger(1), Value.initInteger(3) };
    const sa = PersistentHashSet{ .items = &items_a };
    const sb = PersistentHashSet{ .items = &items_b };
    const sc = PersistentHashSet{ .items = &items_c };
    try testing.expect(Value.initSet(&sa).eql(Value.initSet(&sb)));
    try testing.expect(!Value.initSet(&sa).eql(Value.initSet(&sc)));
}

test "Value.eql - different types" {
    // Different types are never equal (except int/float)
    const nil_v = Value.nil_val;
    const int_v = Value.initInteger(0);
    const bool_v = Value.false_val;
    const str_v = Value.initString(testing.allocator,"nil");
    try testing.expect(!nil_v.eql(int_v));
    try testing.expect(!nil_v.eql(bool_v));
    try testing.expect(!nil_v.eql(str_v));
    try testing.expect(!int_v.eql(bool_v));
}

test "Value - fn_val creation" {
    const fn_obj = Fn{ .proto = undefined, .closure_bindings = null };
    const v = Value.initFn(&fn_obj);
    try testing.expect(!v.isNil());
    try testing.expect(v.isTruthy());
}

test "Value.formatPrStr - fn_val" {
    const fn_obj = Fn{ .proto = undefined, .closure_bindings = null };
    try expectFormat("#<fn>", Value.initFn(&fn_obj));
}

test "Value.eql - fn_val identity" {
    const fn_obj = Fn{ .proto = undefined, .closure_bindings = null };
    const v = Value.initFn(&fn_obj);
    // fn values use identity equality (same pointer)
    try testing.expect(v.eql(v));
    // Different fn_val is not equal (distinct allocation)
    var fn_obj2 = Fn{ .proto = undefined, .closure_bindings = null };
    try testing.expect(!v.eql(Value.initFn(&fn_obj2)));
}

test "Value - isTruthy" {
    const nil_v = Value.nil_val;
    const false_v = Value.false_val;
    const true_v = Value.true_val;
    const zero_v = Value.initInteger(0);
    const empty_str = Value.initString(testing.allocator,"");
    try testing.expect(!nil_v.isTruthy());
    try testing.expect(!false_v.isTruthy());
    try testing.expect(true_v.isTruthy());
    try testing.expect(zero_v.isTruthy());
    try testing.expect(empty_str.isTruthy());
}

fn expectFormatStr(expected: []const u8, v: Value) !void {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try v.formatStr(&w);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "Value.formatStr - nil is empty string" {
    try expectFormatStr("", Value.nil_val);
}

test "Value.formatStr - string without quotes" {
    try expectFormatStr("hello", Value.initString(testing.allocator,"hello"));
}

test "Value.formatStr - char as literal" {
    try expectFormatStr("A", Value.initChar('A'));
    try expectFormatStr("\n", Value.initChar('\n'));
}

test "Value.formatStr - other types same as formatPrStr" {
    try expectFormatStr("42", Value.initInteger(42));
    try expectFormatStr("true", Value.true_val);
    try expectFormatStr("3.14", Value.initFloat(3.14));
    try expectFormatStr(":foo", Value.initKeyword(testing.allocator,.{ .name = "foo", .ns = null }));
}

test "Value - atom creation and formatPrStr" {
    var a = Atom{ .value = Value.initInteger(42) };
    const v = Value.initAtom(&a);
    try testing.expect(!v.isNil());
    try testing.expect(v.isTruthy());
    try expectFormat("#<atom 42>", v);
}

test "Value.eql - atom identity" {
    var a = Atom{ .value = Value.initInteger(42) };
    const v = Value.initAtom(&a);
    try testing.expect(v.eql(v));
    var b = Atom{ .value = Value.initInteger(42) };
    try testing.expect(!v.eql(Value.initAtom(&b)));
}

test "Value.formatPrStr - var_ref" {
    var the_var = Var{
        .sym = .{ .ns = null, .name = "foo" },
        .ns_name = "user",
    };
    try expectFormat("#'user/foo", Value.initVarRef(&the_var));
}

test "Value.eql - var_ref identity" {
    var the_var = Var{
        .sym = .{ .ns = null, .name = "foo" },
        .ns_name = "user",
    };
    const v = Value.initVarRef(&the_var);
    try testing.expect(v.eql(v));
    var other_var = Var{
        .sym = .{ .ns = null, .name = "foo" },
        .ns_name = "user",
    };
    try testing.expect(!v.eql(Value.initVarRef(&other_var)));
}

// === Value Accessor API Tests (Phase 27) ===

test "Value.Tag - tag() returns correct tag" {
    try testing.expect((Value.nil_val).tag() == .nil);
    try testing.expect(Value.initInteger(42).tag() == .integer);
    try testing.expect(Value.initFloat(3.14).tag() == .float);
    try testing.expect(Value.initBoolean(true).tag() == .boolean);
    try testing.expect(Value.initChar('A').tag() == .char);
    try testing.expect(Value.initString(testing.allocator,"hi").tag() == .string);
    try testing.expect(Value.initSymbol(testing.allocator,.{ .name = "x", .ns = null }).tag() == .symbol);
    try testing.expect(Value.initKeyword(testing.allocator,.{ .name = "k", .ns = null }).tag() == .keyword);
}

test "Value constants" {
    try testing.expect(Value.nil_val.isNil());
    try testing.expect(!Value.nil_val.isTruthy());
    try testing.expect(Value.true_val.isTruthy());
    try testing.expect(!Value.false_val.isTruthy());
    try testing.expect(Value.true_val.asBoolean() == true);
    try testing.expect(Value.false_val.asBoolean() == false);
}

test "Value.initInteger / asInteger round-trip" {
    const v = Value.initInteger(-99);
    try testing.expect(v.tag() == .integer);
    try testing.expect(v.asInteger() == -99);
}

test "Value.initFloat / asFloat round-trip" {
    const v = Value.initFloat(2.718);
    try testing.expect(v.tag() == .float);
    try testing.expect(v.asFloat() == 2.718);
}

test "Value.initChar / asChar round-trip" {
    const v = Value.initChar(0x1F600); // emoji codepoint
    try testing.expect(v.tag() == .char);
    try testing.expect(v.asChar() == 0x1F600);
}

test "Value.initString / asString round-trip" {
    const v = Value.initString(testing.allocator,"hello");
    try testing.expect(v.tag() == .string);
    try testing.expectEqualStrings("hello", v.asString());
}

test "Value.initSymbol / asSymbol round-trip" {
    const sym = Symbol{ .name = "foo", .ns = "bar" };
    const v = Value.initSymbol(testing.allocator,sym);
    try testing.expect(v.tag() == .symbol);
    const s = v.asSymbol();
    try testing.expectEqualStrings("foo", s.name);
    try testing.expectEqualStrings("bar", s.ns.?);
}

test "Value.initKeyword / asKeyword round-trip" {
    const kw = Keyword{ .name = "id", .ns = "user" };
    const v = Value.initKeyword(testing.allocator,kw);
    try testing.expect(v.tag() == .keyword);
    const k = v.asKeyword();
    try testing.expectEqualStrings("id", k.name);
    try testing.expectEqualStrings("user", k.ns.?);
}

test "Value.initList / asList round-trip" {
    const items = [_]Value{ Value.initInteger(1), Value.initInteger(2) };
    const list = PersistentList{ .items = &items };
    const v = Value.initList(&list);
    try testing.expect(v.tag() == .list);
    try testing.expect(v.asList().items.len == 2);
}

test "Value.initVector / asVector round-trip" {
    const items = [_]Value{Value.initInteger(10)};
    const vec = PersistentVector{ .items = &items };
    const v = Value.initVector(&vec);
    try testing.expect(v.tag() == .vector);
    try testing.expect(v.asVector().items.len == 1);
}

test "Value.initFn / asFn round-trip" {
    const fn_obj = Fn{ .proto = undefined, .closure_bindings = null };
    const v = Value.initFn(&fn_obj);
    try testing.expect(v.tag() == .fn_val);
    try testing.expect(v.asFn() == &fn_obj);
}

test "Value.initAtom / asAtom round-trip" {
    var a = Atom{ .value = Value.initInteger(42) };
    const v = Value.initAtom(&a);
    try testing.expect(v.tag() == .atom);
    try testing.expect(v.asAtom() == &a);
}

test "Value.initVarRef / asVarRef round-trip" {
    var the_var = Var{
        .sym = .{ .ns = null, .name = "x" },
        .ns_name = "user",
    };
    const v = Value.initVarRef(&the_var);
    try testing.expect(v.tag() == .var_ref);
    try testing.expect(v.asVarRef() == &the_var);
}

test "Value tag switch pattern" {
    const v = Value.initInteger(42);
    const result: i64 = switch (v.tag()) {
        .integer => v.asInteger() * 2,
        else => 0,
    };
    try testing.expect(result == 84);
}
