// SPDX-License-Identifier: EPL-2.0
//! Bytecode opcode set and per-chunk container for the VM backend.
//!
//! The VM backend (ADR-0005) runs alongside the TreeWalk backend.
//! Both must produce bit-for-bit identical Values under
//! `Evaluator.compare` (ADR-0022); the opcode semantics therefore
//! mirror TreeWalk's observable behaviour rather than introducing a
//! new evaluation model.
//!
//! This module holds the data shape: the `Opcode` enum (special
//! forms, collection literals, namespace ops, exception handling,
//! and method dispatch), per-instruction side-tables on
//! `BytecodeChunk`, and the immutable chunk container. The compiler
//! (`vm/compiler.zig`) emits these; the dispatch loop (`vm.zig`)
//! consumes them.

const std = @import("std");
const Value = @import("../../../runtime/value/value.zig").Value;
const method_table = @import("../../../runtime/dispatch/method_table.zig");
const TypeDescriptor = @import("../../../runtime/type_descriptor.zig").TypeDescriptor;

/// Bytecode operations dispatched by the VM.
///
/// Each operand's semantics depend on the opcode:
///   - `op_const`           operand = index into the chunk's constant pool
///   - `op_load_local` /
///     `op_store_local`     operand = frame slot index
///   - `op_get_var`         operand = constants index of a heap-tagged
///                          `Var` Value (analyzer pre-resolves the
///                          pointer; the VM decodes and calls
///                          `Var.deref`)
///   - `op_def`             operand = packed `(flags << 13) | name_idx`
///                          where the low 13 bits are the constants
///                          index of the symbol-name `String` Value
///                          (max `DEF_NAME_IDX_MAX`) and the high
///                          3 bits carry `DEF_FLAG_DYNAMIC /
///                          DEF_FLAG_MACRO / DEF_FLAG_PRIVATE`. The
///                          VM passes the name bytes to `env.intern`
///                          and stamps the flags on the resulting Var.
///   - `op_jump` /
///     `op_jump_if_false`   operand = signed instruction offset (bitcast to i16)
///   - `op_call` /
///     `op_invoke_builtin`  operand = argument count
///   - `op_make_fn`         operand = constants index of the FnProto
///   - `op_recur`           operand = binding count
///   - `op_push_handler`    operand = signed forward offset to the
///                          handler entry (`i16` via `@bitCast`).
///                          The dispatcher records `{ catch_ip,
///                          saved_sp }` and, on `error.ThrownValue`
///                          from the protected region, jumps to the
///                          handler with the thrown Value pushed.
///   - `op_pop_handler`     operand unused — pops the innermost
///                          handler entry (normal try exit)
///   - `op_match_class`     operand = constants index of the catch
///                          class-name `String`. Peeks the top Value
///                          and pushes `true_val` / `false_val`
///                          based on whether the class matches
///                          (delegates to the shared `host_class`
///                          hierarchy table — full class hierarchy,
///                          not just `ExceptionInfo`)
///   - `op_ret` / `op_pop` /
///     `op_dup` / `op_throw` operand unused
pub const Opcode = enum(u8) {
    op_const = 0x00,
    op_load_local = 0x01,
    op_store_local = 0x02,
    op_def = 0x03,
    op_get_var = 0x04,
    op_jump = 0x05,
    op_jump_if_false = 0x06,
    op_call = 0x07,
    op_ret = 0x08,
    op_pop = 0x09,
    op_dup = 0x0A,
    op_throw = 0x0B,
    op_make_fn = 0x0C,
    op_recur = 0x0D,
    op_invoke_builtin = 0x0E,
    op_push_handler = 0x0F,
    op_pop_handler = 0x10,
    op_match_class = 0x11,
    /// `(in-ns 'foo.bar)` — operand = constants index of the heap String
    /// holding the target namespace name. VM dispatch decodes the
    /// string, calls `env.findOrCreateNs` + sets `current_ns`, and
    /// pushes nil (matches `tree_walk::evalInNs` per ADR-0032).
    op_in_ns = 0x12,
    /// `[a b c]` vector literal — operand = element count N. VM
    /// dispatch pops N stack values (top-most = last element), builds
    /// a fresh PersistentVector via `vector.empty()` + `vector.conj`,
    /// and pushes it. Closes D-060 (Phase 6.16.a-3.2).
    op_vector_literal = 0x13,
    /// `{k1 v1 k2 v2 ...}` map literal — operand = total stack-pop
    /// count = 2 * pair_count. VM dispatch pops the pairs (k0 first,
    /// then v0, then k1, ...; built bottom-up to preserve source
    /// order), assoc-folds into an empty ArrayMap, pushes the result.
    /// Closes D-059 (Phase 6.16.b-2).
    op_map_literal = 0x14,
    /// `#{e1 e2 ...}` set literal — operand = element count N. VM
    /// dispatch pops N values, conj-folds into an empty HashSet
    /// (duplicates collapse), pushes the result. Closes D-061
    /// (Phase 6.16.b-2).
    op_set_literal = 0x15,
    /// `(require 'foo.bar)` — operand indexes a String constant in
    /// the chunk's constant pool carrying the namespace name. VM
    /// dispatch mirrors `tree_walk::evalRequire`: if the namespace
    /// is already loaded (= `env.findNs(name).mappings.count() > 0`)
    /// push nil; otherwise call `rt.require_resolver`, raise
    /// `lib_not_found` on null, and on a non-null resolve load the
    /// namespace source via `loader.loadNamespace`. Pushes nil.
    /// ADR-0035 D2/D5/D8.
    op_require = 0x16,
    /// `(ns foo (:refer-clojure))` — operand = constants index of
    /// the heap String holding the target namespace name. VM
    /// dispatch performs op_in_ns logic (findOrCreateNs + set
    /// current_ns), then fires `referAll(rt, here)` + `referAll(
    /// clojure.core, here)`. cw v1 divergence from JVM: the
    /// widened (:refer-clojure) semantic refers BOTH clojure.core
    /// AND rt namespaces. Emitted by `compileNs` when NsNode's
    /// `refer_clojure = true`; bare `(in-ns ...)` continues to
    /// emit `op_in_ns` (no auto-refer post-ADR-0035 D9 second
    /// amendment). Discharges D-073 cluster sub-site (e). Mirrors
    /// `tree_walk::evalNs` post-T3 gating.
    op_ns_with_refer_clojure = 0x17,
    /// Row 7.6 cycle 4 (ADR-0040): method-dispatch cluster opcodes.
    /// (0x18 was `op_deftype`, retired by ADR-0066 when deftype became a
    /// macro lowering to `rt/__deftype!` — registration is now a
    /// backend-neutral primitive call, no dedicated opcode.)
    /// `(Name. args)` — operand = index into the `ctor_sites` side-table
    /// (D-233; was a packed `(name_idx << 8) | arg_count` that truncated
    /// name_idx to 8 bits). Pops `arg_count` values and constructs the
    /// instance via `special_forms.constructInstance`.
    op_ctor_call = 0x19,
    /// `(.member instance args...)` / `(.-field instance)` — operand =
    /// `call_site_idx` into `BytecodeChunk.call_sites`. Pops receiver +
    /// args, runs the unified instance-member resolver: field-first
    /// (`descriptor.field_layout`), then `cs.lookupWithCache(td, null,
    /// method_name, generation)` + `vt.callFn`. The `field_only` flag on
    /// the call-site (the `.-name` form) stops after the field attempt.
    /// ADR-0050 am1 folded the retired `op_field_access` into this arm.
    op_method_call = 0x1A,
    /// `(require '[ns :as alias :refer [v1 v2]])` — operand =
    /// `libspec_idx` into `BytecodeChunk.libspecs`. Looks up the
    /// LibspecEntry (`ns_name` + `?alias` + `[]refers`), runs the
    /// same op_require prelude (env.findNs / require_resolver /
    /// raise on null + on non-null), then applies the alias +
    /// per-refer installation, mirroring `tree_walk::evalRequire`.
    /// Row 7.10 cycle 3 (D-073 sub-site d discharge) — ADR-0036
    /// dual-backend parity contract's first real-feature exercise.
    /// Devil's-advocate Alt 2 (chunk side-table, parallel to
    /// `call_sites`) selected over Vector-in-constant-pool (Option A)
    /// for native field types (no empty-string sentinel for absent
    /// alias) + F-008 zwasm-component-import shape alignment.
    op_require_with_libspec = 0x1B,

    /// `(binding [*v* e ...])` — operand = pair count N. Pops 2N stack
    /// entries `[encVar0, val0, encVar1, val1, …]` (each `encVar` a
    /// `var_ref`-encoded Value), builds a per-thread `BindingFrame`
    /// (validating each target's `flags.dynamic`, else raising
    /// `binding_target_not_dynamic`), and installs it on the env
    /// threadlocal. Paired with `op_pop_binding_frame`; the compiler
    /// wraps the body in a cleanup handler so a thrown exception pops
    /// the frame before escaping (= JVM `finally`).
    op_push_binding_frame = 0x1C,
    /// Pop + free the innermost binding frame. Operand unused.
    op_pop_binding_frame = 0x1D,
    /// `(Class/method args...)` — operand = `call_site_idx` into
    /// `BytecodeChunk.call_sites`. The entry's `descriptor` is non-null
    /// (the analyze-time `InteropCallNode.descriptor`); pops `arg_count`
    /// user args (NO receiver), raw `descriptor.lookupMethod(null, name)`
    /// (matching TreeWalk's cache-free `evalStaticMethodCall` — the
    /// CallSite cache is intentionally skipped, ADR-0050 am2 / D-130),
    /// then `vt.callFn`. Sibling to `op_method_call` (one opcode per
    /// dispatch discipline; am2 reuses `CallSiteEntry` rather than minting
    /// a parallel struct).
    op_static_method_call = 0x1E,

    /// `(binding …)` / bare `(try …)` cleanup edge — operand = signed
    /// forward offset to the cleanup ip (same encoding as
    /// `op_push_handler`). Pushes a `.cleanup`-kind handler: unlike a
    /// `catch` handler, an error reaching it is NOT converted to a
    /// synthetic exception and the dynamic error-context is NOT cleared
    /// — the cleanup bytecode runs and `op_reraise` re-fires the
    /// ORIGINAL error unchanged (= TreeWalk's `defer popFrame`). ADR-0071.
    op_push_cleanup = 0x1F,
    /// Re-fire the in-flight error stashed by the cleanup-handler unwind
    /// (`dispatch.vm_pending_reraise`) WITHOUT conversion / context
    /// mutation. Operand unused. Emitted at the tail of a `.cleanup`
    /// edge after the cleanup bytecode (e.g. `op_pop_binding_frame`).
    /// ADR-0071.
    op_reraise = 0x20,
    /// `(catch :type-kw e …)` — operand = constants index of the catch
    /// keyword Value. Peeks the thrown Value (top of stack) and pushes
    /// `true` iff it is an ex-info whose data map's `:type` equals the
    /// catch keyword (interned identity). Sibling to `op_match_class`;
    /// mirrors `tree_walk::catchMatches` `.type_keyword` arm. Closes the
    /// D-014b VM-DEFER (ADR-0036 dual-backend parity).
    op_match_type_keyword = 0x21,
    /// `(ns foo (:refer-clojure :exclude […] / :only […]))` — operand =
    /// index into `BytecodeChunk.ns_filters`. Enters the ns (findOrCreateNs
    /// + current_ns) then refers `rt` + `clojure.core` THROUGH the entry's
    /// exclude/only filter (`referAllWithFilter`). Pushes nil. Sibling to
    /// `op_ns_with_refer_clojure` (the unfiltered case); ns-level `:require`
    /// libspecs are emitted separately as `op_require[_with_libspec]`.
    /// Closes the D-098 VM-DEFER (ADR-0036 dual-backend parity).
    op_ns_with_filter = 0x22,
    /// `letfn*` closure wiring. operand = `(count << 8) | base_slot`:
    /// after every letfn closure is stored in `locals[base .. base+count)`,
    /// patch each closure's captured letfn slots with the real siblings so
    /// mutual recursion resolves. Stack-neutral (operates on `locals`).
    op_letfn_patch = 0x23,
    /// `(set! *v* value)`. operand = constant index of a `.var_ref` Value
    /// (the target Var). Peeks the top-of-stack value (the assigned value,
    /// which stays as the form's result), updates the Var's innermost thread
    /// binding or, if none active, its root.
    op_set_var = 0x24,
    /// `(:import pkg.Class …)` — operand = index into the `import_sites`
    /// side-table (one entry per imported class). Registers simple->fqcn into
    /// the current ns and pushes nil. (D-235.)
    op_ns_import = 0x25,

    /// `(def x)` no-init: intern an UNBOUND placeholder (operand layout = op_def:
    /// name-idx + flag bits, but consumes NO stack value). Leaves an existing
    /// root intact and `Var.bound` false (the unbound sentinel for `bound?` /
    /// `defonce`). Pushes the Var ref. Distinct opcode because op_def's u16 is
    /// full (13-bit name-idx + 3 flag bits, no spare bit for has_init).
    op_def_unbound = 0x26,

    /// `(set! field v)` on a deftype mutable field (ADR-0104 / D-288).
    /// operand = constant index of the field-name String. Stack on entry:
    /// `[…, receiver, value]` (target compiled, then value). Resolves the
    /// receiver's `field_layout` index by name, writes the slot in place, pops
    /// both, pushes `value` (the form's result). Receiver is always a
    /// `.typed_instance` (the analyzer only emits this for an in-method `this`).
    op_set_field = 0x27,

    /// ADR-0130: `(+ a b)` arithmetic intrinsic — emitted by the compiler when
    /// the callee resolves (by Var pointer identity) to canonical `clojure.core/+`
    /// with exactly 2 args. No operand. Stack on entry: `[…, a, b]`; pops both,
    /// pushes the sum. Dispatch: if `rt.core_arith_pristine` and both operands are
    /// inline fixnums → `intrinsic.fastBinaryFixnum(.add)` (= `promote.addPromoting`,
    /// F-005 overflow→bigint); else `vt.callFn` the cached `+` builtin Var (full
    /// numeric-tower + arg-precise error parity). Net stack effect −1 (not a pure
    /// push). First cut of the intrinsic family (op_sub/op_mul/op_lt… follow).
    op_add = 0x28,

    /// True when this opcode carries a **signed-i16 instruction-position
    /// offset** in `operand`, relative to the instruction after itself
    /// (vm.zig:188-201 + :317 `applyJump`). Peephole's IP-remap pass
    /// (ADR-0047) re-resolves these on instruction removal; mis-classifying
    /// a future position-relative op as non-relative would let the pass
    /// silently corrupt control flow. Exhaustive by design: adding a new
    /// opcode forces a position-relative decision here at compile time.
    /// Safe default for any new op is `false`.
    pub fn isPositionRelative(self: Opcode) bool {
        return switch (self) {
            .op_jump, .op_jump_if_false, .op_push_handler, .op_push_cleanup => true,
            .op_const,
            .op_load_local,
            .op_store_local,
            .op_def,
            .op_def_unbound,
            .op_get_var,
            .op_call,
            .op_ret,
            .op_pop,
            .op_dup,
            .op_throw,
            .op_make_fn,
            .op_recur,
            .op_invoke_builtin,
            .op_pop_handler,
            .op_match_class,
            .op_in_ns,
            .op_vector_literal,
            .op_map_literal,
            .op_set_literal,
            .op_require,
            .op_ns_with_refer_clojure,
            .op_ctor_call,
            .op_method_call,
            .op_require_with_libspec,
            .op_push_binding_frame,
            .op_pop_binding_frame,
            .op_static_method_call,
            .op_reraise,
            .op_match_type_keyword,
            .op_ns_with_filter,
            .op_letfn_patch,
            .op_set_var,
            .op_ns_import,
            .op_set_field,
            .op_add,
            => false,
        };
    }

    /// True when this opcode pushes exactly one value with no side
    /// effect and no other stack effect — so a pure push immediately
    /// followed by `op_pop` is a removable no-op (peephole, ADR-0047).
    /// Exhaustive by design: adding a new opcode forces a purity
    /// decision here at compile time. Mis-classifying a side-effecting
    /// op as pure would let peephole silently drop the effect and
    /// break the ADR-0005 differential oracle, so the safe default for
    /// any new op is `false` (loses optimization, never correctness).
    pub fn isPurePush(self: Opcode) bool {
        return switch (self) {
            .op_const, .op_load_local => true,
            .op_store_local,
            .op_def,
            .op_def_unbound,
            .op_get_var,
            .op_jump,
            .op_jump_if_false,
            .op_call,
            .op_ret,
            .op_pop,
            .op_dup,
            .op_throw,
            .op_make_fn,
            .op_recur,
            .op_invoke_builtin,
            .op_push_handler,
            .op_pop_handler,
            .op_match_class,
            .op_in_ns,
            .op_vector_literal,
            .op_map_literal,
            .op_set_literal,
            .op_require,
            .op_ns_with_refer_clojure,
            .op_ctor_call,
            .op_method_call,
            .op_require_with_libspec,
            .op_push_binding_frame,
            .op_pop_binding_frame,
            .op_static_method_call,
            .op_push_cleanup,
            .op_reraise,
            .op_match_type_keyword,
            .op_ns_with_filter,
            .op_letfn_patch,
            .op_set_var,
            .op_ns_import,
            .op_set_field,
            .op_add,
            => false,
        };
    }
};

