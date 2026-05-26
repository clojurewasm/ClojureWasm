// SPDX-License-Identifier: EPL-2.0
//! Protocol primitives for the `rt/` namespace.
//!
//! Per ADR-0008 amendment 2 (Phase 7.2 Alt 1 = "macros over
//! primitives" pattern) — cycle 7's `defprotocol` macro lowers to
//! these Layer-2 primitives plus a `def`; no special analyzer Node
//! is involved. These wrap the runtime-layer helpers landed in row
//! 7.3 cycles 1-5 (`extendTypeWithImpls`, `makeProtocol`,
//! `makeProtocolFn`, `satisfies`).
//!
//! Cycle 6 scope: `__make-protocol!`, `__make-protocol-fn!`,
//! `__satisfies?`. `__extend-type!` defers to cycle 6.5 alongside
//! the `.type_descriptor` Value wrap migration (Step 0.6 finding —
//! cycles 1-5 surfaced the runtime helpers but did not migrate
//! TypeDescriptor to a Value-wrappable shape; the wrap lands as a
//! thin `TypeDescriptorRef` extern struct rather than churning the
//! 11 TypeDescriptor instantiation sites).

const std = @import("std");
const value = @import("../../runtime/value/value.zig");
const Value = value.Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const protocol_mod = @import("../../runtime/protocol.zig");
const symbol_mod = @import("../../runtime/symbol.zig");
const string_mod = @import("../../runtime/collection/string.zig");
const vector_mod = @import("../../runtime/collection/vector.zig");
const td_mod = @import("../../runtime/type_descriptor.zig");

const MethodEntry = protocol_mod.MethodEntry;
const ProtocolDescriptor = protocol_mod.ProtocolDescriptor;

/// Build the protocol's fully-qualified name from a Symbol Value,
/// allocating on `rt.gc.infra` so the slice is process-lifetime
/// (matches `ProtocolDescriptor.fqcn_ptr/_len` ownership).
fn allocFqcn(rt: *Runtime, sym_val: Value) ![]const u8 {
    const sym = symbol_mod.asSymbol(sym_val);
    if (sym.ns) |ns| {
        const buf = try rt.gc.infra.alloc(u8, ns.len + 1 + sym.name.len);
        @memcpy(buf[0..ns.len], ns);
        buf[ns.len] = '/';
        @memcpy(buf[ns.len + 1 ..], sym.name);
        return buf;
    }
    return rt.gc.infra.dupe(u8, sym.name);
}

/// Build the MethodEntry array for the descriptor from a Clojure
/// vector of method-name Symbols. cycle 6 keeps the method-spec
/// surface minimal: each element is a Symbol whose `.name` becomes
/// the entry's `name` (arity defaults to 1, matching the dispatch
/// surface which discriminates by method name today; row 7.4
/// `definterface` extends to arity overload). The slice is
/// allocated on `rt.gc.infra` so it lives for the descriptor.
fn allocMethods(rt: *Runtime, methods_vec: Value, loc: SourceLocation) ![]const MethodEntry {
    const len = vector_mod.count(methods_vec);
    const buf = try rt.gc.infra.alloc(MethodEntry, len);
    errdefer rt.gc.infra.free(buf);
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const elt = vector_mod.nth(methods_vec, i);
        if (elt.tag() != .symbol) {
            return error_catalog.raise(.type_arg_invalid, loc, .{
                .fn_name = "__make-protocol!",
                .expected = "symbol",
                .actual = @tagName(elt.tag()),
            });
        }
        const sym = symbol_mod.asSymbol(elt);
        buf[i] = .{ .name = sym.name, .arity = 1 };
    }
    return buf;
}

/// `(rt/__make-protocol! 'name methods-vec)` — allocate a
/// ProtocolDescriptor Value on `rt.gc.infra`. `name` is a Symbol
/// (`'user/ISeq`); `methods-vec` is a Vector of method-name Symbols
/// (`['first 'rest 'cons]`). Returns a `.protocol`-tagged Value.
pub fn makeProtocol(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__make-protocol!", args, 2, loc);
    if (args[0].tag() != .symbol) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "__make-protocol!",
            .expected = "symbol",
            .actual = @tagName(args[0].tag()),
        });
    }
    if (args[1].tag() != .vector) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "__make-protocol!",
            .expected = "vector",
            .actual = @tagName(args[1].tag()),
        });
    }
    const fqcn = try allocFqcn(rt, args[0]);
    errdefer rt.gc.infra.free(fqcn);
    const methods = try allocMethods(rt, args[1], loc);
    return protocol_mod.makeProtocol(rt, fqcn, methods);
}

