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
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Env = @import("env.zig").Env;
const err = @import("error.zig");
const TreeWalk = @import("../native/evaluator/tree_walk.zig").TreeWalk;
const atom_mod = @import("builtin/atom.zig");
const chunk_mod = @import("bytecode/chunk.zig");
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

/// Parse source into top-level forms.
fn readForms(allocator: Allocator, source: []const u8, error_ctx: *err.ErrorContext) BootstrapError![]Form {
    var reader = Reader.init(allocator, source, error_ctx);
    return reader.readAll() catch return error.ReadError;
}

/// Save and set macro expansion / lazy-seq realization / fn_val dispatch globals.
/// Returns previous state for restoration via defer.
const MacroEnvState = struct {
    env: ?*Env,
    realize: *const @TypeOf(macroEvalBridge),
    atom_call_fn: ?atom_mod.CallFnType,
};

fn setupMacroEnv(env: *Env) MacroEnvState {
    const prev = MacroEnvState{
        .env = macro_eval_env,
        .realize = value_mod.realize_fn,
        .atom_call_fn = atom_mod.call_fn,
    };
    macro_eval_env = env;
    value_mod.realize_fn = &macroEvalBridge;
    atom_mod.call_fn = &macroEvalBridge;
    return prev;
}

fn restoreMacroEnv(prev: MacroEnvState) void {
    macro_eval_env = prev.env;
    value_mod.realize_fn = prev.realize;
    atom_mod.call_fn = prev.atom_call_fn;
}

/// Analyze a single form with macro expansion support.
fn analyzeForm(allocator: Allocator, error_ctx: *err.ErrorContext, env: *Env, form: Form) BootstrapError!*Node {
    var analyzer = Analyzer.initWithMacroEval(allocator, error_ctx, env, &macroEvalBridge);
    defer analyzer.deinit();
    return analyzer.analyze(form) catch return error.AnalyzeError;
}

/// Evaluate a source string in the given Env.
/// Reads, analyzes, and evaluates each top-level form sequentially.
/// Returns the value of the last form, or nil if source is empty.
pub fn evalString(allocator: Allocator, env: *Env, source: []const u8) BootstrapError!Value {
    var error_ctx: err.ErrorContext = .{};
    const forms = try readForms(allocator, source, &error_ctx);
    if (forms.len == 0) return .nil;

    const prev = setupMacroEnv(env);
    defer restoreMacroEnv(prev);

    // Note: tw is intentionally not deinit'd — closures created during
    // evaluation may be def'd into Vars and must outlive this scope.
    var tw = TreeWalk.initWithEnv(allocator, env);

    var last_value: Value = .nil;
    for (forms) |form| {
        const node = try analyzeForm(allocator, &error_ctx, env, form);
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
    const forms = try readForms(allocator, source, &error_ctx);
    if (forms.len == 0) return .nil;

    const prev = setupMacroEnv(env);
    defer restoreMacroEnv(prev);

    // Accumulate fn allocations across forms so def'd fn_vals survive
    // across Compiler boundaries (fix for use-after-free T9.5.1).
    var retained_protos: std.ArrayList(*const chunk_mod.FnProto) = .empty;
    defer {
        for (retained_protos.items) |proto| {
            allocator.free(proto.code);
            allocator.free(proto.constants);
            allocator.destroy(@constCast(proto));
        }
        retained_protos.deinit(allocator);
    }
    var retained_fns: std.ArrayList(*const value_mod.Fn) = .empty;
    defer {
        for (retained_fns.items) |fn_obj| {
            allocator.destroy(@constCast(fn_obj));
        }
        retained_fns.deinit(allocator);
    }

    var last_value: Value = .nil;
    for (forms) |form| {
        const node = try analyzeForm(allocator, &error_ctx, env, form);

        var compiler = Compiler.init(allocator);
        defer compiler.deinit();
        compiler.compile(node) catch return error.CompileError;
        compiler.chunk.emitOp(.ret) catch return error.CompileError;

        // Detach fn allocations before deinit so they survive for later forms
        const detached = compiler.detachFnAllocations();
        for (detached.fn_protos) |p| {
            retained_protos.append(allocator, p) catch return error.CompileError;
        }
        if (detached.fn_protos.len > 0) allocator.free(detached.fn_protos);
        for (detached.fn_objects) |o| {
            retained_fns.append(allocator, o) catch return error.CompileError;
        }
        if (detached.fn_objects.len > 0) allocator.free(detached.fn_objects);

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
    // Note: tw is NOT deinit'd here — closures created during evaluation
    // (e.g., lazy-seq thunks) must outlive this scope. Memory is owned by
    // the arena allocator, which handles bulk deallocation.
    var tw = if (macro_eval_env) |env|
        TreeWalk.initWithEnv(allocator, env)
    else
        TreeWalk.init(allocator);
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

test "evalStringVM - multi-arity fn" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Multi-arity: select by argument count
    try expectVMEvalInt(alloc, &env, "((fn ([x] x) ([x y] (+ x y))) 5)", 5);
    try expectVMEvalInt(alloc, &env, "((fn ([x] x) ([x y] (+ x y))) 3 4)", 7);
}

test "evalStringVM - def fn then call across forms (T9.5.1)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    // Two separate top-level forms: def creates fn_val in form 1,
    // form 2 calls it. This crosses Compiler boundaries in evalStringVM.
    try expectVMEvalInt(alloc, &env, "(def f (fn [x] (+ x 1))) (f 5)", 6);

    // Multiple defs across forms, then cross-call
    try expectVMEvalInt(alloc, &env,
        "(def add2 (fn [x] (+ x 2))) (def add3 (fn [x] (+ x 3))) (+ (add2 10) (add3 10))",
        25,
    );
}

test "swap! with fn_val closure (T9.5.2)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // swap! with a user-defined closure (fn_val), not a builtin_fn
    try expectEvalInt(alloc, &env,
        "(def a (atom 10)) (swap! a (fn [x] (+ x 5))) @a",
        15,
    );

    // swap! with fn_val and extra args
    try expectEvalInt(alloc, &env,
        "(def b (atom 0)) (swap! b (fn [x y z] (+ x y z)) 3 7) @b",
        10,
    );
}

