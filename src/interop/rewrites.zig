// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Java interop rewrite tables — static field and method rewrites.
//!
//! Extracted from analyzer.zig. Maps Java Class/field and Class/method
//! syntax to corresponding ClojureWasm vars and builtins.

const std = @import("std");

pub const StaticFieldRewrite = struct { ns: ?[]const u8, name: []const u8 };

/// Rewrite Java static field access to CW var reference.
/// Maps Java Class/FIELD syntax to corresponding CW vars.
pub fn rewriteStaticField(ns: []const u8, name: []const u8) ?StaticFieldRewrite {
    if (std.mem.eql(u8, ns, "Math") or std.mem.eql(u8, ns, "java.lang.Math") or std.mem.eql(u8, ns, "StrictMath")) {
        if (std.mem.eql(u8, name, "PI") or std.mem.eql(u8, name, "E")) {
            return .{ .ns = "clojure.math", .name = name };
        }
    } else if (std.mem.eql(u8, ns, "Integer") or std.mem.eql(u8, ns, "java.lang.Integer")) {
        if (integer_fields.get(name)) |cw| return .{ .ns = null, .name = cw };
    } else if (std.mem.eql(u8, ns, "Long") or std.mem.eql(u8, ns, "java.lang.Long")) {
        if (long_fields.get(name)) |cw| return .{ .ns = null, .name = cw };
    } else if (std.mem.eql(u8, ns, "Double") or std.mem.eql(u8, ns, "java.lang.Double")) {
        if (double_fields.get(name)) |cw| return .{ .ns = null, .name = cw };
    } else if (std.mem.eql(u8, ns, "Float") or std.mem.eql(u8, ns, "java.lang.Float")) {
        if (float_fields.get(name)) |cw| return .{ .ns = null, .name = cw };
    } else if (std.mem.eql(u8, ns, "Short") or std.mem.eql(u8, ns, "java.lang.Short")) {
        if (short_fields.get(name)) |cw| return .{ .ns = null, .name = cw };
    } else if (std.mem.eql(u8, ns, "Byte") or std.mem.eql(u8, ns, "java.lang.Byte")) {
        if (byte_fields.get(name)) |cw| return .{ .ns = null, .name = cw };
    } else if (std.mem.eql(u8, ns, "Boolean") or std.mem.eql(u8, ns, "java.lang.Boolean")) {
        if (boolean_fields.get(name)) |cw| return .{ .ns = null, .name = cw };
    } else if (std.mem.eql(u8, ns, "Character") or std.mem.eql(u8, ns, "java.lang.Character")) {
        if (character_fields.get(name)) |cw| return .{ .ns = null, .name = cw };
    } else if (std.mem.eql(u8, ns, "File") or std.mem.eql(u8, ns, "java.io.File")) {
        if (file_fields.get(name)) |cw| return .{ .ns = null, .name = cw };
    }
    return null;
}

