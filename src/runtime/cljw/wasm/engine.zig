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
pub const Memory = zwasm.Memory;
/// Owned export-descriptor list (zwasm `Module.exports`), ADR-0203.
pub const ModuleExports = @typeInfo(@typeInfo(@TypeOf(zwasm.Module.exports)).@"fn".return_type.?).error_union.payload;

/// Per-axis runtime budget for a loaded module (re-exported from zwasm's
/// `Module.Budget`, ADR-0179). `.unmetered` lifts the cap (trusted modules
/// only); `.{ .limited = n }` caps it. cljw's `load` defaults each axis to
/// zwasm's finite default (fuel 1e9 / 4096 pages = 256 MiB), so an untrusted
/// module is bounded out of the box (SE-1 / ZE-1) — the caller opts INTO a
/// larger budget or `.unmetered`, never the reverse.
pub const Budget = zwasm.Module.Budget;

/// Per-instance engine selection (zwasm ADR-0200), re-exported from zwasm's
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
/// The default is `.auto` — the ROADMAP §9.0 gap II×III north-star: zwasm's
/// JIT-first engine with transparent interp fallback, so a no-opts
/// `(wasm/load path)` rides the JIT and the user automatically gets zwasm's
/// latest codegen. zwasm re-landed its `.auto`→JIT flip in v2.0.0-alpha.3 (its
/// D-478): the x86_64 LSRA dual-spill miscompile (D-489/D-494) that gated it is
/// fixed, 3-host green (to_cljw_09). Components stay interp-pinned on the zwasm
/// side (D-500), so the `.auto` default leaves the component path on interp —
/// no behaviour change there. Explicit `:engine :interp` / `:jit` override
/// per-instance; the F-012 dual-backend diff oracle uses the explicit forms, so
/// the default flip does not touch it. `.jit` hard-fails an unsupported module;
/// `.auto` transparently downgrades it to interp instead.
pub const LoadOpts = struct {
    fuel: ?Budget = null,
    max_memory_pages: ?Budget = null,
    engine: EngineKind = .auto,
};