// =========================================================================
// Destructuring tests (T4.9)
// =========================================================================

test "destructuring - sequential basic" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Basic sequential destructuring in let
    try expectEvalInt(alloc, &env, "(let [[a b] [1 2]] (+ a b))", 3);
    try expectEvalInt(alloc, &env, "(let [[a b c] [10 20 30]] (+ a c))", 40);
}

test "destructuring - sequential rest" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // & rest binding
    try expectEvalInt(alloc, &env, "(let [[a & r] [1 2 3]] a)", 1);
    try expectEvalInt(alloc, &env, "(let [[a & r] [1 2 3]] (count r))", 2);
    try expectEvalInt(alloc, &env, "(let [[a b & r] [1 2 3 4 5]] (first r))", 3);
}

test "destructuring - sequential :as" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // :as whole-collection binding
    try expectEvalInt(alloc, &env, "(let [[a b :as all] [1 2 3]] (count all))", 3);
    try expectEvalInt(alloc, &env, "(let [[a :as all] [10 20]] (+ a (count all)))", 12);
}

test "destructuring - map :keys" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // :keys destructuring
    try expectEvalInt(alloc, &env, "(let [{:keys [a b]} {:a 1 :b 2}] (+ a b))", 3);
    try expectEvalInt(alloc, &env, "(let [{:keys [x]} {:x 42}] x)", 42);
}

test "destructuring - map :or defaults" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // :or default values
    try expectEvalInt(alloc, &env, "(let [{:keys [a] :or {a 99}} {}] a)", 99);
    try expectEvalInt(alloc, &env, "(let [{:keys [a] :or {a 99}} {:a 1}] a)", 1);
}

test "destructuring - map :as" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // :as whole-map binding
    try expectEvalInt(alloc, &env, "(let [{:keys [a] :as m} {:a 1 :b 2}] (+ a (count m)))", 3);
}

test "destructuring - map symbol keys" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // {x :x} style
    try expectEvalInt(alloc, &env, "(let [{x :x y :y} {:x 10 :y 20}] (+ x y))", 30);
}

test "destructuring - fn params" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Sequential destructuring in fn params
    try expectEvalInt(alloc, &env, "((fn [[a b]] (+ a b)) [1 2])", 3);
    // Map destructuring in fn params
    try expectEvalInt(alloc, &env, "((fn [{:keys [x y]}] (+ x y)) {:x 3 :y 4})", 7);
}

test "destructuring - loop" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Sequential destructuring in loop
    try expectEvalInt(alloc, &env, "(loop [[a b] [1 2]] (+ a b))", 3);
}

test "destructuring - nested" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Nested sequential destructuring
    try expectEvalInt(alloc, &env, "(let [[[a b] c] [[1 2] 3]] (+ a b c))", 6);
    // Map inside sequential
    try expectEvalInt(alloc, &env, "(let [[{:keys [x]} y] [{:x 10} 20]] (+ x y))", 30);
}