/// `op_def` operand layout — see the Opcode docstring.
pub const DEF_NAME_IDX_MASK: u16 = 0x1FFF;
pub const DEF_NAME_IDX_MAX: u16 = DEF_NAME_IDX_MASK;
pub const DEF_FLAG_DYNAMIC: u16 = 1 << 13;
pub const DEF_FLAG_MACRO: u16 = 1 << 14;
pub const DEF_FLAG_PRIVATE: u16 = 1 << 15;

/// A single VM instruction. Fixed-width (opcode + u16 operand).
///
/// The typed struct is deliberate; ClojureWasm v1 uses a flat
/// `[]u8` stream for JIT-friendly cache density, but cw v2 keeps
/// the typed form for safety and debuggability. JIT-era byte
/// packing is Phase 17+ work.
pub const Instruction = struct {
    opcode: Opcode,
    operand: u16 = 0,
    /// Source position of the form this instruction was compiled from
    /// (ADR-0118 Decision A Rev 1 — closes the VM eval-error `0:0` gap).
    /// The file label is per-chunk (`BytecodeChunk.source_file`); only
    /// line:col rides each instruction so the op the VM is executing on
    /// error annotates the catalog `Info.location`. Default 0 = unknown
    /// (e.g. AOT-deserialized chunks, which don't carry per-op loc — the
    /// serialize format stays `opcode:u8 + operand:u16`).
    line: u32 = 0,
    column: u16 = 0,
};

