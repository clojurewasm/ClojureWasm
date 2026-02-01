// ClojureWasm - Clojure implementation in Zig
// This is the library root module.

pub const value = @import("common/value.zig");
pub const collections = @import("common/collections.zig");

test {
    _ = value;
    _ = collections;
}
