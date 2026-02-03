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

// ============================================================
// Comptime table aggregation
// ============================================================

/// All clojure.core builtins (arithmetic + special forms + future domains).
pub const all_builtins = arithmetic.builtins ++ special_forms.builtins ++ collections_mod.builtins ++ predicates_mod.builtins ++ strings_mod.builtins ++ io_mod.builtins ++ atom_mod.builtins ++ sequences_mod.builtins ++ numeric_mod.builtins ++ metadata_mod.builtins ++ regex_mod.builtins ++ eval_mod.builtins ++ ns_ops_mod.builtins ++ misc_mod.builtins;

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

    env.current_ns = user_ns;
}

// === Tests ===

test "all_builtins count" {
    // Was 116, +4 (re-pattern, re-find, re-matches, re-seq)
    try std.testing.expectEqual(152, builtin_count);
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