/// Per-call-site cache entry — row 7.6 cycle 4 (ADR-0040 Shape 1.b).
/// Each `op_method_call` instruction references one of these by
/// index. The `cache` field is mutated at dispatch time; the rest
/// is compile-time fixed. Analyzer-arena-owned (chunk lifetime).
pub const CallSiteEntry = struct {
    method_name: []const u8,
    arg_count: u16,
    /// ADR-0050 am1: set for the `(.-name recv)` reader form. When true the
    /// resolver reads a field only and never falls back to a method call.
    field_only: bool = false,
    /// ADR-0050 am2: non-null ⇒ STATIC dispatch (op_static_method_call) —
    /// the analyze-time `InteropCallNode.descriptor`; `arg_count` is the
    /// user-arg count with NO receiver, and `cache` is unused (static uses
    /// the raw `lookupMethod` matching TreeWalk). `null` ⇒ instance
    /// dispatch (op_method_call) — descriptor derived from the receiver's
    /// runtime tag, `cache` active. One shared entry, two modes.
    descriptor: ?*const TypeDescriptor = null,
    cache: method_table.CallSite = .{},
};

/// Per-libspec side-table entry — row 7.10 cycle 3 (ADR-0036 first
/// real-feature exercise). Each `op_require_with_libspec` instruction
/// references one of these by index. All fields are compile-time
/// fixed (analyzer-arena-owned, chunk lifetime). Native field types
/// (no sentinel encoding for absent alias) keep the dispatch arm a
/// straight mirror of `tree_walk::evalRequire`.
pub const LibspecEntry = struct {
    ns_name: []const u8,
    alias: ?[]const u8 = null,
    refers: []const []const u8 = &.{},
    /// `:refer :all` / `:use` — refer ALL public vars (env.referAll).
    refer_all: bool = false,
    /// `:exclude [a b]` blacklist applied when `refer_all` is set
    /// (env.referAllWithFilter). Empty = no blacklist.
    exclude: []const []const u8 = &.{},
};

