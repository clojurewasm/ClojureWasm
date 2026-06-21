// SPDX-License-Identifier: EPL-2.0
//! cljw wasm engine wrapper — embeds zwasm v2 (F-001 / ADR-0099). Holds a
//! loaded module's `Engine` + `Module` + `Instance` triple so a cljw
//! `(wasm/load …)` produces a single live handle. Compiled ONLY under `-Dwasm`.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: wasm/load, wasm/call
//!
//! zwasm ownership (zwasm-from-scratch branch): `Engine` owns the c-api
//! `*Store`; `Module`/`Instance` hold pointer-VALUE copies of `c_store` (not
//! self-referential into each other's storage), so the triple is heap-boxable
//! and movable — only deinit order (instance→module→engine) and "engine
//! outlives instance" matter.
//!
//! Phase-16 split alignment (ADR-0099, Alt-2): the public fn shapes
//! (`load`/`invoke`/`exportSig`) match the structure_plan module/instance
//! split, so Phase-16 separating module.zig/instance.zig out is *addition, not
//! extraction*. F-006 seam: `load` takes the allocator as a NAMED parameter
//! (the cw-GC-allocator inject point), never an inline global grab.
const std = @import("std");
const zwasm = @import("zwasm");

pub const Value = zwasm.Value;
pub const FuncType = zwasm.ir.zir.FuncType;
pub const ValType = zwasm.ir.zir.ValType;

/// Per-axis runtime budget for a loaded module (re-exported from zwasm's
/// `Module.Budget`, ADR-0179). `.unmetered` lifts the cap (trusted modules
/// only); `.{ .limited = n }` caps it. cljw's `load` defaults each axis to
/// zwasm's finite default (fuel 1e9 / 4096 pages = 256 MiB), so an untrusted
/// module is bounded out of the box (SE-1 / ZE-1) — the caller opts INTO a
/// larger budget or `.unmetered`, never the reverse.
pub const Budget = zwasm.Module.Budget;

/// Per-instance engine selection (ADR-0200), re-exported from zwasm's
/// `InstantiateOpts.engine` field type so cljw never names zwasm's internal
/// `_api_instance` path. `.auto` = JIT-first with transparent interp fallback
/// (observably identical to interp; falls back before any side effect when the
/// JIT cannot build the module); `.jit` = force JIT (hard fail on an unsupported
/// module, no downgrade); `.interp` = force the interpreter. SIMD (v128) bodies
/// execute on the JIT under `.auto`/`.jit`; only v128 AT the host-call boundary
/// is the niche gap that still routes to interp (zwasm to_cljw_02, D-477 tail).
pub const EngineKind = @FieldType(zwasm.Module.InstantiateOpts, "engine");

/// Optional load-time budget overrides; each axis defaults to zwasm's finite
/// default when left null. `engine` is the per-instance engine selection.
///
/// Explicit `:engine :jit` works end-to-end (incl. `wasm/call`, which reads
/// `instance.exportFuncSig` — zwasm shipped the JIT arm of that accessor
/// @5b6449779, from_cljw_02 / to_cljw_03). The finished form (ROADMAP §9.0 gap
/// II×III) is a `.auto` default that transparently rides the JIT. cljw pins the
/// default to `.interp` for now because zwasm REVERTED its `.auto`→JIT flip
/// (to_cljw_03: the C-ABI invoke/export surface is not yet JIT-complete on all 3
/// hosts), so `.auto` currently resolves to interp anyway — there is no JIT
/// default to ride yet. Flip the default to `.auto` when D-488 closes (zwasm
/// re-lands `.auto`→JIT after its C-surface is complete; their D-478).
pub const LoadOpts = struct {
    fuel: ?Budget = null,
    max_memory_pages: ?Budget = null,
    // PROVISIONAL: default .interp until zwasm re-lands .auto→JIT (C-surface complete) [refs: D-488, feature_deps.yaml#runtime/cljw/wasm/engine_default]
    engine: EngineKind = .interp,
};

