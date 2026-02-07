// Wasm InterOp types — Value wrappers for Wasm module interaction (Phase 25).
//
// Provides WasmModule and WasmFunction types that wrap zware's Store/Module/
// Instance into ClojureWasm's Value system. These become first-class Clojure
// values accessible via (wasm/load ...) and (wasm/fn ...).

const std = @import("std");
const zware = @import("zware");
const Allocator = std.mem.Allocator;

/// Wasm value types exposed to Clojure code.
pub const WasmValType = enum {
    i32,
    i64,
    f32,
    f64,

    pub fn toZware(self: WasmValType) zware.ValType {
        return switch (self) {
            .i32 => .I32,
            .i64 => .I64,
            .f32 => .F32,
            .f64 => .F64,
        };
    }

    pub fn fromZware(vt: zware.ValType) ?WasmValType {
        return switch (vt) {
            .I32 => .i32,
            .I64 => .i64,
            .F32 => .f32,
            .F64 => .f64,
            else => null,
        };
    }
};

/// A loaded and instantiated Wasm module.
/// Heap-allocated because zware Instance holds a *Store pointer — the
/// struct must not move after instantiation.
pub const WasmModule = struct {
    allocator: Allocator,
    store: zware.Store,
    module: zware.Module,
    instance: zware.Instance,

    /// Load a Wasm module from binary bytes, decode, and instantiate.
    /// Returns a heap-allocated WasmModule (pointer-stable for zware).
    pub fn load(allocator: Allocator, wasm_bytes: []const u8) !*WasmModule {
        const self = try allocator.create(WasmModule);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.store = zware.Store.init(allocator);
        errdefer self.store.deinit();

        self.module = zware.Module.init(allocator, wasm_bytes);
        errdefer self.module.deinit();
        try self.module.decode();

        self.instance = zware.Instance.init(allocator, &self.store, self.module);
        errdefer self.instance.deinit();
        try self.instance.instantiate();

        return self;
    }

    pub fn deinit(self: *WasmModule) void {
        const allocator = self.allocator;
        self.instance.deinit();
        self.module.deinit();
        self.store.deinit();
        allocator.destroy(self);
    }

    /// Invoke an exported function by name.
    /// Args and results are passed as u64 arrays (zware convention).
    pub fn invoke(self: *WasmModule, name: []const u8, args: []u64, results: []u64) !void {
        try self.instance.invoke(name, args, results, .{});
    }
};

/// A bound Wasm function — module ref + export name + signature.
/// Returned by (wasm/fn mod "add" {:params [:i32 :i32] :results [:i32]}).
/// Callable as a first-class Clojure function via callFnVal dispatch.
pub const WasmFn = struct {
    module: *WasmModule,
    name: []const u8,
    param_types: []const WasmValType,
    result_types: []const WasmValType,

    /// Call this Wasm function with Clojure Value arguments.
    /// Converts Value args to u64[], invokes via zware, converts results back.
    pub fn call(self: *const WasmFn, allocator: Allocator, args: []const Value) !Value {
        if (args.len != self.param_types.len)
            return error.ArityError;

        // Convert Clojure Values to u64 args
        var wasm_args: [16]u64 = undefined;
        for (args, 0..) |arg, i| {
            wasm_args[i] = try valueToWasm(arg, self.param_types[i]);
        }

        // Invoke
        var wasm_results: [4]u64 = undefined;
        try self.module.invoke(
            self.name,
            wasm_args[0..args.len],
            wasm_results[0..self.result_types.len],
        );

        // Convert results back to Clojure Values
        if (self.result_types.len == 0) return Value.nil;
        return wasmToValue(allocator, wasm_results[0], self.result_types[0]);
    }
};

const Value = @import("../common/value.zig").Value;

/// Convert a Clojure Value to a Wasm u64 based on the expected type.
fn valueToWasm(val: Value, wasm_type: WasmValType) !u64 {
    return switch (wasm_type) {
        .i32 => switch (val) {
            .integer => |n| @bitCast(@as(i64, @intCast(@as(i32, @intCast(n))))),
            .boolean => |b| if (b) @as(u64, 1) else 0,
            .nil => 0,
            else => return error.TypeError,
        },
        .i64 => switch (val) {
            .integer => |n| @bitCast(n),
            .boolean => |b| if (b) @as(u64, 1) else 0,
            .nil => 0,
            else => return error.TypeError,
        },
        .f32 => switch (val) {
            .float => |f| @as(u64, @as(u32, @bitCast(@as(f32, @floatCast(f))))),
            .integer => |n| @as(u64, @as(u32, @bitCast(@as(f32, @floatFromInt(n))))),
            else => return error.TypeError,
        },
        .f64 => switch (val) {
            .float => |f| @bitCast(f),
            .integer => |n| @bitCast(@as(f64, @floatFromInt(n))),
            else => return error.TypeError,
        },
    };
}

/// Convert a Wasm u64 result to a Clojure Value based on the result type.
fn wasmToValue(_: Allocator, raw: u64, wasm_type: WasmValType) Value {
    return switch (wasm_type) {
        .i32 => .{ .integer = @as(i64, @as(i32, @bitCast(@as(u32, @truncate(raw))))) },
        .i64 => .{ .integer = @bitCast(raw) },
        .f32 => .{ .float = @as(f64, @as(f32, @bitCast(@as(u32, @truncate(raw))))) },
        .f64 => .{ .float = @bitCast(raw) },
    };
}

// === Tests ===

const testing = std.testing;

test "zware smoke test — load and call add(3, 4)" {
    const wasm_bytes = @embedFile("testdata/01_add.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    var args = [_]u64{ 3, 4 };
    var results = [_]u64{0};
    try wasm_mod.invoke("add", &args, &results);

    try testing.expectEqual(@as(u64, 7), results[0]);
}

test "zware smoke test — fibonacci(10) = 55" {
    const wasm_bytes = @embedFile("testdata/02_fibonacci.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    var args = [_]u64{10};
    var results = [_]u64{0};
    try wasm_mod.invoke("fib", &args, &results);

    try testing.expectEqual(@as(u64, 55), results[0]);
}

test "WasmValType conversion" {
    try testing.expectEqual(zware.ValType.I32, WasmValType.i32.toZware());
    try testing.expectEqual(zware.ValType.F64, WasmValType.f64.toZware());
    try testing.expectEqual(WasmValType.i64, WasmValType.fromZware(.I64).?);
    try testing.expect(WasmValType.fromZware(.FuncRef) == null);
}
