// SPDX-License-Identifier: EPL-2.0
//! cljw `wasm` namespace — the polyglot Wasm FFI surface (ADR-0099 / CFP P1).
//! `(wasm/load "path.wasm")` embeds + instantiates a module via zwasm v2 and
//! returns an opaque handle; `(wasm/call handle "export" & args)` invokes an
//! export by name, marshalling args/results from the export's runtime signature.
//! Compiled + registered ONLY under `-Dwasm` (`build_options.wasm`); the default
//! build never resolves zwasm (F-001).
//!
//! The builtin fns live in the surface tree (runtime/cljw/**) per ADR-0029 D2:
//! lang/primitive/ may not import a surface, so the host fns + their ns
//! registration live here and are wired via runtime/cljw/_host_api.zig.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: wasm/load, wasm/call, wasm/exports, wasm/engine, wasm/mem-size, wasm/mem-read, wasm/mem-write!
const std = @import("std");
const engine = @import("engine.zig");
const run_cache = @import("run_cache.zig");
const gaps = @import("gaps.zig");
const marshal = @import("marshal.zig");
const wasm_memory = @import("memory.zig");
const wasm_handle = @import("wasm_handle.zig");
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const Value = @import("../../value/value.zig").Value;
const error_catalog = @import("../../error/catalog.zig");
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const string_mod = @import("../../collection/string.zig");
const vector_mod = @import("../../collection/vector.zig");
const map_mod = @import("../../collection/map.zig");
const keyword_mod = @import("../../keyword.zig");
const file_io = @import("../../file_io.zig");

/// `(wasm/load "path.wasm")` / `(wasm/load "path.wasm" {:fuel N :max-memory-pages M
/// :engine :jit})` — read the file, compile + instantiate a non-WASI library
/// module via zwasm v2, and return an opaque, re-invokable instance handle.
/// WASI command modules use the deliberately one-shot `wasm/run` surface;
/// `:wasi` is rejected here so the command/handle lifecycle split is explicit
/// rather than a silently ignored option (ADR-0124 / D-350). F-006: the engine
/// is given `rt.gpa` (the layer-1 backing allocator), keeping zwasm's space
/// separate from the cljw GC heap.
/// With no opts the module runs under zwasm's FINITE default budget (fuel 1e9 /
/// 256 MiB) so an untrusted module is bounded out of the box (SE-1 / ZE-1); an opts
/// map overrides either budget axis (`:fuel` / `:max-memory-pages`), where `0` or a
/// negative value means "unmetered" (lift the cap — trusted modules only). `:engine`
/// (zwasm ADR-0200) picks `:auto` (default — JIT-first with transparent interp fallback) /
/// `:jit` (force JIT) / `:interp` (force the interpreter).
/// Crossing cost (ADR-0196, measured on x86_64 Linux, `.dev/wasm_percall_findings.md`):
/// one `wasm/call` is ~0.4 us on `:interp` and ~1.15 us on the JIT, while the
/// JIT runs a compute-bound body ~15x faster, so a call whose interpreter body
/// runs longer than ~0.8 us wins on the JIT and a shorter one loses. Each
/// engine also has call shapes it cannot dispatch today; `(wasm/engine h)`
/// reports the selection and a trap names the shape and the remedy.
pub fn wasmLoadFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("wasm/load", args, 1, 2, loc);
    if (!args[0].isString())
        return error_catalog.raise(.wasm_path_invalid, loc, .{});
    const path = string_mod.asString(args[0]);

    var opts: engine.LoadOpts = .{};
    if (args.len == 2) opts = try parseLoadOpts(rt, args[1], loc);

    // SE-7: confine to the deploy FS jail (CLJW_FS_ROOT) and read the RESOLVED path.
    const jailed = file_io.jailResolve(rt.gpa, rt.fs_jail_root, path) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.FsJailEscape => return error_catalog.raise(.fs_jail_escape, loc, .{ .fn_name = "wasm/load", .path = path }),
    };
    defer if (jailed) |j| rt.gpa.free(j);
    const open_path = jailed orelse path;

    const bytes = file_io.readAll(rt.io, rt.gpa, open_path) catch
        return error_catalog.raise(.wasm_load_read_failed, loc, .{ .path = path });
    defer rt.gpa.free(bytes);

    const loaded = engine.load(rt.gpa, bytes, opts) catch
        return error_catalog.raise(.wasm_load_failed, loc, .{});
    return wasm_handle.wrap(rt, loaded);
}

