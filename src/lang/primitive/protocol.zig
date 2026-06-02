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
const big_int_mod = @import("../../runtime/numeric/big_int.zig");
const keyword_mod = @import("../../runtime/keyword.zig");
const ex_info_mod = @import("../../runtime/collection/ex_info.zig");
const host_class_mod = @import("../../runtime/error/host_class.zig");

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
    errdefer if (methods.len > 0) rt.gc.infra.free(methods);
    const v = try protocol_mod.makeProtocol(rt, fqcn, methods);
    // Register the descriptor + its owned fqcn / methods slices for
    // rt.deinit cleanup. Without this, every `(defprotocol …)` form
    // — including the bootstrap row 7.7 `IPersistentCollection` — leaks
    // DebugAllocator diagnostics at process exit. Test fixtures in
    // `runtime/protocol.zig` keep the prior manual-destroy shape
    // because their fqcn / methods are stack / rodata literals.
    try rt.trackHeap(.{ .ptr = @constCast(@ptrCast(protocol_mod.asProtocol(v))), .free = protocol_mod.freeOwnedProtocol });
    return v;
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
    errdefer rt.gc.infra.free(name_dup);
    const v = try protocol_mod.makeProtocolFn(rt, proto, name_dup);
    try rt.trackHeap(.{ .ptr = @constCast(@ptrCast(protocol_mod.asProtocolFn(v))), .free = protocol_mod.freeOwnedProtocolFn });
    return v;
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
    // Record the protocol in the declared-interface list so a zero-method
    // MARKER protocol (`Sequential`, no method_table entry) is still
    // detectable, and `protocol_impls` stays an honest "implements P" set
    // (D-190 / ADR-0068).
    try protocol_mod.addProtocolImpl(rt, td, proto.fqcn());
    return args[0];
}

/// `(rt/__native-type tag-keyword)` — return the `.type_descriptor`
/// Value wrapping the native TypeDescriptor for the given Tag. The
/// keyword's name must match a `Value.Tag` enum tag name (e.g.
/// `:integer`, `:string`, `:vector`). Lazy-allocates the descriptor
/// on `rt.gc.infra` on first call per Tag; subsequent calls return
/// the same handle. Cycle 8.5 surface — lets user code `(extend-type
/// (rt/__native-type :integer) P (m [x] ...))` reach the dispatch
/// path for native receivers without needing deftype-defined types.
pub fn nativeType(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__native-type", args, 1, loc);
    if (args[0].tag() != .keyword) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "__native-type",
            .expected = "keyword",
            .actual = @tagName(args[0].tag()),
        });
    }
    const kw = keyword_mod.asKeyword(args[0]);
    // Find the Tag whose @tagName matches the keyword's name. Linear
    // scan over Tag enum is fine — N ≤ 70 and this is a one-time
    // per-feature lookup.
    const tag_name = kw.name;
    inline for (@typeInfo(Value.Tag).@"enum".fields) |field| {
        if (std.mem.eql(u8, field.name, tag_name)) {
            const tag: Value.Tag = @enumFromInt(field.value);
            const td = try rt.nativeDescriptor(tag);
            return td_mod.makeTypeDescriptorRef(rt, td);
        }
    }
    return error_catalog.raise(.type_arg_invalid, loc, .{
        .fn_name = "__native-type",
        .expected = "valid Value.Tag keyword (e.g. :integer, :string, :vector)",
        .actual = tag_name,
    });
}

/// `(rt/__defrecord! 'Name ['field-syms...])` — register a fresh
/// TypeDescriptor with `.kind = .defrecord`. The macro `expandDefrecord`
/// emits this call; registration is shared with `__deftype!` via
/// `registerTypePrim` → `type_descriptor.registerType` (F-009).
///
/// Implements clojure.core/defrecord registration.
/// Spec: `(defrecord Name [fields...])` creates a class Name with
///   - declared positional fields
///   - implicit IPersistentMap semantics (get/assoc/keys/vals over
///     field-name keywords — landed across row 7.4 cycles 3-5).
/// JVM reference: clojure.core/defrecord in clojure/core_deftype.clj L387.
/// cw v1 tier: A (row 7.4 cycle 2 — descriptor kind landed).
pub fn defrecordPrim(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return registerTypePrim(rt, args, loc, .defrecord, "__defrecord!");
}

