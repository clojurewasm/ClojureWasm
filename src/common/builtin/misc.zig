// Misc builtins — gensym, compare-and-set!, format.
//
// Small standalone utilities that don't fit neatly into other domain files.

const std = @import("std");
const Allocator = std.mem.Allocator;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const err = @import("../error.zig");
const bootstrap = @import("../bootstrap.zig");

// ============================================================
// gensym
// ============================================================

var gensym_counter: u64 = 0;

/// (gensym) => G__42
/// (gensym prefix-string) => prefix42
pub fn gensymFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len > 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to gensym", .{args.len});

    const prefix: []const u8 = if (args.len == 1) switch (args[0]) {
        .string => |s| s,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "gensym expects a string prefix, got {s}", .{@tagName(args[0])}),
    } else "G__";

    gensym_counter += 1;

    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll(prefix);
    try w.print("{d}", .{gensym_counter});
    const name = try allocator.dupe(u8, w.buffered());
    return .{ .symbol = .{ .ns = null, .name = name } };
}

// ============================================================
// compare-and-set!
// ============================================================

/// (compare-and-set! atom oldval newval)
/// Atomically sets the value of atom to newval if and only if the
/// current value of the atom is identical to oldval. Returns true
/// if set happened, else false.
pub fn compareAndSetFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to compare-and-set!", .{args.len});
    const atom_ptr = switch (args[0]) {
        .atom => |a| a,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "compare-and-set! expects an atom, got {s}", .{@tagName(args[0])}),
    };
    const oldval = args[1];
    const newval = args[2];

    // Single-threaded: simple compare and swap
    if (atom_ptr.value.eql(oldval)) {
        atom_ptr.value = newval;
        return .{ .boolean = true };
    }
    return .{ .boolean = false };
}

// ============================================================
// format
// ============================================================

/// (format fmt & args)
/// Formats a string using java.lang.String/format-style placeholders.
/// Supported: %s (string), %d (integer), %f (float), %% (literal %).
pub fn formatFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to format", .{args.len});
    const fmt_str = switch (args[0]) {
        .string => |s| s,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "format expects a string as first argument, got {s}", .{@tagName(args[0])}),
    };
    const fmt_args = args[1..];

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var w = &aw.writer;

    var arg_idx: usize = 0;
    var i: usize = 0;
    while (i < fmt_str.len) {
        if (fmt_str[i] == '%') {
            i += 1;
            if (i >= fmt_str.len) return error.FormatError;

            switch (fmt_str[i]) {
                '%' => {
                    try w.writeByte('%');
                },
                's' => {
                    if (arg_idx >= fmt_args.len) return error.FormatError;
                    try fmt_args[arg_idx].formatStr(w);
                    arg_idx += 1;
                },
                'd' => {
                    if (arg_idx >= fmt_args.len) return error.FormatError;
                    switch (fmt_args[arg_idx]) {
                        .integer => |n| try w.print("{d}", .{n}),
                        .float => |f| try w.print("{d}", .{@as(i64, @intFromFloat(f))}),
                        else => return error.FormatError,
                    }
                    arg_idx += 1;
                },
                'f' => {
                    if (arg_idx >= fmt_args.len) return error.FormatError;
                    switch (fmt_args[arg_idx]) {
                        .float => |f| try w.print("{d:.6}", .{f}),
                        .integer => |n| try w.print("{d:.6}", .{@as(f64, @floatFromInt(n))},),
                        else => return error.FormatError,
                    }
                    arg_idx += 1;
                },
                else => {
                    // Unsupported format specifier — pass through
                    try w.writeByte('%');
                    try w.writeByte(fmt_str[i]);
                },
            }
        } else {
            try w.writeByte(fmt_str[i]);
        }
        i += 1;
    }

    const result = try allocator.dupe(u8, aw.writer.buffered());
    return .{ .string = result };
}

// ============================================================
// BuiltinDef table
// ============================================================

