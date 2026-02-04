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
fn isList(v: Value) bool {
    return v == .list;
}
fn isChar(v: Value) bool {
    return v == .char;
}
fn isSequential(v: Value) bool {
    return v == .list or v == .vector;
}
fn isAssociative(v: Value) bool {
    return v == .map or v == .vector;
}
fn isIFn(v: Value) bool {
    return v == .fn_val or v == .builtin_fn or v == .keyword or v == .map or v == .set or v == .vector or v == .symbol;
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
pub fn listPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isList);
}
pub fn intPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isInteger);
}
pub fn charPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isChar);
}
pub fn sequentialPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isSequential);
}
pub fn associativePred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isAssociative);
}
pub fn ifnPred(_: Allocator, args: []const Value) anyerror!Value {
    return predicate(args, isIFn);
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
        .volatile_ref => "volatile",
        .regex => "regex",
        .protocol => "protocol",
        .protocol_fn => "protocol-fn",
        .multi_fn => "multi-fn",
        .lazy_seq => "lazy-seq",
        .cons => "cons",
        .var_ref => "var",
        .reduced => "reduced",
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

/// (var? x) — true if x is a Var reference.
pub fn varPred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value{ .boolean = args[0] == .var_ref };
}

/// (var-get v) — returns the value of the Var.
pub fn varGetFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] != .var_ref) return error.TypeError;
    return args[0].var_ref.deref();
}

/// (var-set v val) — sets the root binding of the Var. Returns val.
pub fn varSetFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .var_ref) return error.TypeError;
    args[0].var_ref.bindRoot(args[1]);
    return args[1];
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
        .volatile_ref => "volatile",
        .regex => "regex",
        .protocol => "protocol",
        .protocol_fn => "protocol_fn",
        .multi_fn => "multi_fn",
        .lazy_seq => "lazy_seq",
        .cons => "cons",
        .var_ref => "var",
        .reduced => "reduced",
    } };
    return Value{ .boolean = protocol.impls.get(type_key) != null };
}

// ============================================================
// Hash & identity functions
// ============================================================

/// (hash x) — returns the hash code of x.
pub fn hashFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value{ .integer = computeHash(args[0]) };
}

fn computeHash(v: Value) i64 {
    return switch (v) {
        .nil => 0,
        .boolean => |b| if (b) @as(i64, 1231) else @as(i64, 1237),
        .integer => |n| n,
        .float => |f| @as(i64, @intFromFloat(f * 1000003)),
        .char => |c| @as(i64, @intCast(c)),
        .string => |s| stringHash(s),
        .keyword => |kw| blk: {
            var h: i64 = 0x9e3779b9;
            if (kw.ns) |ns| {
                h = h *% 31 +% stringHash(ns);
            }
            h = h *% 31 +% stringHash(kw.name);
            break :blk h;
        },
        .symbol => |sym| blk: {
            var h: i64 = 0x517cc1b7;
            if (sym.ns) |ns| {
                h = h *% 31 +% stringHash(ns);
            }
            h = h *% 31 +% stringHash(sym.name);
            break :blk h;
        },
        else => 42,
    };
}

fn stringHash(s: []const u8) i64 {
    var h: i64 = 0;
    for (s) |c| {
        h = h *% 31 +% @as(i64, c);
    }
    return h;
}

/// (identical? x y) — tests if x and y are the same object.
pub fn identicalPred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const a = args[0];
    const b = args[1];

    const a_tag = std.meta.activeTag(a);
    const b_tag = std.meta.activeTag(b);
    if (a_tag != b_tag) return Value{ .boolean = false };

    const result: bool = switch (a) {
        .nil => true,
        .boolean => |av| av == b.boolean,
        .integer => |av| av == b.integer,
        .float => |av| av == b.float,
        .char => |av| av == b.char,
        .string => |av| av.ptr == b.string.ptr and av.len == b.string.len,
        .keyword => |av| std.mem.eql(u8, av.name, b.keyword.name) and eqlOptNs(av.ns, b.keyword.ns),
        .symbol => |av| std.mem.eql(u8, av.name, b.symbol.name) and eqlOptNs(av.ns, b.symbol.ns),
        .vector => |av| av == b.vector,
        .list => |av| av == b.list,
        .map => |av| av == b.map,
        .set => |av| av == b.set,
        .fn_val => |av| av == b.fn_val,
        .atom => |av| av == b.atom,
        else => false,
    };
    return Value{ .boolean = result };
}

