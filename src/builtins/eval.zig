// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! eval builtins — read-string, eval, macroexpand-1, macroexpand.
//!
//! Provides runtime eval pipeline and macro expansion introspection.
//! These builtins bridge the reader/analyzer/evaluator pipeline into
//! callable Clojure functions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const var_mod = @import("../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const Value = @import("../runtime/value.zig").Value;
const Reader = @import("../reader/reader.zig").Reader;
const Form = @import("../reader/form.zig").Form;
const macro = @import("../runtime/macro.zig");
const Analyzer = @import("../analyzer/analyzer.zig").Analyzer;
const Node = @import("../analyzer/node.zig").Node;
const bootstrap = @import("../runtime/bootstrap.zig");
const TreeWalk = @import("../evaluator/tree_walk.zig").TreeWalk;
const err = @import("../runtime/error.zig");
const Env = @import("../runtime/env.zig").Env;
const io = @import("io.zig");
const value_mod = @import("../runtime/value.zig");
const PersistentVector = value_mod.PersistentVector;
const Namespace = @import("../runtime/namespace.zig").Namespace;

// ============================================================
// read-string
// ============================================================

/// (read-string s)
/// Reads one object from the string s. Returns nil if string is empty.
pub fn readStringFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to read-string", .{args.len});
    const s = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "read-string expects a string, got {s}", .{@tagName(args[0].tag())}),
    };
    if (s.len == 0) return Value.nil_val;

    var reader = Reader.init(allocator, s);
    reader.current_ns = resolveCurrentNs();
    const form_opt = reader.read() catch {
        err.ensureInfoSet(.eval, .syntax_error, .{}, "read-string: reader error", .{});
        return error.EvalError;
    };
    const form = form_opt orelse return Value.nil_val;
    return macro.formToValueWithNs(allocator, form, resolveCurrentNs());
}

/// Get the current namespace, respecting dynamic bindings of *ns*.
/// Checks the *ns* Var (which reflects `binding`) first, falls back to env.current_ns.
fn resolveCurrentNs() ?*const Namespace {
    const env = bootstrap.macro_eval_env orelse return null;
    if (env.findNamespace("clojure.core")) |core| {
        if (core.resolve("*ns*")) |ns_var| {
            const ns_val = ns_var.deref();
            if (ns_val.tag() == .symbol) {
                if (env.findNamespace(ns_val.asSymbol().name)) |ns| return ns;
            }
        }
    }
    return env.current_ns;
}

// ============================================================
// eval
// ============================================================

/// (eval form)
/// Evaluates the form data structure and returns the result.
/// For (do ...) forms, evaluates each sub-form sequentially so that
/// side effects (def, declare) are visible to subsequent forms.
pub fn evalFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to eval", .{args.len});
    const env = bootstrap.macro_eval_env orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "eval environment not initialized", .{});
        return error.EvalError;
    };

    // Convert Value -> Form
    const form = try macro.valueToForm(allocator, args[0]);

    // Special case: (do ...) — evaluate each body form sequentially
    // so that def/declare side effects are visible to later forms.
    // This matches JVM Clojure's eval behavior.
    if (isDoForm(form)) {
        const body = form.data.list[1..]; // skip 'do symbol
        var result: Value = Value.nil_val;
        for (body) |sub_form| {
            result = try evalOneForm(allocator, env, sub_form);
        }
        return result;
    }

    return evalOneForm(allocator, env, form);
}

fn evalOneForm(allocator: Allocator, env: *Env, form: Form) anyerror!Value {
    var analyzer = Analyzer.initWithEnv(allocator, env);
    defer analyzer.deinit();
    const node = analyzer.analyze(form) catch {
        err.ensureInfoSet(.analysis, .internal_error, .{}, "eval: analysis error", .{});
        return error.AnalyzeError;
    };

    var tw = TreeWalk.initWithEnv(allocator, env);
    return tw.run(node) catch {
        err.ensureInfoSet(.eval, .internal_error, .{}, "eval: evaluation error", .{});
        return error.EvalError;
    };
}

fn isDoForm(form: Form) bool {
    const items = switch (form.data) {
        .list => |l| l,
        else => return false,
    };
    if (items.len == 0) return false;
    const head = items[0].data;
    return switch (head) {
        .symbol => |s| s.ns == null and std.mem.eql(u8, s.name, "do"),
        else => false,
    };
}

// ============================================================
// macroexpand-1
// ============================================================