// ============================================================
// Dynamic binding support
// ============================================================

/// (push-thread-bindings {var1 val1, var2 val2, ...})
/// Takes a map of Var refs to values, pushes a new binding frame.
pub fn pushThreadBindingsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "push-thread-bindings requires 1 argument, got {d}", .{args.len});
    const m = switch (args[0]) {
        .map => |mp| mp,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "push-thread-bindings requires a map", .{}),
    };
    const n_pairs = m.entries.len / 2;
    if (n_pairs == 0) return .nil;

    const entries = allocator.alloc(var_mod.BindingEntry, n_pairs) catch return error.OutOfMemory;
    var idx: usize = 0;
    var i: usize = 0;
    while (i < m.entries.len) : (i += 2) {
        const key = m.entries[i];
        const val = m.entries[i + 1];
        const v: *var_mod.Var = switch (key) {
            .var_ref => |ptr| ptr,
            else => return err.setErrorFmt(.eval, .type_error, .{}, "push-thread-bindings keys must be Vars", .{}),
        };
        if (!v.dynamic) return err.setErrorFmt(.eval, .value_error, .{}, "Can't dynamically bind non-dynamic var: {s}", .{v.sym.name});
        entries[idx] = .{ .var_ptr = v, .val = val };
        idx += 1;
    }

    const frame = allocator.create(var_mod.BindingFrame) catch return error.OutOfMemory;
    frame.* = .{ .entries = entries, .prev = null };
    var_mod.pushBindings(frame);
    return .nil;
}

/// (pop-thread-bindings) — pops the current binding frame.
pub fn popThreadBindingsFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "pop-thread-bindings takes no arguments, got {d}", .{args.len});
    var_mod.popBindings();
    return .nil;
}

// ============================================================
// thread-bound?, var-raw-root
// ============================================================

/// (thread-bound? & vars) — true if all given vars have thread-local bindings.
pub fn threadBoundPredFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args (0) passed to thread-bound?", .{});
    for (args) |arg| {
        const v = switch (arg) {
            .var_ref => |vr| vr,
            else => return err.setErrorFmt(.eval, .type_error, .{}, "thread-bound? expects Var args, got {s}", .{@tagName(arg)}),
        };
        if (!v.dynamic or !var_mod.hasThreadBinding(v)) return .{ .boolean = false };
    }
    return .{ .boolean = true };
}

/// (var-raw-root v) — returns the root value of a Var, bypassing thread-local bindings.
fn varRawRootFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to var-raw-root", .{args.len});
    const v = switch (args[0]) {
        .var_ref => |vr| vr,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "var-raw-root expects a Var, got {s}", .{@tagName(args[0])}),
    };
    return v.getRawRoot();
}

// ============================================================
// alter-var-root
// ============================================================

/// (alter-var-root var f & args) — atomically alters the root binding of var
/// by applying f to its current value plus any args.
pub fn alterVarRootFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to alter-var-root", .{args.len});
    const v = switch (args[0]) {
        .var_ref => |vr| vr,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "alter-var-root expects a var, got {s}", .{@tagName(args[0])}),
    };
    const f = args[1];
    const old_val = v.deref();

    // Build call args: [old_val, extra_args...]
    const call_args = allocator.alloc(Value, 1 + (args.len - 2)) catch return error.OutOfMemory;
    call_args[0] = old_val;
    for (args[2..], 0..) |a, i| {
        call_args[1 + i] = a;
    }

    const new_val = bootstrap.callFnVal(allocator, f, call_args) catch |e| return e;
    v.bindRoot(new_val);
    return new_val;
}

// ============================================================
// ex-cause
// ============================================================

/// (ex-cause ex)
/// Returns the cause of an exception (currently always nil — no nested cause chain).
pub fn exCauseFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to ex-cause", .{args.len});
    // Our exceptions don't have a cause chain — return nil
    return .nil;
}

// ============================================================
// find-var
// ============================================================