/// `(rt/__deftype! 'Name ['field-syms...])` — register a fresh
/// TypeDescriptor with `.kind = .deftype`. The macro `expandDeftype`
/// (ADR-0066) emits this call; identical registration to `__defrecord!`
/// minus the descriptor kind (deftype gets NO implicit IPersistentMap
/// semantics — the map-protocol arms gate on `kind != .defrecord`).
///
/// Implements clojure.core/deftype registration (JVM reference:
/// clojure.core/deftype in clojure/core_deftype.clj). cw v1 tier: A.
pub fn deftypePrim(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return registerTypePrim(rt, args, loc, .deftype, "__deftype!");
}

/// Shared registration body for `__defrecord!` / `__deftype!` — the two
/// differ only in the registered `TypeDescriptor.kind` and the error
/// fn-name (F-011 commonization; ADR-0066 DA correction 1). Returns a
/// TypeDescriptorRef Value so the macro lowering's `(def Name (rt/__…! …))`
/// + downstream `extend-type` resolve `Name` to a usable Value.
fn registerTypePrim(
    rt: *Runtime,
    args: []const Value,
    loc: SourceLocation,
    kind: td_mod.TypeKind,
    comptime prim_name: []const u8,
) anyerror!Value {
    try error_catalog.checkArity(prim_name, args, 2, loc);
    if (args[0].tag() != .symbol) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = prim_name,
            .expected = "symbol",
            .actual = @tagName(args[0].tag()),
        });
    }
    if (args[1].tag() != .vector) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = prim_name,
            .expected = "vector",
            .actual = @tagName(args[1].tag()),
        });
    }

    const name_sym = symbol_mod.asSymbol(args[0]);
    const len = vector_mod.count(args[1]);
    // Collect field names; borrowed view into the Symbol Values
    // (registerType `dupe`s each into process-lifetime storage).
    const field_names = try rt.gpa.alloc([]const u8, len);
    defer rt.gpa.free(field_names);
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const elt = vector_mod.nth(args[1], i);
        if (elt.tag() != .symbol) {
            return error_catalog.raise(.type_arg_invalid, loc, .{
                .fn_name = prim_name,
                .expected = "symbol",
                .actual = @tagName(elt.tag()),
            });
        }
        field_names[i] = symbol_mod.asSymbol(elt).name;
    }

    const td = try td_mod.registerType(rt, name_sym.name, field_names, kind);
    return td_mod.makeTypeDescriptorRef(rt, td);
}