test "destructuring - VM sequential" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectVMEvalInt(alloc, &env, "(let [[a b] [1 2]] (+ a b))", 3);
    try expectVMEvalInt(alloc, &env, "(let [[a & r] [1 2 3]] a)", 1);
    try expectVMEvalInt(alloc, &env, "(let [[a b :as all] [1 2 3]] (count all))", 3);
}

test "destructuring - VM map" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectVMEvalInt(alloc, &env, "(let [{:keys [a b]} {:a 1 :b 2}] (+ a b))", 3);
    try expectVMEvalInt(alloc, &env, "(let [{:keys [a] :or {a 99}} {}] a)", 99);
}

test "destructuring - VM fn params" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectVMEvalInt(alloc, &env, "((fn [[a b]] (+ a b)) [1 2])", 3);
}

// =========================================================================
// for macro tests (T4.10)
// =========================================================================

test "core.clj - mapcat" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // mapcat: (mapcat (fn [x] (list x x)) [1 2 3]) => (1 1 2 2 3 3)
    try expectEvalInt(alloc, &env, "(count (mapcat (fn [x] (list x x)) [1 2 3]))", 6);
    try expectEvalInt(alloc, &env, "(first (mapcat (fn [x] (list x x)) [1 2 3]))", 1);
}

test "core.clj - for comprehension" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Single binding
    try expectEvalInt(alloc, &env, "(count (for [x [1 2 3]] (* x 2)))", 3);
    try expectEvalInt(alloc, &env, "(first (for [x [1 2 3]] (* x 2)))", 2);
    // Nested bindings: (for [x [1 2] y [10 20]] (+ x y)) => (11 21 12 22)
    try expectEvalInt(alloc, &env, "(count (for [x [1 2] y [10 20]] (+ x y)))", 4);
    try expectEvalInt(alloc, &env, "(first (for [x [1 2] y [10 20]] (+ x y)))", 11);
    // :when modifier
    try expectEvalInt(alloc, &env, "(count (for [x [1 2 3 4 5] :when (odd? x)] x))", 3);
    try expectEvalInt(alloc, &env, "(first (for [x [1 2 3 4 5] :when (odd? x)] x))", 1);
    // :let modifier
    try expectEvalInt(alloc, &env, "(first (for [x [1 2 3] :let [y (* x 10)]] y))", 10);
}

test "defprotocol - basic definition" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // defprotocol should define the protocol and its method vars
    _ = try evalString(alloc, &env, "(defprotocol IGreet (greet [this]))");
    // The method var 'greet' should be resolvable (test by evaluating it)
    // If not defined, this will error
    const greet_val = try evalString(alloc, &env, "greet");
    // It should be a protocol_fn value
    try testing.expect(greet_val == .protocol_fn);

    // extend-type and protocol dispatch
    _ = try evalString(alloc, &env,
        \\(extend-type String IGreet
        \\  (greet [this] (str "Hello, " this "!")))
    );
    try expectEvalStr(alloc, &env,
        \\(greet "World")
    , "Hello, World!");

    // Multiple type implementations
    _ = try evalString(alloc, &env,
        \\(extend-type Integer IGreet
        \\  (greet [this] (str "Number " this)))
    );
    try expectEvalStr(alloc, &env, "(greet 42)", "Number 42");

    // Multi-arity method
    _ = try evalString(alloc, &env, "(defprotocol IAdd (add-to [this x]))");
    _ = try evalString(alloc, &env,
        \\(extend-type Integer IAdd
        \\  (add-to [this x] (+ this x)))
    );
    try expectEvalInt(alloc, &env, "(add-to 10 20)", 30);

    // satisfies?
    try expectEvalBool(alloc, &env, "(satisfies? IGreet \"hello\")", true);
    try expectEvalBool(alloc, &env, "(satisfies? IGreet 42)", true);
    try expectEvalBool(alloc, &env, "(satisfies? IGreet [1 2])", false);
}

test "defrecord - basic constructor" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    _ = try evalString(alloc, &env, "(defrecord Point [x y])");
    try expectEvalInt(alloc, &env, "(:x (->Point 1 2))", 1);
    try expectEvalInt(alloc, &env, "(:y (->Point 1 2))", 2);
}

// =========================================================================
// Phase 6b: core.clj expansion tests (T6.6-T6.10)
// =========================================================================

test "core.clj - get-in" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(get-in {:a {:b 42}} [:a :b])", 42);
    try expectEvalNil(alloc, &env, "(get-in {:a 1} [:b :c])");
}

test "core.clj - assoc-in" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(get-in (assoc-in {} [:a :b] 42) [:a :b])", 42);
}