/// (find-var sym)
/// Returns the Var mapped to the qualified symbol, or nil if not found.
pub fn findVarFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to find-var", .{args.len});
    const sym = switch (args[0]) {
        .symbol => |s| s,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "find-var expects a symbol, got {s}", .{@tagName(args[0])}),
    };
    const env = bootstrap.macro_eval_env orelse return error.EvalError;
    const ns_name = sym.ns orelse {
        // Unqualified — look in current ns
        const current = env.current_ns orelse return .nil;
        if (current.resolve(sym.name)) |_| {
            return args[0]; // return the symbol (we don't expose Var as Value)
        }
        return .nil;
    };
    const ns = env.findNamespace(ns_name) orelse return .nil;
    if (ns.resolve(sym.name)) |_| {
        return args[0];
    }
    return .nil;
}

// ============================================================
// resolve
// ============================================================

/// (resolve sym) or (resolve env sym)
/// Returns the var or Class to which sym will be resolved in the current namespace, else nil.
pub fn resolveFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to resolve", .{args.len});
    const sym = switch (args[args.len - 1]) {
        .symbol => |s| s,
        else => return .nil,
    };
    const env = bootstrap.macro_eval_env orelse return error.EvalError;
    const current = env.current_ns orelse return .nil;

    // Qualified symbol
    if (sym.ns) |ns_name| {
        // Check alias first
        if (current.getAlias(ns_name)) |target_ns| {
            if (target_ns.resolve(sym.name)) |_| {
                return args[args.len - 1];
            }
        }
        // Try direct namespace
        if (env.findNamespace(ns_name)) |ns| {
            if (ns.resolve(sym.name)) |_| {
                return args[args.len - 1];
            }
        }
        return .nil;
    }

    // Unqualified — search current ns
    if (current.resolve(sym.name)) |_| {
        return args[args.len - 1];
    }
    return .nil;
}

// ============================================================
// intern
// ============================================================

/// (intern ns name) or (intern ns name val)
/// Finds or creates a var named by the symbol name in the namespace ns, setting root to val if supplied.
pub fn internFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to intern", .{args.len});
    const ns_name = switch (args[0]) {
        .symbol => |s| s.name,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "intern expects a symbol for namespace, got {s}", .{@tagName(args[0])}),
    };
    const var_name = switch (args[1]) {
        .symbol => |s| s.name,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "intern expects a symbol for name, got {s}", .{@tagName(args[1])}),
    };
    const env = bootstrap.macro_eval_env orelse return error.EvalError;
    const ns = env.findNamespace(ns_name) orelse {
        return err.setErrorFmt(.eval, .value_error, .{}, "No namespace: {s}", .{ns_name});
    };
    const v = try ns.intern(var_name);
    if (args.len == 3) {
        v.bindRoot(args[2]);
    }
    // Return the qualified symbol representing the var
    return .{ .symbol = .{ .ns = ns_name, .name = var_name } };
}

// ============================================================
// loaded-libs
// ============================================================

const ns_ops = @import("ns_ops.zig");

/// (loaded-libs)
/// Returns a sorted set of symbols naming loaded libs.
pub fn loadedLibsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to loaded-libs", .{args.len});
    // Build a set of loaded lib names
    const env = bootstrap.macro_eval_env orelse return error.EvalError;
    // Return all namespace names as a set
    var count: usize = 0;
    var iter = env.namespaces.iterator();
    while (iter.next()) |_| count += 1;

    const items = allocator.alloc(Value, count) catch return .nil;
    var i: usize = 0;
    iter = env.namespaces.iterator();
    while (iter.next()) |entry| {
        items[i] = .{ .symbol = .{ .ns = null, .name = entry.key_ptr.* } };
        i += 1;
    }
    const set = try allocator.create(value_mod.PersistentHashSet);
    set.* = .{ .items = items };
    return .{ .set = set };
}

// ============================================================
// map-entry?
// ============================================================

