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
        switch (rest) {
            .cons => |rc| {
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
            .list => |lst| {
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
            .lazy_seq => |ls| {
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
            .chunked_cons => |cc| {
                var i: usize = 0;
                while (i < cc.chunk.count()) : (i += 1) {
                    if (length) |len| {
                        if (count.* >= @as(usize, @intCast(len))) {
                            try w.writeAll(" ...");
                            return;
                        }
                    }
                    try w.writeAll(" ");
                    const elem = cc.chunk.nth(i) orelse Value.nil;
                    try elem.formatPrStr(w);
                    count.* += 1;
                }
                if (cc.more == .nil) return;
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
    return if (v == .integer) v.integer else null;
}

fn getPrintLevel() ?u32 {
    const v = (print_level_var orelse return null).deref();
    if (v == .integer and v.integer >= 0) return @intCast(v.integer);
    return null;
}

/// Builtin function signature: allocator + args -> Value.
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

/// Protocol method reference — dispatches on first arg type.
pub const ProtocolFn = struct {
    protocol: *Protocol,
    method_name: []const u8,
    // Monomorphic inline cache (24A.5): caches last (type -> method) dispatch
    cached_type_key: ?[]const u8 = null,
    cached_method: Value = .nil,
};

/// MultiFn — multimethod with dispatch function.
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
};

/// Cons cell — a pair of (first, rest) forming a linked sequence.
/// rest can be list, vector, lazy_seq, cons, or nil.
pub const Cons = struct {
    first: Value,
    rest: Value,
};

/// Lazy sequence — thunk-based deferred evaluation with caching.
/// The thunk is a zero-arg function that returns a seq (list/nil/cons).
/// Once realized, the result is cached and the thunk is discarded.
/// Optional `meta` field carries structural metadata for fused reduce (24A.3).
pub const LazySeq = struct {
    thunk: ?Value, // fn of 0 args, null after realization
    realized: ?Value, // cached result, null before realization
    meta: ?*const Meta = null, // structural metadata for fused reduce

    /// Structural metadata for lazy-seq chain fusion.
    /// When present, realize() uses this instead of thunk evaluation,
    /// and fused reduce can walk the chain without intermediate allocations.
    pub const Meta = union(enum) {
        lazy_map: struct { f: Value, source: Value },
        lazy_filter: struct { pred: Value, source: Value },
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

        const thunk = self.thunk orelse return .nil;
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
                if (seq_val == .nil) return .nil;
                const first_elem = try coll_builtins.firstFn(allocator, &[1]Value{seq_val});
                const mapped = try bootstrap.callFnVal(allocator, lm.f, &[1]Value{first_elem});
                const rest_source = try coll_builtins.restFn(allocator, &[1]Value{seq_val});
                const rest_meta = try allocator.create(Meta);
                rest_meta.* = .{ .lazy_map = .{ .f = lm.f, .source = rest_source } };
                const rest_ls = try allocator.create(LazySeq);
                rest_ls.* = .{ .thunk = null, .realized = null, .meta = rest_meta };
                const cons_cell = try allocator.create(Cons);
                cons_cell.* = .{ .first = mapped, .rest = .{ .lazy_seq = rest_ls } };
                return Value{ .cons = cons_cell };
            },
            .lazy_filter => |lf| {
                var current = lf.source;
                while (true) {
                    const seq_val = try coll_builtins.seqFn(allocator, &[1]Value{current});
                    if (seq_val == .nil) return .nil;
                    const elem = try coll_builtins.firstFn(allocator, &[1]Value{seq_val});
                    const pred_result = try bootstrap.callFnVal(allocator, lf.pred, &[1]Value{elem});
                    if (pred_result.isTruthy()) {
                        const rest_source = try coll_builtins.restFn(allocator, &[1]Value{seq_val});
                        const rest_meta = try allocator.create(Meta);
                        rest_meta.* = .{ .lazy_filter = .{ .pred = lf.pred, .source = rest_source } };
                        const rest_ls = try allocator.create(LazySeq);
                        rest_ls.* = .{ .thunk = null, .realized = null, .meta = rest_meta };
                        const cons_cell = try allocator.create(Cons);
                        cons_cell.* = .{ .first = elem, .rest = .{ .lazy_seq = rest_ls } };
                        return Value{ .cons = cons_cell };
                    }
                    current = try coll_builtins.restFn(allocator, &[1]Value{seq_val});
                }
            },
            .lazy_take => |lt| {
                if (lt.n == 0) return .nil;
                const seq_val = try coll_builtins.seqFn(allocator, &[1]Value{lt.source});
                if (seq_val == .nil) return .nil;
                const first_elem = try coll_builtins.firstFn(allocator, &[1]Value{seq_val});
                const rest_source = try coll_builtins.restFn(allocator, &[1]Value{seq_val});
                const rest_meta = try allocator.create(Meta);
                rest_meta.* = .{ .lazy_take = .{ .n = lt.n - 1, .source = rest_source } };
                const rest_ls = try allocator.create(LazySeq);
                rest_ls.* = .{ .thunk = null, .realized = null, .meta = rest_meta };
                const cons_cell = try allocator.create(Cons);
                cons_cell.* = .{ .first = first_elem, .rest = .{ .lazy_seq = rest_ls } };
                return Value{ .cons = cons_cell };
            },
            .range => |r| {
                if ((r.step > 0 and r.current >= r.end) or
                    (r.step < 0 and r.current <= r.end) or
                    (r.step == 0)) return .nil;
                const rest_meta = try allocator.create(Meta);
                rest_meta.* = .{ .range = .{ .current = r.current + r.step, .end = r.end, .step = r.step } };
                const rest_ls = try allocator.create(LazySeq);
                rest_ls.* = .{ .thunk = null, .realized = null, .meta = rest_meta };
                const cons_cell = try allocator.create(Cons);
                cons_cell.* = .{ .first = .{ .integer = r.current }, .rest = .{ .lazy_seq = rest_ls } };
                return Value{ .cons = cons_cell };
            },
            .iterate => |it| {
                const next_val = try bootstrap.callFnVal(allocator, it.f, &[1]Value{it.current});
                const rest_meta = try allocator.create(Meta);
                rest_meta.* = .{ .iterate = .{ .f = it.f, .current = next_val } };
                const rest_ls = try allocator.create(LazySeq);
                rest_ls.* = .{ .thunk = null, .realized = null, .meta = rest_meta };
                const cons_cell = try allocator.create(Cons);
                cons_cell.* = .{ .first = it.current, .rest = .{ .lazy_seq = rest_ls } };
                return Value{ .cons = cons_cell };
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

    /// Clojure pr-str semantics: format value for printing.
    pub fn formatPrStr(self: Value, w: *Writer) Writer.Error!void {
        switch (self) {
            .nil => {
                if (print_readably) try w.writeAll("nil");
                // Non-readable: nil => "" (empty), matching Clojure str/print semantics
            },
            .boolean => |b| try w.writeAll(if (b) "true" else "false"),
            .integer => |n| try w.print("{d}", .{n}),
            .float => |n| {
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
            .char => |c| {
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
            .string => |s| {
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
            .symbol => |sym| {
                if (sym.ns) |ns| {
                    try w.print("{s}/{s}", .{ ns, sym.name });
                } else {
                    try w.writeAll(sym.name);
                }
            },
            .keyword => |k| {
                if (k.ns) |ns| {
                    try w.print(":{s}/{s}", .{ ns, k.name });
                } else {
                    try w.print(":{s}", .{k.name});
                }
            },
            .list => |lst| {
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
            .vector => |vec| {
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
            .map => |m| {
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
            .hash_map => |hm| {
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
            .set => |s| {
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
            .atom => |a| {
                try w.writeAll("#<atom ");
                try a.value.formatPrStr(w);
                try w.writeAll(">");
            },
            .volatile_ref => |v| {
                try w.writeAll("#<volatile ");
                try v.value.formatPrStr(w);
                try w.writeAll(">");
            },
            .regex => |p| {
                try w.writeAll("#\"");
                try w.writeAll(p.source);
                try w.writeAll("\"");
            },
            .protocol => |p| {
                try w.writeAll("#<protocol ");
                try w.writeAll(p.name);
                try w.writeAll(">");
            },
            .protocol_fn => |pf| {
                try w.writeAll("#<protocol-fn ");
                try w.writeAll(pf.protocol.name);
                try w.writeAll("/");
                try w.writeAll(pf.method_name);
                try w.writeAll(">");
            },
            .multi_fn => |mf| {
                try w.writeAll("#<multifn ");
                try w.writeAll(mf.name);
                try w.writeAll(">");
            },
            .lazy_seq => |ls| {
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
            .var_ref => |v| {
                try w.writeAll("#'");
                try w.writeAll(v.ns_name);
                try w.writeAll("/");
                try w.writeAll(v.sym.name);
            },
            .delay => |d| {
                if (d.realized) {
                    try w.writeAll("#delay[");
                    if (d.cached) |v| try v.formatPrStr(w) else try w.writeAll("nil");
                    try w.writeAll("]");
                } else {
                    try w.writeAll("#delay[pending]");
                }
            },
            .reduced => |r| try r.value.formatPrStr(w),
            .transient_vector => try w.writeAll("#<TransientVector>"),
            .transient_map => try w.writeAll("#<TransientMap>"),
            .transient_set => try w.writeAll("#<TransientSet>"),
            .chunked_cons => |cc| {
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
                    const elem = cc.chunk.nth(i) orelse Value.nil;
                    try elem.formatPrStr(w);
                    count += 1;
                }
                if (!truncated and cc.more != .nil) {
                    // Print elements from rest chunks
                    try printSeqRest(w, cc.more, length, &count);
                }
                print_depth -= 1;
                try w.writeAll(")");
            },
            .chunk_buffer => try w.writeAll("#<ChunkBuffer>"),
            .array_chunk => try w.writeAll("#<ArrayChunk>"),
            .cons => |c| {
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
        switch (self) {
            .nil => {}, // nil => "" (empty)
            .char => |c| {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c, &buf) catch 0;
                try w.writeAll(buf[0..len]);
            },
            .string => |s| try w.writeAll(s),
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
        const self_tag = std.meta.activeTag(self);
        const other_tag = std.meta.activeTag(other);

        // Cross-type numeric equality: (= 1 1.0) => true
        if ((self_tag == .integer and other_tag == .float) or
            (self_tag == .float and other_tag == .integer))
        {
            const a: f64 = if (self_tag == .integer) @floatFromInt(self.integer) else self.float;
            const b: f64 = if (other_tag == .integer) @floatFromInt(other.integer) else other.float;
            return a == b;
        }

        // Lazy seqs: realize and compare using JVM LazySeq.equiv() semantics.
        // A realized-nil lazy-seq is an empty sequence (equals () or [], but NOT nil).
        if (self_tag == .lazy_seq) {
            return eqlLazySide(self.lazy_seq, other, other_tag, allocator);
        }
        if (other_tag == .lazy_seq) {
            return eqlLazySide(other.lazy_seq, self, self_tag, allocator);
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

        return switch (self) {
            .nil => true,
            .boolean => |a| a == other.boolean,
            .integer => |a| a == other.integer,
            .float => |a| a == other.float,
            .char => |a| a == other.char,
            .string => |a| std.mem.eql(u8, a, other.string),
            .symbol => |a| eqlOptionalStr(a.ns, other.symbol.ns) and std.mem.eql(u8, a.name, other.symbol.name),
            .keyword => |a| eqlOptionalStr(a.ns, other.keyword.ns) and std.mem.eql(u8, a.name, other.keyword.name),
            .list, .vector => unreachable, // handled by sequential equality above
            .fn_val => |a| a == other.fn_val,
            .builtin_fn => |a| a == other.builtin_fn,
            .atom => |a| a == other.atom, // identity equality
            .volatile_ref => |a| a == other.volatile_ref, // identity equality
            .regex => |a| std.mem.eql(u8, a.source, other.regex.source), // pattern string equality
            .protocol => |a| a == other.protocol, // identity equality
            .protocol_fn => |a| a == other.protocol_fn, // identity equality
            .multi_fn => |a| a == other.multi_fn, // identity equality
            .lazy_seq => unreachable, // handled by early return above
            .var_ref => |a| a == other.var_ref, // identity equality
            .cons => unreachable, // handled by eqlConsSeq above
            .delay => |a| a == other.delay, // identity equality
            .reduced => |a| a.value.eqlImpl(other.reduced.value, allocator),
            .map, .hash_map => unreachable, // handled by eqlMaps above
            .set => |a| {
                const b = other.set;
                if (a.count() != b.count()) return false;
                for (a.items) |item| {
                    if (!b.contains(item)) return false;
                }
                return true;
            },
            .transient_vector => |a| a == other.transient_vector, // identity equality
            .transient_map => |a| a == other.transient_map, // identity equality
            .transient_set => |a| a == other.transient_set, // identity equality
            .chunked_cons => unreachable, // handled by eqlConsSeq above
            .chunk_buffer => |a| a == other.chunk_buffer, // identity equality
            .array_chunk => |a| a == other.array_chunk, // identity equality
        };
    }

    /// Returns true if this value is nil.
    pub fn isNil(self: Value) bool {
        return switch (self) {
            .nil => true,
            else => false,
        };
    }

    /// Clojure truthiness: everything is truthy except nil and false.
    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .nil => false,
            .boolean => |b| b,
            else => true,
        };
    }
};

const Tag = std.meta.Tag(Value);

fn isSequential(tag: Tag) bool {
    return tag == .list or tag == .vector;
}

fn sequentialItems(v: Value) []const Value {
    return switch (v) {
        .list => |lst| lst.items,
        .vector => |vec| vec.items,
        else => unreachable,
    };
}

/// Lazy-seq equality following JVM LazySeq.equiv() semantics:
/// - Realize the lazy-seq
/// - If nil: it's an empty sequence — equal to other empty sequentials, NOT to nil
/// - If non-nil: delegate to the realized value's equality
fn eqlLazySide(lazy: *LazySeq, other: Value, other_tag: Tag, allocator: ?Allocator) bool {
    const realized = blk: {
        if (allocator) |alloc| {
            break :blk lazy.realize(alloc) catch return false;
        }
        break :blk lazy.realized orelse return false;
    };
    if (realized == .nil) {
        // Empty lazy-seq: equal only to empty sequential types
        if (other_tag == .nil) return false; // (= nil (lazy-seq nil)) => false
        if (isSequential(other_tag)) {
            return sequentialItems(other).len == 0;
        }
        if (other_tag == .cons) return false; // cons is never empty
        if (other_tag == .lazy_seq) {
            // Compare two lazy-seqs: both must realize to empty
            if (allocator) |alloc| {
                const other_realized = other.lazy_seq.realize(alloc) catch return false;
                return other_realized == .nil;
            }
            if (other.lazy_seq.realized) |r| return r == .nil;
            return false;
        }
        return false;
    }
    return realized.eqlImpl(other, allocator);
}

/// Compare a cons/chunked_cons with another sequential value element-by-element.
/// Handles cons vs cons, cons vs list/vector, chunked_cons vs list/vector, etc.
fn eqlConsSeq(a: Value, b: Value, allocator: ?Allocator) bool {
    const a_tag = std.meta.activeTag(a);
    const b_tag = std.meta.activeTag(b);

    // Fast path: both cons
    if (a_tag == .cons and b_tag == .cons) {
        if (!a.cons.first.eqlImpl(b.cons.first, allocator)) return false;
        return a.cons.rest.eqlImpl(b.cons.rest, allocator);
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
        const cur_tag = std.meta.activeTag(cur);
        if (cur_tag == .nil) break;
        if (cur_tag == .cons) {
            b_items.append(alloc, cur.cons.first) catch return false;
            cur = cur.cons.rest;
        } else if (cur_tag == .chunked_cons) {
            const cc = cur.chunked_cons;
            var j: usize = 0;
            while (j < cc.chunk.count()) : (j += 1) {
                b_items.append(alloc, cc.chunk.nth(j) orelse Value.nil) catch return false;
            }
            cur = cc.more;
        } else if (isSequential(cur_tag)) {
            for (sequentialItems(cur)) |item| {
                b_items.append(alloc, item) catch return false;
            }
            break;
        } else if (cur_tag == .lazy_seq) {
            cur = cur.lazy_seq.realize(alloc) catch return false;
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
        const cur_tag = std.meta.activeTag(cur);
        if (cur_tag == .cons) {
            if (i >= items.len) return false;
            if (!cur.cons.first.eqlImpl(items[i], allocator)) return false;
            cur = cur.cons.rest;
            i += 1;
        } else if (cur_tag == .chunked_cons) {
            const cc = cur.chunked_cons;
            var j: usize = 0;
            while (j < cc.chunk.count()) : (j += 1) {
                if (i >= items.len) return false;
                const elem = cc.chunk.nth(j) orelse Value.nil;
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
                cur = cur.lazy_seq.realize(alloc) catch return false;
            } else if (cur.lazy_seq.realized) |r| {
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
fn eqlMaps(self: Value, self_tag: Tag, other: Value, other_tag: Tag, allocator: ?Allocator) bool {
    // Get count from both sides
    const self_count: usize = if (self_tag == .map) self.map.count() else self.hash_map.getCount();
    const other_count: usize = if (other_tag == .map) other.map.count() else other.hash_map.getCount();
    if (self_count != other_count) return false;

    // Iterate self's entries and look up in other
    if (self_tag == .map) {
        const a = self.map;
        var i: usize = 0;
        while (i < a.entries.len) : (i += 2) {
            const key = a.entries[i];
            const val = a.entries[i + 1];
            const bval = if (other_tag == .map) other.map.get(key) else other.hash_map.get(key);
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
        const entries = self.hash_map.toEntries(alloc) catch return false;
        var i: usize = 0;
        while (i < entries.len) : (i += 2) {
            const key = entries[i];
            const val = entries[i + 1];
            const bval = if (other_tag == .map) other.map.get(key) else other.hash_map.get(key);
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
    const v: Value = .nil;
    try testing.expect(v.isNil());
}

test "Value - bool creation" {
    const t: Value = .{ .boolean = true };
    const f: Value = .{ .boolean = false };
    try testing.expect(!t.isNil());
    try testing.expect(!f.isNil());
}

test "Value - integer creation" {
    const v: Value = .{ .integer = 42 };
    try testing.expect(!v.isNil());
}

test "Value - float creation" {
    const v: Value = .{ .float = 3.14 };
    try testing.expect(!v.isNil());
}

test "Value - string creation" {
    const v: Value = .{ .string = "hello" };
    try testing.expect(!v.isNil());
}

test "Value - symbol creation" {
    const v: Value = .{ .symbol = .{ .name = "foo", .ns = null } };
    try testing.expect(!v.isNil());
}

test "Value - keyword creation" {
    const v: Value = .{ .keyword = .{ .name = "bar", .ns = null } };
    try testing.expect(!v.isNil());
}

test "Value - char creation" {
    const v: Value = .{ .char = 'A' };
    try testing.expect(!v.isNil());
    try testing.expect(v.isTruthy());
}

test "Value - namespaced symbol" {
    const v: Value = .{ .symbol = .{ .name = "inc", .ns = "clojure.core" } };
    try testing.expect(!v.isNil());
}

test "Value - namespaced keyword" {
    const v: Value = .{ .keyword = .{ .name = "keys", .ns = "clojure.core" } };
    try testing.expect(!v.isNil());
}

fn expectFormat(expected: []const u8, v: Value) !void {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try v.formatPrStr(&w);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "Value.formatPrStr - nil" {
    try expectFormat("nil", .nil);
}

test "Value.formatPrStr - boolean" {
    try expectFormat("true", .{ .boolean = true });
    try expectFormat("false", .{ .boolean = false });
}

test "Value.formatPrStr - integer" {
    try expectFormat("42", .{ .integer = 42 });
    try expectFormat("-1", .{ .integer = -1 });
    try expectFormat("0", .{ .integer = 0 });
}

test "Value.formatPrStr - float" {
    try expectFormat("3.14", .{ .float = 3.14 });
    try expectFormat("0.0", .{ .float = 0.0 });
    try expectFormat("-1.5", .{ .float = -1.5 });
    try expectFormat("1.0", .{ .float = 1.0 });
}

test "Value.formatPrStr - char" {
    try expectFormat("\\A", .{ .char = 'A' });
    try expectFormat("\\newline", .{ .char = '\n' });
    try expectFormat("\\space", .{ .char = ' ' });
    try expectFormat("\\tab", .{ .char = '\t' });
}

test "Value.formatPrStr - string" {
    try expectFormat("\"hello\"", .{ .string = "hello" });
    try expectFormat("\"\"", .{ .string = "" });
}

test "Value.formatPrStr - symbol" {
    try expectFormat("foo", .{ .symbol = .{ .name = "foo", .ns = null } });
    try expectFormat("clojure.core/inc", .{ .symbol = .{ .name = "inc", .ns = "clojure.core" } });
}

test "Value.formatPrStr - keyword" {
    try expectFormat(":bar", .{ .keyword = .{ .name = "bar", .ns = null } });
    try expectFormat(":clojure.core/keys", .{ .keyword = .{ .name = "keys", .ns = "clojure.core" } });
}

test "Value.formatPrStr - list" {
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    const list = PersistentList{ .items = &items };
    try expectFormat("(1 2 3)", .{ .list = &list });
}

test "Value.formatPrStr - empty list" {
    const list = PersistentList{ .items = &.{} };
    try expectFormat("()", .{ .list = &list });
}

test "Value.formatPrStr - vector" {
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const vec = PersistentVector{ .items = &items };
    try expectFormat("[1 2]", .{ .vector = &vec });
}

test "Value.formatPrStr - empty vector" {
    const vec = PersistentVector{ .items = &.{} };
    try expectFormat("[]", .{ .vector = &vec });
}

test "Value.formatPrStr - map" {
    const entries = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 },
        .{ .keyword = .{ .name = "b", .ns = null } }, .{ .integer = 2 },
    };
    const m = PersistentArrayMap{ .entries = &entries };
    try expectFormat("{:a 1, :b 2}", .{ .map = &m });
}

test "Value.formatPrStr - empty map" {
    const m = PersistentArrayMap{ .entries = &.{} };
    try expectFormat("{}", .{ .map = &m });
}

test "Value.formatPrStr - set" {
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const s = PersistentHashSet{ .items = &items };
    try expectFormat("#{1 2}", .{ .set = &s });
}

test "Value.formatPrStr - empty set" {
    const s = PersistentHashSet{ .items = &.{} };
    try expectFormat("#{}", .{ .set = &s });
}

test "Value.eql - nil" {
    try testing.expect((Value{ .nil = {} }).eql(.nil));
}

test "Value.eql - boolean" {
    const t: Value = .{ .boolean = true };
    const f: Value = .{ .boolean = false };
    try testing.expect(t.eql(.{ .boolean = true }));
    try testing.expect(f.eql(.{ .boolean = false }));
    try testing.expect(!t.eql(f));
}

test "Value.eql - integer" {
    const a: Value = .{ .integer = 42 };
    try testing.expect(a.eql(.{ .integer = 42 }));
    try testing.expect(!a.eql(.{ .integer = 43 }));
}

test "Value.eql - float" {
    const a: Value = .{ .float = 3.14 };
    try testing.expect(a.eql(.{ .float = 3.14 }));
    try testing.expect(!a.eql(.{ .float = 2.71 }));
}

test "Value.eql - cross-type numeric" {
    // Clojure: (= 1 1.0) => true
    const i: Value = .{ .integer = 1 };
    const f: Value = .{ .float = 1.0 };
    try testing.expect(i.eql(f));
    try testing.expect(f.eql(i));
    // (= 1 1.5) => false
    try testing.expect(!i.eql(.{ .float = 1.5 }));
}

test "Value.eql - char" {
    const a: Value = .{ .char = 'A' };
    try testing.expect(a.eql(.{ .char = 'A' }));
    try testing.expect(!a.eql(.{ .char = 'B' }));
}

test "Value.eql - string" {
    const a: Value = .{ .string = "hello" };
    try testing.expect(a.eql(.{ .string = "hello" }));
    try testing.expect(!a.eql(.{ .string = "world" }));
}

test "Value.eql - symbol" {
    const a: Value = .{ .symbol = .{ .name = "foo", .ns = null } };
    try testing.expect(a.eql(.{ .symbol = .{ .name = "foo", .ns = null } }));
    try testing.expect(!a.eql(.{ .symbol = .{ .name = "bar", .ns = null } }));
    // Namespaced vs non-namespaced
    try testing.expect(!a.eql(.{ .symbol = .{ .name = "foo", .ns = "x" } }));
}

test "Value.eql - keyword" {
    const a: Value = .{ .keyword = .{ .name = "k", .ns = "ns" } };
    try testing.expect(a.eql(.{ .keyword = .{ .name = "k", .ns = "ns" } }));
    try testing.expect(!a.eql(.{ .keyword = .{ .name = "k", .ns = null } }));
    try testing.expect(!a.eql(.{ .keyword = .{ .name = "other", .ns = "ns" } }));
}

test "Value.eql - list" {
    const items_a = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const items_b = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const items_c = [_]Value{ .{ .integer = 1 }, .{ .integer = 3 } };
    const la = PersistentList{ .items = &items_a };
    const lb = PersistentList{ .items = &items_b };
    const lc = PersistentList{ .items = &items_c };
    try testing.expect((Value{ .list = &la }).eql(.{ .list = &lb }));
    try testing.expect(!(Value{ .list = &la }).eql(.{ .list = &lc }));
}

test "Value.eql - list/vector sequential equality" {
    // Clojure: (= '(1 2) [1 2]) => true
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const lst = PersistentList{ .items = &items };
    const vec = PersistentVector{ .items = &items };
    try testing.expect((Value{ .list = &lst }).eql(.{ .vector = &vec }));
    try testing.expect((Value{ .vector = &vec }).eql(.{ .list = &lst }));
}

test "Value.eql - vector" {
    const items_a = [_]Value{ .{ .integer = 1 } };
    const items_b = [_]Value{ .{ .integer = 1 } };
    const empty = [_]Value{};
    const va = PersistentVector{ .items = &items_a };
    const vb = PersistentVector{ .items = &items_b };
    const ve = PersistentVector{ .items = &empty };
    try testing.expect((Value{ .vector = &va }).eql(.{ .vector = &vb }));
    try testing.expect(!(Value{ .vector = &va }).eql(.{ .vector = &ve }));
}

test "Value.eql - map" {
    const entries_a = [_]Value{ .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 } };
    const entries_b = [_]Value{ .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 } };
    const entries_c = [_]Value{ .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 2 } };
    const ma = PersistentArrayMap{ .entries = &entries_a };
    const mb = PersistentArrayMap{ .entries = &entries_b };
    const mc = PersistentArrayMap{ .entries = &entries_c };
    try testing.expect((Value{ .map = &ma }).eql(.{ .map = &mb }));
    try testing.expect(!(Value{ .map = &ma }).eql(.{ .map = &mc }));
}

test "Value.eql - set" {
    const items_a = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const items_b = [_]Value{ .{ .integer = 2 }, .{ .integer = 1 } };
    const items_c = [_]Value{ .{ .integer = 1 }, .{ .integer = 3 } };
    const sa = PersistentHashSet{ .items = &items_a };
    const sb = PersistentHashSet{ .items = &items_b };
    const sc = PersistentHashSet{ .items = &items_c };
    try testing.expect((Value{ .set = &sa }).eql(.{ .set = &sb }));
    try testing.expect(!(Value{ .set = &sa }).eql(.{ .set = &sc }));
}

test "Value.eql - different types" {
    // Different types are never equal (except int/float)
    const nil_v: Value = .nil;
    const int_v: Value = .{ .integer = 0 };
    const bool_v: Value = .{ .boolean = false };
    const str_v: Value = .{ .string = "nil" };
    try testing.expect(!nil_v.eql(int_v));
    try testing.expect(!nil_v.eql(bool_v));
    try testing.expect(!nil_v.eql(str_v));
    try testing.expect(!int_v.eql(bool_v));
}

test "Value - fn_val creation" {
    const fn_obj = Fn{ .proto = undefined, .closure_bindings = null };
    const v: Value = .{ .fn_val = &fn_obj };
    try testing.expect(!v.isNil());
    try testing.expect(v.isTruthy());
}

test "Value.formatPrStr - fn_val" {
    const fn_obj = Fn{ .proto = undefined, .closure_bindings = null };
    try expectFormat("#<fn>", .{ .fn_val = &fn_obj });
}

test "Value.eql - fn_val identity" {
    const fn_obj = Fn{ .proto = undefined, .closure_bindings = null };
    const v: Value = .{ .fn_val = &fn_obj };
    // fn values use identity equality (same pointer)
    try testing.expect(v.eql(v));
    // Different fn_val is not equal (distinct allocation)
    var fn_obj2 = Fn{ .proto = undefined, .closure_bindings = null };
    try testing.expect(!v.eql(.{ .fn_val = &fn_obj2 }));
}

test "Value - isTruthy" {
    const nil_val: Value = .nil;
    const false_val: Value = .{ .boolean = false };
    const true_val: Value = .{ .boolean = true };
    const zero_val: Value = .{ .integer = 0 };
    const empty_str: Value = .{ .string = "" };
    try testing.expect(!nil_val.isTruthy());
    try testing.expect(!false_val.isTruthy());
    try testing.expect(true_val.isTruthy());
    try testing.expect(zero_val.isTruthy());
    try testing.expect(empty_str.isTruthy());
}

fn expectFormatStr(expected: []const u8, v: Value) !void {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try v.formatStr(&w);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "Value.formatStr - nil is empty string" {
    try expectFormatStr("", .nil);
}

test "Value.formatStr - string without quotes" {
    try expectFormatStr("hello", .{ .string = "hello" });
}

test "Value.formatStr - char as literal" {
    try expectFormatStr("A", .{ .char = 'A' });
    try expectFormatStr("\n", .{ .char = '\n' });
}

test "Value.formatStr - other types same as formatPrStr" {
    try expectFormatStr("42", .{ .integer = 42 });
    try expectFormatStr("true", .{ .boolean = true });
    try expectFormatStr("3.14", .{ .float = 3.14 });
    try expectFormatStr(":foo", .{ .keyword = .{ .name = "foo", .ns = null } });
}

test "Value - atom creation and formatPrStr" {
    var a = Atom{ .value = .{ .integer = 42 } };
    const v: Value = .{ .atom = &a };
    try testing.expect(!v.isNil());
    try testing.expect(v.isTruthy());
    try expectFormat("#<atom 42>", v);
}

test "Value.eql - atom identity" {
    var a = Atom{ .value = .{ .integer = 42 } };
    const v: Value = .{ .atom = &a };
    try testing.expect(v.eql(v));
    var b = Atom{ .value = .{ .integer = 42 } };
    try testing.expect(!v.eql(.{ .atom = &b }));
}

test "Value.formatPrStr - var_ref" {
    var the_var = Var{
        .sym = .{ .ns = null, .name = "foo" },
        .ns_name = "user",
    };
    try expectFormat("#'user/foo", .{ .var_ref = &the_var });
}

test "Value.eql - var_ref identity" {
    var the_var = Var{
        .sym = .{ .ns = null, .name = "foo" },
        .ns_name = "user",
    };
    const v: Value = .{ .var_ref = &the_var };
    try testing.expect(v.eql(v));
    var other_var = Var{
        .sym = .{ .ns = null, .name = "foo" },
        .ns_name = "user",
    };
    try testing.expect(!v.eql(.{ .var_ref = &other_var }));
}
