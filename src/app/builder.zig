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
//! F-009 note: the install-resolver + primitives + macros + loadCore
//! chain lives in one neutral home, `bootstrap.setupCore`, shared by the
//! runner, `buildFile`, and the embedded-run startup. `buildEnvelope`
//! takes already-bootstrapped state as parameters rather than re-deriving
//! it; `buildFile` / `tryRunEmbedded` derive it via `setupCore`.

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
const vm = @import("../eval/backend/vm.zig");
const bootstrap = @import("../lang/bootstrap.zig");
const require_resolver = @import("../lang/require_resolver.zig");
const run_mode = @import("deps/run_mode.zig");

/// Accumulates the require-closure's compiled chunks during the build-time
/// load (ADR-0034 amendment 3 A3-D2). Installed on `rt.build_chunk_sink` so
/// `loader.loadNamespace` feeds each filesystem lib form's chunk here, in
/// post-order. The pushed `BytecodeChunk` copies hold slices into
/// `rt.load_arena`, alive until the payload is serialized.
const ClosureAccum = struct {
    allocator: std.mem.Allocator,
    chunks: std.ArrayList(BytecodeChunk),

    /// `chunk_ptr` is a `*const BytecodeChunk` type-erased by the Layer-0 sink.
    fn push(ctx: *anyopaque, chunk_ptr: *const anyopaque) anyerror!void {
        const self: *ClosureAccum = @ptrCast(@alignCast(ctx));
        const chunk: *const BytecodeChunk = @ptrCast(@alignCast(chunk_ptr));
        try self.chunks.append(self.allocator, chunk.*);
    }
};

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
    // ADR-0034 am3 A3-D2: capture the require-closure's chunks during the
    // entry forms' eval. `loader.loadNamespace` pushes each filesystem lib
    // form's chunk here (post-order) when this sink is set.
    var closure = ClosureAccum{ .allocator = allocator, .chunks = .empty };
    defer closure.chunks.deinit(allocator);
    rt.build_chunk_sink = .{ .ctx = &closure, .push = ClosureAccum.push };
    defer rt.build_chunk_sink = null;

    var entry_chunks: std.ArrayList(BytecodeChunk) = .empty;
    defer entry_chunks.deinit(allocator);

    // A1-D2 (ADR-0034 am1, Alt B): compile-THEN-eval each top-level form.
    // The eval step evolves `env` (macros / requires / defs register) so
    // form N+1 analyses against the same state Clojure AOT would see; a
    // top-level side effect (e.g. `(println …)`) runs at build time, as
    // documented in `cljw build` help. Compile produces the payload chunk;
    // eval (tree_walk via the installed vtable) only mutates env — and, for a
    // `(require …)`, triggers the closure capture via the sink above.
    var locals: [driver.MAX_LOCALS]Value = [_]Value{.nil_val} ** driver.MAX_LOCALS;
    var reader = Reader.init(arena, source_text);
    while (true) {
        const form = (try reader.read()) orelse break;
        const node = try analyzeForm(arena, rt, env, null, form, macro_table);
        const chunk = try vm_compiler.compile(rt, arena, node);
        try entry_chunks.append(allocator, chunk);
        _ = try driver.evalForm(rt, env, &locals, arena, node);
    }

    // A3-D5: payload = [closure chunks, post-order] ++ [entry chunks]. At run
    // time the closure chunks define the user nses first, so the entry's
    // `(require …)` chunk sees them loaded (op_require idempotency, A3-D1) and
    // skips the resolver the embedded binary does not carry. Script mode → no
    // entry manifest (the chunks ARE the program, run top-to-bottom).
    var all: std.ArrayList(BytecodeChunk) = .empty;
    defer all.deinit(allocator);
    try all.appendSlice(allocator, closure.chunks.items);
    try all.appendSlice(allocator, entry_chunks.items);
    return serialize.serializeEnvelope(allocator, all.items, null);
}