test "core.clj - update" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(:a (update {:a 1} :a inc))", 2);
}

test "core.clj - update-in" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(get-in (update-in {:a {:b 1}} [:a :b] inc) [:a :b])", 2);
}

test "core.clj - select-keys" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(count (select-keys {:a 1 :b 2 :c 3} [:a :c]))", 2);
    try expectEvalInt(alloc, &env, "(:a (select-keys {:a 1 :b 2} [:a]))", 1);
}

test "core.clj - some" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(some even? [1 2 3])", 2);
    try expectEvalNil(alloc, &env, "(some even? [1 3 5])");
}

test "core.clj - every?" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalBool(alloc, &env, "(every? even? [2 4 6])", true);
    try expectEvalBool(alloc, &env, "(every? even? [2 3 6])", false);
}

test "core.clj - not-every?" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalBool(alloc, &env, "(not-every? even? [2 4 6])", false);
    try expectEvalBool(alloc, &env, "(not-every? even? [2 3 6])", true);
}

test "core.clj - partial" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "((partial + 10) 5)", 15);
    try expectEvalInt(alloc, &env, "((partial + 1 2) 3)", 6);
}

test "core.clj - comp" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "((comp inc inc) 0)", 2);
}

test "core.clj - if-let" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(if-let [x 42] x 0)", 42);
    try expectEvalInt(alloc, &env, "(if-let [x nil] 1 0)", 0);
}

test "core.clj - when-let" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(when-let [x 42] x)", 42);
    try expectEvalNil(alloc, &env, "(when-let [x nil] 42)");
}

test "core.clj - range" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(count (range 5))", 5);
    try expectEvalInt(alloc, &env, "(first (range 3))", 0);
    try expectEvalInt(alloc, &env, "(count (range 2 8))", 6);
}

test "core.clj - empty?" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalBool(alloc, &env, "(empty? [])", true);
    try expectEvalBool(alloc, &env, "(empty? [1])", false);
    try expectEvalBool(alloc, &env, "(empty? nil)", true);
}

test "core.clj - contains?" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalBool(alloc, &env, "(contains? {:a 1} :a)", true);
    try expectEvalBool(alloc, &env, "(contains? {:a 1} :b)", false);
}

test "core.clj - keys and vals" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(count (keys {:a 1 :b 2}))", 2);
    try expectEvalInt(alloc, &env, "(reduce + 0 (vals {:a 1 :b 2}))", 3);
}

test "core.clj - partition" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(count (partition 2 [1 2 3 4 5]))", 2);
    try expectEvalInt(alloc, &env, "(count (first (partition 2 [1 2 3 4])))", 2);
}

test "core.clj - group-by" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(count (group-by even? [1 2 3 4 5]))", 2);
}

test "core.clj - flatten" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(count (flatten [[1 2] [3 [4 5]]]))", 5);
    try expectEvalInt(alloc, &env, "(first (flatten [[1 2] [3]]))", 1);
}

test "core.clj - interleave" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(count (interleave [1 2 3] [4 5 6]))", 6);
    try expectEvalInt(alloc, &env, "(first (interleave [1 2] [3 4]))", 1);
}

test "core.clj - interpose" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(count (interpose 0 [1 2 3]))", 5);
}

test "core.clj - distinct" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(count (distinct [1 2 1 3 2]))", 3);
}

test "core.clj - frequencies" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(get (frequencies [1 1 2 3 3 3]) 3)", 3);
    try expectEvalInt(alloc, &env, "(count (frequencies [1 2 3]))", 3);
}

test "evalString - call depth limit prevents crash" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);

    // Define a non-tail-recursive function
    _ = try evalString(alloc, &env, "(def deep (fn [n] (if (= n 0) 0 (+ 1 (deep (- n 1))))))");

    // Small depth should succeed
    try expectEvalInt(alloc, &env, "(deep 10)", 10);

    // Moderate depth should succeed (within MAX_CALL_DEPTH)
    try expectEvalInt(alloc, &env, "(deep 100)", 100);

    // Exceeding MAX_CALL_DEPTH (512) should return error, not crash
    const result = evalString(alloc, &env, "(deep 520)");
    try testing.expectError(error.EvalError, result);
}

test "core.clj - doto macro" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // doto returns the original value
    try expectEvalInt(alloc, &env, "(doto 42 identity inc)", 42);
}

test "core.clj - as-> macro" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // as-> lets you name the threaded value and place it anywhere
    try expectEvalInt(alloc, &env, "(as-> 1 x (+ x 10) (- x 5))", 6);
    try expectEvalStr(alloc, &env, "(as-> 42 x (str \"value=\" x))", "value=42");
}

