// Type predicate functions — nil?, number?, string?, etc.
//
// Simple type checks on Value tag. All take exactly 1 argument
// and return a boolean.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const Env = @import("../env.zig").Env;

/// Runtime env for bound? resolution. Set by bootstrap.setupMacroEnv.
/// Module-level (D3 known exception, single-thread only).
pub var current_env: ?*Env = null;

// ============================================================
// Implementations
// ============================================================

fn predicate(args: []const Value, comptime check: fn (Value) bool) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value{ .boolean = check(args[0]) };
}

fn isNil(v: Value) bool {
    return v == .nil;
}
fn isBoolean(v: Value) bool {
    return v == .boolean;
}
fn isNumber(v: Value) bool {
    return v == .integer or v == .float;
}
fn isInteger(v: Value) bool {
    return v == .integer;
}
fn isFloat(v: Value) bool {
    return v == .float;
}
fn isString(v: Value) bool {
    return v == .string;
}
fn isKeyword(v: Value) bool {
    return v == .keyword;
}
fn isSymbol(v: Value) bool {
    return v == .symbol;
}
fn isMap(v: Value) bool {
    return v == .map;
}
fn isVector(v: Value) bool {
    return v == .vector;
}
fn isSeq(v: Value) bool {
    return v == .list;
}
fn isFn(v: Value) bool {
    return v == .fn_val or v == .builtin_fn;
}
fn isSet(v: Value) bool {
    return v == .set;
}
fn isColl(v: Value) bool {
    return v == .list or v == .vector or v == .map or v == .set;
}
fn isChar(v: Value) bool {
    return v == .char;
}

// Builtin wrappers (matching BuiltinFn signature)

pub fn nilPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isNil);
}
pub fn booleanPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isBoolean);
}
pub fn numberPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isNumber);
}
pub fn integerPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isInteger);
}
pub fn floatPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isFloat);
}
pub fn stringPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isString);
}
pub fn keywordPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isKeyword);
}
pub fn symbolPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isSymbol);
}
pub fn mapPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isMap);
}
pub fn vectorPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isVector);
}
pub fn seqPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isSeq);
}
pub fn fnPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isFn);
}
pub fn setPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isSet);
}
pub fn collPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isColl);
}
pub fn charPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isChar);
}

// Numeric predicates
fn isZero(v: Value) bool {
    return switch (v) {
        .integer => |i| i == 0,
        .float => |f| f == 0.0,
        else => false,
    };
}
fn isPos(v: Value) bool {
    return switch (v) {
        .integer => |i| i > 0,
        .float => |f| f > 0.0,
        else => false,
    };
}
fn isNeg(v: Value) bool {
    return switch (v) {
        .integer => |i| i < 0,
        .float => |f| f < 0.0,
        else => false,
    };
}
fn isEven(v: Value) bool {
    return switch (v) {
        .integer => |i| @mod(i, 2) == 0,
        else => false,
    };
}
fn isOdd(v: Value) bool {
    return switch (v) {
        .integer => |i| @mod(i, 2) != 0,
        else => false,
    };
}

pub fn zeroPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isZero);
}
pub fn posPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isPos);
}
pub fn negPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isNeg);
}
pub fn evenPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isEven);
}
pub fn oddPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isOdd);
}

// not is not a type predicate but a core function
pub fn notFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value{ .boolean = !args[0].isTruthy() };
}

/// (type x) — returns a keyword indicating the runtime type of x.
pub fn typeFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const name: []const u8 = switch (args[0]) {
        .nil => "nil",
        .boolean => "boolean",
        .integer => "integer",
        .float => "float",
        .char => "char",
        .string => "string",
        .symbol => "symbol",
        .keyword => "keyword",
        .list => "list",
        .vector => "vector",
        .map => "map",
        .set => "set",
        .fn_val, .builtin_fn => "function",
        .atom => "atom",
        .protocol => "protocol",
        .protocol_fn => "protocol-fn",
        .multi_fn => "multi-fn",
        .lazy_seq => "lazy-seq",
        .cons => "cons",
    };
    return Value{ .keyword = .{ .ns = null, .name = name } };
}

/// (bound? sym) — true if the symbol resolves to a Var with a binding.
/// Takes a quoted symbol, resolves in current namespace.
pub fn boundPred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] != .symbol) return error.TypeError;
    const sym_name = args[0].symbol.name;
    const env = current_env orelse return Value{ .boolean = false };
    const ns = env.current_ns orelse return Value{ .boolean = false };
    const v = ns.resolve(sym_name) orelse return Value{ .boolean = false };
    // Var exists and has been bound (root != .nil means bound)
    // Note: in full Clojure, unbound Vars are distinct from nil-bound.
    // We treat existence in namespace as "bound" since intern + bindRoot
    // is always paired in our implementation.
    _ = v;
    return Value{ .boolean = true };
}

