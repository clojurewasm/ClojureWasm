// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Analyzer — transforms Form (Reader output) into Node (executable AST).
//!
//! Three-phase architecture:
//!   Form (Reader) -> Node (Analyzer) -> Value (Runtime)
//!
//! Special forms are dispatched via comptime StaticStringMap (not if-else chain).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Form = @import("../reader/form.zig").Form;
const FormData = @import("../reader/form.zig").FormData;
const SymbolRef = @import("../reader/form.zig").SymbolRef;
const node_mod = @import("node.zig");
const Node = node_mod.Node;
const SourceInfo = node_mod.SourceInfo;
const Value = @import("../runtime/value.zig").Value;
const err = @import("../runtime/error.zig");
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const var_mod = @import("../runtime/var.zig");
const Var = var_mod.Var;
const macro = @import("../runtime/macro.zig");
const collections = @import("../runtime/collections.zig");
const bootstrap = @import("../runtime/bootstrap.zig");
const value_mod = @import("../runtime/value.zig");
const regex_matcher = @import("../regex/matcher.zig");
const keyword_intern = @import("../runtime/keyword_intern.zig");
const interop_rewrites = @import("../interop/rewrites.zig");

/// Analyzer — stateful Form -> Node transformer.
pub const Analyzer = struct {
    allocator: Allocator,

    /// Optional runtime environment for macro expansion and var resolution.
    env: ?*Env = null,

    /// Local variable bindings stack (let, fn parameters).
    locals: std.ArrayList(LocalBinding) = .empty,

    /// Source file name (for error reporting).
    source_file: ?[]const u8 = null,

    pub const LocalBinding = struct {
        name: []const u8,
        idx: u32,
    };

    pub const AnalyzeError = err.Error;

    pub fn init(allocator: Allocator) Analyzer {
        return .{ .allocator = allocator };
    }

    pub fn initWithEnv(allocator: Allocator, env: *Env) Analyzer {
        return .{ .allocator = allocator, .env = env, .source_file = err.getSourceFile() };
    }


    pub fn deinit(self: *Analyzer) void {
        self.locals.deinit(self.allocator);
    }

    // === Source tracking ===

    fn sourceFromForm(self: *const Analyzer, form: Form) SourceInfo {
        return .{
            .line = form.line,
            .column = form.column,
            .file = self.source_file,
        };
    }

    // === Error helpers ===

    fn analysisError(self: *const Analyzer, kind: err.Kind, message: []const u8, form: Form) AnalyzeError {
        return err.setError(.{
            .kind = kind,
            .phase = .analysis,
            .message = message,
            .location = .{
                .file = self.source_file,
                .line = form.line,
                .column = form.column,
            },
        });
    }

    // === Node constructors ===

    fn makeConstant(self: *Analyzer, val: Value) AnalyzeError!*Node {
        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .constant = .{ .value = val } };
        return n;
    }

    fn makeConstantFrom(self: *Analyzer, val: Value, form: Form) AnalyzeError!*Node {
        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .constant = .{ .value = val, .source = self.sourceFromForm(form) } };
        return n;
    }

    fn analyzeRegex(self: *Analyzer, pattern: []const u8, form: Form) AnalyzeError!*Node {
        _ = form;
        // Compile the regex pattern at analysis time
        const compiled = self.allocator.create(@import("../regex/regex.zig").CompiledRegex) catch return error.OutOfMemory;
        compiled.* = regex_matcher.compile(self.allocator, pattern) catch {
            return error.SyntaxError;
        };
        const pat = self.allocator.create(value_mod.Pattern) catch return error.OutOfMemory;
        pat.* = .{
            .source = pattern,
            .compiled = @ptrCast(compiled),
            .group_count = compiled.group_count,
        };
        return self.makeConstant(Value.initRegex(pat));
    }

    fn analyzeTag(self: *Analyzer, t: @import("../reader/form.zig").TaggedLiteral, form: Form) AnalyzeError!*Node {
        const tag_name = t.tag;

        // Built-in tag: #inst passes through the form value
        if (std.mem.eql(u8, tag_name, "inst")) {
            return self.analyze(t.form.*);
        }

        // Built-in tag: #uuid "..." → (__uuid-from-string "...")
        if (std.mem.eql(u8, tag_name, "uuid")) {
            var rewritten = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
            rewritten[0] = .{
                .data = .{ .symbol = .{ .ns = null, .name = "__uuid-from-string" } },
                .line = form.line, .column = form.column,
            };
            rewritten[1] = t.form.*;
            return self.analyzeCall(rewritten, form);
        }

        // General case: (tagged-literal '<tag-symbol> <form-value>)
        const tag_sym_val = Value.initSymbol(self.allocator, .{ .ns = null, .name = tag_name });
        const quote_data = self.allocator.create(node_mod.QuoteNode) catch return error.OutOfMemory;
        quote_data.* = .{ .value = tag_sym_val, .source = self.sourceFromForm(form) };
        const tag_const = self.allocator.create(Node) catch return error.OutOfMemory;
        tag_const.* = .{ .quote_node = quote_data };

        const form_node = try self.analyze(t.form.*);

        const callee = self.allocator.create(Node) catch return error.OutOfMemory;
        callee.* = .{ .var_ref = .{ .ns = null, .name = "tagged-literal", .source = self.sourceFromForm(form) } };

        const args = self.allocator.alloc(*Node, 2) catch return error.OutOfMemory;
        args[0] = tag_const;
        args[1] = form_node;

        const call = self.allocator.create(node_mod.CallNode) catch return error.OutOfMemory;
        call.* = .{ .callee = callee, .args = args, .source = self.sourceFromForm(form) };

        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .call_node = call };
        return n;
    }

    fn makeLocalRef(self: *Analyzer, name: []const u8, idx: u32, form: Form) AnalyzeError!*Node {
        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .local_ref = .{
            .name = name,
            .idx = idx,
            .source = self.sourceFromForm(form),
        } };
        return n;
    }

    fn makeVarRef(self: *Analyzer, sym: SymbolRef, form: Form) AnalyzeError!*Node {
        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .var_ref = .{
            .ns = sym.ns,
            .name = sym.name,
            .source = self.sourceFromForm(form),
        } };
        return n;
    }

    // === Local variable lookup ===

    fn findLocal(self: *const Analyzer, name: []const u8) ?LocalBinding {
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.locals.items[i].name, name)) {
                return self.locals.items[i];
            }
        }
        return null;
    }

    // === Special form comptime dispatch table ===

    const SpecialFormFn = *const fn (*Analyzer, []const Form, Form) AnalyzeError!*Node;

    const special_forms = std.StaticStringMap(SpecialFormFn).initComptime(.{
        .{ "if", analyzeIf },
        .{ "do", analyzeDo },
        .{ "let", analyzeLet },
        .{ "let*", analyzeLet },
        .{ "letfn*", analyzeLetfn },
        .{ "fn", analyzeFn },
        .{ "fn*", analyzeFn },
        .{ "def", analyzeDef },
        .{ "quote", analyzeQuote },
        .{ "defmacro", analyzeDefmacro },
        .{ "loop", analyzeLoop },
        .{ "recur", analyzeRecur },
        .{ "throw", analyzeThrow },
        .{ "try", analyzeTry },
        .{ "for", analyzeFor },
        .{ "defprotocol", analyzeDefprotocol },
        .{ "extend-type", analyzeExtendType },
        .{ "reify", analyzeReify },
        .{ "defrecord", analyzeDefrecord },
        .{ "defmulti", analyzeDefmulti },
        .{ "defmethod", analyzeDefmethod },
        .{ "lazy-seq", analyzeLazySeq },
        .{ "var", analyzeVarForm },
        .{ "set!", analyzeSetBang },
        .{ "case*", analyzeCaseStar },
        .{ "instance?", analyzeInstanceCheck },
    });

    // === Main entry point ===

    /// Analyze a Form, producing a Node.
    pub fn analyze(self: *Analyzer, form: Form) AnalyzeError!*Node {
        return switch (form.data) {
            .nil => self.makeConstantFrom(Value.nil_val, form),
            .boolean => |b| self.makeConstantFrom(Value.initBoolean(b), form),
            .integer => |n| self.makeConstantFrom(Value.initInteger(n), form),
            .float => |n| self.makeConstantFrom(Value.initFloat(n), form),
            .big_int => |s| self.makeConstantFrom(Value.initBigInt(collections.BigInt.initFromString(self.allocator, s) catch return error.OutOfMemory), form),
            .big_decimal => |s| self.makeConstantFrom(Value.initBigDecimal(collections.BigDecimal.initFromString(self.allocator, s) catch return error.OutOfMemory), form),
            .ratio => |r| blk: {
                const maybe_ratio = collections.Ratio.initFromStrings(self.allocator, r.numerator, r.denominator) catch return error.OutOfMemory;
                if (maybe_ratio) |ratio| {
                    break :blk self.makeConstantFrom(Value.initRatio(ratio), form);
                } else {
                    // Denominator divides numerator: simplifies to integer
                    const n = collections.BigInt.initFromString(self.allocator, r.numerator) catch return error.OutOfMemory;
                    const d = collections.BigInt.initFromString(self.allocator, r.denominator) catch return error.OutOfMemory;
                    const q = self.allocator.create(collections.BigInt) catch return error.OutOfMemory;
                    q.managed = std.math.big.int.Managed.init(self.allocator) catch return error.OutOfMemory;
                    var rem_val = std.math.big.int.Managed.init(self.allocator) catch return error.OutOfMemory;
                    q.managed.divTrunc(&rem_val, &n.managed, &d.managed) catch return error.OutOfMemory;
                    // Try to fit in i64/i48
                    if (q.toI64()) |i| {
                        break :blk self.makeConstantFrom(Value.initInteger(i), form);
                    }
                    break :blk self.makeConstantFrom(Value.initBigInt(q), form);
                }
            },
            .char => |c| self.makeConstantFrom(Value.initChar(c), form),
            .string => |s| self.makeConstantFrom(Value.initString(self.allocator, s), form),
            .keyword => |sym| blk: {
                var resolved_ns = sym.ns;
                if (sym.auto_resolve) {
                    resolved_ns = self.resolveAutoNs(sym.ns) orelse sym.ns;
                }
                keyword_intern.intern(resolved_ns, sym.name);
                break :blk self.makeConstantFrom(Value.initKeyword(self.allocator, .{ .ns = resolved_ns, .name = sym.name }), form);
            },
            .symbol => |sym| self.analyzeSymbol(sym, form),
            .list => |items| self.analyzeList(items, form),
            .vector => |items| self.analyzeVector(items, form),
            .map => |items| self.analyzeMap(items, form),
            .set => |items| self.analyzeSet(items, form),
            .regex => |pattern| self.analyzeRegex(pattern, form),
            .tag => |t| self.analyzeTag(t, form),
        };
    }

    // === Symbol resolution ===

    fn analyzeSymbol(self: *Analyzer, sym: SymbolRef, form: Form) AnalyzeError!*Node {
        // Check locals first (no namespace prefix)
        if (sym.ns == null) {
            if (self.findLocal(sym.name)) |local| {
                return self.makeLocalRef(local.name, local.idx, form);
            }
        }
        // Rewrite Java static field access: Math/PI → clojure.math/PI, etc.
        if (sym.ns) |ns| {
            if (rewriteStaticField(ns, sym.name)) |rewritten| {
                return self.makeVarRef(.{ .ns = rewritten.ns, .name = rewritten.name }, form);
            }
        }
        // Fall through to var_ref (name-based in Phase 1c)
        return self.makeVarRef(sym, form);
    }

    const StaticFieldRewrite = interop_rewrites.StaticFieldRewrite;
    const rewriteStaticField = interop_rewrites.rewriteStaticField;

    // === List analysis ===

    fn analyzeList(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        if (items.len == 0) {
            // Empty list () -> empty list (self-evaluating in Clojure)
            const empty_list = self.allocator.create(value_mod.PersistentList) catch return error.OutOfMemory;
            empty_list.* = .{ .items = &.{} };
            return self.makeConstantFrom(Value.initList(empty_list), form);
        }

        // Strip type hints: (with-meta form {:tag Type}) → analyze inner form
        // Only strip when metadata map contains :tag (reader type hints).
        // Preserve with-meta calls using other metadata keys (e.g. zip metadata).
        if (items.len == 3 and items[0].data == .symbol) {
            const sym = items[0].data.symbol;
            if (sym.ns == null and std.mem.eql(u8, sym.name, "with-meta")) {
                if (isTypeHintMeta(items[2])) {
                    return self.analyze(items[1]);
                }
            }
        }

        // Check for special form (but locals shadow special forms)
        if (items[0].data == .symbol) {
            const sym_name = items[0].data.symbol.name;
            if (items[0].data.symbol.ns == null) {
                // Local bindings take priority over special forms
                if (self.findLocal(sym_name) == null) {
                    if (special_forms.get(sym_name)) |handler| {
                        return handler(self, items, form);
                    }
                }
            } else if (items[0].data.symbol.ns) |ns_prefix| {
                // Qualified special forms: clojure.core/def, c/def (via alias), etc.
                if (self.isClojureCoreNs(ns_prefix)) {
                    if (special_forms.get(sym_name)) |handler| {
                        return handler(self, items, form);
                    }
                }
            }
        }

        // Check for macro call (requires env)
        if (self.env != null and items[0].data == .symbol) {
            if (self.resolveMacroVar(items[0].data.symbol)) |v| {
                if (v.isMacro()) {
                    return self.expandMacro(v, items[1..], form);
                }
            }
        }

        // Rewrite Math/System static method calls to builtin names
        if (items[0].data == .symbol) {
            if (items[0].data.symbol.ns) |ns_name| {
                if (rewriteInteropCall(ns_name, items[0].data.symbol.name)) |builtin_name| {
                    var rewritten = self.allocator.alloc(Form, items.len) catch return error.OutOfMemory;
                    rewritten[0] = .{
                        .data = .{ .symbol = .{ .ns = null, .name = builtin_name } },
                        .line = items[0].line,
                        .column = items[0].column,
                    };
                    @memcpy(rewritten[1..], items[1..]);
                    return self.analyzeCall(rewritten, form);
                }
            }
        }

        // Rewrite (.method obj args...) to (__java-method "method" obj args...)
        if (items[0].data == .symbol and items[0].data.symbol.ns == null) {
            const sym_name = items[0].data.symbol.name;
            if (sym_name.len > 1 and sym_name[0] == '.' and sym_name[1] != '.') {
                if (items.len < 2) {
                    return self.analysisError(.arity_error, "instance method call requires an object", form);
                }
                const method_name = sym_name[1..];
                var rewritten = self.allocator.alloc(Form, items.len + 1) catch return error.OutOfMemory;
                rewritten[0] = .{
                    .data = .{ .symbol = .{ .ns = null, .name = "__java-method" } },
                    .line = items[0].line, .column = items[0].column,
                };
                rewritten[1] = .{
                    .data = .{ .string = method_name },
                    .line = items[0].line, .column = items[0].column,
                };
                @memcpy(rewritten[2..], items[1..]);
                return self.analyzeCall(rewritten, form);
            }
        }

        // Rewrite (ClassName. args...) to (__interop-new "fqcn" args...)
        if (items[0].data == .symbol and items[0].data.symbol.ns == null) {
            const sym_name = items[0].data.symbol.name;
            if (sym_name.len > 1 and sym_name[sym_name.len - 1] == '.') {
                const class_short = sym_name[0 .. sym_name.len - 1];
                if (self.resolveClassFqcn(class_short)) |fqcn| {
                    return self.rewriteConstructorCall(fqcn, items[1..], form, items[0]);
                }
            }
        }

        // Rewrite (new ClassName args...) to (__interop-new "fqcn" args...)
        if (items[0].data == .symbol and items[0].data.symbol.ns == null) {
            if (std.mem.eql(u8, items[0].data.symbol.name, "new")) {
                if (items.len < 2) {
                    return self.analysisError(.arity_error, "new requires a class name", form);
                }
                if (items[1].data != .symbol) {
                    return self.analysisError(.type_error, "new requires a symbol as class name", form);
                }
                const class_name = items[1].data.symbol.name;
                if (self.resolveClassFqcn(class_name)) |fqcn| {
                    return self.rewriteConstructorCall(fqcn, items[2..], form, items[0]);
                }
                return self.analysisError(.value_error, "Unknown class in new expression", form);
            }
        }

        // Function call
        return self.analyzeCall(items, form);
    }

    const interop_constructors = @import("../interop/constructors.zig");

    /// Resolve a class short name to its FQCN.
    /// Checks: 1) known_classes comptime table, 2) local Var value matching a FQCN.
    fn resolveClassFqcn(self: *Analyzer, class_short: []const u8) ?[]const u8 {
        // Check comptime known classes table
        if (interop_constructors.resolveClassName(class_short)) |fqcn| return fqcn;
        // Check if there's a local Var whose value is a FQCN string (from :import)
        if (self.env) |env| {
            if (env.current_ns) |ns| {
                if (ns.resolve(class_short)) |v| {
                    const root = v.root;
                    if (root.isNil()) return null;
                    if (root.tag() == .symbol) {
                        const sym = root.asSymbol();
                        if (sym.ns == null) {
                            // Check if the symbol name is a known FQCN
                            if (interop_constructors.resolveClassName(sym.name)) |_| return sym.name;
                            // Check if it looks like a FQCN (contains dots)
                            if (std.mem.indexOf(u8, sym.name, ".") != null) return sym.name;
                        }
                    }
                }
            }
        }
        return null;
    }

    /// Rewrite a constructor call to (__interop-new "fqcn" args...).
    fn rewriteConstructorCall(self: *Analyzer, fqcn: []const u8, ctor_args: []const Form, form: Form, first_item: Form) AnalyzeError!*Node {
        var rewritten = self.allocator.alloc(Form, ctor_args.len + 2) catch return error.OutOfMemory;
        rewritten[0] = .{
            .data = .{ .symbol = .{ .ns = null, .name = "__interop-new" } },
            .line = first_item.line, .column = first_item.column,
        };
        rewritten[1] = .{
            .data = .{ .string = fqcn },
            .line = first_item.line, .column = first_item.column,
        };
        @memcpy(rewritten[2..], ctor_args);
        return self.analyzeCall(rewritten, form);
    }

    const rewriteInteropCall = interop_rewrites.rewriteInteropCall;

    /// Check if a namespace prefix resolves to clojure.core.
    /// Handles: literal "clojure.core" or an alias pointing to clojure.core.
    fn isClojureCoreNs(self: *const Analyzer, ns_prefix: []const u8) bool {
        if (std.mem.eql(u8, ns_prefix, "clojure.core")) return true;
        const env = self.env orelse return false;
        const ns = env.current_ns orelse return false;
        const aliased = ns.aliases.get(ns_prefix) orelse return false;
        return std.mem.eql(u8, aliased.name, "clojure.core");
    }

    /// Resolve a symbol to a Var if possible (via env).
    fn resolveMacroVar(self: *const Analyzer, sym: SymbolRef) ?*Var {
        const env = self.env orelse return null;
        const ns = env.current_ns orelse return null;
        if (sym.ns) |ns_name| {
            // Try alias/own namespace first
            if (ns.resolveQualified(ns_name, sym.name)) |v| return v;
            // Fall back to full namespace name lookup in env
            if (env.findNamespace(ns_name)) |target_ns| {
                if (target_ns.resolve(sym.name)) |v| return v;
            }
            return null;
        }
        return ns.resolve(sym.name);
    }

    /// Expand a macro call: execute macro function with raw Form args, re-analyze result.
    fn expandMacro(self: *Analyzer, v: *Var, arg_forms: []const Form, form: Form) AnalyzeError!*Node {
        const root = v.deref();

        // Convert arg Forms to Values for the macro function
        var arg_vals: [512]Value = undefined;
        if (arg_forms.len > arg_vals.len) {
            return self.analysisError(.arity_error, "too many macro arguments", form);
        }
        const current_ns_ptr: ?*const @import("../runtime/namespace.zig").Namespace = if (self.env) |env| (if (env.current_ns) |ns| ns else null) else null;
        for (arg_forms, 0..) |af, i| {
            arg_vals[i] = macro.formToValueWithNs(self.allocator, af, current_ns_ptr) catch return error.OutOfMemory;
        }

        // Suppress GC during the entire macro expansion (callFnVal + valueToForm).
        // During macro execution, syntax-quote builds lazy seqs whose internal
        // Values may be swept by GC if they are only reachable through thunk
        // closures. Suppressing GC ensures these Values survive until
        // valueToForm copies all string data to the node_arena.
        const gc_inst = if (self.env) |e| e.gc else null;
        const MarkSweepGc = @import("../runtime/gc.zig").MarkSweepGc;
        if (gc_inst) |g| {
            const gc: *MarkSweepGc = @ptrCast(@alignCast(g));
            gc.suppressCollection();
        }
        defer if (gc_inst) |g| {
            const gc: *MarkSweepGc = @ptrCast(@alignCast(g));
            gc.unsuppressCollection();
        };

        // Call the macro function via unified dispatch
        const result_val: Value = bootstrap.callFnVal(self.allocator, root, arg_vals[0..arg_forms.len]) catch {
            return self.analysisError(.value_error, "macro expansion failed", form);
        };

        // Convert result Value back to Form
        var expanded_form = macro.valueToForm(self.allocator, result_val) catch return error.OutOfMemory;

        // Stamp original macro call source on top-level form if it lost source info
        if (expanded_form.line == 0 and form.line != 0) {
            expanded_form.line = form.line;
            expanded_form.column = form.column;
        }

        // Re-analyze the expanded form
        return self.analyze(expanded_form);
    }

    // === Special form implementations ===

    fn analyzeIf(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (if test then) or (if test then else)
        if (items.len < 3 or items.len > 4) {
            return self.analysisError(.arity_error, "if requires 2 or 3 arguments", form);
        }

        const test_node = try self.analyze(items[1]);
        const then_node = try self.analyze(items[2]);
        const else_node: ?*Node = if (items.len == 4)
            try self.analyze(items[3])
        else
            null;

        const if_data = self.allocator.create(node_mod.IfNode) catch return error.OutOfMemory;
        if_data.* = .{
            .test_node = test_node,
            .then_node = then_node,
            .else_node = else_node,
            .source = self.sourceFromForm(form),
        };

        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .if_node = if_data };
        return n;
    }

    fn analyzeDo(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (do expr1 expr2 ...)
        if (items.len == 1) {
            return self.makeConstant(Value.nil_val);
        }

        var statements = self.allocator.alloc(*Node, items.len - 1) catch return error.OutOfMemory;
        for (items[1..], 0..) |item, i| {
            statements[i] = try self.analyze(item);
        }

        const do_data = self.allocator.create(node_mod.DoNode) catch return error.OutOfMemory;
        do_data.* = .{
            .statements = statements,
            .source = self.sourceFromForm(form),
        };

        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .do_node = do_data };
        return n;
    }

    fn analyzeLet(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (let [bindings...] body...)
        if (items.len < 2) {
            return self.analysisError(.arity_error, "let requires binding vector", form);
        }

        if (items[1].data != .vector) {
            return self.analysisError(.value_error, "let bindings must be a vector", items[1]);
        }

        const binding_pairs = items[1].data.vector;
        if (binding_pairs.len % 2 != 0) {
            return self.analysisError(.value_error, "let bindings must have even number of forms", items[1]);
        }

        const start_locals = self.locals.items.len;

        // Process bindings with destructuring support
        var bindings_list: std.ArrayList(node_mod.LetBinding) = .empty;
        var i: usize = 0;
        while (i < binding_pairs.len) : (i += 2) {
            const init_node = try self.analyze(binding_pairs[i + 1]);
            try self.expandBindingPattern(binding_pairs[i], init_node, &bindings_list, form);
        }

        // Analyze body (wrap multiple exprs in do)
        const body = try self.analyzeBody(items[2..], form);

        // Pop locals
        self.locals.shrinkRetainingCapacity(start_locals);

        const let_data = self.allocator.create(node_mod.LetNode) catch return error.OutOfMemory;
        let_data.* = .{
            .bindings = bindings_list.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            .body = body,
            .source = self.sourceFromForm(form),
        };

        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .let_node = let_data };
        return n;
    }

    fn analyzeLetfn(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (letfn* [name1 fn-expr1 name2 fn-expr2 ...] body...)
        // All names are pre-registered before any init is analyzed,
        // enabling mutual recursion between the bound functions.
        if (items.len < 2) {
            return self.analysisError(.arity_error, "letfn requires binding vector", form);
        }

        if (items[1].data != .vector) {
            return self.analysisError(.value_error, "letfn bindings must be a vector", items[1]);
        }

        const binding_pairs = items[1].data.vector;
        if (binding_pairs.len % 2 != 0) {
            return self.analysisError(.value_error, "letfn bindings must have even number of forms", items[1]);
        }

        const start_locals = self.locals.items.len;

        // Step 1: Pre-register ALL names as locals (before analyzing any init)
        var i: usize = 0;
        while (i < binding_pairs.len) : (i += 2) {
            if (binding_pairs[i].data != .symbol) {
                return self.analysisError(.value_error, "letfn binding name must be a symbol", binding_pairs[i]);
            }
            const name = binding_pairs[i].data.symbol.name;
            const idx: u32 = @intCast(self.locals.items.len);
            self.locals.append(self.allocator, .{ .name = name, .idx = idx }) catch
                return error.OutOfMemory;
        }

        // Step 2: Analyze all init expressions (all names are now visible)
        var bindings_list: std.ArrayList(node_mod.LetBinding) = .empty;
        i = 0;
        while (i < binding_pairs.len) : (i += 2) {
            const name = binding_pairs[i].data.symbol.name;
            const init_node = try self.analyze(binding_pairs[i + 1]);
            bindings_list.append(self.allocator, .{ .name = name, .init = init_node }) catch
                return error.OutOfMemory;
        }

        // Step 3: Analyze body
        const body = try self.analyzeBody(items[2..], form);

        // Pop locals
        self.locals.shrinkRetainingCapacity(start_locals);

        const letfn_data = self.allocator.create(node_mod.LetfnNode) catch return error.OutOfMemory;
        letfn_data.* = .{
            .bindings = bindings_list.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            .body = body,
            .source = self.sourceFromForm(form),
        };

        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .letfn_node = letfn_data };
        return n;
    }

    /// Transform body forms with :pre/:post condition map into assert-wrapped body.
    /// If body_forms[0] is a map {:pre [...] :post [...]} and there are more body forms,
    /// extract conditions and synthesize assertion forms (matching upstream Clojure fn semantics).
    fn transformPrePost(self: *Analyzer, body_forms: []const Form) ![]const Form {
        if (body_forms.len < 2) return body_forms;
        if (body_forms[0].data != .map) return body_forms;

        const map_items = body_forms[0].data.map;
        var pre_conds: ?[]const Form = null;
        var post_conds: ?[]const Form = null;

        var i: usize = 0;
        while (i < map_items.len) : (i += 2) {
            if (i + 1 >= map_items.len) break;
            if (map_items[i].data == .keyword and map_items[i].data.keyword.ns == null) {
                if (std.mem.eql(u8, map_items[i].data.keyword.name, "pre")) {
                    if (map_items[i + 1].data == .vector) {
                        pre_conds = map_items[i + 1].data.vector;
                    }
                } else if (std.mem.eql(u8, map_items[i].data.keyword.name, "post")) {
                    if (map_items[i + 1].data == .vector) {
                        post_conds = map_items[i + 1].data.vector;
                    }
                }
            }
        }

        if (pre_conds == null and post_conds == null) return body_forms;

        const actual_body = body_forms[1..]; // skip condition map
        const alloc = self.allocator;

        // Build new body forms
        var new_body: std.ArrayList(Form) = .empty;

        // Pre-conditions: prepend (assert cond) for each
        if (pre_conds) |pres| {
            for (pres) |cond| {
                const assert_items = alloc.alloc(Form, 2) catch return error.OutOfMemory;
                assert_items[0] = .{ .data = .{ .symbol = .{ .ns = null, .name = "assert" } } };
                assert_items[1] = cond;
                new_body.append(alloc, .{ .data = .{ .list = assert_items } }) catch return error.OutOfMemory;
            }
        }

        if (post_conds) |posts| {
            // Post-conditions: wrap body in (let [% (do body...)] (assert c1) ... %)
            // Build the result expression
            const result_expr: Form = if (actual_body.len == 1)
                actual_body[0]
            else blk: {
                const do_items = alloc.alloc(Form, actual_body.len + 1) catch return error.OutOfMemory;
                do_items[0] = .{ .data = .{ .symbol = .{ .ns = null, .name = "do" } } };
                @memcpy(do_items[1..], actual_body);
                break :blk .{ .data = .{ .list = do_items } };
            };

            // Build let form: (let [% result-expr] (assert c1) ... %)
            const bindings = alloc.alloc(Form, 2) catch return error.OutOfMemory;
            bindings[0] = .{ .data = .{ .symbol = .{ .ns = null, .name = "%" } } };
            bindings[1] = result_expr;

            // let items: [let, [% expr], (assert c1), ..., %]
            const let_items = alloc.alloc(Form, 3 + posts.len) catch return error.OutOfMemory;
            let_items[0] = .{ .data = .{ .symbol = .{ .ns = null, .name = "let" } } };
            let_items[1] = .{ .data = .{ .vector = bindings } };
            for (posts, 0..) |cond, j| {
                const assert_items = alloc.alloc(Form, 2) catch return error.OutOfMemory;
                assert_items[0] = .{ .data = .{ .symbol = .{ .ns = null, .name = "assert" } } };
                assert_items[1] = cond;
                let_items[2 + j] = .{ .data = .{ .list = assert_items } };
            }
            let_items[let_items.len - 1] = .{ .data = .{ .symbol = .{ .ns = null, .name = "%" } } };

            new_body.append(alloc, .{ .data = .{ .list = let_items } }) catch return error.OutOfMemory;
        } else {
            // No post-conditions, just append original body
            for (actual_body) |bf| {
                new_body.append(alloc, bf) catch return error.OutOfMemory;
            }
        }

        return new_body.toOwnedSlice(alloc) catch return error.OutOfMemory;
    }

    /// Extract parameter vector from a form, handling (with-meta [params] meta) wrapper.
    /// Returns the vector items if the form is a vector or a with-meta-wrapped vector, null otherwise.
    fn extractParamVector(f: Form) ?[]const Form {
        if (f.data == .vector) return f.data.vector;
        if (f.data == .list) {
            const list = f.data.list;
            if (list.len == 3 and list[0].data == .symbol) {
                const sym = list[0].data.symbol;
                if (sym.ns == null and std.mem.eql(u8, sym.name, "with-meta") and list[1].data == .vector) {
                    return list[1].data.vector;
                }
            }
        }
        return null;
    }

    fn analyzeFn(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (fn name? docstring? [params] body...) or (fn name? docstring? ([params] body...) ...)
        if (items.len < 2) {
            return self.analysisError(.arity_error, "fn requires parameter vector", form);
        }

        var idx: usize = 1;
        var name: ?[]const u8 = null;

        // Optional name — plain symbol or (with-meta symbol meta) from defn macros
        if (items[idx].data == .symbol) {
            name = items[idx].data.symbol.name;
            idx += 1;
        } else if (items[idx].data == .list) {
            const nm_list = items[idx].data.list;
            if (nm_list.len == 3 and nm_list[0].data == .symbol and
                std.mem.eql(u8, nm_list[0].data.symbol.name, "with-meta") and
                nm_list[1].data == .symbol)
            {
                name = nm_list[1].data.symbol.name;
                idx += 1;
            }
        }

        if (idx >= items.len) {
            return self.analysisError(.arity_error, "fn requires parameter vector", form);
        }

        // Optional docstring (only after name, same as JVM)
        if (name != null and items[idx].data == .string) {
            idx += 1;
        }

        if (idx >= items.len) {
            return self.analysisError(.arity_error, "fn requires parameter vector", form);
        }

        // Named fn: register self-reference local
        const fn_name_locals_start = self.locals.items.len;
        if (name) |fn_name| {
            const fn_local_idx: u32 = @intCast(self.locals.items.len);
            self.locals.append(self.allocator, .{ .name = fn_name, .idx = fn_local_idx }) catch return error.OutOfMemory;
        }

        // Single arity: [params] body... (including ^Tag [params] body...)
        if (extractParamVector(items[idx])) |params| {
            const arity = try self.analyzeFnArity(params, items[idx + 1 ..], form);
            const arities = self.allocator.alloc(node_mod.FnArity, 1) catch return error.OutOfMemory;
            arities[0] = arity;

            self.locals.shrinkRetainingCapacity(fn_name_locals_start);

            const fn_data = self.allocator.create(node_mod.FnNode) catch return error.OutOfMemory;
            fn_data.* = .{
                .name = name,
                .arities = arities,
                .source = self.sourceFromForm(form),
            };

            const n = self.allocator.create(Node) catch return error.OutOfMemory;
            n.* = .{ .fn_node = fn_data };
            return n;
        }

        // Multi-arity: ([params] body...) ...
        var arities_list: std.ArrayList(node_mod.FnArity) = .empty;

        while (idx < items.len) {
            if (items[idx].data != .list) {
                return self.analysisError(.arity_error, "fn arity must be a list: ([params] body...)", form);
            }

            const arity_items = items[idx].data.list;
            const params = if (arity_items.len > 0) extractParamVector(arity_items[0]) else null;
            if (params == null) {
                return self.analysisError(.arity_error, "fn arity must start with parameter vector", form);
            }

            const arity = try self.analyzeFnArity(params.?, arity_items[1..], form);
            arities_list.append(self.allocator, arity) catch return error.OutOfMemory;

            idx += 1;
        }

        self.locals.shrinkRetainingCapacity(fn_name_locals_start);

        if (arities_list.items.len == 0) {
            return self.analysisError(.arity_error, "fn requires at least one arity", form);
        }

        const fn_data = self.allocator.create(node_mod.FnNode) catch return error.OutOfMemory;
        fn_data.* = .{
            .name = name,
            .arities = arities_list.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            .source = self.sourceFromForm(form),
        };

        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .fn_node = fn_data };
        return n;
    }

    fn analyzeFnArity(self: *Analyzer, params_form: []const Form, body_forms_raw: []const Form, form: Form) AnalyzeError!node_mod.FnArity {
        // Detect :pre/:post condition map: {:pre [...] :post [...]} as first body form
        const body_forms = try self.transformPrePost(body_forms_raw);

        var params: std.ArrayList([]const u8) = .empty;
        var variadic = false;

        // Track which params need destructuring (pattern_index -> synthetic_name)
        var destructure_patterns: std.ArrayList(DestructureEntry) = .empty;
        var has_destructuring = false;

        const start_locals = self.locals.items.len;

        var param_idx: usize = 0;
        for (params_form) |raw_p| {
            // Unwrap (with-meta <form> <meta-map>) — reader produces this for ^Type hints
            const p = if (raw_p.data == .list) blk: {
                const wm = raw_p.data.list;
                if (wm.len == 3 and wm[0].data == .symbol and
                    std.mem.eql(u8, wm[0].data.symbol.name, "with-meta"))
                    break :blk wm[1]; // unwrap to inner form (symbol, vector, or map)
                break :blk raw_p;
            } else raw_p;

            if (p.data == .symbol) {
                const param_name = p.data.symbol.name;

                if (std.mem.eql(u8, param_name, "&")) {
                    variadic = true;
                    continue;
                }

                params.append(self.allocator, param_name) catch return error.OutOfMemory;

                const idx: u32 = @intCast(self.locals.items.len);
                self.locals.append(self.allocator, .{ .name = param_name, .idx = idx }) catch return error.OutOfMemory;
            } else if (p.data == .vector or p.data == .map) {
                // Destructuring param: generate synthetic name __p0__, __p1__, etc.
                const syn_name = try self.makeSyntheticParamName(param_idx);
                params.append(self.allocator, syn_name) catch return error.OutOfMemory;

                const idx: u32 = @intCast(self.locals.items.len);
                self.locals.append(self.allocator, .{ .name = syn_name, .idx = idx }) catch return error.OutOfMemory;

                destructure_patterns.append(self.allocator, .{
                    .pattern = p,
                    .syn_name = syn_name,
                    .syn_idx = idx,
                }) catch return error.OutOfMemory;
                has_destructuring = true;
            } else {
                return self.analysisError(.value_error, "fn parameter must be a symbol, vector, or map", p);
            }
            param_idx += 1;
        }

        if (has_destructuring) {
            // Expand destructuring patterns into let bindings that wrap the body
            var bindings_list: std.ArrayList(node_mod.LetBinding) = .empty;
            for (destructure_patterns.items) |entry| {
                const ref_node = try self.makeTempLocalRef(entry.syn_name, entry.syn_idx);
                // Note: for variadic map patterns (fn [& {:keys [x]}] ...),
                // we pass the raw rest args and let expandMapPattern's __seq-to-map
                // handle coercion. This supports Clojure 1.11 semantics where
                // (f {:a 1}) passes the map directly rather than as key-value pairs.
                try self.expandBindingPattern(entry.pattern, ref_node, &bindings_list, form);
            }

            const inner_body = try self.analyzeBody(body_forms, form);

            // Wrap body in let node with destructuring bindings
            const let_data = self.allocator.create(node_mod.LetNode) catch return error.OutOfMemory;
            let_data.* = .{
                .bindings = bindings_list.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
                .body = inner_body,
                .source = self.sourceFromForm(form),
            };
            const body = self.allocator.create(Node) catch return error.OutOfMemory;
            body.* = .{ .let_node = let_data };

            self.locals.shrinkRetainingCapacity(start_locals);

            return .{
                .params = params.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
                .variadic = variadic,
                .body = body,
            };
        }

        const body = try self.analyzeBody(body_forms, form);

        self.locals.shrinkRetainingCapacity(start_locals);

        return .{
            .params = params.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            .variadic = variadic,
            .body = body,
        };
    }

    const DestructureEntry = struct {
        pattern: Form,
        syn_name: []const u8,
        syn_idx: u32,
    };

    fn makeSyntheticParamName(self: *Analyzer, idx: usize) AnalyzeError![]const u8 {
        // Generate __p0__, __p1__, etc.
        var buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "__p{d}__", .{idx}) catch return error.OutOfMemory;
        const owned = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
        return owned;
    }

    fn analyzeDef(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (def name) or (def name value) or (def name "doc" value)
        // (def ^:dynamic name value) → reader produces (def (with-meta name {:dynamic true}) value)
        if (items.len < 2 or items.len > 4) {
            return self.analysisError(.arity_error, "def requires 1, 2, or 3 arguments", form);
        }

        var sym_name: []const u8 = undefined;
        var is_dynamic = false;
        var is_private = false;
        var is_const = false;
        var doc: ?[]const u8 = null;

        // Extract symbol name and metadata from potentially nested (with-meta ...) forms
        // Supports: sym, (with-meta sym meta), (with-meta (with-meta sym meta1) meta2), etc.
        {
            var current = items[1];
            // Unwrap nested (with-meta ...) forms, collecting metadata at each level
            while (current.data == .list) {
                const wm_items = current.data.list;
                if (wm_items.len == 3 and wm_items[0].data == .symbol and
                    std.mem.eql(u8, wm_items[0].data.symbol.name, "with-meta"))
                {
                    // Parse metadata map for :dynamic, :private, :const, :doc
                    if (wm_items[2].data == .map) {
                        const meta_entries = wm_items[2].data.map;
                        var mi: usize = 0;
                        while (mi + 1 < meta_entries.len) : (mi += 2) {
                            if (meta_entries[mi].data == .keyword) {
                                const kw_name = meta_entries[mi].data.keyword.name;
                                if (meta_entries[mi + 1].data == .boolean and
                                    meta_entries[mi + 1].data.boolean)
                                {
                                    if (std.mem.eql(u8, kw_name, "dynamic")) {
                                        is_dynamic = true;
                                    } else if (std.mem.eql(u8, kw_name, "private")) {
                                        is_private = true;
                                    } else if (std.mem.eql(u8, kw_name, "const")) {
                                        is_const = true;
                                    }
                                } else if (std.mem.eql(u8, kw_name, "doc") and
                                    meta_entries[mi + 1].data == .string)
                                {
                                    doc = meta_entries[mi + 1].data.string;
                                }
                            }
                        }
                    }
                    current = wm_items[1];
                } else {
                    return self.analysisError(.value_error, "def name must be a symbol", items[1]);
                }
            }
            if (current.data != .symbol) {
                return self.analysisError(.value_error, "def name must be a symbol", items[1]);
            }
            sym_name = current.data.symbol.name;
        }

        // (def name "doc" value) — inline docstring form
        if (items.len == 4) {
            if (items[2].data == .string) {
                doc = items[2].data.string;
            } else {
                return self.analysisError(.value_error, "def docstring must be a string", items[2]);
            }
        }

        const init_node: ?*Node = if (items.len == 4)
            try self.analyze(items[3])
        else if (items.len == 3)
            try self.analyze(items[2])
        else
            null;

        // Extract arglists from fn init form for Var metadata.
        var arglists: ?[]const u8 = null;
        if (init_node) |in| {
            if (in.* == .fn_node) {
                arglists = buildArglistsStr(self.allocator, in.fn_node) catch null;
            }
        }

        const def_data = self.allocator.create(node_mod.DefNode) catch return error.OutOfMemory;
        def_data.* = .{
            .sym_name = sym_name,
            .init = init_node,
            .is_dynamic = is_dynamic,
            .is_private = is_private,
            .is_const = is_const,
            .doc = doc,
            .arglists = arglists,
            .source = self.sourceFromForm(form),
        };

        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .def_node = def_data };
        return n;
    }

    fn analyzeQuote(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (quote form)
        if (items.len != 2) {
            return self.analysisError(.arity_error, "quote requires exactly 1 argument", form);
        }

        const quote_ns_ptr: ?*const @import("../runtime/namespace.zig").Namespace = if (self.env) |env| (if (env.current_ns) |ns| ns else null) else null;
        const val = macro.formToValueWithNs(self.allocator, items[1], quote_ns_ptr) catch return error.OutOfMemory;

        const quote_data = self.allocator.create(node_mod.QuoteNode) catch return error.OutOfMemory;
        quote_data.* = .{
            .value = val,
            .source = self.sourceFromForm(form),
        };

        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .quote_node = quote_data };
        return n;
    }

    fn analyzeDefmacro(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (defmacro name docstring? attr-map? [params] body...)
        // (defmacro name docstring? attr-map? ([params] body...) ...)
        if (items.len < 3) {
            return self.analysisError(.arity_error, "defmacro requires name and body", form);
        }

        // Extract name — handle both plain symbol and (with-meta symbol map)
        const sym_name = if (items[1].data == .symbol)
            items[1].data.symbol.name
        else if (items[1].data == .list and items[1].data.list.len == 3 and
            items[1].data.list[0].data == .symbol and
            std.mem.eql(u8, items[1].data.list[0].data.symbol.name, "with-meta") and
            items[1].data.list[1].data == .symbol)
            items[1].data.list[1].data.symbol.name
        else
            return self.analysisError(.value_error, "defmacro name must be a symbol", items[1]);

        // Skip optional docstring and attr-map
        var body_start: usize = 2;
        if (body_start < items.len and items[body_start].data == .string) {
            body_start += 1;
        }
        if (body_start < items.len and items[body_start].data == .map) {
            body_start += 1;
        }

        if (body_start >= items.len) {
            return self.analysisError(.arity_error, "defmacro requires parameter vector", form);
        }

        // Build fn node — supports both single and multi-arity
        var fn_node: *Node = undefined;

        if (items[body_start].data == .vector) {
            // Single arity: [params] body...
            const arity = try self.analyzeFnArity(items[body_start].data.vector, items[body_start + 1 ..], form);
            const arities = self.allocator.alloc(node_mod.FnArity, 1) catch return error.OutOfMemory;
            arities[0] = arity;

            const fn_data = self.allocator.create(node_mod.FnNode) catch return error.OutOfMemory;
            fn_data.* = .{
                .name = null,
                .arities = arities,
                .source = self.sourceFromForm(form),
            };

            fn_node = self.allocator.create(Node) catch return error.OutOfMemory;
            fn_node.* = .{ .fn_node = fn_data };
        } else {
            // Multi-arity: ([params] body...) ...
            var arities_list: std.ArrayList(node_mod.FnArity) = .empty;
            var idx = body_start;

            while (idx < items.len) {
                if (items[idx].data != .list) {
                    return self.analysisError(.arity_error, "defmacro arity must be a list: ([params] body...)", form);
                }

                const arity_items = items[idx].data.list;
                if (arity_items.len == 0 or arity_items[0].data != .vector) {
                    return self.analysisError(.arity_error, "defmacro arity must start with parameter vector", form);
                }

                const arity = try self.analyzeFnArity(arity_items[0].data.vector, arity_items[1..], form);
                arities_list.append(self.allocator, arity) catch return error.OutOfMemory;

                idx += 1;
            }

            if (arities_list.items.len == 0) {
                return self.analysisError(.arity_error, "defmacro requires at least one arity", form);
            }

            const fn_data = self.allocator.create(node_mod.FnNode) catch return error.OutOfMemory;
            fn_data.* = .{
                .name = null,
                .arities = arities_list.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
                .source = self.sourceFromForm(form),
            };

            fn_node = self.allocator.create(Node) catch return error.OutOfMemory;
            fn_node.* = .{ .fn_node = fn_data };
        }

        const def_data = self.allocator.create(node_mod.DefNode) catch return error.OutOfMemory;
        def_data.* = .{
            .sym_name = sym_name,
            .init = fn_node,
            .is_macro = true,
            .source = self.sourceFromForm(form),
        };

        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .def_node = def_data };
        return n;
    }

    fn analyzeLoop(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (loop [bindings...] body...)
        if (items.len < 2) {
            return self.analysisError(.arity_error, "loop requires binding vector", form);
        }

        if (items[1].data != .vector) {
            return self.analysisError(.value_error, "loop bindings must be a vector", items[1]);
        }

        const binding_pairs = items[1].data.vector;
        if (binding_pairs.len % 2 != 0) {
            return self.analysisError(.value_error, "loop bindings must have even number of forms", items[1]);
        }

        // Check if any binding uses destructuring patterns
        var has_destructuring = false;
        {
            var ci: usize = 0;
            while (ci < binding_pairs.len) : (ci += 2) {
                if (binding_pairs[ci].data != .symbol) {
                    has_destructuring = true;
                    break;
                }
            }
        }

        const start_locals = self.locals.items.len;

        if (!has_destructuring) {
            // Simple case: all bindings are symbols — no transformation needed
            var bindings_list: std.ArrayList(node_mod.LetBinding) = .empty;
            var i: usize = 0;
            while (i < binding_pairs.len) : (i += 2) {
                const init_node = try self.analyze(binding_pairs[i + 1]);
                try self.expandBindingPattern(binding_pairs[i], init_node, &bindings_list, form);
            }

            const body = try self.analyzeBody(items[2..], form);
            self.locals.shrinkRetainingCapacity(start_locals);

            const loop_data = self.allocator.create(node_mod.LoopNode) catch return error.OutOfMemory;
            loop_data.* = .{
                .bindings = bindings_list.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
                .body = body,
                .source = self.sourceFromForm(form),
            };

            const n = self.allocator.create(Node) catch return error.OutOfMemory;
            n.* = .{ .loop_node = loop_data };
            return n;
        }

        // Destructuring case: transform to temp recur targets + inner let.
        // (loop [[x & etc :as xs] coll] body)
        // becomes:
        // (loop [__loop_0__ coll]
        //   (let [[x & etc :as xs] __loop_0__]
        //     body))
        const pair_count = binding_pairs.len / 2;

        // Phase 1: Create recur-target bindings (simple symbols only)
        var loop_bindings: std.ArrayList(node_mod.LetBinding) = .empty;
        const temp_names = self.allocator.alloc([]const u8, pair_count) catch return error.OutOfMemory;
        const temp_indices = self.allocator.alloc(u32, pair_count) catch return error.OutOfMemory;
        const is_destructured = self.allocator.alloc(bool, pair_count) catch return error.OutOfMemory;

        var i: usize = 0;
        var pair_idx: usize = 0;
        while (i < binding_pairs.len) : ({
            i += 2;
            pair_idx += 1;
        }) {
            const pattern = binding_pairs[i];
            const init_node = try self.analyze(binding_pairs[i + 1]);

            if (pattern.data == .symbol) {
                // Simple symbol: use directly as recur target
                const name = pattern.data.symbol.name;
                temp_names[pair_idx] = name;
                is_destructured[pair_idx] = false;

                const idx: u32 = @intCast(self.locals.items.len);
                temp_indices[pair_idx] = idx;
                self.locals.append(self.allocator, .{ .name = name, .idx = idx }) catch return error.OutOfMemory;
                loop_bindings.append(self.allocator, .{ .name = name, .init = init_node }) catch return error.OutOfMemory;
            } else {
                // Destructuring pattern: create temp var as recur target
                const temp_name = std.fmt.allocPrint(self.allocator, "__loop_{d}__", .{pair_idx}) catch return error.OutOfMemory;
                temp_names[pair_idx] = temp_name;
                is_destructured[pair_idx] = true;

                const idx: u32 = @intCast(self.locals.items.len);
                temp_indices[pair_idx] = idx;
                self.locals.append(self.allocator, .{ .name = temp_name, .idx = idx }) catch return error.OutOfMemory;
                loop_bindings.append(self.allocator, .{ .name = temp_name, .init = init_node }) catch return error.OutOfMemory;
            }
        }

        // Phase 2: Create inner let bindings that destructure from temp vars
        var let_bindings: std.ArrayList(node_mod.LetBinding) = .empty;
        pair_idx = 0;
        i = 0;
        while (i < binding_pairs.len) : ({
            i += 2;
            pair_idx += 1;
        }) {
            if (is_destructured[pair_idx]) {
                const temp_ref = try self.makeTempLocalRef(temp_names[pair_idx], temp_indices[pair_idx]);
                try self.expandBindingPattern(binding_pairs[i], temp_ref, &let_bindings, form);
            }
        }

        // Phase 3: Wrap body in inner let for destructuring
        const inner_body = try self.analyzeBody(items[2..], form);

        var body: *Node = undefined;
        if (let_bindings.items.len > 0) {
            const let_data = self.allocator.create(node_mod.LetNode) catch return error.OutOfMemory;
            let_data.* = .{
                .bindings = let_bindings.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
                .body = inner_body,
                .source = self.sourceFromForm(form),
            };
            body = self.allocator.create(Node) catch return error.OutOfMemory;
            body.* = .{ .let_node = let_data };
        } else {
            body = inner_body;
        }

        self.locals.shrinkRetainingCapacity(start_locals);

        const loop_data = self.allocator.create(node_mod.LoopNode) catch return error.OutOfMemory;
        loop_data.* = .{
            .bindings = loop_bindings.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            .body = body,
            .source = self.sourceFromForm(form),
        };

        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .loop_node = loop_data };
        return n;
    }

    fn analyzeFor(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (for [bindings...] body)
        // bindings: sym coll [:when test] [:let [binds]] [:while test] sym coll ...
        if (items.len < 3) {
            return self.analysisError(.arity_error, "for requires a binding vector and body", form);
        }
        if (items[1].data != .vector) {
            return self.analysisError(.value_error, "for bindings must be a vector", items[1]);
        }
        const bindings = items[1].data.vector;
        const body_forms = items[2..];

        return self.expandForBindings(bindings, body_forms, form);
    }

    /// Recursively expand for bindings into map/mapcat calls.
    fn expandForBindings(
        self: *Analyzer,
        bindings: []const Form,
        body_forms: []const Form,
        form: Form,
    ) AnalyzeError!*Node {
        if (bindings.len < 2) {
            return self.analysisError(.value_error, "for requires at least one binding pair", form);
        }

        const sym_form = bindings[0];
        const coll_form = bindings[1];

        // Collect modifiers (:when, :let, :while) after this binding pair
        var mod_idx: usize = 2;
        var when_forms: std.ArrayList(Form) = .empty;
        var let_forms: std.ArrayList(Form) = .empty;
        var while_forms: std.ArrayList(Form) = .empty;
        // Track how many :when forms precede each :while (for correct :when/:while ordering)
        var when_count_at_while: std.ArrayList(usize) = .empty;
        while (mod_idx < bindings.len) {
            if (bindings[mod_idx].data == .keyword) {
                const kw = bindings[mod_idx].data.keyword.name;
                if (std.mem.eql(u8, kw, "when")) {
                    if (mod_idx + 1 >= bindings.len) {
                        return self.analysisError(.value_error, ":when requires a test expression", form);
                    }
                    when_forms.append(self.allocator, bindings[mod_idx + 1]) catch return error.OutOfMemory;
                    mod_idx += 2;
                } else if (std.mem.eql(u8, kw, "let")) {
                    if (mod_idx + 1 >= bindings.len or bindings[mod_idx + 1].data != .vector) {
                        return self.analysisError(.value_error, ":let requires a binding vector", form);
                    }
                    let_forms.append(self.allocator, bindings[mod_idx + 1]) catch return error.OutOfMemory;
                    mod_idx += 2;
                } else if (std.mem.eql(u8, kw, "while")) {
                    if (mod_idx + 1 >= bindings.len) {
                        return self.analysisError(.value_error, ":while requires a test expression", form);
                    }
                    when_count_at_while.append(self.allocator, when_forms.items.len) catch return error.OutOfMemory;
                    while_forms.append(self.allocator, bindings[mod_idx + 1]) catch return error.OutOfMemory;
                    mod_idx += 2;
                } else {
                    break; // unknown keyword = start of next binding
                }
            } else {
                break; // next binding pair
            }
        }

        const remaining_bindings = bindings[mod_idx..];
        const is_last = remaining_bindings.len == 0;

        // Analyze collection expression
        var coll_node = try self.analyze(coll_form);

        // Build the fn body
        const start_locals = self.locals.items.len;

        // Bind the iteration variable
        if (sym_form.data != .symbol and sym_form.data != .vector and sym_form.data != .map) {
            return self.analysisError(.value_error, "for binding must be a symbol, vector, or map", sym_form);
        }

        // Register param (simple symbol or destructuring)
        var param_name: []const u8 = undefined;
        var needs_destructure = false;
        if (sym_form.data == .symbol) {
            param_name = sym_form.data.symbol.name;
        } else {
            // Destructuring: use synthetic param
            param_name = try self.makeSyntheticParamName(0);
            needs_destructure = true;
        }
        const param_idx: u32 = @intCast(self.locals.items.len);
        self.locals.append(self.allocator, .{ .name = param_name, .idx = param_idx }) catch return error.OutOfMemory;

        // Apply :while by wrapping coll with take-while
        // When :when precedes :while on same binding, guard the take-while predicate
        // so :when-false elements pass through (to be filtered later by :when in body).
        // Clojure semantics: (for [a coll :when P :while Q] body)
        //   → P false: skip element (don't check Q)
        //   → P true, Q true: include
        //   → P true, Q false: terminate
        // Predicate: (fn [a] (if P Q true)) instead of (fn [a] Q)
        for (while_forms.items, 0..) |while_form, while_idx| {
            var while_test = try self.analyze(while_form);

            // Guard with preceding :when conditions
            const guard_count = when_count_at_while.items[while_idx];
            if (guard_count > 0) {
                // Build: (if when_1 (if when_2 ... while_test ... true) true)
                const true_val = try self.makeConstant(Value.true_val);
                var g: usize = guard_count;
                while (g > 0) {
                    g -= 1;
                    const when_guard = try self.analyze(when_forms.items[g]);
                    const guard_if = self.allocator.create(node_mod.IfNode) catch return error.OutOfMemory;
                    guard_if.* = .{
                        .test_node = when_guard,
                        .then_node = while_test,
                        .else_node = true_val,
                        .source = self.sourceFromForm(form),
                    };
                    const guard_node = self.allocator.create(Node) catch return error.OutOfMemory;
                    guard_node.* = .{ .if_node = guard_if };
                    while_test = guard_node;
                }
            }

            // Build predicate fn: (fn [param] while_test)
            const tw_params = self.allocator.alloc([]const u8, 1) catch return error.OutOfMemory;
            tw_params[0] = param_name;
            const tw_arities = self.allocator.alloc(node_mod.FnArity, 1) catch return error.OutOfMemory;
            tw_arities[0] = .{
                .params = tw_params,
                .variadic = false,
                .body = while_test,
            };
            const tw_fn_data = self.allocator.create(node_mod.FnNode) catch return error.OutOfMemory;
            tw_fn_data.* = .{
                .name = null,
                .arities = tw_arities,
                .source = self.sourceFromForm(form),
            };
            const tw_fn_node = self.allocator.create(Node) catch return error.OutOfMemory;
            tw_fn_node.* = .{ .fn_node = tw_fn_data };

            // Build call: (take-while pred coll)
            const tw_ref = self.allocator.create(Node) catch return error.OutOfMemory;
            tw_ref.* = .{ .var_ref = .{ .ns = null, .name = "take-while", .source = .{} } };
            const tw_call_data = self.allocator.create(node_mod.CallNode) catch return error.OutOfMemory;
            const tw_call_args = self.allocator.alloc(*Node, 2) catch return error.OutOfMemory;
            tw_call_args[0] = tw_fn_node;
            tw_call_args[1] = coll_node;
            tw_call_data.* = .{
                .callee = tw_ref,
                .args = tw_call_args,
                .source = self.sourceFromForm(form),
            };
            const tw_call_node = self.allocator.create(Node) catch return error.OutOfMemory;
            tw_call_node.* = .{ .call_node = tw_call_data };
            coll_node = tw_call_node;
        }

        // Apply :let bindings BEFORE analyzing body (so body can reference :let vars)
        var let_bindings_list: std.ArrayList(node_mod.LetBinding) = .empty;
        for (let_forms.items) |let_form| {
            const let_binds = let_form.data.vector;
            if (let_binds.len % 2 != 0) {
                return self.analysisError(.value_error, ":let bindings must have even number of forms", form);
            }
            var j: usize = 0;
            while (j < let_binds.len) : (j += 2) {
                const init_node = try self.analyze(let_binds[j + 1]);
                try self.expandBindingPattern(let_binds[j], init_node, &let_bindings_list, form);
            }
        }

        // Pre-expand destructuring pattern BEFORE analyzing body
        // This adds destructured vars (a, b from [a b]) to locals so they're in scope
        var destr_bindings: std.ArrayList(node_mod.LetBinding) = .empty;
        if (needs_destructure) {
            const ref = try self.makeTempLocalRef(param_name, param_idx);
            try self.expandBindingPattern(sym_form, ref, &destr_bindings, form);
        }

        // Build fn body - all vars (including destructured) now in scope
        var fn_body: *Node = undefined;

        if (is_last) {
            fn_body = try self.analyzeBody(body_forms, form);
        } else {
            fn_body = try self.expandForBindings(remaining_bindings, body_forms, form);
        }

        // Wrap with :when guards FIRST (inner), then :let (outer)
        // so that :let vars are available in :when tests
        for (when_forms.items) |when_form| {
            const test_node = try self.analyze(when_form);
            if (is_last) {
                // Wrap in (if test (list body) (list)) for filter behavior
                const body_vec_args = self.allocator.alloc(*Node, 1) catch return error.OutOfMemory;
                body_vec_args[0] = fn_body;
                const body_as_list = try self.makeBuiltinCall("list", body_vec_args);

                const empty_list_args = self.allocator.alloc(*Node, 0) catch return error.OutOfMemory;
                const empty_list = try self.makeBuiltinCall("list", empty_list_args);

                const if_data = self.allocator.create(node_mod.IfNode) catch return error.OutOfMemory;
                if_data.* = .{
                    .test_node = test_node,
                    .then_node = body_as_list,
                    .else_node = empty_list,
                    .source = self.sourceFromForm(form),
                };
                fn_body = self.allocator.create(Node) catch return error.OutOfMemory;
                fn_body.* = .{ .if_node = if_data };
            } else {
                // For non-innermost: wrap in (if test inner-for [])
                const empty_list_args = self.allocator.alloc(*Node, 0) catch return error.OutOfMemory;
                const empty_list = try self.makeBuiltinCall("list", empty_list_args);

                const if_data = self.allocator.create(node_mod.IfNode) catch return error.OutOfMemory;
                if_data.* = .{
                    .test_node = test_node,
                    .then_node = fn_body,
                    .else_node = empty_list,
                    .source = self.sourceFromForm(form),
                };
                fn_body = self.allocator.create(Node) catch return error.OutOfMemory;
                fn_body.* = .{ .if_node = if_data };
            }
        }

        // Wrap with :let bindings (outer) so vars are available to :when tests
        if (let_bindings_list.items.len > 0) {
            const let_data = self.allocator.create(node_mod.LetNode) catch return error.OutOfMemory;
            let_data.* = .{
                .bindings = let_bindings_list.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
                .body = fn_body,
                .source = self.sourceFromForm(form),
            };
            fn_body = self.allocator.create(Node) catch return error.OutOfMemory;
            fn_body.* = .{ .let_node = let_data };
        }

        // Wrap with pre-built destructure bindings
        if (destr_bindings.items.len > 0) {
            const let_data = self.allocator.create(node_mod.LetNode) catch return error.OutOfMemory;
            let_data.* = .{
                .bindings = destr_bindings.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
                .body = fn_body,
                .source = self.sourceFromForm(form),
            };
            fn_body = self.allocator.create(Node) catch return error.OutOfMemory;
            fn_body.* = .{ .let_node = let_data };
        }

        self.locals.shrinkRetainingCapacity(start_locals);

        // Build the fn node: (fn [sym] fn_body)
        const params = self.allocator.alloc([]const u8, 1) catch return error.OutOfMemory;
        params[0] = param_name;
        const arities = self.allocator.alloc(node_mod.FnArity, 1) catch return error.OutOfMemory;
        arities[0] = .{
            .params = params,
            .variadic = false,
            .body = fn_body,
        };
        const fn_data = self.allocator.create(node_mod.FnNode) catch return error.OutOfMemory;
        fn_data.* = .{
            .name = null,
            .arities = arities,
            .source = self.sourceFromForm(form),
        };
        const fn_node = self.allocator.create(Node) catch return error.OutOfMemory;
        fn_node.* = .{ .fn_node = fn_data };

        // Build the call: map (innermost) or mapcat (nested/when)
        const use_flatten = !is_last or when_forms.items.len > 0;

        if (!use_flatten) {
            // (map fn coll)
            const map_args = self.allocator.alloc(*Node, 2) catch return error.OutOfMemory;
            map_args[0] = fn_node;
            map_args[1] = coll_node;
            return try self.makeBuiltinCall("map", map_args);
        }

        // (mapcat fn coll) — lazy concatenation of mapped results
        const mapcat_ref = self.allocator.create(Node) catch return error.OutOfMemory;
        mapcat_ref.* = .{ .var_ref = .{ .ns = null, .name = "mapcat", .source = .{} } };
        const mc_call_data = self.allocator.create(node_mod.CallNode) catch return error.OutOfMemory;
        const mc_call_args = self.allocator.alloc(*Node, 2) catch return error.OutOfMemory;
        mc_call_args[0] = fn_node;
        mc_call_args[1] = coll_node;
        mc_call_data.* = .{
            .callee = mapcat_ref,
            .args = mc_call_args,
            .source = self.sourceFromForm(form),
        };
        const mc_call_node = self.allocator.create(Node) catch return error.OutOfMemory;
        mc_call_node.* = .{ .call_node = mc_call_data };
        return mc_call_node;
    }

    fn analyzeDefprotocol(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (defprotocol Name (method1 [this]) (method2 [this arg]) ...)
        if (items.len < 2) {
            return self.analysisError(.arity_error, "defprotocol requires a name", form);
        }
        if (items[1].data != .symbol) {
            return self.analysisError(.value_error, "defprotocol name must be a symbol", items[1]);
        }

        const name = items[1].data.symbol.name;
        const method_forms = items[2..];

        var sigs: std.ArrayList(node_mod.MethodSigNode) = .empty;
        for (method_forms) |mf| {
            // Skip docstrings and keyword options (e.g. :extend-via-metadata true)
            if (mf.data == .string or mf.data == .keyword or mf.data == .boolean) continue;
            if (mf.data != .list) {
                return self.analysisError(.value_error, "defprotocol method must be a list", mf);
            }
            const m_items = mf.data.list;
            if (m_items.len < 2) {
                return self.analysisError(.arity_error, "method requires name and arglist", mf);
            }
            if (m_items[0].data != .symbol) {
                return self.analysisError(.value_error, "method name must be a symbol", m_items[0]);
            }
            if (m_items[1].data != .vector) {
                return self.analysisError(.value_error, "method arglist must be a vector", m_items[1]);
            }
            // Method must take at least one arg (the 'this' parameter)
            if (m_items[1].data.vector.len == 0) {
                return self.analysisError(.value_error, "Definition of function in protocol must take at least one arg", mf);
            }
            // Check for duplicate method names
            const method_name = m_items[0].data.symbol.name;
            for (sigs.items) |existing| {
                if (std.mem.eql(u8, existing.name, method_name)) {
                    return self.analysisError(.value_error, "Function in protocol was redefined. Specify all arities in single definition", mf);
                }
            }
            sigs.append(self.allocator, .{
                .name = method_name,
                .arity = @intCast(m_items[1].data.vector.len),
            }) catch return error.OutOfMemory;
        }

        const dp = self.allocator.create(node_mod.DefProtocolNode) catch return error.OutOfMemory;
        dp.* = .{
            .name = name,
            .method_sigs = sigs.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            .source = self.sourceFromForm(form),
        };

        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .defprotocol_node = dp };
        return n;
    }

    fn analyzeExtendType(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (extend-type TypeName Protocol (method [args] body) ...)
        if (items.len < 3) {
            return self.analysisError(.arity_error, "extend-type requires type, protocol, and methods", form);
        }

        // Type name (symbol, e.g. String, Integer, nil)
        // nil comes as a nil literal from macro expansion, not a symbol
        const type_name = if (items[1].data == .symbol)
            items[1].data.symbol.name
        else if (items[1].data == .nil)
            "nil"
        else {
            return self.analysisError(.value_error, "extend-type type must be a symbol", items[1]);
        };

        // Protocol name (may be namespace-qualified, e.g. clojure.core.protocols/CollReduce)
        if (items[2].data != .symbol) {
            return self.analysisError(.value_error, "extend-type protocol must be a symbol", items[2]);
        }
        const protocol_ns = items[2].data.symbol.ns;
        const protocol_name = items[2].data.symbol.name;

        // Methods
        const method_forms = items[3..];
        var methods: std.ArrayList(node_mod.ExtendMethodNode) = .empty;

        for (method_forms) |mf| {
            if (mf.data != .list) {
                return self.analysisError(.value_error, "extend-type method must be a list", mf);
            }
            const m_items = mf.data.list;
            if (m_items.len < 3) {
                return self.analysisError(.arity_error, "method requires name, arglist, body", mf);
            }
            if (m_items[0].data != .symbol) {
                return self.analysisError(.value_error, "method name must be a symbol", m_items[0]);
            }
            const method_name = m_items[0].data.symbol.name;

            // Build fn node from method: (fn [args] body)
            // Reuse analyzeFnInner logic: construct items as if (fn [args] body)
            const fn_items = self.allocator.alloc(Form, m_items.len) catch return error.OutOfMemory;
            fn_items[0] = m_items[0]; // name (used as fn name is optional, use method name)
            @memcpy(fn_items[1..], m_items[1..]);

            // Analyze as (fn method-name [args] body)
            const fn_node = try self.analyzeFn(fn_items, mf);
            // fn_node should be .fn_node
            methods.append(self.allocator, .{
                .name = method_name,
                .fn_node = fn_node.fn_node,
            }) catch return error.OutOfMemory;
        }

        const et = self.allocator.create(node_mod.ExtendTypeNode) catch return error.OutOfMemory;
        et.* = .{
            .type_name = type_name,
            .protocol_ns = protocol_ns,
            .protocol_name = protocol_name,
            .methods = methods.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            .source = self.sourceFromForm(form),
        };

        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .extend_type_node = et };
        return n;
    }

    fn analyzeReify(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (reify Protocol1 (method1 [args] body) ... Protocol2 ...)
        if (items.len < 2) {
            return self.analysisError(.arity_error, "reify requires at least a protocol and method", form);
        }

        var protocols: std.ArrayList(node_mod.ReifyProtocol) = .empty;
        var i: usize = 1; // skip 'reify'
        while (i < items.len) {
            // Expect protocol name (symbol)
            if (items[i].data != .symbol) {
                return self.analysisError(.value_error, "reify expects protocol name", items[i]);
            }
            const protocol_ns = items[i].data.symbol.ns;
            const protocol_name = items[i].data.symbol.name;
            i += 1;

            // Collect methods until we hit another symbol (next protocol) or end
            var methods: std.ArrayList(node_mod.ExtendMethodNode) = .empty;
            while (i < items.len and items[i].data == .list) {
                const m_items = items[i].data.list;
                if (m_items.len < 3) {
                    return self.analysisError(.arity_error, "reify method requires name, arglist, body", items[i]);
                }
                if (m_items[0].data != .symbol) {
                    return self.analysisError(.value_error, "method name must be a symbol", m_items[0]);
                }
                const method_name = m_items[0].data.symbol.name;
                const fn_items = self.allocator.alloc(Form, m_items.len) catch return error.OutOfMemory;
                fn_items[0] = m_items[0];
                @memcpy(fn_items[1..], m_items[1..]);
                const fn_node = try self.analyzeFn(fn_items, items[i]);
                methods.append(self.allocator, .{
                    .name = method_name,
                    .fn_node = fn_node.fn_node,
                }) catch return error.OutOfMemory;
                i += 1;
            }

            protocols.append(self.allocator, .{
                .protocol_ns = protocol_ns,
                .protocol_name = protocol_name,
                .methods = methods.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            }) catch return error.OutOfMemory;
        }

        const reify = self.allocator.create(node_mod.ReifyNode) catch return error.OutOfMemory;
        reify.* = .{
            .protocols = protocols.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            .source = self.sourceFromForm(form),
        };
        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .reify_node = reify };
        return n;
    }

    fn analyzeDefrecord(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (defrecord Name [fields])
        // Expand to:
        //   (do
        //     (def ->Name (fn ->Name [field1 field2 ...] (hash-map :field1 field1 ...)))
        //     (def map->Name (fn map->Name [m] m)))
        if (items.len < 3) {
            return self.analysisError(.arity_error, "defrecord requires name and fields", form);
        }
        if (items[1].data != .symbol) {
            return self.analysisError(.value_error, "defrecord name must be a symbol", items[1]);
        }
        if (items[2].data != .vector) {
            return self.analysisError(.value_error, "defrecord fields must be a vector", items[2]);
        }

        const rec_name = items[1].data.symbol.name;
        const fields = items[2].data.vector;

        for (fields) |field| {
            if (field.data != .symbol) {
                return self.analysisError(.value_error, "defrecord field must be a symbol", field);
            }
        }

        const ctor_name = std.fmt.allocPrint(self.allocator, "->{s}", .{rec_name}) catch return error.OutOfMemory;
        const map_ctor_name = std.fmt.allocPrint(self.allocator, "map->{s}", .{rec_name}) catch return error.OutOfMemory;

        // Build (hash-map :__reify_type "Name" :field1 field1 :field2 field2 ...) as Forms
        // The :__reify_type key enables protocol dispatch via extend-type on record types.
        const hm_form_count = 1 + 2 + fields.len * 2; // hash-map + type tag + pairs
        const hm_forms = self.allocator.alloc(Form, hm_form_count) catch return error.OutOfMemory;
        hm_forms[0] = .{ .data = .{ .symbol = .{ .ns = null, .name = "hash-map" } } };
        hm_forms[1] = .{ .data = .{ .keyword = .{ .ns = null, .name = "__reify_type" } } };
        hm_forms[2] = .{ .data = .{ .string = rec_name } };
        for (fields, 0..) |field, i| {
            hm_forms[3 + i * 2] = .{ .data = .{ .keyword = .{ .ns = null, .name = field.data.symbol.name } } };
            hm_forms[3 + i * 2 + 1] = field; // symbol ref
        }

        // Build (fn ->Name [fields...] (hash-map ...))
        const fn_forms = self.allocator.alloc(Form, 4) catch return error.OutOfMemory;
        fn_forms[0] = .{ .data = .{ .symbol = .{ .ns = null, .name = "fn" } } };
        fn_forms[1] = .{ .data = .{ .symbol = .{ .ns = null, .name = ctor_name } } };
        fn_forms[2] = items[2]; // [fields] vector
        fn_forms[3] = .{ .data = .{ .list = hm_forms } };

        // Build (def ->Name (fn ...))
        const def_ctor_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        def_ctor_forms[0] = .{ .data = .{ .symbol = .{ .ns = null, .name = "def" } } };
        def_ctor_forms[1] = .{ .data = .{ .symbol = .{ .ns = null, .name = ctor_name } } };
        def_ctor_forms[2] = .{ .data = .{ .list = fn_forms } };

        // Build (fn map->Name [m] m) — identity on map arg
        const map_param = self.allocator.alloc(Form, 1) catch return error.OutOfMemory;
        map_param[0] = .{ .data = .{ .symbol = .{ .ns = null, .name = "m" } } };
        const map_fn_forms = self.allocator.alloc(Form, 4) catch return error.OutOfMemory;
        map_fn_forms[0] = .{ .data = .{ .symbol = .{ .ns = null, .name = "fn" } } };
        map_fn_forms[1] = .{ .data = .{ .symbol = .{ .ns = null, .name = map_ctor_name } } };
        map_fn_forms[2] = .{ .data = .{ .vector = map_param } };
        map_fn_forms[3] = .{ .data = .{ .symbol = .{ .ns = null, .name = "m" } } };

        // Build (def map->Name (fn ...))
        const def_map_ctor_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        def_map_ctor_forms[0] = .{ .data = .{ .symbol = .{ .ns = null, .name = "def" } } };
        def_map_ctor_forms[1] = .{ .data = .{ .symbol = .{ .ns = null, .name = map_ctor_name } } };
        def_map_ctor_forms[2] = .{ .data = .{ .list = map_fn_forms } };

        // Wrap in (do (def ->Name ...) (def map->Name ...))
        const do_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        do_forms[0] = .{ .data = .{ .symbol = .{ .ns = null, .name = "do" } } };
        do_forms[1] = .{ .data = .{ .list = def_ctor_forms } };
        do_forms[2] = .{ .data = .{ .list = def_map_ctor_forms } };

        const do_form = Form{ .data = .{ .list = do_forms } };
        return self.analyze(do_form);
    }

    fn analyzeDefmulti(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (defmulti name dispatch-fn & options)
        // Supports metadata on name: (defmulti ^:dynamic name dispatch-fn)
        if (items.len < 3) {
            return self.analysisError(.arity_error, "defmulti requires name and dispatch-fn", form);
        }

        // Unwrap metadata from name (e.g. ^:dynamic)
        var name_form = items[1];
        while (name_form.data == .list) {
            const wm_items = name_form.data.list;
            if (wm_items.len == 3 and wm_items[0].data == .symbol and
                std.mem.eql(u8, wm_items[0].data.symbol.name, "with-meta"))
            {
                name_form = wm_items[1];
            } else break;
        }
        if (name_form.data != .symbol) {
            return self.analysisError(.value_error, "defmulti name must be a symbol", items[1]);
        }

        const name = name_form.data.symbol.name;
        const dispatch_node = try self.analyze(items[2]);

        // Parse keyword options: :hierarchy var-ref
        var hierarchy_node: ?*Node = null;
        var i: usize = 3;
        while (i + 1 < items.len) : (i += 2) {
            if (items[i].data == .keyword) {
                if (std.mem.eql(u8, items[i].data.keyword.name, "hierarchy")) {
                    hierarchy_node = try self.analyze(items[i + 1]);
                }
            }
        }

        const dm = self.allocator.create(node_mod.DefMultiNode) catch return error.OutOfMemory;
        dm.* = .{
            .name = name,
            .dispatch_fn = dispatch_node,
            .hierarchy_node = hierarchy_node,
            .source = self.sourceFromForm(form),
        };

        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .defmulti_node = dm };
        return n;
    }

    fn analyzeDefmethod(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (defmethod name dispatch-val [args] body...)
        // body is optional — empty body returns nil (like upstream)
        if (items.len < 4) {
            return self.analysisError(.arity_error, "defmethod requires name, dispatch-val, and args", form);
        }
        if (items[1].data != .symbol) {
            return self.analysisError(.value_error, "defmethod name must be a symbol", items[1]);
        }

        const multi_name = items[1].data.symbol.name;
        const dispatch_val_node = try self.analyze(items[2]);

        // Build fn node from [args] body: reuse analyzeFn
        // Construct (fn [args] body) form items
        const fn_items = self.allocator.alloc(Form, items.len - 2) catch return error.OutOfMemory;
        fn_items[0] = .{ .data = .{ .symbol = .{ .ns = null, .name = "fn" } } };
        @memcpy(fn_items[1..], items[3..]);

        const fn_node = try self.analyzeFn(fn_items, form);

        const dm = self.allocator.create(node_mod.DefMethodNode) catch return error.OutOfMemory;
        dm.* = .{
            .multi_name = multi_name,
            .dispatch_val = dispatch_val_node,
            .fn_node = fn_node.fn_node,
            .source = self.sourceFromForm(form),
        };

        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .defmethod_node = dm };
        return n;
    }

    fn analyzeLazySeq(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (lazy-seq body) — wrap body in (fn [] body)
        if (items.len < 2) {
            return self.analysisError(.arity_error, "lazy-seq requires a body", form);
        }

        // items = [lazy-seq, body1, body2, ...]
        // Build fn_items = [fn, [], body1, body2, ...]
        const body_forms = items[1..]; // skip "lazy-seq"
        const fn_items = self.allocator.alloc(Form, 2 + body_forms.len) catch return error.OutOfMemory;
        fn_items[0] = .{ .data = .{ .symbol = .{ .ns = null, .name = "fn" } } };
        fn_items[1] = .{ .data = .{ .vector = &.{} } }; // empty params []
        @memcpy(fn_items[2..], body_forms);

        const fn_node = try self.analyzeFn(fn_items, form);

        const ls = self.allocator.create(node_mod.LazySeqNode) catch return error.OutOfMemory;
        ls.* = .{
            .body_fn = fn_node.fn_node,
            .source = self.sourceFromForm(form),
        };

        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .lazy_seq_node = ls };
        return n;
    }

    /// (var sym) — resolve symbol to its Var and return as a Value.
    fn analyzeVarForm(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        if (items.len != 2) {
            return self.analysisError(.arity_error, "var requires exactly one argument", form);
        }
        if (items[1].data != .symbol) {
            return self.analysisError(.syntax_error, "var requires a symbol argument", form);
        }
        const sym = items[1].data.symbol;
        const env = self.env orelse {
            return self.analysisError(.syntax_error, "var requires runtime environment", form);
        };
        const ns = env.current_ns orelse {
            return self.analysisError(.syntax_error, "var requires a current namespace", form);
        };
        const the_var = blk: {
            if (sym.ns) |ns_name| {
                // Try current namespace's aliases/mappings first
                if (ns.resolveQualified(ns_name, sym.name)) |v| break :blk v;
                // Try direct namespace lookup in env (for #'clojure.core/name etc.)
                if (env.findNamespace(ns_name)) |target_ns| {
                    if (target_ns.resolve(sym.name)) |v| break :blk v;
                }
                break :blk @as(?*var_mod.Var, null);
            } else {
                break :blk ns.resolve(sym.name);
            }
        };
        if (the_var) |v| {
            return self.makeConstant(Value.initVarRef(v));
        }
        // For unqualified vars, intern in current namespace (JVM Clojure
        // behavior: def interns at compile time, so #'x works even before
        // the def form executes at runtime).
        if (sym.ns == null) {
            const interned = ns.intern(sym.name) catch return error.OutOfMemory;
            return self.makeConstant(Value.initVarRef(interned));
        }
        return self.analysisError(.syntax_error, "Unable to resolve var", form);
    }

    /// Rewrite (instance? ClassName expr) → (__instance? "ClassName" expr)
    /// The class name is passed as a string literal so it bypasses symbol resolution.
    /// Also handles keyword type names: (instance? :integer 42) → (__instance? :integer 42)
    fn analyzeInstanceCheck(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        if (items.len != 3) {
            return self.analysisError(.arity_error, "instance? requires exactly 2 arguments", form);
        }

        const callee_form = Form{
            .data = .{ .symbol = .{ .ns = null, .name = "__instance?" } },
            .line = items[0].line,
            .column = items[0].column,
        };

        var rewritten = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        rewritten[0] = callee_form;
        rewritten[2] = items[2];

        if (items[1].data == .symbol) {
            // Class name symbol → convert to string literal
            const sym = items[1].data.symbol;
            const class_name = if (sym.ns) |ns|
                std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ ns, sym.name }) catch return error.OutOfMemory
            else
                sym.name;
            rewritten[1] = Form{
                .data = .{ .string = class_name },
                .line = items[1].line,
                .column = items[1].column,
            };
        } else {
            // Keyword or other expression — pass through as-is
            rewritten[1] = items[1];
        }
        return self.analyzeCall(rewritten, form);
    }

    fn analyzeSetBang(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (set! var-symbol expr)
        if (items.len != 3) {
            return self.analysisError(.arity_error, "set! requires exactly 2 arguments", form);
        }
        if (items[1].data != .symbol) {
            return self.analysisError(.syntax_error, "set! target must be a symbol", items[1]);
        }
        const sym_name = items[1].data.symbol.name;
        const expr = try self.analyze(items[2]);

        const set_data = self.allocator.create(node_mod.SetNode) catch return error.OutOfMemory;
        set_data.* = .{
            .var_name = sym_name,
            .expr = expr,
            .source = self.sourceFromForm(form),
        };
        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .set_node = set_data };
        return n;
    }

    fn analyzeRecur(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (recur arg1 arg2 ...)
        _ = form;
        var args = self.allocator.alloc(*Node, items.len - 1) catch return error.OutOfMemory;
        for (items[1..], 0..) |item, i| {
            args[i] = try self.analyze(item);
        }

        const recur_data = self.allocator.create(node_mod.RecurNode) catch return error.OutOfMemory;
        recur_data.* = .{
            .args = args,
            .source = self.sourceFromForm(items[0]),
        };

        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .recur_node = recur_data };
        return n;
    }

    fn analyzeThrow(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (throw expr)
        if (items.len != 2) {
            return self.analysisError(.arity_error, "throw requires exactly 1 argument", form);
        }

        const expr = try self.analyze(items[1]);

        const throw_data = self.allocator.create(node_mod.ThrowNode) catch return error.OutOfMemory;
        throw_data.* = .{
            .expr = expr,
            .source = self.sourceFromForm(form),
        };

        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .throw_node = throw_data };
        return n;
    }

    fn analyzeTry(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (try body... (catch ExType e handler...) (finally cleanup...))
        if (items.len < 2) {
            return self.analysisError(.arity_error, "try requires at least a body expression", form);
        }

        var body_forms: std.ArrayList(Form) = .empty;
        var catch_clauses: std.ArrayList(node_mod.CatchClause) = .empty;
        var finally_body: ?*Node = null;

        for (items[1..]) |item| {
            if (item.data == .list) {
                const sub_items = item.data.list;
                if (sub_items.len > 0 and sub_items[0].data == .symbol and sub_items[0].data.symbol.ns == null) {
                    const name = sub_items[0].data.symbol.name;

                    if (std.mem.eql(u8, name, "catch")) {
                        // (catch ExType name body*)
                        if (sub_items.len < 4) {
                            return self.analysisError(.arity_error, "catch requires (catch ExceptionType name body*)", item);
                        }
                        // sub_items[1] = ExType (class name for exception matching)
                        const class_name = if (sub_items[1].data == .symbol)
                            sub_items[1].data.symbol.name
                        else
                            "Exception";
                        if (sub_items[2].data != .symbol) {
                            return self.analysisError(.value_error, "catch binding must be a symbol", sub_items[2]);
                        }
                        const binding_name = sub_items[2].data.symbol.name;

                        const saved_depth = self.locals.items.len;
                        self.locals.append(self.allocator, .{
                            .name = binding_name,
                            .idx = @intCast(saved_depth),
                        }) catch return error.OutOfMemory;

                        const handler_body = try self.analyzeBody(sub_items[3..], item);

                        self.locals.shrinkRetainingCapacity(saved_depth);

                        catch_clauses.append(self.allocator, .{
                            .class_name = class_name,
                            .binding_name = binding_name,
                            .body = handler_body,
                        }) catch return error.OutOfMemory;
                        continue;
                    }

                    if (std.mem.eql(u8, name, "finally")) {
                        // (finally body*)
                        if (sub_items.len < 2) {
                            return self.analysisError(.arity_error, "finally requires at least one expression", item);
                        }

                        finally_body = try self.analyzeBody(sub_items[1..], item);
                        continue;
                    }
                }
            }

            // Not catch/finally -> body form
            body_forms.append(self.allocator, item) catch return error.OutOfMemory;
        }

        const body_node = try self.analyzeBody(body_forms.items, form);

        // Build nested try nodes for multiple catch clauses (innermost = first clause).
        // Single catch or no catch: straightforward.
        // Multi-catch (catch A e h1) (catch B e h2) (finally f):
        //   → (try (try body (catch A e h1)) (catch B e h2) (finally f))
        if (catch_clauses.items.len <= 1) {
            const try_data = self.allocator.create(node_mod.TryNode) catch return error.OutOfMemory;
            try_data.* = .{
                .body = body_node,
                .catch_clause = if (catch_clauses.items.len == 1) catch_clauses.items[0] else null,
                .finally_body = finally_body,
                .source = self.sourceFromForm(form),
            };
            const n = self.allocator.create(Node) catch return error.OutOfMemory;
            n.* = .{ .try_node = try_data };
            return n;
        } else {
            // Multi-catch: nest from inside out. First clause is innermost.
            // Inner try: body + first catch clause (no finally)
            var current_body = body_node;
            for (catch_clauses.items[0 .. catch_clauses.items.len - 1]) |clause| {
                const inner_try = self.allocator.create(node_mod.TryNode) catch return error.OutOfMemory;
                inner_try.* = .{
                    .body = current_body,
                    .catch_clause = clause,
                    .finally_body = null,
                    .source = self.sourceFromForm(form),
                };
                const inner_node = self.allocator.create(Node) catch return error.OutOfMemory;
                inner_node.* = .{ .try_node = inner_try };
                current_body = inner_node;
            }
            // Outermost try: nested body + last catch clause + finally
            const outer_try = self.allocator.create(node_mod.TryNode) catch return error.OutOfMemory;
            outer_try.* = .{
                .body = current_body,
                .catch_clause = catch_clauses.items[catch_clauses.items.len - 1],
                .finally_body = finally_body,
                .source = self.sourceFromForm(form),
            };
            const n = self.allocator.create(Node) catch return error.OutOfMemory;
            n.* = .{ .try_node = outer_try };
            return n;
        }
    }

    // === Call analysis ===

    fn analyzeCall(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        const callee = try self.analyze(items[0]);
        var args = self.allocator.alloc(*Node, items.len - 1) catch return error.OutOfMemory;
        for (items[1..], 0..) |item, i| {
            args[i] = try self.analyze(item);
        }

        const call_data = self.allocator.create(node_mod.CallNode) catch return error.OutOfMemory;
        call_data.* = .{
            .callee = callee,
            .args = args,
            .source = self.sourceFromForm(form),
        };

        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .call_node = call_data };
        return n;
    }

    // === Collection literals ===

    fn analyzeVector(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        var nodes = self.allocator.alloc(*Node, items.len) catch return error.OutOfMemory;
        var all_const = true;
        for (items, 0..) |item, i| {
            nodes[i] = try self.analyze(item);
            if (nodes[i].* != .constant) {
                all_const = false;
            }
        }

        if (all_const) {
            var values = self.allocator.alloc(Value, items.len) catch return error.OutOfMemory;
            for (nodes, 0..) |n, i| {
                values[i] = n.constant.value;
            }
            const vec = self.allocator.create(@import("../runtime/value.zig").PersistentVector) catch return error.OutOfMemory;
            vec.* = .{ .items = values };
            return self.makeConstantFrom(Value.initVector(vec), form);
        }

        // Non-constant: produce call to "vector"
        return self.makeBuiltinCall("vector", nodes);
    }

    fn analyzeMap(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        var nodes = self.allocator.alloc(*Node, items.len) catch return error.OutOfMemory;
        var all_const = true;
        for (items, 0..) |item, i| {
            nodes[i] = try self.analyze(item);
            if (nodes[i].* != .constant) {
                all_const = false;
            }
        }

        if (all_const) {
            var values = self.allocator.alloc(Value, items.len) catch return error.OutOfMemory;
            for (nodes, 0..) |n, i| {
                values[i] = n.constant.value;
            }
            const m = self.allocator.create(@import("../runtime/value.zig").PersistentArrayMap) catch return error.OutOfMemory;
            m.* = .{ .entries = values };
            return self.makeConstantFrom(Value.initMap(m), form);
        }

        return self.makeBuiltinCall("hash-map", nodes);
    }

    fn analyzeSet(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        var nodes = self.allocator.alloc(*Node, items.len) catch return error.OutOfMemory;
        var all_const = true;
        for (items, 0..) |item, i| {
            nodes[i] = try self.analyze(item);
            if (nodes[i].* != .constant) {
                all_const = false;
            }
        }

        if (all_const) {
            var values = self.allocator.alloc(Value, items.len) catch return error.OutOfMemory;
            for (nodes, 0..) |n, i| {
                values[i] = n.constant.value;
            }
            const s = self.allocator.create(@import("../runtime/value.zig").PersistentHashSet) catch return error.OutOfMemory;
            s.* = .{ .items = values };
            return self.makeConstantFrom(Value.initSet(s), form);
        }

        return self.makeBuiltinCall("hash-set", nodes);
    }

    /// Build a call to a builtin function by name (name-based var_ref in Phase 1c).
    // === Destructuring expansion ===

    /// Expand a binding pattern into simple name=init bindings.
    /// Dispatches on pattern form type: symbol (simple), vector (sequential), map (associative).
    fn expandBindingPattern(
        self: *Analyzer,
        pattern: Form,
        init_node: *Node,
        bindings: *std.ArrayList(node_mod.LetBinding),
        form: Form,
    ) AnalyzeError!void {
        switch (pattern.data) {
            .symbol => |sym| {
                // Simple binding: name = init
                // Namespace-qualified symbols not allowed in bindings (only in map destructuring :keys/:syms)
                if (sym.ns != null) {
                    return self.analysisError(.value_error, "can't let qualified name", pattern);
                }
                const name = sym.name;
                const idx: u32 = @intCast(self.locals.items.len);
                self.locals.append(self.allocator, .{ .name = name, .idx = idx }) catch return error.OutOfMemory;
                bindings.append(self.allocator, .{ .name = name, .init = init_node }) catch return error.OutOfMemory;
            },
            .vector => |elems| {
                // Sequential destructuring: [a b c] = coll
                try self.expandSequentialPattern(elems, init_node, bindings, form);
            },
            .map => |entries| {
                // Map destructuring: {:keys [a b]} = map
                try self.expandMapPattern(entries, init_node, bindings, form);
            },
            else => {
                return self.analysisError(.value_error, "binding pattern must be a symbol, vector, or map", pattern);
            },
        }
    }

    /// Expand sequential destructuring pattern.
    /// [a b c]       -> a = (nth coll 0), b = (nth coll 1), c = (nth coll 2)
    /// [a b & rest]  -> seq-based: s = (seq coll), a = (first s), s = (next s), ...
    /// [a b :as all] -> a = (nth coll 0), b = (nth coll 1), all = coll
    fn expandSequentialPattern(
        self: *Analyzer,
        elems: []const Form,
        init_node: *Node,
        bindings: *std.ArrayList(node_mod.LetBinding),
        form: Form,
    ) AnalyzeError!void {
        // Bind whole collection to temp var (avoid multiple evaluation)
        const temp_name = "__destructure_seq__";
        const temp_idx: u32 = @intCast(self.locals.items.len);
        self.locals.append(self.allocator, .{ .name = temp_name, .idx = temp_idx }) catch return error.OutOfMemory;
        bindings.append(self.allocator, .{ .name = temp_name, .init = init_node }) catch return error.OutOfMemory;

        // Create reference node for the temp var
        const temp_ref = try self.makeTempLocalRef(temp_name, temp_idx);

        // Pre-scan for & — when present, use seq/first/next chain (JVM behavior).
        // This is needed because non-seqable collections (maps) can be destructured
        // via & (e.g., [[k v] & ks :as keys] some-map).
        const has_rest = blk: {
            for (elems) |e| {
                if (e.data == .symbol and std.mem.eql(u8, e.data.symbol.name, "&"))
                    break :blk true;
            }
            break :blk false;
        };

        if (has_rest) {
            // seq-based access: seq_ref = (seq coll), then first/next chain
            return self.expandSequentialPatternSeqBased(elems, temp_ref, bindings, form);
        }

        // No & — use efficient nth-based access
        var pos: usize = 0;
        var i: usize = 0;
        while (i < elems.len) : (i += 1) {
            const elem = elems[i];

            // :as check
            if (elem.data == .keyword and std.mem.eql(u8, elem.data.keyword.name, "as")) {
                if (i + 1 >= elems.len) {
                    return self.analysisError(.value_error, ":as must be followed by a symbol", form);
                }
                try self.expandBindingPattern(elems[i + 1], temp_ref, bindings, form);
                i += 1;
                continue;
            }

            // Normal element: elem = (nth coll pos)
            const nth_init = try self.makeNthCall(temp_ref, pos);
            try self.expandBindingPattern(elem, nth_init, bindings, form);
            pos += 1;
        }
    }

    /// seq-based sequential destructuring for patterns with &.
    /// Matches JVM Clojure: s = (seq coll), elem = (first s), s = (next s), ...
    fn expandSequentialPatternSeqBased(
        self: *Analyzer,
        elems: []const Form,
        coll_ref: *Node,
        bindings: *std.ArrayList(node_mod.LetBinding),
        form: Form,
    ) AnalyzeError!void {
        // seq_ref = (seq coll)
        const seq_name = "__destructure_s__";
        var seq_idx: u32 = @intCast(self.locals.items.len);
        self.locals.append(self.allocator, .{ .name = seq_name, .idx = seq_idx }) catch return error.OutOfMemory;
        const seq_args = self.allocator.alloc(*Node, 1) catch return error.OutOfMemory;
        seq_args[0] = coll_ref;
        const seq_init = try self.makeBuiltinCall("seq", seq_args);
        bindings.append(self.allocator, .{ .name = seq_name, .init = seq_init }) catch return error.OutOfMemory;

        var i: usize = 0;
        while (i < elems.len) : (i += 1) {
            const elem = elems[i];

            // & rest check
            if (elem.data == .symbol and std.mem.eql(u8, elem.data.symbol.name, "&")) {
                if (i + 1 >= elems.len) {
                    return self.analysisError(.value_error, "& must be followed by a binding", form);
                }
                const rest_pattern = elems[i + 1];

                // rest = seq_ref (already a seq, nil if exhausted)
                const rest_ref = try self.makeTempLocalRef(seq_name, seq_idx);
                try self.expandBindingPattern(rest_pattern, rest_ref, bindings, form);

                i += 1; // skip rest pattern

                // Check for :as after & rest
                if (i + 1 < elems.len) {
                    if (elems[i + 1].data == .keyword and std.mem.eql(u8, elems[i + 1].data.keyword.name, "as")) {
                        if (i + 2 >= elems.len) {
                            return self.analysisError(.value_error, ":as must be followed by a symbol", form);
                        }
                        try self.expandBindingPattern(elems[i + 2], coll_ref, bindings, form);
                        i += 2;
                    }
                }
                continue;
            }

            // :as check
            if (elem.data == .keyword and std.mem.eql(u8, elem.data.keyword.name, "as")) {
                if (i + 1 >= elems.len) {
                    return self.analysisError(.value_error, ":as must be followed by a symbol", form);
                }
                try self.expandBindingPattern(elems[i + 1], coll_ref, bindings, form);
                i += 1;
                continue;
            }

            // Normal element: elem = (first seq_ref)
            const cur_seq_ref = try self.makeTempLocalRef(seq_name, seq_idx);
            const first_args = self.allocator.alloc(*Node, 1) catch return error.OutOfMemory;
            first_args[0] = cur_seq_ref;
            const first_init = try self.makeBuiltinCall("first", first_args);
            try self.expandBindingPattern(elem, first_init, bindings, form);

            // Advance: seq_ref = (next seq_ref) — new local slot each time
            const next_seq_ref = try self.makeTempLocalRef(seq_name, seq_idx);
            const next_args = self.allocator.alloc(*Node, 1) catch return error.OutOfMemory;
            next_args[0] = next_seq_ref;
            const next_init = try self.makeBuiltinCall("next", next_args);
            seq_idx = @intCast(self.locals.items.len);
            self.locals.append(self.allocator, .{ .name = seq_name, .idx = seq_idx }) catch return error.OutOfMemory;
            bindings.append(self.allocator, .{ .name = seq_name, .init = next_init }) catch return error.OutOfMemory;
        }
    }

    /// Expand map destructuring pattern.
    /// {:keys [a b]}        -> a = (get coll :a), b = (get coll :b)
    /// {:strs [a b]}        -> a = (get coll "a"), b = (get coll "b")
    /// {a :a, b :b}         -> a = (get coll :a), b = (get coll :b)
    /// {:keys [a] :or {a 0}} -> a = (get coll :a) with default 0
    /// {:keys [a] :as m}    -> a = (get coll :a), m = coll
    fn expandMapPattern(
        self: *Analyzer,
        entries: []const Form,
        init_node: *Node,
        bindings: *std.ArrayList(node_mod.LetBinding),
        form: Form,
    ) AnalyzeError!void {
        // Wrap init with __seq-to-map to coerce seqs to maps (JVM destructure semantics)
        const coerce_args = self.allocator.alloc(*Node, 1) catch return error.OutOfMemory;
        coerce_args[0] = init_node;
        const coerced_init = try self.makeBuiltinCall("__seq-to-map", coerce_args);

        // Bind whole collection to temp var
        const temp_name = "__destructure_map__";
        const temp_idx: u32 = @intCast(self.locals.items.len);
        self.locals.append(self.allocator, .{ .name = temp_name, .idx = temp_idx }) catch return error.OutOfMemory;
        bindings.append(self.allocator, .{ .name = temp_name, .init = coerced_init }) catch return error.OutOfMemory;

        const temp_ref = try self.makeTempLocalRef(temp_name, temp_idx);

        // First pass: find :or defaults
        var defaults: ?[]const Form = null;
        {
            var i: usize = 0;
            while (i + 1 < entries.len) : (i += 2) {
                if (entries[i].data == .keyword and std.mem.eql(u8, entries[i].data.keyword.name, "or")) {
                    if (entries[i + 1].data == .map) {
                        defaults = entries[i + 1].data.map;
                    }
                }
            }
        }

        // Second pass: process entries
        var i: usize = 0;
        while (i + 1 < entries.len) : (i += 2) {
            const key = entries[i];
            const val = entries[i + 1];

            if (key.data == .keyword) {
                const kw_name = key.data.keyword.name;

                if (std.mem.eql(u8, kw_name, "keys")) {
                    // :keys [a b c] or :ns/keys [a b c] -> keyword-keyed get
                    // Supports: :keys [a], :keys [:a/b], :keys [a/b], :ns/keys [b], ::keys [b]
                    if (val.data != .vector) {
                        return self.analysisError(.value_error, ":keys must be followed by a vector", val);
                    }
                    const key_ns = if (key.data.keyword.ns) |ns|
                        ns
                    else if (key.data.keyword.auto_resolve)
                        self.resolveAutoNs(null)
                    else
                        null;
                    for (val.data.vector) |sym_form| {
                        var lookup_ns: ?[]const u8 = key_ns;
                        var bind_name: []const u8 = undefined;
                        if (sym_form.data == .symbol) {
                            bind_name = sym_form.data.symbol.name;
                            if (sym_form.data.symbol.ns) |ns| lookup_ns = ns;
                        } else if (sym_form.data == .keyword) {
                            bind_name = sym_form.data.keyword.name;
                            if (sym_form.data.keyword.ns) |ns| {
                                if (sym_form.data.keyword.auto_resolve) {
                                    // ::alias/x in :keys — resolve alias to full namespace
                                    lookup_ns = self.resolveAutoNs(ns);
                                } else {
                                    lookup_ns = ns;
                                }
                            } else if (sym_form.data.keyword.auto_resolve) {
                                // ::x in :keys — resolve to current namespace
                                lookup_ns = self.resolveAutoNs(null);
                            }
                        } else {
                            return self.analysisError(.value_error, ":keys elements must be symbols or keywords", sym_form);
                        }
                        const get_init = try self.makeGetKeywordCall(temp_ref, bind_name, lookup_ns, defaults);
                        const bind_idx: u32 = @intCast(self.locals.items.len);
                        self.locals.append(self.allocator, .{ .name = bind_name, .idx = bind_idx }) catch return error.OutOfMemory;
                        bindings.append(self.allocator, .{ .name = bind_name, .init = get_init }) catch return error.OutOfMemory;
                    }
                } else if (std.mem.eql(u8, kw_name, "strs")) {
                    // :strs [a b] -> each symbol becomes a string-keyed get
                    if (val.data != .vector) {
                        return self.analysisError(.value_error, ":strs must be followed by a vector", val);
                    }
                    for (val.data.vector) |sym_form| {
                        if (sym_form.data != .symbol) {
                            return self.analysisError(.value_error, ":strs elements must be symbols", sym_form);
                        }
                        const sym_name = sym_form.data.symbol.name;
                        const get_init = try self.makeGetStringCall(temp_ref, sym_name, defaults);
                        const bind_idx: u32 = @intCast(self.locals.items.len);
                        self.locals.append(self.allocator, .{ .name = sym_name, .idx = bind_idx }) catch return error.OutOfMemory;
                        bindings.append(self.allocator, .{ .name = sym_name, .init = get_init }) catch return error.OutOfMemory;
                    }
                } else if (std.mem.eql(u8, kw_name, "syms")) {
                    // :syms [a b] or :ns/syms [a b] -> symbol-keyed get
                    // Supports: :syms [a], :syms [a/b], :ns/syms [b], ::syms [b]
                    if (val.data != .vector) {
                        return self.analysisError(.value_error, ":syms must be followed by a vector", val);
                    }
                    const key_ns = if (key.data.keyword.ns) |ns|
                        ns
                    else if (key.data.keyword.auto_resolve)
                        self.resolveAutoNs(null)
                    else
                        null;
                    for (val.data.vector) |sym_form| {
                        if (sym_form.data != .symbol) {
                            return self.analysisError(.value_error, ":syms elements must be symbols", sym_form);
                        }
                        const bind_name = sym_form.data.symbol.name;
                        var lookup_ns: ?[]const u8 = key_ns;
                        if (sym_form.data.symbol.ns) |ns| lookup_ns = ns;
                        const get_init = try self.makeGetSymbolCall(temp_ref, bind_name, lookup_ns, defaults);
                        const bind_idx: u32 = @intCast(self.locals.items.len);
                        self.locals.append(self.allocator, .{ .name = bind_name, .idx = bind_idx }) catch return error.OutOfMemory;
                        bindings.append(self.allocator, .{ .name = bind_name, .init = get_init }) catch return error.OutOfMemory;
                    }
                } else if (std.mem.eql(u8, kw_name, "as")) {
                    // :as all -> all = coll
                    try self.expandBindingPattern(val, temp_ref, bindings, form);
                } else if (std.mem.eql(u8, kw_name, "or")) {
                    // :or already processed, skip
                    continue;
                } else {
                    return self.analysisError(.value_error, "unknown map destructuring keyword", key);
                }
            } else if (key.data == .symbol) {
                // {x :x, y :y} -> x = (get coll :x)
                const sym_name = key.data.symbol.name;
                if (val.data != .keyword) {
                    return self.analysisError(.value_error, "map destructuring: value must be a keyword", val);
                }
                const get_init = try self.makeGetKeywordCall(temp_ref, val.data.keyword.name, val.data.keyword.ns, null);
                const bind_idx: u32 = @intCast(self.locals.items.len);
                self.locals.append(self.allocator, .{ .name = sym_name, .idx = bind_idx }) catch return error.OutOfMemory;
                bindings.append(self.allocator, .{ .name = sym_name, .init = get_init }) catch return error.OutOfMemory;
            } else if (key.data == .map or key.data == .vector) {
                // Nested destructuring: {{x :x} :b} or {[a b] :items}
                // val is the lookup key, key is the nested pattern
                if (val.data != .keyword) {
                    return self.analysisError(.value_error, "nested destructuring: value must be a keyword", val);
                }
                const get_init = try self.makeGetKeywordCall(temp_ref, val.data.keyword.name, val.data.keyword.ns, defaults);
                try self.expandBindingPattern(key, get_init, bindings, form);
            } else {
                return self.analysisError(.value_error, "map destructuring: key must be keyword, symbol, map, or vector", key);
            }
        }
    }

    /// Create a local_ref node for a temp var (no source info).
    fn makeTempLocalRef(self: *Analyzer, name: []const u8, idx: u32) AnalyzeError!*Node {
        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .local_ref = .{
            .name = name,
            .idx = idx,
            .source = .{},
        } };
        return n;
    }

    /// Resolve auto-resolved keyword namespace.
    /// For ::foo (alias=null) → current ns name.
    /// For ::alias/foo (alias!=null) → resolved alias ns name.
    fn resolveAutoNs(self: *const Analyzer, alias: ?[]const u8) ?[]const u8 {
        const env = self.env orelse return null;
        const ns = env.current_ns orelse return null;
        if (alias) |a| {
            const resolved = ns.getAlias(a) orelse return null;
            return resolved.name;
        }
        return ns.name;
    }

    /// Generate (nth coll idx) call node.
    fn makeNthCall(self: *Analyzer, coll_node: *Node, idx: usize) AnalyzeError!*Node {
        const idx_node = try self.makeConstant(Value.initInteger(@intCast(idx)));
        const nil_node = try self.makeConstant(Value.nil_val);
        const args = self.allocator.alloc(*Node, 3) catch return error.OutOfMemory;
        args[0] = coll_node;
        args[1] = idx_node;
        args[2] = nil_node;
        return self.makeBuiltinCall("nth", args);
    }

    /// Generate chained rest calls: (rest (rest ... (rest coll))) pos times.
    fn makeNthRest(self: *Analyzer, coll_node: *Node, pos: usize) AnalyzeError!*Node {
        if (pos == 0) return coll_node;

        var current = coll_node;
        for (0..pos) |_| {
            const args = self.allocator.alloc(*Node, 1) catch return error.OutOfMemory;
            args[0] = current;
            current = try self.makeBuiltinCall("rest", args);
        }
        return current;
    }

    /// Generate (get coll :ns/keyword) or (get coll :keyword default) call node.
    fn makeGetKeywordCall(self: *Analyzer, coll_node: *Node, key_name: []const u8, ns: ?[]const u8, defaults: ?[]const Form) AnalyzeError!*Node {
        const key_node = try self.makeConstant(Value.initKeyword(self.allocator, .{ .ns = ns, .name = key_name }));
        const default_node = try self.findDefault(key_name, defaults);
        return self.makeGetCallNode(coll_node, key_node, default_node);
    }

    /// Generate (get coll "string") or (get coll "string" default) call node.
    fn makeGetStringCall(self: *Analyzer, coll_node: *Node, key_name: []const u8, defaults: ?[]const Form) AnalyzeError!*Node {
        const key_node = try self.makeConstant(Value.initString(self.allocator, key_name));
        const default_node = try self.findDefault(key_name, defaults);
        return self.makeGetCallNode(coll_node, key_node, default_node);
    }

    /// Generate (get coll 'ns/symbol) or (get coll 'symbol default) call node.
    fn makeGetSymbolCall(self: *Analyzer, coll_node: *Node, sym_name: []const u8, ns: ?[]const u8, defaults: ?[]const Form) AnalyzeError!*Node {
        const key_node = try self.makeConstant(Value.initSymbol(self.allocator, .{ .ns = ns, .name = sym_name }));
        const default_node = try self.findDefault(sym_name, defaults);
        return self.makeGetCallNode(coll_node, key_node, default_node);
    }

    /// Generate (get coll key) or (get coll key default) call node.
    fn makeGetCallNode(self: *Analyzer, coll_node: *Node, key_node: *Node, default_node: ?*Node) AnalyzeError!*Node {
        if (default_node) |def| {
            const args = self.allocator.alloc(*Node, 3) catch return error.OutOfMemory;
            args[0] = coll_node;
            args[1] = key_node;
            args[2] = def;
            return self.makeBuiltinCall("get", args);
        } else {
            const args = self.allocator.alloc(*Node, 2) catch return error.OutOfMemory;
            args[0] = coll_node;
            args[1] = key_node;
            return self.makeBuiltinCall("get", args);
        }
    }

    /// Find default value for a key in :or map.
    fn findDefault(self: *Analyzer, key_name: []const u8, defaults: ?[]const Form) AnalyzeError!?*Node {
        const defs = defaults orelse return null;
        var j: usize = 0;
        while (j + 1 < defs.len) : (j += 2) {
            if (defs[j].data == .symbol and std.mem.eql(u8, defs[j].data.symbol.name, key_name)) {
                return try self.analyze(defs[j + 1]);
            }
        }
        return null;
    }

    fn makeBuiltinCall(self: *Analyzer, name: []const u8, args: []*Node) AnalyzeError!*Node {
        const callee = self.allocator.create(Node) catch return error.OutOfMemory;
        callee.* = .{ .var_ref = .{
            .ns = null,
            .name = name,
            .source = .{},
        } };

        const call_data = self.allocator.create(node_mod.CallNode) catch return error.OutOfMemory;
        call_data.* = .{
            .callee = callee,
            .args = args,
            .source = .{},
        };

        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .call_node = call_data };
        return n;
    }

    // === Body helper ===

    /// Analyze a sequence of body forms. Returns nil for empty, single form, or do-wrapped.
    fn analyzeBody(self: *Analyzer, body_forms: []const Form, form: Form) AnalyzeError!*Node {
        if (body_forms.len == 0) {
            return self.makeConstant(Value.nil_val);
        }
        if (body_forms.len == 1) {
            return self.analyze(body_forms[0]);
        }
        // Wrap in do
        var statements = self.allocator.alloc(*Node, body_forms.len) catch return error.OutOfMemory;
        for (body_forms, 0..) |item, i| {
            statements[i] = try self.analyze(item);
        }
        const do_data = self.allocator.create(node_mod.DoNode) catch return error.OutOfMemory;
        do_data.* = .{
            .statements = statements,
            .source = self.sourceFromForm(form),
        };
        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .do_node = do_data };
        return n;
    }

    // === Helpers ===

    /// Build Clojure-style arglists string from FnNode arities.
    /// e.g. "([x] [x y])" for multi-arity, "([x y & more])" for variadic.
    fn buildArglistsStr(allocator: Allocator, fn_node: *node_mod.FnNode) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        try buf.append(allocator, '(');
        for (fn_node.arities, 0..) |arity, ai| {
            if (ai > 0) try buf.append(allocator, ' ');
            try buf.append(allocator, '[');
            for (arity.params, 0..) |param, pi| {
                if (pi > 0) try buf.append(allocator, ' ');
                if (arity.variadic and pi == arity.params.len - 1) {
                    try buf.appendSlice(allocator, "& ");
                }
                try buf.appendSlice(allocator, param);
            }
            try buf.append(allocator, ']');
        }
        try buf.append(allocator, ')');
        return buf.items;
    }

    // =================================================================
    // case* special form
    // =================================================================

    /// (case* expr shift mask default case-map switch-type test-type skip-check?)
    fn analyzeCaseStar(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // items[0] = "case*", items[1..] = args
        if (items.len < 8) {
            return self.analysisError(.arity_error, "case* requires at least 7 arguments", form);
        }

        // 1. Analyze expr
        const expr = try self.analyze(items[1]);

        // 2. Extract shift (integer literal)
        const shift: i32 = switch (items[2].data) {
            .integer => |v| @intCast(v),
            else => return self.analysisError(.syntax_error, "case* shift must be an integer", items[2]),
        };

        // 3. Extract mask (integer literal)
        const mask: i32 = switch (items[3].data) {
            .integer => |v| @intCast(v),
            else => return self.analysisError(.syntax_error, "case* mask must be an integer", items[3]),
        };

        // 4. Analyze default expression
        const default = try self.analyze(items[4]);

        // 5. Parse case-map: {hash-key [test-value then-expr], ...}
        const map_forms = switch (items[5].data) {
            .map => |m| m,
            else => return self.analysisError(.syntax_error, "case* case-map must be a map", items[5]),
        };

        // map_forms is flat pairs: [key1, val1, key2, val2, ...]
        const num_clauses = map_forms.len / 2;
        const clauses = self.allocator.alloc(node_mod.CaseClause, num_clauses) catch return error.OutOfMemory;

        const quote_ns_ptr: ?*const @import("../runtime/namespace.zig").Namespace =
            if (self.env) |env| (if (env.current_ns) |ns| ns else null) else null;

        var ci: usize = 0;
        var mi: usize = 0;
        while (mi + 1 < map_forms.len) : (mi += 2) {
            // Key: integer hash
            const hash_key: i64 = switch (map_forms[mi].data) {
                .integer => |v| v,
                else => return self.analysisError(.syntax_error, "case* map key must be an integer", map_forms[mi]),
            };

            // Value: [test-value then-expr]
            const val_vec = switch (map_forms[mi + 1].data) {
                .vector => |v| v,
                else => return self.analysisError(.syntax_error, "case* map value must be a vector", map_forms[mi + 1]),
            };
            if (val_vec.len != 2) {
                return self.analysisError(.syntax_error, "case* map value must be [test then]", map_forms[mi + 1]);
            }

            // Convert test-value Form to Value (it's a constant, not evaluated)
            const test_val = macro.formToValueWithNs(self.allocator, val_vec[0], quote_ns_ptr) catch return error.OutOfMemory;

            // Analyze then-expr
            const then_node = try self.analyze(val_vec[1]);

            clauses[ci] = .{
                .hash_key = hash_key,
                .test_value = test_val,
                .then_node = then_node,
            };
            ci += 1;
        }

        // 6. Extract test-type keyword
        const test_type: node_mod.CaseNode.TestType = blk: {
            if (items[7].data == .keyword) {
                const name = items[7].data.keyword.name;
                if (std.mem.eql(u8, name, "int")) break :blk .int_test;
                if (std.mem.eql(u8, name, "hash-equiv")) break :blk .hash_equiv;
                if (std.mem.eql(u8, name, "hash-identity")) break :blk .hash_identity;
            }
            return self.analysisError(.syntax_error, "case* test-type must be :int, :hash-equiv, or :hash-identity", items[7]);
        };

        // 7. Parse skip-check set (optional, items[8])
        const skip_check: []const i64 = if (items.len > 8) blk: {
            switch (items[8].data) {
                .set => |s| {
                    const sc = self.allocator.alloc(i64, s.len) catch return error.OutOfMemory;
                    for (s, 0..) |elem, i| {
                        sc[i] = switch (elem.data) {
                            .integer => |v| v,
                            else => return self.analysisError(.syntax_error, "case* skip-check elements must be integers", elem),
                        };
                    }
                    break :blk sc;
                },
                else => break :blk &[_]i64{},
            }
        } else &[_]i64{};

        // 8. Create CaseNode
        const case_data = self.allocator.create(node_mod.CaseNode) catch return error.OutOfMemory;
        case_data.* = .{
            .expr = expr,
            .shift = shift,
            .mask = mask,
            .default = default,
            .clauses = clauses[0..ci],
            .test_type = test_type,
            .skip_check = skip_check,
            .source = self.sourceFromForm(form),
        };
        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .case_node = case_data };
        return n;
    }
};

