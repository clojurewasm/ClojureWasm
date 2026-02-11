// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Var — Clojure variable with root binding and dynamic binding support.
//!
//! Global variables qualified by namespace. Supports root binding,
//! dynamic (thread-local) bindings, and metadata flags.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const Symbol = value.Symbol;
const err_mod = @import("error.zig");

/// Builtin function signature: re-exported from value.zig to avoid circular dependency.
pub const BuiltinFn = value.BuiltinFn;

/// Metadata definition for builtin functions/macros.
pub const BuiltinDef = struct {
    /// Function/macro name (e.g. "+", "map", "if").
    name: []const u8,
    /// Runtime function pointer (null for special forms and vm_intrinsics).
    func: ?BuiltinFn = null,
    /// Docstring (Clojure :doc metadata).
    doc: ?[]const u8 = null,
    /// Argument list display string (e.g. "([] [x] [x y & more])").
    arglists: ?[]const u8 = null,
    /// Clojure version when added (e.g. "1.0").
    added: ?[]const u8 = null,
    /// ClojureWasm version when added.
    since_cw: ?[]const u8 = null,
};

/// Var — Clojure variable bound to a namespace-qualified symbol.
pub const Var = struct {
    /// Variable name (symbol).
    sym: Symbol,

    /// Owning namespace name.
    ns_name: []const u8,

    /// Root binding (global value).
    root: Value = Value.nil_val,

    /// ^:dynamic flag.
    dynamic: bool = false,

    /// ^:macro flag.
    macro: bool = false,

    /// ^:private flag.
    private: bool = false,

    /// ^:const flag (compile-time inlining).
    is_const: bool = false,

    /// Docstring (Clojure :doc metadata).
    doc: ?[]const u8 = null,

    /// Argument list display string (Clojure :arglists metadata).
    arglists: ?[]const u8 = null,

    /// Clojure version when added (Clojure :added metadata).
    added: ?[]const u8 = null,

    /// ClojureWasm version when added.
    since_cw: ?[]const u8 = null,

    /// Source file where this var was defined.
    file: ?[]const u8 = null,

    /// Source line number where this var was defined.
    line: u32 = 0,

    /// Source column number where this var was defined.
    column: u32 = 0,

    /// User-defined metadata map (mutable via alter-meta! / reset-meta!).
    meta: ?*value.PersistentArrayMap = null,

    /// Dereference: return the current value.
    /// When dynamic, checks thread binding stack first.
    pub fn deref(self: *const Var) Value {
        if (self.dynamic) {
            if (getThreadBinding(self)) |val| return val;
        }
        return self.root;
    }

    /// Return root value directly (bypass thread bindings).
    pub fn getRawRoot(self: *const Var) Value {
        return self.root;
    }

    /// Set root binding.
    pub fn bindRoot(self: *Var, v: Value) void {
        self.root = v;
    }

    pub fn isDynamic(self: *const Var) bool {
        return self.dynamic;
    }

    pub fn isMacro(self: *const Var) bool {
        return self.macro;
    }

    pub fn setMacro(self: *Var, is_macro: bool) void {
        self.macro = is_macro;
    }

    pub fn isPrivate(self: *const Var) bool {
        return self.private;
    }

    /// Apply metadata from a BuiltinDef to this Var.
    pub fn applyBuiltinDef(self: *Var, def: BuiltinDef) void {
        self.doc = def.doc;
        self.arglists = def.arglists;
        self.added = def.added;
        self.since_cw = def.since_cw;
    }

    /// Return fully qualified name (e.g. "clojure.core/map").
    pub fn qualifiedName(self: *const Var, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.ns_name, self.sym.name }) catch self.sym.name;
    }
};

// === Dynamic Binding (single-thread, Wasm target) ===

/// Binding entry: Var -> Value.
pub const BindingEntry = struct {
    var_ptr: *Var,
    val: Value,
};

/// Binding frame (push/pop unit).
pub const BindingFrame = struct {
    entries: []BindingEntry,
    prev: ?*BindingFrame,
};

/// Per-thread binding stack. Each thread has its own binding frame chain.
/// (Phase 48: was global var, now threadlocal for concurrency.)
threadlocal var current_frame: ?*BindingFrame = null;

/// Return the current binding frame (for GC root traversal).
pub fn getCurrentBindingFrame() ?*BindingFrame {
    return current_frame;
}

/// Set the current binding frame (for thread pool binding conveyance).
pub fn setCurrentBindingFrame(frame: ?*BindingFrame) void {
    current_frame = frame;
}

/// Push a new binding frame.
pub fn pushBindings(frame: *BindingFrame) void {
    frame.prev = current_frame;
    current_frame = frame;
}

/// Pop the current binding frame.
pub fn popBindings() void {
    if (current_frame) |f| {
        current_frame = f.prev;
    }
}

