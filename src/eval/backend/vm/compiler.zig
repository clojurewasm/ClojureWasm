// SPDX-License-Identifier: EPL-2.0
//! Compiles an analyzed Node tree into an immutable `BytecodeChunk`.
//!
//! The compiler mirrors the TreeWalk backend's observable behaviour
//! (ADR-0005 / ADR-0022). It is a state-holding struct that grows
//! mutable instruction and constant ArrayLists while walking the
//! Node tree, then `finalize`s by duping the slices into the caller's
//! arena so the resulting chunk is immutable.
//!
//! Phase-1/2 special forms (`def` / `if` / `do` / `quote` / `let*` /
//! `fn*` / call) land across the early §9.6 / 4.5 cycles. The first
//! cycle handles `constant` Nodes (the leaf case all other forms
//! decompose into); subsequent cycles widen the `compileNode`
//! switch arm-by-arm.

const std = @import("std");
const node_mod = @import("../../node.zig");
const opcode_mod = @import("opcode.zig");
const peephole = @import("peephole.zig");
const value_mod = @import("../../../runtime/value/value.zig");
const env_mod = @import("../../../runtime/env.zig");
const runtime_mod = @import("../../../runtime/runtime.zig");
const string_mod = @import("../../../runtime/collection/string.zig");
const tree_walk = @import("../tree_walk.zig");

const Node = node_mod.Node;
const Opcode = opcode_mod.Opcode;
const Instruction = opcode_mod.Instruction;
const BytecodeChunk = opcode_mod.BytecodeChunk;
const Value = value_mod.Value;
const Runtime = runtime_mod.Runtime;

pub const Error = error{
    TooManyConstants,
    JumpTooFar,
    TooManyCallArgs,
    VectorLiteralTooLarge,
    MapLiteralTooLarge,
    SetLiteralTooLarge,
    NotImplemented,
} || std.mem.Allocator.Error;

/// One-shot entry: compile `root` into a finalised `BytecodeChunk`.
///
/// The chunk's `instructions` and `constants` slices are owned by
/// `arena` (analyzer-arena lifetime). New heap Values created during
/// compilation (currently: the symbol-name `String` for `def_node`)
/// are allocated through `rt` and tracked by the runtime's heap
/// ledger, so they outlive the arena and reach the future GC.
pub fn compile(
    rt: *Runtime,
    arena: std.mem.Allocator,
    root: *const Node,
) Error!BytecodeChunk {
    var c: Compiler = .init(rt, arena);
    defer c.deinit();
    try c.compileNode(root);
    try c.emit(.op_ret, 0);
    return try c.finalize();
}

const CallSiteEntry = opcode_mod.CallSiteEntry;
const LibspecEntry = opcode_mod.LibspecEntry;

