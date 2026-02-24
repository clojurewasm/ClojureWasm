// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Dispatch — central function call dispatch for all CW value types.
//!
//! This module lives in Layer 0 (runtime/) and uses function pointer vtables
//! to call into Layer 1 (engine/) without any upward imports (D109, R1).
//!
//! The vtable is initialized at bootstrap time by engine-level code.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const err = @import("error.zig");

/// Signature for call bridge functions (treewalk and bytecode).
const CallBridgeFn = *const fn (Allocator, Value, []const Value) anyerror!Value;

/// Signature for the active VM call (reuses existing VM stack).
const ActiveVmCallFn = *const fn (Value, []const Value) anyerror!Value;

/// Signature for valueTypeKey (protocol dispatch).
const ValueTypeKeyFn = *const fn (Value) []const u8;

/// Engine-level function pointers, initialized at bootstrap.
/// These break the runtime/ → engine/ dependency cycle.
var treewalk_call_bridge: CallBridgeFn = undefined;
var bytecode_call_bridge: CallBridgeFn = undefined;
var value_type_key_fn: ValueTypeKeyFn = undefined;

/// Active VM call — set by VM.execute(), cleared on exit.
/// When set, bytecode calls reuse the active VM's stack instead of
/// allocating a new VM instance (~500KB heap alloc saved).
/// Per-thread for concurrency (Phase 48).
pub threadlocal var active_vm_call: ?ActiveVmCallFn = null;

/// Initialize the dispatch vtable. Called once at bootstrap.
pub fn init(
    treewalk_bridge: CallBridgeFn,
    bytecode_bridge: CallBridgeFn,
    type_key: ValueTypeKeyFn,
) void {
    treewalk_call_bridge = treewalk_bridge;
    bytecode_call_bridge = bytecode_bridge;
    value_type_key_fn = type_key;
}

/// Env reference for macro expansion bridge. Set during evalString.
/// Public so eval builtins can access the current Env.
/// Per-thread for concurrency (Phase 48).
pub threadlocal var macro_eval_env: ?*@import("env.zig").Env = null;

/// Last exception value thrown by TreeWalk, for VM boundary crossing.
/// VM reads this in dispatchErrorToHandler to avoid creating generic ExInfo.
/// Per-thread for concurrency (Phase 48).
pub threadlocal var last_thrown_exception: ?Value = null;

/// Flag set by apply's lazy variadic path (F99). When true, the single rest arg
/// in the next variadic call is already a seq and should not be re-wrapped in a list.
/// Consumed (reset to false) by VM/TreeWalk rest packing code.
pub threadlocal var apply_rest_is_seq: bool = false;

/// Predicate evaluation environment. Set by lifecycle/pipeline, read by predicates.
/// Breaks runtime/ → lang/builtins/predicates.zig dependency (D109 Z3).
pub threadlocal var current_env: ?*@import("env.zig").Env = null;

// === Seq operations vtable (D109 R7) ===
// Breaks value.zig → builtins/collections.zig dependency.

/// Builtin function signature: fn(Allocator, []const Value) anyerror!Value
const BuiltinFn = *const fn (std.mem.Allocator, []const Value) anyerror!Value;

/// Seq operation function pointers, initialized by registry at startup.
pub var seq_fn: BuiltinFn = undefined;
pub var first_fn: BuiltinFn = undefined;
pub var rest_fn: BuiltinFn = undefined;

/// Initialize seq operation vtable. Called from registerBuiltins.
pub fn initSeqOps(seq: BuiltinFn, first: BuiltinFn, rest: BuiltinFn) void {
    seq_fn = seq;
    first_fn = first;
    rest_fn = rest;
}

// === GC FnProto tracing vtable (D109 Z3) ===
// Breaks gc.zig → engine/compiler/chunk.zig dependency.

/// Opaque tracing callback: gc calls this to trace a bytecode FnProto.
/// Signature: fn(gc: *anyopaque, proto: *const anyopaque) void
/// The gc parameter is the MarkSweepGc instance (passed as anyopaque to avoid cycle).
pub var trace_fn_proto: ?*const fn (*anyopaque, *const anyopaque) void = null;

// === VM helper vtable (D109 Z3) ===
// Breaks vm.zig → lang/builtins/predicates.zig and metadata.zig dependencies.

