// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.xml — XML reading/writing.
//! Replaces clojure/xml.clj with a native Zig XML parser.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../../runtime/value.zig");
const Value = value_mod.Value;
const var_mod = @import("../../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const errmod = @import("../../runtime/error.zig");
const bootstrap = @import("../../runtime/bootstrap.zig");
const dispatch = @import("../../runtime/dispatch.zig");
const Env = @import("../../runtime/env.zig").Env;
const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;

fn callCore(allocator: Allocator, name: []const u8, args: []const Value) !Value {
    const env = dispatch.macro_eval_env orelse return error.EvalError;
    const core_ns = env.findNamespace("clojure.core") orelse return error.EvalError;
    const v = core_ns.mappings.get(name) orelse return error.EvalError;
    return bootstrap.callFnVal(allocator, v.deref(), args);
}

fn kw(allocator: Allocator, name: []const u8) Value {
    return Value.initKeyword(allocator, .{ .ns = null, .name = name });
}

fn str(allocator: Allocator, s: []const u8) Value {
    return Value.initString(allocator, @constCast(s));
}

// --- Native Zig XML parser ---

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isNameChar(c: u8) bool {
    return !isWhitespace(c) and c != '>' and c != '/' and c != '=' and c != '<';
}

fn skipWs(s: []const u8, pos: usize) usize {
    var i = pos;
    while (i < s.len and isWhitespace(s[i])) : (i += 1) {}
    return i;
}

fn readName(s: []const u8, pos: usize) struct { name: []const u8, end: usize } {
    var i = pos;
    while (i < s.len and isNameChar(s[i])) : (i += 1) {}
    return .{ .name = s[pos..i], .end = i };
}

fn indexOf(s: []const u8, needle: []const u8, start: usize) ?usize {
    if (start >= s.len) return null;
    const haystack = s[start..];
    const idx = std.mem.indexOf(u8, haystack, needle) orelse return null;
    return start + idx;
}

fn decodeEntity(allocator: Allocator, entity: []const u8) ![]const u8 {
    if (std.mem.eql(u8, entity, "amp")) return "&";
    if (std.mem.eql(u8, entity, "lt")) return "<";
    if (std.mem.eql(u8, entity, "gt")) return ">";
    if (std.mem.eql(u8, entity, "quot")) return "\"";
    if (std.mem.eql(u8, entity, "apos")) return "'";
    if (entity.len > 0 and entity[0] == '#') {
        const code: u21 = blk: {
            if (entity.len > 1 and entity[1] == 'x') {
                break :blk std.fmt.parseInt(u21, entity[2..], 16) catch return entity;
            } else {
                break :blk std.fmt.parseInt(u21, entity[1..], 10) catch return entity;
            }
        };
        // Encode codepoint as UTF-8
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(code, &buf) catch return entity;
        return allocator.dupe(u8, buf[0..len]) catch return entity;
    }
    // Unknown entity — return as-is with & and ;
    const result = allocator.alloc(u8, entity.len + 2) catch return entity;
    result[0] = '&';
    @memcpy(result[1 .. 1 + entity.len], entity);
    result[entity.len + 1] = ';';
    return result;
}

fn decodeEntities(allocator: Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, s, "&") == null) return s;
    var result = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            if (indexOf(s, ";", i)) |semi| {
                const entity = s[i + 1 .. semi];
                const decoded = try decodeEntity(allocator, entity);
                result.appendSlice(allocator, decoded) catch return error.EvalError;
                i = semi + 1;
            } else {
                result.append(allocator, s[i]) catch return error.EvalError;
                i += 1;
            }
        } else {
            result.append(allocator, s[i]) catch return error.EvalError;
            i += 1;
        }
    }
    return result.items;
}

fn readAttrValue(allocator: Allocator, s: []const u8, pos: usize) !struct { value: []const u8, end: usize } {
    const quote_char = s[pos];
    const end = indexOf(s, &.{quote_char}, pos + 1) orelse return error.EvalError;
    const raw = s[pos + 1 .. end];
    const decoded = try decodeEntities(allocator, raw);
    return .{ .value = decoded, .end = end + 1 };
}