const Compiler = struct {
    rt: *Runtime,
    arena: std.mem.Allocator,
    instructions: std.ArrayList(Instruction),
    constants: std.ArrayList(Value),
    /// Row 7.6 cycle 4 (ADR-0040) — per-call-site cache side-table.
    /// Each `op_method_call` instruction's operand indexes here.
    call_sites: std.ArrayList(CallSiteEntry),
    /// Row 7.10 cycle 3 (ADR-0036 first real-feature exercise) —
    /// per-libspec side-table. Each `op_require_with_libspec`
    /// instruction's operand indexes here.
    libspecs: std.ArrayList(LibspecEntry),
    /// Innermost enclosing `loop*` frame, or `null` outside a loop.
    /// `compileRecur` reads this to know the back-edge target IP and
    /// the slot list to rebind. Saved/restored across nested loops.
    current_loop: ?LoopFrame = null,

    const LoopFrame = struct {
        /// Instruction index `recur` jumps back to (the first
        /// instruction of the loop body — *after* the initial
        /// op_store_local sequence).
        top_ip: usize,
        bindings: []const node_mod.LetNode.Binding,
    };

    fn init(rt: *Runtime, arena: std.mem.Allocator) Compiler {
        return .{
            .rt = rt,
            .arena = arena,
            .instructions = .empty,
            .constants = .empty,
            .call_sites = .empty,
            .libspecs = .empty,
            .current_loop = null,
        };
    }

    fn deinit(self: *Compiler) void {
        self.instructions.deinit(self.arena);
        self.constants.deinit(self.arena);
        self.call_sites.deinit(self.arena);
        self.libspecs.deinit(self.arena);
    }

    fn compileNode(self: *Compiler, node: *const Node) Error!void {
        switch (node.*) {
            .constant => |n| try self.emitConst(n.value),
            .quote_node => |n| try self.emitConst(n.quoted),
            .do_node => |n| try self.compileDo(n.forms),
            .local_ref => |n| try self.emit(.op_load_local, n.index),
            .var_ref => |n| try self.compileVarRef(n),
            .def_node => |n| try self.compileDef(n),
            .if_node => |n| try self.compileIf(n),
            .let_node => |n| try self.compileLet(n),
            .call_node => |n| try self.compileCall(n),
            .fn_node => |n| try self.compileFn(n),
            .throw_node => |n| try self.compileThrow(n),
            .try_node => |n| try self.compileTry(n),
            .loop_node => |n| try self.compileLoop(n),
            .binding_node => |n| try self.compileBinding(n),
            .recur_node => |n| try self.compileRecur(n),
            .deftype_node => |n| try self.compileDeftype(n),
            .interop_call_node => |n| try self.compileInteropCall(n),
            .in_ns_node => |n| try self.compileInNs(n),
            .require_node => |n| try self.compileRequire(n),
            .ns_node => |n| try self.compileNs(n),
            // Closes D-060 (Phase 6.16.a-3.2): emit each element + the
            // `op_vector_literal <n>` operand. VM dispatch pops N values
            // and builds a PersistentVector.
            .vector_literal_node => |n| try self.compileVectorLiteral(n),
            // Closes D-059 + D-061 (Phase 6.16.b-2): same shape — emit
            // each element, then the matching collection-build opcode.
            .map_literal_node => |n| try self.compileMapLiteral(n),
            .set_literal_node => |n| try self.compileSetLiteral(n),
        }
    }

    fn compileVectorLiteral(self: *Compiler, n: node_mod.VectorLiteralNode) Error!void {
        for (n.elements) |*elt| try self.compileNode(elt);
        if (n.elements.len > std.math.maxInt(u16)) return error.VectorLiteralTooLarge;
        try self.emit(.op_vector_literal, @intCast(n.elements.len));
    }

    fn compileMapLiteral(self: *Compiler, n: node_mod.MapLiteralNode) Error!void {
        for (n.elements) |*elt| try self.compileNode(elt);
        if (n.elements.len > std.math.maxInt(u16)) return error.MapLiteralTooLarge;
        try self.emit(.op_map_literal, @intCast(n.elements.len));
    }

    fn compileSetLiteral(self: *Compiler, n: node_mod.SetLiteralNode) Error!void {
        for (n.elements) |*elt| try self.compileNode(elt);
        if (n.elements.len > std.math.maxInt(u16)) return error.SetLiteralTooLarge;
        try self.emit(.op_set_literal, @intCast(n.elements.len));
    }

    fn emitConst(self: *Compiler, v: Value) Error!void {
        const idx = try self.addConstant(v);
        try self.emit(.op_const, idx);
    }

    fn compileDo(self: *Compiler, forms: []const Node) Error!void {
        if (forms.len == 0) {
            try self.emitConst(Value.nil_val);
            return;
        }
        for (forms[0 .. forms.len - 1]) |*f| {
            try self.compileNode(f);
            try self.emit(.op_pop, 0);
        }
        try self.compileNode(&forms[forms.len - 1]);
    }

    fn compileIf(self: *Compiler, n: node_mod.IfNode) Error!void {
        try self.compileNode(n.cond);
        const jif = try self.emitJump(.op_jump_if_false);
        try self.compileNode(n.then_branch);
        const jend = try self.emitJump(.op_jump);
        try self.patchJump(jif);
        if (n.else_branch) |eb| {
            try self.compileNode(eb);
        } else {
            try self.emitConst(Value.nil_val);
        }
        try self.patchJump(jend);
    }

    fn compileLet(self: *Compiler, n: node_mod.LetNode) Error!void {
        for (n.bindings) |b| {
            try self.compileNode(b.value_expr);
            try self.emit(.op_store_local, b.index);
        }
        try self.compileNode(n.body);
    }

    fn compileVarRef(self: *Compiler, n: node_mod.VarRef) Error!void {
        // The analyzer has already resolved the Var pointer. Encode it
        // as a heap-tagged Value, stash it in the constant pool, and
        // emit `op_get_var <idx>` — the VM dispatch loop decodes the
        // pointer and calls `Var.deref`.
        const var_value = Value.encodeHeapPtr(.var_ref, n.var_ptr);
        const idx = try self.addConstant(var_value);
        try self.emit(.op_get_var, idx);
    }

    fn compileCall(self: *Compiler, n: node_mod.CallNode) Error!void {
        try self.compileNode(n.callee);
        if (n.args.len > std.math.maxInt(u16)) return error.TooManyCallArgs;
        for (n.args) |*a| try self.compileNode(a);
        try self.emit(.op_call, @intCast(n.args.len));
    }

    fn compileFn(self: *Compiler, n: node_mod.FnNode) Error!void {
        // Row 7.8 cycle 1 (ADR-0041): emit one BytecodeChunk per
        // FnMethod (and one for `variadic` if present). The Function
        // dispatcher (`callFunction` / `op_make_fn`) selects the
        // chunk matching the call's arity. Sub-compiler state
        // isolation lets the outer compiler continue appending
        // instructions after each nested chunk finalizes.
        const method_chunks = try self.arena.alloc(?*const BytecodeChunk, n.methods.len);
        for (n.methods, 0..) |m, i| {
            method_chunks[i] = try self.compileFnMethodBody(m.body);
        }
        const variadic_chunk: ?*const BytecodeChunk = if (n.variadic) |v|
            try self.compileFnMethodBody(v.body)
        else
            null;

        // Closure-less fns (slot_base == 0): allocate the final
        // Function at compile time and push as a constant. Closure
        // capture (slot_base > 0): allocate a *template* Function
        // (closure_bindings stays null); op_make_fn dispatcher
        // snapshots the caller's locals at run time.
        const fn_val = if (n.slot_base == 0)
            try tree_walk.allocFunctionWithBytecode(self.rt, n, &.{}, method_chunks, variadic_chunk)
        else
            try tree_walk.allocFunctionTemplate(self.rt, n, method_chunks, variadic_chunk);

        const idx = try self.addConstant(fn_val);
        try self.emit(.op_make_fn, idx);
    }

    fn compileFnMethodBody(self: *Compiler, body: *const Node) Error!*const BytecodeChunk {
        var sub: Compiler = .init(self.rt, self.arena);
        defer sub.deinit();
        try sub.compileNode(body);
        try sub.emit(.op_ret, 0);
        const body_chunk = try sub.finalize();
        const chunk_ptr = try self.arena.create(BytecodeChunk);
        chunk_ptr.* = body_chunk;
        return chunk_ptr;
    }

    fn compileLoop(self: *Compiler, n: node_mod.LoopNode) Error!void {
        // (loop* [n1 e1 …] body) — same binding shape as let*: emit
        // each value-expr + op_store_local. The loop top is the body's
        // first instruction (after the initial binds), so a back-edge
        // `op_jump` rewinds straight to the body without re-running
        // initial binds.
        for (n.bindings) |b| {
            try self.compileNode(b.value_expr);
            try self.emit(.op_store_local, b.index);
        }
        const saved = self.current_loop;
        defer self.current_loop = saved;
        self.current_loop = .{
            .top_ip = self.instructions.items.len,
            .bindings = n.bindings,
        };
        try self.compileNode(n.body);
    }

    fn compileRecur(self: *Compiler, n: node_mod.RecurNode) Error!void {
        // recur target = innermost enclosing loop frame, supplied by
        // the analyser via current_loop. Stack discipline: push args
        // in order, then `op_recur <N>` (arity check), then pop them
        // back into the loop's binding slots in reverse order so the
        // bindings see the pre-recur frame (matches TreeWalk's
        // "evaluate all args before mutating any slot" semantics).
        // Both invariants are analyser-guaranteed; this is a defensive
        // dev-only check (the analyser rejects recur outside loop and
        // recur with mismatched arity at parse time). `unreachable`
        // per Zig 0.16 idiom for analyzer-guaranteed conditions —
        // not a VM-DEFER site (= these branches are not deferred VM
        // semantics, they are claims about analyzer correctness).
        const frame = self.current_loop.?;
        if (n.args.len != frame.bindings.len) unreachable;
        if (n.args.len > std.math.maxInt(u16)) return error.TooManyCallArgs;
        for (n.args) |*a| try self.compileNode(a);
        try self.emit(.op_recur, @intCast(n.args.len));
        var i: usize = frame.bindings.len;
        while (i > 0) {
            i -= 1;
            try self.emit(.op_store_local, frame.bindings[i].index);
        }
        const back_distance: usize = self.instructions.items.len + 1 - frame.top_ip;
        if (back_distance > std.math.maxInt(i16))
            return error.JumpTooFar;
        const back_offset: i16 = -@as(i16, @intCast(back_distance));
        try self.emit(.op_jump, @as(u16, @bitCast(back_offset)));
    }

    fn compileTry(self: *Compiler, n: node_mod.TryNode) Error!void {
        // Lowering shape (mirrors TreeWalk's evalTry semantics):
        //
        //   op_push_handler  +offset_to_handler
        //   <body>
        //   op_pop_handler
        //   [finally]                                   ; success path
        //   op_jump  +offset_to_end
        // handler:                                     ; thrown on stack
        //   for each catch clause:
        //     op_match_class <class_idx>               ; peek, push bool
        //     op_jump_if_false +offset_to_next_clause
        //     op_store_local <binding_idx>             ; pop thrown
        //     <catch body>
        //     [finally]                                ; matched-catch path
        //     op_jump  +offset_to_end
        //   ; no clause matched — thrown still on stack
        //   [finally]                                  ; no-match path
        //   op_throw                                   ; re-raises
        // end:
        //
        // `finally` is duplicated on each exit edge so no opcode
        // overhead is paid at run time and the BytecodeChunk shape
        // stays simple (matches JVM Clojure's lowering).

        const push_handler_idx = try self.emitJump(.op_push_handler);
        try self.compileNode(n.body);
        try self.emit(.op_pop_handler, 0);
        if (n.finally_body) |fb| try self.compileFinallyPreservingTop(fb);
        const success_jump_idx = try self.emitJump(.op_jump);

        try self.patchJump(push_handler_idx);

        var end_jump_indices: std.ArrayList(usize) = .empty;
        defer end_jump_indices.deinit(self.arena);
        try end_jump_indices.append(self.arena, success_jump_idx);

        for (n.catch_clauses) |cc| {
            const class_name = switch (cc.target) {
                .class_name => |name| name,
                // VM-DEFER: keyword catch dispatch pending op_match_type_keyword design [refs: D-014b, feature_deps.yaml#runtime/eval/catch_type_keyword]
                .type_keyword => return error.NotImplemented,
            };
            const class_val = try string_mod.alloc(self.rt, class_name);
            const class_idx = try self.addConstant(class_val);
            try self.emit(.op_match_class, class_idx);
            const skip_clause_idx = try self.emitJump(.op_jump_if_false);
            try self.emit(.op_store_local, cc.binding_index);
            try self.compileNode(cc.body);
            if (n.finally_body) |fb| try self.compileFinallyPreservingTop(fb);
            const clause_end_jump = try self.emitJump(.op_jump);
            try end_jump_indices.append(self.arena, clause_end_jump);
            try self.patchJump(skip_clause_idx);
        }

        // No clause matched (or no clauses at all). The thrown Value is
        // still on top of the operand stack; run finally on the
        // re-raise path, then op_throw re-fires the unwind.
        if (n.finally_body) |fb| try self.compileFinallyPreservingTop(fb);
        try self.emit(.op_throw, 0);

        for (end_jump_indices.items) |idx| try self.patchJump(idx);
    }

    /// Emit `finally`'s body and discard its result so the
    /// surrounding form's top-of-stack remains the body or catch
    /// result. Per JVM Clojure semantics, finally is evaluated for
    /// effect, not value.
    fn compileFinallyPreservingTop(self: *Compiler, fb: *const node_mod.Node) Error!void {
        try self.compileNode(fb);
        try self.emit(.op_pop, 0);
    }

    fn compileBinding(self: *Compiler, n: node_mod.BindingNode) Error!void {
        // Lowering shape (mirrors evalBinding + reuses compileTry's
        // duplicate-cleanup-on-each-edge so a thrown exception pops the
        // frame before escaping = JVM finally):
        //
        //   for each pair: op_const <encVar>          ; var_ref-encoded Var
        //                  <value_expr>                ; init in outer scope
        //   op_push_binding_frame  N                  ; pops 2N, installs frame
        //   op_push_handler  +cleanup
        //   <body>
        //   op_pop_handler
        //   op_pop_binding_frame                       ; success-path pop
        //   op_jump  +end
        // cleanup:                                     ; thrown on stack
        //   op_pop_binding_frame                       ; exception-path pop
        //   op_throw                                   ; re-raises
        // end:
        if (n.pairs.len > std.math.maxInt(u16)) return Error.TooManyConstants;
        for (n.pairs) |pair| {
            // var_ref-encode the resolved Var into the constant pool, same
            // shape op_def / op_get_var use for Var references.
            try self.emitConst(Value.encodeHeapPtr(.var_ref, pair.var_ptr));
            try self.compileNode(pair.value_expr);
        }
        try self.emit(.op_push_binding_frame, @intCast(n.pairs.len));

        const handler_idx = try self.emitJump(.op_push_handler);
        try self.compileNode(n.body);
        try self.emit(.op_pop_handler, 0);
        try self.emit(.op_pop_binding_frame, 0);
        const end_jump = try self.emitJump(.op_jump);

        try self.patchJump(handler_idx);
        try self.emit(.op_pop_binding_frame, 0);
        try self.emit(.op_throw, 0);

        try self.patchJump(end_jump);
    }

    fn compileThrow(self: *Compiler, n: node_mod.ThrowNode) Error!void {
        // (throw expr) — TreeWalk's evalThrow evaluates the expr then
        // stashes the value in `dispatch.last_thrown_exception` and
        // returns `error.ThrownValue`. The VM dispatcher does both via
        // its `op_throw` arm, so the compiler emits the value-expr
        // followed by a single `op_throw` instruction.
        try self.compileNode(n.expr);
        try self.emit(.op_throw, 0);
    }

    // --- Row 7.6 cycle 4 (ADR-0040) deftype-family + method-dispatch ---

    /// `(deftype Name [fields])` — analyzer-time `registerType`
    /// already populated `rt.types`. The VM op pushes nil to match
    /// TreeWalk's `evalDeftype` return. Operand is unused for now
    /// (reserved for future per-deftype side-table metadata).
    fn compileDeftype(self: *Compiler, n: node_mod.DeftypeNode) Error!void {
        _ = n;
        try self.emit(.op_deftype, 0);
    }

    /// ADR-0050 (am1) unified InteropCallNode VM compile arm. Two kinds
    /// ship real bytecode: `.constructor` (op_ctor_call) and
    /// `.instance_member` (op_method_call — am1 folded the retired
    /// op_field_access into op_method_call's receiver-keyed resolver, so a
    /// field read and a method call share one call-site + opcode; the
    /// `field_only` flag carries the `.-name` form's field-only intent).
    /// `.static_method` is D-121's new dispatch shape; its bytecode form
    /// (single op_interop_call with kind operand, or a sibling
    /// op_static_method_call) lands at D-130 (row 7.6.b successor). Until
    /// then static_method rides VM-DEFER.
    fn compileInteropCall(self: *Compiler, n: node_mod.InteropCallNode) Error!void {
        switch (n.kind) {
            .constructor => {
                for (n.args) |*a| try self.compileNode(a);
                const name_val = try string_mod.alloc(self.rt, n.type_name);
                const name_idx = try self.addConstant(name_val);
                if (n.args.len > 0xFF) return Error.TooManyCallArgs;
                const operand: u16 = (@as(u16, name_idx) << 8) | @as(u16, @intCast(n.args.len));
                try self.emit(.op_ctor_call, operand);
            },
            .instance_member => {
                const target = n.target orelse @panic("compileInteropCall: target null for .instance_member (analyzer bug)");
                try self.compileNode(target);
                for (n.args) |*a| try self.compileNode(a);
                if (self.call_sites.items.len > std.math.maxInt(u16)) return Error.TooManyConstants;
                const cs_idx: u16 = @intCast(self.call_sites.items.len);
                const method_name_dup = try self.arena.dupe(u8, n.name);
                const total_args: u16 = @intCast(1 + n.args.len);
                try self.call_sites.append(self.arena, .{
                    .method_name = method_name_dup,
                    .arg_count = total_args,
                    .field_only = n.field_only,
                });
                try self.emit(.op_method_call, cs_idx);
            },
            .static_method => {
                // VM-DEFER: static method dispatch bytecode shape pending D-130 op_interop_call vs op_static_method_call decision [refs: D-130, feature_deps.yaml#runtime/vm/interop_call_static_method]
                return error.NotImplemented;
            },
        }
    }

    fn compileInNs(self: *Compiler, n: node_mod.InNsNode) Error!void {
        // ADR-0032 in-ns VM path. Heap-allocate the ns name as a
        // String Value (the dispatcher decodes it via
        // `string_collection.asString`), park it in the constant pool,
        // and emit op_in_ns. The dispatcher mutates env.current_ns
        // and pushes nil (matching tree_walk::evalInNs).
        const name_val = try string_mod.alloc(self.rt, n.ns_name);
        const idx = try self.addConstant(name_val);
        try self.emit(.op_in_ns, idx);
    }

    fn compileNs(self: *Compiler, n: node_mod.NsNode) Error!void {
        // ADR-0035 D1 ns VM path + D9 second amendment (Phase 7
        // entry T3, 2026-05-26). When `refer_clojure = true` emit
        // `op_ns_with_refer_clojure` which performs op_in_ns logic
        // + referAll(rt) + referAll(clojure.core). When
        // `refer_clojure = false` emit bare `op_in_ns`.
        //
        // Row 14.7 (D-098): the new fields `refer_clojure_exclude` /
        // `refer_clojure_only` / `libspecs` are TreeWalk-only today;
        // VM lowering needs a new opcode (`op_ns_with_filter <name_idx>
        // <filter_idx>`) plus a per-libspec side-table emission loop.
        // Both ride VM-DEFER until the bytecode side-table extension
        // settles per D-100 (a) constants-pool design.
        if (n.refer_clojure_exclude.len > 0 or n.refer_clojure_only != null or n.libspecs.len > 0) {
            // VM-DEFER: ns filter + libspec list pending op_ns_with_filter + libspec side-table extension [refs: D-098, feature_deps.yaml#runtime/vm/ns_filter_and_libspec]
            return error.NotImplemented;
        }
        const name_val = try string_mod.alloc(self.rt, n.name);
        const idx = try self.addConstant(name_val);
        if (n.refer_clojure) {
            try self.emit(.op_ns_with_refer_clojure, idx);
        } else {
            try self.emit(.op_in_ns, idx);
        }
    }

    fn compileRequire(self: *Compiler, n: node_mod.RequireNode) Error!void {
        // ADR-0035 D2 require VM path. The bare-symbol shape parks
        // the ns name as a String constant and emits op_require. The
        // libspec shape (alias or refers present) builds a LibspecEntry
        // in `self.libspecs` and emits op_require_with_libspec with
        // the side-table index — row 7.10 cycle 3 (ADR-0036 first
        // real-feature exercise; Devil's-advocate Alt 2 = chunk
        // side-table parallel to ADR-0040's `call_sites`).
        if (n.alias != null or n.refers.len > 0) {
            if (self.libspecs.items.len > std.math.maxInt(u16)) return Error.TooManyConstants;
            const idx: u16 = @intCast(self.libspecs.items.len);
            const ns_dup = try self.arena.dupe(u8, n.ns_name);
            const alias_dup: ?[]const u8 = if (n.alias) |a| try self.arena.dupe(u8, a) else null;
            const refers_dup = try self.arena.alloc([]const u8, n.refers.len);
            for (n.refers, 0..) |r, i| refers_dup[i] = try self.arena.dupe(u8, r);
            try self.libspecs.append(self.arena, .{
                .ns_name = ns_dup,
                .alias = alias_dup,
                .refers = refers_dup,
            });
            try self.emit(.op_require_with_libspec, idx);
            return;
        }
        const name_val = try string_mod.alloc(self.rt, n.ns_name);
        const idx = try self.addConstant(name_val);
        try self.emit(.op_require, idx);
    }

    fn compileDef(self: *Compiler, n: node_mod.DefNode) Error!void {
        // Emit the value expression first, then `op_def <packed>` where
        // the low 13 bits index the symbol-name String constant and
        // the high 3 bits carry the dynamic / macro / private flags
        // (see `opcode.zig` for the layout). The constant-pool ceiling
        // shrinks from u16 to `DEF_NAME_IDX_MAX` only for def name
        // slots — call / let / get_var indices keep the full u16.
        try self.compileNode(n.value_expr);
        const name_val = try string_mod.alloc(self.rt, n.name);
        const idx = try self.addConstant(name_val);
        if (idx > opcode_mod.DEF_NAME_IDX_MAX) return error.TooManyConstants;
        var packed_operand: u16 = idx;
        if (n.is_dynamic) packed_operand |= opcode_mod.DEF_FLAG_DYNAMIC;
        if (n.is_macro) packed_operand |= opcode_mod.DEF_FLAG_MACRO;
        if (n.is_private) packed_operand |= opcode_mod.DEF_FLAG_PRIVATE;
        try self.emit(.op_def, packed_operand);
    }

    /// Emit a jump opcode with a placeholder operand and return the
    /// instruction index so `patchJump` can fill in the offset once
    /// the target is known.
    fn emitJump(self: *Compiler, op: Opcode) Error!usize {
        const idx = self.instructions.items.len;
        try self.emit(op, 0);
        return idx;
    }

    /// Patch a previously emitted jump to land on the next instruction
    /// to be emitted. Offset is relative to the instruction *after*
    /// the jump (so 0 means "fall through").
    fn patchJump(self: *Compiler, jump_index: usize) Error!void {
        const offset = self.instructions.items.len - jump_index - 1;
        if (offset > std.math.maxInt(i16)) return error.JumpTooFar;
        self.instructions.items[jump_index].operand = @as(u16, @bitCast(@as(i16, @intCast(offset))));
    }

    fn emit(self: *Compiler, op: Opcode, operand: u16) Error!void {
        try self.instructions.append(self.arena, .{ .opcode = op, .operand = operand });
    }

    fn addConstant(self: *Compiler, v: Value) Error!u16 {
        if (self.constants.items.len > std.math.maxInt(u16)) return error.TooManyConstants;
        const idx: u16 = @intCast(self.constants.items.len);
        try self.constants.append(self.arena, v);
        return idx;
    }

    fn finalize(self: *Compiler) Error!BytecodeChunk {
        const raw = try self.arena.dupe(Instruction, self.instructions.items);
        const consts = try self.arena.dupe(Value, self.constants.items);
        const sites = try self.arena.dupe(CallSiteEntry, self.call_sites.items);
        const specs = try self.arena.dupe(LibspecEntry, self.libspecs.items);
        // ADR-0047 row 13.3: peephole runs inside finalize so every
        // chunk — top-level + every fn sub-chunk built via
        // compileFnMethodBody → sub.finalize() — is optimized through
        // the same path, and the Phase-12 serializer caches the
        // optimized chunk transparently.
        const instrs = try peephole.optimize(self.arena, raw);
        return .{ .instructions = instrs, .constants = consts, .call_sites = sites, .libspecs = specs };
    }
};

