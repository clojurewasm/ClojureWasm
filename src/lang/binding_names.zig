// SPDX-License-Identifier: EPL-2.0
//! Which local names a binding form introduces.
//!
//! A binding form is what `fn*` / `let` / a deftype method accepts in a
//! parameter position: a bare symbol, or a vector / map destructuring
//! pattern. The deftype / defrecord lowering
//! (`macro_transforms.zig::wrapMethodBodyWithFields`) asks this module
//! whether a method parameter binds a field's name: if it does, the field
//! must NOT be re-bound around the body, or the field would shadow the
//! parameter (JVM: the parameter wins, `(m [_ {:keys [a]}] a)` answers the
//! destructured `a`).

const std = @import("std");
const Form = @import("../eval/form.zig").Form;

/// True iff the binding form `b` binds the unqualified local `name`.
///
/// Symbols bind themselves. A vector binds whatever its elements bind (`&`
/// and `:as` are markers that bind nothing; the symbol after `:as` binds
/// itself). A map binds `:keys` / `:strs` / `:syms` entries by their name
/// part (`:keys [a ns/b :c]` binds a, b and c), its `:as` symbol, and every
/// non-keyword key as a nested binding form (`{x :k}`, `{[a b] :k}`).
/// `:or` holds defaults for names bound elsewhere and binds nothing.
pub fn binds(b: Form, name: []const u8) bool {
    switch (b.data) {
        .symbol => |s| return s.ns == null and std.mem.eql(u8, s.name, name),
        .vector => |items| {
            for (items) |it| if (binds(it, name)) return true;
            return false;
        },
        .map => |kvs| {
            var i: usize = 0;
            while (i + 1 < kvs.len) : (i += 2) {
                const k = kvs[i];
                const v = kvs[i + 1];
                if (k.data != .keyword) {
                    if (binds(k, name)) return true;
                    continue;
                }
                const kn = k.data.keyword.name;
                if (isNameListKey(kn)) {
                    if (v.data == .vector and nameListBinds(v.data.vector, name)) return true;
                } else if (std.mem.eql(u8, kn, "as")) {
                    if (binds(v, name)) return true;
                }
            }
            return false;
        },
        else => return false,
    }
}

/// `:keys` / `:strs` / `:syms`, plain or ns-qualified (`:ns/keys`).
fn isNameListKey(kn: []const u8) bool {
    return std.mem.eql(u8, kn, "keys") or std.mem.eql(u8, kn, "strs") or
        std.mem.eql(u8, kn, "syms");
}

fn nameListBinds(entries: []const Form, name: []const u8) bool {
    for (entries) |e| {
        const en = switch (e.data) {
            .symbol => |s| s.name,
            .keyword => |kw| kw.name,
            else => continue,
        };
        if (std.mem.eql(u8, en, name)) return true;
    }
    return false;
}

// --- tests ---

fn tsym(name: []const u8) Form {
    return .{ .data = .{ .symbol = .{ .name = name } } };
}
fn tkw(name: []const u8) Form {
    return .{ .data = .{ .keyword = .{ .name = name } } };
}

test "a plain symbol param binds its own name" {
    try std.testing.expect(binds(tsym("a"), "a"));
    try std.testing.expect(!binds(tsym("b"), "a"));
}

test "a :keys map param binds each listed name" {
    const keys = [_]Form{ tsym("theta"), tsym("omega") };
    const m = [_]Form{ tkw("keys"), .{ .data = .{ .vector = &keys } } };
    const f: Form = .{ .data = .{ .map = &m } };
    try std.testing.expect(binds(f, "theta"));
    try std.testing.expect(binds(f, "omega"));
    try std.testing.expect(!binds(f, "length"));
}

test "a map param binds :as and nested keys but not :or defaults" {
    const or_m = [_]Form{ tsym("z"), .{ .data = .{ .integer = 1 } } };
    const m = [_]Form{
        tsym("x"), tkw("x"),
        tkw("as"), tsym("whole"),
        tkw("or"), .{ .data = .{ .map = &or_m } },
    };
    const f: Form = .{ .data = .{ .map = &m } };
    try std.testing.expect(binds(f, "x"));
    try std.testing.expect(binds(f, "whole"));
    try std.testing.expect(!binds(f, "z"));
}

test "a vector param binds its elements, including after & and :as" {
    const v = [_]Form{ tsym("a"), tsym("&"), tsym("more"), tkw("as"), tsym("all") };
    const f: Form = .{ .data = .{ .vector = &v } };
    try std.testing.expect(binds(f, "a"));
    try std.testing.expect(binds(f, "more"));
    try std.testing.expect(binds(f, "all"));
    try std.testing.expect(!binds(f, "b"));
}