/// Check if a metadata form is a type hint (map literal containing :tag key).
/// Used to distinguish reader type hints (^String x → strip) from
/// intentional metadata (^{:zip/branch? f} vec → keep).
fn isTypeHintMeta(form: Form) bool {
    if (form.data != .map) return false;
    const pairs = form.data.map;
    // Only strip pure type hints: exactly {:tag <symbol>}
    // Preserve user metadata like {:tag :keyword}, {:tag :test, :other val}
    if (pairs.len != 2) return false; // must be exactly one key-value pair
    if (pairs[0].data != .keyword) return false;
    const kw = pairs[0].data.keyword;
    if (kw.ns != null or !std.mem.eql(u8, kw.name, "tag")) return false;
    // Value must be a symbol (type name like String, long, etc.)
    return pairs[1].data == .symbol;
}

// === formToValue (for quote) ===

/// Convert a Form to a runtime Value (used by quote).
/// Collections are converted recursively.
pub fn formToValue(allocator: Allocator, form: Form) Value {
    return switch (form.data) {
        .nil => Value.nil_val,
        .boolean => |b| Value.initBoolean(b),
        .integer => |n| Value.initInteger(n),
        .float => |n| Value.initFloat(n),
        .big_int => |s| Value.initBigInt(collections.BigInt.initFromString(allocator, s) catch return Value.nil_val),
        .big_decimal => |s| Value.initBigDecimal(collections.BigDecimal.initFromString(allocator, s) catch return Value.nil_val),
        .ratio => |r| blk: {
            const maybe_ratio = collections.Ratio.initFromStrings(allocator, r.numerator, r.denominator) catch break :blk Value.nil_val;
            if (maybe_ratio) |ratio| {
                break :blk Value.initRatio(ratio);
            } else {
                const n = collections.BigInt.initFromString(allocator, r.numerator) catch break :blk Value.nil_val;
                const d = collections.BigInt.initFromString(allocator, r.denominator) catch break :blk Value.nil_val;
                const q = allocator.create(collections.BigInt) catch break :blk Value.nil_val;
                q.managed = std.math.big.int.Managed.init(allocator) catch break :blk Value.nil_val;
                var rem_val = std.math.big.int.Managed.init(allocator) catch break :blk Value.nil_val;
                q.managed.divTrunc(&rem_val, &n.managed, &d.managed) catch break :blk Value.nil_val;
                if (q.toI64()) |i| break :blk Value.initInteger(i);
                break :blk Value.initBigInt(q);
            }
        },
        .char => |c| Value.initChar(c),
        .string => |s| Value.initString(allocator, s),
        .symbol => |sym| Value.initSymbol(allocator, .{ .ns = sym.ns, .name = sym.name }),
        .keyword => |sym| Value.initKeyword(allocator, .{ .ns = sym.ns, .name = sym.name }),
        // Collections/regex not supported here — use macro.formToValue instead.
        .list, .vector, .map, .set => Value.nil_val,
        .regex => |_| Value.nil_val,
        .tag => Value.nil_val,
    };
}

