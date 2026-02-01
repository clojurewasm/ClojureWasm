// ClojureWasm - Clojure implementation in Zig
// This is the library root module.

pub const value = @import("common/value.zig");
pub const collections = @import("common/collections.zig");
pub const tokenizer = @import("common/reader/tokenizer.zig");
pub const form = @import("common/reader/form.zig");
pub const err = @import("common/error.zig");
pub const reader = @import("common/reader/reader.zig");
pub const node = @import("common/analyzer/node.zig");
pub const analyzer = @import("common/analyzer/analyzer.zig");
pub const env = @import("common/env.zig");
pub const var_mod = @import("common/var.zig");
pub const namespace = @import("common/namespace.zig");
pub const gc = @import("common/gc.zig");
pub const opcodes = @import("common/bytecode/opcodes.zig");
pub const chunk = @import("common/bytecode/chunk.zig");
pub const compiler = @import("common/bytecode/compiler.zig");
pub const vm = @import("native/vm/vm.zig");
pub const tree_walk = @import("native/evaluator/tree_walk.zig");
pub const eval_engine = @import("common/eval_engine.zig");
pub const builtin_arithmetic = @import("common/builtin/arithmetic.zig");
pub const builtin_special_forms = @import("common/builtin/special_forms.zig");
pub const builtin_registry = @import("common/builtin/registry.zig");

test {
    _ = value;
    _ = collections;
    _ = tokenizer;
    _ = form;
    _ = err;
    _ = reader;
    _ = node;
    _ = analyzer;
    _ = env;
    _ = var_mod;
    _ = namespace;
    _ = gc;
    _ = opcodes;
    _ = chunk;
    _ = compiler;
    _ = vm;
    _ = tree_walk;
    _ = eval_engine;
    _ = builtin_arithmetic;
    _ = builtin_special_forms;
    _ = builtin_registry;
}