/// `(rt/__reify! [interfaces] [[method-name proto fn-val]...])` —
/// allocate an anonymous TypeDescriptor + ReifiedInstance pair.
///
/// `interfaces` is a Vector of `.protocol`-tagged Values (the
/// `defprotocol`-bound symbols evaluate to these at call time).
/// `method-rows` is a Vector of 3-element Vectors `[name proto fn]`
/// — each row binds one (protocol, method-name) entry on the
/// anonymous descriptor's `method_table` to a closure-bearing
/// `.fn_val`. Closure capture is already discharged: each `fn-val`
/// arrived as an `allocFunction`-snapshotted closure at the
/// reify-form's call site (eval/backend/tree_walk.zig L177-L206).
///
/// The anonymous descriptor lives on `rt.gpa`, NOT registered in
/// `rt.types` (per survey §5 — name lookup is never consulted; the
/// dispatch ABI reads through `inst.descriptor` directly).
///
/// Row 7.5 cycle 3 — happy path lands; per-call descriptor allocation
/// (cache by source location deferred to Phase 8+ per F-003).
pub fn reifyPrim(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__reify!", args, 2, loc);
    if (args[0].tag() != .vector) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "__reify!",
            .expected = "vector of protocols",
            .actual = @tagName(args[0].tag()),
        });
    }
    if (args[1].tag() != .vector) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "__reify!",
            .expected = "vector of [method-name proto fn] rows",
            .actual = @tagName(args[1].tag()),
        });
    }

    // Build protocol_impls — one entry per declared interface, dup'd
    // onto rt.gpa so the slice outlives the call frame.
    const proto_count = vector_mod.count(args[0]);
    const protocol_impls = try rt.gpa.alloc([]const u8, proto_count);
    errdefer rt.gpa.free(protocol_impls);
    var pi: u32 = 0;
    while (pi < proto_count) : (pi += 1) {
        const p = vector_mod.nth(args[0], pi);
        if (p.tag() != .protocol) {
            return error_catalog.raise(.type_arg_invalid, loc, .{
                .fn_name = "__reify!",
                .expected = "protocol",
                .actual = @tagName(p.tag()),
            });
        }
        protocol_impls[pi] = try rt.gpa.dupe(u8, protocol_mod.asProtocol(p).fqcn());
    }

    // Build method_table — one MethodEntry per row.
    const row_count = vector_mod.count(args[1]);
    const method_table = try rt.gpa.alloc(td_mod.TypeDescriptor.MethodEntry, row_count);
    errdefer rt.gpa.free(method_table);
    var ri: u32 = 0;
    while (ri < row_count) : (ri += 1) {
        const row = vector_mod.nth(args[1], ri);
        if (row.tag() != .vector or vector_mod.count(row) != 3) {
            return error_catalog.raise(.type_arg_invalid, loc, .{
                .fn_name = "__reify!",
                .expected = "[method-name proto fn] row",
                .actual = @tagName(row.tag()),
            });
        }
        const name_val = vector_mod.nth(row, 0);
        const proto_val = vector_mod.nth(row, 1);
        const fn_val = vector_mod.nth(row, 2);
        if (name_val.tag() != .string or proto_val.tag() != .protocol) {
            return error_catalog.raise(.type_arg_invalid, loc, .{
                .fn_name = "__reify!",
                .expected = "[string proto fn]",
                .actual = "row shape",
            });
        }
        const proto = protocol_mod.asProtocol(proto_val);
        method_table[ri] = .{
            .protocol_name = try rt.gpa.dupe(u8, proto.fqcn()),
            .method_name = try rt.gpa.dupe(u8, string_mod.asString(name_val)),
            .method_val = fn_val,
        };
    }

    // Allocate the anonymous TypeDescriptor on rt.gpa. Not registered
    // in rt.types (= dispatch consults `inst.descriptor` directly), so
    // `Runtime.deinit` Pass 3 won't see it. Register via `rt.trackHeap`
    // so `freeReifyDescriptor` walks `protocol_impls` + `method_table`
    // and destroys the descriptor at process exit. Mirrors the cycle 1
    // (row 7.7) trackHeap discipline for ProtocolDescriptor / ProtocolFn
    // / TypeDescriptorRef — anonymous reify descriptors get the same
    // lifecycle hook so DebugAllocator stays quiet across diff_test runs.
    const td = try rt.gpa.create(td_mod.TypeDescriptor);
    errdefer rt.gpa.destroy(td);
    td.* = .{
        .fqcn = null,
        .kind = .reify_anon,
        .field_layout = null,
        .protocol_impls = protocol_impls,
        .method_table = method_table,
        .parent = null,
        .meta = Value.nil_val,
    };
    try rt.trackHeap(.{ .ptr = td, .free = freeReifyDescriptor });

    return td_mod.allocReifiedInstance(rt, td);
}

/// trackHeap freer for the anonymous reify TypeDescriptor. Walks the
/// dup'd protocol_impls + method_table entries (allocated on `rt.gpa`
/// by `reifyPrim`) before destroying the descriptor itself.
pub fn freeReifyDescriptor(gpa: std.mem.Allocator, ptr: *anyopaque) void {
    const td: *td_mod.TypeDescriptor = @ptrCast(@alignCast(ptr));
    for (td.protocol_impls) |name| gpa.free(name);
    gpa.free(td.protocol_impls);
    for (td.method_table) |entry| {
        gpa.free(entry.protocol_name);
        gpa.free(entry.method_name);
    }
    gpa.free(td.method_table);
    gpa.destroy(td);
}