// === Tests ===

test "analyze nil literal" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const result = try a.analyze(.{ .data = .nil });
    try std.testing.expectEqualStrings("constant", result.kindName());
    try std.testing.expect(result.constant.value.isNil());
}

test "analyze boolean literals" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const t = try a.analyze(.{ .data = .{ .boolean = true } });
    try std.testing.expect(t.constant.value.eql(Value.true_val));

    const f = try a.analyze(.{ .data = .{ .boolean = false } });
    try std.testing.expect(f.constant.value.eql(Value.false_val));
}

test "analyze integer literal" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const result = try a.analyze(.{ .data = .{ .integer = 42 } });
    try std.testing.expect(result.constant.value.eql(Value.initInteger(42)));
}

test "analyze string literal" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const result = try a.analyze(.{ .data = .{ .string = "hello" } });
    try std.testing.expect(result.constant.value.eql(Value.initString(arena.allocator(), "hello")));
}

test "analyze keyword" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const result = try a.analyze(.{ .data = .{ .keyword = .{ .ns = null, .name = "foo" } } });
    try std.testing.expectEqualStrings("constant", result.kindName());
}

test "analyze unresolved symbol -> var_ref" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const result = try a.analyze(.{ .data = .{ .symbol = .{ .ns = null, .name = "+" } } });
    try std.testing.expectEqualStrings("var-ref", result.kindName());
    try std.testing.expectEqualStrings("+", result.var_ref.name);
}

