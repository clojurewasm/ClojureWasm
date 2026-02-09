// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

// Macro expansion utilities — Form <-> Value conversion and macro execution.
//
// Enables the Analyzer to call macro functions during analysis:
//   1. Convert Form arguments to Values (data as code)
//   2. Execute macro function (Value -> Value transformation)
//   3. Convert result Value back to Form for re-analysis

const std = @import("std");
const Allocator = std.mem.Allocator;
const form_mod = @import("reader/form.zig");
const Form = form_mod.Form;
const FormData = form_mod.FormData;
const SymbolRef = form_mod.SymbolRef;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const collections = @import("collections.zig");
const builtin_collections = @import("builtin/collections.zig");
const Namespace = @import("namespace.zig").Namespace;

/// Convert a Form to a runtime Value (for passing to macro functions).
/// Collections are recursively converted. Source info preserved on lists/vectors.
pub fn formToValue(allocator: Allocator, form: Form) Allocator.Error!Value {
    return formToValueWithNs(allocator, form, null);
}

/// Convert a Form to a runtime Value, resolving auto-resolved keywords
/// using the given namespace (for both current-ns and alias resolution).
pub fn formToValueWithNs(allocator: Allocator, form: Form, ns: ?*const Namespace) Allocator.Error!Value {
    return switch (form.data) {
        .nil => Value.nil_val,
        .boolean => |b| Value.initBoolean(b),
        .integer => |n| Value.initInteger(n),
        .float => |n| Value.initFloat(n),
        .big_int => |s| Value.initBigInt(collections.BigInt.initFromString(allocator, s) catch return error.OutOfMemory),
        .big_decimal => |s| Value.initBigDecimal(collections.BigDecimal.initFromString(allocator, s) catch return error.OutOfMemory),
        .ratio => |r| blk: {
            const maybe_ratio = collections.Ratio.initFromStrings(allocator, r.numerator, r.denominator) catch return error.OutOfMemory;
            if (maybe_ratio) |ratio| {
                break :blk Value.initRatio(ratio);
            } else {
                // Simplifies to integer
                const n = collections.BigInt.initFromString(allocator, r.numerator) catch return error.OutOfMemory;
                const d = collections.BigInt.initFromString(allocator, r.denominator) catch return error.OutOfMemory;
                const q = allocator.create(collections.BigInt) catch return error.OutOfMemory;
                q.managed = std.math.big.int.Managed.init(allocator) catch return error.OutOfMemory;
                var rem_val = std.math.big.int.Managed.init(allocator) catch return error.OutOfMemory;
                q.managed.divTrunc(&rem_val, &n.managed, &d.managed) catch return error.OutOfMemory;
                if (q.toI64()) |i| break :blk Value.initInteger(i);
                break :blk Value.initBigInt(q);
            }
        },
        .char => |c| Value.initChar(c),
        .string => |s| Value.initString(allocator, s),
        .symbol => |sym| Value.initSymbol(allocator, .{ .ns = sym.ns, .name = sym.name }),
        .keyword => |sym| blk: {
            if (sym.auto_resolve) {
                if (ns) |current_ns| {
                    if (sym.ns) |alias| {
                        // ::alias/name — resolve alias to full namespace
                        const resolved = current_ns.getAlias(alias);
                        break :blk Value.initKeyword(allocator, .{ .ns = if (resolved) |r| r.name else alias, .name = sym.name });
                    } else {
                        // ::name — use current namespace
                        break :blk Value.initKeyword(allocator, .{ .ns = current_ns.name, .name = sym.name });
                    }
                } else {
                    // No namespace available — fallback to sym.ns
                    break :blk Value.initKeyword(allocator, .{ .ns = sym.ns, .name = sym.name });
                }
            } else {
                break :blk Value.initKeyword(allocator, .{ .ns = sym.ns, .name = sym.name });
            }
        },
        .list => |items| {
            const vals = try allocator.alloc(Value, items.len);
            const c_lines = try allocator.alloc(u32, items.len);
            const c_cols = try allocator.alloc(u16, items.len);
            for (items, 0..) |item, i| {
                vals[i] = try formToValueWithNs(allocator, item, ns);
                c_lines[i] = item.line;
                c_cols[i] = item.column;
            }
            const lst = try allocator.create(collections.PersistentList);
            lst.* = .{
                .items = vals,
                .source_line = form.line,
                .source_column = form.column,
                .child_lines = c_lines,
                .child_columns = c_cols,
            };
            return Value.initList(lst);
        },
        .vector => |items| {
            const vals = try allocator.alloc(Value, items.len);
            const c_lines = try allocator.alloc(u32, items.len);
            const c_cols = try allocator.alloc(u16, items.len);
            for (items, 0..) |item, i| {
                vals[i] = try formToValueWithNs(allocator, item, ns);
                c_lines[i] = item.line;
                c_cols[i] = item.column;
            }
            const vec = try allocator.create(collections.PersistentVector);
            vec.* = .{
                .items = vals,
                .source_line = form.line,
                .source_column = form.column,
                .child_lines = c_lines,
                .child_columns = c_cols,
            };
            return Value.initVector(vec);
        },
        .map => |items| {
            const vals = try allocator.alloc(Value, items.len);
            for (items, 0..) |item, i| {
                vals[i] = try formToValueWithNs(allocator, item, ns);
            }
            const m = try allocator.create(collections.PersistentArrayMap);
            m.* = .{ .entries = vals };
            return Value.initMap(m);
        },
        .set => |items| {
            const vals = try allocator.alloc(Value, items.len);
            for (items, 0..) |item, i| {
                vals[i] = try formToValueWithNs(allocator, item, ns);
            }
            const s = try allocator.create(collections.PersistentHashSet);
            s.* = .{ .items = vals };
            return Value.initSet(s);
        },
        .regex => |pattern| {
            // Compile regex so it survives the formToValue/valueToForm roundtrip
            const regex_mod = @import("regex/regex.zig");
            const matcher_mod = @import("regex/matcher.zig");
            const compiled = allocator.create(regex_mod.CompiledRegex) catch return error.OutOfMemory;
            compiled.* = matcher_mod.compile(allocator, pattern) catch {
                // Fallback to string if compilation fails (shouldn't happen — reader validated)
                return Value.initString(allocator, pattern);
            };
            const pat = try allocator.create(value_mod.Pattern);
            pat.* = .{
                .source = pattern,
                .compiled = @ptrCast(compiled),
                .group_count = compiled.group_count,
            };
            return Value.initRegex(pat);
        },
        .tag => Value.nil_val, // tagged literals not supported in macro args
    };
}

