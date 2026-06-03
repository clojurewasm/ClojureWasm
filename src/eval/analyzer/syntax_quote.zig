// SPDX-License-Identifier: EPL-2.0
//! Syntax-quote expander (ADR-0082). The reader produces `.syntax_quote` /
//! `.unquote` / `.unquote_splicing` Form nodes; this turns a `.syntax_quote`
//! tree into a template Form (the `(seq (concat …))` build shape clj uses) that
//! the analyzer then analyzes normally.
//!
//! D-226 STAGE 1 — NON-QUALIFYING: a symbol stays bare (`` `foo `` →
//! `(quote foo)`), so single-ns + core-symbol macros work but a backtick
//! reference to another ns's private helper does not (D-226 stays open; the
//! qualification pass is stage 2). `foo#` auto-gensym is consistent within one
//! syntax-quote (a per-`expand` name map).

const std = @import("std");
const form_mod = @import("../form.zig");
const Form = form_mod.Form;
const SymbolRef = form_mod.SymbolRef;
const md = @import("../macro_dispatch.zig");
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;

pub const ExpandError = error_mod.ClojureWasmError || error{OutOfMemory};

const GensymMap = std.StringHashMap([]const u8);

/// Symbols syntax-quote leaves BARE (never ns-qualified), mirroring clj: the
/// analyzer special forms + `catch`/`finally` (analyzed inside `try`) + the
/// rest marker `&`. Interop / class symbols (containing `.`) are also kept bare
/// (handled separately by `hasDot`). Kept in sync with `analyzer.SPECIAL_FORMS`
/// (a local copy because analyzer ↔ syntax_quote is a circular import).
const BARE_SYMS = std.StaticStringMap(void).initComptime(.{
    .{"def"},        .{"defmacro"}, .{"if"},     .{"do"},      .{"quote"},
    .{"var"},        .{"fn*"},      .{"let*"},   .{"letfn*"},  .{"loop*"},
    .{"recur"},      .{"binding"},  .{"try"},    .{"throw"},   .{"in-ns"},
    .{"require"},    .{"ns"},       .{"catch"},  .{"finally"}, .{"&"},
    .{"new"},        .{"set!"},     .{"."},
});

fn hasDot(name: []const u8) bool {
    return std.mem.findScalar(u8, name, '.') != null;
}

/// Expand one `.syntax_quote` inner form into its template Form.
pub fn expand(arena: std.mem.Allocator, rt: *Runtime, env: *Env, form: Form, loc: SourceLocation) ExpandError!Form {
    var gmap = GensymMap.init(arena);
    return try walk(arena, rt, env, form, &gmap, loc);
}

/// Resolve a bare symbol to its ns-qualified syntax-quote form (clj hygiene,
/// ADR-0082 stage 2). Special forms / interop / `&` stay bare; an
/// already-qualified symbol keeps its ns; otherwise resolve against the current
/// ns — a referred/aliased var qualifies to its HOME ns (`+` → `clojure.core/+`),
/// an unresolved name to the current ns (`foo` → `user/foo`, so a macro can
/// reference its own private helper).
fn qualifySym(env: *Env, s: SymbolRef, loc: SourceLocation) Form {
    if (s.ns != null or BARE_SYMS.has(s.name) or hasDot(s.name) or (s.name.len > 0 and s.name[0] == '.'))
        return .{ .data = .{ .symbol = s }, .location = loc };
    const cur = env.current_ns orelse return .{ .data = .{ .symbol = s }, .location = loc };
    var home = if (cur.resolve(s.name)) |v|
        v.ns.name
    else if (s.name.len > 0 and s.name[0] >= 'A' and s.name[0] <= 'Z')
        // An unresolved capitalized symbol is a class name (`Throwable`,
        // `String`); cljw uses simple host-class names (AD-003), so keep it
        // BARE rather than qualifying to the current ns (clj FQCNs it, but a
        // cljw catch / interop matches the simple name).
        return .{ .data = .{ .symbol = s }, .location = loc }
    else
        cur.name;
    // cljw's `rt` ns is the implementation home of what clj calls `clojure.core`
    // (primitives are interned in `rt` + referred everywhere; `clojure.core/+`
    // also resolves). Present them as `clojure.core/…` so a syntax-quoted core
    // symbol matches clj (`` `+ `` → clojure.core/+, not rt/+).
    if (std.mem.eql(u8, home, "rt")) home = "clojure.core";
    return .{ .data = .{ .symbol = .{ .ns = home, .name = s.name } }, .location = loc };
}