/// Parse a `{:fuel N :max-memory-pages M :engine :jit}` opts map into
/// `engine.LoadOpts`. A missing budget key leaves that axis at zwasm's finite
/// default; a non-positive value (`<= 0`) selects `.unmetered`; a positive value
/// caps the axis. `:engine` selects `:auto` (default) / `:jit` / `:interp`.
pub fn parseLoadOpts(rt: *Runtime, m: Value, loc: SourceLocation) anyerror!engine.LoadOpts {
    const tag = m.tag();
    if (tag != .array_map and tag != .hash_map)
        return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "the options argument must be a map" });
    const wasi_kw = try keyword_mod.intern(rt, null, "wasi");
    if (try map_mod.contains(m, wasi_kw))
        return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "the :wasi option is not supported on persistent handles; use wasm/run for WASI commands or a Wasm component for reusable WASI state" });
    var opts: engine.LoadOpts = .{};
    if (try axisFromMap(rt, m, "fuel", loc)) |b| opts.fuel = b;
    if (try axisFromMap(rt, m, "max-memory-pages", loc)) |b| opts.max_memory_pages = b;
    if (try engineFromMap(rt, m, loc)) |e| opts.engine = e;
    return opts;
}

/// Read keyword `:engine` from `m` as an `engine.EngineKind` (zwasm ADR-0200). Absent
/// / nil → null (zwasm's `.auto` default — JIT-first, transparent interp
/// fallback). A `:auto` / `:jit` / `:interp` keyword selects the engine; any
/// other value is a usage error.
fn engineFromMap(rt: *Runtime, m: Value, loc: SourceLocation) anyerror!?engine.EngineKind {
    const kw = try keyword_mod.intern(rt, null, "engine");
    const v = map_mod.get(m, kw) catch return null;
    if (v.isNil()) return null;
    if (v.tag() != .keyword)
        return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "the :engine option must be one of :auto, :jit, :interp" });
    const name = keyword_mod.asKeyword(v).name;
    if (std.mem.eql(u8, name, "auto")) return .auto;
    if (std.mem.eql(u8, name, "jit")) return .jit;
    if (std.mem.eql(u8, name, "interp")) return .interp;
    return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "the :engine option must be one of :auto, :jit, :interp" });
}

/// Read keyword `:name` from `m` as a `Budget`: absent / nil → null (use the
/// finite default); integer <= 0 → `.unmetered`; positive integer →
/// `.{ .limited = n }`.
fn axisFromMap(rt: *Runtime, m: Value, comptime name: []const u8, loc: SourceLocation) anyerror!?engine.Budget {
    const kw = try keyword_mod.intern(rt, null, name);
    const v = map_mod.get(m, kw) catch return null;
    if (v.isNil()) return null;
    if (!v.isInt())
        return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "the :" ++ name ++ " option must be an integer" });
    const n = v.asInteger();
    if (n <= 0) return .unmetered;
    return engine.Budget{ .limited = @intCast(n) };
}

/// `(wasm/call handle "export" & args)` — invoke an export by name. Arg/result
/// types come from the export's runtime signature; a single result is returned
/// as a scalar, multiple as a vector, none as nil.
pub fn wasmCallFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityMin("wasm/call", args, 2, loc);
    if (!wasm_handle.isHandle(args[0]))
        return error_catalog.raise(.wasm_handle_invalid, loc, .{ .fn_name = "wasm/call" });
    if (!args[1].isString())
        return error_catalog.raise(.wasm_export_name_invalid, loc, .{});

    return callExport(rt, wasm_handle.unwrap(args[0]), string_mod.asString(args[1]), args[2..], loc);
}

/// `(.export h args…)` on a `.wasm_module` receiver (ADR-0203 decision 2):
/// the method name is the export name verbatim, and the call is `wasm/call`'s
/// own path. Installed on `rt.wasm_member_call` by `register`.
fn memberCallFn(rt: *Runtime, receiver: Value, name: []const u8, args: []const Value, loc: SourceLocation) anyerror!Value {
    return callExport(rt, wasm_handle.unwrap(receiver), name, args, loc);
}