/// `(rt/__satisfies? proto val)` — returns true iff `val`'s
/// TypeDescriptor (or any ancestor on its `.parent` chain) carries
/// a method entry for the protocol. typed_instance receivers carry
/// their own descriptor; native-Tag receivers consult the per-Tag
/// default registry (cycle 8.5 — `Runtime.nativeDescriptor`).
pub fn satisfiesPrim(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__satisfies?", args, 2, loc);
    if (args[0].tag() != .protocol) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "__satisfies?",
            .expected = "protocol",
            .actual = @tagName(args[0].tag()),
        });
    }
    const proto = protocol_mod.asProtocol(args[0]);
    const td: *const td_mod.TypeDescriptor = if (args[1].tag() == .typed_instance) blk: {
        break :blk args[1].decodePtr(*const td_mod.TypedInstance).descriptor;
    } else if (args[1].tag() == .reified_instance) blk: {
        // Row 7.5 cycle 3 — anonymous descriptor lookup parallels typed_instance.
        break :blk args[1].decodePtr(*const td_mod.ReifiedInstance).descriptor;
    } else try rt.nativeDescriptor(args[1].tag());
    return Value.initBoolean(protocol_mod.satisfies(proto, td));
}

/// `(rt/__extends? proto type)` — returns true iff the TypeDescriptor
/// `type` (a `.type_descriptor` Value from `__native-type` /
/// `defrecord` / `deftype`) carries a method entry for the protocol on
/// itself or any ancestor. The type-level counterpart of `__satisfies?`:
/// where `__satisfies?` takes an instance and reads its descriptor,
/// `__extends?` receives the descriptor directly.
pub fn extendsPrim(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("__extends?", args, 2, loc);
    if (args[0].tag() != .protocol) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "__extends?",
            .expected = "protocol",
            .actual = @tagName(args[0].tag()),
        });
    }
    if (args[1].tag() != .type_descriptor) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "__extends?",
            .expected = "type_descriptor",
            .actual = @tagName(args[1].tag()),
        });
    }
    const proto = protocol_mod.asProtocol(args[0]);
    const td = td_mod.asTypeDescriptorRef(args[1]);
    return Value.initBoolean(protocol_mod.satisfies(proto, td));
}

/// `(rt/__class x)` — the TypeDescriptor of `x` as an interned
/// `.type_descriptor` Value (ADR-0059). `(class nil)` → nil (JVM
/// semantics). typed_instance / reified_instance carry their own
/// descriptor; every other value consults the per-Tag native
/// descriptor. Interning (`makeTypeDescriptorRef` caches one ref per
/// descriptor) makes `(= (class a) (class b))` hold iff a and b share a
/// type, and lets a class be a map key. The `.clj` `class` wraps this;
/// `type` = `(or (:type (meta x)) (class x))`.
pub fn classPrim(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__class", args, 1, loc);
    const v = args[0];
    if (v.tag() == .nil) return Value.nil_val;
    // A heap-boxed Long (D-165 / ADR-0080) is class Long, not BigInt — it
    // shares the inline-int (`.integer`) native descriptor.
    if (v.tag() == .big_int and big_int_mod.originOf(v) == .long) {
        return td_mod.makeTypeDescriptorRef(rt, try rt.nativeDescriptor(.integer));
    }
    // An exception value reports its specific class (D-213): the per-value
    // `ExInfo.class_name` (null → "ExceptionInfo"), normalized to the simple
    // name per AD-003 — not the generic `.ex_info` native descriptor.
    if (v.tag() == .ex_info) {
        const raw = ex_info_mod.className(v) orelse "ExceptionInfo";
        const simple = host_class_mod.normalizeClassName(raw);
        return td_mod.makeTypeDescriptorRef(rt, try rt.exceptionDescriptor(simple));
    }
    const td: *const td_mod.TypeDescriptor = switch (v.tag()) {
        .typed_instance => v.decodePtr(*const td_mod.TypedInstance).descriptor,
        .reified_instance => v.decodePtr(*const td_mod.ReifiedInstance).descriptor,
        else => try rt.nativeDescriptor(v.tag()),
    };
    return td_mod.makeTypeDescriptorRef(rt, td);
}