/// A loaded wasm module instance + its owning engine/module, boxed together so
/// the cross-pointers (Module/Instance borrow Engine's `*Store`) stay valid.
pub const Loaded = struct {
    engine: zwasm.Engine,
    module: zwasm.Module,
    instance: zwasm.Instance,

    /// Runtime signature of an exported function (`null` if absent / not a
    /// func). Drives the marshal: caller sizes its `[]Value` buffers from
    /// `sig.params` / `sig.results`.
    pub fn exportSig(self: *Loaded, name: []const u8) ?FuncType {
        return self.instance.exportFuncSig(name);
    }

    /// Invoke an export by name on caller-allocated arg/result slices.
    pub fn invoke(self: *Loaded, name: []const u8, args: []const Value, results: []Value) !void {
        return self.instance.invoke(name, args, results);
    }

    /// Free the zwasm triple (instance→module→engine). Does NOT free the box
    /// itself — the caller frees the `*Loaded` box. Called by the `.wasm_module`
    /// GC finaliser (`wasm_handle.finaliseGc`), which then frees the box back to
    /// `gc.infra`; so a swept `(wasm/load …)` handle no longer leaks (D-259 (b)).
    pub fn deinit(self: *Loaded) void {
        self.instance.deinit();
        self.module.deinit();
        self.engine.deinit();
    }
};

/// One preopened host directory mapped into the WASI guest's preopen table.
pub const PreopenDir = zwasm.cli.run.PreopenDir;

/// Options for `run` (the WASI command path). `argv` is forwarded verbatim
/// (argv[0] is the program name by convention); `stdin` feeds the guest's fd 0;
/// `preopens` maps host directories into the guest's preopen table (host paths
/// are expected FS-jail resolved by the caller); `env_keys`/`env_vals` are the
/// parallel environment pairs.
pub const RunOpts = struct {
    argv: []const []const u8 = &.{},
    stdin: ?[]const u8 = null,
    preopens: []const PreopenDir = &.{},
    env_keys: []const []const u8 = &.{},
    env_vals: []const []const u8 = &.{},
};

/// Captured result of a WASI command run. `out`/`err` are owned by the caller's
/// allocator (the surface copies them into GC strings, then frees them).
pub const RunResult = struct {
    out: []u8,
    err: []u8,
    exit: u8,
};

/// Compile + instantiate-with-WASI + run the guest's command entry
/// (`_start` → `main` → first export), capturing stdout/stderr and the exit
/// code. Mirrors zwasm's own CLI runner (`zwasm.cli.run.runWasmCapturedFull`)
/// — the C-API WASI path, the only one that captures output today. A non-zero
/// `exit` (incl. a trap → 1) is returned as data, not raised; only a
/// load/instantiate/preopen failure returns a Zig error. F-006: `alloc` is the
/// layer-1 backing allocator (the cljw GC heap is never handed to zwasm).
pub fn run(alloc: std.mem.Allocator, io: std.Io, bytes: []const u8, opts: RunOpts) !RunResult {
    var out_list: std.ArrayList(u8) = .empty;
    errdefer out_list.deinit(alloc);
    var err_list: std.ArrayList(u8) = .empty;
    errdefer err_list.deinit(alloc);

    // NOTE: zwasm's C-API WASI run path does not thread fuel/max-memory budgets
    // (unlike `wasm/load`), so a wasm/run module is currently unmetered — bounded
    // by the OS sandbox (wall-clock + ulimit) in the playground. Threading
    // budgets through the C-API run path is a tracked zwasm gap (D-347).
    const exit = try zwasm.cli.run.runWasmCapturedFull(
        alloc,
        io,
        bytes,
        opts.argv,
        &out_list,
        &err_list,
        opts.stdin,
        null, // invoke_name → _start / main / first export
        opts.preopens,
        opts.env_keys,
        opts.env_vals,
        null, // invoke_args
        .{}, // limits — zwasm-HEAD Limits param (D-347 budget seam); defaults for now
    );

    return .{
        .out = try out_list.toOwnedSlice(alloc),
        .err = try err_list.toOwnedSlice(alloc),
        .exit = exit,
    };
}