/// The one export-invoke path shared by `wasm/call` and dot-interop: signature
/// probe, arity check, marshalling, fuel and trap mapping.
fn callExport(rt: *Runtime, loaded: *engine.Loaded, name: []const u8, call_args: []const Value, loc: SourceLocation) anyerror!Value {
    const sig = loaded.exportSig(name) orelse
        return error_catalog.raise(.wasm_export_not_found, loc, .{ .name = name });
    if (call_args.len != sig.params.len)
        return error_catalog.raise(.wasm_arity_mismatch, loc, .{ .name = name, .expected = sig.params.len, .actual = call_args.len });

    // Marshal args in + size the results buffer. Both are short-lived
    // host-side scratch on rt.gpa (the wasm boundary, not cljw Values).
    const in = try rt.gpa.alloc(engine.Value, sig.params.len);
    defer rt.gpa.free(in);
    for (call_args, sig.params, 0..) |a, vt, i| in[i] = try marshal.toWasm(a, vt, loc);

    const out = try rt.gpa.alloc(engine.Value, sig.results.len);
    defer rt.gpa.free(out);

    // Export + arity were validated above, so an invoke failure here is a trap
    // (div-by-zero, OOB, unreachable, …) — surfaced as a clean cljw exception,
    // not a crash. The per-trap-kind 1:1 map is Phase-16 (ADR-0099 trap_map).
    // ADR-0196: the message names the export, its signature and the engine,
    // plus the remedy when the shape is a known engine gap.
    loaded.invoke(name, in, out) catch |e| {
        if (e == error.OutOfFuel)
            return error_catalog.raise(.wasm_fuel_exhausted, loc, .{ .name = name });
        var sig_buf: [192]u8 = undefined;
        const gap = gaps.find(loaded.engine_kind, sig);
        return error_catalog.raise(.wasm_trap, loc, .{
            .name = name,
            .sig = fmtSig(&sig_buf, sig),
            .engine = engineLabel(loaded.engine_kind),
            .sep = if (gap != null) "; " else "",
            .hint = if (gap) |g| g.remedy else "",
        });
    };

    if (out.len == 0) return Value.nil_val;
    if (out.len == 1) return marshal.fromWasm(rt, out[0], loc);

    const items = try rt.gpa.alloc(Value, out.len);
    defer rt.gpa.free(items);

    // GC-ROOT: `items` is a gpa slice the collector does NOT trace, and an i64
    // result outside the i48 immediate window is a HEAP Long, so a collect
    // during a later result's alloc would sweep the ones already lifted. Same
    // bracket as `wasmMemReadFn`. [ref: .dev/gc_rooting.md]
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    for (out, 0..) |r, i| items[i] = try marshal.fromWasm(rt, r, loc);
    return vector_mod.fromSlice(rt, items);
}

/// `(wasm/engine handle)` — the engine selection the handle was loaded with:
/// `:auto`, `:jit` or `:interp` (ADR-0196). Under `:auto` this is the request,
/// not the arm zwasm chose for the module.
pub fn wasmEngineFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("wasm/engine", args, 1, loc);
    if (!wasm_handle.isHandle(args[0]))
        return error_catalog.raise(.wasm_handle_invalid, loc, .{ .fn_name = "wasm/engine" });
    const loaded = wasm_handle.unwrap(args[0]);
    return keyword_mod.intern(rt, null, @tagName(loaded.engine_kind));
}

/// The engine as a trap message names it.
fn engineLabel(kind: engine.EngineKind) []const u8 {
    return switch (kind) {
        .auto => "auto (JIT-first)",
        .jit => "jit",
        .interp => "interp",
    };
}

/// Render an export signature as `(i32 f64) -> (f64)` into `buf` (an empty
/// list renders as `()`).
fn fmtSig(buf: []u8, sig: engine.FuncType) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    writeSig(&w, sig) catch {
        // A signature longer than the buffer is cut short; the message stays valid.
    };
    return w.buffered();
}

fn writeSig(w: *std.Io.Writer, sig: engine.FuncType) !void {
    try writeTypes(w, sig.params);
    try w.writeAll(" -> ");
    try writeTypes(w, sig.results);
}

fn writeTypes(w: *std.Io.Writer, types: []const engine.ValType) !void {
    try w.writeByte('(');
    for (types, 0..) |t, i| {
        if (i != 0) try w.writeByte(' ');
        try w.writeAll(@tagName(t));
    }
    try w.writeByte(')');
}

