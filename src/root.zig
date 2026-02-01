// ClojureWasm - Clojure implementation in Zig
// This is the library root module.

pub const value = @import("common/value.zig");

test {
    _ = value;
}
