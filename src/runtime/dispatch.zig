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
