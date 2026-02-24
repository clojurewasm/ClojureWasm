// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Cache — bootstrap cache generation, restoration, and AOT compilation.
//!
//! Extracted from bootstrap.zig (D109 R5). Provides loadBootstrapAll,
//! vmRecompileAll, generateBootstrapCache, restoreFromBootstrapCache,
//! compileToModule, and runBytecodeModule.
//!
//! Layer 1 (engine): imports runtime/ + engine modules (compiler, vm, serializer).

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const Env = @import("../runtime/env.zig").Env;
const err = @import("../runtime/error.zig");
const gc_mod = @import("../runtime/gc.zig");
const Compiler = @import("compiler/compiler.zig").Compiler;
const vm_mod = @import("vm/vm.zig");
const VM = vm_mod.VM;
const serialize_mod = @import("compiler/serialize.zig");
const pipeline = @import("pipeline.zig");
const loader = @import("../lang/loader.zig");

const BootstrapError = pipeline.BootstrapError;

// Re-export pipeline functions used internally
const readForms = pipeline.readForms;
const analyzeForm = pipeline.analyzeForm;
const setupMacroEnv = pipeline.setupMacroEnv;
const restoreMacroEnv = pipeline.restoreMacroEnv;
const evalStringVMBootstrap = pipeline.evalStringVMBootstrap;

/// Embedded Clojure source strings for recompilation.
const es = @import("embedded_sources.zig");

/// Compile source to a serialized bytecode Module.
///
/// Parses, analyzes (with macro expansion), and compiles all top-level forms
/// into a single Chunk. The resulting Module (header + string table + FnProto
/// table + Chunk) is returned as owned bytes.
///
/// Requires bootstrap already loaded (macros must be available for expansion).
pub fn compileToModule(allocator: Allocator, env: *Env, source: []const u8) BootstrapError![]const u8 {
    const node_alloc = env.nodeAllocator();
    const forms = try readForms(node_alloc, source);
    if (forms.len == 0) return error.CompileError;

    const prev = setupMacroEnv(env);
    defer restoreMacroEnv(prev);

    // Compile all forms into a single Chunk.
    // Intermediate form results are popped; final form result is returned by .ret.
    var compiler = Compiler.init(allocator);
    if (env.current_ns) |ns| {
        compiler.current_ns_name = ns.name;
        compiler.current_ns = ns;
    }
    for (forms, 0..) |form, i| {
        const node = try analyzeForm(node_alloc, env, form);
        compiler.compile(node) catch return error.CompileError;
        if (i < forms.len - 1) {
            compiler.chunk.emitOp(.pop) catch return error.CompileError;
        }
    }
    compiler.chunk.emitOp(.ret) catch return error.CompileError;

    // Serialize the Module
    var ser: serialize_mod.Serializer = .{};
    ser.serializeModule(allocator, &compiler.chunk) catch return error.CompileError;
    const bytes = ser.getBytes();
    return allocator.dupe(u8, bytes) catch return error.OutOfMemory;
}

/// Run a compiled bytecode Module in the given Env.
///
/// Deserializes the Module, then runs the top-level Chunk via VM.
/// Returns the value of the last form.
pub fn runBytecodeModule(allocator: Allocator, env: *Env, module_bytes: []const u8) BootstrapError!Value {
    const prev = setupMacroEnv(env);
    defer restoreMacroEnv(prev);

    var de: serialize_mod.Deserializer = .{ .data = module_bytes };
    const chunk = de.deserializeModule(allocator) catch return error.CompileError;

    const gc: ?*gc_mod.MarkSweepGc = if (env.gc) |g| @ptrCast(@alignCast(g)) else null;

    // Heap-allocate VM (struct is ~1.5MB)
    const vm = env.allocator.create(VM) catch return error.CompileError;
    defer env.allocator.destroy(vm);
    vm.* = VM.initWithEnv(allocator, env);
    vm.gc = gc;
    return vm.run(&chunk) catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
        return error.EvalError;
    };
}

/// Unified bootstrap: loads all standard library namespaces.
///
/// Use this instead of calling each individually.
/// Pure-zig namespaces are registered in registerBuiltins().
/// Lazy namespaces (spec, main, etc.) are loaded on first require.
pub fn loadBootstrapAll(allocator: Allocator, env: *Env) BootstrapError!void {
    try loader.loadCore(allocator, env);
    try loader.loadTest(allocator, env);
    try loader.loadRepl(allocator, env);
    try loader.loadPprint(allocator, env);
    try loader.loadReducers(allocator, env);
}