/// (map-entry? x)
/// Returns true if x is a map entry (2-element vector from map seq).
pub fn mapEntryFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to map-entry?", .{args.len});
    // In our implementation, map entries are 2-element vectors
    return switch (args[0]) {
        .vector => |v| .{ .boolean = v.items.len == 2 },
        else => .{ .boolean = false },
    };
}

// ============================================================
// Hashing
// ============================================================

const predicates_mod = @import("predicates.zig");
const collections_mod = @import("collections.zig");

/// Murmur3 constants (matches JVM Clojure)
const M3_C1: i32 = @bitCast(@as(u32, 0xcc9e2d51));
const M3_C2: i32 = @bitCast(@as(u32, 0x1b873593));

fn mixK1(k: i32) i32 {
    var k1: u32 = @bitCast(k);
    k1 *%= @bitCast(M3_C1);
    k1 = std.math.rotl(u32, k1, 15);
    k1 *%= @bitCast(M3_C2);
    return @bitCast(k1);
}

fn mixH1(h: i32, k1: i32) i32 {
    var h1: u32 = @bitCast(h);
    h1 ^= @as(u32, @bitCast(k1));
    h1 = std.math.rotl(u32, h1, 13);
    h1 = h1 *% 5 +% @as(u32, 0xe6546b64);
    return @bitCast(h1);
}

fn fmix(h: i32, length: i32) i32 {
    var h1 = h;
    h1 ^= length;
    h1 ^= @as(i32, @intCast(@as(u32, @bitCast(h1)) >> 16));
    h1 = h1 *% @as(i32, @bitCast(@as(u32, 0x85ebca6b)));
    h1 ^= @as(i32, @intCast(@as(u32, @bitCast(h1)) >> 13));
    h1 = h1 *% @as(i32, @bitCast(@as(u32, 0xc2b2ae35)));
    h1 ^= @as(i32, @intCast(@as(u32, @bitCast(h1)) >> 16));
    return h1;
}

fn mixCollHash(hash_val: i32, count: i32) i32 {
    var h1: i32 = 0; // seed
    const k1 = mixK1(hash_val);
    h1 = mixH1(h1, k1);
    return fmix(h1, count);
}

/// (mix-collection-hash hash-basis count)
pub fn mixCollectionHashFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to mix-collection-hash", .{args.len});
    const hash_basis: i32 = switch (args[0]) {
        .integer => |n| @truncate(n),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "mix-collection-hash expects integer, got {s}", .{@tagName(args[0])}),
    };
    const count: i32 = switch (args[1]) {
        .integer => |n| @truncate(n),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "mix-collection-hash expects integer count, got {s}", .{@tagName(args[1])}),
    };
    return Value{ .integer = @as(i64, mixCollHash(hash_basis, count)) };
}

/// (hash-ordered-coll coll)
pub fn hashOrderedCollFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to hash-ordered-coll", .{args.len});
    var n: i32 = 0;
    var hash: i32 = 1;
    // Walk the seq
    var s = try collections_mod.seqFn(allocator, &.{args[0]});
    while (s != .nil) {
        const first = try collections_mod.firstFn(allocator, &.{s});
        const h = predicates_mod.computeHash(first);
        hash = hash *% 31 +% @as(i32, @truncate(h));
        n += 1;
        s = try collections_mod.restFn(allocator, &.{s});
        // restFn returns empty list, not nil, so check for empty
        s = try collections_mod.seqFn(allocator, &.{s});
    }
    return Value{ .integer = @as(i64, mixCollHash(hash, n)) };
}

/// (hash-unordered-coll coll)
pub fn hashUnorderedCollFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to hash-unordered-coll", .{args.len});
    var n: i32 = 0;
    var hash: i32 = 0;
    var s = try collections_mod.seqFn(allocator, &.{args[0]});
    while (s != .nil) {
        const first = try collections_mod.firstFn(allocator, &.{s});
        const h = predicates_mod.computeHash(first);
        hash +%= @as(i32, @truncate(h));
        n += 1;
        s = try collections_mod.restFn(allocator, &.{s});
        s = try collections_mod.seqFn(allocator, &.{s});
    }
    return Value{ .integer = @as(i64, mixCollHash(hash, n)) };
}