/// Per-`(Class. …)`-constructor side-table entry (D-233). Each
/// `op_ctor_call` instruction references one by index. The class name lives
/// here (not packed into the operand) so it carries full width — the old
/// `(name_idx << 8) | arg_count` packing truncated name_idx to 8 bits and
/// corrupted ctor calls in chunks with > 255 constants. `type_name` is
/// analyzer-arena-owned, chunk lifetime.
pub const CtorEntry = struct {
    type_name: []const u8,
    arg_count: u16,
};

/// Per-`(:import …)`-class side-table entry (D-235). Each `op_ns_import`
/// instruction references one by index: `simple` is the bare class name,
/// `fqcn` the JVM-form fully-qualified name it maps to. Analyzer-arena-owned,
/// chunk lifetime.
pub const ImportPair = struct {
    simple: []const u8,
    fqcn: []const u8,
};

/// Per-`(ns …)`-filter side-table entry (D-098). Each `op_ns_with_filter`
/// instruction references one by index. `exclude` / `only` are the
/// `:refer-clojure` filter lists threaded into `referAllWithFilter`
/// (`only == null` ⇒ no whitelist). All fields are analyzer-arena-owned,
/// chunk lifetime — a straight mirror of `tree_walk::evalNs`.
pub const NsFilterEntry = struct {
    name: []const u8,
    exclude: []const []const u8 = &.{},
    only: ?[]const []const u8 = null,
};

