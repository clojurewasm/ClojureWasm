//! Primitive registration entry point.
//!
//! `registerAll(env)` runs once at boot (from the runner's setup,
//! after `Env.init` and `tree_walk.installVTable`). It:
//!
//!   1. Looks up the `rt` namespace (created by `Env.init`).
//!   2. Calls each primitive module's `register(env, rt_ns)` so they
//!      `intern` themselves under rt/.
//!   3. Refers all rt mappings into `user` via `Env.referAll`. This
//!      boot-time rt → user refer is the deliberate REPL convenience
//!      (see L132 + ADR-0035 D9): `require`/`(ns …)` semantics are
//!      implemented and do NOT auto-refer rt.
//!
//! The `const … = @import("primitive/…")` block below is the
//! authoritative module inventory; `registerAll` invokes each in
//! order. Add a module by importing it and adding a `try
//! X.register(…)` line.

const std = @import("std");
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const Value = @import("../runtime/value/value.zig").Value;

const math = @import("primitive/math.zig");
const core = @import("primitive/core.zig");
const sequence = @import("primitive/sequence.zig");
const collection = @import("primitive/collection.zig");
const transient_prim = @import("primitive/transient.zig");
const edn_prim = @import("primitive/edn.zig");
const json_prim = @import("primitive/json.zig");
const csv_prim = @import("primitive/csv.zig");
const higher_order = @import("primitive/higher_order.zig");
const error_prim = @import("primitive/error.zig");
const uuid = @import("primitive/uuid.zig");
const inst = @import("primitive/inst.zig");
const file_io_prim = @import("primitive/file_io.zig");
const host_stream = @import("../runtime/io/host_stream.zig");
const regex_prim = @import("primitive/regex.zig");
const string_prim = @import("primitive/string.zig");
const set_prim = @import("primitive/set.zig");
const walk_prim = @import("primitive/walk.zig");
const multimethod_prim = @import("primitive/multimethod.zig");
const protocol_prim = @import("primitive/protocol.zig");
const stm_prim = @import("primitive/stm.zig");
const locking_prim = @import("primitive/locking.zig");
const agent_prim = @import("primitive/agent.zig");
const atom_prim = @import("primitive/atom.zig");
const metadata_prim = @import("primitive/metadata.zig");
const sorted_prim = @import("primitive/sorted.zig");
const reduced_prim = @import("primitive/reduced.zig");
const namespace_prim = @import("primitive/namespace.zig");
const macroexpand_prim = @import("primitive/macroexpand.zig");
const array_prim = @import("primitive/array.zig");

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
    // clojure.core/read-string — in cljw the reader has no `#=` eval-reader,
    // so core/read-string is the same full-reader readOne→formToValue as
    // clojure.edn/read-string (a safe DIVERGENCE: JVM core/read-string can
    // eval). Reuse the edn impl, interned into rt (→ referred into user).
    _ = try env.intern(rt_ns, "read-string", Value.initBuiltinFn(&edn_prim.readStringFn), null);
    try json_prim.register(env);
    try csv_prim.register(env);
    try higher_order.register(env, rt_ns, clojure_core_ns);
    try error_prim.register(env, rt_ns);
    try uuid.register(env, rt_ns);
    try inst.register(env, rt_ns);
    try file_io_prim.register(env, rt_ns);
    try host_stream.register(env, rt_ns);
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
    try locking_prim.register(env, rt_ns);
    try agent_prim.register(env, rt_ns);
    try atom_prim.register(env, rt_ns);
    try metadata_prim.register(env, rt_ns);
    try sorted_prim.register(env, rt_ns);
    try reduced_prim.register(env, rt_ns);
    try namespace_prim.register(env, rt_ns); // ADR-0083 ns-reflection
    try macroexpand_prim.register(env, rt_ns); // D-229 macroexpand-1/macroexpand
    try array_prim.register(env, rt_ns); // ADR-0105 / D-287 Java arrays

    // Phase 14 row 14.1 (D-079 discharge): walk every
    // `runtime/java/<pkg>/<Class>.zig`'s `___HOST_EXTENSION`
    // declaration, create its cljw_ns, register its TypeDescriptor.
    // ADR-0029 D5 aggregator; F-009 thin-wrapper invariant.
    try @import("../runtime/java/_host_api.zig").installAll(env);
    // ADR-0098: the cljw-original surface aggregator (cljw.http.server / .client).
    try @import("../runtime/cljw/_host_api.zig").installAll(env);

    // ADR-0087: register the clojure.lang.PersistentQueue surface descriptor
    // (carries the EMPTY static field) directly — it is not a java/ surface
    // file (zone: collection/ cannot import java/_host_api), so it registers
    // its own rt.types entry here.
    try @import("../runtime/collection/persistent_queue.zig").registerType(env.rt);

    // ADR-0050 am1: populate native-type instance method tables (String, …)
    // on the per-Runtime native descriptors. Distinct from installAll's
    // static `rt.types` descriptors — `(.toUpperCase s)` dispatches on the
    // receiver's runtime tag via `rt.nativeDescriptor(.string)`.
    try @import("../runtime/java/lang/String.zig").installNativeMethods(env.rt);
    // D-198: java.lang.Throwable read accessors (.getMessage/.getCause/
    // .getData) on the `.ex_info` native descriptor — the high-frequency
    // catch-body pattern. Both backends resolve via receiverDescriptor.
    try @import("../runtime/java/lang/Throwable.zig").installNativeMethods(env.rt);
    // D-311: java.lang.Class instance methods (.isArray/.getName/.getSimpleName/
    // .isInstance) on the `.type_descriptor` native descriptor — the value
    // `(class x)` returns. Surfaced by clojure.core.unify's `composite?`.
    try @import("../runtime/java/lang/Class.zig").installNativeMethods(env.rt);
    // D-232: `.name`/`.getName`/`.toString` interop on the Namespace `.ns` value.
    try @import("../runtime/namespace_methods.zig").installNativeMethods(env.rt);
    // `.sym` interop on the `.keyword` value (clojure.lang.Keyword) — honeysql's
    // `sql-kw` does `(.sym ^clojure.lang.Keyword k)`.
    try @import("../runtime/keyword_methods.zig").installNativeMethods(env.rt);
    // `(.matcher re s)` on the `.regex` value (java.util.regex.Pattern) —
    // clojure.core/re-matcher's body; instaparse's re-match-at-front.
    try @import("../runtime/java/util/regex/Pattern.zig").installNativeMethods(env.rt);

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