const testing = std.testing;

/// Minimal fixture that builds the Runtime + arena needed to call
/// `compile`. Heap Values allocated during compilation (e.g. the
/// symbol-name String emitted by `compileDef`) are tracked by
/// `rt.trackHeap` and freed in `rt.deinit`.
const Fixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,
    arena: std.heap.ArenaAllocator,

    fn init(alloc: std.mem.Allocator) Fixture {
        var f: Fixture = undefined;
        f.threaded = std.Io.Threaded.init(alloc, .{});
        f.rt = Runtime.init(f.threaded.io(), alloc);
        f.arena = std.heap.ArenaAllocator.init(alloc);
        return f;
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.rt.deinit();
        self.threaded.deinit();
    }

    fn compile(self: *Fixture, node: *const Node) Error!BytecodeChunk {
        return @import("compiler.zig").compile(&self.rt, self.arena.allocator(), node);
    }
};

test "compile constant emits op_const + op_ret" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const node: Node = .{ .constant = .{ .value = Value.nil_val } };
    const chunk = try f.compile(&node);

    try testing.expectEqual(@as(usize, 2), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[0].opcode);
    try testing.expectEqual(@as(u16, 0), chunk.instructions[0].operand);
    try testing.expectEqual(Opcode.op_ret, chunk.instructions[1].opcode);
    try testing.expectEqual(@as(usize, 1), chunk.constants.len);
    try testing.expectEqual(Value.nil_val, chunk.constants[0]);
}

