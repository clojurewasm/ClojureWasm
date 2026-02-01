// Bootstrap — loads and evaluates core.clj to register macros and core functions.
//
// Pipeline: source string -> Reader -> Forms -> Analyzer -> Nodes -> TreeWalk eval
// Each top-level form is analyzed and evaluated sequentially.
// defmacro forms register macros in the Env for use by subsequent forms.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = @import("reader/reader.zig").Reader;
const Form = @import("reader/form.zig").Form;
const Analyzer = @import("analyzer/analyzer.zig").Analyzer;
const Node = @import("analyzer/node.zig").Node;
const Value = @import("value.zig").Value;
const Env = @import("env.zig").Env;
const err = @import("error.zig");
const TreeWalk = @import("../native/evaluator/tree_walk.zig").TreeWalk;

/// Bootstrap error type.
pub const BootstrapError = error{
    ReadError,
    AnalyzeError,
    EvalError,
    OutOfMemory,
};

/// Embedded core.clj source (compiled into binary).
const core_clj_source = @embedFile("../clj/core.clj");

/// Load and evaluate core.clj in the given Env.
/// Called after registerBuiltins to define core macros (defn, when, etc.).
/// Temporarily switches to clojure.core namespace so macros are defined there,
/// then re-refers them into user namespace.
pub fn loadCore(allocator: Allocator, env: *Env) BootstrapError!void {
    // Save current namespace and switch to clojure.core
    const saved_ns = env.current_ns;
    env.current_ns = env.findNamespace("clojure.core") orelse return error.EvalError;

    // Evaluate core.clj (defines macros in clojure.core)
    _ = try evalString(allocator, env, core_clj_source);

    // Re-refer new core bindings into user namespace
    if (saved_ns) |user_ns| {
        const core_ns = env.current_ns.?;
        // Refer any macro Vars defined by core.clj
        const macro_names = [_][]const u8{ "defn", "when" };
        for (macro_names) |name| {
            if (core_ns.resolve(name)) |v| {
                user_ns.refer(name, v) catch {};
            }
        }
    }

    // Restore user namespace
    env.current_ns = saved_ns;
}

/// Evaluate a source string in the given Env.
/// Reads, analyzes, and evaluates each top-level form sequentially.
/// Returns the value of the last form, or nil if source is empty.
pub fn evalString(allocator: Allocator, env: *Env, source: []const u8) BootstrapError!Value {
    // Create error context (shared by reader and analyzer)
    var error_ctx: err.ErrorContext = .{};

    // Parse all top-level forms
    var reader = Reader.init(allocator, source, &error_ctx);
    const forms = reader.readAll() catch return error.ReadError;

    if (forms.len == 0) return .nil;

    // Create a TreeWalk instance for:
    //   1. Evaluating each top-level form
    //   2. Providing macro_eval_fn for fn_val macros during analysis
    var tw = TreeWalk.initWithEnv(allocator, env);
    defer tw.deinit();

    // Set env for macro expansion bridge
    const prev_env = macro_eval_env;
    macro_eval_env = env;
    defer macro_eval_env = prev_env;

    var last_value: Value = .nil;

    for (forms) |form| {
        // Analyze with macro expansion support
        var analyzer = Analyzer.initWithMacroEval(
            allocator,
            &error_ctx,
            env,
            &macroEvalBridge,
        );
        defer analyzer.deinit();

        const node = analyzer.analyze(form) catch return error.AnalyzeError;

        // Evaluate
        last_value = tw.run(node) catch return error.EvalError;
    }

    return last_value;
}

/// Bridge function: called by Analyzer to execute fn_val macros via TreeWalk.
/// Uses thread-local env reference set by evalString.
fn macroEvalBridge(allocator: Allocator, fn_val: Value, args: []const Value) anyerror!Value {
    var tw = if (macro_eval_env) |env|
        TreeWalk.initWithEnv(allocator, env)
    else
        TreeWalk.init(allocator);
    defer tw.deinit();
    return tw.callValue(fn_val, args);
}

/// Env reference for macro expansion bridge. Set during evalString.
var macro_eval_env: ?*Env = null;

// === Tests ===

const testing = std.testing;
const registry = @import("builtin/registry.zig");

test "evalString - simple constant" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    const result = try evalString(alloc, &env, "42");
    try testing.expectEqual(Value{ .integer = 42 }, result);
}

test "evalString - function call" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    const result = try evalString(alloc, &env, "(+ 1 2)");
    try testing.expectEqual(Value{ .integer = 3 }, result);
}

test "evalString - multiple forms returns last" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    const result = try evalString(alloc, &env, "1 2 3");
    try testing.expectEqual(Value{ .integer = 3 }, result);
}

test "evalString - def + reference" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    const result = try evalString(alloc, &env, "(def x 10) (+ x 5)");
    try testing.expectEqual(Value{ .integer = 15 }, result);
}

test "evalString - defmacro and macro use" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    // Define a macro: (defmacro my-const [x] x)
    // This macro just returns its argument unevaluated (identity macro)
    // Then use it: (my-const 42) -> 42
    const result = try evalString(alloc, &env,
        \\(defmacro my-const [x] x)
        \\(my-const 42)
    );
    try testing.expectEqual(Value{ .integer = 42 }, result);
}

test "evalString - defn macro from core" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    // Step 1: define defn macro
    const r1 = try evalString(alloc, &env,
        \\(defmacro defn [name & fdecl]
        \\  `(def ~name (fn ~name ~@fdecl)))
    );
    _ = r1;

    // Step 2: use defn macro
    const r2 = try evalString(alloc, &env,
        \\(defn add1 [x] (+ x 1))
    );
    _ = r2;

    // Step 3: call defined function
    const result = try evalString(alloc, &env,
        \\(add1 10)
    );
    try testing.expectEqual(Value{ .integer = 11 }, result);
}

test "evalString - when macro" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    // Define when macro
    _ = try evalString(alloc, &env,
        \\(defmacro when [test & body]
        \\  `(if ~test (do ~@body)))
    );

    // when true -> returns body result
    const r1 = try evalString(alloc, &env, "(when true 42)");
    try testing.expectEqual(Value{ .integer = 42 }, r1);

    // when false -> returns nil
    const r2 = try evalString(alloc, &env, "(when false 42)");
    try testing.expectEqual(Value.nil, r2);
}

test "loadCore - core.clj defines defn and when" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    // Load core.clj
    try loadCore(alloc, &env);

    // defn should be available as a macro
    const core = env.findNamespace("clojure.core").?;
    const defn_var = core.resolve("defn");
    try testing.expect(defn_var != null);
    try testing.expect(defn_var.?.isMacro());

    // when should be available as a macro
    const when_var = core.resolve("when");
    try testing.expect(when_var != null);
    try testing.expect(when_var.?.isMacro());

    // Use defn from core.clj
    const result = try evalString(alloc, &env,
        \\(defn double [x] (+ x x))
        \\(double 21)
    );
    try testing.expectEqual(Value{ .integer = 42 }, result);
}