test "core.clj - some-> macro" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // some-> threads value through forms, short-circuits on nil
    try expectEvalInt(alloc, &env, "(some-> 1 inc inc)", 3);
    try expectEvalNil(alloc, &env, "(some-> nil inc inc)");
}

test "core.clj - cond-> macro" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // cond-> threads value through forms where condition is true
    try expectEvalInt(alloc, &env, "(cond-> 1 true inc false inc)", 2);
    try expectEvalInt(alloc, &env, "(cond-> 1 true inc true inc)", 3);
}

test "defmulti/defmethod - basic dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Define a multimethod dispatching on :shape key
    _ = try evalString(alloc, &env,
        \\(defmulti area :shape)
        \\(defmethod area :circle [x] (* 3 (:radius x) (:radius x)))
        \\(defmethod area :rect [x] (* (:width x) (:height x)))
    );

    try expectEvalInt(alloc, &env, "(area {:shape :circle :radius 5})", 75);
    try expectEvalInt(alloc, &env, "(area {:shape :rect :width 3 :height 4})", 12);
}

test "defmulti/defmethod - default method" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    _ = try evalString(alloc, &env,
        \\(defmulti greet identity)
        \\(defmethod greet :en [_] "hello")
        \\(defmethod greet :default [_] "hi")
    );

    try expectEvalStr(alloc, &env, "(greet :en)", "hello");
    try expectEvalStr(alloc, &env, "(greet :fr)", "hi");
}

test "try/catch/throw - basic exception" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalStr(alloc, &env,
        \\(try (throw "oops") (catch Exception e (str "caught: " e)))
    , "caught: oops");
}

test "try/catch/throw - no exception" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalInt(alloc, &env, "(try (+ 1 2) (catch Exception e 0))", 3);
}

test "try/catch/throw - throw map value" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalStr(alloc, &env,
        \\(try (throw {:type :err :msg "bad"}) (catch Exception e (:msg e)))
    , "bad");
}

test "ex-info and ex-data" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    try expectEvalStr(alloc, &env,
        \\(try (throw (ex-info "boom" {:code 42}))
        \\  (catch Exception e (ex-message e)))
    , "boom");

    try expectEvalInt(alloc, &env,
        \\(try (throw (ex-info "boom" {:code 42}))
        \\  (catch Exception e (:code (ex-data e))))
    , 42);
}

test "try/catch/finally" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // finally runs but return value is from catch
    try expectEvalStr(alloc, &env,
        \\(try (throw "x") (catch Exception e e) (finally nil))
    , "x");
}

test "lazy-seq - basic" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // lazy-seq wrapping cons produces a seq
    try expectEvalInt(alloc, &env,
        \\(first (lazy-seq (cons 42 nil)))
    , 42);
}

test "lazy-seq - iterate with take" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Define iterate using lazy-seq
    _ = try evalString(alloc, &env,
        \\(defn my-iterate [f x]
        \\  (lazy-seq (cons x (my-iterate f (f x)))))
    );

    try expectEvalInt(alloc, &env, "(first (my-iterate inc 0))", 0);
    try expectEvalInt(alloc, &env, "(first (rest (my-iterate inc 0)))", 1);
    try expectEvalInt(alloc, &env, "(first (rest (rest (my-iterate inc 0))))", 2);
}

test "lazy-seq - take from infinite sequence" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // Build lazy iterate + take
    _ = try evalString(alloc, &env,
        \\(defn my-iterate [f x]
        \\  (lazy-seq (cons x (my-iterate f (f x)))))
    );

    // take 5 from infinite sequence
    const result = try evalString(alloc, &env,
        \\(take 5 (my-iterate inc 0))
    );
    // Should be (0 1 2 3 4) or [0 1 2 3 4]
    try std.testing.expect(result == .list or result == .vector);
}

test "core.clj - mapv" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const result = try evalString(alloc, &env, "(mapv inc [1 2 3])");
    try std.testing.expect(result == .vector);
    try std.testing.expectEqual(@as(usize, 3), result.vector.items.len);
    try std.testing.expectEqual(Value{ .integer = 2 }, result.vector.items[0]);
    try std.testing.expectEqual(Value{ .integer = 3 }, result.vector.items[1]);
    try std.testing.expectEqual(Value{ .integer = 4 }, result.vector.items[2]);
}

test "core.clj - reduce-kv" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // reduce-kv sums values of a map
    const result = try evalString(alloc, &env,
        \\(reduce-kv (fn [acc k v] (+ acc v)) 0 {:a 1 :b 2 :c 3})
    );
    try std.testing.expectEqual(Value{ .integer = 6 }, result);
}

