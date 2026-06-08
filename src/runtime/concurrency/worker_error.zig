// SPDX-License-Identifier: EPL-2.0
//! Uniform cross-thread worker-error marshalling (ADR-0120).
//!
//! cljw runs user code on real OS threads (`future`, `agent` drainers, future
//! `pmap`). When a worker throws, its error lives in THREADLOCAL state
//! (`error/info.zig` `last_error` / `msg_buf` / `trace_snapshot`,
//! `dispatch.last_thrown_exception`) that dies with the thread. The single
//! discipline here marshals that error into a GC-heap exception Value on the
//! worker (so it survives the thread), and re-raises it faithfully on the
//! consuming thread — one `capture`/`reraise` pair for future/agent/pmap,
//! not an ad-hoc per-construct conversion.

const Value = @import("../value/value.zig").Value;
const Runtime = @import("../runtime.zig").Runtime;
const dispatch = @import("../dispatch.zig");
const error_mod = @import("../error/info.zig");
const host_class = @import("../error/host_class.zig");
const ex_info = @import("../collection/ex_info.zig");

/// Worker-side, at the catch: marshal the worker's pending error into a GC-heap
/// exception Value that OUTLIVES the worker thread (its threadlocal Info is
/// about to die). A user `(throw v)` carries the Value directly; a catalog
/// error synthesises an exception with the KIND-DERIVED class (fixing the old
/// agent bug that hardcoded `"ExceptionInfo"`) + the source location (ADR-0120
/// Stage A `allocExceptionLoc`, which dupes message + file into GC storage, so
/// the result points at nothing threadlocal). Returns `.nil_val` only when no
/// error was pending (shouldn't happen at a real catch site).
pub fn capture(rt: *Runtime) Value {
    if (dispatch.last_thrown_exception) |thrown| {
        dispatch.last_thrown_exception = null;
        return thrown;
    }
    if (error_mod.getLastError()) |info| {
        const class = host_class.kindToHostClass(info.kind) orelse "clojure.lang.ExceptionInfo";
        return ex_info.allocExceptionLoc(rt, info.message, class, info.location) catch Value.nil_val;
    }
    return Value.nil_val;
}

/// Consumer-side: re-raise a marshalled exception Value as a thrown exception,
/// so the renderer (`buildThrownInfo`) shows the carried class / message /
/// location — identical to an in-thread throw of the same Value. Always returns
/// `error.ThrownValue` (the value rides `dispatch.last_thrown_exception`).
pub fn reraise(v: Value) anyerror {
    dispatch.last_thrown_exception = v;
    return error.ThrownValue;
}
