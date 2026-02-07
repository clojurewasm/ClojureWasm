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
        .nil => .nil,
        .boolean => |b| .{ .boolean = b },
        .integer => |n| .{ .integer = n },
        .float => |n| .{ .float = n },
        .char => |c| .{ .char = c },
        .string => |s| .{ .string = s },
        .symbol => |sym| .{ .symbol = .{ .ns = sym.ns, .name = sym.name } },
        .keyword => |sym| blk: {
            if (sym.auto_resolve) {
                if (ns) |current_ns| {
                    if (sym.ns) |alias| {
                        // ::alias/name — resolve alias to full namespace
                        const resolved = current_ns.getAlias(alias);
                        break :blk .{ .keyword = .{ .ns = if (resolved) |r| r.name else alias, .name = sym.name } };
                    } else {
                        // ::name — use current namespace
                        break :blk .{ .keyword = .{ .ns = current_ns.name, .name = sym.name } };
                    }
                } else {
                    // No namespace available — fallback to sym.ns
                    break :blk .{ .keyword = .{ .ns = sym.ns, .name = sym.name } };
                }
            } else {
                break :blk .{ .keyword = .{ .ns = sym.ns, .name = sym.name } };
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
            return .{ .list = lst };
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
            return .{ .vector = vec };
        },
        .map => |items| {
            const vals = try allocator.alloc(Value, items.len);
            for (items, 0..) |item, i| {
                vals[i] = try formToValueWithNs(allocator, item, ns);
            }
            const m = try allocator.create(collections.PersistentArrayMap);
            m.* = .{ .entries = vals };
            return .{ .map = m };
        },
        .set => |items| {
            const vals = try allocator.alloc(Value, items.len);
            for (items, 0..) |item, i| {
                vals[i] = try formToValueWithNs(allocator, item, ns);
            }
            const s = try allocator.create(collections.PersistentHashSet);
            s.* = .{ .items = vals };
            return .{ .set = s };
        },
        .regex => |pattern| {
            // Compile regex so it survives the formToValue/valueToForm roundtrip
            const regex_mod = @import("regex/regex.zig");
            const matcher_mod = @import("regex/matcher.zig");
            const compiled = allocator.create(regex_mod.CompiledRegex) catch return error.OutOfMemory;
            compiled.* = matcher_mod.compile(allocator, pattern) catch {
                // Fallback to string if compilation fails (shouldn't happen — reader validated)
                return .{ .string = pattern };
            };
            const pat = try allocator.create(value_mod.Pattern);
            pat.* = .{
                .source = pattern,
                .compiled = @ptrCast(compiled),
                .group_count = compiled.group_count,
            };
            return .{ .regex = pat };
        },
        .tag => .nil, // tagged literals not supported in macro args
    };
}

/// Convert a runtime Value back to a Form (for re-analysis after macro expansion).
/// Collections are recursively converted. Source info restored from list/vector fields.
pub fn valueToForm(allocator: Allocator, val: Value) Allocator.Error!Form {
    return switch (val) {
        .nil => Form{ .data = .nil },
        .boolean => |b| Form{ .data = .{ .boolean = b } },
        .integer => |n| Form{ .data = .{ .integer = n } },
        .float => |n| Form{ .data = .{ .float = n } },
        .char => |c| Form{ .data = .{ .char = c } },
        .string => |s| Form{ .data = .{ .string = s } },
        .symbol => |sym| Form{ .data = .{ .symbol = .{ .ns = sym.ns, .name = sym.name } } },
        .keyword => |k| Form{ .data = .{ .keyword = .{ .ns = k.ns, .name = k.name } } },
        .list => |lst| {
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
        .vector => |vec| {
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
        .map => |m| {
            const forms = try allocator.alloc(Form, m.entries.len);
            for (m.entries, 0..) |item, i| {
                forms[i] = try valueToForm(allocator, item);
            }
            return Form{ .data = .{ .map = forms } };
        },
        .hash_map => |hm| {
            const entries = try hm.toEntries(allocator);
            const forms = try allocator.alloc(Form, entries.len);
            for (entries, 0..) |item, i| {
                forms[i] = try valueToForm(allocator, item);
            }
            return Form{ .data = .{ .map = forms } };
        },
        .set => |s| {
            const forms = try allocator.alloc(Form, s.items.len);
            for (s.items, 0..) |item, i| {
                forms[i] = try valueToForm(allocator, item);
            }
            return Form{ .data = .{ .set = forms } };
        },
        .var_ref => |v| {
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
        .regex => |pat| Form{ .data = .{ .regex = pat.source } },
        // Non-data values become nil (shouldn't appear in macro output)
        .fn_val, .builtin_fn, .atom, .volatile_ref, .protocol, .protocol_fn, .multi_fn, .delay, .reduced, .transient_vector, .transient_map, .transient_set, .chunked_cons, .chunk_buffer, .array_chunk, .wasm_module, .wasm_fn => Form{ .data = .nil },
    };
}

// === Tests ===

const testing = std.testing;

test "formToValue - primitives" {
    const alloc = testing.allocator;
    try testing.expectEqual(Value.nil, try formToValue(alloc, .{ .data = .nil }));
    try testing.expectEqual(Value{ .boolean = true }, try formToValue(alloc, .{ .data = .{ .boolean = true } }));
    try testing.expectEqual(Value{ .integer = 42 }, try formToValue(alloc, .{ .data = .{ .integer = 42 } }));
    try testing.expectEqual(Value{ .float = 3.14 }, try formToValue(alloc, .{ .data = .{ .float = 3.14 } }));
    try testing.expectEqual(Value{ .char = 'A' }, try formToValue(alloc, .{ .data = .{ .char = 'A' } }));
    try testing.expectEqualStrings("hello", (try formToValue(alloc, .{ .data = .{ .string = "hello" } })).string);
}

test "formToValue - symbol" {
    const alloc = testing.allocator;
    const val = try formToValue(alloc, .{ .data = .{ .symbol = .{ .ns = null, .name = "foo" } } });
    try testing.expectEqualStrings("foo", val.symbol.name);
    try testing.expect(val.symbol.ns == null);
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
    try testing.expect(val == .list);
    try testing.expectEqual(@as(usize, 2), val.list.items.len);
    try testing.expectEqual(Value{ .integer = 1 }, val.list.items[0]);
    try testing.expectEqual(Value{ .integer = 2 }, val.list.items[1]);
}

test "valueToForm - primitives" {
    const alloc = testing.allocator;
    const f1 = try valueToForm(alloc, .nil);
    try testing.expect(f1.data == .nil);
    const f2 = try valueToForm(alloc, .{ .integer = 42 });
    try testing.expectEqual(@as(i64, 42), f2.data.integer);
    const f3 = try valueToForm(alloc, .{ .string = "hello" });
    try testing.expectEqualStrings("hello", f3.data.string);
}

test "valueToForm - symbol" {
    const alloc = testing.allocator;
    const f = try valueToForm(alloc, .{ .symbol = .{ .ns = "ns", .name = "bar" } });
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
    try testing.expectEqual(@as(u32, 5), val.list.source_line);
    try testing.expectEqual(@as(u16, 10), val.list.source_column);

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

    try testing.expectEqual(@as(u32, 3), val.vector.source_line);
    try testing.expectEqual(@as(u16, 7), val.vector.source_column);

    const restored = try valueToForm(alloc, val);
    try testing.expectEqual(@as(u32, 3), restored.line);
    try testing.expectEqual(@as(u16, 7), restored.column);
}