test "core.clj - reduce-kv builds new map" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // reduce-kv that transforms values
    const result = try evalString(alloc, &env,
        \\(reduce-kv (fn [acc k v] (assoc acc k (inc v))) {} {:a 1 :b 2})
    );
    try std.testing.expect(result == .map);
    // Check the map has 2 entries with incremented values
    try std.testing.expectEqual(@as(usize, 2), result.map.count());
}

test "core.clj - filterv" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    _ = try evalString(alloc, &env, "(defn even? [x] (= 0 (rem x 2)))");
    const result = try evalString(alloc, &env, "(filterv even? [1 2 3 4 5 6])");
    try std.testing.expect(result == .vector);
    try std.testing.expectEqual(@as(usize, 3), result.vector.items.len);
    try std.testing.expectEqual(Value{ .integer = 2 }, result.vector.items[0]);
    try std.testing.expectEqual(Value{ .integer = 4 }, result.vector.items[1]);
    try std.testing.expectEqual(Value{ .integer = 6 }, result.vector.items[2]);
}

test "core.clj - partition-all" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // partition-all includes trailing incomplete chunk
    const result = try evalString(alloc, &env, "(partition-all 3 [1 2 3 4 5])");
    try std.testing.expect(result == .list);
    try std.testing.expectEqual(@as(usize, 2), result.list.items.len);
    // First chunk: (1 2 3)
    const chunk1 = result.list.items[0];
    try std.testing.expect(chunk1 == .list);
    try std.testing.expectEqual(@as(usize, 3), chunk1.list.items.len);
    // Second chunk: (4 5) — incomplete
    const chunk2 = result.list.items[1];
    try std.testing.expect(chunk2 == .list);
    try std.testing.expectEqual(@as(usize, 2), chunk2.list.items.len);
}

test "core.clj - take-while" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    _ = try evalString(alloc, &env, "(defn pos? [x] (> x 0))");
    const result = try evalString(alloc, &env, "(take-while pos? [3 2 1 0 -1])");
    try std.testing.expect(result == .list);
    try std.testing.expectEqual(@as(usize, 3), result.list.items.len);
    try std.testing.expectEqual(Value{ .integer = 3 }, result.list.items[0]);
    try std.testing.expectEqual(Value{ .integer = 2 }, result.list.items[1]);
    try std.testing.expectEqual(Value{ .integer = 1 }, result.list.items[2]);
}

test "core.clj - drop-while" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    _ = try evalString(alloc, &env, "(defn pos? [x] (> x 0))");
    const result = try evalString(alloc, &env, "(drop-while pos? [3 2 1 0 -1])");
    try std.testing.expect(result == .list);
    try std.testing.expectEqual(@as(usize, 2), result.list.items.len);
    try std.testing.expectEqual(Value{ .integer = 0 }, result.list.items[0]);
    try std.testing.expectEqual(Value{ .integer = -1 }, result.list.items[1]);
}

test "core.clj - last" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const result = try evalString(alloc, &env, "(last [1 2 3 4 5])");
    try std.testing.expectEqual(Value{ .integer = 5 }, result);

    const r2 = try evalString(alloc, &env, "(last [42])");
    try std.testing.expectEqual(Value{ .integer = 42 }, r2);

    const r3 = try evalString(alloc, &env, "(last [])");
    try std.testing.expectEqual(Value.nil, r3);
}

test "core.clj - butlast" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const result = try evalString(alloc, &env, "(butlast [1 2 3 4])");
    try std.testing.expect(result == .list);
    try std.testing.expectEqual(@as(usize, 3), result.list.items.len);
    try std.testing.expectEqual(Value{ .integer = 1 }, result.list.items[0]);
    try std.testing.expectEqual(Value{ .integer = 3 }, result.list.items[2]);

    const r2 = try evalString(alloc, &env, "(butlast [1])");
    try std.testing.expectEqual(Value.nil, r2);
}

test "core.clj - second" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const result = try evalString(alloc, &env, "(second [10 20 30])");
    try std.testing.expectEqual(Value{ .integer = 20 }, result);
}

test "core.clj - fnext" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // fnext = first of next = second
    const result = try evalString(alloc, &env, "(fnext [10 20 30])");
    try std.testing.expectEqual(Value{ .integer = 20 }, result);
}

test "core.clj - nfirst" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // nfirst = next of first; first of [[1 2] [3 4]] is [1 2], next of that is (2)
    const result = try evalString(alloc, &env, "(nfirst [[1 2] [3 4]])");
    try std.testing.expect(result == .list);
    try std.testing.expectEqual(@as(usize, 1), result.list.items.len);
    try std.testing.expectEqual(Value{ .integer = 2 }, result.list.items[0]);
}