/// Check if an exception value matches a class name (for catch dispatch).
pub var exception_matches_class: *const fn (Value, []const u8) bool = &defaultExceptionMatchesClass;

fn defaultExceptionMatchesClass(_: Value, class_name: []const u8) bool {
    // Default: Throwable/Exception match everything (sufficient for unit tests).
    // Full implementation set by registry at bootstrap.
    return std.mem.eql(u8, class_name, "Throwable") or
        std.mem.eql(u8, class_name, "Exception") or
        std.mem.eql(u8, class_name, "RuntimeException");
}

/// Get metadata from a value (returns nil if none).
pub var get_meta: *const fn (Value) Value = &defaultGetMeta;

fn defaultGetMeta(_: Value) Value {
    return Value.nil_val;
}

/// Find best multimethod dispatch match (for VM protocol_call opcode).
pub var find_best_method: *const fn (Allocator, *const value_mod.MultiFn, Value, ?*Env) ?Value = &defaultFindBestMethod;

fn defaultFindBestMethod(_: Allocator, mf: *const value_mod.MultiFn, dispatch_val: Value, _: ?*Env) ?Value {
    return mf.methods.get(dispatch_val);
}

// === Loader vtable (D109 Z3) ===
// Breaks cache.zig/bootstrap.zig → lang/loader.zig dependency.

const Env = @import("env.zig").Env;
const LoaderFn = *const fn (Allocator, *Env) anyerror!void;
const SyncFn = *const fn (*Env) void;

pub var load_core: LoaderFn = undefined;
pub var load_test: LoaderFn = undefined;
pub var load_repl: LoaderFn = undefined;
pub var load_pprint: LoaderFn = undefined;
pub var load_reducers: LoaderFn = undefined;
pub var load_embedded_lib: *const fn (Allocator, *Env, []const u8) anyerror!bool = undefined;
pub var sync_ns_var: SyncFn = undefined;

// === Macro expansion vtable (D109 zone cleanup) ===
// Breaks macro.zig → lang/builtins/collections.zig, interop/ dependencies.

/// Realize a lazy value (lazy-seq, cons) to a concrete collection.
pub var realize_value: *const fn (Allocator, Value) anyerror!Value = &defaultRealizeValue;

fn defaultRealizeValue(_: Allocator, val: Value) anyerror!Value {
    return val; // Default: return as-is (no realization without lang/ builtins)
}

/// Construct a UUID from a string (for #uuid tagged literal).
pub var construct_uuid: *const fn (Allocator, []const u8) anyerror!Value = &defaultConstructUuid;

fn defaultConstructUuid(_: Allocator, _: []const u8) anyerror!Value {
    return Value.nil_val;
}

/// Make a class instance (for #inst tagged literal).
pub var make_inst_value: *const fn (Allocator, Value) anyerror!Value = &defaultMakeInstValue;

fn defaultMakeInstValue(_: Allocator, _: Value) anyerror!Value {
    return Value.nil_val;
}

// === Interop rewrite vtable (D109 zone cleanup) ===
// Breaks analyzer.zig → lang/interop/rewrites.zig, constructors.zig dependencies.

pub const StaticFieldRewrite = struct { ns: ?[]const u8, name: []const u8 };

/// Rewrite Java static field access to CW var reference.
pub var rewrite_static_field: *const fn ([]const u8, []const u8) ?StaticFieldRewrite = &defaultRewriteStaticField;

fn defaultRewriteStaticField(_: []const u8, _: []const u8) ?StaticFieldRewrite {
    return null;
}

/// Rewrite Java static method calls to CW builtins.
pub var rewrite_interop_call: *const fn ([]const u8, []const u8) ?[]const u8 = &defaultRewriteInteropCall;

fn defaultRewriteInteropCall(_: []const u8, _: []const u8) ?[]const u8 {
    return null;
}

/// Resolve a short class name to its FQCN.
pub var resolve_class_name: *const fn ([]const u8) ?[]const u8 = &defaultResolveClassName;

fn defaultResolveClassName(_: []const u8) ?[]const u8 {
    return null;
}