test "analyze (if true 1 2)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "if" } } },
        .{ .data = .{ .boolean = true } },
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .integer = 2 } },
    };
    const result = try a.analyze(.{ .data = .{ .list = &items } });
    try std.testing.expectEqualStrings("if", result.kindName());
    try std.testing.expect(result.if_node.else_node != null);
}

test "analyze (if true 1) - no else" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "if" } } },
        .{ .data = .{ .boolean = true } },
        .{ .data = .{ .integer = 1 } },
    };
    const result = try a.analyze(.{ .data = .{ .list = &items } });
    try std.testing.expectEqualStrings("if", result.kindName());
    try std.testing.expect(result.if_node.else_node == null);
}

test "analyze (do 1 2 3)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "do" } } },
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .integer = 2 } },
        .{ .data = .{ .integer = 3 } },
    };
    const result = try a.analyze(.{ .data = .{ .list = &items } });
    try std.testing.expectEqualStrings("do", result.kindName());
    try std.testing.expectEqual(@as(usize, 3), result.do_node.statements.len);
}

test "analyze (let [x 1] x)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const bindings = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "x" } } },
        .{ .data = .{ .integer = 1 } },
    };
    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "let" } } },
        .{ .data = .{ .vector = &bindings } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "x" } } },
    };
    const result = try a.analyze(.{ .data = .{ .list = &items } });
    try std.testing.expectEqualStrings("let", result.kindName());
    try std.testing.expectEqual(@as(usize, 1), result.let_node.bindings.len);
    try std.testing.expectEqualStrings("x", result.let_node.bindings[0].name);
    // Body should be local_ref
    try std.testing.expectEqualStrings("local-ref", result.let_node.body.kindName());
}

