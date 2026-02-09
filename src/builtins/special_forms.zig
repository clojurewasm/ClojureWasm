// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

// Special form definitions — BuiltinDef metadata for compiler-handled forms.
//
// Special forms are handled directly by the Compiler/Analyzer and have
// no runtime function implementation. They are registered as Vars in
// clojure.core so that (doc if), (meta #'if) etc. work correctly.

const var_mod = @import("../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;

/// Special forms registered in clojure.core.
/// These have kind = .special_form and no runtime function.
pub const builtins = [_]BuiltinDef{
    .{
        .name = "if",
        .doc = "Evaluates test. If not the singular values nil or false, evaluates and yields then, otherwise evaluates and yields else. If else is not supplied it defaults to nil.",
        .arglists = "([test then] [test then else])",
        .added = "1.0",
    },
    .{
        .name = "do",
        .doc = "Evaluates the expressions in order and returns the value of the last. If no expressions are supplied, returns nil.",
        .arglists = "([& exprs])",
        .added = "1.0",
    },
    .{
        .name = "let*",
        .doc = "binding => binding-form init-expr. Evaluates the exprs in a lexical context in which the symbols in the binding-forms are bound to their respective init-exprs or parts therein.",
        .arglists = "([bindings & body])",
        .added = "1.0",
    },
    .{
        .name = "fn*",
        .doc = "params => positional-params*, or positional-params* & rest-param. Defines a function (fn).",
        .arglists = "([& sigs])",
        .added = "1.0",
    },
    .{
        .name = "def",
        .doc = "Creates and interns a global var with the name of symbol in the current namespace.",
        .arglists = "([symbol] [symbol init] [symbol doc-string init])",
        .added = "1.0",
    },
    .{
        .name = "quote",
        .doc = "Yields the unevaluated form.",
        .arglists = "([form])",
        .added = "1.0",
    },
    .{
        .name = "var",
        .doc = "The symbol must resolve to a var, and the Var object itself (not its value) is returned.",
        .arglists = "([symbol])",
        .added = "1.0",
    },
    .{
        .name = "loop*",
        .doc = "Evaluates the exprs in a lexical context in which the symbols in the binding-forms are bound to their respective init-exprs or parts therein. Acts as a recur target.",
        .arglists = "([bindings & body])",
        .added = "1.0",
    },
    .{
        .name = "recur",
        .doc = "Evaluates the exprs in order, then, in parallel, rebinds the bindings of the recursion point to the values of the exprs.",
        .arglists = "([& exprs])",
        .added = "1.0",
    },
    .{
        .name = "throw",
        .doc = "Throw an exception.",
        .arglists = "([expr])",
        .added = "1.0",
    },
    .{
        .name = "try",
        .doc = "catch-clause => (catch classname name expr*). finally-clause => (finally expr*). Catches and handles exceptions.",
        .arglists = "([expr* catch-clause* finally-clause?])",
        .added = "1.0",
    },
    .{
        .name = "set!",
        .doc = "Assignment special form. Sets the value of a thread-local binding.",
        .arglists = "([var-symbol expr])",
        .added = "1.0",
    },
    .{
        .name = "defmacro",
        .doc = "Like defn, but the resulting function name is declared as a macro and will be used as a macro by the compiler when it is called.",
        .arglists = "([name doc-string? attr-map? [params*] body] [name doc-string? attr-map? ([params*] body) + attr-map?])",
        .added = "1.0",
    },
};

// === Tests ===

const std = @import("std");

test "special_forms table has 13 entries" {
    try std.testing.expectEqual(13, builtins.len);
}

test "special_forms all have no func (compiler-handled)" {
    for (builtins) |b| {
        try std.testing.expect(b.func == null);
    }
}

test "special_forms have doc strings" {
    for (builtins) |b| {
        try std.testing.expect(b.doc != null);
        try std.testing.expect(b.arglists != null);
    }
}

test "special_forms no duplicate names" {
    comptime {
        for (builtins, 0..) |a, i| {
            for (builtins[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a.name, b.name)) {
                    @compileError("duplicate special form: " ++ a.name);
                }
            }
        }
    }
}

test "special_forms comptime lookup for if" {
    const found = comptime blk: {
        for (&builtins) |b| {
            if (std.mem.eql(u8, b.name, "if")) break :blk b;
        }
        @compileError("if not found");
    };
    try std.testing.expectEqualStrings("if", found.name);
    try std.testing.expect(found.func == null);
}
