// Var — Clojure variable with root binding and dynamic binding support.
//
// Global variables qualified by namespace. Supports root binding,
// dynamic (thread-local) bindings, and metadata flags.
//
// Three-phase architecture:
//   Form (Reader) -> Node (Analyzer) -> Value (Runtime)

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const Symbol = value.Symbol;

/// Var — Clojure variable bound to a namespace-qualified symbol.
pub const Var = struct {
    /// Variable name (symbol).
    sym: Symbol,

    /// Owning namespace name.
    ns_name: []const u8,

    /// Root binding (global value).
    root: Value = .nil,

    /// ^:dynamic flag.
    dynamic: bool = false,

    /// ^:macro flag.
    macro: bool = false,

    /// ^:private flag.
    private: bool = false,

    /// ^:const flag (compile-time inlining).
    is_const: bool = false,

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

/// Global binding stack (single-thread — Wasm target).
var current_frame: ?*BindingFrame = null;

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
    return error.IllegalState;
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
    v.bindRoot(.{ .integer = 42 });
    try std.testing.expect(v.deref().eql(.{ .integer = 42 }));
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
    v.bindRoot(.{ .integer = 1 });

    // No binding -> root
    try std.testing.expect(v.deref().eql(.{ .integer = 1 }));
    try std.testing.expect(!hasThreadBinding(&v));

    // Push binding
    var entries = [_]BindingEntry{.{ .var_ptr = &v, .val = .{ .integer = 10 } }};
    var frame = BindingFrame{ .entries = &entries, .prev = null };
    pushBindings(&frame);

    try std.testing.expect(v.deref().eql(.{ .integer = 10 }));
    try std.testing.expect(hasThreadBinding(&v));

    // Pop -> back to root
    popBindings();
    try std.testing.expect(v.deref().eql(.{ .integer = 1 }));
    try std.testing.expect(!hasThreadBinding(&v));
}

test "Var dynamic binding nested" {
    var x = Var{ .sym = .{ .name = "*x*", .ns = null }, .ns_name = "user", .dynamic = true };
    var y = Var{ .sym = .{ .name = "*y*", .ns = null }, .ns_name = "user", .dynamic = true };
    x.bindRoot(.{ .integer = 1 });
    y.bindRoot(.{ .integer = 2 });

    var entries1 = [_]BindingEntry{.{ .var_ptr = &x, .val = .{ .integer = 10 } }};
    var frame1 = BindingFrame{ .entries = &entries1, .prev = null };
    pushBindings(&frame1);

    var entries2 = [_]BindingEntry{.{ .var_ptr = &y, .val = .{ .integer = 20 } }};
    var frame2 = BindingFrame{ .entries = &entries2, .prev = null };
    pushBindings(&frame2);

    try std.testing.expect(x.deref().eql(.{ .integer = 10 }));
    try std.testing.expect(y.deref().eql(.{ .integer = 20 }));

    popBindings();
    try std.testing.expect(x.deref().eql(.{ .integer = 10 }));
    try std.testing.expect(y.deref().eql(.{ .integer = 2 }));

    popBindings();
    try std.testing.expect(x.deref().eql(.{ .integer = 1 }));
    try std.testing.expect(y.deref().eql(.{ .integer = 2 }));
}

test "Var set! within binding" {
    var v = Var{ .sym = .{ .name = "*x*", .ns = null }, .ns_name = "user", .dynamic = true };
    v.bindRoot(.{ .integer = 1 });

    var entries = [_]BindingEntry{.{ .var_ptr = &v, .val = .{ .integer = 10 } }};
    var frame = BindingFrame{ .entries = &entries, .prev = null };
    pushBindings(&frame);

    try setThreadBinding(&v, .{ .integer = 99 });
    try std.testing.expect(v.deref().eql(.{ .integer = 99 }));

    popBindings();
    // Root unchanged
    try std.testing.expect(v.deref().eql(.{ .integer = 1 }));
}

test "Var set! outside binding is error" {
    var v = Var{ .sym = .{ .name = "*x*", .ns = null }, .ns_name = "user", .dynamic = true };
    v.bindRoot(.{ .integer = 1 });

    try std.testing.expectError(error.IllegalState, setThreadBinding(&v, .{ .integer = 99 }));
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