/// Look up a dynamic binding for a Var in the frame stack.
pub fn getThreadBinding(v: *const Var) ?Value {
    var frame = current_frame;
    while (frame) |f| {
        for (f.entries) |e| {
            if (e.var_ptr == @as(*Var, @constCast(v))) return e.val;
        }
        frame = f.prev;
    }
    return null;
}

/// set! — mutate the current frame's binding for a Var.
pub fn setThreadBinding(v: *Var, new_val: Value) !void {
    var frame = current_frame;
    while (frame) |f| {
        for (f.entries) |*e| {
            if (e.var_ptr == v) {
                e.val = new_val;
                return;
            }
        }
        frame = f.prev;
    }
    return err_mod.setErrorFmt(.eval, .value_error, .{}, "Can't change/establish root binding of: {s}", .{v.sym.name});
}

/// Check if a Var has a thread binding.
pub fn hasThreadBinding(v: *const Var) bool {
    return getThreadBinding(v) != null;
}

// === Tests ===

test "Var basic root binding" {
    var v = Var{
        .sym = .{ .name = "foo", .ns = null },
        .ns_name = "user",
    };

    // Default root is nil
    try std.testing.expect(v.deref().isNil());

    // Bind root
    v.bindRoot(Value.initInteger(42));
    try std.testing.expect(v.deref().eql(Value.initInteger(42)));
}

test "Var flags" {
    var v = Var{
        .sym = .{ .name = "*debug*", .ns = null },
        .ns_name = "user",
        .dynamic = true,
        .private = true,
    };

    try std.testing.expect(v.isDynamic());
    try std.testing.expect(v.isPrivate());
    try std.testing.expect(!v.isMacro());

    v.setMacro(true);
    try std.testing.expect(v.isMacro());
}

test "Var dynamic binding push/pop" {
    var v = Var{
        .sym = .{ .name = "*x*", .ns = null },
        .ns_name = "user",
        .dynamic = true,
    };
    v.bindRoot(Value.initInteger(1));

    // No binding -> root
    try std.testing.expect(v.deref().eql(Value.initInteger(1)));
    try std.testing.expect(!hasThreadBinding(&v));

    // Push binding
    var entries = [_]BindingEntry{.{ .var_ptr = &v, .val = Value.initInteger(10) }};
    var frame = BindingFrame{ .entries = &entries, .prev = null };
    pushBindings(&frame);

    try std.testing.expect(v.deref().eql(Value.initInteger(10)));
    try std.testing.expect(hasThreadBinding(&v));

    // Pop -> back to root
    popBindings();
    try std.testing.expect(v.deref().eql(Value.initInteger(1)));
    try std.testing.expect(!hasThreadBinding(&v));
}

test "Var dynamic binding nested" {
    var x = Var{ .sym = .{ .name = "*x*", .ns = null }, .ns_name = "user", .dynamic = true };
    var y = Var{ .sym = .{ .name = "*y*", .ns = null }, .ns_name = "user", .dynamic = true };
    x.bindRoot(Value.initInteger(1));
    y.bindRoot(Value.initInteger(2));

    var entries1 = [_]BindingEntry{.{ .var_ptr = &x, .val = Value.initInteger(10) }};
    var frame1 = BindingFrame{ .entries = &entries1, .prev = null };
    pushBindings(&frame1);

    var entries2 = [_]BindingEntry{.{ .var_ptr = &y, .val = Value.initInteger(20) }};
    var frame2 = BindingFrame{ .entries = &entries2, .prev = null };
    pushBindings(&frame2);

    try std.testing.expect(x.deref().eql(Value.initInteger(10)));
    try std.testing.expect(y.deref().eql(Value.initInteger(20)));

    popBindings();
    try std.testing.expect(x.deref().eql(Value.initInteger(10)));
    try std.testing.expect(y.deref().eql(Value.initInteger(2)));

    popBindings();
    try std.testing.expect(x.deref().eql(Value.initInteger(1)));
    try std.testing.expect(y.deref().eql(Value.initInteger(2)));
}

test "Var set! within binding" {
    var v = Var{ .sym = .{ .name = "*x*", .ns = null }, .ns_name = "user", .dynamic = true };
    v.bindRoot(Value.initInteger(1));

    var entries = [_]BindingEntry{.{ .var_ptr = &v, .val = Value.initInteger(10) }};
    var frame = BindingFrame{ .entries = &entries, .prev = null };
    pushBindings(&frame);

    try setThreadBinding(&v, Value.initInteger(99));
    try std.testing.expect(v.deref().eql(Value.initInteger(99)));

    popBindings();
    // Root unchanged
    try std.testing.expect(v.deref().eql(Value.initInteger(1)));
}

test "Var set! outside binding is error" {
    var v = Var{ .sym = .{ .name = "*x*", .ns = null }, .ns_name = "user", .dynamic = true };
    v.bindRoot(Value.initInteger(1));

    try std.testing.expectError(error.ValueError, setThreadBinding(&v, Value.initInteger(99)));
}