/// `(rt/__make-protocol-fn! proto method-name)` — allocate a
/// ProtocolFn Value pointing at the given protocol descriptor with
/// the supplied method name. `proto` is a `.protocol`-tagged Value;
/// `method-name` is a String. Returns a `.protocol_fn`-tagged Value.
pub fn makeProtocolFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__make-protocol-fn!", args, 2, loc);
    if (args[0].tag() != .protocol) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "__make-protocol-fn!",
            .expected = "protocol",
            .actual = @tagName(args[0].tag()),
        });
    }
    if (args[1].tag() != .string) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "__make-protocol-fn!",
            .expected = "string",
            .actual = @tagName(args[1].tag()),
        });
    }
    const proto = protocol_mod.asProtocol(args[0]);
    // The method-name backing bytes live on the GC heap (String is
    // a `.string`-tagged Value). ProtocolFn.method_name_ptr must
    // remain valid for the runtime's lifetime — dupe onto infra so
    // a future String GC sweep does not dangle the pointer.
    const name_dup = try rt.gc.infra.dupe(u8, string_mod.asString(args[1]));
    return protocol_mod.makeProtocolFn(rt, proto, name_dup);
}

/// `(rt/__extend-type! td-ref proto impls-vec)` — mutate the
/// target TypeDescriptor (decoded from a `.type_descriptor` Value)
/// by appending `(protocol_name, method_name, method_val)` rows for
/// each impl pair in `impls-vec`. Each impls vec element is a
/// 2-element Vector `[method-name-string fn-val]` whose first
/// element names the method and whose second element is the
/// callable Value (an `.fn_val` user closure, an `.builtin_fn`
/// native impl, etc.). Bumps `rt.protocol_generation` via
/// `extendTypeWithImpls` so live CallSite caches invalidate on
/// next dispatch. Returns the target Value (args[0]) unchanged so
/// macros can chain.
pub fn extendType(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__extend-type!", args, 3, loc);
    if (args[0].tag() != .type_descriptor) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "__extend-type!",
            .expected = "type_descriptor",
            .actual = @tagName(args[0].tag()),
        });
    }
    if (args[1].tag() != .protocol) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "__extend-type!",
            .expected = "protocol",
            .actual = @tagName(args[1].tag()),
        });
    }
    if (args[2].tag() != .vector) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "__extend-type!",
            .expected = "vector",
            .actual = @tagName(args[2].tag()),
        });
    }
    const td = @constCast(td_mod.asTypeDescriptorRef(args[0]));
    const proto = protocol_mod.asProtocol(args[1]);
    const len = vector_mod.count(args[2]);
    const new_impls = try rt.gc.infra.alloc(td_mod.TypeDescriptor.MethodEntry, len);
    errdefer rt.gc.infra.free(new_impls);
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const pair = vector_mod.nth(args[2], i);
        if (pair.tag() != .vector or vector_mod.count(pair) != 2) {
            return error_catalog.raise(.type_arg_invalid, loc, .{
                .fn_name = "__extend-type!",
                .expected = "[method-name fn-val] pair",
                .actual = @tagName(pair.tag()),
            });
        }
        const name_val = vector_mod.nth(pair, 0);
        const fn_val = vector_mod.nth(pair, 1);
        if (name_val.tag() != .string) {
            return error_catalog.raise(.type_arg_invalid, loc, .{
                .fn_name = "__extend-type!",
                .expected = "string method name",
                .actual = @tagName(name_val.tag()),
            });
        }
        // Method name slice must outlive the descriptor. Dupe onto
        // infra so a future String GC sweep does not dangle the
        // pointer (same shape as `__make-protocol-fn!`).
        const name_dup = try rt.gc.infra.dupe(u8, string_mod.asString(name_val));
        new_impls[i] = .{
            .protocol_name = proto.fqcn(),
            .method_name = name_dup,
            .method_val = fn_val,
        };
    }
    try protocol_mod.extendTypeWithImpls(rt, td, new_impls);
    // extendTypeWithImpls @memcpy's into a fresh combined slice on
    // `rt.gc.infra` and swaps it onto `td.method_table`; the input
    // `new_impls` slice is no longer referenced, so free it back.
    rt.gc.infra.free(new_impls);
    return args[0];
}