fn call(arena: std.mem.Allocator, name: []const u8, args: []const Form, loc: SourceLocation) ExpandError!Form {
    const items = try arena.alloc(Form, args.len + 1);
    items[0] = md.makeSymbol(name, loc);
    @memcpy(items[1..], args);
    return md.makeList(arena, items, loc);
}

fn quoted(arena: std.mem.Allocator, inner: Form, loc: SourceLocation) ExpandError!Form {
    return call(arena, "quote", &[_]Form{inner}, loc);
}

/// `(seq (concat <builders>))` where each non-splice item is wrapped `(list …)`
/// and a `~@x` item contributes `x` directly. Empty → the right empty literal
/// is the caller's job (clj `` `() `` → `()`).
fn seqConcat(arena: std.mem.Allocator, rt: *Runtime, env: *Env, items: []const Form, gmap: *GensymMap, loc: SourceLocation) ExpandError!Form {
    const builders = try arena.alloc(Form, items.len);
    for (items, 0..) |it, i| {
        if (it.data == .unquote_splicing) {
            builders[i] = it.data.unquote_splicing.*;
        } else {
            builders[i] = try call(arena, "list", &[_]Form{try walk(arena, rt, env, it, gmap, loc)}, loc);
        }
    }
    const concat = try call(arena, "concat", builders, loc);
    return try call(arena, "seq", &[_]Form{concat}, loc);
}

fn walk(arena: std.mem.Allocator, rt: *Runtime, env: *Env, form: Form, gmap: *GensymMap, loc: SourceLocation) ExpandError!Form {
    return switch (form.data) {
        // `~x` → the inner code, evaluated in place.
        .unquote => |inner| inner.*,
        // `~@x` outside a collection has nothing to splice into.
        .unquote_splicing => error_catalog.raise(.token_invalid, form.location, .{ .token = "~@ (unquote-splicing outside a list/vector/set)" }),
        // Nested `` ` `` — flatten by expanding the inner template (approximation;
        // full depth-counted nesting is a stage-2 refinement).
        .syntax_quote => |inner| try walk(arena, rt, env, inner.*, gmap, loc),
        .symbol => |s| blk: {
            // `foo#` auto-gensym (unqualified only): one stable name per syntax-quote.
            if (s.ns == null and s.name.len > 1 and s.name[s.name.len - 1] == '#') {
                const g = gmap.get(s.name) orelse g2: {
                    const name = try rt.gensym(arena, s.name[0 .. s.name.len - 1]);
                    try gmap.put(s.name, name);
                    break :g2 name;
                };
                break :blk try quoted(arena, md.makeSymbol(g, form.location), form.location);
            }
            // Stage 2: qualify to the symbol's ns (clj hygiene).
            break :blk try quoted(arena, qualifySym(env, s, form.location), form.location);
        },
        // `(…)` → (seq (concat …)); empty → `(list)` = ().
        .list => |items| if (items.len == 0)
            try call(arena, "list", &.{}, loc)
        else
            try seqConcat(arena, rt, env, items, gmap, loc),
        // `[…]` → (vec (seq (concat …))); empty → `[]`.
        .vector => |items| if (items.len == 0)
            md.makeVector(arena, &.{}, loc)
        else
            try call(arena, "vec", &[_]Form{try seqConcat(arena, rt, env, items, gmap, loc)}, loc),
        // `{…}` → (apply hash-map (seq (concat <flat k/v>))); empty → `(hash-map)`.
        .map => |items| try call(arena, "apply", &[_]Form{
            md.makeSymbol("hash-map", loc),
            if (items.len == 0) try call(arena, "list", &.{}, loc) else try seqConcat(arena, rt, env, items, gmap, loc),
        }, loc),
        // `#{…}` → (apply hash-set (seq (concat …))); empty → `(hash-set)`.
        .set => |items| try call(arena, "apply", &[_]Form{
            md.makeSymbol("hash-set", loc),
            if (items.len == 0) try call(arena, "list", &.{}, loc) else try seqConcat(arena, rt, env, items, gmap, loc),
        }, loc),
        // Self-evaluating literals (numbers, strings, keywords, nil, bool, …)
        // pass through — `` `5 `` → 5, `` `:k `` → :k.
        else => form,
    };
}
