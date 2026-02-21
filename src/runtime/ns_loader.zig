// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! Generic namespace loading — driven by NamespaceDef.
//!
//! Replaces hand-written loadXxx() functions in bootstrap.zig.
//! Each NamespaceDef declares its builtins, embedded source, extra refers,
//! and aliases. This module provides one function to load any of them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const env_mod = @import("env.zig");
const Env = env_mod.Env;
const Value = @import("value.zig").Value;
const err = @import("error.zig");
const bootstrap = @import("bootstrap.zig");
const registry = @import("../builtins/registry.zig");
const NamespaceDef = registry.NamespaceDef;
const BootstrapError = bootstrap.BootstrapError;

/// Load a namespace from its NamespaceDef.
///
/// 1. Find or create the namespace
/// 2. Register builtins (for lazy namespaces not yet registered at startup)
/// 3. Refer clojure.core + extra_refers
/// 4. Set up extra_aliases
/// 5. Evaluate embedded_source (if any)
/// 6. Restore saved namespace
pub fn loadNamespaceClj(allocator: Allocator, env: *Env, comptime def: NamespaceDef) BootstrapError!void {
    const ns = env.findOrCreateNamespace(def.name) catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
        return error.EvalError;
    };

    // Register builtins (idempotent — intern returns existing var)
    for (def.builtins) |b| {
        const v = ns.intern(b.name) catch return error.EvalError;
        v.applyBuiltinDef(b);
        if (b.func) |f| {
            v.bindRoot(Value.initBuiltinFn(f));
        }
    }

    const source = def.embedded_source orelse return; // Nothing to eval

    // Refer clojure.core
    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    var core_iter = core_ns.mappings.iterator();
    while (core_iter.next()) |entry| {
        ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }

    // Refer extra namespaces
    inline for (def.extra_refers) |ref_ns_name| {
        if (env.findNamespace(ref_ns_name)) |ref_ns| {
            var ref_iter = ref_ns.mappings.iterator();
            while (ref_iter.next()) |entry| {
                ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
            }
        }
    }

    // Set up aliases
    inline for (def.extra_aliases) |alias| {
        if (env.findNamespace(alias[1])) |target_ns| {
            ns.setAlias(alias[0], target_ns) catch {};
        }
    }

    // Switch to target NS, eval, restore
    const saved_ns = env.current_ns;
    env.current_ns = ns;

    _ = try bootstrap.evalString(allocator, env, source);

    env.current_ns = saved_ns;
    bootstrap.syncNsVar(env);
}

/// Load a lazy namespace by name (called from ns_ops.requireLib on first require).
/// Replaces bootstrap.loadEmbeddedLib() if-chain with comptime table lookup.
/// Returns true if the namespace was found and loaded.
pub fn loadLazyNamespace(allocator: Allocator, env: *Env, ns_name: []const u8) BootstrapError!bool {
    const lib_defs = @import("../builtins/lib/defs.zig");

    // Handle dependency: spec.alpha requires spec.gen.alpha
    if (std.mem.eql(u8, ns_name, "clojure.spec.alpha")) {
        if (env.findNamespace("clojure.spec.gen.alpha") == null) {
            try loadNamespaceClj(allocator, env, @import("../builtins/lib/clojure_spec_gen_alpha.zig").namespace_def);
        }
    }

    inline for (lib_defs.all_namespace_defs) |def| {
        if (def.loading == .lazy) {
            if (std.mem.eql(u8, def.name, ns_name)) {
                try loadNamespaceClj(allocator, env, def);
                return true;
            }
        }
    }
    return false;
}

/// Re-refer all bindings from a namespace into the user (current) namespace.
/// Used for eager namespaces (test, repl) that should be available without require.
pub fn referToUserNs(env: *Env, ns_name: []const u8) void {
    const ns = env.findNamespace(ns_name) orelse return;
    const user_ns = env.current_ns orelse return;
    var iter = ns.mappings.iterator();
    while (iter.next()) |entry| {
        user_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }
}
