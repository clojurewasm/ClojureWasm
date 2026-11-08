// SPDX-License-Identifier: EPL-2.0
//! cljw-original surface aggregator (ADR-0098), the sibling of
//! `runtime/java/_host_api.zig`. `installAll` registers every `cljw.*` host
//! namespace; it is imported by `src/lang/primitive.zig` — the only lang
//! aggregator permitted to reach a surface tree under the ADR-0029 D2 / F-009
//! zone rule (files *under* `lang/primitive/` must not import a surface).
//!
//! As more cljw-original surfaces land (cljw.build / cljw.wasm / cljw.edge /
//! cljw.repl per structure_plan.md), add their `register(env)` here.
const Env = @import("../env.zig").Env;
const builtin = @import("builtin");
const build_options = @import("build_options");
const http_server = @import("http/server.zig");
const eval_with_budget = @import("eval/with_budget.zig");
const net_socket = @import("net/socket.zig");
const process_run = @import("process/run.zig");

pub fn installAll(env: *Env) !void {
    if (comptime builtin.os.tag != .wasi) try http_server.register(env);
    try eval_with_budget.register(env);
    if (comptime builtin.os.tag != .wasi) try net_socket.register(env);
    if (comptime builtin.os.tag != .wasi) try process_run.register(env);
    // wasm FFI surface (ADR-0099): only under `-Dwasm`, so the default build
    // never resolves zwasm (F-001). The comptime-false branch is not analysed,
    // so `wasm/surface.zig` (and its `@import("zwasm")`) is absent by default.
    if (build_options.wasm) try @import("wasm/surface.zig").register(env);
    // C FFI surface (ADR-0202): only where `build.zig` set `ffi` (x86_64 /
    // aarch64 on Linux or macOS, `-Dffi` not false). Absent on wasm targets.
    if (build_options.ffi) try @import("ffi/surface.zig").register(env);
}