/// (hash-combine x y) — à la boost::hash_combine
pub fn hashCombineFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to hash-combine", .{args.len});
    const x: i32 = switch (args[0]) {
        .integer => |n| @truncate(n),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "hash-combine expects integer, got {s}", .{@tagName(args[0])}),
    };
    const y_hash: i32 = @truncate(predicates_mod.computeHash(args[1]));
    // a la boost: seed ^= hash + 0x9e3779b9 + (seed << 6) + (seed >> 2)
    var seed: i32 = x;
    seed ^= y_hash +% @as(i32, @bitCast(@as(u32, 0x9e3779b9))) +% (seed << 6) +% @as(i32, @intCast(@as(u32, @bitCast(seed)) >> 2));
    return Value{ .integer = @as(i64, seed) };
}

pub const builtins = [_]BuiltinDef{
    .{
        .name = "gensym",
        .func = gensymFn,
        .doc = "Returns a new symbol with a unique name. If a prefix string is supplied, the name is prefix# where # is some unique number. If no prefix is supplied, the prefix is 'G__'.",
        .arglists = "([] [prefix-string])",
        .added = "1.0",
    },
    .{
        .name = "compare-and-set!",
        .func = compareAndSetFn,
        .doc = "Atomically sets the value of atom to newval if and only if the current value of the atom is identical to oldval. Returns true if set happened, else false.",
        .arglists = "([atom oldval newval])",
        .added = "1.0",
    },
    .{
        .name = "format",
        .func = formatFn,
        .doc = "Formats a string using java.lang.String/format-style placeholders. Supports %s, %d, %f, %%.",
        .arglists = "([fmt & args])",
        .added = "1.0",
    },
    .{
        .name = "push-thread-bindings",
        .func = pushThreadBindingsFn,
        .doc = "Pushes a new frame of bindings for dynamic vars. bindings-map is a map of Var/value pairs.",
        .arglists = "([bindings-map])",
        .added = "1.0",
    },
    .{
        .name = "pop-thread-bindings",
        .func = popThreadBindingsFn,
        .doc = "Pops the frame of bindings most recently pushed with push-thread-bindings.",
        .arglists = "([])",
        .added = "1.0",
    },
    .{
        .name = "thread-bound?",
        .func = threadBoundPredFn,
        .doc = "Returns true if all given vars have thread-local bindings.",
        .arglists = "([& vars])",
        .added = "1.0",
    },
    .{
        .name = "var-raw-root",
        .func = varRawRootFn,
        .doc = "Returns the root value of a Var, bypassing thread-local bindings.",
        .arglists = "([v])",
        .added = "1.0",
    },
    .{
        .name = "alter-var-root",
        .func = &alterVarRootFn,
        .doc = "Atomically alters the root binding of var by applying f to its current value plus any args.",
        .arglists = "([v f & args])",
        .added = "1.0",
    },
    .{
        .name = "ex-cause",
        .func = exCauseFn,
        .doc = "Returns the cause of an exception.",
        .arglists = "([ex])",
        .added = "1.0",
    },
    .{
        .name = "find-var",
        .func = findVarFn,
        .doc = "Returns the global var named by the namespace-qualified symbol, or nil if no var with that name.",
        .arglists = "([sym])",
        .added = "1.0",
    },
    .{
        .name = "resolve",
        .func = resolveFn,
        .doc = "Returns the var or Class to which a symbol will be resolved in the namespace, else nil.",
        .arglists = "([sym] [env sym])",
        .added = "1.0",
    },
    .{
        .name = "intern",
        .func = internFn,
        .doc = "Finds or creates a var named by the symbol name in the namespace ns, optionally setting root binding.",
        .arglists = "([ns name] [ns name val])",
        .added = "1.0",
    },
    .{
        .name = "loaded-libs",
        .func = loadedLibsFn,
        .doc = "Returns a sorted set of symbols naming the currently loaded libs.",
        .arglists = "([])",
        .added = "1.0",
    },
    .{
        .name = "map-entry?",
        .func = mapEntryFn,
        .doc = "Return true if x is a map entry.",
        .arglists = "([x])",
        .added = "1.9",
    },
    .{
        .name = "mix-collection-hash",
        .func = mixCollectionHashFn,
        .doc = "Mix final collection hash for ordered or unordered collections. hash-basis is the combined collection hash, count is the number of elements included in the basis.",
        .arglists = "([hash-basis count])",
        .added = "1.6",
    },
    .{
        .name = "hash-ordered-coll",
        .func = hashOrderedCollFn,
        .doc = "Returns the hash code, consistent with =, for an external ordered collection implementing Iterable.",
        .arglists = "([coll])",
        .added = "1.6",
    },
    .{
        .name = "hash-unordered-coll",
        .func = hashUnorderedCollFn,
        .doc = "Returns the hash code, consistent with =, for an external unordered collection implementing Iterable.",
        .arglists = "([coll])",
        .added = "1.6",
    },
    .{
        .name = "hash-combine",
        .func = hashCombineFn,
        .doc = "Utility function for combining hash values.",
        .arglists = "([x y])",
        .added = "1.2",
    },
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "gensym - no prefix" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const r1 = try gensymFn(alloc, &[_]Value{});
    try testing.expect(r1 == .symbol);
    // Should start with G__
    try testing.expect(std.mem.startsWith(u8, r1.symbol.name, "G__"));

    const r2 = try gensymFn(alloc, &[_]Value{});
    // Should be different from r1
    try testing.expect(!std.mem.eql(u8, r1.symbol.name, r2.symbol.name));
}