test "fmtSig renders params and results, and the empty list" {
    var buf: [64]u8 = undefined;
    const VT = engine.ValType;
    try std.testing.expectEqualStrings("(i32 f64) -> ()", fmtSig(&buf, .{ .params = &[_]VT{ .i32, .f64 }, .results = &.{} }));
    try std.testing.expectEqualStrings("() -> (i64 v128)", fmtSig(&buf, .{ .params = &.{}, .results = &[_]VT{ .i64, .v128 } }));
}

/// FS-jail resolve a `:dir` / `:dirs` host path; returns the path to open (the
/// resolved path under the jail, or the original when no jail is configured).
fn resolveDir(rt: *Runtime, scratch: std.mem.Allocator, dir_path: []const u8, loc: SourceLocation) ![]const u8 {
    const resolved = file_io.jailResolve(scratch, rt.fs_jail_root, dir_path) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.FsJailEscape => return error_catalog.raise(.fs_jail_escape, loc, .{ .fn_name = "wasm/run", .path = dir_path }),
    };
    return resolved orelse dir_path;
}

/// Accumulator for the `:env` map walk (`map_mod.forEachEntry`, D-348): collects
/// each entry into the parallel name/value slices zwasm's runner expects. A key
/// may be a string or a keyword (its name is used — `:PATH` → "PATH"); the value
/// must be a string. A non-conforming entry sets `bad`. Slices are scratch-arena
/// allocated; the string views point into GC strings (valid through engine.run).
const EnvCollect = struct {
    keys: *std.ArrayList([]const u8),
    vals: *std.ArrayList([]const u8),
    scratch: std.mem.Allocator,
    bad: bool = false,
};
fn collectEnvEntry(c: *EnvCollect, k: Value, v: Value) anyerror!void {
    if (!v.isString()) {
        c.bad = true;
        return;
    }
    const name = if (k.isString())
        string_mod.asString(k)
    else if (k.tag() == .keyword)
        keyword_mod.asKeyword(k).name
    else {
        c.bad = true;
        return;
    };
    try c.keys.append(c.scratch, name);
    try c.vals.append(c.scratch, string_mod.asString(v));
}

/// The `:cache` option of `wasm/run`: absent / nil / true caches the compiled
/// module (D-350), `false` compiles for this call only. Read before the module
/// file, so a non-map second argument is left to the full option parse.
fn cacheFromOpts(rt: *Runtime, args: []const Value, loc: SourceLocation) anyerror!bool {
    if (args.len < 2) return true;
    const t = args[1].tag();
    if (t != .array_map and t != .hash_map) return true;
    const v = map_mod.get(args[1], try keyword_mod.intern(rt, null, "cache")) catch return true;
    if (v.isNil()) return true;
    if (v != Value.true_val and v != Value.false_val)
        return error_catalog.raise(.wasm_run_arg_invalid, loc, .{ .detail = "the :cache option must be a boolean" });
    return v.asBoolean();
}

/// `(wasm/clear-cache!)` — drop every module `wasm/run` holds compiled and
/// return how many there were. A run in progress keeps its module until it
/// returns; the next `wasm/run` of any path compiles afresh.
pub fn wasmClearCacheFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("wasm/clear-cache!", args, 0, loc);
    return Value.initInteger(@intCast(run_cache.clear()));
}

