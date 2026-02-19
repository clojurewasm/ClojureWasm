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
pub const tokenizer = @import("reader/tokenizer.zig");
pub const form = @import("reader/form.zig");
pub const err = @import("runtime/error.zig");
pub const reader = @import("reader/reader.zig");
pub const node = @import("analyzer/node.zig");
pub const analyzer = @import("analyzer/analyzer.zig");
pub const env = @import("runtime/env.zig");
pub const var_mod = @import("runtime/var.zig");
pub const namespace = @import("runtime/namespace.zig");
pub const gc = @import("runtime/gc.zig");
pub const opcodes = @import("compiler/opcodes.zig");
pub const chunk = @import("compiler/chunk.zig");
pub const compiler = @import("compiler/compiler.zig");
pub const serialize = @import("compiler/serialize.zig");
pub const vm = @import("vm/vm.zig");
pub const tree_walk = @import("evaluator/tree_walk.zig");
pub const eval_engine = @import("runtime/eval_engine.zig");
pub const builtin_arithmetic = @import("builtins/arithmetic.zig");
pub const builtin_special_forms = @import("builtins/special_forms.zig");
pub const builtin_registry = @import("builtins/registry.zig");
pub const builtin_collections = @import("builtins/collections.zig");
pub const builtin_predicates = @import("builtins/predicates.zig");
pub const builtin_strings = @import("builtins/strings.zig");
pub const builtin_io = @import("builtins/io.zig");
pub const builtin_atom = @import("builtins/atom.zig");
pub const builtin_regex = @import("builtins/regex_builtins.zig");
pub const regex_parser = @import("regex/regex.zig");
pub const regex_matcher = @import("regex/matcher.zig");
pub const macro_utils = @import("runtime/macro.zig");
pub const bootstrap = @import("runtime/bootstrap.zig");
pub const bencode = @import("repl/bencode.zig");
pub const nrepl = @import("repl/nrepl.zig");
pub const line_editor = @import("repl/line_editor.zig");
pub const wasm_types = @import("wasm/types.zig");
pub const lifecycle = @import("runtime/lifecycle.zig");
pub const wasm_builtins = @import("wasm/builtins.zig");
pub const wit_parser = @import("wasm/wit_parser.zig");
pub const builtin_shell = @import("builtins/shell.zig");
pub const builtin_pprint = @import("builtins/pprint.zig");
pub const interop_rewrites = @import("interop/rewrites.zig");
pub const interop_dispatch = @import("interop/dispatch.zig");
pub const interop_constructors = @import("interop/constructors.zig");
pub const interop_exception_hierarchy = @import("interop/exception_hierarchy.zig");
pub const interop_class_registry = @import("interop/class_registry.zig");
pub const interop_uri = @import("interop/classes/uri.zig");
pub const interop_file = @import("interop/classes/file.zig");
pub const interop_uuid = @import("interop/classes/uuid.zig");
pub const thread_pool = @import("runtime/thread_pool.zig");
pub const concurrency_test = @import("runtime/concurrency_test.zig");
pub const stm = @import("runtime/stm.zig");
pub const deps = @import("deps.zig");

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