test "compile records each constant exactly once" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const node: Node = .{ .constant = .{ .value = Value.true_val } };
    const chunk = try f.compile(&node);

    try testing.expectEqual(@as(usize, 1), chunk.constants.len);
    try testing.expectEqual(Value.true_val, chunk.constants[0]);
}

test "compile quote pushes the quoted value as a constant" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const node: Node = .{ .quote_node = .{ .quoted = Value.false_val } };
    const chunk = try f.compile(&node);

    try testing.expectEqual(@as(usize, 2), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[0].opcode);
    try testing.expectEqual(Opcode.op_ret, chunk.instructions[1].opcode);
    try testing.expectEqual(@as(usize, 1), chunk.constants.len);
    try testing.expectEqual(Value.false_val, chunk.constants[0]);
}

test "compile empty do yields nil constant" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const node: Node = .{ .do_node = .{ .forms = &.{} } };
    const chunk = try f.compile(&node);

    try testing.expectEqual(@as(usize, 2), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[0].opcode);
    try testing.expectEqual(Opcode.op_ret, chunk.instructions[1].opcode);
    try testing.expectEqual(@as(usize, 1), chunk.constants.len);
    try testing.expectEqual(Value.nil_val, chunk.constants[0]);
}

test "compile local_ref emits op_load_local with slot index" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const node: Node = .{ .local_ref = .{ .name = "x", .index = 3 } };
    const chunk = try f.compile(&node);

    try testing.expectEqual(@as(usize, 2), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_load_local, chunk.instructions[0].opcode);
    try testing.expectEqual(@as(u16, 3), chunk.instructions[0].operand);
    try testing.expectEqual(Opcode.op_ret, chunk.instructions[1].opcode);
}