/// `(wasm/run "path.wasm")` / `(wasm/run "path.wasm" {:args [...] :stdin "..." :dir "..." :dirs [[h g]...] :env {k v}})`
/// — run a WASI command module (Rust/Go/… compiled to wasm32-wasip1): compile,
/// instantiate with a WASI host, run the command entry (`_start`/`main`), and
/// return `{:out <stdout> :err <stderr> :exit <code>}`. A non-zero exit (incl. a
/// guest trap → 1) is returned as data, not raised; only a path/opts type error,
/// FS-jail escape, unreadable file, or compile/instantiate/preopen failure is a
/// catchable exception. `:dir` preopens one host directory (FS-jail resolved) as
/// the guest's "/". Complements `wasm/call` (scalar pure-compute, no WASI).
/// The compiled module is cached per file (`run_cache`), so a repeated run only
/// instantiates; `:cache false` compiles for this call alone.
pub fn wasmRunFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("wasm/run", args, 1, 2, loc);
    if (!args[0].isString())
        return error_catalog.raise(.wasm_run_arg_invalid, loc, .{ .detail = "the module path must be a string" });
    const path = string_mod.asString(args[0]);

    const jailed = file_io.jailResolve(rt.gpa, rt.fs_jail_root, path) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.FsJailEscape => return error_catalog.raise(.fs_jail_escape, loc, .{ .fn_name = "wasm/run", .path = path }),
    };
    defer if (jailed) |j| rt.gpa.free(j);
    const open_path = jailed orelse path;

    // D-350: a cached module (`run_cache`) skips the read and the compile; a
    // miss reads here as before and compiles once below.
    const use_cache = try cacheFromOpts(rt, args, loc);
    var probe: ?run_cache.Probe = null;
    if (use_cache) probe = run_cache.lookup(rt.io, open_path) catch
        return error_catalog.raise(.wasm_run_read_failed, loc, .{ .path = path });
    var lease: ?run_cache.Lease = if (probe) |p| p.hit else null;
    defer if (lease) |l| l.release();
    const hit = lease != null;

    const bytes: []const u8 = if (hit) &.{} else file_io.readAll(rt.io, rt.gpa, open_path) catch
        return error_catalog.raise(.wasm_run_read_failed, loc, .{ .path = path });
    defer if (!hit) rt.gpa.free(bytes);

    // Parse-scratch arena: argv slice, preopen host paths + slice. String views
    // (asString) point into GC strings, which stay valid during engine.run (no
    // cljw allocation happens there); the arena holds the slices + jail-resolved
    // host paths, bulk-freed when the builtin returns.
    var arena_state = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena_state.deinit();
    const scratch = arena_state.allocator();

    var run_opts: engine.RunOpts = .{};

    if (args.len == 2) {
        const m = args[1];
        const mt = m.tag();
        if (mt != .array_map and mt != .hash_map)
            return error_catalog.raise(.wasm_run_arg_invalid, loc, .{ .detail = "the options argument must be a map" });

        const args_v = map_mod.get(m, try keyword_mod.intern(rt, null, "args")) catch Value.nil_val;
        if (!args_v.isNil()) {
            if (args_v.tag() != .vector)
                return error_catalog.raise(.wasm_run_arg_invalid, loc, .{ .detail = "the :args option must be a vector of strings" });
            const n = vector_mod.count(args_v);
            const argv = try scratch.alloc([]const u8, n);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const e = vector_mod.nth(args_v, i);
                if (!e.isString())
                    return error_catalog.raise(.wasm_run_arg_invalid, loc, .{ .detail = "every :args element must be a string" });
                argv[i] = string_mod.asString(e);
            }
            run_opts.argv = argv;
        }

        const stdin_v = map_mod.get(m, try keyword_mod.intern(rt, null, "stdin")) catch Value.nil_val;
        if (!stdin_v.isNil()) {
            if (!stdin_v.isString())
                return error_catalog.raise(.wasm_run_arg_invalid, loc, .{ .detail = "the :stdin option must be a string" });
            run_opts.stdin = string_mod.asString(stdin_v);
        }

        // :env — a map of env-var name → value (D-348). Names may be strings or
        // keywords (`:PATH` → "PATH"); values must be strings. Walked into the
        // parallel slices zwasm's runner already threads.
        const env_v = map_mod.get(m, try keyword_mod.intern(rt, null, "env")) catch Value.nil_val;
        if (!env_v.isNil()) {
            const et = env_v.tag();
            if (et != .array_map and et != .hash_map)
                return error_catalog.raise(.wasm_run_arg_invalid, loc, .{ .detail = "the :env option must be a map of name to string value" });
            var env_keys: std.ArrayList([]const u8) = .empty;
            var env_vals: std.ArrayList([]const u8) = .empty;
            var ec = EnvCollect{ .keys = &env_keys, .vals = &env_vals, .scratch = scratch };
            try map_mod.forEachEntry(env_v, &ec, collectEnvEntry);
            if (ec.bad)
                return error_catalog.raise(.wasm_run_arg_invalid, loc, .{ .detail = "every :env key must be a string/keyword and every value a string" });
            run_opts.env_keys = env_keys.items;
            run_opts.env_vals = env_vals.items;
        }

        // Preopens: :dir (one host dir → guest "/") is sugar; :dirs is a vector of
        // [host guest] pairs. Both host paths are FS-jail resolved.
        var preopens: std.ArrayList(engine.PreopenDir) = .empty;
        const dir_v = map_mod.get(m, try keyword_mod.intern(rt, null, "dir")) catch Value.nil_val;
        if (!dir_v.isNil()) {
            if (!dir_v.isString())
                return error_catalog.raise(.wasm_run_arg_invalid, loc, .{ .detail = "the :dir option must be a string" });
            try preopens.append(scratch, .{
                .host_path = try resolveDir(rt, scratch, string_mod.asString(dir_v), loc),
                .guest_path = "/",
            });
        }
        const dirs_v = map_mod.get(m, try keyword_mod.intern(rt, null, "dirs")) catch Value.nil_val;
        if (!dirs_v.isNil()) {
            if (dirs_v.tag() != .vector)
                return error_catalog.raise(.wasm_run_arg_invalid, loc, .{ .detail = "the :dirs option must be a vector of [host guest] pairs" });
            const n = vector_mod.count(dirs_v);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const pair = vector_mod.nth(dirs_v, i);
                if (pair.tag() != .vector or vector_mod.count(pair) != 2)
                    return error_catalog.raise(.wasm_run_arg_invalid, loc, .{ .detail = "each :dirs entry must be a [host guest] pair" });
                const host_v = vector_mod.nth(pair, 0);
                const guest_v = vector_mod.nth(pair, 1);
                if (!host_v.isString() or !guest_v.isString())
                    return error_catalog.raise(.wasm_run_arg_invalid, loc, .{ .detail = "each :dirs [host guest] must be two strings" });
                try preopens.append(scratch, .{
                    .host_path = try resolveDir(rt, scratch, string_mod.asString(host_v), loc),
                    .guest_path = string_mod.asString(guest_v),
                });
            }
        }
        run_opts.preopens = preopens.items;

        // D-347: the same budget axes `wasm/load` accepts, so a caller can
        // widen or lift the default for a trusted command. Absent = the finite
        // default; `<= 0` = `.unmetered`.
        if (try axisFromMap(rt, m, "fuel", loc)) |b| run_opts.fuel = b;
        if (try axisFromMap(rt, m, "max-memory-pages", loc)) |b| run_opts.max_memory_pages = b;
        if (try axisFromMap(rt, m, "max-output-bytes", loc)) |b| run_opts.max_output_bytes = b;
        if (try axisFromMap(rt, m, "timeout-ms", loc)) |b| run_opts.timeout_ms = b;
    }

    if (use_cache and lease == null) lease = run_cache.insert(rt.gpa, open_path, probe.?.stat, bytes) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return error_catalog.raise(.wasm_run_failed, loc, .{}),
    };
    const run_result = if (lease) |l|
        engine.runPrepared(rt.gpa, rt.io, l.prepared(), run_opts)
    else
        engine.run(rt.gpa, rt.io, bytes, run_opts);
    const res = run_result catch
        return error_catalog.raise(.wasm_run_failed, loc, .{});
    defer rt.gpa.free(res.out);
    defer rt.gpa.free(res.err);

    var result = map_mod.empty();
    result = try map_mod.assoc(rt, result, try keyword_mod.intern(rt, null, "out"), try string_mod.alloc(rt, res.out));
    result = try map_mod.assoc(rt, result, try keyword_mod.intern(rt, null, "err"), try string_mod.alloc(rt, res.err));
    result = try map_mod.assoc(rt, result, try keyword_mod.intern(rt, null, "exit"), Value.initInteger(@as(i64, res.exit)));
    return result;
}