/// (macroexpand-1 form)
/// If form is a list whose first element resolves to a macro Var,
/// expands it once and returns the result. Otherwise returns form unchanged.
pub fn macroexpand1Fn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to macroexpand-1", .{args.len});
    return macroexpand1(allocator, args[0]);
}

fn macroexpand1(allocator: Allocator, form: Value) anyerror!Value {
    // Only expand list forms starting with a symbol
    const lst = switch (form.tag()) {
        .list => form.asList(),
        else => return form,
    };
    if (lst.items.len == 0) return form;

    const head = lst.items[0];
    const sym = switch (head.tag()) {
        .symbol => head.asSymbol(),
        else => return form,
    };

    // Resolve symbol to Var
    const env = bootstrap.macro_eval_env orelse return form;
    const ns = env.current_ns orelse return form;
    const v = if (sym.ns) |ns_name|
        ns.resolveQualified(ns_name, sym.name)
    else
        ns.resolve(sym.name);

    const var_ref = v orelse return form;
    if (!var_ref.isMacro()) return form;

    // Call macro function with remaining list elements as args
    const macro_fn = var_ref.deref();
    return bootstrap.callFnVal(allocator, macro_fn, lst.items[1..]);
}

// ============================================================
// macroexpand
// ============================================================

/// (macroexpand form)
/// Repeatedly calls macroexpand-1 until the form no longer changes.
pub fn macroexpandFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to macroexpand", .{args.len});

    var current = args[0];
    var i: usize = 0;
    const max_expansions = 1000;
    while (i < max_expansions) : (i += 1) {
        const expanded = try macroexpand1(allocator, current);
        // If expansion didn't change the form, we're done
        if (expanded.eql(current)) break;
        current = expanded;
    }
    return current;
}

// ============================================================
// load-string
// ============================================================

/// (load-string s)
/// Sequentially read and evaluate the set of forms contained in the string.
pub fn loadStringFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to load-string", .{args.len});
    const s = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "load-string expects a string, got {s}", .{@tagName(args[0].tag())}),
    };
    if (s.len == 0) return Value.nil_val;

    const env = bootstrap.macro_eval_env orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "eval environment not initialized", .{});
        return error.EvalError;
    };

    var reader = Reader.init(allocator, s);
    reader.current_ns = resolveCurrentNs();
    var result: Value = Value.nil_val;
    while (true) {
        const form_opt = reader.read() catch {
            err.ensureInfoSet(.eval, .syntax_error, .{}, "load-string: reader error", .{});
            return error.EvalError;
        };
        const form = form_opt orelse break;
        const val = macro.formToValueWithNs(allocator, form, resolveCurrentNs()) catch {
            err.ensureInfoSet(.eval, .internal_error, .{}, "load-string: form conversion error", .{});
            return error.EvalError;
        };
        const eval_form = macro.valueToForm(allocator, val) catch {
            err.ensureInfoSet(.eval, .internal_error, .{}, "load-string: form conversion error", .{});
            return error.EvalError;
        };

        if (isDoForm(eval_form)) {
            const body = eval_form.data.list[1..];
            for (body) |sub_form| {
                result = try evalOneForm(allocator, env, sub_form);
            }
        } else {
            result = try evalOneForm(allocator, env, eval_form);
        }
    }
    return result;
}

// ============================================================
// read
// ============================================================

