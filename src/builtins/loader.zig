// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Loader — namespace loading functions.
//!
//! Extracted from bootstrap.zig (D109 R4). Provides loadCore, loadTest,
//! loadRepl, loadPprint, loadReducers, loadEmbeddedLib, and syncNsVar.
//!
//! Layer 2 (lang): imports runtime/ + engine/.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../runtime/value.zig").Value;
const Env = @import("../runtime/env.zig").Env;
const err = @import("../runtime/error.zig");
const pipeline = @import("../runtime/pipeline.zig");
const ns_loader = @import("../runtime/ns_loader.zig");

const BootstrapError = pipeline.BootstrapError;

/// Embedded Clojure source strings.
const es = @import("../runtime/embedded_sources.zig");

/// Load core function definitions via VM compiler (Phase 2 of bootstrap, D73).
///
/// Phase 1 (core.clj) eliminated — all builtins now registered by registerBuiltins().
///
/// Phase 2: Compile hot-path transducer functions (map, filter, comp,
///   get-in, assoc-in, update-in) and HOF closures (constantly, complement,
///   partial, juxt, etc.) via VM compiler. This produces bytecode closures
///   that run ~200x faster in VM reduce loops than TreeWalk closures.
///
/// Called after registerBuiltins. Temporarily switches to clojure.core namespace,
/// then re-refers all bindings into user namespace.
pub fn loadCore(allocator: Allocator, env: *Env) BootstrapError!void {
    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };

    // Save current namespace and switch to clojure.core
    const saved_ns = env.current_ns;
    env.current_ns = core_ns;

    // Phase 1: core.clj eliminated — all macros/functions now Zig builtins (Phase C.1).

    // Phase 2: Re-compile transducer factory functions to bytecodes via VM.
    // Only 1-arity (transducer) forms are bytecoded; other arities delegate
    // to original TreeWalk versions to minimize memory/cache footprint.
    _ = try pipeline.evalStringVMBootstrap(allocator, env, es.hot_core_defs);

    // Phase 2b: Define HOF closure utilities via VM (constantly, complement,
    // partial, juxt, every-pred, some-fn, fnil, memoize, etc.).
    _ = try pipeline.evalStringVMBootstrap(allocator, env, es.core_hof_defs);

    // Phase 2c: Define remaining transducers, lazy-seq constructors, def constants
    // via VM (concat, iterate, range, repeat, partition, destructure, etc.).
    _ = try pipeline.evalStringVMBootstrap(allocator, env, es.core_seq_defs);

    // Restore user namespace and re-refer all core bindings
    env.current_ns = saved_ns;
    syncNsVar(env);
    if (saved_ns) |user_ns| {
        var iter = core_ns.mappings.iterator();
        while (iter.next()) |entry| {
            user_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
    }

    // Note: print Var caches (*print-length*, *print-level*) are initialized
    // by restoreFromBootstrapCache() in the production path, not here.
    // loadCore is also used in tests with local arenas, so setting globals
    // here would create dangling pointers after the arena is freed.
}

pub fn loadTest(allocator: Allocator, env: *Env) BootstrapError!void {
    try ns_loader.loadNamespaceClj(allocator, env, @import("lib/clojure_test.zig").namespace_def);
    ns_loader.referToUserNs(env, "clojure.test");
}

pub fn loadRepl(allocator: Allocator, env: *Env) BootstrapError!void {
    try ns_loader.loadNamespaceClj(allocator, env, @import("lib/clojure_repl.zig").namespace_def);
    ns_loader.referToUserNs(env, "clojure.repl");
}

pub fn loadPprint(allocator: Allocator, env: *Env) BootstrapError!void {
    try ns_loader.loadNamespaceClj(allocator, env, @import("lib/clojure_pprint.zig").namespace_def);
}

pub fn loadReducers(allocator: Allocator, env: *Env) BootstrapError!void {
    try ns_loader.loadNamespaceClj(allocator, env, @import("lib/clojure_core_reducers.zig").namespace_def);
}

/// Load an embedded library lazily (called from ns_ops.requireLib on first require).
/// Returns true if the namespace was loaded from embedded source.
pub fn loadEmbeddedLib(allocator: Allocator, env: *Env, ns_name: []const u8) BootstrapError!bool {
    return ns_loader.loadLazyNamespace(allocator, env, ns_name);
}

/// Sync *ns* var with env.current_ns. Called after manual namespace switches.
pub fn syncNsVar(env: *Env) void {
    const ns_name = if (env.current_ns) |ns| ns.name else "user";
    if (env.findNamespace("clojure.core")) |core| {
        if (core.resolve("*ns*")) |ns_var| {
            const old_val = ns_var.getRawRoot();
            const new_val = Value.initSymbol(env.allocator, .{ .ns = null, .name = ns_name });
            ns_var.bindRoot(new_val);
            env.replaceOwnedSymbol(old_val, new_val);
        }
    }
}