/// Compiled bytecode for a single function or top-level form.
///
/// The chunk is immutable after compile (except for `call_sites[i].cache`
/// which mutates monomorphically at first dispatch). The compiler
/// owns the slices through the analyzer arena; the VM borrows them
/// for the duration of a call.
pub const BytecodeChunk = struct {
    instructions: []const Instruction,
    constants: []const Value,
    /// Source file label shared by every instruction in this chunk
    /// (ADR-0118 — the per-op `line`/`column` + this = the full
    /// `SourceLocation` the VM annotates on error). `"unknown"` for
    /// AOT-deserialized chunks (the serialize format omits it).
    source_file: []const u8 = "unknown",
    /// Side-table indexed by `op_method_call` operand. Empty for
    /// chunks that contain no method-call sites.
    call_sites: []CallSiteEntry = &.{},
    /// Side-table indexed by `op_require_with_libspec` operand. Empty
    /// for chunks that contain no libspec require sites.
    libspecs: []LibspecEntry = &.{},
    /// Side-table indexed by `op_ns_with_filter` operand. Empty for
    /// chunks with no filtered `(ns …)` form.
    ns_filters: []NsFilterEntry = &.{},
    /// Side-table indexed by `op_ctor_call` operand. Empty for chunks with
    /// no `(Class. …)` constructor call.
    ctor_sites: []CtorEntry = &.{},
    /// Side-table indexed by `op_ns_import` operand. Empty for chunks with no
    /// `(:import …)` directive.
    import_sites: []ImportPair = &.{},
};