/// Read one form from the current input source (*in* / with-in-str) or stdin.
/// Returns the parsed form, or throws on EOF (default) or returns eof-value.
fn readFromSource(allocator: Allocator, eof_error: bool, eof_value: Value) anyerror!Value {
    if (io.hasInputSource()) {
        // Read from string input source (with-in-str)
        const remaining = io.getCurrentInputRemaining() orelse return eof_value;
        if (remaining.len == 0) {
            if (eof_error) {
                return err.setErrorFmt(.eval, .io_error, .{}, "EOF while reading", .{});
            }
            return eof_value;
        }
        var reader = Reader.init(allocator, remaining);
        reader.current_ns = resolveCurrentNs();
        const form_opt = reader.read() catch {
            err.ensureInfoSet(.eval, .syntax_error, .{}, "read: reader error", .{});
            return error.EvalError;
        };
        const form = form_opt orelse {
            if (eof_error) {
                return err.setErrorFmt(.eval, .io_error, .{}, "EOF while reading", .{});
            }
            return eof_value;
        };
        // Advance input source past consumed bytes
        io.advanceCurrentInput(reader.position());
        return macro.formToValueWithNs(allocator, form, resolveCurrentNs());
    }

    // Read from stdin — read lines and try parsing after each
    const stdin: std.fs.File = .{ .handle = std.posix.STDIN_FILENO };
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    const max_retries: usize = 100; // prevent infinite loop on truly broken input
    var retries: usize = 0;

    while (retries < max_retries) : (retries += 1) {
        // Read one line from stdin
        var line_buf: [8192]u8 = undefined;
        var pos: usize = 0;
        while (pos < line_buf.len) {
            var byte: [1]u8 = undefined;
            const n = stdin.read(&byte) catch {
                if (eof_error) {
                    return err.setErrorFmt(.eval, .io_error, .{}, "EOF while reading", .{});
                }
                return eof_value;
            };
            if (n == 0) {
                // EOF
                if (buf.items.len == 0 and pos == 0) {
                    if (eof_error) {
                        return err.setErrorFmt(.eval, .io_error, .{}, "EOF while reading", .{});
                    }
                    return eof_value;
                }
                break;
            }
            if (byte[0] == '\n') break;
            line_buf[pos] = byte[0];
            pos += 1;
        }

        // Strip trailing \r
        if (pos > 0 and line_buf[pos - 1] == '\r') pos -= 1;

        // Append line to buffer (with newline separator if not first line)
        if (buf.items.len > 0) {
            buf.append(allocator, '\n') catch return error.OutOfMemory;
        }
        for (line_buf[0..pos]) |b| {
            buf.append(allocator, b) catch return error.OutOfMemory;
        }

        // Try to parse accumulated input
        if (buf.items.len > 0) {
            var reader = Reader.init(allocator, buf.items);
            reader.current_ns = resolveCurrentNs();
            const form_opt = reader.read() catch {
                // Syntax error — might be incomplete (unclosed paren, etc.)
                // Continue reading more input
                continue;
            };
            if (form_opt) |form| {
                return macro.formToValueWithNs(allocator, form, resolveCurrentNs());
            }
        }
    }

    return err.setErrorFmt(.eval, .syntax_error, .{}, "read: could not parse complete form from stdin", .{});
}

/// (read) (read stream) (read stream eof-error? eof-value) (read opts stream)
/// CW simplification: only 0-arg (from *in*/stdin) and 3-arg (eof handling) supported.
/// Stream args are ignored — always reads from current input source.
pub fn readFn(allocator: Allocator, args: []const Value) anyerror!Value {
    switch (args.len) {
        0 => return readFromSource(allocator, true, Value.nil_val),
        1 => {
            // (read stream) — ignore stream, read from *in*
            return readFromSource(allocator, true, Value.nil_val);
        },
        3 => {
            // (read stream eof-error? eof-value)
            const eof_error = if (args[1] == Value.false_val or args[1] == Value.nil_val) false else true;
            return readFromSource(allocator, eof_error, args[2]);
        },
        else => return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to read", .{args.len}),
    }
}

// ============================================================
// read+string
// ============================================================

