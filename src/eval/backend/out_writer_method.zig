// SPDX-License-Identifier: EPL-2.0
//! Writer-interop fallback for cljw's `*out*` sentinel (D-434). cljw's `*out*`
//! root is the keyword `:clojure.core/stdout` — a print-routing SENTINEL, not a
//! Writer object — so a Java-Writer-interop call `(.write *out* s)` / `.append`
//! / `.flush` (used by libs like clojure.data.csv's `write-csv` to `*out*`, and
//! clojure.pprint) has no method to dispatch and would raise `<.member>`.
//!
//! This dispatch-level fallback (consulted by BOTH backends after the
//! Object-method + clojure.lang-method misses) routes those calls through
//! `clojure.core/print`, which already honors the `with-out-str` / nREPL capture
//! lane via `emitToStdout` — so writing to `*out*` via the Writer interface
//! behaves exactly like `print`. Shared by tree_walk + vm so the parity is one
//! source (ADR-0036). Layer 1: imports `runtime/` only.
//!
//! Scope: `*out*` (stdout sentinel) only. `*err*` writer-interop is NOT routed
//! here — routing it through `print` would mis-send to stdout, and cljw's `*err*`
//! output path is itself unwired (a separate, tracked residual). An `*err*`
//! receiver falls through to the caller's `<.member>` error, unchanged.

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const Env = @import("../../runtime/env.zig").Env;
const keyword = @import("../../runtime/keyword.zig");
const SourceLocation = @import("../../runtime/error/info.zig").SourceLocation;

/// True iff `v` is the `:clojure.core/stdout` sentinel (the root value of `*out*`).
fn isStdoutSentinel(v: Value) bool {
    if (v.tag() != .keyword) return false;
    const k = keyword.asKeyword(v);
    const ns = k.ns orelse return false;
    return std.mem.eql(u8, ns, "clojure.core") and std.mem.eql(u8, k.name, "stdout");
}

/// If `receiver` is the `*out*` sentinel and `name` is a 1-arg Writer-interface
/// method (`write` / `append` / `flush`), route through `clojure.core/print`
/// (capture-lane-aware) and return the JVM-faithful result: nil for `write` /
/// `flush` (void), the receiver for `append` (chains). Otherwise `null` so the
/// caller raises its original `<.member>` error. `args` EXCLUDES the receiver.
pub fn tryOutWriterMethod(
    rt: *Runtime,
    env: *Env,
    receiver: Value,
    name: []const u8,
    args: []const Value,
    loc: SourceLocation,
) !?Value {
    if (!isStdoutSentinel(receiver)) return null;
    if (std.mem.eql(u8, name, "flush")) return .nil_val; // cljw flushes per-print; no-op
    const is_write = std.mem.eql(u8, name, "write");
    const is_append = std.mem.eql(u8, name, "append");
    if (!is_write and !is_append) return null;
    if (args.len != 1) return null; // multi-arg (.write s off len / char[]) → caller raises

    const vt = rt.vtable orelse return null;
    const core_ns = env.findNs("clojure.core") orelse return null;
    const print_var = core_ns.resolve("print") orelse return null;
    // `.write(int)` writes the char with that codepoint; a String / CharSequence
    // (the common `write-csv` case) prints its str-form. print str-ifies, so a
    // string writes raw (no quoting) — exactly Writer.write's contract.
    const to_print: Value = blk: {
        if (is_write and args[0].tag() == .integer) {
            const cp = args[0].asInteger();
            if (cp >= 0 and cp <= 0x10FFFF) break :blk Value.initChar(@intCast(cp));
        }
        break :blk args[0];
    };
    _ = try vt.callFn(rt, env, print_var.deref(), &.{to_print}, loc);
    return if (is_append) receiver else .nil_val;
}
