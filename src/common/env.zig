// Env — runtime environment (instantiated, no threadlocal).
//
// Owns the ErrorContext (D3a) and will own Namespace registry (Task 2.2).
// Each VM instance holds its own Env.

const std = @import("std");
const Allocator = std.mem.Allocator;
const err = @import("error.zig");

/// Runtime environment — instantiated per VM.
pub const Env = struct {
    allocator: Allocator,
    error_ctx: err.ErrorContext = .{},

    pub fn init(allocator: Allocator) Env {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Env) void {
        // Namespace cleanup will be added in Task 2.2.
        _ = self;
    }
};

// === Tests ===

test "Env init creates valid error context" {
    var env = Env.init(std.heap.page_allocator);
    defer env.deinit();

    // ErrorContext should be usable
    const e = env.error_ctx.setError(.{
        .kind = .syntax_error,
        .phase = .parse,
        .message = "test error",
    });
    try std.testing.expectEqual(error.SyntaxError, e);

    const info = env.error_ctx.getLastError().?;
    try std.testing.expectEqualStrings("test error", info.message);
}