test "compile if emits jump_if_false + jump with patched offsets" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const cond: Node = .{ .constant = .{ .value = Value.true_val } };
    const then_b: Node = .{ .constant = .{ .value = Value.false_val } };
    const else_b: Node = .{ .constant = .{ .value = Value.nil_val } };
    const node: Node = .{ .if_node = .{ .cond = &cond, .then_branch = &then_b, .else_branch = &else_b } };
    const chunk = try f.compile(&node);

    // op_const cond ; op_jump_if_false +2 ; op_const then ; op_jump +1 ; op_const else ; op_ret
    try testing.expectEqual(@as(usize, 6), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[0].opcode);
    try testing.expectEqual(Opcode.op_jump_if_false, chunk.instructions[1].opcode);
    try testing.expectEqual(@as(i16, 2), @as(i16, @bitCast(chunk.instructions[1].operand)));
    try testing.expectEqual(Opcode.op_const, chunk.instructions[2].opcode);
    try testing.expectEqual(Opcode.op_jump, chunk.instructions[3].opcode);
    try testing.expectEqual(@as(i16, 1), @as(i16, @bitCast(chunk.instructions[3].operand)));
    try testing.expectEqual(Opcode.op_const, chunk.instructions[4].opcode);
    try testing.expectEqual(Opcode.op_ret, chunk.instructions[5].opcode);
}

