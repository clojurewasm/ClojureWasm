// SPDX-License-Identifier: EPL-2.0
//! The known engine gaps at the wasm surface (ADR-0196): which (engine, export
//! signature) shapes an engine cannot run today, and the user-facing remedy
//! `wasm/call` appends to a trap diagnostic. One table, one lookup. Each row
//! names its evidence rung; a row is deleted in the pin bump whose gap-lock
//! test flips (engine.zig's D-585 lock for `jit_void_window`).
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: none

const std = @import("std");
const engine = @import("engine.zig");

/// How a row was established. A `measured` row states its remedy as a fact;
/// a `zwasm_listed` row (a shape zwasm names as interpreter-only, not yet
/// probed at invoke through cljw) words it as a suggestion.
pub const Evidence = enum { measured, zwasm_listed };

pub const Gap = struct {
    /// Stable name for tests and notes; never user-facing.
    id: []const u8,
    /// The engine the row applies to, `.jit` or `.interp`. `.auto` is looked
    /// up as `.jit`, the arm it prefers.
    engine: engine.EngineKind,
    evidence: Evidence,
    matches: *const fn (sig: engine.FuncType) bool,
    /// Appended to the trap message. Names the option to pass, never a
    /// ledger id.
    remedy: []const u8,
};

fn hasFloat(types: []const engine.ValType) bool {
    for (types) |t| switch (t) {
        .f32, .f64 => return true,
        else => {},
    };
    return false;
}

fn hasV128(types: []const engine.ValType) bool {
    for (types) |t| switch (t) {
        .v128 => return true,
        else => {},
    };
    return false;
}

/// A zero-result export runs on the JIT only at arity <= 1, or at arity 2-3
/// with no floating-point parameter (measured over 40 shapes, D-585).
fn jitVoidWindow(sig: engine.FuncType) bool {
    if (sig.results.len != 0) return false;
    const n = sig.params.len;
    if (n <= 1) return false;
    if (n <= 3 and !hasFloat(sig.params)) return false;
    return true;
}

fn jitWideArity(sig: engine.FuncType) bool {
    return sig.params.len > 5;
}

fn jitManyResults(sig: engine.FuncType) bool {
    return sig.results.len > 2;
}

fn v128AtBoundary(sig: engine.FuncType) bool {
    return hasV128(sig.params) or hasV128(sig.results);
}

pub const table = [_]Gap{
    .{
        .id = "jit_void_window",
        .engine = .jit,
        .evidence = .measured,
        .matches = &jitVoidWindow,
        .remedy = "the JIT engine has no call dispatch for a zero-result export of this shape; load the module with {:engine :interp}, or give the export a result",
    },
    .{
        .id = "jit_wide_arity",
        .engine = .jit,
        .evidence = .zwasm_listed,
        .matches = &jitWideArity,
        .remedy = "the JIT engine may not dispatch an export with more than 5 parameters; try {:engine :interp}",
    },
    .{
        .id = "jit_many_results",
        .engine = .jit,
        .evidence = .zwasm_listed,
        .matches = &jitManyResults,
        .remedy = "the JIT engine may not dispatch an export with more than 2 results; try {:engine :interp}",
    },
    .{
        .id = "jit_v128_boundary",
        .engine = .jit,
        .evidence = .zwasm_listed,
        .matches = &v128AtBoundary,
        .remedy = "the JIT engine may not dispatch a v128 parameter or result at the call boundary; try {:engine :interp}",
    },
    .{
        .id = "interp_v128",
        .engine = .interp,
        .evidence = .measured,
        .matches = &v128AtBoundary,
        .remedy = "the interpreter cannot run SIMD (v128); load the module with {:engine :jit}",
    },
};

/// The first row whose engine and signature predicate match, or null when
/// the shape is not a known gap (an ordinary guest trap).
pub fn find(kind: engine.EngineKind, sig: engine.FuncType) ?*const Gap {
    const arm: engine.EngineKind = if (kind == .auto) .jit else kind;
    for (&table) |*g| {
        if (g.engine == arm and g.matches(sig)) return g;
    }
    return null;
}

const VT = engine.ValType;

fn sigOf(params: []const VT, results: []const VT) engine.FuncType {
    return .{ .params = params, .results = results };
}

test "jit: a zero-result export outside the window matches, inside it does not" {
    try std.testing.expectEqualStrings("jit_void_window", find(.jit, sigOf(&.{ .i32, .f64 }, &.{})).?.id);
    try std.testing.expectEqualStrings("jit_void_window", find(.jit, sigOf(&.{ .i32, .i32, .i32, .i32 }, &.{})).?.id);
    try std.testing.expect(find(.jit, sigOf(&.{.i32}, &.{})) == null);
    try std.testing.expect(find(.jit, sigOf(&.{ .i32, .i32, .i32 }, &.{})) == null);
    try std.testing.expect(find(.jit, sigOf(&.{}, &.{})) == null);
    // The same parameters with a result are clean (the D-585 discriminator).
    try std.testing.expect(find(.jit, sigOf(&.{ .i32, .f64 }, &.{.f64})) == null);
    try std.testing.expect(find(.jit, sigOf(&.{ .i32, .i32, .i32, .i32 }, &.{.i32})) == null);
}

test "auto is looked up as the JIT arm; interp has its own rows" {
    try std.testing.expectEqualStrings("jit_void_window", find(.auto, sigOf(&.{ .i32, .i32, .i32, .i32 }, &.{})).?.id);
    try std.testing.expect(find(.interp, sigOf(&.{ .i32, .i32, .i32, .i32 }, &.{})) == null);
    try std.testing.expectEqualStrings("interp_v128", find(.interp, sigOf(&.{.v128}, &.{.i32})).?.id);
    try std.testing.expectEqualStrings("jit_v128_boundary", find(.jit, sigOf(&.{.i32}, &.{.v128})).?.id);
}

test "zwasm-listed JIT shapes: wide arity and many results" {
    try std.testing.expectEqualStrings("jit_wide_arity", find(.jit, sigOf(&.{ .i32, .i32, .i32, .i32, .i32, .i32 }, &.{.i32})).?.id);
    try std.testing.expect(find(.jit, sigOf(&.{ .i32, .i32, .i32, .i32, .i32 }, &.{.i32})) == null);
    try std.testing.expectEqualStrings("jit_many_results", find(.jit, sigOf(&.{.i32}, &.{ .i32, .i32, .i32 })).?.id);
    try std.testing.expect(find(.jit, sigOf(&.{.i32}, &.{ .i32, .i32 })) == null);
}

test "every remedy names the option to pass and no ledger id" {
    for (table) |g| {
        try std.testing.expect(std.mem.find(u8, g.remedy, "{:engine") != null);
        try std.testing.expect(std.mem.find(u8, g.remedy, "D-") == null);
        try std.testing.expect(std.mem.find(u8, g.remedy, "ADR") == null);
    }
}