/// `(class? x)` — true iff `x` is a class object, i.e. the `.type_descriptor`
/// Value that `(class …)` returns (D-215). In JVM Clojure this is
/// `(instance? Class x)`; cljw has no `java.lang.Class`, so the class object
/// is a boxed TypeDescriptor ref (ADR-0059).
pub fn classPred(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("__class?", args, 1, loc);
    return Value.initBoolean(args[0].tag() == .type_descriptor);
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
    .{ .name = "__extends?", .f = &extendsPrim },
    .{ .name = "__class", .f = &classPrim },
    .{ .name = "__class?", .f = &classPred },
    .{ .name = "__native-type", .f = &nativeType },
    .{ .name = "__defrecord!", .f = &defrecordPrim },
    .{ .name = "__deftype!", .f = &deftypePrim },
    .{ .name = "__reify!", .f = &reifyPrim },
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

test "__make-protocol! returns a .protocol Value carrying the qualified symbol name" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const name = try symbol_mod.intern(&fix.rt, "user", "ISeq");
    const methods_vec = vector_mod.empty();

    const result = try makeProtocol(&fix.rt, &fix.env, &[_]Value{ name, methods_vec }, .{});
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

    const method_name_str = try string_mod.alloc(&fix.rt, "first");
    const pfn_val = try makeProtocolFn(&fix.rt, &fix.env, &[_]Value{ proto_val, method_name_str }, .{});
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

test "__extends? returns true when the type itself carries the protocol" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const proto_name = try symbol_mod.intern(&fix.rt, null, "P");
    var methods_vec = vector_mod.empty();
    methods_vec = try vector_mod.conj(&fix.rt, methods_vec, try symbol_mod.intern(&fix.rt, null, "m"));
    const proto_val = try makeProtocol(&fix.rt, &fix.env, &[_]Value{ proto_name, methods_vec }, .{});

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

    // extends? receives the TypeDescriptor directly (not an instance).
    const type_val = try td_mod.makeTypeDescriptorRef(&fix.rt, td);
    const result = try extendsPrim(&fix.rt, &fix.env, &[_]Value{ proto_val, type_val }, .{});
    try testing.expectEqual(Value.true_val, result);
}

test "__extends? returns false when the type lacks the protocol" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    // A protocol the descriptor was never extended with.
    const other_name = try symbol_mod.intern(&fix.rt, null, "Q");
    var methods_vec = vector_mod.empty();
    methods_vec = try vector_mod.conj(&fix.rt, methods_vec, try symbol_mod.intern(&fix.rt, null, "n"));
    const other_proto = try makeProtocol(&fix.rt, &fix.env, &[_]Value{ other_name, methods_vec }, .{});

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

    const type_val = try td_mod.makeTypeDescriptorRef(&fix.rt, td);
    const result = try extendsPrim(&fix.rt, &fix.env, &[_]Value{ other_proto, type_val }, .{});
    try testing.expectEqual(Value.false_val, result);
}

test "__class returns nil for a nil input (JVM semantics)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const result = try classPrim(&fix.rt, &fix.env, &[_]Value{Value.nil_val}, .{});
    try testing.expectEqual(Value.nil_val, result);
}