/// Re-compile all bootstrap functions to bytecode via VM compiler.
///
/// After normal TreeWalk bootstrap, vars hold TreeWalk closures (kind=treewalk).
/// These cannot be serialized because their proto points to TreeWalk.Closure (AST),
/// not FnProto (bytecode). This function re-evaluates all bootstrap source files
/// through the VM compiler, replacing all defn/defmacro var roots with bytecode closures.
///
/// Must be called after loadBootstrapAll(). After this, all top-level fn_val vars
/// are bytecode-backed and eligible for serialization.
pub fn vmRecompileAll(allocator: Allocator, env: *Env) BootstrapError!void {
    const saved_ns = env.current_ns;

    // Re-compile core functions to bytecode (core.clj eliminated, Phase C.1)
    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    env.current_ns = core_ns;
    _ = try evalStringVMBootstrap(allocator, env, es.hot_core_defs);
    _ = try evalStringVMBootstrap(allocator, env, es.core_hof_defs);
    _ = try evalStringVMBootstrap(allocator, env, es.core_seq_defs);

    // clojure.walk — Zig builtins (Phase B.4), no recompilation needed

    // Re-compile test.clj
    if (env.findNamespace("clojure.test")) |test_ns| {
        env.current_ns = test_ns;
        _ = try evalStringVMBootstrap(allocator, env, es.test_clj_source);
    }

    // clojure.set — Zig builtins (Phase B.6), no recompilation needed
    // clojure.data — Zig builtins (Phase B.5), no recompilation needed

    // Re-compile repl.clj
    if (env.findNamespace("clojure.repl")) |repl_ns| {
        env.current_ns = repl_ns;
        _ = try evalStringVMBootstrap(allocator, env, es.repl_macros_source);
    }

    // clojure.java.io — Zig builtins (Phase B.7), no recompilation needed

    // Re-compile pprint.clj
    if (env.findNamespace("clojure.pprint")) |pprint_ns| {
        env.current_ns = pprint_ns;
        _ = try evalStringVMBootstrap(allocator, env, es.pprint_clj_source);
    }

    // clojure.stacktrace — Zig builtins (Phase B.4), no recompilation needed

    // clojure.zip — Zig builtins (Phase B.9), no recompilation needed

    // clojure.core.protocols — Zig builtins (Phase B.3), no recompilation needed

    // Re-compile core/reducers.clj
    if (env.findNamespace("clojure.core.reducers")) |reducers_ns| {
        env.current_ns = reducers_ns;
        _ = try evalStringVMBootstrap(allocator, env, es.reducers_macros_source);
    }

    // spec.alpha re-compiled lazily on first require (startup time)

    // Restore namespace
    env.current_ns = saved_ns;
    loader.syncNsVar(env);
}

/// Generate a bootstrap cache: serialized env state with all fns as bytecode.
///
/// Performs full bootstrap (TreeWalk), re-compiles all fns to bytecode,
/// then serializes the entire env state. Returns owned bytes that can
/// be written to a cache file or embedded in a binary.
pub fn generateBootstrapCache(allocator: Allocator, env: *Env) BootstrapError![]const u8 {
    // Re-compile all bootstrap fns to bytecode (required for serialization)
    try vmRecompileAll(allocator, env);

    // Serialize env snapshot
    var ser: serialize_mod.Serializer = .{};
    ser.serializeEnvSnapshot(allocator, env) catch return error.CompileError;
    // Return a copy of the serialized bytes owned by the caller's allocator
    const bytes = ser.getBytes();
    return allocator.dupe(u8, bytes) catch return error.OutOfMemory;
}

/// Restore bootstrap state from a cache (serialized env snapshot).
///
/// Expects registerBuiltins(env) already called. Restores all namespaces,
/// vars, refers, and aliases from the cache bytes. Reconnects *print-length*
/// and *print-level* var caches for correct print behavior.
pub fn restoreFromBootstrapCache(allocator: Allocator, env: *Env, cache_bytes: []const u8) BootstrapError!void {
    var de: serialize_mod.Deserializer = .{ .data = cache_bytes };
    de.restoreEnvSnapshotLazy(allocator, env) catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
        return error.EvalError;
    };

    // Eagerly restore deferred namespaces that already exist from registerBuiltins.
    // Without this, namespaces created by registerBuiltins() would be marked as loaded
    // by markBootstrapLibs(), causing requireLib() to skip the deferred cache restore.
    // This merges cache-defined vars (e.g. macros from evalString) into Zig-builtin namespaces.
    serialize_mod.restorePreRegisteredDeferredNs(allocator, env);

    // Reconnect printVar caches (value.initPrintVars)
    const core_ns = env.findNamespace("clojure.core") orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "bootstrap: required namespace not found", .{});
        return error.EvalError;
    };
    if (core_ns.resolve("*print-length*")) |pl_var| {
        if (core_ns.resolve("*print-level*")) |pv_var| {
            value_mod.initPrintVars(pl_var, pv_var);
        }
    }
    if (core_ns.resolve("*print-readably*")) |pr_var| {
        if (core_ns.resolve("*print-meta*")) |pm_var| {
            value_mod.initPrintFlagVars(pr_var, pm_var);
        }
    }

    // Cache *print-dup* var for readable override
    if (core_ns.resolve("*print-dup*")) |pd_var| {
        value_mod.initPrintDupVar(pd_var);
    }

    // Cache *agent* var for binding in agent action processing
    if (core_ns.resolve("*agent*")) |agent_v| {
        const thread_pool_mod = @import("../runtime/thread_pool.zig");
        thread_pool_mod.initAgentVar(agent_v);
    }

    // Ensure *ns* is synced
    loader.syncNsVar(env);
}
