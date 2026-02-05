// Builtin registry — comptime table aggregation and Env registration.
//
// Aggregates per-domain BuiltinDef tables, validates no duplicates at
// comptime, and provides registerBuiltins() to intern Vars with metadata
// into the clojure.core namespace.

const std = @import("std");
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const env_mod = @import("../env.zig");
const Env = env_mod.Env;
const Value = @import("../value.zig").Value;

// Domain modules
const arithmetic = @import("arithmetic.zig");
const special_forms = @import("special_forms.zig");
const collections_mod = @import("collections.zig");
const predicates_mod = @import("predicates.zig");
const strings_mod = @import("strings.zig");
const io_mod = @import("io.zig");
const atom_mod = @import("atom.zig");
const sequences_mod = @import("sequences.zig");
const numeric_mod = @import("numeric.zig");
const metadata_mod = @import("metadata.zig");
const regex_mod = @import("regex_builtins.zig");
const eval_mod = @import("eval.zig");
const ns_ops_mod = @import("ns_ops.zig");
const misc_mod = @import("misc.zig");
const clj_string_mod = @import("clj_string.zig");
const multimethods_mod = @import("multimethods.zig");
const file_io_mod = @import("file_io.zig");
const system_mod = @import("system.zig");
const transient_mod = @import("transient.zig");
const chunk_mod = @import("chunk.zig");
const math_mod = @import("math.zig");

// ============================================================
// Comptime table aggregation
// ============================================================

/// All clojure.core builtins (arithmetic + special forms + future domains).
pub const all_builtins = arithmetic.builtins ++ special_forms.builtins ++ collections_mod.builtins ++ predicates_mod.builtins ++ strings_mod.builtins ++ io_mod.builtins ++ atom_mod.builtins ++ sequences_mod.builtins ++ numeric_mod.builtins ++ metadata_mod.builtins ++ regex_mod.builtins ++ eval_mod.builtins ++ ns_ops_mod.builtins ++ misc_mod.builtins ++ multimethods_mod.builtins ++ file_io_mod.builtins ++ system_mod.builtins ++ transient_mod.builtins ++ chunk_mod.builtins;

/// Number of registered builtins.
pub const builtin_count = all_builtins.len;

// Comptime validation: no duplicate names
comptime {
    @setEvalBranchQuota(all_builtins.len * all_builtins.len * 10);
    for (all_builtins, 0..) |a, i| {
        for (all_builtins[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.name, b.name)) {
                @compileError("duplicate builtin name: " ++ a.name);
            }
        }
    }
}

// ============================================================
// Lookup
// ============================================================

/// Find a BuiltinDef by name at comptime.
pub fn comptimeLookup(comptime name: []const u8) BuiltinDef {
    for (all_builtins) |b| {
        if (comptime std.mem.eql(u8, b.name, name)) return b;
    }
    @compileError("unknown builtin: " ++ name);
}