/// Convert a runtime Value back to a Form (for re-analysis after macro expansion).
/// Collections are recursively converted. Source info restored from list/vector fields.
pub fn valueToForm(allocator: Allocator, val: Value) Allocator.Error!Form {
    return switch (val.tag()) {
        .nil => Form{ .data = .nil },
        .boolean => Form{ .data = .{ .boolean = val.asBoolean() } },
        .integer => Form{ .data = .{ .integer = val.asInteger() } },
        .float => Form{ .data = .{ .float = val.asFloat() } },
        .char => Form{ .data = .{ .char = val.asChar() } },
        .string => Form{ .data = .{ .string = val.asString() } },
        .symbol => blk: {
            const sym = val.asSymbol();
            break :blk Form{ .data = .{ .symbol = .{ .ns = sym.ns, .name = sym.name } } };
        },
        .keyword => blk: {
            const k = val.asKeyword();
            break :blk Form{ .data = .{ .keyword = .{ .ns = k.ns, .name = k.name } } };
        },
        .list => {
            const lst = val.asList();
            const forms = try allocator.alloc(Form, lst.items.len);
            for (lst.items, 0..) |item, i| {
                forms[i] = try valueToForm(allocator, item);
                // Restore child source positions from formToValue roundtrip
                if (forms[i].line == 0) {
                    if (lst.child_lines) |cl| if (i < cl.len) {
                        forms[i].line = cl[i];
                    };
                    if (lst.child_columns) |cc| if (i < cc.len) {
                        forms[i].column = cc[i];
                    };
                }
            }
            return Form{ .data = .{ .list = forms }, .line = lst.source_line, .column = lst.source_column };
        },
        .vector => {
            const vec = val.asVector();
            const forms = try allocator.alloc(Form, vec.items.len);
            for (vec.items, 0..) |item, i| {
                forms[i] = try valueToForm(allocator, item);
                if (forms[i].line == 0) {
                    if (vec.child_lines) |cl| if (i < cl.len) {
                        forms[i].line = cl[i];
                    };
                    if (vec.child_columns) |cc| if (i < cc.len) {
                        forms[i].column = cc[i];
                    };
                }
            }
            return Form{ .data = .{ .vector = forms }, .line = vec.source_line, .column = vec.source_column };
        },
        .map => {
            const m = val.asMap();
            const forms = try allocator.alloc(Form, m.entries.len);
            for (m.entries, 0..) |item, i| {
                forms[i] = try valueToForm(allocator, item);
            }
            return Form{ .data = .{ .map = forms } };
        },
        .hash_map => {
            const hm = val.asHashMap();
            const entries = try hm.toEntries(allocator);
            const forms = try allocator.alloc(Form, entries.len);
            for (entries, 0..) |item, i| {
                forms[i] = try valueToForm(allocator, item);
            }
            return Form{ .data = .{ .map = forms } };
        },
        .set => {
            const s = val.asSet();
            const forms = try allocator.alloc(Form, s.items.len);
            for (s.items, 0..) |item, i| {
                forms[i] = try valueToForm(allocator, item);
            }
            return Form{ .data = .{ .set = forms } };
        },
        .var_ref => {
            const v = val.asVarRef();
            // (var ns/name)
            const items = try allocator.alloc(Form, 2);
            items[0] = Form{ .data = .{ .symbol = .{ .ns = null, .name = "var" } } };
            items[1] = Form{ .data = .{ .symbol = .{ .ns = v.ns_name, .name = v.sym.name } } };
            return Form{ .data = .{ .list = items } };
        },
        // Lazy seq / cons — realize to list and convert
        .lazy_seq, .cons => {
            const realized = builtin_collections.realizeValue(allocator, val) catch return Form{ .data = .nil };
            return valueToForm(allocator, realized);
        },
        .regex => Form{ .data = .{ .regex = val.asRegex().source } },
        .big_int => blk: {
            const bi = val.asBigInt();
            const s = bi.managed.toConst().toStringAlloc(allocator, 10, .lower) catch return Form{ .data = .nil };
            break :blk Form{ .data = .{ .big_int = s } };
        },
        .big_decimal => blk: {
            const bd = val.asBigDecimal();
            const s = bd.toStringAlloc(allocator) catch return Form{ .data = .nil };
            break :blk Form{ .data = .{ .big_decimal = s } };
        },
        .ratio => blk: {
            const r = val.asRatio();
            const num_s = r.numerator.managed.toConst().toStringAlloc(allocator, 10, .lower) catch return Form{ .data = .nil };
            const den_s = r.denominator.managed.toConst().toStringAlloc(allocator, 10, .lower) catch return Form{ .data = .nil };
            break :blk Form{ .data = .{ .ratio = .{ .numerator = num_s, .denominator = den_s } } };
        },
        // Non-data values become nil (shouldn't appear in macro output)
        .fn_val, .builtin_fn, .atom, .volatile_ref, .protocol, .protocol_fn, .multi_fn, .delay, .reduced, .transient_vector, .transient_map, .transient_set, .chunked_cons, .chunk_buffer, .array_chunk, .wasm_module, .wasm_fn, .matcher, .array => Form{ .data = .nil },
    };
}