test "__class interns one boxed Value per descriptor (identity equality)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const a = try classPrim(&fix.rt, &fix.env, &[_]Value{Value.initInteger(5)}, .{});
    const b = try classPrim(&fix.rt, &fix.env, &[_]Value{Value.initInteger(6)}, .{});
    try testing.expect(a.tag() == .type_descriptor);
    // Interning invariant: same native descriptor → bit-identical Value,
    // so the equality/hash identity fast path makes (= (class 5) (class 6)).
    try testing.expectEqual(@intFromEnum(a), @intFromEnum(b));

    // A different native tag is a different descriptor → different Value.
    const s = try classPrim(&fix.rt, &fix.env, &[_]Value{try string_mod.alloc(&fix.rt, "x")}, .{});
    try testing.expect(@intFromEnum(a) != @intFromEnum(s));
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
    try testing.expect(rt_ns.resolve("__extends?") != null);
    try testing.expect(rt_ns.resolve("__class") != null);
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
    // makeTypeDescriptorRef trackHeap-registers the ref (row 7.7 cycle 1);
    // rt.deinit owns the destroy.

    const impl_fn = Value.initBuiltinFn(&extendTypeMockBuiltin);
    var impls = vector_mod.empty();
    impls = try vector_mod.conj(&fix.rt, impls, try buildImplPair(&fix.rt, "m", impl_fn));

    const gen_before = fix.rt.protocol_generation;
    const result = try extendType(&fix.rt, &fix.env, &[_]Value{ td_ref, proto_val, impls }, .{});
    // Per the per-task note's test-only cleanup policy, the infra-
    // allocated method_table slice + each method-name dup + the
    // protocol_impls slice (D-190/ADR-0068: addProtocolImpl records "P")
    // must be freed when the test exits (production leaks them on purpose).
    defer {
        for (td.method_table) |entry| fix.rt.gc.infra.free(entry.method_name);
        fix.rt.gc.infra.free(td.method_table);
        if (td.protocol_impls.len > 0) fix.rt.gc.infra.free(td.protocol_impls);
    }

    try testing.expectEqual(@intFromEnum(td_ref), @intFromEnum(result));
    try testing.expectEqual(gen_before +% 1, fix.rt.protocol_generation);
    try testing.expectEqual(@as(usize, 1), td.method_table.len);
    // addProtocolImpl recorded "P" in the declared-interface list.
    try testing.expectEqual(@as(usize, 1), td.protocol_impls.len);
    try testing.expectEqualStrings("P", td.protocol_impls[0]);
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

    const impls = vector_mod.empty();
    try testing.expectError(
        error.TypeError,
        extendType(&fix.rt, &fix.env, &[_]Value{ Value.initInteger(7), proto_val, impls }, .{}),
    );
}

// --- row 7.4 cycle 2 — __defrecord! primitive ---

test "__defrecord! registers a TypeDescriptor with .kind = .defrecord" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const name_sym = try symbol_mod.intern(&fix.rt, null, "Point");
    var fields_vec = vector_mod.empty();
    fields_vec = try vector_mod.conj(&fix.rt, fields_vec, try symbol_mod.intern(&fix.rt, null, "x"));
    fields_vec = try vector_mod.conj(&fix.rt, fields_vec, try symbol_mod.intern(&fix.rt, null, "y"));

    const result = try defrecordPrim(&fix.rt, &fix.env, &[_]Value{ name_sym, fields_vec }, .{});
    // Row 7.4 cycle 5 changed the return value from nil_val to a
    // `TypeDescriptorRef` so the macro lowering can `(def Name ...)`.
    try testing.expect(result.tag() == .type_descriptor);
    // makeTypeDescriptorRef trackHeap-registers the ref (row 7.7 cycle 1);
    // rt.deinit owns the destroy.

    const td = fix.rt.types.get("Point") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(td_mod.TypeKind.defrecord, td.kind);
    const layout = td.field_layout orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), layout.len);
    try testing.expectEqualStrings("x", layout[0].name);
    try testing.expectEqualStrings("y", layout[1].name);
}

test "__defrecord! rejects a non-symbol name" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const fields_vec = vector_mod.empty();
    try testing.expectError(
        error.TypeError,
        defrecordPrim(&fix.rt, &fix.env, &[_]Value{ Value.initInteger(42), fields_vec }, .{}),
    );
}

test "__defrecord! rejects a non-vector fields argument" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const name_sym = try symbol_mod.intern(&fix.rt, null, "Foo");
    try testing.expectError(
        error.TypeError,
        defrecordPrim(&fix.rt, &fix.env, &[_]Value{ name_sym, Value.initInteger(7) }, .{}),
    );
}