/// A loaded wasm module instance + its owning engine/module, boxed together so
/// the cross-pointers (Module/Instance borrow Engine's `*Store`) stay valid.
pub const Loaded = struct {
    engine: zwasm.Engine,
    module: zwasm.Module,
    instance: zwasm.Instance,
    /// The engine selection this instance was loaded with (ADR-0196). Under
    /// `.auto` it is the request, not the arm zwasm chose; `wasm/engine`
    /// reports it and the trap diagnostic names it.
    engine_kind: EngineKind,
    /// The allocator the box and its cache live on (`load`'s `alloc`).
    alloc: std.mem.Allocator,
    /// Export name -> resolved signature, filled by `exportSig` on first use.
    /// Keys are owned copies; values are slices into the instance's own
    /// signature storage, valid for the instance's lifetime.
    sig_cache: std.StringHashMapUnmanaged(FuncType),
    /// Export descriptors (name + kind, export order) decoded at `load`, while
    /// the module bytes are still alive: zwasm's native section view borrows
    /// them, so a later `Module.exports` would decode freed memory (ADR-0203).
    export_list: ModuleExports,

    /// Runtime signature of an exported function (`null` if absent / not a
    /// func). Drives the marshal: caller sizes its `[]Value` buffers from
    /// `sig.params` / `sig.results`. Resolved through the instance once per
    /// name, then served from `sig_cache` (the JIT arm of `exportFuncSig`
    /// re-parses the module per call otherwise).
    pub fn exportSig(self: *Loaded, name: []const u8) ?FuncType {
        if (self.sig_cache.get(name)) |sig| return sig;
        const sig = self.instance.exportFuncSig(name) orelse return null;
        // The caller's `name` is a GC string; the key must outlive it. An
        // allocation failure only means the next call resolves again.
        const key = self.alloc.dupe(u8, name) catch return sig;
        self.sig_cache.put(self.alloc, key, sig) catch {
            self.alloc.free(key);
        };
        return sig;
    }

    /// Invoke an export by name on caller-allocated arg/result slices.
    pub fn invoke(self: *Loaded, name: []const u8, args: []const Value, results: []Value) !void {
        return self.instance.invoke(name, args, results);
    }

    /// The module's exported linear memory, `null` when it exports none
    /// (ADR-0192). The returned view borrows the instance's backing store, so
    /// it is valid only while `self` is — the `.wasm_module` handle owns that
    /// lifetime, which is why the cljw surface takes the handle per call
    /// rather than minting a separate memory handle.
    pub fn memory(self: *Loaded) ?Memory {
        return self.instance.memory();
    }

    /// Free the zwasm triple (instance→module→engine). Does NOT free the box
    /// itself — the caller frees the `*Loaded` box. Called by the `.wasm_module`
    /// GC finaliser (`wasm_handle.finaliseGc`), which then frees the box back to
    /// `gc.infra`; so a swept `(wasm/load …)` handle no longer leaks (D-259 (b)).
    pub fn deinit(self: *Loaded) void {
        var keys = self.sig_cache.keyIterator();
        while (keys.next()) |k| self.alloc.free(k.*);
        self.sig_cache.deinit(self.alloc);
        self.export_list.deinit();
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
    /// Runtime budgets, mirroring `LoadOpts` (D-347). A null axis takes the
    /// same finite default `wasm/load` gets, so an untrusted WASI command is
    /// bounded out of the box; `.unmetered` opts a trusted module out.
    fuel: ?Budget = null,
    max_memory_pages: ?Budget = null,
    /// Cap on the captured stdout and stderr, PER stream (D-349). Neither of
    /// the budgets above bounds it: fuel bounds instructions, and how many
    /// bytes an instruction writes is entirely the guest's choice. Measured
    /// before this existed — a guest looping on a 64-byte `fd_write` buffered
    /// 64 MB per 1e6 fuel, i.e. ~64 GB under the default fuel budget.
    max_output_bytes: ?Budget = null,
    /// Wall-clock cap in milliseconds (D-570). The fourth axis, and the one the
    /// other three do not imply: **fuel is a very poor proxy for time.**
    /// Measured on the same 1,000,000 fuel — a host-call-heavy guest took 66 s,
    /// a compute-bound one 0.087 s. A ~760x spread, so the 1e9 default fuel
    /// permits roughly 18 HOURS of wall clock for the first shape.
    timeout_ms: ?Budget = null,
};

/// Default wall-clock cap. Chosen from the measurement above rather than taste:
/// it turns the pathological shape's ~18 hours into one minute, while leaving a
/// legitimate guest ~700x the time the measured one needed. `<= 0` opts out on
/// the same convention as the other three axes.
///
/// The asymmetry decides the value. Too low cuts off a long-but-legitimate
/// guest, which is recoverable — the caller raises `:timeout-ms` and the error
/// says so. Absent, a wedged host process looks like a hang for hours, which is
/// not. So a finite default with a clear error beats opt-in-only, which would
/// have been a knob nothing sets.
pub const default_timeout_ms: u64 = 60_000;

/// Default cap on each captured stream. Generous for the demo / CLI uses
/// `wasm/run` is for (a compiler's diagnostics, a test binary's output) and
/// nowhere near enough to matter as host memory. `:unmetered` opts out.
pub const default_max_output_bytes: u64 = 16 * 1024 * 1024;

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
    return runSource(alloc, io, .{ .bytes = bytes }, opts);
}

/// A WASI command validated + JIT-compiled once (zwasm `PreparedWasi`), for
/// `runPrepared`. Owns a copy of the bytes; `deinit` frees it and the code.
pub const Prepared = zwasm.cli.run_prepared.PreparedWasi;

/// Validate + compile `bytes` for repeated `runPrepared` under the `.auto`
/// engine `run` uses. A module `run` would reject fails here instead.
pub fn prepare(alloc: std.mem.Allocator, bytes: []const u8) !Prepared {
    return Prepared.init(alloc, bytes, .auto);
}

/// `run` against a `Prepared` module: instantiate + run only. Every `opts`
/// field applies per call exactly as in `run`, and the result is the same.
pub fn runPrepared(alloc: std.mem.Allocator, io: std.Io, prepared: *const Prepared, opts: RunOpts) !RunResult {
    return runSource(alloc, io, .{ .prepared = prepared }, opts);
}

const RunSource = union(enum) {
    bytes: []const u8,
    prepared: *const Prepared,
};

