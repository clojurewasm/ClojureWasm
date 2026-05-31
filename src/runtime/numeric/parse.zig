// SPDX-License-Identifier: EPL-2.0
//! Java/Clojure-compatible numeric string parsing (neutral leaf).
//!
//! The single integer-parse mechanism shared by the Clojure-ns
//! `parse-long` primitive and the Java-ns `Integer/parseInt` /
//! `Long/parseLong` statics (F-009 neutral home, F-011 DRY). Surfaces
//! map the error to `nil` (Clojure `parse-*`) or NumberFormatException
//! (Java `parse*`); the acceptance rule lives here, in one place.
//!
//! Zig's `std.fmt.parseInt` accepts `_` digit separators (`1_000`) that
//! Java `Integer.parseInt` and Clojure `parse-long` both reject —
//! `(parse-long "1_000")` is `nil` in real Clojure. This leaf rejects
//! the underscore so every surface matches the oracle; everything else
//! (optional leading `+`/`-`, no surrounding whitespace) already agrees
//! between Zig and Java/Clojure.

const std = @import("std");

/// The single error a malformed numeric string yields. Surfaces decide
/// whether it becomes `nil` or a thrown NumberFormatException.
pub const ParseError = error{InvalidNumberFormat};

/// Parse a signed integer of type `T` from `s` in `radix`, matching
/// Java/Clojure acceptance. `T` is the surface's value range:
/// `i32` for `Integer/parseInt` (out-of-int-range string ⇒ error, as
/// real clj throws), `i64` for `Long/parseLong` and `parse-long`.
pub fn parseSigned(comptime T: type, s: []const u8, radix: u8) ParseError!T {
    if (std.mem.findScalar(u8, s, '_') != null) return error.InvalidNumberFormat;
    return std.fmt.parseInt(T, s, radix) catch error.InvalidNumberFormat;
}

const testing = std.testing;

test "parseSigned base-10 accepts sign, rejects underscore + whitespace" {
    try testing.expectEqual(@as(i64, 42), try parseSigned(i64, "42", 10));
    try testing.expectEqual(@as(i64, -10), try parseSigned(i64, "-10", 10));
    try testing.expectEqual(@as(i64, 5), try parseSigned(i64, "+5", 10));
    try testing.expectError(error.InvalidNumberFormat, parseSigned(i64, "1_000", 10));
    try testing.expectError(error.InvalidNumberFormat, parseSigned(i64, " 5", 10));
    try testing.expectError(error.InvalidNumberFormat, parseSigned(i64, "abc", 10));
}

test "parseSigned honours radix" {
    try testing.expectEqual(@as(i32, 255), try parseSigned(i32, "ff", 16));
    try testing.expectEqual(@as(i32, 8), try parseSigned(i32, "10", 8));
}

test "parseSigned i32 range models Java int overflow" {
    // 9999999999 fits i64 but not i32 — real clj (Integer/parseInt) throws.
    try testing.expectError(error.InvalidNumberFormat, parseSigned(i32, "9999999999", 10));
    try testing.expectEqual(@as(i64, 9999999999), try parseSigned(i64, "9999999999", 10));
}
