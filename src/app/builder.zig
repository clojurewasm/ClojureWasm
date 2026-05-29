// SPDX-License-Identifier: EPL-2.0
//! `cljw build` — compile a Clojure source to a serialized bytecode
//! payload envelope (D-100(b), ADR-0034 amendment 1 Alt B). Each
//! top-level form compiles to one `BytecodeChunk`; the chunks are framed
//! by `serialize.serializeEnvelope`. This module is the **compile core**:
//! it turns already-bootstrapped runtime state + source text into the
//! payload bytes. The Deno-style binary trailer (runtime + payload +
//! `"CLJC"` footer) and the `cljw build app.clj -o app` CLI dispatch
//! layer above this in later steps.
//!
//! Backend: surface-only (Layer 3 → eval/runtime impl). Impl deps:
//! serialize, vm/compiler, analyzer. Clojure peer: none.
//!
//! F-009 note: `runner.runSource` already owns the bootstrap chain
//! (Runtime / Env / macro_table / loadCore) and is documented as the
//! shared entry for "the build-runner"; this core takes that state as
//! parameters rather than re-deriving it, so the eventual CLI path wires
//! the same setup once and feeds both run and build.

const std = @import("std");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const Env = @import("../runtime/env.zig").Env;
const Reader = @import("../eval/reader.zig").Reader;
const analyzeForm = @import("../eval/analyzer/analyzer.zig").analyze;
const macro_dispatch = @import("../eval/macro_dispatch.zig");
const vm_compiler = @import("../eval/backend/vm/compiler.zig");
const serialize = @import("../eval/bytecode/serialize.zig");
const BytecodeChunk = @import("../eval/backend/vm/opcode.zig").BytecodeChunk;
const driver = @import("../eval/driver.zig");
const Value = @import("../runtime/value/value.zig").Value;

/// Compile every top-level form in `source_text` to a `BytecodeChunk`
/// and return the serialized payload envelope (caller frees the bytes
/// via `allocator.free`). The runtime / env / macro_table must already
/// be bootstrapped (`loadCore` done) by the caller.
///
/// The compiled chunks' slices are allocated from `arena`
/// (`vm_compiler.compile` uses it), so `serializeEnvelope` copies their
/// bytes and the chunks need no per-chunk free — the caller's arena owns
/// them.
pub fn buildEnvelope(
    allocator: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    macro_table: *macro_dispatch.Table,
    arena: std.mem.Allocator,
    source_text: []const u8,
) ![]u8 {
    var chunks: std.ArrayList(BytecodeChunk) = .empty;
    defer chunks.deinit(allocator);

    // A1-D2 (ADR-0034 am1, Alt B): compile-THEN-eval each top-level form.
    // The eval step evolves `env` (macros / requires / defs register) so
    // form N+1 analyses against the same state Clojure AOT would see; a
    // top-level side effect (e.g. `(println …)`) runs at build time, as
    // documented in `cljw build` help. Compile produces the payload chunk;
    // eval (tree_walk via the installed vtable) only mutates env.
    var locals: [driver.MAX_LOCALS]Value = [_]Value{.nil_val} ** driver.MAX_LOCALS;
    var reader = Reader.init(arena, source_text);
    while (true) {
        const form = (try reader.read()) orelse break;
        const node = try analyzeForm(arena, rt, env, null, form, macro_table);
        const chunk = try vm_compiler.compile(rt, arena, node);
        try chunks.append(allocator, chunk);
        _ = try driver.evalForm(rt, env, &locals, arena, node);
    }
    return serialize.serializeEnvelope(allocator, chunks.items);
}

// --- tests ---

const testing = std.testing;
const primitive = @import("../lang/primitive.zig");
const macro_transforms = @import("../lang/macro_transforms.zig");
const bootstrap = @import("../lang/bootstrap.zig");
const tree_walk = @import("../eval/backend/tree_walk.zig");
const vm = @import("../eval/backend/vm.zig");

test "buildEnvelope compiles two forms into a two-chunk envelope" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try Env.init(&rt);
    defer env.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    driver.installVTable(&rt);
    bootstrap.installEmbeddedResolver(&rt);
    try primitive.registerAll(&env);
    var macro_table = macro_dispatch.Table.init(testing.allocator);
    defer macro_table.deinit();
    try macro_transforms.registerInto(&env, &macro_table);
    try bootstrap.loadCore(arena, &rt, &env, &macro_table);

    const bytes = try buildEnvelope(testing.allocator, &rt, &env, &macro_table, arena, "(+ 1 2) (* 3 4)");
    defer testing.allocator.free(bytes);

    const chunks = try serialize.deserializeEnvelope(testing.allocator, &rt, &env, bytes);
    defer serialize.freeEnvelope(testing.allocator, chunks);

    // Two top-level forms → two chunks, in source order, each with a
    // non-empty instruction stream (the compiler emits at least op_ret).
    try testing.expectEqual(@as(usize, 2), chunks.len);
    try testing.expect(chunks[0].instructions.len > 0);
    try testing.expect(chunks[1].instructions.len > 0);
}

