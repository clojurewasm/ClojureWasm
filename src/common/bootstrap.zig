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
const Compiler = @import("bytecode/compiler.zig").Compiler;
const VM = @import("../native/vm/vm.zig").VM;

/// Bootstrap error type.
pub const BootstrapError = error{
    ReadError,
    AnalyzeError,
    EvalError,
    CompileError,
    OutOfMemory,
};

/// Embedded core.clj source (compiled into binary).
const core_clj_source = @embedFile("../clj/core.clj");

/// Load and evaluate core.clj in the given Env.
/// Called after registerBuiltins to define core macros (defn, when, etc.).
/// Temporarily switches to clojure.core namespace so macros are defined there,
/// then re-refers them into user namespace.
pub fn loadCore(allocator: Allocator, env: *Env) BootstrapError!void {
    const core_ns = env.findNamespace("clojure.core") orelse return error.EvalError;

    // Save current namespace and switch to clojure.core
    const saved_ns = env.current_ns;
    env.current_ns = core_ns;

    // Evaluate core.clj (defines macros/functions in clojure.core)
    _ = try evalString(allocator, env, core_clj_source);

    // Restore user namespace and re-refer all core bindings
    env.current_ns = saved_ns;
    if (saved_ns) |user_ns| {
        var iter = core_ns.mappings.iterator();
        while (iter.next()) |entry| {
            user_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
    }
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
    // Note: tw is intentionally not deinit'd here because closures created
    // during evaluation may be def'd into Vars and must outlive this scope.
    // Memory is owned by the arena allocator passed in.
    var tw = TreeWalk.initWithEnv(allocator, env);

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

/// Evaluate source via Compiler + VM pipeline.
/// Macros are still expanded via TreeWalk (macroEvalBridge), but evaluation
/// uses the bytecode compiler and VM. Supports calling TreeWalk-defined
/// closures (from loadCore) via fn_val_dispatcher.
pub fn evalStringVM(allocator: Allocator, env: *Env, source: []const u8) BootstrapError!Value {
    var error_ctx: err.ErrorContext = .{};

    // Parse all top-level forms
    var reader = Reader.init(allocator, source, &error_ctx);
    const forms = reader.readAll() catch return error.ReadError;

    if (forms.len == 0) return .nil;

    // Set env for macro expansion bridge
    const prev_env = macro_eval_env;
    macro_eval_env = env;
    defer macro_eval_env = prev_env;

    var last_value: Value = .nil;

    for (forms) |form| {
        // Analyze with macro expansion support (same as evalString)
        var analyzer = Analyzer.initWithMacroEval(
            allocator,
            &error_ctx,
            env,
            &macroEvalBridge,
        );
        defer analyzer.deinit();

        const node = analyzer.analyze(form) catch return error.AnalyzeError;

        // Compile Node -> bytecode
        var compiler = Compiler.init(allocator);
        defer compiler.deinit();
        compiler.compile(node) catch return error.CompileError;
        compiler.chunk.emitOp(.ret) catch return error.CompileError;

        // Execute via VM
        var vm = VM.initWithEnv(allocator, env);
        defer vm.deinit();
        vm.fn_val_dispatcher = &macroEvalBridge;
        last_value = vm.run(&compiler.chunk) catch return error.EvalError;
    }

    return last_value;
}

/// Bridge function: called by Analyzer to execute fn_val macros via TreeWalk.
/// Also used by VM as fn_val_dispatcher for TreeWalk closures.
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

/// Test helper: evaluate expression and check integer result.
fn expectEvalInt(alloc: std.mem.Allocator, env: *Env, source: []const u8, expected: i64) !void {
    const result = try evalString(alloc, env, source);
    try testing.expectEqual(Value{ .integer = expected }, result);
}

/// Test helper: evaluate expression and check boolean result.
fn expectEvalBool(alloc: std.mem.Allocator, env: *Env, source: []const u8, expected: bool) !void {
    const result = try evalString(alloc, env, source);
    try testing.expectEqual(Value{ .boolean = expected }, result);
}

/// Test helper: evaluate expression and check nil result.
fn expectEvalNil(alloc: std.mem.Allocator, env: *Env, source: []const u8) !void {
    const result = try evalString(alloc, env, source);
    try testing.expectEqual(Value.nil, result);
}

/// Test helper: evaluate expression and check string result.
fn expectEvalStr(alloc: std.mem.Allocator, env: *Env, source: []const u8, expected: []const u8) !void {
    const result = try evalString(alloc, env, source);
    try testing.expectEqualStrings(expected, result.string);
}

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

test "evalString - higher-order function call" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Pass fn as argument and call it
    const result = try evalString(alloc, &env,
        \\(defn apply1 [f x] (f x))
        \\(defn inc [x] (+ x 1))
        \\(apply1 inc 41)
    );
    try testing.expectEqual(Value{ .integer = 42 }, result);
}

test "evalString - loop/recur" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Sum 1..10 using loop/recur
    const result = try evalString(alloc, &env,
        \\(loop [i 0 sum 0]
        \\  (if (= i 10)
        \\    sum
        \\    (recur (+ i 1) (+ sum i))))
    );
    try testing.expectEqual(Value{ .integer = 45 }, result);
}