/// AOT-compile the WHOLE eager bootstrap (`bootstrap.FILES` — clojure.core +
/// the 23 non-core bundled `.clj` libs) to one bytecode envelope, mirroring
/// `bootstrap.loadCoreFiles`'s per-file read→analyze→compile→eval loop but
/// CAPTURING each form's compiled chunk (D-452 Part B / ADR-0056 Cycle 3). The
/// load path (`bootstrap.loadCoreAot`) runs this via `driver.runEnvelope`
/// instead of re-parsing the non-core libs from source on every startup
/// (~2.9 ms across all benches). Eval order is identical to `loadCoreFiles`,
/// so intra-bootstrap requires stay idempotent (a dep file is always eval'd
/// before its dependent) and no filesystem resolver / closure-sink is needed.
///
/// `rt`/`env`/`macro_table` must be in the prefix-only state
/// (`setupCorePrefix`, no `loadCore`) — this function evals core FIRST, so a
/// pre-`loadCore` env is required (a double-load would re-register). The
/// compiled chunks' slices live in `arena`; `serializeEnvelope` copies the
/// bytes, so the caller's arena owns them.
pub fn buildBootstrapEnvelope(
    allocator: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    macro_table: *macro_dispatch.Table,
    arena: std.mem.Allocator,
    files: []const bootstrap.FileEntry,
) ![]u8 {
    var chunks: std.ArrayList(BytecodeChunk) = .empty;
    defer chunks.deinit(allocator);
    var locals: [driver.MAX_LOCALS]Value = [_]Value{.nil_val} ** driver.MAX_LOCALS;
    for (files) |file| {
        // Register the file's bytes so a build-time error frame keeps its
        // per-file SourceContext (mirror of loadCoreFiles; idempotent).
        try rt.registerSource(file.label, file.source);
        var reader = Reader.init(arena, file.source);
        while (true) {
            const form = (try reader.read()) orelse break;
            const node = try analyzeForm(arena, rt, env, null, form, macro_table);
            const chunk = try vm_compiler.compile(rt, arena, node);
            try chunks.append(allocator, chunk);
            // Eval so later forms / files see earlier defs/macros/in-ns/requires
            // (A1-D2 Clojure-AOT — identical state evolution to loadCoreFiles).
            _ = try driver.evalForm(rt, env, &locals, arena, node);
        }
    }
    return serialize.serializeEnvelope(allocator, chunks.items, null);
}

/// `cljw build -m <ns>` (ADR-0034 amendment 4 A4-D1/D2). Build-time eval of
/// `(require '[<ns>])` captures the require closure (via the am3 sink) +
/// registers `<ns>`'s defns — but `-main` is DEFINED, never CALLED at build, so
/// a server-starting `-main` does not hang the build. The payload carries the
/// closure chunks + an entry manifest `{ ns, args }`; at run, `tryRunEmbedded`
/// invokes `(<ns>/-main …)` via the shared `synthMainNs` (A4-D3). No entry
/// chunk is embedded — the entry is artifact metadata, not code.
pub fn buildMainEnvelope(
    allocator: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    macro_table: *macro_dispatch.Table,
    arena: std.mem.Allocator,
    ns: []const u8,
    args: []const []const u8,
) ![]u8 {
    var closure = ClosureAccum{ .allocator = allocator, .chunks = .empty };
    defer closure.chunks.deinit(allocator);
    rt.build_chunk_sink = .{ .ctx = &closure, .push = ClosureAccum.push };
    defer rt.build_chunk_sink = null;

    // Eval `(require '[<ns>])` → the am3 sink captures the closure (incl. <ns>
    // itself) in post-order; the require itself is build-only (its chunk is not
    // embedded — the closure chunks define <ns>, and the run-side synthMainNs
    // re-requires idempotently).
    const req_src = try std.fmt.allocPrint(arena, "(clojure.core/require (quote [{s}]))", .{ns});
    var locals: [driver.MAX_LOCALS]Value = [_]Value{.nil_val} ** driver.MAX_LOCALS;
    var reader = Reader.init(arena, req_src);
    const form = (try reader.read()) orelse return error.EmptyRequireForm;
    const node = try analyzeForm(arena, rt, env, null, form, macro_table);
    _ = try driver.evalForm(rt, env, &locals, arena, node);

    return serialize.serializeEnvelope(allocator, closure.chunks.items, .{ .ns = ns, .args = args });
}

// === cljw build CLI core + embedded-run startup ===

/// Read an entire file into a freshly `gpa`-allocated slice (caller frees).
fn readFileAll(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var fr = f.reader(io, &buf);
    return fr.interface.allocRemaining(gpa, .unlimited);
}