test "compile if without else branch emits nil for the alternative" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const cond: Node = .{ .constant = .{ .value = Value.true_val } };
    const then_b: Node = .{ .constant = .{ .value = Value.false_val } };
    const node: Node = .{ .if_node = .{ .cond = &cond, .then_branch = &then_b, .else_branch = null } };
    const chunk = try f.compile(&node);

    try testing.expectEqual(@as(usize, 6), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[4].opcode);
    // The synthesized nil constant lives at index 2 in the pool.
    try testing.expectEqual(Value.nil_val, chunk.constants[chunk.instructions[4].operand]);
}

test "compile let* stores each binding then evaluates the body" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const v0: Node = .{ .constant = .{ .value = Value.true_val } };
    const v1: Node = .{ .constant = .{ .value = Value.false_val } };
    const body: Node = .{ .local_ref = .{ .name = "y", .index = 1 } };
    const bindings = [_]node_mod.LetNode.Binding{
        .{ .name = "x", .index = 0, .value_expr = &v0 },
        .{ .name = "y", .index = 1, .value_expr = &v1 },
    };
    const node: Node = .{ .let_node = .{ .bindings = &bindings, .body = &body } };
    const chunk = try f.compile(&node);

    // op_const true ; op_store_local 0 ; op_const false ; op_store_local 1 ; op_load_local 1 ; op_ret
    try testing.expectEqual(@as(usize, 6), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[0].opcode);
    try testing.expectEqual(Opcode.op_store_local, chunk.instructions[1].opcode);
    try testing.expectEqual(@as(u16, 0), chunk.instructions[1].operand);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[2].opcode);
    try testing.expectEqual(Opcode.op_store_local, chunk.instructions[3].opcode);
    try testing.expectEqual(@as(u16, 1), chunk.instructions[3].operand);
    try testing.expectEqual(Opcode.op_load_local, chunk.instructions[4].opcode);
    try testing.expectEqual(@as(u16, 1), chunk.instructions[4].operand);
    try testing.expectEqual(Opcode.op_ret, chunk.instructions[5].opcode);
}

test "compile var_ref stores the Var pointer Value and emits op_get_var" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    // The test does not deref the Var; it only checks that the
    // compiler encodes the pointer into the constant pool and emits
    // op_get_var with the correct index.
    var dummy_ns: env_mod.Namespace = undefined;
    var dummy_var: env_mod.Var = .{ .ns = &dummy_ns, .name = "x" };
    const node: Node = .{ .var_ref = .{ .var_ptr = &dummy_var } };
    const chunk = try f.compile(&node);

    try testing.expectEqual(@as(usize, 2), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_get_var, chunk.instructions[0].opcode);
    try testing.expectEqual(@as(u16, 0), chunk.instructions[0].operand);
    try testing.expectEqual(Opcode.op_ret, chunk.instructions[1].opcode);
    try testing.expectEqual(@as(usize, 1), chunk.constants.len);
    try testing.expectEqual(Value.encodeHeapPtr(.var_ref, &dummy_var), chunk.constants[0]);
}

test "compile call emits callee, args, op_call <arity>" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const callee: Node = .{ .constant = .{ .value = Value.true_val } };
    const args = [_]Node{
        .{ .constant = .{ .value = Value.false_val } },
        .{ .constant = .{ .value = Value.nil_val } },
    };
    const node: Node = .{ .call_node = .{ .callee = &callee, .args = &args } };
    const chunk = try f.compile(&node);

    // op_const callee ; op_const arg0 ; op_const arg1 ; op_call 2 ; op_ret
    try testing.expectEqual(@as(usize, 5), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[0].opcode);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[1].opcode);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[2].opcode);
    try testing.expectEqual(Opcode.op_call, chunk.instructions[3].opcode);
    try testing.expectEqual(@as(u16, 2), chunk.instructions[3].operand);
    try testing.expectEqual(Opcode.op_ret, chunk.instructions[4].opcode);
}

test "compile call with zero args emits op_call 0" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const callee: Node = .{ .constant = .{ .value = Value.true_val } };
    const node: Node = .{ .call_node = .{ .callee = &callee, .args = &.{} } };
    const chunk = try f.compile(&node);

    try testing.expectEqual(@as(usize, 3), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_call, chunk.instructions[1].opcode);
    try testing.expectEqual(@as(u16, 0), chunk.instructions[1].operand);
}

