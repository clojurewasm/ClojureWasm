//! Primitive registration entry point.
//!
//! Phase-2 calls `registerAll(env)` exactly once at startup
//! (typically from `main.zig` after `Env.init` and
//! `tree_walk.installVTable`). It:
//!
//!   1. Looks up the `rt` namespace (created by `Env.init`).
//!   2. Calls each primitive module's `register(env, rt_ns)` so they
//!      `intern` themselves under rt/.
//!   3. Refers all rt mappings into `user` via `Env.referAll`. This
//!      stands in for Clojure's `(refer 'rt)`; Phase 4 replaces it
//!      with the proper `(require ...)` semantics.
//!
//! ### Module list
//!
//! - `primitive/math.zig` — arithmetic + comparison
//! - `primitive/core.zig` — nil? / true? / false? / identical?
//!
//! Phase-3+ will add seq.zig, pred.zig, io.zig, etc. The orchestration
//! shape stays the same — add a `try X.register(...)` line.

const std = @import("std");
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const Runtime = @import("../runtime/runtime.zig").Runtime;

const math = @import("primitive/math.zig");
const core = @import("primitive/core.zig");
const sequence = @import("primitive/sequence.zig");
const collection = @import("primitive/collection.zig");
const transient_prim = @import("primitive/transient.zig");
const edn_prim = @import("primitive/edn.zig");
const json_prim = @import("primitive/json.zig");
const csv_prim = @import("primitive/csv.zig");
const cli_prim = @import("primitive/cli.zig");
const test_assert_prim = @import("primitive/test_assert.zig");
const higher_order = @import("primitive/higher_order.zig");
const error_prim = @import("primitive/error.zig");
const uuid = @import("primitive/uuid.zig");
const file_io_prim = @import("primitive/file_io.zig");
const regex_prim = @import("primitive/regex.zig");
const string_prim = @import("primitive/string.zig");
const set_prim = @import("primitive/set.zig");
const walk_prim = @import("primitive/walk.zig");
const multimethod_prim = @import("primitive/multimethod.zig");
const protocol_prim = @import("primitive/protocol.zig");
const stm_prim = @import("primitive/stm.zig");

pub const RegisterError = error{
    RtNamespaceMissing,
    UserNamespaceMissing,
    ClojureCoreNamespaceMissing,
    OutOfMemory,
};

/// Register every Phase-2 rt/ primitive and refer them into user/.
/// Idempotent because every step underneath (intern + referAll) is.
pub fn registerAll(env: *Env) !void {
    const rt_ns = env.findNs("rt") orelse return RegisterError.RtNamespaceMissing;
    const user_ns = env.findNs("user") orelse return RegisterError.UserNamespaceMissing;
    const clojure_core_ns = env.findNs("clojure.core") orelse return RegisterError.ClojureCoreNamespaceMissing;

    try math.register(env, rt_ns);
    try core.register(env, rt_ns);
    try sequence.register(env, rt_ns);
    try collection.register(env, rt_ns);
    try transient_prim.register(env, rt_ns);
    try edn_prim.register(env);
    try json_prim.register(env);
    try csv_prim.register(env);
    try cli_prim.register(env);
    try test_assert_prim.register(env);
    try higher_order.register(env, rt_ns, clojure_core_ns);
    try error_prim.register(env, rt_ns);
    try uuid.register(env, rt_ns);
    try file_io_prim.register(env, rt_ns);
    try regex_prim.register(env, rt_ns);

    // clojure.string namespace surface (ADR-0032 + ADR-0029). Creates
    // the `clojure.string` namespace + interns cycle-1 vars; the
    // bootstrap loader later runs `string.clj` which opens with
    // `(in-ns 'clojure.string)` and finds an already-populated ns.
    try string_prim.register(env);
    try set_prim.register(env);
    try walk_prim.register(env);
    try multimethod_prim.register(env, rt_ns);
    try protocol_prim.register(env, rt_ns);
    try stm_prim.register(env, rt_ns);

    // Phase 14 row 14.1 (D-079 discharge): walk every
    // `runtime/java/<pkg>/<Class>.zig`'s `___HOST_EXTENSION`
    // declaration, create its cljw_ns, register its TypeDescriptor.
    // ADR-0029 D5 aggregator; F-009 thin-wrapper invariant.
    try @import("../runtime/java/_host_api.zig").installAll(env);

    // ADR-0050 am1: populate native-type instance method tables (String, …)
    // on the per-Runtime native descriptors. Distinct from installAll's
    // static `rt.types` descriptors — `(.toUpperCase s)` dispatches on the
    // receiver's runtime tag via `rt.nativeDescriptor(.string)`.
    try @import("../runtime/java/lang/String.zig").installNativeMethods(env.rt);

    // ADR-0035 D9 (sub-cycle d): boot-time rt → user refer makes
    // primitives (`+`, `=`, `count`, ...) reachable unqualified at
    // the REPL prompt. The `(ns foo (:refer-clojure))` macro does NOT
    // refer rt into the entering ns; explicit `(require '[rt …])` is
    // not a stable surface, so `user/` retains the rt refer at boot.
    try env.referAll(rt_ns, user_ns);
}

// --- tests ---

const testing = std.testing;

test "registerAll installs every Phase-2 primitive in rt/" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try Env.init(&rt);
    defer env.deinit();

    try registerAll(&env);
    const rt_ns = env.findNs("rt").?;

    // Math (sample)
    try testing.expect(rt_ns.resolve("+") != null);
    try testing.expect(rt_ns.resolve("=") != null);
    try testing.expect(rt_ns.resolve("<") != null);
    // Core (sample)
    try testing.expect(rt_ns.resolve("nil?") != null);
    try testing.expect(rt_ns.resolve("identical?") != null);
    // Regex (sample — ADR-0031 cycle 1c.2)
    try testing.expect(rt_ns.resolve("re-pattern") != null);
    try testing.expect(rt_ns.resolve("re-find") != null);
    try testing.expect(rt_ns.resolve("re-matches") != null);
}

test "registerAll refers rt/ into user/ so + resolves unqualified" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try Env.init(&rt);
    defer env.deinit();

    try registerAll(&env);
    const user_ns = env.findNs("user").?;

    // Reachable via refers — user does NOT own the Var itself.
    try testing.expect(user_ns.resolve("+") != null);
    try testing.expect(!user_ns.mappings.contains("+"));
    try testing.expect(user_ns.refers.contains("+"));
}

test "registerAll is idempotent (re-running does not double-insert)" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    var env = try Env.init(&rt);
    defer env.deinit();

    try registerAll(&env);
    const user_ns = env.findNs("user").?;
    const refer_count = user_ns.refers.count();

    try registerAll(&env);
    try testing.expectEqual(refer_count, user_ns.refers.count());
}

test "registerAll fails cleanly when the rt namespace is missing" {
    // Construct a half-baked Env where `rt` ns has been removed. We
    // do this by skipping Env.init's bootstrap — manually construct.
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    var env = Env{ .rt = &rt, .alloc = rt.gpa };
    defer env.deinit();
    // No rt / user namespaces created → registerAll must error out.

    try testing.expectError(RegisterError.RtNamespaceMissing, registerAll(&env));
}