test "core.clj - not-empty" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // non-empty collection returns itself
    const r1 = try evalString(alloc, &env, "(not-empty [1 2 3])");
    try std.testing.expect(r1 == .vector);
    try std.testing.expectEqual(@as(usize, 3), r1.vector.items.len);

    // empty collection returns nil
    const r2 = try evalString(alloc, &env, "(not-empty [])");
    try std.testing.expectEqual(Value.nil, r2);
}

test "core.clj - every-pred" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    _ = try evalString(alloc, &env, "(defn pos? [x] (> x 0))");
    _ = try evalString(alloc, &env, "(defn even? [x] (= 0 (rem x 2)))");

    // every-pred combines two predicates
    const r1 = try evalString(alloc, &env, "((every-pred pos? even?) 4)");
    try std.testing.expect(r1 != Value.nil);

    const r2 = try evalString(alloc, &env, "((every-pred pos? even?) 3)");
    try std.testing.expect(r2 == .boolean and r2.boolean == false);
}

test "core.clj - some-fn" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    _ = try evalString(alloc, &env, "(defn pos? [x] (> x 0))");
    _ = try evalString(alloc, &env, "(defn even? [x] (= 0 (rem x 2)))");

    // some-fn: at least one predicate returns truthy
    const r1 = try evalString(alloc, &env, "((some-fn pos? even?) -2)");
    try std.testing.expect(r1 != Value.nil);

    const r2 = try evalString(alloc, &env, "((some-fn pos? even?) -3)");
    // -3 is not positive and not even => falsy (false or nil depending on or impl)
    try std.testing.expect(r2 == Value.nil or (r2 == .boolean and r2.boolean == false));
}

test "core.clj - fnil" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // fnil replaces nil with default
    const result = try evalString(alloc, &env, "((fnil inc 0) nil)");
    try std.testing.expectEqual(Value{ .integer = 1 }, result);

    // non-nil passes through
    const r2 = try evalString(alloc, &env, "((fnil inc 0) 5)");
    try std.testing.expectEqual(Value{ .integer = 6 }, r2);
}

test "core.clj - doseq" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // doseq iterates for side effects, returns nil
    const result = try evalString(alloc, &env,
        \\(let [a (atom 0)]
        \\  (doseq [x [1 2 3]]
        \\    (swap! a + x))
        \\  (deref a))
    );
    try std.testing.expectEqual(Value{ .integer = 6 }, result);
}

test "core.clj - doall" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // doall forces lazy seq and returns it
    const result = try evalString(alloc, &env, "(doall (map inc [1 2 3]))");
    try std.testing.expect(result == .list);
    try std.testing.expectEqual(@as(usize, 3), result.list.items.len);
}

test "core.clj - dorun" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // dorun walks seq, returns nil
    const result = try evalString(alloc, &env, "(dorun (map inc [1 2 3]))");
    try std.testing.expectEqual(Value.nil, result);
}

test "core.clj - while" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // while loop with atom — use builtin + for swap!
    const result = try evalString(alloc, &env,
        \\(let [a (atom 0)]
        \\  (while (< (deref a) 5)
        \\    (swap! a + 1))
        \\  (deref a))
    );
    try std.testing.expectEqual(Value{ .integer = 5 }, result);
}

test "core.clj - case" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const r1 = try evalString(alloc, &env, "(case 2 1 :a 2 :b 3 :c)");
    try std.testing.expect(r1 == .keyword);

    // default case
    const r2 = try evalString(alloc, &env, "(case 99 1 :a 2 :b :default)");
    try std.testing.expect(r2 == .keyword);
}

test "core.clj - condp" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const result = try evalString(alloc, &env,
        \\(condp = 2
        \\  1 :a
        \\  2 :b
        \\  3 :c)
    );
    try std.testing.expect(result == .keyword);
}

test "core.clj - declare" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    _ = try evalString(alloc, &env, "(declare my-forward-fn)");
    // Should be nil (declared but not defined)
    const result = try evalString(alloc, &env, "my-forward-fn");
    try std.testing.expectEqual(Value.nil, result);

    // Now define it
    _ = try evalString(alloc, &env, "(defn my-forward-fn [x] (+ x 1))");
    const r2 = try evalString(alloc, &env, "(my-forward-fn 5)");
    try std.testing.expectEqual(Value{ .integer = 6 }, r2);
}