fn eqlOptNs(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// (== x y & more) — numeric equality. Returns true if all nums are numerically equal.
/// All arguments must be numbers; otherwise throws TypeError.
pub fn numericEqFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return error.ArityError;
    if (args.len == 1) return Value{ .boolean = true };

    for (args) |a| {
        if (a != .integer and a != .float) return error.TypeError;
    }

    const first: f64 = if (args[0] == .integer) @floatFromInt(args[0].integer) else args[0].float;
    for (args[1..]) |b| {
        const fb: f64 = if (b == .integer) @floatFromInt(b.integer) else b.float;
        if (first != fb) return Value{ .boolean = false };
    }
    return Value{ .boolean = true };
}

// ============================================================
// Reduced functions (early termination for reduce)
// ============================================================

const Reduced = value_mod.Reduced;

/// (reduced x) — wraps x so that reduce will terminate with the value x.
pub fn reducedFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const r = try allocator.create(Reduced);
    r.* = .{ .value = args[0] };
    return Value{ .reduced = r };
}

/// (reduced? x) — returns true if x is the result of a call to reduced.
pub fn isReducedPred(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return Value{ .boolean = args[0] == .reduced };
}

/// (unreduced x) — if x is reduced, returns the value that was wrapped, else returns x.
pub fn unreducedFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .reduced => |r| r.value,
        else => args[0],
    };
}

/// (ensure-reduced x) — if x is already reduced, returns it, else wraps in reduced.
pub fn ensureReducedFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] == .reduced) return args[0];
    const r = try allocator.create(Reduced);
    r.* = .{ .value = args[0] };
    return Value{ .reduced = r };
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
    .{ .name = "list?", .func = &listPred, .doc = "Returns true if x implements IPersistentList.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "int?", .func = &intPred, .doc = "Return true if x is a fixed precision integer.", .arglists = "([x])", .added = "1.9" },
    .{ .name = "char?", .func = &charPred, .doc = "Return true if x is a Character.", .arglists = "([x])", .added = "1.5" },
    .{ .name = "sequential?", .func = &sequentialPred, .doc = "Return true if coll implements Sequential.", .arglists = "([coll])", .added = "1.0" },
    .{ .name = "associative?", .func = &associativePred, .doc = "Returns true if coll implements Associative.", .arglists = "([coll])", .added = "1.0" },
    .{ .name = "ifn?", .func = &ifnPred, .doc = "Returns true if x implements IFn. Note that many data structures (e.g. sets and maps) implement IFn.", .arglists = "([x])", .added = "1.0" },
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
    .{ .name = "var?", .func = &varPred, .doc = "Returns true if v is of type clojure.lang.Var.", .arglists = "([v])", .added = "1.0" },
    .{ .name = "var-get", .func = &varGetFn, .doc = "Gets the value in the var object.", .arglists = "([x])", .added = "1.0" },
    .{ .name = "var-set", .func = &varSetFn, .doc = "Sets the value in the var object to val.", .arglists = "([x val])", .added = "1.0" },
    .{ .name = "hash", .func = &hashFn, .doc = "Returns the hash code of its argument. Note this is the hash code consistent with =, and thus is different than .hashCode for Integer, Short, Byte and Clojure collections.", .arglists = "([x])", .added = "1.6" },
    .{ .name = "identical?", .func = &identicalPred, .doc = "Tests if 2 arguments are the same object.", .arglists = "([x y])", .added = "1.0" },
    .{ .name = "==", .func = &numericEqFn, .doc = "Returns non-nil if nums all have the equivalent value, otherwise false.", .arglists = "([x] [x y] [x y & more])", .added = "1.0" },
    .{ .name = "reduced", .func = &reducedFn, .doc = "Wraps x in a way such that a reduce will terminate with the value x.", .arglists = "([x])", .added = "1.5" },
    .{ .name = "reduced?", .func = &isReducedPred, .doc = "Returns true if x is the result of a call to reduced.", .arglists = "([x])", .added = "1.5" },
    .{ .name = "unreduced", .func = &unreducedFn, .doc = "If x is reduced?, returns (deref x), else returns x.", .arglists = "([x])", .added = "1.7" },
    .{ .name = "ensure-reduced", .func = &ensureReducedFn, .doc = "If x is already reduced?, returns it, else returns (reduced x).", .arglists = "([x])", .added = "1.7" },
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

// --- hash tests ---

test "hash of integer returns itself" {
    const result = try hashFn(test_alloc, &.{Value{ .integer = 42 }});
    try testing.expect(result == .integer);
    try testing.expectEqual(@as(i64, 42), result.integer);
}

test "hash of nil returns 0" {
    const result = try hashFn(test_alloc, &.{Value.nil});
    try testing.expect(result == .integer);
    try testing.expectEqual(@as(i64, 0), result.integer);
}

test "hash of boolean" {
    const t = try hashFn(test_alloc, &.{Value{ .boolean = true }});
    const f = try hashFn(test_alloc, &.{Value{ .boolean = false }});
    try testing.expect(t.integer != f.integer);
}

test "hash of string is deterministic" {
    const h1 = try hashFn(test_alloc, &.{Value{ .string = "hello" }});
    const h2 = try hashFn(test_alloc, &.{Value{ .string = "hello" }});
    try testing.expectEqual(h1.integer, h2.integer);
}

test "hash of different strings differ" {
    const h1 = try hashFn(test_alloc, &.{Value{ .string = "hello" }});
    const h2 = try hashFn(test_alloc, &.{Value{ .string = "world" }});
    try testing.expect(h1.integer != h2.integer);
}

test "hash arity check" {
    try testing.expectError(error.ArityError, hashFn(test_alloc, &.{}));
    try testing.expectError(error.ArityError, hashFn(test_alloc, &.{ Value.nil, Value.nil }));
}

// --- identical? tests ---

test "identical? same integer" {
    const result = try identicalPred(test_alloc, &.{ Value{ .integer = 42 }, Value{ .integer = 42 } });
    try testing.expectEqual(Value{ .boolean = true }, result);
}

test "identical? different integers" {
    const result = try identicalPred(test_alloc, &.{ Value{ .integer = 1 }, Value{ .integer = 2 } });
    try testing.expectEqual(Value{ .boolean = false }, result);
}

test "identical? different types" {
    const result = try identicalPred(test_alloc, &.{ Value{ .integer = 1 }, Value{ .string = "1" } });
    try testing.expectEqual(Value{ .boolean = false }, result);
}

test "identical? nil" {
    const result = try identicalPred(test_alloc, &.{ Value.nil, Value.nil });
    try testing.expectEqual(Value{ .boolean = true }, result);
}

test "identical? same keyword" {
    const result = try identicalPred(test_alloc, &.{
        Value{ .keyword = .{ .name = "a", .ns = null } },
        Value{ .keyword = .{ .name = "a", .ns = null } },
    });
    try testing.expectEqual(Value{ .boolean = true }, result);
}

// --- == tests ---

test "== numeric equality integers" {
    const result = try numericEqFn(test_alloc, &.{ Value{ .integer = 3 }, Value{ .integer = 3 } });
    try testing.expectEqual(Value{ .boolean = true }, result);
}

test "== numeric cross-type" {
    const result = try numericEqFn(test_alloc, &.{ Value{ .integer = 1 }, Value{ .float = 1.0 } });
    try testing.expectEqual(Value{ .boolean = true }, result);
}

test "== numeric inequality" {
    const result = try numericEqFn(test_alloc, &.{ Value{ .integer = 1 }, Value{ .integer = 2 } });
    try testing.expectEqual(Value{ .boolean = false }, result);
}

test "== non-numeric is error" {
    try testing.expectError(error.TypeError, numericEqFn(test_alloc, &.{ Value{ .string = "a" }, Value{ .string = "a" } }));
}

// --- reduced tests ---

test "reduced wraps a value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try reducedFn(arena.allocator(), &.{Value{ .integer = 42 }});
    try testing.expect(result == .reduced);
    try testing.expect(result.reduced.value.eql(.{ .integer = 42 }));
}