/// Read the running executable's own bytes (the runtime binary
/// `frameArtifact` prepends to the payload). `openSelfExe` does not exist in
/// Zig 0.16 — resolve the path via `std.process.executablePathAlloc`.
fn readSelfExe(io: std.Io, gpa: std.mem.Allocator) ![]u8 {
    const path = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(path);
    return readFileAll(io, gpa, path);
}

/// What to build: a script (the entry file's top-level forms ARE the program)
/// or a `-m` main entry (require the closure, invoke `(<ns>/-main …)` at run).
const BuildSpec = union(enum) {
    script: []const u8, // entry source text
    main: struct { ns: []const u8, args: []const []const u8 },
};

/// Shared build driver: bootstrap a runtime + classpath, produce the payload
/// per `spec`, and append it to a copy of the running cljw binary as a
/// self-contained `"CLJC"`-trailered executable. `buildFile` / `buildMainFile`
/// are the two thin entry points (F-009/F-011 — one setup, one write tail).
fn buildArtifact(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, out_path: []const u8, load_paths: []const []const u8, spec: BuildSpec) !void {
    var rt = Runtime.init(io, gpa);
    defer rt.deinit();
    var env = try Env.init(&rt);
    defer env.deinit();
    driver.installVTable(&rt);
    var macro_table = macro_dispatch.Table.init(gpa);
    defer macro_table.deinit();
    try bootstrap.setupCore(arena, &rt, &env, &macro_table);
    // ADR-0034 am3 A3-D4: enable filesystem `require` so a build-time
    // `(require '[lib])` resolves off the classpath (mirrors runner.zig). Set
    // AFTER setupCore — it installs the embedded-ONLY resolver at bootstrap, so
    // an earlier installChained would be overwritten.
    rt.load_paths = load_paths;
    require_resolver.installChained(&rt);

    const payload = switch (spec) {
        .script => |src| try buildEnvelope(gpa, &rt, &env, &macro_table, arena, src),
        .main => |m| try buildMainEnvelope(gpa, &rt, &env, &macro_table, arena, m.ns, m.args),
    };
    defer gpa.free(payload);

    const self_bytes = try readSelfExe(io, gpa);
    defer gpa.free(self_bytes);

    const artifact = try serialize.frameArtifact(gpa, self_bytes, payload);
    defer gpa.free(artifact);

    const out = try std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true, .permissions = .executable_file });
    defer out.close(io);
    var wbuf: [4096]u8 = undefined;
    var ow = out.writer(io, &wbuf);
    try ow.interface.writeAll(artifact);
    try ow.interface.flush();
}

/// `cljw build <in.clj> -o <out>` (script mode): compile the source to a
/// payload envelope and append it to a copy of the running cljw binary as a
/// self-contained artifact with a `"CLJC"` trailer (ADR-0034 amendment 1/2).
/// Build-time eval runs top-level side effects (A1-D2). The output is executable.
pub fn buildFile(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, in_path: []const u8, out_path: []const u8, load_paths: []const []const u8) !void {
    const source = try readFileAll(io, gpa, in_path);
    defer gpa.free(source);
    return buildArtifact(io, gpa, arena, out_path, load_paths, .{ .script = source });
}

/// `cljw build -m <ns> [args…] -o <out>` (main mode, ADR-0034 am4): embed the
/// require closure for `<ns>` + an entry manifest; the produced binary invokes
/// `(<ns>/-main args)` at run, NOT at build (so a server `-main` does not hang
/// the build).
pub fn buildMainFile(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, ns: []const u8, args: []const []const u8, out_path: []const u8, load_paths: []const []const u8) !void {
    return buildArtifact(io, gpa, arena, out_path, load_paths, .{ .main = .{ .ns = ns, .args = args } });
}