/// Read one form and return [form string] — the parsed form and the source text.
fn readPlusStringFromSource(allocator: Allocator, eof_error: bool, eof_value: Value) anyerror!Value {
    if (io.hasInputSource()) {
        const remaining = io.getCurrentInputRemaining() orelse {
            if (eof_error) {
                return err.setErrorFmt(.eval, .io_error, .{}, "EOF while reading", .{});
            }
            return eof_value;
        };
        if (remaining.len == 0) {
            if (eof_error) {
                return err.setErrorFmt(.eval, .io_error, .{}, "EOF while reading", .{});
            }
            return eof_value;
        }
        var reader = Reader.init(allocator, remaining);
        reader.current_ns = resolveCurrentNs();
        const form_opt = reader.read() catch {
            err.ensureInfoSet(.eval, .syntax_error, .{}, "read+string: reader error", .{});
            return error.EvalError;
        };
        const form = form_opt orelse {
            if (eof_error) {
                return err.setErrorFmt(.eval, .io_error, .{}, "EOF while reading", .{});
            }
            return eof_value;
        };
        const consumed = reader.position();
        // Capture the consumed source text (trimmed)
        const src_text = std.mem.trimLeft(u8, remaining[0..consumed], " \t\n\r,");
        const text_str = Value.initString(allocator, try allocator.dupe(u8, src_text));
        io.advanceCurrentInput(consumed);
        const val = try macro.formToValueWithNs(allocator, form, resolveCurrentNs());
        // Return [form string] vector
        const items = try allocator.alloc(Value, 2);
        items[0] = val;
        items[1] = text_str;
        const vec = try allocator.create(PersistentVector);
        vec.* = .{ .items = items };
        return Value.initVector(vec);
    }

    // stdin path — accumulate lines and return [form string]
    const stdin: std.fs.File = .{ .handle = std.posix.STDIN_FILENO };
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    const max_retries: usize = 100;
    var retries: usize = 0;

    while (retries < max_retries) : (retries += 1) {
        var line_buf: [8192]u8 = undefined;
        var pos: usize = 0;
        while (pos < line_buf.len) {
            var byte: [1]u8 = undefined;
            const n = stdin.read(&byte) catch {
                if (eof_error) {
                    return err.setErrorFmt(.eval, .io_error, .{}, "EOF while reading", .{});
                }
                return eof_value;
            };
            if (n == 0) {
                if (buf.items.len == 0 and pos == 0) {
                    if (eof_error) {
                        return err.setErrorFmt(.eval, .io_error, .{}, "EOF while reading", .{});
                    }
                    return eof_value;
                }
                break;
            }
            if (byte[0] == '\n') break;
            line_buf[pos] = byte[0];
            pos += 1;
        }
        if (pos > 0 and line_buf[pos - 1] == '\r') pos -= 1;
        if (buf.items.len > 0) {
            buf.append(allocator, '\n') catch return error.OutOfMemory;
        }
        for (line_buf[0..pos]) |b| {
            buf.append(allocator, b) catch return error.OutOfMemory;
        }

        if (buf.items.len > 0) {
            var reader = Reader.init(allocator, buf.items);
            reader.current_ns = resolveCurrentNs();
            const form_opt = reader.read() catch {
                continue;
            };
            if (form_opt) |form| {
                const consumed = reader.position();
                const src_text = std.mem.trimLeft(u8, buf.items[0..consumed], " \t\n\r,");
                const text_str = Value.initString(allocator, try allocator.dupe(u8, src_text));
                const val = try macro.formToValueWithNs(allocator, form, resolveCurrentNs());
                const items = try allocator.alloc(Value, 2);
                items[0] = val;
                items[1] = text_str;
                const vec = try allocator.create(PersistentVector);
                vec.* = .{ .items = items };
                return Value.initVector(vec);
            }
        }
    }

    return err.setErrorFmt(.eval, .syntax_error, .{}, "read+string: could not parse complete form from stdin", .{});
}

/// (read+string) (read+string stream) (read+string stream eof-error? eof-value)
pub fn readPlusStringFn(allocator: Allocator, args: []const Value) anyerror!Value {
    switch (args.len) {
        0 => return readPlusStringFromSource(allocator, true, Value.nil_val),
        1 => return readPlusStringFromSource(allocator, true, Value.nil_val),
        3 => {
            const eof_error = if (args[1] == Value.false_val or args[1] == Value.nil_val) false else true;
            return readPlusStringFromSource(allocator, eof_error, args[2]);
        },
        else => return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to read+string", .{args.len}),
    }
}

// ============================================================
// clojure.edn/read-string
// ============================================================

/// (clojure.edn/read-string s)
/// (clojure.edn/read-string opts s)
/// Reads one object from the string s in EDN format.
/// opts is an optional map (currently ignored — reader is already EDN-safe).
/// Returns nil when s is nil or empty.
pub fn ednReadStringFn(allocator: Allocator, args: []const Value) anyerror!Value {
    switch (args.len) {
        1 => {
            // (edn/read-string s)
            if (args[0].tag() == .nil) return Value.nil_val;
            const s = switch (args[0].tag()) {
                .string => args[0].asString(),
                else => return err.setErrorFmt(.eval, .type_error, .{}, "clojure.edn/read-string expects a string, got {s}", .{@tagName(args[0].tag())}),
            };
            if (s.len == 0) return Value.nil_val;
            var reader = Reader.init(allocator, s);
            reader.current_ns = resolveCurrentNs();
            const form_opt = reader.read() catch {
                err.ensureInfoSet(.eval, .syntax_error, .{}, "edn/read-string: reader error", .{});
                return error.EvalError;
            };
            const form = form_opt orelse return Value.nil_val;
            return macro.formToValueWithNs(allocator, form, resolveCurrentNs());
        },
        2 => {
            // (edn/read-string opts s) — opts map currently ignored
            if (args[1].tag() == .nil) return Value.nil_val;
            const s = switch (args[1].tag()) {
                .string => args[1].asString(),
                else => return err.setErrorFmt(.eval, .type_error, .{}, "clojure.edn/read-string expects a string as second arg, got {s}", .{@tagName(args[1].tag())}),
            };
            if (s.len == 0) return Value.nil_val;
            var reader = Reader.init(allocator, s);
            reader.current_ns = resolveCurrentNs();
            const form_opt = reader.read() catch {
                err.ensureInfoSet(.eval, .syntax_error, .{}, "edn/read-string: reader error", .{});
                return error.EvalError;
            };
            const form = form_opt orelse return Value.nil_val;
            return macro.formToValueWithNs(allocator, form, resolveCurrentNs());
        },
        else => return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to clojure.edn/read-string", .{args.len}),
    }
}