/// Find a BuiltinDef by name at runtime. Returns null if not found.
pub fn lookup(name: []const u8) ?BuiltinDef {
    for (all_builtins) |b| {
        if (std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

// ============================================================
// Env registration
// ============================================================

/// Register all builtins into clojure.core namespace in the given Env.
/// Interns a Var for each BuiltinDef and applies metadata.
/// Also sets up "user" namespace with refers to clojure.core.
pub fn registerBuiltins(env: *Env) !void {
    const core_ns = try env.findOrCreateNamespace("clojure.core");

    for (all_builtins) |b| {
        const v = try core_ns.intern(b.name);
        v.applyBuiltinDef(b);
        // Bind runtime function as root value
        if (b.func) |f| {
            v.bindRoot(.{ .builtin_fn = f });
        }
    }

    // Create user namespace and refer all core builtins
    const user_ns = try env.findOrCreateNamespace("user");
    for (all_builtins) |b| {
        if (core_ns.resolve(b.name)) |v| {
            try user_ns.refer(b.name, v);
        }
    }

    // Register *ns* dynamic var (tracks current namespace)
    const ns_var = try core_ns.intern("*ns*");
    ns_var.dynamic = true;
    ns_var.bindRoot(.{ .symbol = .{ .ns = null, .name = "user" } });
    try user_ns.refer("*ns*", ns_var);

    // Register dynamic vars with default values
    const dynamic_vars = .{
        .{ "*file*", Value.nil },
        .{ "*command-line-args*", Value.nil },
        .{ "*e", Value.nil },
        .{ "*flush-on-newline*", Value{ .boolean = true } },
        .{ "*print-dup*", Value{ .boolean = false } },
        .{ "*print-length*", Value.nil },
        .{ "*print-level*", Value.nil },
        .{ "*print-meta*", Value{ .boolean = false } },
        .{ "*print-namespace-maps*", Value{ .boolean = true } },
        .{ "*print-readably*", Value{ .boolean = true } },
        .{ "*read-eval*", Value{ .boolean = true } },
        .{ "*data-readers*", Value.nil },
        .{ "*default-data-reader-fn*", Value.nil },
        .{ "*source-path*", Value.nil },
        .{ "*unchecked-math*", Value{ .boolean = false } },
        .{ "*verbose-defrecords*", Value{ .boolean = false } },
        .{ "*repl*", Value{ .boolean = false } },
        .{ "*err*", Value.nil }, // placeholder — no Java streams
        .{ "*in*", Value.nil }, // placeholder — no Java streams
        .{ "*out*", Value.nil }, // placeholder — no Java streams
    };
    inline for (dynamic_vars) |entry| {
        const dv = try core_ns.intern(entry[0]);
        dv.dynamic = true;
        dv.bindRoot(entry[1]);
        try user_ns.refer(entry[0], dv);
    }

    // Register constant vars
    const unquote_var = try core_ns.intern("unquote");
    unquote_var.bindRoot(.{ .symbol = .{ .ns = null, .name = "unquote" } });
    try user_ns.refer("unquote", unquote_var);

    const unquote_splicing_var = try core_ns.intern("unquote-splicing");
    unquote_splicing_var.bindRoot(.{ .symbol = .{ .ns = null, .name = "unquote-splicing" } });
    try user_ns.refer("unquote-splicing", unquote_splicing_var);

    // Register clojure.string namespace builtins
    const str_ns = try env.findOrCreateNamespace("clojure.string");
    for (clj_string_mod.builtins) |b| {
        const v = try str_ns.intern(b.name);
        v.applyBuiltinDef(b);
        if (b.func) |f| {
            v.bindRoot(.{ .builtin_fn = f });
        }
    }

    // Register clojure.edn namespace builtins
    const edn_ns = try env.findOrCreateNamespace("clojure.edn");
    for (eval_mod.edn_builtins) |b| {
        const v = try edn_ns.intern(b.name);
        v.applyBuiltinDef(b);
        if (b.func) |f| {
            v.bindRoot(.{ .builtin_fn = f });
        }
    }

    // Register clojure.math namespace builtins + constants
    const math_ns = try env.findOrCreateNamespace("clojure.math");
    for (math_mod.builtins) |b| {
        const v = try math_ns.intern(b.name);
        v.applyBuiltinDef(b);
        if (b.func) |f| {
            v.bindRoot(.{ .builtin_fn = f });
        }
    }
    const pi_var = try math_ns.intern("PI");
    pi_var.bindRoot(.{ .float = math_mod.PI });
    const e_var = try math_ns.intern("E");
    e_var.bindRoot(.{ .float = math_mod.E });

    env.current_ns = user_ns;
}

// === Tests ===

test "all_builtins count" {
    // 258 + 8 (chunk) + 2 (sorted-map-by, sorted-set-by) + 2 (subseq, rsubseq) + 3 (ns-resolve, ns-aliases, ns-refers)
    try std.testing.expectEqual(275, builtin_count);
}

test "comptime lookup finds +" {
    const def = comptime comptimeLookup("+");
    try std.testing.expectEqualStrings("+", def.name);
    try std.testing.expect(def.func != null);
}

test "comptime lookup finds if" {
    const def = comptime comptimeLookup("if");
    try std.testing.expectEqualStrings("if", def.name);
    try std.testing.expect(def.func == null);
}

test "runtime lookup" {
    const plus_opt = lookup("+");
    try std.testing.expect(plus_opt != null);
    const plus = plus_opt.?;
    try std.testing.expectEqualStrings("+", plus.name);

    const unknown = lookup("nonexistent");
    try std.testing.expect(unknown == null);
}

test "registerBuiltins creates core namespace with Vars" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var env = Env.init(arena.allocator());
    defer env.deinit();

    try registerBuiltins(&env);

    // clojure.core namespace exists
    const core = env.findNamespace("clojure.core");
    try std.testing.expect(core != null);

    // + Var exists with correct metadata
    const plus_var = core.?.resolve("+");
    try std.testing.expect(plus_var != null);
    try std.testing.expectEqualStrings("Returns the sum of nums. (+) returns 0. Does not auto-promote longs, will throw on overflow.", plus_var.?.doc.?);
    try std.testing.expectEqualStrings("([] [x] [x y] [x y & more])", plus_var.?.arglists.?);
    try std.testing.expectEqualStrings("1.0", plus_var.?.added.?);

    // if Var exists
    const if_var = core.?.resolve("if");
    try std.testing.expect(if_var != null);
}

test "registerBuiltins creates user namespace with refers" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var env = Env.init(arena.allocator());
    defer env.deinit();

    try registerBuiltins(&env);

    // user namespace exists and is current
    const user = env.findNamespace("user");
    try std.testing.expect(user != null);
    try std.testing.expectEqual(user, env.current_ns);

    // + is resolvable in user (via refer)
    const plus_var = user.?.resolve("+");
    try std.testing.expect(plus_var != null);
    try std.testing.expectEqualStrings("clojure.core", plus_var.?.ns_name);
}

test "registerBuiltins all builtins resolvable in core" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var env = Env.init(arena.allocator());
    defer env.deinit();

    try registerBuiltins(&env);

    const core = env.findNamespace("clojure.core").?;
    for (all_builtins) |b| {
        const v = core.resolve(b.name);
        try std.testing.expect(v != null);
    }
}