/// `(rt/__satisfies? proto val)` — returns true iff `val`'s
/// TypeDescriptor (or any ancestor on its `.parent` chain) carries
/// a method entry for the protocol. cycle 6 only resolves
/// typed_instance receivers; native-Tag descriptor lookup arrives
/// with the per-Tag descriptor registry (survey §5.5, cycle 6.5+).
/// Returns false for any non-typed_instance receiver.
pub fn satisfiesPrim(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("__satisfies?", args, 2, loc);
    if (args[0].tag() != .protocol) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "__satisfies?",
            .expected = "protocol",
            .actual = @tagName(args[0].tag()),
        });
    }
    if (args[1].tag() != .typed_instance) return Value.false_val;
    const proto = protocol_mod.asProtocol(args[0]);
    const inst = args[1].decodePtr(*const td_mod.TypedInstance);
    return Value.initBoolean(protocol_mod.satisfies(proto, inst.descriptor));
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value,
};

const ENTRIES = [_]Entry{
    .{ .name = "__make-protocol!", .f = &makeProtocol },
    .{ .name = "__make-protocol-fn!", .f = &makeProtocolFn },
    .{ .name = "__extend-type!", .f = &extendType },
    .{ .name = "__satisfies?", .f = &satisfiesPrim },
};

pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}

// --- tests ---

const testing = std.testing;

const TestFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,
    env: Env,

    fn init(self: *TestFixture, alloc: std.mem.Allocator) !void {
        self.threaded = std.Io.Threaded.init(alloc, .{});
        self.rt = Runtime.init(self.threaded.io(), alloc);
        self.env = try Env.init(&self.rt);
    }

    fn deinit(self: *TestFixture) void {
        self.env.deinit();
        self.rt.deinit();
        self.threaded.deinit();
    }
};

/// Test-only cleanup: release a `.protocol` Value's infra-owned
/// fqcn slice + methods slice + the descriptor struct itself. Mirrors
/// the cycle 1-5 policy — production runtime leaks these on purpose
/// (descriptors are process-lifetime + live CallSite caches reference
/// them), tests free explicitly so `testing.allocator` is satisfied.
fn destroyProtoForTest(rt: *Runtime, val: Value) void {
    const pd = protocol_mod.asProtocol(val);
    rt.gc.infra.free(pd.fqcn());
    rt.gc.infra.free(pd.methods());
    rt.gc.infra.destroy(@constCast(pd));
}

/// Test-only cleanup for a `.protocol_fn` Value — frees the
/// infra-owned method-name dup + the struct itself.
fn destroyProtoFnForTest(rt: *Runtime, val: Value) void {
    const pfn = protocol_mod.asProtocolFn(val);
    rt.gc.infra.free(pfn.methodName());
    rt.gc.infra.destroy(@constCast(pfn));
}

test "__make-protocol! returns a .protocol Value carrying the qualified symbol name" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const name = try symbol_mod.intern(&fix.rt, "user", "ISeq");
    const methods_vec = vector_mod.empty();

    const result = try makeProtocol(&fix.rt, &fix.env, &[_]Value{ name, methods_vec }, .{});
    defer destroyProtoForTest(&fix.rt, result);
    try testing.expect(result.tag() == .protocol);

    const pd = protocol_mod.asProtocol(result);
    try testing.expectEqualStrings("user/ISeq", pd.fqcn());
    try testing.expectEqual(@as(usize, 0), pd.methods().len);
}