test "BuiltinDef creation" {
    const def = BuiltinDef{
        .name = "+",
        .doc = "Returns the sum of nums. (+) returns 0.",
        .arglists = "([] [x] [x y] [x y & more])",
        .added = "1.0",
        .since_cw = "0.1.0",
    };

    try std.testing.expectEqualStrings("+", def.name);
    try std.testing.expectEqualStrings("Returns the sum of nums. (+) returns 0.", def.doc.?);
    try std.testing.expectEqualStrings("([] [x] [x y] [x y & more])", def.arglists.?);
    try std.testing.expectEqualStrings("1.0", def.added.?);
    try std.testing.expectEqualStrings("0.1.0", def.since_cw.?);
}

test "BuiltinDef optional fields default to null" {
    const def = BuiltinDef{
        .name = "if",
    };

    try std.testing.expectEqualStrings("if", def.name);
    try std.testing.expect(def.doc == null);
    try std.testing.expect(def.arglists == null);
    try std.testing.expect(def.added == null);
    try std.testing.expect(def.since_cw == null);
}

test "Var metadata fields" {
    const v = Var{
        .sym = .{ .name = "map", .ns = null },
        .ns_name = "clojure.core",
        .doc = "Returns a lazy sequence...",
        .arglists = "([f] [f coll] [f c1 c2] [f c1 c2 c3] [f c1 c2 c3 & colls])",
        .added = "1.0",
        .since_cw = "0.1.0",
    };

    try std.testing.expectEqualStrings("Returns a lazy sequence...", v.doc.?);
    try std.testing.expectEqualStrings("1.0", v.added.?);
    try std.testing.expectEqualStrings("0.1.0", v.since_cw.?);

    // Default: all metadata null
    const v2 = Var{
        .sym = .{ .name = "x", .ns = null },
        .ns_name = "user",
    };
    try std.testing.expect(v2.doc == null);
    try std.testing.expect(v2.arglists == null);
    try std.testing.expect(v2.added == null);
    try std.testing.expect(v2.since_cw == null);
}

test "Var applyBuiltinDef transfers metadata" {
    const def = BuiltinDef{
        .name = "+",
        .doc = "Returns the sum of nums.",
        .arglists = "([] [x] [x y] [x y & more])",
        .added = "1.0",
        .since_cw = "0.1.0",
    };

    var v = Var{
        .sym = .{ .name = "+", .ns = null },
        .ns_name = "clojure.core",
    };

    // Before: defaults
    try std.testing.expect(v.doc == null);

    v.applyBuiltinDef(def);

    // After: metadata transferred
    try std.testing.expectEqualStrings("Returns the sum of nums.", v.doc.?);
    try std.testing.expectEqualStrings("([] [x] [x y] [x y & more])", v.arglists.?);
    try std.testing.expectEqualStrings("1.0", v.added.?);
    try std.testing.expectEqualStrings("0.1.0", v.since_cw.?);
}

test "BuiltinDef comptime table" {
    const builtins = [_]BuiltinDef{
        .{ .name = "+", .doc = "Returns the sum of nums.", .added = "1.0" },
        .{ .name = "-", .doc = "Subtraction.", .added = "1.0" },
        .{ .name = "if" },
        .{ .name = "map", .doc = "Returns a lazy sequence.", .added = "1.0" },
        .{ .name = "defn", .doc = "Define a function.", .added = "1.0" },
    };

    // Comptime iteration works
    comptime {
        var count: usize = 0;
        for (builtins) |b| {
            if (b.doc != null) count += 1;
        }
        if (count != 4) @compileError("expected 4 with doc");
    }

    // Runtime lookup by name
    const found = comptime blk: {
        for (&builtins) |*b| {
            if (std.mem.eql(u8, b.name, "map")) break :blk b;
        }
        @compileError("not found");
    };
    try std.testing.expectEqualStrings("map", found.name);
    try std.testing.expectEqualStrings("Returns a lazy sequence.", found.doc.?);
}

test "Var source location fields" {
    var v = Var{
        .sym = .{ .name = "my-fn", .ns = null },
        .ns_name = "user",
    };

    // Default: no source location
    try std.testing.expect(v.file == null);
    try std.testing.expectEqual(@as(u32, 0), v.line);
    try std.testing.expectEqual(@as(u32, 0), v.column);

    // Set source location
    v.file = "src/my_file.clj";
    v.line = 42;
    v.column = 3;

    try std.testing.expectEqualStrings("src/my_file.clj", v.file.?);
    try std.testing.expectEqual(@as(u32, 42), v.line);
    try std.testing.expectEqual(@as(u32, 3), v.column);
}

test "Var qualifiedName" {
    const v = Var{
        .sym = .{ .name = "map", .ns = null },
        .ns_name = "clojure.core",
    };

    var buf: [64]u8 = undefined;
    const qname = v.qualifiedName(&buf);
    try std.testing.expectEqualStrings("clojure.core/map", qname);
}