test "compile fn* (closure-less) allocates a Function with bytecode and emits op_make_fn" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    // (fn* [] true) — closure-less, zero-arg, body returns true.
    const body: Node = .{ .constant = .{ .value = Value.true_val } };
    const methods = [_]node_mod.FnMethod{.{
        .arity = 0,
        .has_rest = false,
        .params = &.{},
        .body = &body,
    }};
    const node: Node = .{ .fn_node = .{
        .methods = &methods,
        .slot_base = 0,
    } };
    const chunk = try f.compile(&node);

    // op_make_fn 0 ; op_ret
    try testing.expectEqual(@as(usize, 2), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_make_fn, chunk.instructions[0].opcode);
    try testing.expectEqual(@as(u16, 0), chunk.instructions[0].operand);
    try testing.expectEqual(Opcode.op_ret, chunk.instructions[1].opcode);

    // The constant is a Function Value whose first method's bytecode
    // body is the compiled (true ; ret) inner chunk.
    const fn_val = chunk.constants[0];
    try testing.expectEqual(value_mod.Value.Tag.fn_val, fn_val.tag());
    const fn_ptr = fn_val.decodePtr(*const tree_walk.Function);
    try testing.expectEqual(@as(usize, 1), fn_ptr.methods.len);
    try testing.expect(fn_ptr.methods[0].bytecode != null);
    const body_chunk = fn_ptr.methods[0].bytecode.?;
    try testing.expectEqual(@as(usize, 2), body_chunk.instructions.len);
    try testing.expectEqual(Opcode.op_const, body_chunk.instructions[0].opcode);
    try testing.expectEqual(Opcode.op_ret, body_chunk.instructions[1].opcode);
    try testing.expectEqual(Value.true_val, body_chunk.constants[0]);
}

test "compile fn* with slot_base > 0 emits a template Function (closure capture wired at op_make_fn)" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const body: Node = .{ .constant = .{ .value = Value.nil_val } };
    const methods = [_]node_mod.FnMethod{.{
        .arity = 0,
        .has_rest = false,
        .params = &.{},
        .body = &body,
    }};
    const node: Node = .{ .fn_node = .{
        .methods = &methods,
        .slot_base = 1,
    } };
    const chunk = try f.compile(&node);

    // The constant holds a *template* Function: slot_base > 0,
    // closure_bindings still null. The dispatcher snapshots locals
    // at op_make_fn time.
    const fn_val = chunk.constants[0];
    try testing.expectEqual(value_mod.Value.Tag.fn_val, fn_val.tag());
    const fn_ptr = fn_val.decodePtr(*const tree_walk.Function);
    try testing.expectEqual(@as(u16, 1), fn_ptr.slot_base);
    try testing.expect(fn_ptr.closure_bindings == null);
}

test "compile def emits value-expr then op_def with symbol-name String" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const value_expr: Node = .{ .constant = .{ .value = Value.true_val } };
    const node: Node = .{ .def_node = .{ .name = "hello", .value_expr = &value_expr } };
    const chunk = try f.compile(&node);

    // op_const true ; op_def <idx-of-"hello"> ; op_ret
    try testing.expectEqual(@as(usize, 3), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[0].opcode);
    try testing.expectEqual(Opcode.op_def, chunk.instructions[1].opcode);
    try testing.expectEqual(Opcode.op_ret, chunk.instructions[2].opcode);

    const operand = chunk.instructions[1].operand;
    try testing.expectEqual(@as(u16, 0), operand & ~opcode_mod.DEF_NAME_IDX_MASK);
    const name_val = chunk.constants[operand & opcode_mod.DEF_NAME_IDX_MASK];
    try testing.expect(name_val.isString());
    try testing.expectEqualStrings("hello", string_mod.asString(name_val));
}

test "compile def packs dynamic / macro / private flags into op_def operand" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const value_expr: Node = .{ .constant = .{ .value = Value.true_val } };
    const node: Node = .{ .def_node = .{
        .name = "foo",
        .value_expr = &value_expr,
        .is_dynamic = true,
        .is_macro = false,
        .is_private = true,
    } };
    const chunk = try f.compile(&node);

    const operand = chunk.instructions[1].operand;
    const name_idx = operand & opcode_mod.DEF_NAME_IDX_MASK;
    try testing.expectEqual(@as(u16, opcode_mod.DEF_FLAG_DYNAMIC), operand & opcode_mod.DEF_FLAG_DYNAMIC);
    try testing.expectEqual(@as(u16, 0), operand & opcode_mod.DEF_FLAG_MACRO);
    try testing.expectEqual(@as(u16, opcode_mod.DEF_FLAG_PRIVATE), operand & opcode_mod.DEF_FLAG_PRIVATE);
    try testing.expectEqualStrings("foo", string_mod.asString(chunk.constants[name_idx]));
}

test "compile loop* emits initial bindings then body without exit op" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    // (loop* [x true] x) — minimal loop with one binding, body is the
    // local ref. No recur, so no back-edge.
    const init_val: Node = .{ .constant = .{ .value = Value.true_val } };
    const body: Node = .{ .local_ref = .{ .name = "x", .index = 0 } };
    const bindings = [_]node_mod.LetNode.Binding{
        .{ .name = "x", .index = 0, .value_expr = &init_val },
    };
    const node: Node = .{ .loop_node = .{ .bindings = &bindings, .body = &body } };
    const chunk = try f.compile(&node);

    // op_const true ; op_store_local 0 ; op_load_local 0 ; op_ret
    try testing.expectEqual(@as(usize, 4), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[0].opcode);
    try testing.expectEqual(Opcode.op_store_local, chunk.instructions[1].opcode);
    try testing.expectEqual(Opcode.op_load_local, chunk.instructions[2].opcode);
    try testing.expectEqual(Opcode.op_ret, chunk.instructions[3].opcode);
}

test "compile recur emits args, op_recur, reverse op_store_locals, back-edge op_jump" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    // (loop* [i 0] (recur 1)) — one-arg recur drains stack into i.
    const init_val: Node = .{ .constant = .{ .value = Value.nil_val } };
    const recur_arg: Node = .{ .constant = .{ .value = Value.true_val } };
    const recur_args = [_]Node{recur_arg};
    const body: Node = .{ .recur_node = .{ .args = &recur_args } };
    const bindings = [_]node_mod.LetNode.Binding{
        .{ .name = "i", .index = 0, .value_expr = &init_val },
    };
    const node: Node = .{ .loop_node = .{ .bindings = &bindings, .body = &body } };
    const chunk = try f.compile(&node);

    // op_const nil ; op_store_local 0 ; <body starts here>
    // op_const true ; op_recur 1 ; op_store_local 0 ; op_jump -4 ; op_ret
    try testing.expectEqual(Opcode.op_store_local, chunk.instructions[1].opcode);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[2].opcode);
    try testing.expectEqual(Opcode.op_recur, chunk.instructions[3].opcode);
    try testing.expectEqual(@as(u16, 1), chunk.instructions[3].operand);
    try testing.expectEqual(Opcode.op_store_local, chunk.instructions[4].opcode);
    try testing.expectEqual(Opcode.op_jump, chunk.instructions[5].opcode);
    const back_offset: i16 = @bitCast(chunk.instructions[5].operand);
    try testing.expect(back_offset < 0);
}