/// Compile + instantiate `bytes` into a fresh `*Loaded`, boxed on `alloc`
/// (the F-006 seam — pass cljw's layer-1 backing allocator, NOT the moving GC
/// heap; zwasm keeps its linear memory + bookkeeping in this separate space).
/// `opts` caps the module's runtime budget; a null axis uses zwasm's finite
/// default (so an untrusted module is bounded by default — SE-1 / ZE-1). Caller
/// owns the returned box.
pub fn load(alloc: std.mem.Allocator, bytes: []const u8, opts: LoadOpts) !*Loaded {
    const self = try alloc.create(Loaded);
    errdefer alloc.destroy(self);

    self.engine = try zwasm.Engine.init(alloc, .{});
    errdefer self.engine.deinit();
    self.module = try self.engine.compile(bytes);
    errdefer self.module.deinit();
    // Build zwasm InstantiateOpts: a null cljw axis leaves zwasm's struct default
    // (finite) in place; a provided axis overrides it.
    var inst_opts: zwasm.Module.InstantiateOpts = .{};
    if (opts.fuel) |b| inst_opts.fuel = b;
    if (opts.max_memory_pages) |b| inst_opts.max_memory_pages = b;
    inst_opts.engine = opts.engine;
    self.instance = try self.module.instantiate(inst_opts);
    return self;
}

// (module
//   (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add)
//   (func (export "lane0") (result i32)
//     (i32x4.extract_lane 0 (v128.const i32x4 42 0 0 0))))
// A multi-arg GPR export + a SIMD-body (v128) export whose result crosses the
// scalar boundary — the canonical "SIMD executes on the JIT" shape (zwasm
// examples/zig_host/jit_engine.zig). Used by the dual-engine diff-oracle test.
const dual_engine_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x0b, 0x02, 0x60, 0x02, 0x7f, 0x7f, 0x01,
    0x7f, 0x60, 0x00, 0x01, 0x7f, 0x03, 0x03, 0x02,
    0x00, 0x01, 0x07, 0x0f, 0x02, 0x03, 0x61, 0x64,
    0x64, 0x00, 0x00, 0x05, 0x6c, 0x61, 0x6e, 0x65,
    0x30, 0x00, 0x01, 0x0a, 0x21, 0x02, 0x07, 0x00,
    0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b, 0x17, 0x00,
    0xfd, 0x0c, 0x2a, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0xfd, 0x1b, 0x00, 0x0b,
};

fn invokeAdd(loaded: *Loaded, a: i32, b: i32) !i32 {
    var in = [_]Value{ Value.fromI32(a), Value.fromI32(b) };
    var out = [_]Value{Value.fromI32(0)};
    try loaded.invoke("add", &in, &out);
    return out[0].i32;
}

fn invokeLane0(loaded: *Loaded) !i32 {
    var out = [_]Value{Value.fromI32(0)};
    try loaded.invoke("lane0", &.{}, &out);
    return out[0].i32;
}

test "dual-engine: jit==interp on GPR export; SIMD (v128) is JIT-only in zwasm" {
    const alloc = std.testing.allocator;

    const interp = try load(alloc, &dual_engine_wasm, .{ .engine = .interp });
    defer {
        interp.deinit();
        alloc.destroy(interp);
    }
    const jit = try load(alloc, &dual_engine_wasm, .{ .engine = .jit });
    defer {
        jit.deinit();
        alloc.destroy(jit);
    }

    // GPR multi-arg export: byte-identical on both engines — the F-012 differential
    // discipline applied to engine choice (ADR-0200 adoption / north-star gap II×III).
    try std.testing.expectEqual(@as(i32, 5), try invokeAdd(interp, 2, 3));
    try std.testing.expectEqual(@as(i32, 5), try invokeAdd(jit, 2, 3));

    // SIMD (v128) body executes JIT-compiled and crosses the scalar boundary → 42.
    try std.testing.expectEqual(@as(i32, 42), try invokeLane0(jit));

    // zwasm's interpreter has no v128 dispatch handler (interp/dispatch.zig only
    // registers scalar opcodes), so the same SIMD body traps Unreachable on
    // .interp — SIMD is JIT-only in the pinned zwasm. Lock the gap: if zwasm later
    // wires interp SIMD this flips and forces a conscious update (and the dual-engine
    // diff oracle can then cover SIMD too). Reported upstream via from_cljw_02.
    if (invokeLane0(interp)) |_| {
        return error.TestExpectedSimdTrapOnInterp;
    } else |_| {
        // Expected: SIMD is JIT-only in zwasm (interp has no v128 dispatch
        // handler), confirmed intentional via to_cljw_03 — the interp body traps.
    }
}

