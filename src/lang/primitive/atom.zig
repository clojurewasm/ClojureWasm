// SPDX-License-Identifier: EPL-2.0
//! Atom primitives — `atom` / `swap!` / `reset!` / `compare-and-set!`.
//!
//! The mutable cell + GC trace live in `runtime/atom.zig` (Layer 0).
//! `deref` / `@` for atoms is handled by the shared IDeref dispatcher in
//! `stm.zig` + the `@` reader macro. Watches / validators / real
//! CAS-under-contention are Phase 15 (D-157) — single-threaded now, so
//! `swap!` needs no CAS-retry loop (no contention exists; a no-op loop
//! would be a smell).

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const atom_mod = @import("../../runtime/atom.zig");
const higher_order = @import("higher_order.zig");

fn requireAtom(name: []const u8, v: Value, loc: SourceLocation) !void {
    if (!atom_mod.isAtom(v)) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = name,
            .expected = "atom",
            .actual = @tagName(v.tag()),
        });
    }
}

/// `(atom x)` — construct an atom holding x. (JVM also accepts
/// `:meta` / `:validator` kwargs — Phase 15, D-157.)
pub fn atomFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("atom", args, 1, loc);
    return try atom_mod.alloc(rt, args[0]);
}

/// `(reset! a newval)` — set the atom to newval, return newval.
pub fn resetFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("reset!", args, 2, loc);
    try requireAtom("reset!", args[0], loc);
    atom_mod.setCurrent(args[0], args[1]);
    return args[1];
}

/// `(swap! a f & args)` — set the atom to `(apply f current args)` and
/// return the new value.
pub fn swapFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len < 2) {
        return error_catalog.raise(.arity_below_min, loc, .{ .fn_name = "swap!", .got = args.len, .min = 2 });
    }
    try requireAtom("swap!", args[0], loc);
    const a = args[0];
    const f = args[1];
    var call_args: std.ArrayList(Value) = .empty;
    defer call_args.deinit(rt.gpa);
    try call_args.append(rt.gpa, atom_mod.current(a));
    try call_args.appendSlice(rt.gpa, args[2..]);
    const newval = try higher_order.invokeCallable(rt, env, f, call_args.items, loc);
    atom_mod.setCurrent(a, newval);
    return newval;
}

/// `(compare-and-set! a old new)` — set to new iff current is IDENTICAL
/// to old (JVM `AtomicReference.compareAndSet` — reference identity, NOT
/// `=`). Returns true on success, false otherwise.
pub fn compareAndSetFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("compare-and-set!", args, 3, loc);
    try requireAtom("compare-and-set!", args[0], loc);
    const cur = atom_mod.current(args[0]);
    if (@intFromEnum(cur) == @intFromEnum(args[1])) {
        atom_mod.setCurrent(args[0], args[2]);
        return Value.true_val;
    }
    return Value.false_val;
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "atom", .f = &atomFn },
    .{ .name = "swap!", .f = &swapFn },
    .{ .name = "reset!", .f = &resetFn },
    .{ .name = "compare-and-set!", .f = &compareAndSetFn },
};

pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