test "opcode enum tags are stable u8 values" {
    try std.testing.expectEqual(@as(u8, 0x00), @intFromEnum(Opcode.op_const));
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(Opcode.op_load_local));
    try std.testing.expectEqual(@as(u8, 0x02), @intFromEnum(Opcode.op_store_local));
    try std.testing.expectEqual(@as(u8, 0x03), @intFromEnum(Opcode.op_def));
    try std.testing.expectEqual(@as(u8, 0x04), @intFromEnum(Opcode.op_get_var));
    try std.testing.expectEqual(@as(u8, 0x05), @intFromEnum(Opcode.op_jump));
    try std.testing.expectEqual(@as(u8, 0x06), @intFromEnum(Opcode.op_jump_if_false));
    try std.testing.expectEqual(@as(u8, 0x07), @intFromEnum(Opcode.op_call));
    try std.testing.expectEqual(@as(u8, 0x08), @intFromEnum(Opcode.op_ret));
    try std.testing.expectEqual(@as(u8, 0x09), @intFromEnum(Opcode.op_pop));
    try std.testing.expectEqual(@as(u8, 0x0A), @intFromEnum(Opcode.op_dup));
    try std.testing.expectEqual(@as(u8, 0x0B), @intFromEnum(Opcode.op_throw));
    try std.testing.expectEqual(@as(u8, 0x0C), @intFromEnum(Opcode.op_make_fn));
    try std.testing.expectEqual(@as(u8, 0x0D), @intFromEnum(Opcode.op_recur));
    try std.testing.expectEqual(@as(u8, 0x0E), @intFromEnum(Opcode.op_invoke_builtin));
    try std.testing.expectEqual(@as(u8, 0x0F), @intFromEnum(Opcode.op_push_handler));
    try std.testing.expectEqual(@as(u8, 0x10), @intFromEnum(Opcode.op_pop_handler));
    try std.testing.expectEqual(@as(u8, 0x11), @intFromEnum(Opcode.op_match_class));
    try std.testing.expectEqual(@as(u8, 0x12), @intFromEnum(Opcode.op_in_ns));
    try std.testing.expectEqual(@as(u8, 0x13), @intFromEnum(Opcode.op_vector_literal));
    try std.testing.expectEqual(@as(u8, 0x14), @intFromEnum(Opcode.op_map_literal));
    try std.testing.expectEqual(@as(u8, 0x15), @intFromEnum(Opcode.op_set_literal));
    try std.testing.expectEqual(@as(u8, 0x16), @intFromEnum(Opcode.op_require));
    try std.testing.expectEqual(@as(u8, 0x17), @intFromEnum(Opcode.op_ns_with_refer_clojure));
    try std.testing.expectEqual(@as(u8, 0x19), @intFromEnum(Opcode.op_ctor_call));
    try std.testing.expectEqual(@as(u8, 0x1A), @intFromEnum(Opcode.op_method_call));
    try std.testing.expectEqual(@as(u8, 0x1B), @intFromEnum(Opcode.op_require_with_libspec));
    try std.testing.expectEqual(@as(u8, 0x1E), @intFromEnum(Opcode.op_static_method_call));
}