test "reduced? returns true for reduced values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try reducedFn(arena.allocator(), &.{Value{ .integer = 1 }});
    const result = try isReducedPred(test_alloc, &.{r});
    try testing.expectEqual(Value{ .boolean = true }, result);
}

test "reduced? returns false for normal values" {
    const result = try isReducedPred(test_alloc, &.{Value{ .integer = 1 }});
    try testing.expectEqual(Value{ .boolean = false }, result);
}

test "unreduced unwraps reduced" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try reducedFn(arena.allocator(), &.{Value{ .integer = 42 }});
    const result = try unreducedFn(test_alloc, &.{r});
    try testing.expect(result.eql(.{ .integer = 42 }));
}

test "unreduced passes through normal values" {
    const result = try unreducedFn(test_alloc, &.{Value{ .integer = 42 }});
    try testing.expect(result.eql(.{ .integer = 42 }));
}

test "ensure-reduced wraps non-reduced" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try ensureReducedFn(arena.allocator(), &.{Value{ .integer = 42 }});
    try testing.expect(result == .reduced);
    try testing.expect(result.reduced.value.eql(.{ .integer = 42 }));
}

test "ensure-reduced passes through reduced" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try reducedFn(arena.allocator(), &.{Value{ .integer = 42 }});
    const result = try ensureReducedFn(arena.allocator(), &.{r});
    try testing.expect(result == .reduced);
    try testing.expect(result.reduced.value.eql(.{ .integer = 42 }));
}

test "builtins table has 40 entries" {
    try testing.expectEqual(40, builtins.len);
}

test "builtins all have func" {
    for (builtins) |b| {
        try testing.expect(b.func != null);
    }
}
