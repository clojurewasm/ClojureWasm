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
const md = @import("../macro_dispatch.zig");
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;

pub const ExpandError = error_mod.ClojureWasmError || error{OutOfMemory};

const GensymMap = std.StringHashMap([]const u8);

/// Expand one `.syntax_quote` inner form into its template Form.
pub fn expand(arena: std.mem.Allocator, rt: *Runtime, form: Form, loc: SourceLocation) ExpandError!Form {
    var gmap = GensymMap.init(arena);
    return try walk(arena, rt, form, &gmap, loc);
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
fn seqConcat(arena: std.mem.Allocator, rt: *Runtime, items: []const Form, gmap: *GensymMap, loc: SourceLocation) ExpandError!Form {
    const builders = try arena.alloc(Form, items.len);
    for (items, 0..) |it, i| {
        if (it.data == .unquote_splicing) {
            builders[i] = it.data.unquote_splicing.*;
        } else {
            builders[i] = try call(arena, "list", &[_]Form{try walk(arena, rt, it, gmap, loc)}, loc);
        }
    }
    const concat = try call(arena, "concat", builders, loc);
    return try call(arena, "seq", &[_]Form{concat}, loc);
}

fn walk(arena: std.mem.Allocator, rt: *Runtime, form: Form, gmap: *GensymMap, loc: SourceLocation) ExpandError!Form {
    return switch (form.data) {
        // `~x` → the inner code, evaluated in place.
        .unquote => |inner| inner.*,
        // `~@x` outside a collection has nothing to splice into.
        .unquote_splicing => error_catalog.raise(.token_invalid, form.location, .{ .token = "~@ (unquote-splicing outside a list/vector/set)" }),
        // Nested `` ` `` — flatten by expanding the inner template (approximation;
        // full depth-counted nesting is a stage-2 refinement).
        .syntax_quote => |inner| try walk(arena, rt, inner.*, gmap, loc),
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
            break :blk try quoted(arena, form, form.location); // bare symbol (stage 1)
        },
        // `(…)` → (seq (concat …)); empty → `(list)` = ().
        .list => |items| if (items.len == 0)
            try call(arena, "list", &.{}, loc)
        else
            try seqConcat(arena, rt, items, gmap, loc),
        // `[…]` → (vec (seq (concat …))); empty → `[]`.
        .vector => |items| if (items.len == 0)
            md.makeVector(arena, &.{}, loc)
        else
            try call(arena, "vec", &[_]Form{try seqConcat(arena, rt, items, gmap, loc)}, loc),
        // `{…}` → (apply hash-map (seq (concat <flat k/v>))); empty → `(hash-map)`.
        .map => |items| try call(arena, "apply", &[_]Form{
            md.makeSymbol("hash-map", loc),
            if (items.len == 0) try call(arena, "list", &.{}, loc) else try seqConcat(arena, rt, items, gmap, loc),
        }, loc),
        // `#{…}` → (apply hash-set (seq (concat …))); empty → `(hash-set)`.
        .set => |items| try call(arena, "apply", &[_]Form{
            md.makeSymbol("hash-set", loc),
            if (items.len == 0) try call(arena, "list", &.{}, loc) else try seqConcat(arena, rt, items, gmap, loc),
        }, loc),
        // Self-evaluating literals (numbers, strings, keywords, nil, bool, …)
        // pass through — `` `5 `` → 5, `` `:k `` → :k.
        else => form,
    };
}