test "analyze (fn [x] x)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const params = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "x" } } },
    };
    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "fn" } } },
        .{ .data = .{ .vector = &params } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "x" } } },
    };
    const result = try a.analyze(.{ .data = .{ .list = &items } });
    try std.testing.expectEqualStrings("fn", result.kindName());
    try std.testing.expectEqual(@as(usize, 1), result.fn_node.arities.len);
    try std.testing.expect(!result.fn_node.arities[0].variadic);
    // Body should resolve x as local_ref
    try std.testing.expectEqualStrings("local-ref", result.fn_node.arities[0].body.kindName());
}

test "analyze (fn [x & rest] x) - variadic" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const params = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "x" } } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "&" } } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "rest" } } },
    };
    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "fn" } } },
        .{ .data = .{ .vector = &params } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "x" } } },
    };
    const result = try a.analyze(.{ .data = .{ .list = &items } });
    try std.testing.expect(result.fn_node.arities[0].variadic);
    try std.testing.expectEqual(@as(usize, 2), result.fn_node.arities[0].params.len);
}

test "analyze (def x 42)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "def" } } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "x" } } },
        .{ .data = .{ .integer = 42 } },
    };
    const result = try a.analyze(.{ .data = .{ .list = &items } });
    try std.testing.expectEqualStrings("def", result.kindName());
    try std.testing.expectEqualStrings("x", result.def_node.sym_name);
    try std.testing.expect(result.def_node.init != null);
    try std.testing.expect(!result.def_node.is_macro);
}