test "core.clj - next returns nil for empty" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // next of single-element list should be nil
    const r1 = try evalString(alloc, &env, "(next (list 1))");
    try testing.expectEqual(Value.nil, r1);

    // next of multi-element list should be non-nil
    const r2 = try evalString(alloc, &env, "(next (list 1 2))");
    try testing.expect(r2 == .list);
}

test "core.clj - map" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    _ = try evalString(alloc, &env, "(defn inc [x] (+ x 1))");
    const result = try evalString(alloc, &env, "(map inc (list 1 2 3))");
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 3), result.list.items.len);
    try testing.expectEqual(Value{ .integer = 2 }, result.list.items[0]);
    try testing.expectEqual(Value{ .integer = 3 }, result.list.items[1]);
    try testing.expectEqual(Value{ .integer = 4 }, result.list.items[2]);
}

test "core.clj - filter" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    _ = try evalString(alloc, &env, "(defn even? [x] (= 0 (rem x 2)))");
    const result = try evalString(alloc, &env, "(filter even? (list 1 2 3 4 5 6))");
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 3), result.list.items.len);
    try testing.expectEqual(Value{ .integer = 2 }, result.list.items[0]);
    try testing.expectEqual(Value{ .integer = 4 }, result.list.items[1]);
    try testing.expectEqual(Value{ .integer = 6 }, result.list.items[2]);
}

test "core.clj - reduce" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // reduce using core.clj definition
    _ = try evalString(alloc, &env, "(defn add [a b] (+ a b))");
    const result = try evalString(alloc, &env, "(reduce add 0 (list 1 2 3))");
    try testing.expectEqual(Value{ .integer = 6 }, result);
}

test "core.clj - take" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const result = try evalString(alloc, &env, "(take 2 (list 1 2 3 4 5))");
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 2), result.list.items.len);
    try testing.expectEqual(Value{ .integer = 1 }, result.list.items[0]);
    try testing.expectEqual(Value{ .integer = 2 }, result.list.items[1]);
}

test "core.clj - drop" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const result = try evalString(alloc, &env, "(drop 2 (list 1 2 3 4 5))");
    try testing.expect(result == .list);
    try testing.expectEqual(@as(usize, 3), result.list.items.len);
    try testing.expectEqual(Value{ .integer = 3 }, result.list.items[0]);
    try testing.expectEqual(Value{ .integer = 4 }, result.list.items[1]);
    try testing.expectEqual(Value{ .integer = 5 }, result.list.items[2]);
}

test "core.clj - comment" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const result = try evalString(alloc, &env, "(comment 1 2 3)");
    try testing.expectEqual(Value.nil, result);
}

test "core.clj - cond" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // First branch true
    const r1 = try evalString(alloc, &env,
        \\(cond
        \\  true 1
        \\  true 2)
    );
    try testing.expectEqual(Value{ .integer = 1 }, r1);

    // Second branch true
    const r2 = try evalString(alloc, &env,
        \\(cond
        \\  false 1
        \\  true 2)
    );
    try testing.expectEqual(Value{ .integer = 2 }, r2);

    // No branch matches -> nil
    const r3 = try evalString(alloc, &env,
        \\(cond
        \\  false 1
        \\  false 2)
    );
    try testing.expectEqual(Value.nil, r3);
}

test "core.clj - if-not" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const r1 = try evalString(alloc, &env, "(if-not false 1 2)");
    try testing.expectEqual(Value{ .integer = 1 }, r1);

    const r2 = try evalString(alloc, &env, "(if-not true 1 2)");
    try testing.expectEqual(Value{ .integer = 2 }, r2);
}

test "core.clj - when-not" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const r1 = try evalString(alloc, &env, "(when-not false 42)");
    try testing.expectEqual(Value{ .integer = 42 }, r1);

    const r2 = try evalString(alloc, &env, "(when-not true 42)");
    try testing.expectEqual(Value.nil, r2);
}