test "core.clj - delay and force" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // delay creates a deferred computation, force evaluates it
    const result = try evalString(alloc, &env,
        \\(let [d (delay (+ 1 2))]
        \\  (force d))
    );
    try std.testing.expectEqual(Value{ .integer = 3 }, result);
}

test "core.clj - delay memoizes" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // force should return same value on repeated calls (memoized)
    const result = try evalString(alloc, &env,
        \\(let [counter (atom 0)
        \\      d (delay (do (swap! counter + 1) (deref counter)))]
        \\  (force d)
        \\  (force d)
        \\  (deref counter))
    );
    // Counter should be 1 (thunk evaluated only once)
    try std.testing.expectEqual(Value{ .integer = 1 }, result);
}

test "core.clj - realized?" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const result = try evalString(alloc, &env,
        \\(let [d (delay (+ 1 2))]
        \\  (let [before (realized? d)]
        \\    (force d)
        \\    (let [after (realized? d)]
        \\      (list before after))))
    );
    // before=false, after=true
    try std.testing.expect(result == .list);
    try std.testing.expectEqual(@as(usize, 2), result.list.items.len);
    try std.testing.expect(result.list.items[0] == .boolean and result.list.items[0].boolean == false);
    try std.testing.expect(result.list.items[1] == .boolean and result.list.items[1].boolean == true);
}

test "core.clj - boolean" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const r1 = try evalString(alloc, &env, "(boolean 42)");
    try std.testing.expect(r1 == .boolean and r1.boolean == true);

    const r2 = try evalString(alloc, &env, "(boolean nil)");
    try std.testing.expect(r2 == .boolean and r2.boolean == false);

    const r3 = try evalString(alloc, &env, "(boolean false)");
    try std.testing.expect(r3 == .boolean and r3.boolean == false);
}

test "core.clj - true? false? some? any?" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const r1 = try evalString(alloc, &env, "(true? true)");
    try std.testing.expect(r1 == .boolean and r1.boolean == true);

    const r2 = try evalString(alloc, &env, "(true? 1)");
    try std.testing.expect(r2 == .boolean and r2.boolean == false);

    const r3 = try evalString(alloc, &env, "(false? false)");
    try std.testing.expect(r3 == .boolean and r3.boolean == true);

    const r4 = try evalString(alloc, &env, "(false? nil)");
    try std.testing.expect(r4 == .boolean and r4.boolean == false);

    const r5 = try evalString(alloc, &env, "(some? 42)");
    try std.testing.expect(r5 == .boolean and r5.boolean == true);

    const r6 = try evalString(alloc, &env, "(some? nil)");
    try std.testing.expect(r6 == .boolean and r6.boolean == false);

    const r7 = try evalString(alloc, &env, "(any? nil)");
    try std.testing.expect(r7 == .boolean and r7.boolean == true);
}

test "core.clj - type" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    // type returns keyword for value type
    const r1 = try evalString(alloc, &env, "(type 42)");
    try std.testing.expect(r1 == .keyword);
    try std.testing.expectEqualStrings("integer", r1.keyword.name);

    const r2 = try evalString(alloc, &env, "(type \"hello\")");
    try std.testing.expect(r2 == .keyword);
    try std.testing.expectEqualStrings("string", r2.keyword.name);

    const r3 = try evalString(alloc, &env, "(type :foo)");
    try std.testing.expect(r3 == .keyword);
    try std.testing.expectEqualStrings("keyword", r3.keyword.name);

    const r4 = try evalString(alloc, &env, "(type [1 2])");
    try std.testing.expect(r4 == .keyword);
    try std.testing.expectEqualStrings("vector", r4.keyword.name);

    const r5 = try evalString(alloc, &env, "(type nil)");
    try std.testing.expect(r5 == .keyword);
    try std.testing.expectEqualStrings("nil", r5.keyword.name);
}

test "core.clj - instance?" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Env.init(alloc);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try loadCore(alloc, &env);

    const r1 = try evalString(alloc, &env, "(instance? :integer 42)");
    try std.testing.expect(r1 == .boolean and r1.boolean == true);

    const r2 = try evalString(alloc, &env, "(instance? :string 42)");
    try std.testing.expect(r2 == .boolean and r2.boolean == false);
}

// VM test for `for` deferred: the `for` expansion generates inline fn nodes
// that the VM compiles to FnProto-based fn_vals. When core.clj `map` (a TreeWalk
// closure) calls back into these fn_vals via macroEvalBridge, the TreeWalk
// callClosure expects Closure proto but receives FnProto, causing a segfault.
// This requires a unified fn_val representation (VM + TreeWalk) to fix — tracked
// as a known limitation for the dual-backend architecture.