fn runSource(alloc: std.mem.Allocator, io: std.Io, source: RunSource, opts: RunOpts) !RunResult {
    var out_list: std.ArrayList(u8) = .empty;
    errdefer out_list.deinit(alloc);
    var err_list: std.ArrayList(u8) = .empty;
    errdefer err_list.deinit(alloc);

    // D-347: the C-API WASI run path takes a `Limits` struct whose axes all
    // default to null = UNMETERED, while `Module.InstantiateOpts` (the
    // `wasm/load` path) defaults to a finite budget. Passing `.{}` here left
    // `(wasm/run …)` unbounded — an infinite loop in an untrusted guest hung
    // the host process forever, while the same loop under `wasm/load` was
    // fuel-trapped. The two surfaces now share one posture: bounded by default,
    // `.unmetered` is opt-in. Note the unit change — zwasm's run path caps
    // memory in BYTES, its instantiate path in 64 KiB PAGES.
    const page_size: u64 = 65536;
    const limits: zwasm.cli.run.Limits = .{
        .fuel = (opts.fuel orelse Budget{ .limited = zwasm.Module.default_fuel }).toOptional(),
        .max_memory_bytes = switch (opts.max_memory_pages orelse Budget{ .limited = zwasm.Module.default_max_memory_pages }) {
            .unmetered => null,
            .limited => |pages| pages * page_size,
        },
        // D-349: the third axis, and the one the other two do not imply.
        .max_output_bytes = (opts.max_output_bytes orelse Budget{ .limited = default_max_output_bytes }).toOptional(),
        .timeout_ms = (opts.timeout_ms orelse Budget{ .limited = default_timeout_ms }).toOptional(),
    };

    // zwasm 2.6.0 (#257) widened fd 0 from `?[]const u8` to a `StdinSource`
    // union so a core module can INHERIT the host's stdin. cljw's
    // `(wasm/run … {:stdin "…"})` is a byte slice by contract, so the two
    // pre-2.6 states map straight across and behaviour is unchanged.
    // `.inherit` is a new capability, not wired: handing an untrusted guest
    // the host's terminal is a sandbox decision, not a build fix.
    const stdin: zwasm.cli.run.StdinSource = if (opts.stdin) |b| .{ .bytes = b } else .none;
    const exit = switch (source) {
        .bytes => |bytes| try zwasm.cli.run.runWasmCapturedFull(
            alloc,
            io,
            bytes,
            opts.argv,
            &out_list,
            &err_list,
            stdin,
            null, // invoke_name → _start / main / first export
            opts.preopens,
            opts.env_keys,
            opts.env_vals,
            null, // invoke_args
            limits,
        ),
        .prepared => |p| try p.run(alloc, io, opts.argv, &out_list, &err_list, stdin, opts.preopens, opts.env_keys, opts.env_vals, limits),
    };

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
    self.export_list = try self.module.exports(alloc);
    errdefer self.export_list.deinit();
    self.instance = try self.module.instantiate(inst_opts);
    self.engine_kind = opts.engine;
    self.alloc = alloc;
    self.sig_cache = .empty;
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
    // discipline applied to engine choice (zwasm ADR-0200 adoption / north-star gap II×III).
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

// (module
//   (func (export "nop_void") (param i32 f64))
//   (func (export "nop_ret")  (param i32 f64) (result f64) local.get 1)
//   (func (export "gpr4_void") (param i32 i32 i32 i32))
//   (func (export "gpr4_ret")  (param i32 i32 i32 i32) (result i32) i32.const 0))
// The minimal discriminators for D-585, with EMPTY bodies that touch no memory,
// so any difference is the signature alone:
//   nop_void  vs nop_ret  — identical params, only the result arity differs.
//   gpr4_void vs gpr4_ret — the same, with NO floating-point param anywhere.
// The second pair is the half that surprises: a void export traps from arity 4
// upward whatever its parameter types are.
const void_arity_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x1b, 0x04, 0x60, 0x02, 0x7f, 0x7c, 0x00,
    0x60, 0x02, 0x7f, 0x7c, 0x01, 0x7c, 0x60, 0x04,
    0x7f, 0x7f, 0x7f, 0x7f, 0x00, 0x60, 0x04, 0x7f,
    0x7f, 0x7f, 0x7f, 0x01, 0x7f, 0x03, 0x05, 0x04,
    0x00, 0x01, 0x02, 0x03, 0x07, 0x2d, 0x04, 0x08,
    0x6e, 0x6f, 0x70, 0x5f, 0x76, 0x6f, 0x69, 0x64,
    0x00, 0x00, 0x07, 0x6e, 0x6f, 0x70, 0x5f, 0x72,
    0x65, 0x74, 0x00, 0x01, 0x09, 0x67, 0x70, 0x72,
    0x34, 0x5f, 0x76, 0x6f, 0x69, 0x64, 0x00, 0x02,
    0x08, 0x67, 0x70, 0x72, 0x34, 0x5f, 0x72, 0x65,
    0x74, 0x00, 0x03, 0x0a, 0x11, 0x04, 0x02, 0x00,
    0x0b, 0x04, 0x00, 0x20, 0x01, 0x0b, 0x02, 0x00,
    0x0b, 0x04, 0x00, 0x41, 0x00, 0x0b,
};

