// SPDX-License-Identifier: EPL-2.0
//! `clojure.test/is` minimum surface (§9.13 row 11.2).
//!
//! cw v1 cycle-1 surface: `(is expr)` evaluates `expr` and returns
//! `true` when truthy, `false` when falsy. Future cycles add the
//! 2-arg `(is expr msg)` form + the `=` / `thrown?` predicates the
//! JVM `is` macro recognises as special.
//!
//! Why a Zig primitive (not a Pattern A `.clj` defn): cw v1's
//! user-defined `defmacro` raises `user_macro_not_supported`
//! (D-099), so `is` cannot be a macro that captures source for
//! failure reporting. The simplest viable surface — return-bool +
//! no source capture — works fine for `test_clj` Tier A gate
//! "count passes vs fails" semantics. Source-capturing `is` lands
//! when D-099 closes.
//!
//! `deftest` + `run-tests` are deferred to D-099 — without user
//! defmacro support, `deftest` requires a new special form.
//! Users write `(defn test-foo [] (clojure.test/is ...))` +
//! `(test-foo)` to run a test manually.

const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");

/// Implements clojure.test/is (1-arity minimum).
/// Spec: `(is expr)` — returns `true` when `expr` is truthy
///   (not nil, not false), `false` otherwise. Future
///   2-arity `(is expr msg)` + JVM-style predicate
///   pattern-matching (`(= ...)` / `(thrown? ...)`) lands per D-099.
/// JVM reference: clojure.test/is
/// cw v1 tier: A (Phase 11 row 11.2)
pub fn isFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("is", args, 1, loc);
    return if (isTruthy(args[0])) Value.true_val else Value.false_val;
}

fn isTruthy(v: Value) bool {
    return !(v.isNil() or v == Value.false_val);
}

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "is", .f = &isFn },
};

pub fn register(env: *Env) !void {
    const ns = try env.findOrCreateNs("clojure.test");
    for (ENTRIES) |it| {
        _ = try env.intern(ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
