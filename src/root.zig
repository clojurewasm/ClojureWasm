// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! ClojureWasm - Clojure implementation in Zig
//! This is the library root module.

pub const value = @import("runtime/value.zig");
pub const collections = @import("runtime/collections.zig");
pub const tokenizer = @import("engine/reader/tokenizer.zig");
pub const form = @import("engine/reader/form.zig");
pub const err = @import("runtime/error.zig");
pub const reader = @import("engine/reader/reader.zig");
pub const node = @import("engine/analyzer/node.zig");
pub const analyzer = @import("engine/analyzer/analyzer.zig");
pub const env = @import("runtime/env.zig");
pub const var_mod = @import("runtime/var.zig");
pub const namespace = @import("runtime/namespace.zig");
pub const gc = @import("runtime/gc.zig");
pub const runtime_arithmetic = @import("runtime/arithmetic.zig");
pub const opcodes = @import("engine/compiler/opcodes.zig");
pub const chunk = @import("engine/compiler/chunk.zig");
pub const compiler = @import("engine/compiler/compiler.zig");
pub const serialize = @import("engine/compiler/serialize.zig");
pub const vm = @import("engine/vm/vm.zig");
pub const tree_walk = @import("engine/evaluator/tree_walk.zig");
pub const eval_engine = @import("lang/eval_engine.zig");
pub const builtin_arithmetic = @import("lang/builtins/arithmetic.zig");
pub const builtin_special_forms = @import("lang/builtins/special_forms.zig");
pub const builtin_registry = @import("lang/registry.zig");
pub const builtin_collections = @import("lang/builtins/collections.zig");
pub const builtin_predicates = @import("lang/builtins/predicates.zig");
pub const builtin_strings = @import("lang/builtins/strings.zig");
pub const builtin_io = @import("lang/builtins/io.zig");
pub const builtin_atom = @import("lang/builtins/atom.zig");
pub const builtin_regex = @import("lang/builtins/regex_builtins.zig");
pub const regex_parser = @import("regex/regex.zig");
pub const regex_matcher = @import("regex/matcher.zig");
pub const macro_utils = @import("engine/macro.zig");
pub const bootstrap = @import("engine/bootstrap.zig");
pub const bencode = @import("app/repl/bencode.zig");
pub const nrepl = @import("app/repl/nrepl.zig");
pub const line_editor = @import("app/repl/line_editor.zig");
pub const wasm_types = @import("runtime/wasm_types.zig");
pub const lifecycle = @import("runtime/lifecycle.zig");
pub const wasm_builtins = @import("lang/lib/cljw_wasm_builtins.zig");
pub const wit_parser = @import("runtime/wasm_wit_parser.zig");
pub const builtin_shell = @import("lang/builtins/shell.zig");
pub const builtin_pprint = @import("lang/builtins/pprint.zig");
pub const interop_rewrites = @import("lang/interop/rewrites.zig");
pub const interop_dispatch = @import("lang/interop/dispatch.zig");
pub const interop_constructors = @import("lang/interop/constructors.zig");
pub const codepoint = @import("runtime/codepoint.zig");
pub const interop_exception_hierarchy = @import("lang/interop/exception_hierarchy.zig");
pub const interop_class_registry = @import("lang/interop/class_registry.zig");
pub const interop_uri = @import("lang/interop/classes/uri.zig");
pub const interop_file = @import("lang/interop/classes/file.zig");
pub const interop_uuid = @import("lang/interop/classes/uuid.zig");
pub const thread_pool = @import("runtime/thread_pool.zig");
pub const concurrency_test = @import("runtime/concurrency_test.zig");
pub const stm = @import("runtime/stm.zig");
pub const deps = @import("app/deps.zig");
pub const cli = @import("app/cli.zig");
pub const app_runner = @import("app/runner.zig");
pub const app_test_runner = @import("app/test_runner.zig");

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
    _ = serialize;
    _ = vm;
    _ = tree_walk;
    _ = eval_engine;
    _ = builtin_arithmetic;
    _ = builtin_special_forms;
    _ = builtin_registry;
    _ = builtin_collections;
    _ = builtin_predicates;
    _ = builtin_strings;
    _ = builtin_io;
    _ = builtin_atom;
    _ = builtin_regex;
    _ = regex_parser;
    _ = regex_matcher;
    _ = macro_utils;
    _ = bootstrap;
    _ = bencode;
    _ = nrepl;
    _ = line_editor;
    _ = lifecycle;
    _ = wasm_types;
    _ = wasm_builtins;
    _ = wit_parser;
    _ = builtin_shell;
    _ = builtin_pprint;
    _ = interop_rewrites;
    _ = interop_dispatch;
    _ = interop_constructors;
    _ = codepoint;
    _ = interop_exception_hierarchy;
    _ = interop_class_registry;
    _ = interop_uri;
    _ = interop_file;
    _ = interop_uuid;
    _ = thread_pool;
    _ = concurrency_test;
    _ = stm;
    _ = deps;
}