/// Startup hook: if the running binary carries an embedded payload trailer,
/// deserialize + run it on the VM and return true; otherwise return false so
/// normal CLI dispatch proceeds. Per-chunk INTERLEAVED deserialize+run (a
/// later chunk's var_ref to an earlier chunk's def needs that def to have
/// RUN); chunks live in `arena` for the whole run (a fn def'd in one chunk
/// may be called in a later one), bulk-freed by the caller's arena. The
/// payload's own `(println …)` etc. write straight to process stdout via
/// `rt.io`, so no writer is threaded here.
pub fn tryRunEmbedded(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, stdout: *std.Io.Writer, main_args: []const []const u8) !bool {
    // D-140: reads the whole self-exe to check the tail; a footer-only seek
    // would avoid the full read on every normal startup.
    const self_bytes = try readSelfExe(io, gpa);
    defer gpa.free(self_bytes);
    const payload = serialize.extractPayload(self_bytes) orelse return false;

    var rt = Runtime.init(io, gpa);
    defer rt.deinit();
    // Route every println/print/prn through the ONE process-shared, offset-
    // tracking stdout writer (D-096). Without this, rt.stdout stays null and the
    // print primitive falls back to a fresh per-call writer whose file offset
    // restarts at 0 each time, so successive lines overwrite each other (the
    // built-binary stdout-corruption bug). Mirrors runner.zig's setup + flush.
    rt.stdout = stdout;
    var env = try Env.init(&rt);
    defer env.deinit();
    vm.installVTable(&rt); // wires evalChunk so deserialized fns run on the VM
    var macro_table = macro_dispatch.Table.init(gpa);
    defer macro_table.deinit();
    // ADR-0056 Cycle 2c: a built app also AOT-restores clojure.core (it no
    // longer re-parses+evals core.clj at startup), then runs the embedded
    // user payload — advancing the D-131 built-app re-bootstrap gap.
    try bootstrap.setupCoreAot(arena, &rt, &env, &macro_table, @import("bootstrap_cache").data);

    try driver.runEnvelope(&rt, &env, arena, payload);

    // ADR-0034 am4 A4-D3: main mode. The payload's entry manifest (if any)
    // names `<ns>` whose `-main` is the entry point; the closure chunks just
    // ran, so `<ns>` is defined. Invoke `(<ns>/-main args)` via the SAME
    // `run_mode.synthMainNs` `cljw -M -m` uses (F-011), with args = the baked
    // build-time args UNLESS the binary got its own runtime argv (`./out 8080`),
    // which overrides. `requiring-resolve` is idempotent (ns already loaded).
    if (try serialize.readEnvelopeEntry(arena, payload)) |entry| {
        const all_args = if (main_args.len > 0) main_args else entry.args;
        const src = try run_mode.synthMainNs(arena, entry.ns, all_args);
        var reader = Reader.init(arena, src);
        var locals: [driver.MAX_LOCALS]Value = [_]Value{.nil_val} ** driver.MAX_LOCALS;
        while (try reader.read()) |form| {
            const node = try analyzeForm(arena, &rt, &env, null, form, &macro_table);
            _ = try driver.evalForm(&rt, &env, &locals, arena, node);
        }
    }

    try stdout.flush();
    return true;
}

// --- tests ---

const testing = std.testing;
const tree_walk = @import("../eval/backend/tree_walk.zig");

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
    var macro_table = macro_dispatch.Table.init(testing.allocator);
    defer macro_table.deinit();
    try bootstrap.setupCore(arena, &rt, &env, &macro_table);

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
    var macro_table = macro_dispatch.Table.init(testing.allocator);
    defer macro_table.deinit();
    try bootstrap.setupCore(arena, &rt, &env, &macro_table);

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

test "aot: core.clj round-trips — build envelope, restore into a fresh env, run a core.clj fn (ADR-0056 Cycle 1)" {
    const A = testing.allocator;

    // --- Build phase: compile core.clj to a bytecode envelope under a
    //     prefix-only env (primitives + macros, NO loadCore). The chunks
    //     are self-contained (serializeEnvelope copies the bytes), so they
    //     outlive this scope's arena/env. ---
    var core_bytes: []u8 = undefined;
    {
        var th = std.Io.Threaded.init(A, .{});
        defer th.deinit();
        var rt = Runtime.init(th.io(), A);
        defer rt.deinit();
        var env = try Env.init(&rt);
        defer env.deinit();
        var arena_state = std.heap.ArenaAllocator.init(A);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        driver.installVTable(&rt);
        var table = macro_dispatch.Table.init(A);
        defer table.deinit();
        try bootstrap.setupCorePrefix(&rt, &env, &table);
        core_bytes = try buildEnvelope(A, &rt, &env, &table, arena, bootstrap.CORE_SOURCE);
    }
    defer A.free(core_bytes);

    // --- Restore phase: a FRESH env gets clojure.core from the bytecode
    //     envelope via driver.runEnvelope — no parse/analyze/eval of .clj
    //     source. ---
    var th = std.Io.Threaded.init(A, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), A);
    defer rt.deinit();
    var env = try Env.init(&rt);
    defer env.deinit();
    var arena_state = std.heap.ArenaAllocator.init(A);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    driver.installVTable(&rt); // tree_walk vtable + Cycle-0 evalChunk
    var table = macro_dispatch.Table.init(A);
    defer table.deinit();
    try bootstrap.setupCorePrefix(&rt, &env, &table);
    try driver.runEnvelope(&rt, &env, arena, core_bytes);

    // --- Verify: `comp` is core.clj-defined (NOT a primitive), so its
    //     presence proves the AOT restore ran; the restored fn is bytecode
    //     and dispatches through the tree_walk vtable's evalChunk (Cycle 0).
    var reader = Reader.init(arena, "((comp inc inc inc) 0)");
    const form = (try reader.read()).?;
    const node = try analyzeForm(arena, &rt, &env, null, form, &table);
    var locals: [driver.MAX_LOCALS]Value = [_]Value{.nil_val} ** driver.MAX_LOCALS;
    const result = try driver.evalForm(&rt, &env, &locals, arena, node);
    try testing.expectEqual(@as(i64, 3), result.asInteger());
}