/// (satisfies? protocol x) — true if x's type has an impl for the protocol.
pub fn satisfiesPred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .protocol) return error.TypeError;
    const protocol = args[0].protocol;
    const type_key: Value = .{ .string = switch (args[1]) {
        .nil => "nil",
        .boolean => "boolean",
        .integer => "integer",
        .float => "float",
        .char => "char",
        .string => "string",
        .symbol => "symbol",
        .keyword => "keyword",
        .list => "list",
        .vector => "vector",
        .map => "map",
        .set => "set",
        .fn_val, .builtin_fn => "function",
        .atom => "atom",
        .protocol => "protocol",
        .protocol_fn => "protocol_fn",
        .multi_fn => "multi_fn",
        .lazy_seq => "lazy_seq",
        .cons => "cons",
    } };
    return Value{ .boolean = protocol.impls.get(type_key) != null };
}

// ============================================================
// BuiltinDef table
// ============================================================

pub const builtins = [_]BuiltinDef{
    .{ .name = "nil?", .func = &nilPred, .doc = "Returns true if x is nil, false otherwise.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "boolean?", .func = &booleanPred, .doc = "Return true if x is a Boolean.", .arglists = "([x])", .added = "1.9" },
    .{ .name = "number?", .func = &numberPred, .doc = "Returns true if x is a Number.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "integer?", .func = &integerPred, .doc = "Return true if n is an integer.", .arglists = "([n])", .added = "1.9" },
    .{ .name = "float?", .func = &floatPred, .doc = "Returns true if n is a floating point number.", .arglists = "([n])", .added = "1.9" },
    .{ .name = "string?", .func = &stringPred, .doc = "Return true if x is a String.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "keyword?", .func = &keywordPred, .doc = "Return true if x is a Keyword.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "symbol?", .func = &symbolPred, .doc = "Return true if x is a Symbol.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "map?", .func = &mapPred, .doc = "Return true if x implements IPersistentMap.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "vector?", .func = &vectorPred, .doc = "Return true if x implements IPersistentVector.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "seq?", .func = &seqPred, .doc = "Return true if x implements ISeq.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "fn?", .func = &fnPred, .doc = "Return true if x is a function.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "set?", .func = &setPred, .doc = "Returns true if x implements IPersistentSet.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "coll?", .func = &collPred, .doc = "Returns true if x implements IPersistentCollection.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "char?", .func = &charPred, .doc = "Return true if x is a Character.", .arglists = "([x])", .added = "1.5" },
    .{ .name = "zero?", .func = &zeroPred, .doc = "Returns true if num is zero, else false.", .arglists = "([num])", .added = "1.0" },
    .{ .name = "pos?", .func = &posPred, .doc = "Returns true if num is greater than zero, else false.", .arglists = "([num])", .added = "1.0" },
    .{ .name = "neg?", .func = &negPred, .doc = "Returns true if num is less than zero, else false.", .arglists = "([num])", .added = "1.0" },
    .{ .name = "even?", .func = &evenPred, .doc = "Returns true if n is even, throws an exception if n is not an integer.", .arglists = "([n])", .added = "1.0" },
    .{ .name = "odd?", .func = &oddPred, .doc = "Returns true if n is odd, throws an exception if n is not an integer.", .arglists = "([n])", .added = "1.0" },
    .{ .name = "not", .func = &notFn, .doc = "Returns true if x is logical false, false otherwise.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "satisfies?", .func = &satisfiesPred, .doc = "Returns true if x satisfies the protocol.", .arglists = "([protocol x])", .added = "1.2" },
    .{ .name = "type", .func = &typeFn, .doc = "Returns the type of x as a keyword.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "class", .func = &typeFn, .doc = "Returns the type of x as a keyword.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "bound?", .func = &boundPred, .doc = "Returns true if the var/symbol has been bound to a value.", .arglists = "([sym])", .added = "1.2" },
};

// === Tests ===

const testing = std.testing;
const test_alloc = testing.allocator;

test "nil? predicate" {
    try testing.expectEqual(Value{ .boolean = true }, try nilPred(test_alloc, &.{Value.nil}));
    try testing.expectEqual(Value{ .boolean = false }, try nilPred(test_alloc, &.{Value{ .integer = 1 }}));
}

test "number? predicate" {
    try testing.expectEqual(Value{ .boolean = true }, try numberPred(test_alloc, &.{Value{ .integer = 42 }}));
    try testing.expectEqual(Value{ .boolean = true }, try numberPred(test_alloc, &.{Value{ .float = 3.14 }}));
    try testing.expectEqual(Value{ .boolean = false }, try numberPred(test_alloc, &.{Value{ .string = "hello" }}));
}

test "string? predicate" {
    try testing.expectEqual(Value{ .boolean = true }, try stringPred(test_alloc, &.{Value{ .string = "hi" }}));
    try testing.expectEqual(Value{ .boolean = false }, try stringPred(test_alloc, &.{Value{ .integer = 1 }}));
}

test "keyword? predicate" {
    try testing.expectEqual(Value{ .boolean = true }, try keywordPred(test_alloc, &.{Value{ .keyword = .{ .name = "a", .ns = null } }}));
    try testing.expectEqual(Value{ .boolean = false }, try keywordPred(test_alloc, &.{Value{ .string = "a" }}));
}

test "coll? predicate" {
    const items = [_]Value{};
    var lst = value_mod.PersistentList{ .items = &items };
    var vec = value_mod.PersistentVector{ .items = &items };
    try testing.expectEqual(Value{ .boolean = true }, try collPred(test_alloc, &.{Value{ .list = &lst }}));
    try testing.expectEqual(Value{ .boolean = true }, try collPred(test_alloc, &.{Value{ .vector = &vec }}));
    try testing.expectEqual(Value{ .boolean = false }, try collPred(test_alloc, &.{Value{ .integer = 1 }}));
}

test "not function" {
    try testing.expectEqual(Value{ .boolean = true }, try notFn(test_alloc, &.{Value.nil}));
    try testing.expectEqual(Value{ .boolean = true }, try notFn(test_alloc, &.{Value{ .boolean = false }}));
    try testing.expectEqual(Value{ .boolean = false }, try notFn(test_alloc, &.{Value{ .integer = 1 }}));
    try testing.expectEqual(Value{ .boolean = false }, try notFn(test_alloc, &.{Value{ .boolean = true }}));
}

test "fn? predicate" {
    const f = value_mod.Fn{ .proto = @as(*const anyopaque, @ptrFromInt(1)), .closure_bindings = null };
    try testing.expectEqual(Value{ .boolean = true }, try fnPred(test_alloc, &.{Value{ .fn_val = &f }}));
    try testing.expectEqual(Value{ .boolean = false }, try fnPred(test_alloc, &.{Value{ .integer = 1 }}));
}

test "zero? predicate" {
    try testing.expectEqual(Value{ .boolean = true }, try zeroPred(test_alloc, &.{Value{ .integer = 0 }}));
    try testing.expectEqual(Value{ .boolean = true }, try zeroPred(test_alloc, &.{Value{ .float = 0.0 }}));
    try testing.expectEqual(Value{ .boolean = false }, try zeroPred(test_alloc, &.{Value{ .integer = 1 }}));
    try testing.expectEqual(Value{ .boolean = false }, try zeroPred(test_alloc, &.{Value{ .float = -0.5 }}));
}

test "pos? predicate" {
    try testing.expectEqual(Value{ .boolean = true }, try posPred(test_alloc, &.{Value{ .integer = 1 }}));
    try testing.expectEqual(Value{ .boolean = false }, try posPred(test_alloc, &.{Value{ .integer = 0 }}));
    try testing.expectEqual(Value{ .boolean = false }, try posPred(test_alloc, &.{Value{ .integer = -1 }}));
    try testing.expectEqual(Value{ .boolean = true }, try posPred(test_alloc, &.{Value{ .float = 0.1 }}));
}

test "neg? predicate" {
    try testing.expectEqual(Value{ .boolean = true }, try negPred(test_alloc, &.{Value{ .integer = -1 }}));
    try testing.expectEqual(Value{ .boolean = false }, try negPred(test_alloc, &.{Value{ .integer = 0 }}));
    try testing.expectEqual(Value{ .boolean = false }, try negPred(test_alloc, &.{Value{ .integer = 1 }}));
    try testing.expectEqual(Value{ .boolean = true }, try negPred(test_alloc, &.{Value{ .float = -0.1 }}));
}

test "even? predicate" {
    try testing.expectEqual(Value{ .boolean = true }, try evenPred(test_alloc, &.{Value{ .integer = 0 }}));
    try testing.expectEqual(Value{ .boolean = true }, try evenPred(test_alloc, &.{Value{ .integer = 2 }}));
    try testing.expectEqual(Value{ .boolean = false }, try evenPred(test_alloc, &.{Value{ .integer = 1 }}));
    try testing.expectEqual(Value{ .boolean = true }, try evenPred(test_alloc, &.{Value{ .integer = -4 }}));
}

test "odd? predicate" {
    try testing.expectEqual(Value{ .boolean = true }, try oddPred(test_alloc, &.{Value{ .integer = 1 }}));
    try testing.expectEqual(Value{ .boolean = true }, try oddPred(test_alloc, &.{Value{ .integer = -3 }}));
    try testing.expectEqual(Value{ .boolean = false }, try oddPred(test_alloc, &.{Value{ .integer = 0 }}));
    try testing.expectEqual(Value{ .boolean = false }, try oddPred(test_alloc, &.{Value{ .integer = 2 }}));
}

test "builtins table has 25 entries" {
    try testing.expectEqual(25, builtins.len);
}

test "builtins all have func" {
    for (builtins) |b| {
        try testing.expect(b.func != null);
    }
}