// === Tests ===

const testing = std.testing;

test "formToValue - primitives" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectEqual(Value.nil_val, try formToValue(alloc, .{ .data = .nil }));
    try testing.expectEqual(Value.true_val, try formToValue(alloc, .{ .data = .{ .boolean = true } }));
    try testing.expectEqual(Value.initInteger(42), try formToValue(alloc, .{ .data = .{ .integer = 42 } }));
    try testing.expectEqual(Value.initFloat(3.14), try formToValue(alloc, .{ .data = .{ .float = 3.14 } }));
    try testing.expectEqual(Value.initChar('A'), try formToValue(alloc, .{ .data = .{ .char = 'A' } }));
    try testing.expectEqualStrings("hello", (try formToValue(alloc, .{ .data = .{ .string = "hello" } })).asString());
}

test "formToValue - symbol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try formToValue(alloc, .{ .data = .{ .symbol = .{ .ns = null, .name = "foo" } } });
    try testing.expectEqualStrings("foo", val.asSymbol().name);
    try testing.expect(val.asSymbol().ns == null);
}

test "formToValue - list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Form{
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .integer = 2 } },
    };
    const val = try formToValue(alloc, .{ .data = .{ .list = &items } });
    try testing.expect(val.tag() == .list);
    try testing.expectEqual(@as(usize, 2), val.asList().items.len);
    try testing.expectEqual(Value.initInteger(1), val.asList().items[0]);
    try testing.expectEqual(Value.initInteger(2), val.asList().items[1]);
}