test "__make-protocol! captures method-name Symbols into MethodEntry array" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const name = try symbol_mod.intern(&fix.rt, null, "P");
    var methods_vec = vector_mod.empty();
    methods_vec = try vector_mod.conj(&fix.rt, methods_vec, try symbol_mod.intern(&fix.rt, null, "first"));
    methods_vec = try vector_mod.conj(&fix.rt, methods_vec, try symbol_mod.intern(&fix.rt, null, "rest"));

    const result = try makeProtocol(&fix.rt, &fix.env, &[_]Value{ name, methods_vec }, .{});
    defer destroyProtoForTest(&fix.rt, result);
    const pd = protocol_mod.asProtocol(result);
    try testing.expectEqualStrings("P", pd.fqcn());
    try testing.expectEqual(@as(usize, 2), pd.methods().len);
    try testing.expectEqualStrings("first", pd.methods()[0].name);
    try testing.expectEqualStrings("rest", pd.methods()[1].name);
    try testing.expectEqual(@as(u8, 1), pd.methods()[0].arity);
}

test "__make-protocol! rejects a non-symbol name with type_arg_invalid" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const methods_vec = vector_mod.empty();
    try testing.expectError(error.TypeError, makeProtocol(&fix.rt, &fix.env, &[_]Value{ Value.initInteger(42), methods_vec }, .{}));
}

test "__make-protocol-fn! returns a .protocol_fn Value carrying descriptor + method name" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const name = try symbol_mod.intern(&fix.rt, null, "P");
    const methods_vec = vector_mod.empty();
    const proto_val = try makeProtocol(&fix.rt, &fix.env, &[_]Value{ name, methods_vec }, .{});
    defer destroyProtoForTest(&fix.rt, proto_val);

    const method_name_str = try string_mod.alloc(&fix.rt, "first");
    const pfn_val = try makeProtocolFn(&fix.rt, &fix.env, &[_]Value{ proto_val, method_name_str }, .{});
    defer destroyProtoFnForTest(&fix.rt, pfn_val);
    try testing.expect(pfn_val.tag() == .protocol_fn);

    const pfn = protocol_mod.asProtocolFn(pfn_val);
    try testing.expect(pfn.descriptor == protocol_mod.asProtocol(proto_val));
    try testing.expectEqualStrings("first", pfn.methodName());
}

test "__make-protocol-fn! rejects a non-protocol first arg" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const method_name_str = try string_mod.alloc(&fix.rt, "first");
    try testing.expectError(
        error.TypeError,
        makeProtocolFn(&fix.rt, &fix.env, &[_]Value{ Value.initInteger(1), method_name_str }, .{}),
    );
}

test "__satisfies? returns false for non-typed_instance receivers" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const name = try symbol_mod.intern(&fix.rt, null, "P");
    const methods_vec = vector_mod.empty();
    const proto_val = try makeProtocol(&fix.rt, &fix.env, &[_]Value{ name, methods_vec }, .{});
    defer destroyProtoForTest(&fix.rt, proto_val);

    const result = try satisfiesPrim(&fix.rt, &fix.env, &[_]Value{ proto_val, Value.initInteger(42) }, .{});
    try testing.expectEqual(Value.false_val, result);
}

test "__satisfies? returns true when typed_instance's descriptor implements the protocol" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    // Build a protocol "P" with one method.
    const proto_name = try symbol_mod.intern(&fix.rt, null, "P");
    var methods_vec = vector_mod.empty();
    methods_vec = try vector_mod.conj(&fix.rt, methods_vec, try symbol_mod.intern(&fix.rt, null, "m"));
    const proto_val = try makeProtocol(&fix.rt, &fix.env, &[_]Value{ proto_name, methods_vec }, .{});
    defer destroyProtoForTest(&fix.rt, proto_val);

    // Synthetic TypeDescriptor with an entry for protocol "P" — mirrors the
    // shape `extendTypeWithImpls` would install once cycle 6.5 lands the
    // `__extend-type!` surface.
    const td = try fix.rt.gc.infra.create(td_mod.TypeDescriptor);
    defer fix.rt.gc.infra.destroy(td);
    const impl_entries = try fix.rt.gc.infra.alloc(td_mod.TypeDescriptor.MethodEntry, 1);
    defer fix.rt.gc.infra.free(impl_entries);
    impl_entries[0] = .{ .protocol_name = "P", .method_name = "m", .method_val = Value.nil_val };
    td.* = .{
        .fqcn = "user/Foo",
        .kind = .deftype,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = impl_entries,
        .parent = null,
        .meta = Value.nil_val,
    };

    const inst_val = try td_mod.allocInstance(&fix.rt, td, &.{});
    const result = try satisfiesPrim(&fix.rt, &fix.env, &[_]Value{ proto_val, inst_val }, .{});
    try testing.expectEqual(Value.true_val, result);
}