test "buildEnvelope evaluates each form so later forms see earlier env (ADR-0034 A1-D2)" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try Env.init(&rt);
    defer env.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    driver.installVTable(&rt);
    bootstrap.installEmbeddedResolver(&rt);
    try primitive.registerAll(&env);
    var macro_table = macro_dispatch.Table.init(testing.allocator);
    defer macro_table.deinit();
    try macro_transforms.registerInto(&env, &macro_table);
    try bootstrap.loadCore(arena, &rt, &env, &macro_table);

    // Form 2 `(s/union …)` only ANALYSES once form 1's `(require …:as s)`
    // has been EVALUATED — the alias `s` is registered when the
    // `op_require_with_libspec` op RUNS (vm.zig), not at compile time. A
    // compile-only loop leaves `s` unbound and form 2 raises name_error.
    // This proves the A1-D2 eval step while keeping both chunks
    // serializable (libspec table + var_ref + array-set constants; no
    // fn_val). Clojure AOT shape.
    const bytes = try buildEnvelope(testing.allocator, &rt, &env, &macro_table, arena, "(require '[clojure.set :as s]) (s/union #{1} #{2})");
    defer testing.allocator.free(bytes);

    const chunks = try serialize.deserializeEnvelope(testing.allocator, &rt, &env, bytes);
    defer serialize.freeEnvelope(testing.allocator, chunks);

    try testing.expectEqual(@as(usize, 2), chunks.len);
    try testing.expect(chunks[1].instructions.len > 0);
}

test "fn_val constant round-trips through serialize (ADR-0034 am2)" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try Env.init(&rt);
    defer env.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    driver.installVTable(&rt);
    bootstrap.installEmbeddedResolver(&rt);
    try primitive.registerAll(&env);
    var macro_table = macro_dispatch.Table.init(testing.allocator);
    defer macro_table.deinit();
    try macro_transforms.registerInto(&env, &macro_table);
    try bootstrap.loadCore(arena, &rt, &env, &macro_table);

    // `(def add2 (fn* [x] (+ x 2)))` compiles a `fn_val` CONSTANT
    // (op_make_fn's operand). The serializer must round-trip it (ADR-0034
    // amendment 2) — before A2-D1 this raised UnsupportedValueTag, making
    // `cljw build` reject every program with a user function.
    const bytes = try buildEnvelope(testing.allocator, &rt, &env, &macro_table, arena, "(def add2 (fn* [x] (+ x 2)))");
    defer testing.allocator.free(bytes);

    const chunks = try serialize.deserializeEnvelope(testing.allocator, &rt, &env, bytes);
    defer serialize.freeEnvelope(testing.allocator, chunks);

    try testing.expectEqual(@as(usize, 1), chunks.len);
    var found_fn = false;
    for (chunks[0].constants) |c| {
        if (c.tag() == .fn_val) {
            found_fn = true;
            const f = c.decodePtr(*const tree_walk.Function);
            try testing.expectEqual(@as(usize, 1), f.methods.len);
            try testing.expectEqual(@as(u16, 1), f.methods[0].arity);
            try testing.expect(f.closure_bindings == null);
        }
    }
    try testing.expect(found_fn);
}

test "deserialized fn_val executes through the VM (ADR-0034 am2)" {
    // --- Build side: compile a user fn + a call into a payload. ---
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try Env.init(&rt);
    defer env.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    driver.installVTable(&rt);
    bootstrap.installEmbeddedResolver(&rt);
    try primitive.registerAll(&env);
    var macro_table = macro_dispatch.Table.init(testing.allocator);
    defer macro_table.deinit();
    try macro_transforms.registerInto(&env, &macro_table);
    try bootstrap.loadCore(arena, &rt, &env, &macro_table);
    // Two forms: `def` a fn in chunk 1, CALL it in chunk 2. Proves both
    // fn_val execution AND the interleaved startup model — chunk 2's
    // `var_ref` to `add2` only resolves because chunk 1 has already RUN
    // (op_def interned add2). Eager deserialize-all would fail here.
    const bytes = try buildEnvelope(testing.allocator, &rt, &env, &macro_table, arena, "(def add2 (fn* [x] (+ x 2))) (add2 40)");
    defer testing.allocator.free(bytes);

    // --- Run side: a FRESH runtime simulating the built binary's startup
    // (bootstrap, then VM-run the embedded chunks). The `add2` that runs
    // `(add2 40)` is the DESERIALIZED fn_val, not the build-side one. ---
    var th2 = std.Io.Threaded.init(testing.allocator, .{});
    defer th2.deinit();
    var rt2 = Runtime.init(th2.io(), testing.allocator);
    defer rt2.deinit();
    var env2 = try Env.init(&rt2);
    defer env2.deinit();
    var arena2_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2_state.deinit();
    const arena2 = arena2_state.allocator();
    vm.installVTable(&rt2); // wires evalChunk so deserialized fns run on the VM
    bootstrap.installEmbeddedResolver(&rt2);
    try primitive.registerAll(&env2);
    var macro_table2 = macro_dispatch.Table.init(testing.allocator);
    defer macro_table2.deinit();
    try macro_transforms.registerInto(&env2, &macro_table2);
    try bootstrap.loadCore(arena2, &rt2, &env2, &macro_table2);

    // Interleave deserialize + run per chunk into a run-lifetime arena: the
    // chunks (and add2's method sub-chunk) must outlive every chunk's eval
    // (add2 is called in a later chunk), so bulk-free at the end — never
    // per-chunk. The fn_val Function is gpa+trackHeap (freed at rt2.deinit).
    var run_arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer run_arena_state.deinit();
    const run_arena = run_arena_state.allocator();
    var it = try serialize.EnvelopeIterator.init(bytes);
    var locals: [driver.MAX_LOCALS]Value = [_]Value{.nil_val} ** driver.MAX_LOCALS;
    var last: Value = .nil_val;
    while (try it.next()) |chunk_bytes| {
        var chunk = try serialize.deserializeChunk(run_arena, &rt2, &env2, chunk_bytes);
        last = try vm.eval(&rt2, &env2, &locals, &chunk);
    }

    // `(add2 40)` ran the reconstructed function on the VM → 42.
    try testing.expectEqual(@as(i64, 42), last.asInteger());
}
