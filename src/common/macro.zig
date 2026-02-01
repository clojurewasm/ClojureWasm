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

/// Convert a Form to a runtime Value (for passing to macro functions).
/// Collections are recursively converted. Source info is lost.
pub fn formToValue(allocator: Allocator, form: Form) Allocator.Error!Value {
    return switch (form.data) {
        .nil => .nil,
        .boolean => |b| .{ .boolean = b },
        .integer => |n| .{ .integer = n },
        .float => |n| .{ .float = n },
        .char => |c| .{ .char = c },
        .string => |s| .{ .string = s },
        .symbol => |sym| .{ .symbol = .{ .ns = sym.ns, .name = sym.name } },
        .keyword => |sym| .{ .keyword = .{ .ns = sym.ns, .name = sym.name } },
        .list => |items| {
            const vals = try allocator.alloc(Value, items.len);
            for (items, 0..) |item, i| {
                vals[i] = try formToValue(allocator, item);
            }
            const lst = try allocator.create(collections.PersistentList);
            lst.* = .{ .items = vals };
            return .{ .list = lst };
        },
        .vector => |items| {
            const vals = try allocator.alloc(Value, items.len);
            for (items, 0..) |item, i| {
                vals[i] = try formToValue(allocator, item);
            }
            const vec = try allocator.create(collections.PersistentVector);
            vec.* = .{ .items = vals };
            return .{ .vector = vec };
        },
        .map => |items| {
            const vals = try allocator.alloc(Value, items.len);
            for (items, 0..) |item, i| {
                vals[i] = try formToValue(allocator, item);
            }
            const m = try allocator.create(collections.PersistentArrayMap);
            m.* = .{ .entries = vals };
            return .{ .map = m };
        },
        .set => |items| {
            const vals = try allocator.alloc(Value, items.len);
            for (items, 0..) |item, i| {
                vals[i] = try formToValue(allocator, item);
            }
            const s = try allocator.create(collections.PersistentHashSet);
            s.* = .{ .items = vals };
            return .{ .set = s };
        },
        .regex => |pattern| .{ .string = pattern }, // regex as string
        .tag => .nil, // tagged literals not supported in macro args
    };
}

/// Convert a runtime Value back to a Form (for re-analysis after macro expansion).
/// Collections are recursively converted. Source info set to 0.
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
            }
            return Form{ .data = .{ .list = forms } };
        },
        .vector => |vec| {
            const forms = try allocator.alloc(Form, vec.items.len);
            for (vec.items, 0..) |item, i| {
                forms[i] = try valueToForm(allocator, item);
            }
            return Form{ .data = .{ .vector = forms } };
        },
        .map => |m| {
            const forms = try allocator.alloc(Form, m.entries.len);
            for (m.entries, 0..) |item, i| {
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
        // Non-data values become nil (shouldn't appear in macro output)
        .fn_val, .builtin_fn, .atom => Form{ .data = .nil },
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
