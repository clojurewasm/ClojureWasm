// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Pipeline — read → analyze → evaluate orchestration.
//!
//! Extracted from bootstrap.zig (D109 R2). This module provides the full
//! evaluation pipeline for source strings: parsing, analysis (with macro
//! expansion), and evaluation via TreeWalk or Compiler+VM.
//!
//! Layer 1 (engine): imports reader/, analyzer/, compiler/, evaluator/, vm/, runtime/.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = @import("../reader/reader.zig").Reader;
const Form = @import("../reader/form.zig").Form;
const Analyzer = @import("../analyzer/analyzer.zig").Analyzer;
const Node = @import("../analyzer/node.zig").Node;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Env = @import("env.zig").Env;
const Namespace = @import("namespace.zig").Namespace;
const err = @import("error.zig");
const TreeWalk = @import("../evaluator/tree_walk.zig").TreeWalk;
const predicates_mod = @import("../builtins/predicates.zig");
const chunk_mod = @import("../compiler/chunk.zig");
const Compiler = @import("../compiler/compiler.zig").Compiler;
const vm_mod = @import("../vm/vm.zig");
const VM = vm_mod.VM;
const gc_mod = @import("gc.zig");
const dispatch = @import("dispatch.zig");

/// Bootstrap error type (shared with bootstrap.zig).
pub const BootstrapError = error{
    ReadError,
    AnalyzeError,
    EvalError,
    CompileError,
    OutOfMemory,
};

/// Save and set macro expansion / lazy-seq realization / fn_val dispatch globals.
/// Returns previous state for restoration via defer.
pub const MacroEnvState = struct {
    env: ?*Env,
    pred_env: ?*Env,
};

pub fn setupMacroEnv(env: *Env) MacroEnvState {
    const prev = MacroEnvState{
        .env = dispatch.macro_eval_env,
        .pred_env = predicates_mod.current_env,
    };
    dispatch.macro_eval_env = env;
    predicates_mod.current_env = env;
    return prev;
}

pub fn restoreMacroEnv(prev: MacroEnvState) void {
    dispatch.macro_eval_env = prev.env;
    predicates_mod.current_env = prev.pred_env;
}

/// Parse source into top-level forms.
pub fn readForms(allocator: Allocator, source: []const u8) BootstrapError![]Form {
    return readFormsWithNs(allocator, source, null);
}

pub fn readFormsWithNs(allocator: Allocator, source: []const u8, current_ns: ?*const Namespace) BootstrapError![]Form {
    var reader = Reader.init(allocator, source);
    reader.current_ns = current_ns;
    return reader.readAll() catch return error.ReadError;
}

/// Analyze a single form with macro expansion support.
pub fn analyzeForm(allocator: Allocator, env: *Env, form: Form) BootstrapError!*Node {
    var analyzer = Analyzer.initWithEnv(allocator, env);
    defer analyzer.deinit();
    return analyzer.analyze(form) catch return error.AnalyzeError;
}

/// Callback invoked after each top-level form is evaluated.
/// Used by -e mode and REPL to print results interleaved with side-effects.
pub const FormObserver = struct {
    context: *anyopaque,
    onResult: *const fn (*anyopaque, Value) void,
};

/// Reads, analyzes, and evaluates each top-level form sequentially.
/// Returns the value of the last form, or nil if source is empty.
pub fn evalString(allocator: Allocator, env: *Env, source: []const u8) BootstrapError!Value {
    return evalStringInner(allocator, env, source, null);
}

/// Like evalString but calls observer.onResult after each form is evaluated.
/// This ensures result printing is interleaved with side-effects (println etc).
pub fn evalStringObserved(allocator: Allocator, env: *Env, source: []const u8, observer: FormObserver) BootstrapError!Value {
    return evalStringInner(allocator, env, source, observer);
}

fn evalStringInner(allocator: Allocator, env: *Env, source: []const u8, observer: ?FormObserver) BootstrapError!Value {
    // Reader/analyzer use node_arena (GPA-backed, not GC-tracked) so AST Nodes
    // survive GC sweeps. TreeWalk uses allocator (gc_alloc) for Value creation.
    const node_alloc = env.nodeAllocator();

    // Read forms one at a time, updating reader.current_ns after each eval.
    // This ensures syntax-quote symbol resolution uses the correct namespace
    // after (ns ...) forms set up :refer-clojure :exclude mappings.
    var reader = Reader.init(node_alloc, source);
    reader.current_ns = if (env.current_ns) |ns| ns else null;

    const prev = setupMacroEnv(env);
    defer restoreMacroEnv(prev);

    // Note: tw is intentionally not deinit'd — closures created during
    // evaluation may be def'd into Vars and must outlive this scope.
    var tw = TreeWalk.initWithEnv(allocator, env);

    var last_value: Value = Value.nil_val;
    while (true) {
        const form = reader.read() catch return error.ReadError;
        if (form == null) break;
        const node = try analyzeForm(node_alloc, env, form.?);
        last_value = tw.run(node) catch {
            err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
            return error.EvalError;
        };
        if (observer) |obs| obs.onResult(obs.context, last_value);
        // Update reader namespace after eval so subsequent syntax-quote
        // resolves symbols in the new namespace (e.g. after ns form).
        reader.current_ns = if (env.current_ns) |ns| ns else null;
    }
    return last_value;
}