fn readAttrs(allocator: Allocator, s: []const u8, pos: usize) !struct { attrs: ?Value, end: usize } {
    var i = skipWs(s, pos);
    var attrs_val: ?Value = null;
    while (i < s.len and s[i] != '>' and s[i] != '/') {
        const name_result = readName(s, i);
        const eq_pos = skipWs(s, name_result.end);
        // skip '='
        const val_pos = skipWs(s, eq_pos + 1);
        const val_result = try readAttrValue(allocator, s, val_pos);
        const attr_key = kw(allocator, name_result.name);
        const attr_val = str(allocator, val_result.value);
        attrs_val = try callCore(allocator, "assoc", &.{ attrs_val orelse try callCore(allocator, "hash-map", &.{}), attr_key, attr_val });
        i = skipWs(s, val_result.end);
    }
    return .{ .attrs = attrs_val, .end = i };
}

const ParseResult = struct { items: []const Value, end: usize };

fn parseXml(allocator: Allocator, s: []const u8, pos: usize) anyerror!ParseResult {
    var i = skipWs(s, pos);
    var children = std.ArrayList(Value).empty;

    while (i < s.len) {
        if (s[i] == '<') {
            if (i + 1 >= s.len) break;
            const next_c = s[i + 1];

            if (next_c == '/') {
                // End tag
                break;
            } else if (next_c == '!' and i + 3 < s.len and s[i + 2] == '-' and s[i + 3] == '-') {
                // Comment: <!-- ... -->
                const end = indexOf(s, "-->", i + 4) orelse break;
                i = end + 3;
            } else if (next_c == '!' and i + 8 < s.len and std.mem.eql(u8, s[i + 2 .. i + 9], "[CDATA[")) {
                // CDATA: <![CDATA[ ... ]]>
                const end = indexOf(s, "]]>", i + 9) orelse break;
                const text = s[i + 9 .. end];
                children.append(allocator, str(allocator, text)) catch return error.EvalError;
                i = end + 3;
            } else if (next_c == '!') {
                // DOCTYPE or other declarations
                const bracket = indexOf(s, "[", i);
                const gt = indexOf(s, ">", i) orelse break;
                if (bracket != null and bracket.? < gt) {
                    const end = indexOf(s, "]>", bracket.?) orelse break;
                    i = end + 2;
                } else {
                    i = gt + 1;
                }
            } else if (next_c == '?') {
                // Processing instruction: <? ... ?>
                const end = indexOf(s, "?>", i + 2) orelse break;
                i = end + 2;
            } else {
                // Start tag
                const name_result = readName(s, i + 1);
                const tag_name = name_result.name;
                const tag_pos = skipWs(s, name_result.end);

                if (tag_pos < s.len and (s[tag_pos] == '>' or s[tag_pos] == '/')) {
                    if (s[tag_pos] == '/') {
                        // Self-closing: <tag/>
                        const elem = try makeElement(allocator, tag_name, null, null);
                        children.append(allocator, elem) catch return error.EvalError;
                        i = tag_pos + 2;
                    } else {
                        // Open tag: <tag>
                        const child_result = try parseXml(allocator, s, tag_pos + 1);
                        // skip </tag>
                        const close_name = readName(s, child_result.end + 2);
                        const close_end = skipWs(s, close_name.end);
                        i = close_end + 1; // skip >
                        const content_val = if (child_result.items.len > 0)
                            try callCore(allocator, "vec", &.{try listFromSlice(allocator, child_result.items)})
                        else
                            Value.nil_val;
                        const elem = try makeElement(allocator, tag_name, null, content_val);
                        children.append(allocator, elem) catch return error.EvalError;
                    }
                } else {
                    // Has attributes
                    const attrs_result = try readAttrs(allocator, s, tag_pos);
                    const attr_end = attrs_result.end;
                    if (attr_end < s.len and s[attr_end] == '/') {
                        // Self-closing with attrs: <tag attr="val"/>
                        const elem = try makeElement(allocator, tag_name, attrs_result.attrs, null);
                        children.append(allocator, elem) catch return error.EvalError;
                        i = attr_end + 2;
                    } else {
                        // Open tag with attrs: <tag attr="val">
                        const child_result = try parseXml(allocator, s, attr_end + 1);
                        const close_name = readName(s, child_result.end + 2);
                        const close_end = skipWs(s, close_name.end);
                        i = close_end + 1;
                        const content_val = if (child_result.items.len > 0)
                            try callCore(allocator, "vec", &.{try listFromSlice(allocator, child_result.items)})
                        else
                            Value.nil_val;
                        const elem = try makeElement(allocator, tag_name, attrs_result.attrs, content_val);
                        children.append(allocator, elem) catch return error.EvalError;
                    }
                }
            }
        } else {
            // Text content
            const next_lt = indexOf(s, "<", i) orelse s.len;
            const raw_text = s[i..next_lt];
            const text = try decodeEntities(allocator, raw_text);
            // Skip whitespace-only text
            var all_ws = true;
            for (text) |c| {
                if (!isWhitespace(c)) {
                    all_ws = false;
                    break;
                }
            }
            if (!all_ws) {
                children.append(allocator, str(allocator, text)) catch return error.EvalError;
            }
            i = next_lt;
        }
    }

    return .{ .items = children.items, .end = i };
}

