// Test root for library module.
// As modules grow, import them here so `zig build test` discovers all tests.

test {
    _ = @import("runtime/value.zig");
    _ = @import("runtime/error.zig");
    _ = @import("runtime/gc/arena.zig");
    _ = @import("runtime/collection/list.zig");
    _ = @import("runtime/hash.zig");
    _ = @import("runtime/keyword.zig");
    _ = @import("eval/form.zig");
    _ = @import("eval/tokenizer.zig");
}