// --- linear memory (ADR-0192) -----------------------------------------------
//
// `wasm/call` marshals scalars, which reaches every guest whose whole interface
// fits in numbers. The dominant convention for a NUMERIC guest does not: it
// passes an array as a (ptr,len) pair into linear memory. These three fns are
// the other end of that pointer.

/// Resolve arg 0 to the module's exported linear memory. Raises when the value
/// is not a loaded handle, or when the module exports no memory — "exports
/// none" is a program error, distinct from "holds nothing yet".
pub fn memoryArg(comptime fn_name: []const u8, arg: Value, loc: SourceLocation) anyerror!engine.Memory {
    if (!wasm_handle.isHandle(arg))
        return error_catalog.raise(.wasm_handle_invalid, loc, .{ .fn_name = fn_name });
    return wasm_handle.unwrap(arg).memory() orelse
        error_catalog.raise(.wasm_memory_absent, loc, .{ .fn_name = fn_name });
}

/// Resolve an element-type keyword (`:f64`) to a `Dtype`. The element type is
/// the GUEST's layout, so it is stated by the caller and never inferred from
/// the data — `[1 2]` and `[1.0 2.0]` denote the same `:f64` buffer.
pub fn dtypeArg(comptime fn_name: []const u8, arg: Value, loc: SourceLocation) anyerror!wasm_memory.Dtype {
    if (arg.tag() != .keyword)
        return error_catalog.raise(.wasm_memory_dtype_invalid, loc, .{ .fn_name = fn_name });
    return wasm_memory.dtypeFromName(keyword_mod.asKeyword(arg).name) orelse
        error_catalog.raise(.wasm_memory_dtype_invalid, loc, .{ .fn_name = fn_name });
}