test "aot: full bootstrap round-trips — a NON-core lib restores from bytecode (D-452 Part B)" {
    // buildBootstrapEnvelope compiles the WHOLE eager bootstrap (core + the 23
    // non-core libs) to one envelope; loadCoreAot runs it instead of re-parsing
    // the non-core .clj from source. This proves the type_descriptor AOT
    // (ADR-0034 am5) unblocked it: clojure.zip + clojure.core.protocols (the
    // descriptor-constant carriers) are in the bootstrap, so a clean build of
    // the envelope is itself the regression gate; here we additionally restore
    // it into a fresh env and run a clojure.string fn (a non-core var that does
    // NOT exist unless the non-core AOT chunks ran).
    const A = testing.allocator;
    var blob: []u8 = undefined;
    {
        var th = std.Io.Threaded.init(A, .{});
        defer th.deinit();
        var rt = Runtime.init(th.io(), A);
        defer rt.deinit();
        var env = try Env.init(&rt);
        defer env.deinit();
        var arena_state = std.heap.ArenaAllocator.init(A);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        driver.installVTable(&rt);
        var table = macro_dispatch.Table.init(A);
        defer table.deinit();
        try bootstrap.setupCorePrefix(&rt, &env, &table);
        blob = try buildBootstrapEnvelope(A, &rt, &env, &table, arena, bootstrap.FILES);
    }
    defer A.free(blob);

    var th = std.Io.Threaded.init(A, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), A);
    defer rt.deinit();
    var env = try Env.init(&rt);
    defer env.deinit();
    var arena_state = std.heap.ArenaAllocator.init(A);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    driver.installVTable(&rt);
    var table = macro_dispatch.Table.init(A);
    defer table.deinit();
    try bootstrap.setupCorePrefix(&rt, &env, &table);
    // The whole eager bootstrap from bytecode (no .clj re-parse) — the loadCoreAot path.
    try driver.runEnvelope(&rt, &env, arena, blob);

    // clojure.string/upper-case is a non-core lib var: present ONLY if the
    // non-core AOT chunks ran. Call it to prove the restored fn dispatches.
    var reader = Reader.init(arena, "(clojure.string/upper-case \"hi\")");
    const form = (try reader.read()).?;
    const node = try analyzeForm(arena, &rt, &env, null, form, &table);
    var locals: [driver.MAX_LOCALS]Value = [_]Value{.nil_val} ** driver.MAX_LOCALS;
    const result = try driver.evalForm(&rt, &env, &locals, arena, node);
    try testing.expectEqualStrings("HI", @import("../runtime/collection/string.zig").asString(result));
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
    var macro_table = macro_dispatch.Table.init(testing.allocator);
    defer macro_table.deinit();
    try bootstrap.setupCore(arena, &rt, &env, &macro_table);

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
    var macro_table = macro_dispatch.Table.init(testing.allocator);
    defer macro_table.deinit();
    try bootstrap.setupCore(arena, &rt, &env, &macro_table);
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
    var macro_table2 = macro_dispatch.Table.init(testing.allocator);
    defer macro_table2.deinit();
    try bootstrap.setupCore(arena2, &rt2, &env2, &macro_table2);

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