test "Instruction carries opcode and u16 operand" {
    const ins: Instruction = .{ .opcode = .op_const, .operand = 42 };
    try std.testing.expectEqual(Opcode.op_const, ins.opcode);
    try std.testing.expectEqual(@as(u16, 42), ins.operand);

    const ret: Instruction = .{ .opcode = .op_ret };
    try std.testing.expectEqual(@as(u16, 0), ret.operand);
}

test "Instruction operand reaches u16 boundary" {
    const ins: Instruction = .{ .opcode = .op_jump, .operand = std.math.maxInt(u16) };
    try std.testing.expectEqual(@as(u16, 65535), ins.operand);
}

test "BytecodeChunk holds instructions and constants" {
    const instrs = [_]Instruction{
        .{ .opcode = .op_const, .operand = 0 },
        .{ .opcode = .op_ret },
    };
    const constants = [_]Value{Value.nil_val};
    const chunk: BytecodeChunk = .{
        .instructions = &instrs,
        .constants = &constants,
    };
    try std.testing.expectEqual(@as(usize, 2), chunk.instructions.len);
    try std.testing.expectEqual(@as(usize, 1), chunk.constants.len);
    try std.testing.expectEqual(Opcode.op_const, chunk.instructions[0].opcode);
    try std.testing.expectEqual(Opcode.op_ret, chunk.instructions[1].opcode);
    try std.testing.expectEqual(Value.nil_val, chunk.constants[0]);
}

test "empty BytecodeChunk is well-formed" {
    const chunk: BytecodeChunk = .{
        .instructions = &.{},
        .constants = &.{},
    };
    try std.testing.expectEqual(@as(usize, 0), chunk.instructions.len);
    try std.testing.expectEqual(@as(usize, 0), chunk.constants.len);
}