test "core.clj - and/or" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // and
    const a1 = try evalString(alloc, &env, "(and true true)");
    try testing.expectEqual(Value{ .boolean = true }, a1);
    const a2 = try evalString(alloc, &env, "(and true false)");
    try testing.expectEqual(Value{ .boolean = false }, a2);
    const a3 = try evalString(alloc, &env, "(and nil 42)");
    try testing.expectEqual(Value.nil, a3);
    const a4 = try evalString(alloc, &env, "(and 1 2 3)");
    try testing.expectEqual(Value{ .integer = 3 }, a4);

    // or
    const o1 = try evalString(alloc, &env, "(or nil false 42)");
    try testing.expectEqual(Value{ .integer = 42 }, o1);
    const o2 = try evalString(alloc, &env, "(or nil false)");
    try testing.expectEqual(Value{ .boolean = false }, o2);
    const o3 = try evalString(alloc, &env, "(or 1 2)");
    try testing.expectEqual(Value{ .integer = 1 }, o3);
}

test "core.clj - identity/constantly/complement" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const r1 = try evalString(alloc, &env, "(identity 42)");
    try testing.expectEqual(Value{ .integer = 42 }, r1);

    const r2 = try evalString(alloc, &env, "((constantly 99) 1 2 3)");
    try testing.expectEqual(Value{ .integer = 99 }, r2);

    const r3 = try evalString(alloc, &env, "((complement nil?) 42)");
    try testing.expectEqual(Value{ .boolean = true }, r3);
    const r4 = try evalString(alloc, &env, "((complement nil?) nil)");
    try testing.expectEqual(Value{ .boolean = false }, r4);
}

test "core.clj - thread-first" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    _ = try evalString(alloc, &env, "(defn inc [x] (+ x 1))");
    _ = try evalString(alloc, &env, "(defn double [x] (* x 2))");

    // (-> 5 inc double) => (double (inc 5)) => 12
    const r1 = try evalString(alloc, &env, "(-> 5 inc double)");
    try testing.expectEqual(Value{ .integer = 12 }, r1);
}

test "core.clj - thread-last" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // (->> (list 1 2 3) (map inc)) with inline inc
    _ = try evalString(alloc, &env, "(defn inc [x] (+ x 1))");
    const r1 = try evalString(alloc, &env, "(->> (list 1 2 3) (map inc))");
    try testing.expect(r1 == .list);
    try testing.expectEqual(@as(usize, 3), r1.list.items.len);
    try testing.expectEqual(Value{ .integer = 2 }, r1.list.items[0]);
}

test "core.clj - defn-" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    _ = try evalString(alloc, &env, "(defn- private-fn [x] (+ x 10))");
    const result = try evalString(alloc, &env, "(private-fn 5)");
    try testing.expectEqual(Value{ .integer = 15 }, result);
}

test "core.clj - dotimes" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // dotimes returns nil (side-effect macro)
    const result = try evalString(alloc, &env, "(dotimes [i 3] i)");
    try testing.expectEqual(Value.nil, result);
}

// =========================================================================
// SCI Tier 1 compatibility tests
// Ported from ClojureWasmBeta test/compat/sci/core_test.clj
// =========================================================================

test "SCI - do" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(do 0 1 2)", 2);
    try expectEvalNil(alloc, &env, "(do 1 2 nil)");
}

test "SCI - if and when" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(let [x 0] (if (zero? x) 1 2))", 1);
    try expectEvalInt(alloc, &env, "(let [x 1] (if (zero? x) 1 2))", 2);
    try expectEvalInt(alloc, &env, "(let [x 0] (when (zero? x) 1))", 1);
    try expectEvalNil(alloc, &env, "(let [x 1] (when (zero? x) 1))");
    try expectEvalInt(alloc, &env, "(when true 0 1 2)", 2);
}

test "SCI - and / or" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalBool(alloc, &env, "(let [x 0] (and false true x))", false);
    try expectEvalInt(alloc, &env, "(let [x 0] (and true true x))", 0);
    try expectEvalInt(alloc, &env, "(let [x 1] (or false false x))", 1);
    try expectEvalBool(alloc, &env, "(let [x false] (or false false x))", false);
    try expectEvalInt(alloc, &env, "(let [x false] (or false false x 3))", 3);
}

test "SCI - fn named recursion" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "((fn foo [x] (if (< x 3) (foo (inc x)) x)) 0)", 3);
}

test "SCI - def" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalStr(alloc, &env,
        \\(do (def foo "nice val") foo)
    , "nice val");
}

test "SCI - defn" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(do (defn my-inc [x] (inc x)) (my-inc 1))", 2);
}

test "SCI - let" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(let [x 2] 1 2 3 x)", 2);
}

test "SCI - closure" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(do (let [x 1] (defn cl-foo [] x)) (cl-foo))", 1);
    try expectEvalInt(alloc, &env,
        "(let [x 1 y 2] ((fn [] (let [g (fn [] y)] (+ x (g))))))", 3);
}