// Java static field -> CW var name lookup tables
const integer_fields = std.StaticStringMap([]const u8).initComptime(.{
    .{ "MAX_VALUE", "__integer-max-value" },
    .{ "MIN_VALUE", "__integer-min-value" },
    .{ "SIZE", "__integer-size" },
    .{ "BYTES", "__integer-bytes" },
});
const long_fields = std.StaticStringMap([]const u8).initComptime(.{
    .{ "MAX_VALUE", "__long-max-value" },
    .{ "MIN_VALUE", "__long-min-value" },
    .{ "SIZE", "__long-size" },
    .{ "BYTES", "__long-bytes" },
});
const double_fields = std.StaticStringMap([]const u8).initComptime(.{
    .{ "MAX_VALUE", "__double-max-value" },
    .{ "MIN_VALUE", "__double-min-value" },
    .{ "NaN", "__double-nan" },
    .{ "POSITIVE_INFINITY", "__double-positive-infinity" },
    .{ "NEGATIVE_INFINITY", "__double-negative-infinity" },
    .{ "MIN_NORMAL", "__double-min-normal" },
    .{ "MAX_EXPONENT", "__double-max-exponent" },
    .{ "MIN_EXPONENT", "__double-min-exponent" },
    .{ "SIZE", "__double-size" },
    .{ "BYTES", "__double-bytes" },
});
const float_fields = std.StaticStringMap([]const u8).initComptime(.{
    .{ "MAX_VALUE", "__float-max-value" },
    .{ "MIN_VALUE", "__float-min-value" },
    .{ "NaN", "__float-nan" },
    .{ "POSITIVE_INFINITY", "__float-positive-infinity" },
    .{ "NEGATIVE_INFINITY", "__float-negative-infinity" },
    .{ "MIN_NORMAL", "__float-min-normal" },
    .{ "MAX_EXPONENT", "__float-max-exponent" },
    .{ "MIN_EXPONENT", "__float-min-exponent" },
    .{ "SIZE", "__float-size" },
    .{ "BYTES", "__float-bytes" },
});
const short_fields = std.StaticStringMap([]const u8).initComptime(.{
    .{ "MAX_VALUE", "__short-max-value" },
    .{ "MIN_VALUE", "__short-min-value" },
    .{ "SIZE", "__short-size" },
    .{ "BYTES", "__short-bytes" },
});
const byte_fields = std.StaticStringMap([]const u8).initComptime(.{
    .{ "MAX_VALUE", "__byte-max-value" },
    .{ "MIN_VALUE", "__byte-min-value" },
    .{ "SIZE", "__byte-size" },
    .{ "BYTES", "__byte-bytes" },
});
const boolean_fields = std.StaticStringMap([]const u8).initComptime(.{
    .{ "TRUE", "__boolean-true" },
    .{ "FALSE", "__boolean-false" },
});
const character_fields = std.StaticStringMap([]const u8).initComptime(.{
    .{ "MAX_VALUE", "__character-max-value" },
    .{ "MIN_VALUE", "__character-min-value" },
    .{ "MAX_CODE_POINT", "__character-max-code-point" },
    .{ "MIN_CODE_POINT", "__character-min-code-point" },
    .{ "SIZE", "__character-size" },
    .{ "BYTES", "__character-bytes" },
});

const file_fields = std.StaticStringMap([]const u8).initComptime(.{
    .{ "separator", "__file-separator" },
    .{ "pathSeparator", "__file-path-separator" },
    .{ "separatorChar", "__file-separator-char" },
    .{ "pathSeparatorChar", "__file-path-separator-char" },
});

/// Rewrite Java static method calls to ClojureWasm builtins.
pub fn rewriteInteropCall(ns: []const u8, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, ns, "Math")) {
        return math_rewrites.get(name);
    } else if (std.mem.eql(u8, ns, "System")) {
        return system_rewrites.get(name);
    } else if (std.mem.eql(u8, ns, "Thread")) {
        return thread_rewrites.get(name);
    } else if (std.mem.eql(u8, ns, "String")) {
        return string_rewrites.get(name);
    } else if (std.mem.eql(u8, ns, "Integer") or std.mem.eql(u8, ns, "Long")) {
        return integer_rewrites.get(name);
    } else if (std.mem.eql(u8, ns, "Double") or std.mem.eql(u8, ns, "Float")) {
        return double_rewrites.get(name);
    } else if (std.mem.eql(u8, ns, "Character")) {
        return character_rewrites.get(name);
    } else if (std.mem.eql(u8, ns, "Boolean")) {
        return boolean_rewrites.get(name);
    } else if (std.mem.eql(u8, ns, "Pattern") or std.mem.eql(u8, ns, "java.util.regex.Pattern")) {
        return pattern_rewrites.get(name);
    } else if (std.mem.eql(u8, ns, "URI") or std.mem.eql(u8, ns, "java.net.URI")) {
        return uri_rewrites.get(name);
    }
    return null;
}