/// Resolve a byte-offset / element-count argument to an exact i64.
pub fn indexArg(comptime fn_name: []const u8, arg: Value, loc: SourceLocation) anyerror!i64 {
    return wasm_memory.indexArg(arg) orelse
        error_catalog.raise(.wasm_memory_index_invalid, loc, .{ .fn_name = fn_name });
}

/// `(wasm/mem-size handle)` — the byte length of the module's exported linear
/// memory. BYTES, not 64 KiB pages: every caller of this surface is doing
/// arithmetic against a byte offset it is about to hand to `wasm/call`, so
/// answering in pages would make the unit of the answer differ from the unit
/// of every other number in the same expression.
pub fn wasmMemSizeFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("wasm/mem-size", args, 1, loc);
    const mem = try memoryArg("wasm/mem-size", args[0], loc);
    // Not caller data: a wasm32 linear memory is bounded by the 4 GiB address
    // space and by the `:max-memory-pages` budget, so it cannot exceed i64.
    return Value.initInteger(@as(i64, @intCast(mem.slice().len)));
}

/// `(wasm/mem-read handle :f64 offset n)` — read `n` elements of the given
/// element type starting at BYTE `offset`, as a vector. Little-endian (the
/// wasm memory model) and alignment-tolerant, because a (ptr,len) ABI hands
/// the host whatever offset the guest's allocator produced.
pub fn wasmMemReadFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("wasm/mem-read", args, 4, loc);
    const mem = try memoryArg("wasm/mem-read", args[0], loc);
    const dt = try dtypeArg("wasm/mem-read", args[1], loc);
    const offset = try indexArg("wasm/mem-read", args[2], loc);
    const count = try indexArg("wasm/mem-read", args[3], loc);

    const bytes = mem.slice();
    const range = wasm_memory.byteRange(offset, count, dt, bytes.len) orelse
        return error_catalog.raise(.wasm_memory_range_invalid, loc, .{
            .fn_name = "wasm/mem-read",
            .offset = offset,
            .count = count,
            .size = bytes.len,
        });

    const n: usize = @intCast(count);
    const items = try rt.gpa.alloc(Value, n);
    defer rt.gpa.free(items);

    // GC-ROOT: `items` is a gpa slice the collector does NOT trace, and an
    // `:i64` element outside the i48 immediate window is a HEAP Long — so a
    // collect during a later element's alloc would sweep the ones already
    // decoded. Bracket the bounded build in the fabrication no-collect region,
    // like the other multi-alloc builders. [ref: .dev/gc_rooting.md]
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();

    const w: usize = dt.width();
    for (items, 0..) |*slot, i| {
        const at = range.start + i * w;
        slot.* = try wasm_memory.readElem(rt, dt, bytes[at .. at + w]);
    }
    return vector_mod.fromSlice(rt, items);
}