test "valueToForm - primitives" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const f1 = try valueToForm(alloc, Value.nil_val);
    try testing.expect(f1.data == .nil);
    const f2 = try valueToForm(alloc, Value.initInteger(42));
    try testing.expectEqual(@as(i64, 42), f2.data.integer);
    const f3 = try valueToForm(alloc, Value.initString(alloc, "hello"));
    try testing.expectEqualStrings("hello", f3.data.string);
}

test "valueToForm - symbol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const f = try valueToForm(alloc, Value.initSymbol(alloc, .{ .ns = "ns", .name = "bar" }));
    try testing.expectEqualStrings("ns", f.data.symbol.ns.?);
    try testing.expectEqualStrings("bar", f.data.symbol.name);
}

test "valueToForm - list roundtrip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "+" } } },
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .integer = 2 } },
    };
    const val = try formToValue(alloc, .{ .data = .{ .list = &items } });
    const form = try valueToForm(alloc, val);
    try testing.expect(form.data == .list);
    try testing.expectEqual(@as(usize, 3), form.data.list.len);
    try testing.expectEqualStrings("+", form.data.list[0].data.symbol.name);
    try testing.expectEqual(@as(i64, 1), form.data.list[1].data.integer);
    try testing.expectEqual(@as(i64, 2), form.data.list[2].data.integer);
}

test "formToValue/valueToForm - list source location roundtrip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "+" } } },
        .{ .data = .{ .integer = 1 } },
    };
    // Form with source location
    const form = Form{ .data = .{ .list = &items }, .line = 5, .column = 10 };
    const val = try formToValue(alloc, form);

    // Value should carry source info
    try testing.expectEqual(@as(u32, 5), val.asList().source_line);
    try testing.expectEqual(@as(u16, 10), val.asList().source_column);

    // Roundtrip back to Form should restore source
    const restored = try valueToForm(alloc, val);
    try testing.expectEqual(@as(u32, 5), restored.line);
    try testing.expectEqual(@as(u16, 10), restored.column);
}

test "formToValue/valueToForm - vector source location roundtrip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]Form{
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .integer = 2 } },
    };
    const form = Form{ .data = .{ .vector = &items }, .line = 3, .column = 7 };
    const val = try formToValue(alloc, form);

    try testing.expectEqual(@as(u32, 3), val.asVector().source_line);
    try testing.expectEqual(@as(u16, 7), val.asVector().source_column);

    const restored = try valueToForm(alloc, val);
    try testing.expectEqual(@as(u32, 3), restored.line);
    try testing.expectEqual(@as(u16, 7), restored.column);
}