test "dual-engine: a zero-result export traps on the JIT beyond a narrow window (D-585 gap lock)" {
    const alloc = std.testing.allocator;

    const interp = try load(alloc, &void_arity_wasm, .{ .engine = .interp });
    defer {
        interp.deinit();
        alloc.destroy(interp);
    }
    const jit = try load(alloc, &void_arity_wasm, .{ .engine = .jit });
    defer {
        jit.deinit();
        alloc.destroy(jit);
    }

    var in = [_]Value{ Value.fromI32(0), Value.fromF64Bits(@bitCast(@as(f64, 1.5))) };

    // The interpreter runs both shapes.
    try interp.invoke("nop_void", &in, &.{});
    var out = [_]Value{Value.fromF64Bits(0)};
    try interp.invoke("nop_ret", &in, &out);
    try std.testing.expectEqual(@as(f64, 1.5), @as(f64, @bitCast(out[0].f64)));

    // The JIT runs the NON-void one with the same parameters...
    var jout = [_]Value{Value.fromF64Bits(0)};
    try jit.invoke("nop_ret", &in, &jout);
    try std.testing.expectEqual(@as(f64, 1.5), @as(f64, @bitCast(jout[0].f64)));

    // ...and traps the void one. Same params, empty body, only the result arity
    // differs, so the discriminator is the SIGNATURE.
    if (jit.invoke("nop_void", &in, &.{})) |_| {
        return error.TestExpectedVoidFpTrapOnJit;
    } else |_| {
        // Expected while D-585 stands.
    }

    // The second half, and the one that surprises: NO floating-point parameter
    // is needed. An all-GPR export traps too once its arity reaches 4, while
    // the same four parameters with one i32 result are fine.
    var g4 = [_]Value{ Value.fromI32(0), Value.fromI32(0), Value.fromI32(0), Value.fromI32(4) };
    var gout = [_]Value{Value.fromI32(-1)};
    try interp.invoke("gpr4_void", &g4, &.{});
    try jit.invoke("gpr4_ret", &g4, &gout);
    try std.testing.expectEqual(@as(i32, 0), gout[0].i32);
    if (jit.invoke("gpr4_void", &g4, &.{})) |_| {
        return error.TestExpectedVoidArity4TrapOnJit;
    } else |_| {
        // Expected while D-585 stands.
    }

    // Measured window (empty bodies, arities 1..5, every i32/f64 mix): a
    // zero-result export runs on the JIT only at arity <= 1, or at arity 2-3
    // with no FP parameter. Everything else void traps. NON-void was clean at
    // every arity and mix tested.
    //
    // That is not a curiosity, it is most in-place numeric kernels: raster's
    // `residual-add!` is (i32,i32,i32,i32) -> void and traps here, as does any
    // scale/axpy/SGD-step taking a pointer, a length and a scalar. Lock the
    // gap: if zwasm later wires the dispatch this test flips and forces a
    // conscious update, and the `.auto` note below can go with it.

    // `.auto` does NOT save the caller here. Its contract is a transparent
    // downgrade when the JIT cannot BUILD the module; this module builds, then
    // traps at invoke, so the fallback never fires. A caller who needs a void
    // FP-param export today passes `:engine :interp` explicitly.
    const auto = try load(alloc, &void_arity_wasm, .{ .engine = .auto });
    defer {
        auto.deinit();
        alloc.destroy(auto);
    }
    if (auto.invoke("nop_void", &in, &.{})) |_| {
        return error.TestExpectedVoidFpTrapOnAuto;
    } else |_| {
        // Expected: `.auto` builds this module, so it never downgrades.
    }
}

test "exportSig resolves a name once per instance on either engine; the cache dies with the box" {
    const alloc = std.testing.allocator;
    inline for (.{ EngineKind.interp, EngineKind.jit }) |kind| {
        const loaded = try load(alloc, &dual_engine_wasm, .{ .engine = kind });
        defer {
            loaded.deinit();
            alloc.destroy(loaded);
        }
        try std.testing.expectEqual(@as(u32, 0), loaded.sig_cache.count());
        const first = loaded.exportSig("add").?;
        const again = loaded.exportSig("add").?;
        try std.testing.expectEqual(@as(u32, 1), loaded.sig_cache.count());
        try std.testing.expectEqual(first.params.len, again.params.len);
        try std.testing.expectEqual(first.results.len, again.results.len);
        // A miss is not cached, and it does not disturb the hit.
        try std.testing.expect(loaded.exportSig("absent") == null);
        try std.testing.expectEqual(@as(u32, 1), loaded.sig_cache.count());
        // The cached signature still drives a real call.
        try std.testing.expectEqual(@as(i32, 5), try invokeAdd(loaded, 2, 3));
    }
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