/// Compile source to bytecode and dump to stderr without executing.
pub fn dumpBytecodeVM(allocator: Allocator, env: *Env, source: []const u8) BootstrapError!void {
    const node_alloc = env.nodeAllocator();
    const ns_ptr: ?*const Namespace = if (env.current_ns) |ns| ns else null;
    const forms = try readFormsWithNs(node_alloc, source, ns_ptr);
    if (forms.len == 0) return;

    const prev = setupMacroEnv(env);
    defer restoreMacroEnv(prev);

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var w = &aw.writer;

    for (forms, 0..) |form, form_idx| {
        const node = try analyzeForm(node_alloc, env, form);

        var compiler = Compiler.init(allocator);
        defer compiler.deinit();
        if (env.current_ns) |ns| {
            compiler.current_ns_name = ns.name;
            compiler.current_ns = ns;
        }
        compiler.compile(node) catch return error.CompileError;
        compiler.chunk.emitOp(.ret) catch return error.CompileError;

        w.print("\n=== Form {d} ===\n", .{form_idx}) catch {};
        compiler.chunk.dump(w) catch {};

        // Dump all nested FnProtos
        for (compiler.fn_protos.items) |proto| {
            proto.dump(w) catch {};
        }
    }

    // Write collected output to stderr
    const output = w.buffered();
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
    _ = stderr.write(output) catch {};
}

pub fn evalStringVM(allocator: Allocator, env: *Env, source: []const u8) BootstrapError!Value {
    return evalStringVMInner(allocator, env, source, null);
}

/// Like evalStringVM but calls observer.onResult after each form is evaluated.
pub fn evalStringVMObserved(allocator: Allocator, env: *Env, source: []const u8, observer: FormObserver) BootstrapError!Value {
    return evalStringVMInner(allocator, env, source, observer);
}