const math_rewrites = std.StaticStringMap([]const u8).initComptime(.{
    .{ "abs", "abs" },
    .{ "max", "max" },
    .{ "min", "min" },
    .{ "pow", "__pow" },
    .{ "sqrt", "__sqrt" },
    .{ "round", "__round" },
    .{ "ceil", "__ceil" },
    .{ "floor", "__floor" },
});

const system_rewrites = std.StaticStringMap([]const u8).initComptime(.{
    .{ "getenv", "__getenv" },
    .{ "exit", "__exit" },
    .{ "nanoTime", "__nano-time" },
    .{ "currentTimeMillis", "__current-time-millis" },
    .{ "getProperty", "__get-property" },
});

const thread_rewrites = std.StaticStringMap([]const u8).initComptime(.{
    .{ "sleep", "__thread-sleep" },
});

const string_rewrites = std.StaticStringMap([]const u8).initComptime(.{
    .{ "valueOf", "str" },
    .{ "format", "format" },
    .{ "join", "__string-join-static" },
});

const integer_rewrites = std.StaticStringMap([]const u8).initComptime(.{
    .{ "parseInt", "parse-long" },
    .{ "parseLong", "parse-long" },
    .{ "valueOf", "parse-long" },
    .{ "toBinaryString", "__int-to-binary-string" },
    .{ "toHexString", "__int-to-hex-string" },
    .{ "toOctalString", "__int-to-octal-string" },
});

const double_rewrites = std.StaticStringMap([]const u8).initComptime(.{
    .{ "parseDouble", "parse-double" },
    .{ "parseFloat", "parse-double" },
    .{ "valueOf", "parse-double" },
    .{ "isNaN", "__double-is-nan" },
    .{ "isInfinite", "__double-is-infinite" },
});

const character_rewrites = std.StaticStringMap([]const u8).initComptime(.{
    .{ "isDigit", "__char-is-digit" },
    .{ "isLetter", "__char-is-letter" },
    .{ "isWhitespace", "__char-is-whitespace" },
    .{ "isUpperCase", "__char-is-upper-case" },
    .{ "isLowerCase", "__char-is-lower-case" },
});

const boolean_rewrites = std.StaticStringMap([]const u8).initComptime(.{
    .{ "parseBoolean", "__parse-boolean" },
    .{ "valueOf", "__parse-boolean" },
});

const pattern_rewrites = std.StaticStringMap([]const u8).initComptime(.{
    .{ "compile", "re-pattern" },
    .{ "quote", "__regex-quote" },
});

const uri_rewrites = std.StaticStringMap([]const u8).initComptime(.{
    .{ "create", "__uri-create" },
});

// Tests
const testing = std.testing;

test "rewriteStaticField — Math/PI" {
    const result = rewriteStaticField("Math", "PI");
    try testing.expect(result != null);
    try testing.expectEqualStrings("clojure.math", result.?.ns.?);
    try testing.expectEqualStrings("PI", result.?.name);
}

test "rewriteStaticField — Integer/MAX_VALUE" {
    const result = rewriteStaticField("Integer", "MAX_VALUE");
    try testing.expect(result != null);
    try testing.expect(result.?.ns == null);
    try testing.expectEqualStrings("__integer-max-value", result.?.name);
}

test "rewriteStaticField — unknown class" {
    try testing.expect(rewriteStaticField("Foo", "BAR") == null);
}

test "rewriteInteropCall — Math/sqrt" {
    const result = rewriteInteropCall("Math", "sqrt");
    try testing.expect(result != null);
    try testing.expectEqualStrings("__sqrt", result.?);
}

test "rewriteInteropCall — System/exit" {
    const result = rewriteInteropCall("System", "exit");
    try testing.expect(result != null);
    try testing.expectEqualStrings("__exit", result.?);
}

test "rewriteInteropCall — Pattern/compile" {
    const result = rewriteInteropCall("Pattern", "compile");
    try testing.expect(result != null);
    try testing.expectEqualStrings("re-pattern", result.?);
}

test "rewriteInteropCall — unknown" {
    try testing.expect(rewriteInteropCall("Foo", "bar") == null);
}