// ============================================================
// BuiltinDef table
// ============================================================

pub const builtins = [_]BuiltinDef{
    .{
        .name = "read-string",
        .func = readStringFn,
        .doc = "Reads one object from the string s. Returns nil for empty string.",
        .arglists = "([s])",
        .added = "1.0",
    },
    .{
        .name = "eval",
        .func = evalFn,
        .doc = "Evaluates the form data structure (not text!) and returns the result.",
        .arglists = "([form])",
        .added = "1.0",
    },
    .{
        .name = "macroexpand-1",
        .func = macroexpand1Fn,
        .doc = "If form represents a macro form, returns its expansion, else returns form.",
        .arglists = "([form])",
        .added = "1.0",
    },
    .{
        .name = "load-string",
        .func = loadStringFn,
        .doc = "Sequentially read and evaluate the set of forms contained in the string.",
        .arglists = "([s])",
        .added = "1.0",
    },
    .{
        .name = "macroexpand",
        .func = macroexpandFn,
        .doc = "Repeatedly calls macroexpand-1 on form until it no longer represents a macro form, then returns it.",
        .arglists = "([form])",
        .added = "1.0",
    },
    .{
        .name = "read",
        .func = readFn,
        .doc = "Reads the next object from the current input source (*in*). With eof-error? false, returns eof-value on end of input.",
        .arglists = "([] [stream] [stream eof-error? eof-value])",
        .added = "1.0",
    },
    .{
        .name = "read+string",
        .func = readPlusStringFn,
        .doc = "Like read, but returns a vector [object string] where string is the source text that was read.",
        .arglists = "([] [stream] [stream eof-error? eof-value])",
        .added = "1.10",
    },
};

/// clojure.edn namespace builtins.
pub const edn_builtins = [_]BuiltinDef{
    .{
        .name = "read-string",
        .func = ednReadStringFn,
        .doc = "Reads one object from the string s. Returns nil when s is nil or empty.",
        .arglists = "([s] [opts s])",
        .added = "1.5",
    },
    .{
        .name = "read",
        .func = readFn,
        .doc = "Reads the next object from the current input source in EDN format.",
        .arglists = "([] [stream] [stream eof-error? eof-value])",
        .added = "1.5",
    },
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "read-string - integer" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try readStringFn(alloc, &[_]Value{Value.initString(alloc, "42")});
    try testing.expectEqual(Value.initInteger(42), result);
}

test "read-string - string" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try readStringFn(alloc, &[_]Value{Value.initString(alloc, "\"hello\"")});
    try testing.expectEqualStrings("hello", result.asString());
}

test "read-string - symbol" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try readStringFn(alloc, &[_]Value{Value.initString(alloc, "foo")});
    try testing.expect(result.tag() == .symbol);
    try testing.expectEqualStrings("foo", result.asSymbol().name);
}

test "read-string - keyword" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try readStringFn(alloc, &[_]Value{Value.initString(alloc, ":bar")});
    try testing.expect(result.tag() == .keyword);
    try testing.expectEqualStrings("bar", result.asKeyword().name);
}

test "read-string - vector" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try readStringFn(alloc, &[_]Value{Value.initString(alloc, "[1 2 3]")});
    try testing.expect(result.tag() == .vector);
    try testing.expectEqual(@as(usize, 3), result.asVector().items.len);
}

test "read-string - empty string returns nil" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try readStringFn(alloc, &[_]Value{Value.initString(alloc, "")});
    try testing.expectEqual(Value.nil_val, result);
}

test "read-string - map" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try readStringFn(alloc, &[_]Value{Value.initString(alloc, "{:a 1}")});
    try testing.expect(result.tag() == .map);
}

test "read-string - list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try readStringFn(alloc, &[_]Value{Value.initString(alloc, "(+ 1 2)")});
    try testing.expect(result.tag() == .list);
    try testing.expectEqual(@as(usize, 3), result.asList().items.len);
}