/// `(wasm/mem-write! handle :f64 offset data)` — write vector `data` as the
/// given element type starting at BYTE `offset`; returns the number of
/// elements written, so a caller can thread it.
///
/// `data` is a VECTOR, the same shape `wasm/run`'s `:args` takes: this module
/// is zone 0 and the seq protocol lives in zone 2, so a caller holding a lazy
/// seq calls `vec` first. Nothing is written unless the whole range is in
/// bounds, but an element that fails to encode leaves the ones before it
/// written — the buffer is the guest's, and rolling back would need a copy of
/// it.
pub fn wasmMemWriteFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("wasm/mem-write!", args, 4, loc);
    const mem = try memoryArg("wasm/mem-write!", args[0], loc);
    const dt = try dtypeArg("wasm/mem-write!", args[1], loc);
    const offset = try indexArg("wasm/mem-write!", args[2], loc);
    if (args[3].tag() == .array) return @import("memory_array.zig").writeArray(mem, dt, offset, args[3], loc);

    const n = wasm_memory.indexedCount(args[3]) orelse
        return error_catalog.raise(.wasm_memory_data_invalid, loc, .{ .fn_name = "wasm/mem-write!" });

    const bytes = mem.slice();
    const range = wasm_memory.byteRange(offset, @as(i64, n), dt, bytes.len) orelse
        return error_catalog.raise(.wasm_memory_range_invalid, loc, .{
            .fn_name = "wasm/mem-write!",
            .offset = offset,
            .count = @as(i64, n),
            .size = bytes.len,
        });

    const w: usize = dt.width();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const at = range.start + @as(usize, i) * w;
        wasm_memory.writeElem(wasm_memory.indexedNth(args[3], i), dt, bytes[at .. at + w]) catch |e|
            return error_catalog.raise(.wasm_memory_element_invalid, loc, .{
                .fn_name = "wasm/mem-write!",
                .index = i,
                .detail = switch (e) {
                    error.NotANumber => "is not a number",
                    error.NotAnInteger => "is not an integer",
                    error.OutOfRange => "is outside this element type's range",
                },
            });
    }
    return Value.initInteger(n);
}

/// Create the `wasm` host namespace. Called by
/// `runtime/cljw/_host_api.zig::installAll` under `build_options.wasm`.
pub fn register(env: *Env) !void {
    // Register the `.wasm_module` GC finaliser so a swept `(wasm/load …)` handle
    // tears down its zwasm triple instead of leaking (D-259 (b)).
    wasm_handle.registerGcHooks();
    // ADR-0203: `.member` dispatch on a handle routes to `callExport`.
    env.rt.wasm_member_call = &memberCallFn;
    const ns = try env.findOrCreateNs("wasm");
    _ = try env.intern(ns, "load", Value.initBuiltinFn(&wasmLoadFn), null);
    _ = try env.intern(ns, "call", Value.initBuiltinFn(&wasmCallFn), null);
    _ = try env.intern(ns, "engine", Value.initBuiltinFn(&wasmEngineFn), null);
    _ = try env.intern(ns, "exports", Value.initBuiltinFn(&@import("exports.zig").wasmExportsFn), null);
    _ = try env.intern(ns, "run", Value.initBuiltinFn(&wasmRunFn), null);
    _ = try env.intern(ns, "clear-cache!", Value.initBuiltinFn(&wasmClearCacheFn), null);
    // ADR-0192: the (ptr,len) half of the FFI — `wasm/call` passes the pointer,
    // these three put something at the other end of it.
    _ = try env.intern(ns, "mem-size", Value.initBuiltinFn(&wasmMemSizeFn), null);
    _ = try env.intern(ns, "mem-read", Value.initBuiltinFn(&wasmMemReadFn), null);
    _ = try env.intern(ns, "mem-write!", Value.initBuiltinFn(&wasmMemWriteFn), null);
    try @import("memory_array.zig").register(env, ns);
    // EXPERIMENT (D-404 / ADR-0135, push-suppressed): component introspection +
    // typed invoke probes — the require-a-component substrate.
    const component = @import("component.zig");
    _ = try env.intern(ns, "component-exports", Value.initBuiltinFn(&component.componentExportsFn), null);
    _ = try env.intern(ns, "component-invoke", Value.initBuiltinFn(&component.componentInvokeFn), null);
    // Instance caching (REQ-7, zwasm 33e0100c): a long-lived handle persists the
    // opened component across calls so resource chains (constructor → method
    // own-handle) and require-a-component (one Var per export) become expressible.
    _ = try env.intern(ns, "load-component", Value.initBuiltinFn(&component.loadComponentFn), null);
    _ = try env.intern(ns, "component-call", Value.initBuiltinFn(&component.componentCallFn), null);
    // ADR-0159: deterministic release of a component `own` resource handle.
    _ = try env.intern(ns, "resource-drop", Value.initBuiltinFn(&component.resourceDropFn), null);
}
