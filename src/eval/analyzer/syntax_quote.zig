// SPDX-License-Identifier: EPL-2.0
//! Syntax-quote expander (ADR-0082). The reader produces `.syntax_quote` /
//! `.unquote` / `.unquote_splicing` Form nodes; this turns a `.syntax_quote`
//! tree into a template Form (the `(seq (concat …))` build shape clj uses) that
//! the analyzer then analyzes normally.
//!
//! A bare symbol is ns-qualified to its home ns (`qualifySym`, clj
//! hygiene): a referred/aliased var qualifies to its home (`+` →
//! `clojure.core/+`), an unresolved name to the current ns (`foo` →
//! `user/foo`), so a macro can reference another ns's private helper.
//! Special forms / interop / `&` / capitalized class names stay bare.
//! `foo#` auto-gensym is consistent within one syntax-quote (a
//! per-`expand` name map).

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
    .{"def"},     .{"defmacro"}, .{"if"},    .{"do"},      .{"quote"},
    .{"var"},     .{"fn*"},      .{"let*"},  .{"letfn*"},  .{"loop*"},
    .{"recur"},   .{"binding"},  .{"try"},   .{"throw"},   .{"in-ns"},
    .{"require"}, .{"ns"},       .{"catch"}, .{"finally"}, .{"&"},
    .{"new"},     .{"set!"},     .{"."},
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
    if (s.ns) |ns_name| {
        // An aliased ns prefix (`str/join` where `str` is `(:require … :as str)`)
        // resolves to the alias target's full name — clj syntax-quote hygiene
        // (`` `str/join `` → `clojure.string/join`), so a macro template's
        // alias-qualified call still resolves wherever the macro is expanded
        // (the hiccup.core `html` → `hiccup2.core/html` case). A real ns name or
        // an unknown prefix is left as-is.
        if (env.current_ns) |cur| {
            if (cur.aliases.get(ns_name)) |aliased|
                return .{ .data = .{ .symbol = .{ .ns = aliased.name, .name = s.name } }, .location = loc };
        }
        return .{ .data = .{ .symbol = s }, .location = loc };
    }
    // `%`-prefixed names are anon-fn params (`#(…)` lowers to `(fn* [%1 %2] …)`
    // at read time); like `&`, they must stay BARE so a syntax-quoted `#()` in a
    // macro template (hiccup's `#(.append sb# %)`) does not qualify them into an
    // invalid `user/%1` fn* parameter.
    if (BARE_SYMS.has(s.name) or hasDot(s.name) or (s.name.len > 0 and (s.name[0] == '.' or s.name[0] == '%')))
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

/// Like `call`, but the head is a FULLY-QUALIFIED `clojure.core/<name>` so the
/// syntax-quote build machinery (list/concat/seq/vec/apply/hash-map/hash-set) is
/// immune to a user `(:refer-clojure :exclude [vec …])` (D-296). Matches clj,
/// whose syntax-quote emits `clojure.core/*` for its reconstruction fns. (`quote`
/// stays bare — it is a special form, not a core var.)
fn coreCall(arena: std.mem.Allocator, name: []const u8, args: []const Form, loc: SourceLocation) ExpandError!Form {
    const items = try arena.alloc(Form, args.len + 1);
    items[0] = coreSym(name, loc);
    @memcpy(items[1..], args);
    return md.makeList(arena, items, loc);
}

fn coreSym(name: []const u8, loc: SourceLocation) Form {
    return .{ .data = .{ .symbol = .{ .ns = "clojure.core", .name = name } }, .location = loc };
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
            builders[i] = try coreCall(arena, "list", &[_]Form{try walk(arena, rt, env, it, gmap, loc)}, loc);
        }
    }
    const concat = try coreCall(arena, "concat", builders, loc);
    return try coreCall(arena, "seq", &[_]Form{concat}, loc);
}

fn walk(arena: std.mem.Allocator, rt: *Runtime, env: *Env, form: Form, gmap: *GensymMap, loc: SourceLocation) ExpandError!Form {
    return switch (form.data) {
        // `~x` → the inner code, evaluated in place.
        .unquote => |inner| inner.*,
        // `~@x` outside a collection has nothing to splice into.
        .unquote_splicing => error_catalog.raise(.token_invalid, form.location, .{ .token = "~@ (unquote-splicing outside a list/vector/set)" }),
        // Nested `` ` `` (ADR-0082 / D-228): clj expands an inner syntax-quote at
        // read time into its `(seq (concat …))` build form, then the OUTER
        // syntax-quote walks THAT build form as ordinary data — so an inner `~` is
        // consumed at the INNER level and its expression is PRESERVED as data at
        // the outer level (`` `(a `(b ~(+ 1 2))) `` keeps `(+ 1 2)` unevaluated,
        // re-qualified to `clojure.core/+`), not flattened/evaluated. Match it:
        // expand the inner with a FRESH gensym scope (each backtick is its own
        // `foo#` scope, clj parity) into its build form, then re-walk that build
        // form at this (outer) level so its symbols/forms become outer data.
        .syntax_quote => |inner| blk: {
            var inner_gmap = GensymMap.init(arena);
            const inner_expanded = try walk(arena, rt, env, inner.*, &inner_gmap, loc);
            break :blk try walk(arena, rt, env, inner_expanded, gmap, loc);
        },
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
        // `(…)` → (seq (concat …)); empty → `(list)` = (). Machinery fns are
        // clojure.core-qualified (D-296) so a user :exclude can't break them.
        .list => |items| if (items.len == 0)
            try coreCall(arena, "list", &.{}, loc)
        else
            try seqConcat(arena, rt, env, items, gmap, loc),
        // `[…]` → (vec (seq (concat …))); empty → `[]`.
        .vector => |items| if (items.len == 0)
            md.makeVector(arena, &.{}, loc)
        else
            try coreCall(arena, "vec", &[_]Form{try seqConcat(arena, rt, env, items, gmap, loc)}, loc),
        // `{…}` → (apply hash-map (seq (concat <flat k/v>))); empty → `(hash-map)`.
        .map => |items| try coreCall(arena, "apply", &[_]Form{
            coreSym("hash-map", loc),
            if (items.len == 0) try coreCall(arena, "list", &.{}, loc) else try seqConcat(arena, rt, env, items, gmap, loc),
        }, loc),
        // `#{…}` → (apply hash-set (seq (concat …))); empty → `(hash-set)`.
        .set => |items| try coreCall(arena, "apply", &[_]Form{
            coreSym("hash-set", loc),
            if (items.len == 0) try coreCall(arena, "list", &.{}, loc) else try seqConcat(arena, rt, env, items, gmap, loc),
        }, loc),
        // Self-evaluating literals (numbers, strings, keywords, nil, bool, …)
        // pass through — `` `5 `` → 5, `` `:k `` → :k.
        else => form,
    };
}