test "SCI - arithmetic" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(+ 1 2)", 3);
    try expectEvalInt(alloc, &env, "(+)", 0);
    try expectEvalInt(alloc, &env, "(* 2 3)", 6);
    try expectEvalInt(alloc, &env, "(*)", 1);
    try expectEvalInt(alloc, &env, "(- 1)", -1);
    try expectEvalInt(alloc, &env, "(mod 10 7)", 3);
}

test "SCI - comparisons" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalBool(alloc, &env, "(= 1 1)", true);
    try expectEvalBool(alloc, &env, "(not= 1 2)", true);
    try expectEvalBool(alloc, &env, "(< 1 2)", true);
    try expectEvalBool(alloc, &env, "(< 1 3 2)", false);
    try expectEvalBool(alloc, &env, "(<= 1 1)", true);
    try expectEvalBool(alloc, &env, "(zero? 0)", true);
    try expectEvalBool(alloc, &env, "(pos? 1)", true);
    try expectEvalBool(alloc, &env, "(neg? -1)", true);
}

test "SCI - sequences" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalBool(alloc, &env, "(= (list 2 3 4) (map inc (list 1 2 3)))", true);
    try expectEvalBool(alloc, &env, "(= (list 2 4) (filter even? (list 1 2 3 4 5)))", true);
    try expectEvalInt(alloc, &env, "(reduce + 0 (list 1 2 3 4))", 10);
    try expectEvalInt(alloc, &env, "(reduce + 5 (list 1 2 3 4))", 15);
    try expectEvalInt(alloc, &env, "(first (list 1 2 3))", 1);
    try expectEvalNil(alloc, &env, "(next (list 1))");
    try expectEvalBool(alloc, &env, "(= (list 1 2) (take 2 (list 1 2 3 4)))", true);
}

test "SCI - string operations" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalStr(alloc, &env,
        \\(str "hello" " " "world")
    , "hello world");
    try expectEvalStr(alloc, &env, "(str)", "");
}

test "SCI - loop/recur" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(let [x 1] (loop [x (inc x)] x))", 2);
    try expectEvalInt(alloc, &env, "(loop [x 0] (if (< x 10000) (recur (inc x)) x))", 10000);
    try expectEvalInt(alloc, &env, "((fn foo [x] (if (= 72 x) x (foo (inc x)))) 0)", 72);
}

test "SCI - cond" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(let [x 2] (cond (string? x) 1 true 2))", 2);
}

test "SCI - comment" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalNil(alloc, &env, "(comment (+ 1 2 (* 3 4)))");
}

test "SCI - threading macros" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(let [x 1] (-> x inc inc (inc)))", 4);
}

test "SCI - quoting" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalBool(alloc, &env, "(= (list 1 2 3) '(1 2 3))", true);
}

test "SCI - defn-" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(do (defn- priv-fn [] 42) (priv-fn))", 42);
}

// === VM eval tests ===

/// Test helper: evaluate expression via VM and check integer result.
fn expectVMEvalInt(alloc: std.mem.Allocator, env: *Env, source: []const u8, expected: i64) !void {
    const result = try evalStringVM(alloc, env, source);
    try testing.expectEqual(Value{ .integer = expected }, result);
}

test "evalStringVM - basic arithmetic" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    try expectVMEvalInt(alloc, &env, "(+ 1 2 3)", 6);
    try expectVMEvalInt(alloc, &env, "(- 10 3)", 7);
    try expectVMEvalInt(alloc, &env, "(* 4 5)", 20);
}

test "evalStringVM - calls core.clj fn (inc)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // inc is defined in core.clj as (defn inc [x] (+ x 1))
    // VM should call the TreeWalk closure via fn_val_dispatcher
    try expectVMEvalInt(alloc, &env, "(inc 5)", 6);
}

test "evalStringVM - uses core macro (when)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // when is a macro — expanded at analyze time, so VM just sees (if ...)
    try expectVMEvalInt(alloc, &env, "(when true 42)", 42);
}

test "evalStringVM - def and call fn" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Inline fn call (no def)
    try expectVMEvalInt(alloc, &env, "((fn [x] (* x 2)) 21)", 42);
}

test "evalStringVM - defn and call" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // defn macro expands to (def double (fn double [x] (* x 2)))
    // VM compiles and executes the def, then calls the VM-compiled closure
    try expectVMEvalInt(alloc, &env, "(do (defn double [x] (* x 2)) (double 21))", 42);
}

test "evalStringVM - loop/recur" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectVMEvalInt(alloc, &env,
        "(loop [x 0] (if (< x 5) (recur (+ x 1)) x))", 5);
}

test "evalStringVM - higher-order fn (map via dispatcher)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // map is a TreeWalk closure from core.clj; inc is also a TW closure
    // VM should dispatch both through fn_val_dispatcher
    try expectVMEvalInt(alloc, &env, "(count (map inc [1 2 3]))", 3);
}