test "register installs the 4 protocol primitives in rt/" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const rt_ns = fix.env.findNs("rt").?;
    try register(&fix.env, rt_ns);
    try testing.expect(rt_ns.resolve("__make-protocol!") != null);
    try testing.expect(rt_ns.resolve("__make-protocol-fn!") != null);
    try testing.expect(rt_ns.resolve("__extend-type!") != null);
    try testing.expect(rt_ns.resolve("__satisfies?") != null);
}

/// Test helper: build an `impls-vec` cell `[method-name fn-val]`
/// for `__extend-type!`'s input vector. Allocates two GC-heap String
/// + Vector Values.
fn buildImplPair(rt: *Runtime, method_name: []const u8, fn_val: Value) !Value {
    const name_str = try string_mod.alloc(rt, method_name);
    var pair = vector_mod.empty();
    pair = try vector_mod.conj(rt, pair, name_str);
    pair = try vector_mod.conj(rt, pair, fn_val);
    return pair;
}

fn extendTypeMockBuiltin(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    _ = loc;
    return Value.initInteger(@intCast(args.len + 100));
}

test "__extend-type! appends method_val rows + bumps protocol_generation" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    // Protocol "P" carrying one method "m".
    const proto_name = try symbol_mod.intern(&fix.rt, null, "P");
    var methods_vec = vector_mod.empty();
    methods_vec = try vector_mod.conj(&fix.rt, methods_vec, try symbol_mod.intern(&fix.rt, null, "m"));
    const proto_val = try makeProtocol(&fix.rt, &fix.env, &[_]Value{ proto_name, methods_vec }, .{});
    defer destroyProtoForTest(&fix.rt, proto_val);

    // Empty TypeDescriptor on infra.
    const td = try fix.rt.gc.infra.create(td_mod.TypeDescriptor);
    defer fix.rt.gc.infra.destroy(td);
    td.* = .{
        .fqcn = "user/Foo",
        .kind = .deftype,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = Value.nil_val,
    };
    const td_ref = try td_mod.makeTypeDescriptorRef(&fix.rt, td);
    defer fix.rt.gc.infra.destroy(@constCast(td_ref.decodePtr(*const td_mod.TypeDescriptorRef)));

    const impl_fn = Value.initBuiltinFn(&extendTypeMockBuiltin);
    var impls = vector_mod.empty();
    impls = try vector_mod.conj(&fix.rt, impls, try buildImplPair(&fix.rt, "m", impl_fn));

    const gen_before = fix.rt.protocol_generation;
    const result = try extendType(&fix.rt, &fix.env, &[_]Value{ td_ref, proto_val, impls }, .{});
    // Per the per-task note's test-only cleanup policy, the infra-
    // allocated method_table slice + each method-name dup must be
    // freed when the test exits (production leaks them on purpose).
    defer {
        for (td.method_table) |entry| fix.rt.gc.infra.free(entry.method_name);
        fix.rt.gc.infra.free(td.method_table);
    }

    try testing.expectEqual(@intFromEnum(td_ref), @intFromEnum(result));
    try testing.expectEqual(gen_before +% 1, fix.rt.protocol_generation);
    try testing.expectEqual(@as(usize, 1), td.method_table.len);
    try testing.expectEqualStrings("P", td.method_table[0].protocol_name);
    try testing.expectEqualStrings("m", td.method_table[0].method_name);
    try testing.expectEqual(@intFromEnum(impl_fn), @intFromEnum(td.method_table[0].method_val));
}

test "__extend-type! rejects a non-type_descriptor target" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const proto_name = try symbol_mod.intern(&fix.rt, null, "P");
    const empty_methods = vector_mod.empty();
    const proto_val = try makeProtocol(&fix.rt, &fix.env, &[_]Value{ proto_name, empty_methods }, .{});
    defer destroyProtoForTest(&fix.rt, proto_val);

    const impls = vector_mod.empty();
    try testing.expectError(
        error.TypeError,
        extendType(&fix.rt, &fix.env, &[_]Value{ Value.initInteger(7), proto_val, impls }, .{}),
    );
}
