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
//! Clojure peer: wasm/load, wasm/call
const engine = @import("engine.zig");
const marshal = @import("marshal.zig");
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

/// `(wasm/load "path.wasm")` / `(wasm/load "path.wasm" {:fuel N :max-memory-pages M})`
/// — read the file, compile + instantiate it via zwasm v2, and return an opaque
/// instance handle. F-006: the engine is given `rt.gpa` (the layer-1 backing
/// allocator), keeping zwasm's space separate from the cljw GC heap. With no opts
/// the module runs under zwasm's FINITE default budget (fuel 1e9 / 256 MiB) so an
/// untrusted module is bounded out of the box (SE-1 / ZE-1); an opts map overrides
/// either axis (`:fuel` / `:max-memory-pages`), and `0` or a negative value on an
/// axis means "unmetered" (lift the cap — trusted modules only).
pub fn wasmLoadFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("wasm/load", args, 1, 2, loc);
    if (!args[0].isString())
        return error_catalog.raise(.wasm_path_invalid, loc, .{});
    const path = string_mod.asString(args[0]);

    var opts: engine.LoadOpts = .{};
    if (args.len == 2) opts = try parseLoadOpts(rt, args[1], loc);

    const bytes = file_io.readAll(rt.io, rt.gpa, path) catch
        return error_catalog.raise(.wasm_load_read_failed, loc, .{ .path = path });
    defer rt.gpa.free(bytes);

    const loaded = engine.load(rt.gpa, bytes, opts) catch
        return error_catalog.raise(.wasm_load_failed, loc, .{});
    return wasm_handle.wrap(rt, loaded);
}

/// Parse a `{:fuel N :max-memory-pages M}` opts map into `engine.LoadOpts`. A
/// missing key leaves that axis at zwasm's finite default; a non-positive value
/// (`<= 0`) selects `.unmetered`; a positive value caps the axis.
fn parseLoadOpts(rt: *Runtime, m: Value, loc: SourceLocation) anyerror!engine.LoadOpts {
    const tag = m.tag();
    if (tag != .array_map and tag != .hash_map)
        return error_catalog.raise(.wasm_opts_invalid, loc, .{ .detail = "the options argument must be a map" });
    var opts: engine.LoadOpts = .{};
    if (try axisFromMap(rt, m, "fuel", loc)) |b| opts.fuel = b;
    if (try axisFromMap(rt, m, "max-memory-pages", loc)) |b| opts.max_memory_pages = b;
    return opts;
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
        return error_catalog.raise(.wasm_handle_invalid, loc, .{});
    if (!args[1].isString())
        return error_catalog.raise(.wasm_export_name_invalid, loc, .{});

    const loaded = wasm_handle.unwrap(args[0]);
    const name = string_mod.asString(args[1]);
    const call_args = args[2..];

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
    loaded.invoke(name, in, out) catch
        return error_catalog.raise(.wasm_trap, loc, .{});

    if (out.len == 0) return Value.nil_val;
    if (out.len == 1) return marshal.fromWasm(out[0], loc);

    const items = try rt.gpa.alloc(Value, out.len);
    defer rt.gpa.free(items);
    for (out, 0..) |r, i| items[i] = try marshal.fromWasm(r, loc);
    return vector_mod.fromSlice(rt, items);
}

/// Create the `wasm` host namespace. Called by
/// `runtime/cljw/_host_api.zig::installAll` under `build_options.wasm`.
pub fn register(env: *Env) !void {
    // Register the `.wasm_module` GC finaliser so a swept `(wasm/load …)` handle
    // tears down its zwasm triple instead of leaking (D-259 (b)).
    wasm_handle.registerGcHooks();
    const ns = try env.findOrCreateNs("wasm");
    _ = try env.intern(ns, "load", Value.initBuiltinFn(&wasmLoadFn), null);
    _ = try env.intern(ns, "call", Value.initBuiltinFn(&wasmCallFn), null);
}