test "analyze (quote foo)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "quote" } } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "foo" } } },
    };
    const result = try a.analyze(.{ .data = .{ .list = &items } });
    try std.testing.expectEqualStrings("quote", result.kindName());
    switch (result.quote_node.value.tag()) {
        .symbol => try std.testing.expectEqualStrings("foo", result.quote_node.value.asSymbol().name),
        else => unreachable,
    }
}

test "analyze (defmacro m [x] x)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const params = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "x" } } },
    };
    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "defmacro" } } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "m" } } },
        .{ .data = .{ .vector = &params } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "x" } } },
    };
    const result = try a.analyze(.{ .data = .{ .list = &items } });
    try std.testing.expectEqualStrings("def", result.kindName());
    try std.testing.expect(result.def_node.is_macro);
    try std.testing.expectEqualStrings("m", result.def_node.sym_name);
    // init should be a fn_node
    try std.testing.expectEqualStrings("fn", result.def_node.init.?.kindName());
}

test "analyze function call (+ 1 2)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "+" } } },
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .integer = 2 } },
    };
    const result = try a.analyze(.{ .data = .{ .list = &items } });
    try std.testing.expectEqualStrings("call", result.kindName());
    try std.testing.expectEqual(@as(usize, 2), result.call_node.args.len);
}