/// Central function dispatch for all callable CW value types.
///
/// Handles: builtin_fn, fn_val (treewalk + bytecode), multi_fn,
/// keyword-as-function, map/set-as-function, wasm, var deref,
/// and protocol dispatch.
///
/// This replaces 5 separate dispatch mechanisms (D36/T10.4):
///   vm.zig, tree_walk.zig, atom.zig, value.zig, analyzer.zig
/// all import dispatch.callFnVal directly.
///
/// Active VM bridge: When a bytecode closure is called and an active
/// VM exists (set via vm.zig's execute()), we reuse that VM's stack via
/// callFunction() instead of creating a new VM instance (~500KB heap alloc).
/// This is the critical path for fused reduce callbacks and makes deep
/// predicate chains (sieve's 168 filters) feasible.
pub fn callFnVal(allocator: Allocator, fn_val: Value, args: []const Value) anyerror!Value {
    switch (fn_val.tag()) {
        .builtin_fn => return fn_val.asBuiltinFn()(allocator, args),
        .fn_val => {
            const fn_obj = fn_val.asFn();
            if (fn_obj.kind == .bytecode) {
                // Active VM bridge: reuse existing VM stack (avoids ~500KB heap alloc)
                if (active_vm_call) |vm_call| {
                    return vm_call(fn_val, args) catch |e| {
                        return @as(anyerror, @errorCast(e));
                    };
                }
                return bytecode_call_bridge(allocator, fn_val, args);
            } else {
                return treewalk_call_bridge(allocator, fn_val, args);
            }
        },
        .multi_fn => {
            const mf = fn_val.asMultiFn();
            // Dispatch: call dispatch_fn, lookup method, call method
            const dispatch_val = try callFnVal(allocator, mf.dispatch_fn, args);
            const method_fn = mf.methods.get(dispatch_val) orelse
                mf.methods.get(Value.initKeyword(allocator, .{ .ns = null, .name = "default" })) orelse
                return error.TypeError;
            return callFnVal(allocator, method_fn, args);
        },
        .keyword => {
            const kw = fn_val.asKeyword();
            // Keyword-as-function: (:key map) => (get map :key)
            if (args.len < 1) return error.TypeError;
            if (args[0].tag() == .wasm_module and args.len == 1) {
                const wm = args[0].asWasmModule();
                return if (wm.getExportFn(kw.name)) |wf|
                    Value.initWasmFn(wf)
                else
                    Value.nil_val;
            }
            if (args[0].tag() == .map) {
                return args[0].asMap().get(fn_val) orelse
                    if (args.len >= 2) args[1] else Value.nil_val;
            }
            return if (args.len >= 2) args[1] else Value.nil_val;
        },
        .map => {
            const m = fn_val.asMap();
            // Map-as-function: ({:a 1} :b) => (get map key)
            if (args.len < 1) return error.TypeError;
            return m.get(args[0]) orelse
                if (args.len >= 2) args[1] else Value.nil_val;
        },
        .set => {
            const s = fn_val.asSet();
            // Set-as-function: (#{:a :b} :a) => :a or nil
            if (args.len < 1) return error.TypeError;
            return if (s.contains(args[0])) args[0] else Value.nil_val;
        },
        .wasm_module => {
            const wm = fn_val.asWasmModule();
            // Module-as-function: (mod :add) => cached WasmFn
            if (args.len != 1) return error.ArityError;
            const name = switch (args[0].tag()) {
                .keyword => args[0].asKeyword().name,
                .string => args[0].asString(),
                else => return error.TypeError,
            };
            return if (wm.getExportFn(name)) |wf|
                Value.initWasmFn(wf)
            else
                Value.nil_val;
        },
        .wasm_fn => return fn_val.asWasmFn().call(allocator, args),
        .var_ref => return callFnVal(allocator, fn_val.asVarRef().deref(), args),
        .protocol_fn => {
            const pf = fn_val.asProtocolFn();
            if (args.len == 0) return error.ArityError;
            const type_key = value_type_key_fn(args[0]);
            const method_map_val = pf.protocol.impls.getByStringKey(type_key) orelse return error.TypeError;
            if (method_map_val.tag() != .map) return error.TypeError;
            const impl_fn = method_map_val.asMap().getByStringKey(pf.method_name) orelse return error.TypeError;
            return callFnVal(allocator, impl_fn, args);
        },
        else => return error.TypeError,
    }
}