test "compile try with no catches still emits push/pop_handler and re-raise path" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    // (try true) — no catches, no finally. The compiler still installs
    // a handler frame (so an exception inside the body unwinds
    // correctly) and the handler entry is just op_throw on the bare
    // thrown value.
    const body: Node = .{ .constant = .{ .value = Value.true_val } };
    const node: Node = .{ .try_node = .{ .body = &body, .catch_clauses = &.{} } };
    const chunk = try f.compile(&node);

    // Layout: push_handler ; const true ; pop_handler ; jump end ;
    //         handler: op_throw ; end: op_ret
    try testing.expectEqual(@as(usize, 6), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_push_handler, chunk.instructions[0].opcode);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[1].opcode);
    try testing.expectEqual(Opcode.op_pop_handler, chunk.instructions[2].opcode);
    try testing.expectEqual(Opcode.op_jump, chunk.instructions[3].opcode);
    try testing.expectEqual(Opcode.op_throw, chunk.instructions[4].opcode);
    try testing.expectEqual(Opcode.op_ret, chunk.instructions[5].opcode);
}

test "compile try with one catch wires match_class + jump_if_false + store_local" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    // (try true (catch ExceptionInfo e e))
    const body: Node = .{ .constant = .{ .value = Value.true_val } };
    const catch_body: Node = .{ .local_ref = .{ .name = "e", .index = 0 } };
    const clauses = [_]node_mod.TryNode.CatchClause{.{
        .target = .{ .class_name = "ExceptionInfo" },
        .binding_name = "e",
        .binding_index = 0,
        .body = &catch_body,
    }};
    const node: Node = .{ .try_node = .{ .body = &body, .catch_clauses = &clauses } };
    const chunk = try f.compile(&node);

    // Layout: push_handler ; const true ; pop_handler ; jump end ;
    //         match_class ; jump_if_false +skip ; store_local 0 ;
    //         local_ref 0 ; jump end ;
    //         (no-match path) op_throw ; end: op_ret
    try testing.expectEqual(Opcode.op_push_handler, chunk.instructions[0].opcode);
    try testing.expectEqual(Opcode.op_match_class, chunk.instructions[4].opcode);
    try testing.expectEqual(Opcode.op_jump_if_false, chunk.instructions[5].opcode);
    try testing.expectEqual(Opcode.op_store_local, chunk.instructions[6].opcode);
    try testing.expectEqual(Opcode.op_throw, chunk.instructions[chunk.instructions.len - 2].opcode);
    try testing.expectEqual(Opcode.op_ret, chunk.instructions[chunk.instructions.len - 1].opcode);
}

test "compile try with finally duplicates the finally body on each exit path" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    // (try true (finally :side)) — finally body is one form that the
    // compiler duplicates: once on success, once on re-raise. Each
    // copy is followed by op_pop because finally's value is discarded.
    const body: Node = .{ .constant = .{ .value = Value.true_val } };
    const fb: Node = .{ .constant = .{ .value = Value.nil_val } };
    const node: Node = .{ .try_node = .{
        .body = &body,
        .catch_clauses = &.{},
        .finally_body = &fb,
    } };
    const chunk = try f.compile(&node);

    var pop_count: usize = 0;
    for (chunk.instructions) |inst| {
        if (inst.opcode == .op_pop) pop_count += 1;
    }
    // Pre-ADR-0047 this asserted two op_pops, one per finally exit
    // (success + re-raise). Post-peephole, the success-path finally is
    // `op_const nil; op_pop` — a pure-push + discard — which peephole
    // elides as semantically dead (a constant with no side effect
    // dropped is correct). The re-raise-path finally is preserved
    // because the handler-target lands on its op_const, so the removal
    // guard blocks elision there. Net surviving op_pop count: 1.
    try testing.expectEqual(@as(usize, 1), pop_count);
}

test "compile throw emits value-expr then op_throw" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const expr: Node = .{ .constant = .{ .value = Value.true_val } };
    const node: Node = .{ .throw_node = .{ .expr = &expr } };
    const chunk = try f.compile(&node);

    // op_const true ; op_throw ; op_ret (the dispatcher returns via
    // op_throw's ThrownValue signal; op_ret is unreachable but the
    // compile signature appends it unconditionally).
    try testing.expectEqual(@as(usize, 3), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[0].opcode);
    try testing.expectEqual(Opcode.op_throw, chunk.instructions[1].opcode);
    try testing.expectEqual(Opcode.op_ret, chunk.instructions[2].opcode);
}

test "compile do pops intermediate forms and keeps the last" {
    var f = Fixture.init(testing.allocator);
    defer f.deinit();

    const forms = [_]Node{
        .{ .constant = .{ .value = Value.true_val } },
        .{ .constant = .{ .value = Value.false_val } },
        .{ .constant = .{ .value = Value.nil_val } },
    };
    const node: Node = .{ .do_node = .{ .forms = &forms } };
    const chunk = try f.compile(&node);

    // Pre-ADR-0047 raw shape: `op_const 0; op_pop; op_const 1;
    // op_pop; op_const 2; op_ret` (6 instructions). compileDo still
    // emits a pop after each non-final form — but peephole then elides
    // every `op_const X; op_pop` pair as a pure-push + discard. The
    // final-form const + op_ret survive. Constants pool is untouched
    // (peephole only rewrites instructions; orphan-constant pruning is
    // a future pass) so all 3 constants stay.
    try testing.expectEqual(@as(usize, 2), chunk.instructions.len);
    try testing.expectEqual(Opcode.op_const, chunk.instructions[0].opcode);
    try testing.expectEqual(@as(u16, 2), chunk.instructions[0].operand);
    try testing.expectEqual(Opcode.op_ret, chunk.instructions[1].opcode);
    try testing.expectEqual(@as(usize, 3), chunk.constants.len);
}