// (module
//   (func (export "addf") (param f64 f64) (result f64) local.get 0 local.get 1 f64.add)
//   (func (export "divmod") (param i32 i32) (result i32 i32)
//     local.get 0 local.get 1 i32.div_s  local.get 0 local.get 1 i32.rem_s))
// An f64 FP-bank param/result export + a multi-value (>1 scalar result) export —
// the two invoke shapes the to_cljw_02 matrix lists as JIT-supported beyond GPR.
// Built with `wasm-tools parse` (see test/e2e/fixtures/wasm/jit_shapes.wasm).
const f64_multivalue_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x0e, 0x02, 0x60, 0x02, 0x7c, 0x7c, 0x01,
    0x7c, 0x60, 0x02, 0x7f, 0x7f, 0x02, 0x7f, 0x7f,
    0x03, 0x03, 0x02, 0x00, 0x01, 0x07, 0x11, 0x02,
    0x04, 0x61, 0x64, 0x64, 0x66, 0x00, 0x00, 0x06,
    0x64, 0x69, 0x76, 0x6d, 0x6f, 0x64, 0x00, 0x01,
    0x0a, 0x16, 0x02, 0x07, 0x00, 0x20, 0x00, 0x20,
    0x01, 0xa0, 0x0b, 0x0c, 0x00, 0x20, 0x00, 0x20,
    0x01, 0x6d, 0x20, 0x00, 0x20, 0x01, 0x6f, 0x0b,
};

fn invokeAddF(loaded: *Loaded, a: f64, b: f64) !f64 {
    var in = [_]Value{ Value.fromF64Bits(@bitCast(a)), Value.fromF64Bits(@bitCast(b)) };
    var out = [_]Value{Value.fromF64Bits(0)};
    try loaded.invoke("addf", &in, &out);
    return @bitCast(out[0].f64);
}

fn invokeDivmod(loaded: *Loaded, a: i32, b: i32) ![2]i32 {
    var in = [_]Value{ Value.fromI32(a), Value.fromI32(b) };
    var out = [_]Value{ Value.fromI32(0), Value.fromI32(0) };
    try loaded.invoke("divmod", &in, &out);
    return .{ out[0].i32, out[1].i32 };
}

test "dual-engine: multi-value + 2-arg f64 FP-bank agree jit==interp" {
    const alloc = std.testing.allocator;

    const interp = try load(alloc, &f64_multivalue_wasm, .{ .engine = .interp });
    defer {
        interp.deinit();
        alloc.destroy(interp);
    }
    const jit = try load(alloc, &f64_multivalue_wasm, .{ .engine = .jit });
    defer {
        jit.deinit();
        alloc.destroy(jit);
    }

    // Multi-value (>1 scalar result) — (quotient, remainder), caller-pre-sized out[].
    // Byte-identical across engines (all-i32 GPR → both interp and JIT handle it).
    try std.testing.expectEqual([2]i32{ 3, 2 }, try invokeDivmod(interp, 17, 5));
    try std.testing.expectEqual([2]i32{ 3, 2 }, try invokeDivmod(jit, 17, 5));

    // 2-arg f64 FP-bank param/result: byte-identical across engines. zwasm @d7da97e04
    // fixed the 2-arg×FP-bank JIT dispatch — the 7 FP entry keys were absent in
    // `dispatchScalar2`, narrowed via the from_cljw_03 arity×FP repro table. (Wider :jit
    // gaps remain — multi-result-with-FP, 3+-arg FP shapes, v128 boundary — per
    // to_cljw_04; not exercised here.)
    try std.testing.expectEqual(@as(f64, 3.75), try invokeAddF(interp, 1.5, 2.25));
    try std.testing.expectEqual(@as(f64, 3.75), try invokeAddF(jit, 1.5, 2.25));
}