test "analyze vector literal [1 2 3]" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const items = [_]Form{
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .integer = 2 } },
        .{ .data = .{ .integer = 3 } },
    };
    const result = try a.analyze(.{ .data = .{ .vector = &items } });
    // All constants -> should be a constant vector
    try std.testing.expectEqualStrings("constant", result.kindName());
    try std.testing.expect(result.constant.value.tag() == .vector);
}

test "analyze error: if with wrong arity" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "if" } } },
        .{ .data = .{ .boolean = true } },
    };
    const result = a.analyze(.{ .data = .{ .list = &items } });
    try std.testing.expectError(error.ArityError, result);
}

test "analyze let scoping - x not visible after let" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    // First, analyze (let [x 1] x) to verify x resolves
    const bindings = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "x" } } },
        .{ .data = .{ .integer = 1 } },
    };
    const let_items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "let" } } },
        .{ .data = .{ .vector = &bindings } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "x" } } },
    };
    const let_result = try a.analyze(.{ .data = .{ .list = &let_items } });
    try std.testing.expectEqualStrings("local-ref", let_result.let_node.body.kindName());

    // After let, x should be var_ref (not local)
    const x_after = try a.analyze(.{ .data = .{ .symbol = .{ .ns = null, .name = "x" } } });
    try std.testing.expectEqualStrings("var-ref", x_after.kindName());
}

