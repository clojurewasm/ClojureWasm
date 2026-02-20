// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Builtin registry — comptime table aggregation and Env registration.
//!
//! Aggregates per-domain BuiltinDef tables, validates no duplicates at
//! comptime, and provides registerBuiltins() to intern Vars with metadata
//! into the clojure.core namespace.

const std = @import("std");
const var_mod = @import("../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const Value = @import("../runtime/value.zig").Value;

// Domain modules
const arithmetic = @import("arithmetic.zig");
const special_forms = @import("special_forms.zig");
const collections_mod = @import("collections.zig");
const predicates_mod = @import("predicates.zig");
const strings_mod = @import("strings.zig");
const io_mod = @import("io.zig");
const atom_mod = @import("atom.zig");
const sequences_mod = @import("sequences.zig");
const metadata_mod = @import("metadata.zig");
const regex_mod = @import("regex_builtins.zig");
const eval_mod = @import("eval.zig");
const ns_ops_mod = @import("ns_ops.zig");
const misc_mod = @import("misc.zig");
const multimethods_mod = @import("multimethods.zig");
const system_mod = @import("system.zig");
const transient_mod = @import("transient.zig");
const chunk_mod = @import("chunk.zig");
const math_mod = @import("math.zig");
const http_server_mod = @import("http_server.zig");
const lifecycle_mod = @import("../runtime/lifecycle.zig");
const wasm_builtins_mod = @import("../wasm/builtins.zig");
const shell_mod = @import("shell.zig");
const pprint_mod = @import("pprint.zig");
const array_mod = @import("array.zig");
const constructors_mod = @import("../interop/constructors.zig");

// ============================================================
// Comptime table aggregation
// ============================================================

/// All clojure.core builtins (arithmetic + special forms + future domains).
pub const all_builtins = arithmetic.builtins ++ special_forms.builtins ++ collections_mod.builtins ++ predicates_mod.builtins ++ strings_mod.builtins ++ io_mod.builtins ++ atom_mod.builtins ++ sequences_mod.builtins ++ arithmetic.numeric_builtins ++ metadata_mod.builtins ++ regex_mod.builtins ++ eval_mod.builtins ++ ns_ops_mod.builtins ++ misc_mod.builtins ++ multimethods_mod.builtins ++ io_mod.file_io_builtins ++ system_mod.builtins ++ transient_mod.builtins ++ chunk_mod.builtins ++ lifecycle_mod.builtins ++ array_mod.builtins ++ constructors_mod.builtins;

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
            v.bindRoot(Value.initBuiltinFn(f));
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
    const ns_sym = Value.initSymbol(env.allocator, .{ .ns = null, .name = "user" });
    ns_var.bindRoot(ns_sym);
    env.trackOwnedSymbol(ns_sym);
    try user_ns.refer("*ns*", ns_var);

    // Register dynamic vars with default values
    const dynamic_vars = .{
        .{ "*file*", Value.nil_val },
        .{ "*command-line-args*", Value.nil_val },
        .{ "*e", Value.nil_val },
        .{ "*flush-on-newline*", Value.true_val },
        .{ "*print-dup*", Value.false_val },
        .{ "*print-length*", Value.nil_val },
        .{ "*print-level*", Value.nil_val },
        .{ "*print-meta*", Value.false_val },
        .{ "*print-namespace-maps*", Value.true_val },
        .{ "*print-readably*", Value.true_val },
        .{ "*read-eval*", Value.true_val },
        .{ "*data-readers*", Value.nil_val },
        .{ "*default-data-reader-fn*", Value.nil_val },
        .{ "*source-path*", Value.nil_val },
        .{ "*unchecked-math*", Value.false_val },
        .{ "*verbose-defrecords*", Value.false_val },
        .{ "*repl*", Value.false_val },
        .{ "*err*", Value.nil_val }, // placeholder — no Java streams
        .{ "*in*", Value.nil_val }, // placeholder — no Java streams
        .{ "*out*", Value.nil_val }, // placeholder — no Java streams
    };
    inline for (dynamic_vars) |entry| {
        const dv = try core_ns.intern(entry[0]);
        dv.dynamic = true;
        dv.bindRoot(entry[1]);
        try user_ns.refer(entry[0], dv);
    }

    // Register constant vars
    const unquote_var = try core_ns.intern("unquote");
    const uq_sym = Value.initSymbol(env.allocator, .{ .ns = null, .name = "unquote" });
    unquote_var.bindRoot(uq_sym);
    env.trackOwnedSymbol(uq_sym);
    try user_ns.refer("unquote", unquote_var);

    const unquote_splicing_var = try core_ns.intern("unquote-splicing");
    const uqs_sym = Value.initSymbol(env.allocator, .{ .ns = null, .name = "unquote-splicing" });
    unquote_splicing_var.bindRoot(uqs_sym);
    env.trackOwnedSymbol(uqs_sym);
    try user_ns.refer("unquote-splicing", unquote_splicing_var);

    // Register clojure.string namespace builtins
    const str_ns = try env.findOrCreateNamespace("clojure.string");
    for (strings_mod.clj_string_builtins) |b| {
        const v = try str_ns.intern(b.name);
        v.applyBuiltinDef(b);
        if (b.func) |f| {
            v.bindRoot(Value.initBuiltinFn(f));
        }
    }

    // Register clojure.edn namespace builtins
    const edn_ns = try env.findOrCreateNamespace("clojure.edn");
    for (eval_mod.edn_builtins) |b| {
        const v = try edn_ns.intern(b.name);
        v.applyBuiltinDef(b);
        if (b.func) |f| {
            v.bindRoot(Value.initBuiltinFn(f));
        }
    }

    // Register clojure.math namespace builtins + constants
    const math_ns = try env.findOrCreateNamespace("clojure.math");
    for (math_mod.builtins) |b| {
        const v = try math_ns.intern(b.name);
        v.applyBuiltinDef(b);
        if (b.func) |f| {
            v.bindRoot(Value.initBuiltinFn(f));
        }
    }
    const pi_var = try math_ns.intern("PI");
    pi_var.bindRoot(Value.initFloat(math_mod.PI));
    const e_var = try math_ns.intern("E");
    e_var.bindRoot(Value.initFloat(math_mod.E));

    // Register Java interop static field constants in clojure.core.
    // These are referenced via rewriteStaticField in the analyzer
    // (e.g. Integer/MAX_VALUE → __integer-max-value).
    const java_consts = [_]struct { name: []const u8, val: Value }{
        // Integer (Java i32)
        .{ .name = "__integer-max-value", .val = Value.initInteger(2147483647) },
        .{ .name = "__integer-min-value", .val = Value.initInteger(-2147483648) },
        .{ .name = "__integer-size", .val = Value.initInteger(32) },
        .{ .name = "__integer-bytes", .val = Value.initInteger(4) },
        // Double (Java f64)
        .{ .name = "__double-max-value", .val = Value.initFloat(std.math.floatMax(f64)) },
        .{ .name = "__double-min-value", .val = Value.initFloat(std.math.floatTrueMin(f64)) },
        .{ .name = "__double-nan", .val = Value.initFloat(std.math.nan(f64)) },
        .{ .name = "__double-positive-infinity", .val = Value.initFloat(std.math.inf(f64)) },
        .{ .name = "__double-negative-infinity", .val = Value.initFloat(-std.math.inf(f64)) },
        .{ .name = "__double-min-normal", .val = Value.initFloat(std.math.floatMin(f64)) },
        .{ .name = "__double-max-exponent", .val = Value.initInteger(1023) },
        .{ .name = "__double-min-exponent", .val = Value.initInteger(-1022) },
        .{ .name = "__double-size", .val = Value.initInteger(64) },
        .{ .name = "__double-bytes", .val = Value.initInteger(8) },
        // Float (Java f32, values stored as f64)
        .{ .name = "__float-max-value", .val = Value.initFloat(@as(f64, std.math.floatMax(f32))) },
        .{ .name = "__float-min-value", .val = Value.initFloat(@as(f64, std.math.floatTrueMin(f32))) },
        .{ .name = "__float-nan", .val = Value.initFloat(std.math.nan(f64)) },
        .{ .name = "__float-positive-infinity", .val = Value.initFloat(std.math.inf(f64)) },
        .{ .name = "__float-negative-infinity", .val = Value.initFloat(-std.math.inf(f64)) },
        .{ .name = "__float-min-normal", .val = Value.initFloat(@as(f64, std.math.floatMin(f32))) },
        .{ .name = "__float-max-exponent", .val = Value.initInteger(127) },
        .{ .name = "__float-min-exponent", .val = Value.initInteger(-126) },
        .{ .name = "__float-size", .val = Value.initInteger(32) },
        .{ .name = "__float-bytes", .val = Value.initInteger(4) },
        // Short (Java i16)
        .{ .name = "__short-max-value", .val = Value.initInteger(32767) },
        .{ .name = "__short-min-value", .val = Value.initInteger(-32768) },
        .{ .name = "__short-size", .val = Value.initInteger(16) },
        .{ .name = "__short-bytes", .val = Value.initInteger(2) },
        // Byte (Java i8)
        .{ .name = "__byte-max-value", .val = Value.initInteger(127) },
        .{ .name = "__byte-min-value", .val = Value.initInteger(-128) },
        .{ .name = "__byte-size", .val = Value.initInteger(8) },
        .{ .name = "__byte-bytes", .val = Value.initInteger(1) },
        // Boolean
        .{ .name = "__boolean-true", .val = Value.true_val },
        .{ .name = "__boolean-false", .val = Value.false_val },
        // Character (Java u16)
        .{ .name = "__character-max-value", .val = Value.initChar(0xFFFF) },
        .{ .name = "__character-min-value", .val = Value.initChar(0) },
        .{ .name = "__character-max-code-point", .val = Value.initInteger(0x10FFFF) },
        .{ .name = "__character-min-code-point", .val = Value.initInteger(0) },
        .{ .name = "__character-size", .val = Value.initInteger(16) },
        .{ .name = "__character-bytes", .val = Value.initInteger(2) },
        // Long (i64 — exceeds i48 NaN-boxing, auto-promotes to float via initInteger)
        .{ .name = "__long-max-value", .val = Value.initInteger(std.math.maxInt(i64)) },
        .{ .name = "__long-min-value", .val = Value.initInteger(std.math.minInt(i64)) },
        .{ .name = "__long-size", .val = Value.initInteger(64) },
        .{ .name = "__long-bytes", .val = Value.initInteger(8) },
    };
    // File static fields (Java File.separator, File.pathSeparator)
    const file_consts = [_]struct { name: []const u8, val: Value }{
        .{ .name = "__file-separator", .val = Value.initString(std.heap.page_allocator, "/") },
        .{ .name = "__file-path-separator", .val = Value.initString(std.heap.page_allocator, ":") },
        .{ .name = "__file-separator-char", .val = Value.initChar('/') },
        .{ .name = "__file-path-separator-char", .val = Value.initChar(':') },
    };
    for (java_consts) |jc| {
        const v = try core_ns.intern(jc.name);
        v.bindRoot(jc.val);
        try user_ns.refer(jc.name, v);
    }
    for (file_consts) |fc| {
        const v = try core_ns.intern(fc.name);
        v.bindRoot(fc.val);
        try user_ns.refer(fc.name, v);
    }

    // Register wasm namespace builtins (Phase 25, D82: renamed wasm -> cljw.wasm)
    if (@import("../wasm/types.zig").enable_wasm) {
        const wasm_ns = try env.findOrCreateNamespace("cljw.wasm");
        for (wasm_builtins_mod.builtins) |b| {
            const v = try wasm_ns.intern(b.name);
            v.applyBuiltinDef(b);
            if (b.func) |f| {
                v.bindRoot(Value.initBuiltinFn(f));
            }
        }
    }

    // Register clojure.java.io namespace builtins (Phase 33.3, D82)
    const java_io_ns = try env.findOrCreateNamespace("clojure.java.io");
    for (io_mod.java_io_builtins) |b| {
        const v = try java_io_ns.intern(b.name);
        v.applyBuiltinDef(b);
        if (b.func) |f| {
            v.bindRoot(Value.initBuiltinFn(f));
        }
    }

    // Register cljw.http namespace builtins (Phase 34.2)
    const http_ns = try env.findOrCreateNamespace("cljw.http");
    for (http_server_mod.builtins) |b| {
        const v = try http_ns.intern(b.name);
        v.applyBuiltinDef(b);
        if (b.func) |f| {
            v.bindRoot(Value.initBuiltinFn(f));
        }
    }
    // Hidden var for GC rooting of handler function
    _ = try http_ns.intern("__handler");

    // Register clojure.java.shell namespace builtins (Phase 39.1)
    const shell_ns = try env.findOrCreateNamespace("clojure.java.shell");
    for (shell_mod.builtins) |b| {
        const v = try shell_ns.intern(b.name);
        v.applyBuiltinDef(b);
        if (b.func) |f| {
            v.bindRoot(Value.initBuiltinFn(f));
        }
    }

    // Register clojure.pprint namespace builtins (Phase 39.2)
    const pprint_ns = try env.findOrCreateNamespace("clojure.pprint");
    for (pprint_mod.builtins) |b| {
        const v = try pprint_ns.intern(b.name);
        v.applyBuiltinDef(b);
        if (b.func) |f| {
            v.bindRoot(Value.initBuiltinFn(f));
        }
    }
    // pprint dynamic vars
    const pprint_dvars = [_]struct { name: []const u8, val: Value }{
        .{ .name = "*print-right-margin*", .val = Value.initInteger(72) },
        .{ .name = "*print-miser-width*", .val = Value.initInteger(40) },
        .{ .name = "*print-pretty*", .val = Value.true_val },
        .{ .name = "*print-suppress-namespaces*", .val = Value.false_val },
        .{ .name = "*print-radix*", .val = Value.false_val },
        .{ .name = "*print-base*", .val = Value.initInteger(10) },
        .{ .name = "*print-pprint-dispatch*", .val = Value.nil_val },
    };
    for (pprint_dvars) |dv| {
        const v = try pprint_ns.intern(dv.name);
        v.dynamic = true;
        v.bindRoot(dv.val);
    }

    env.current_ns = user_ns;
}

// === Tests ===

test "all_builtins count" {
    // 379 + 2 (error-handler, error-mode) + 12 Java interop methods + 2 (read, read+string) + 5 (__interop-new, __uri-create, __uuid-random-uuid, __uuid-from-string, __inst-from-string) + 16 (A.4) + 15 (A.5)
    try std.testing.expectEqual(510, builtin_count);
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