fn makeElement(allocator: Allocator, tag_name: []const u8, attrs: ?Value, content: ?Value) !Value {
    var m = try callCore(allocator, "hash-map", &.{});
    m = try callCore(allocator, "assoc", &.{ m, kw(allocator, "tag"), kw(allocator, tag_name) });
    m = try callCore(allocator, "assoc", &.{ m, kw(allocator, "attrs"), if (attrs) |a| a else Value.nil_val });
    m = try callCore(allocator, "assoc", &.{ m, kw(allocator, "content"), if (content) |c| c else Value.nil_val });
    return m;
}

fn listFromSlice(allocator: Allocator, items: []const Value) !Value {
    var result = Value.nil_val;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        result = try callCore(allocator, "cons", &.{ items[i], result });
    }
    return result;
}

// --- Public builtins ---

/// (parse source) or (parse source startparse)
/// Parses XML from a file path. Returns a tree of element maps.
fn parseFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) {
        errmod.setInfoFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to parse", .{args.len});
        return error.EvalError;
    }
    // Read file content via slurp
    const path_val = try callCore(allocator, "str", &.{args[0]});
    const content_val = try callCore(allocator, "slurp", &.{path_val});
    if (content_val.tag() != .string) return error.EvalError;
    return parseXmlString(allocator, content_val.asString());
}

/// (parse-str s) — Parse XML from a string directly.
fn parseStrFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) {
        errmod.setInfoFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to parse-str", .{args.len});
        return error.EvalError;
    }
    if (args[0].tag() != .string) return error.EvalError;
    return parseXmlString(allocator, args[0].asString());
}

fn parseXmlString(allocator: Allocator, s: []const u8) !Value {
    const result = try parseXml(allocator, s, 0);
    if (result.items.len > 0) {
        return result.items[0];
    }
    return Value.nil_val;
}

/// (emit-element e)
fn emitElementFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) {
        errmod.setInfoFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to emit-element", .{args.len});
        return error.EvalError;
    }
    try emitElementImpl(allocator, args[0]);
    return Value.nil_val;
}