test "analyze named fn with self-reference" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const params = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "n" } } },
    };
    const call_items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "fact" } } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "n" } } },
    };
    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "fn" } } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "fact" } } },
        .{ .data = .{ .vector = &params } },
        .{ .data = .{ .list = &call_items } },
    };
    const result = try a.analyze(.{ .data = .{ .list = &items } });
    try std.testing.expectEqualStrings("fn", result.kindName());
    try std.testing.expectEqualStrings("fact", result.fn_node.name.?);
    // Body should be call_node
    try std.testing.expectEqualStrings("call", result.fn_node.arities[0].body.kindName());
    // fact should resolve as local_ref inside body
    try std.testing.expectEqualStrings("local-ref", result.fn_node.arities[0].body.call_node.callee.kindName());
}

test "formToValue converts primitives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = formToValue(alloc, .{ .data = .{ .integer = 42 } });
    try std.testing.expect(val.eql(Value.initInteger(42)));

    const sym = formToValue(alloc, .{ .data = .{ .symbol = .{ .ns = null, .name = "foo" } } });
    try std.testing.expect(sym.tag() == .symbol);
    try std.testing.expectEqualStrings("foo", sym.asSymbol().name);
}

test "analyze (loop [x 0] x)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const bindings = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "x" } } },
        .{ .data = .{ .integer = 0 } },
    };
    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "loop" } } },
        .{ .data = .{ .vector = &bindings } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "x" } } },
    };
    const result = try a.analyze(.{ .data = .{ .list = &items } });
    try std.testing.expectEqualStrings("loop", result.kindName());
    try std.testing.expectEqual(@as(usize, 1), result.loop_node.bindings.len);
    try std.testing.expectEqualStrings("x", result.loop_node.bindings[0].name);
    try std.testing.expectEqualStrings("local-ref", result.loop_node.body.kindName());
}

test "analyze (recur 1 2)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "recur" } } },
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .integer = 2 } },
    };
    const result = try a.analyze(.{ .data = .{ .list = &items } });
    try std.testing.expectEqualStrings("recur", result.kindName());
    try std.testing.expectEqual(@as(usize, 2), result.recur_node.args.len);
}

test "analyze (throw \"error\")" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "throw" } } },
        .{ .data = .{ .string = "error" } },
    };
    const result = try a.analyze(.{ .data = .{ .list = &items } });
    try std.testing.expectEqualStrings("throw", result.kindName());
    try std.testing.expect(result.throw_node.expr.constant.value.eql(Value.initString(arena.allocator(), "error")));
}

test "analyze (try 1 (catch Exception e 2))" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    // (catch Exception e 2)
    const catch_items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "catch" } } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "Exception" } } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "e" } } },
        .{ .data = .{ .integer = 2 } },
    };
    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "try" } } },
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .list = &catch_items } },
    };
    const result = try a.analyze(.{ .data = .{ .list = &items } });
    try std.testing.expectEqualStrings("try", result.kindName());
    try std.testing.expect(result.try_node.catch_clause != null);
    try std.testing.expectEqualStrings("e", result.try_node.catch_clause.?.binding_name);
    try std.testing.expect(result.try_node.finally_body == null);
    // body should be constant 1
    try std.testing.expect(result.try_node.body.constant.value.eql(Value.initInteger(1)));
}

test "analyze (try 1 (finally 3))" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const finally_items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "finally" } } },
        .{ .data = .{ .integer = 3 } },
    };
    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "try" } } },
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .list = &finally_items } },
    };
    const result = try a.analyze(.{ .data = .{ .list = &items } });
    try std.testing.expectEqualStrings("try", result.kindName());
    try std.testing.expect(result.try_node.catch_clause == null);
    try std.testing.expect(result.try_node.finally_body != null);
}

test "analyze (try 1 (catch Exception e 2) (finally 3))" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const catch_items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "catch" } } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "Exception" } } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "e" } } },
        .{ .data = .{ .integer = 2 } },
    };
    const finally_items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "finally" } } },
        .{ .data = .{ .integer = 3 } },
    };
    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "try" } } },
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .list = &catch_items } },
        .{ .data = .{ .list = &finally_items } },
    };
    const result = try a.analyze(.{ .data = .{ .list = &items } });
    try std.testing.expectEqualStrings("try", result.kindName());
    try std.testing.expect(result.try_node.catch_clause != null);
    try std.testing.expect(result.try_node.finally_body != null);
}

test "analyze error: loop without binding vector" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "loop" } } },
    };
    const result = a.analyze(.{ .data = .{ .list = &items } });
    try std.testing.expectError(error.ArityError, result);
}

test "analyze error: loop odd bindings" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const bindings = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "x" } } },
        .{ .data = .{ .integer = 0 } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "y" } } },
    };
    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "loop" } } },
        .{ .data = .{ .vector = &bindings } },
        .{ .data = .{ .integer = 1 } },
    };
    const result = a.analyze(.{ .data = .{ .list = &items } });
    try std.testing.expectError(error.ValueError, result);
}

test "analyze error: throw wrong arity" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "throw" } } },
    };
    const result = a.analyze(.{ .data = .{ .list = &items } });
    try std.testing.expectError(error.ArityError, result);
}

test "analyze error: catch missing binding symbol" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const catch_items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "catch" } } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "Exception" } } },
        .{ .data = .{ .integer = 42 } }, // not a symbol
        .{ .data = .{ .integer = 2 } },
    };
    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "try" } } },
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .list = &catch_items } },
    };
    const result = a.analyze(.{ .data = .{ .list = &items } });
    try std.testing.expectError(error.ValueError, result);
}

test "analyze catch scoping - e not visible after try" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    // (try 1 (catch Exception e e))
    const catch_items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "catch" } } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "Exception" } } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "e" } } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "e" } } },
    };
    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "try" } } },
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .list = &catch_items } },
    };
    const result = try a.analyze(.{ .data = .{ .list = &items } });
    // e inside catch handler should be local_ref
    try std.testing.expectEqualStrings("local-ref", result.try_node.catch_clause.?.body.kindName());

    // After try, e should be var_ref (not local)
    const e_after = try a.analyze(.{ .data = .{ .symbol = .{ .ns = null, .name = "e" } } });
    try std.testing.expectEqualStrings("var-ref", e_after.kindName());
}

test "analyze loop scoping - x not visible after loop" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const bindings = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "x" } } },
        .{ .data = .{ .integer = 0 } },
    };
    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "loop" } } },
        .{ .data = .{ .vector = &bindings } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "x" } } },
    };
    _ = try a.analyze(.{ .data = .{ .list = &items } });

    // After loop, x should be var_ref
    const x_after = try a.analyze(.{ .data = .{ .symbol = .{ .ns = null, .name = "x" } } });
    try std.testing.expectEqualStrings("var-ref", x_after.kindName());
}

test "macro expansion - builtin_fn macro" {
    // Create a simple macro that transforms (my-macro x) -> (do x)
    // by wrapping the arg in a (do ...) list
    const TestMacro = struct {
        fn expandFn(allocator: Allocator, args: []const Value) anyerror!Value {
            // Build (do arg0): list with symbol "do" + first arg
            const items = try allocator.alloc(Value, 1 + args.len);
            items[0] = Value.initSymbol(allocator, .{ .ns = null, .name = "do" });
            for (args, 0..) |arg, i| {
                items[1 + i] = arg;
            }
            const lst = try allocator.create(collections.PersistentList);
            lst.* = .{ .items = items };
            return Value.initList(lst);
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Set up env with a macro var
    var env = Env.init(alloc);
    defer env.deinit();
    const ns = try env.findOrCreateNamespace("user");
    env.current_ns = ns;
    const v = try ns.intern("my-macro");
    v.setMacro(true);
    v.bindRoot(Value.initBuiltinFn(&TestMacro.expandFn));

    var a = Analyzer.initWithEnv(alloc, &env);
    defer a.deinit();

    // (my-macro 42) should expand to (do 42), which analyzes as constant 42
    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "my-macro" } } },
        .{ .data = .{ .integer = 42 } },
    };
    const result = try a.analyze(.{ .data = .{ .list = &items } });
    // (do 42) -> DoNode with single expr -> constant 42
    try std.testing.expect(result.* == .do_node);
}

test "analyze empty list -> empty list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator());
    defer a.deinit();

    const items = [_]Form{};
    const result = try a.analyze(.{ .data = .{ .list = &items } });
    // Empty list () is self-evaluating in Clojure
    try std.testing.expect(result.constant.value.tag() == .list);
    try std.testing.expectEqual(@as(usize, 0), result.constant.value.asList().items.len);
}