fn evalStringVMInner(allocator: Allocator, env: *Env, source: []const u8, observer: ?FormObserver) BootstrapError!Value {
    // Reader/analyzer use node_arena (GPA-backed, not GC-tracked).
    // Compiler/VM use allocator (gc_alloc) for bytecode and Values.
    const node_alloc = env.nodeAllocator();

    // Read forms one at a time, updating reader.current_ns after each eval.
    // This ensures syntax-quote symbol resolution uses the correct namespace
    // after (ns ...) forms set up :refer-clojure :exclude mappings.
    var reader = Reader.init(node_alloc, source);
    reader.current_ns = if (env.current_ns) |ns| ns else null;

    const prev = setupMacroEnv(env);
    defer restoreMacroEnv(prev);

    const gc: ?*gc_mod.MarkSweepGc = if (env.gc) |g| @ptrCast(@alignCast(g)) else null;

    if (gc != null) {
        // GC mode: GC owns all allocations. No manual retain/detach needed.
        // Don't call compiler.deinit() — GC traces FnProto internals via traceValue.
        // Heap-allocate VM to avoid C stack overflow (VM struct is ~1.5MB).
        const vm = env.allocator.create(VM) catch return error.CompileError;
        defer env.allocator.destroy(vm);
        var last_value: Value = Value.nil_val;
        while (true) {
            const form = reader.read() catch return error.ReadError;
            if (form == null) break;
            const node = try analyzeForm(node_alloc, env, form.?);

            var compiler = Compiler.init(allocator);
            if (env.current_ns) |ns| {
                compiler.current_ns_name = ns.name;
                compiler.current_ns = ns;
            }
            compiler.compile(node) catch return error.CompileError;
            compiler.chunk.emitOp(.ret) catch return error.CompileError;

            vm.* = VM.initWithEnv(allocator, env);
            vm.gc = gc;
            last_value = vm.run(&compiler.chunk) catch {
                err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
                return error.EvalError;
            };
            if (observer) |obs| obs.onResult(obs.context, last_value);
            reader.current_ns = if (env.current_ns) |ns| ns else null;
        }
        return last_value;
    }

    // Non-GC mode: manual retain/detach pattern (fix for use-after-free T9.5.1).
    var retained_protos: std.ArrayList(*const chunk_mod.FnProto) = .empty;
    defer {
        for (retained_protos.items) |proto| {
            allocator.free(proto.code);
            allocator.free(proto.constants);
            allocator.destroy(@constCast(proto));
        }
        retained_protos.deinit(allocator);
    }
    var retained_fns: std.ArrayList(*const value_mod.Fn) = .empty;
    defer {
        for (retained_fns.items) |fn_obj| {
            allocator.destroy(@constCast(fn_obj));
        }
        retained_fns.deinit(allocator);
    }

    var last_value: Value = Value.nil_val;
    while (true) {
        const form = reader.read() catch return error.ReadError;
        if (form == null) break;
        const node = try analyzeForm(node_alloc, env, form.?);

        var compiler = Compiler.init(allocator);
        defer compiler.deinit();
        if (env.current_ns) |ns| {
            compiler.current_ns_name = ns.name;
            compiler.current_ns = ns;
        }
        compiler.compile(node) catch return error.CompileError;
        compiler.chunk.emitOp(.ret) catch return error.CompileError;

        const detached = compiler.detachFnAllocations();
        for (detached.fn_protos) |p| {
            retained_protos.append(allocator, p) catch return error.CompileError;
        }
        if (detached.fn_protos.len > 0) allocator.free(detached.fn_protos);
        for (detached.fn_objects) |o| {
            retained_fns.append(allocator, o) catch return error.CompileError;
        }
        if (detached.fn_objects.len > 0) allocator.free(detached.fn_objects);

        // Heap-allocate VM to avoid C stack overflow (VM struct is ~1.5MB).
        const vm = env.allocator.create(VM) catch return error.CompileError;
        vm.* = VM.initWithEnv(allocator, env);
        defer {
            vm.deinit();
            env.allocator.destroy(vm);
        }
        last_value = vm.run(&compiler.chunk) catch {
            err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
            return error.EvalError;
        };
        if (observer) |obs| obs.onResult(obs.context, last_value);

        const vm_fns = vm.detachFnAllocations();
        for (vm_fns) |f| {
            retained_fns.append(allocator, f) catch return error.CompileError;
        }
        if (vm_fns.len > 0) allocator.free(vm_fns);
        reader.current_ns = if (env.current_ns) |ns| ns else null;
    }
    return last_value;
}

/// Evaluate source via Compiler+VM, retaining all FnProto/Fn allocations.
/// Used for bootstrap where closures are stored in Vars and must outlive evaluation.
/// Compiler is intentionally NOT deinit'd — FnProtos referenced by Fn objects in Vars
/// must persist for the program lifetime. The VM is also not deinit'd — allocated
/// Values (lists, vectors, maps, fns) may be stored in Vars via def/defn.
pub fn evalStringVMBootstrap(allocator: Allocator, env: *Env, source: []const u8) BootstrapError!Value {
    const node_alloc = env.nodeAllocator();

    // Read forms one at a time, updating reader.current_ns after each eval.
    var reader = Reader.init(node_alloc, source);
    reader.current_ns = if (env.current_ns) |ns| ns else null;

    const prev = setupMacroEnv(env);
    defer restoreMacroEnv(prev);

    // Heap-allocate VM to avoid C stack overflow (VM struct is ~1.5MB).
    // Reused across forms — re-initialized each iteration.
    const vm = env.allocator.create(VM) catch return error.CompileError;
    defer env.allocator.destroy(vm);

    var last_value: Value = Value.nil_val;
    while (true) {
        const form = reader.read() catch return error.ReadError;
        if (form == null) break;
        const node = try analyzeForm(node_alloc, env, form.?);

        // Note: compiler is intentionally NOT deinit'd — closures created during
        // evaluation may be def'd into Vars and must outlive this scope.
        var compiler = Compiler.init(allocator);
        if (env.current_ns) |ns| {
            compiler.current_ns_name = ns.name;
            compiler.current_ns = ns;
        }
        compiler.compile(node) catch return error.CompileError;
        compiler.chunk.emitOp(.ret) catch return error.CompileError;

        vm.* = VM.initWithEnv(allocator, env);
        last_value = vm.run(&compiler.chunk) catch {
            err.ensureInfoSet(.eval, .internal_error, .{}, "bootstrap evaluation error", .{});
            return error.EvalError;
        };
        reader.current_ns = if (env.current_ns) |ns| ns else null;
    }
    return last_value;
}