fn emitElementImpl(allocator: Allocator, e: Value) !void {
    // If it's a string, just print it
    if (e.tag() == .string) {
        _ = try callCore(allocator, "println", &.{e});
        return;
    }
    // It's a map element
    const tag_val = try callCore(allocator, "get", &.{ e, kw(allocator, "tag") });
    const attrs_val = try callCore(allocator, "get", &.{ e, kw(allocator, "attrs") });
    const content_val = try callCore(allocator, "get", &.{ e, kw(allocator, "content") });

    const tag_name = try callCore(allocator, "name", &.{tag_val});

    // Print opening tag
    const open = try callCore(allocator, "str", &.{ str(allocator, "<"), tag_name });
    _ = try callCore(allocator, "print", &.{open});

    // Print attributes
    if (attrs_val.isTruthy()) {
        var attr_seq = try callCore(allocator, "seq", &.{attrs_val});
        while (attr_seq.isTruthy()) {
            const attr = try callCore(allocator, "first", &.{attr_seq});
            const attr_key = try callCore(allocator, "key", &.{attr});
            const attr_value = try callCore(allocator, "val", &.{attr});
            const attr_str = try callCore(allocator, "str", &.{
                str(allocator, " "),
                try callCore(allocator, "name", &.{attr_key}),
                str(allocator, "='"),
                attr_value,
                str(allocator, "'"),
            });
            _ = try callCore(allocator, "print", &.{attr_str});
            attr_seq = try callCore(allocator, "next", &.{attr_seq});
        }
    }

    // Print content or self-close
    if (content_val.isTruthy()) {
        _ = try callCore(allocator, "println", &.{str(allocator, ">")});
        var content_seq = try callCore(allocator, "seq", &.{content_val});
        while (content_seq.isTruthy()) {
            const child = try callCore(allocator, "first", &.{content_seq});
            try emitElementImpl(allocator, child);
            content_seq = try callCore(allocator, "next", &.{content_seq});
        }
        const close_tag = try callCore(allocator, "str", &.{ str(allocator, "</"), tag_name, str(allocator, ">") });
        _ = try callCore(allocator, "println", &.{close_tag});
    } else {
        _ = try callCore(allocator, "println", &.{str(allocator, "/>")});
    }
}

/// (emit x)
fn emitFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) {
        errmod.setInfoFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to emit", .{args.len});
        return error.EvalError;
    }
    _ = try callCore(allocator, "println", &.{str(allocator, "<?xml version='1.0' encoding='UTF-8'?>")});
    try emitElementImpl(allocator, args[0]);
    return Value.nil_val;
}

/// Post-registration: bind tag/attrs/content to their keyword values.
fn postRegisterImpl(allocator: Allocator, ns: anytype) void {
    // tag = :tag, attrs = :attrs, content = :content
    if (ns.mappings.get("tag")) |v| {
        v.bindRoot(kw(allocator, "tag"));
    }
    if (ns.mappings.get("attrs")) |v| {
        v.bindRoot(kw(allocator, "attrs"));
    }
    if (ns.mappings.get("content")) |v| {
        v.bindRoot(kw(allocator, "content"));
    }
}

fn postRegister(allocator: Allocator, env: *Env) anyerror!void {
    const ns = env.findNamespace("clojure.xml") orelse return;
    postRegisterImpl(allocator, ns);
}

// ============================================================
// Namespace definition
// ============================================================

const builtins = [_]BuiltinDef{
    .{ .name = "tag", .func = null, .doc = "Access :tag of an element" },
    .{ .name = "attrs", .func = null, .doc = "Access :attrs of an element" },
    .{ .name = "content", .func = null, .doc = "Access :content of an element" },
    .{ .name = "parse", .func = &parseFn, .doc = "Parses and loads XML from a file path or File. Returns a tree of element maps." },
    .{ .name = "parse-str", .func = &parseStrFn, .doc = "Parses XML from a string. Returns a tree of element maps." },
    .{ .name = "emit-element", .func = &emitElementFn, .doc = "Prints the XML element as text." },
    .{ .name = "emit", .func = &emitFn, .doc = "Prints XML with header." },
};

pub const namespace_def = NamespaceDef{
    .name = "clojure.xml",
    .builtins = &builtins,
    .post_register = &postRegister,
};