test "gensym - with prefix" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try gensymFn(alloc, &[_]Value{.{ .string = "foo" }});
    try testing.expect(result == .symbol);
    try testing.expect(std.mem.startsWith(u8, result.symbol.name, "foo"));
}

test "compare-and-set! - successful swap" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var atom = value_mod.Atom{ .value = .{ .integer = 1 } };
    const result = try compareAndSetFn(alloc, &[_]Value{
        .{ .atom = &atom },
        .{ .integer = 1 },
        .{ .integer = 2 },
    });
    try testing.expectEqual(Value{ .boolean = true }, result);
    try testing.expectEqual(Value{ .integer = 2 }, atom.value);
}

test "compare-and-set! - failed swap" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var atom = value_mod.Atom{ .value = .{ .integer = 1 } };
    const result = try compareAndSetFn(alloc, &[_]Value{
        .{ .atom = &atom },
        .{ .integer = 99 }, // doesn't match current value
        .{ .integer = 2 },
    });
    try testing.expectEqual(Value{ .boolean = false }, result);
    try testing.expectEqual(Value{ .integer = 1 }, atom.value); // unchanged
}

test "format - %s" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try formatFn(alloc, &[_]Value{
        .{ .string = "hello %s" },
        .{ .string = "world" },
    });
    try testing.expectEqualStrings("hello world", result.string);
}

test "format - %d" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try formatFn(alloc, &[_]Value{
        .{ .string = "count: %d" },
        .{ .integer = 42 },
    });
    try testing.expectEqualStrings("count: 42", result.string);
}

test "format - %%" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try formatFn(alloc, &[_]Value{
        .{ .string = "100%%" },
    });
    try testing.expectEqualStrings("100%", result.string);
}

test "format - mixed" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try formatFn(alloc, &[_]Value{
        .{ .string = "%s is %d" },
        .{ .string = "x" },
        .{ .integer = 10 },
    });
    try testing.expectEqualStrings("x is 10", result.string);
}
