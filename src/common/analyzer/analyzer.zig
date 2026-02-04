// Analyzer — transforms Form (Reader output) into Node (executable AST).
//
// Three-phase architecture:
//   Form (Reader) -> Node (Analyzer) -> Value (Runtime)
//
// Special forms are dispatched via comptime StaticStringMap (not if-else chain).
// Phase 1c: no Env/Namespace/Var (name-based var_ref only).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Form = @import("../reader/form.zig").Form;
const FormData = @import("../reader/form.zig").FormData;
const SymbolRef = @import("../reader/form.zig").SymbolRef;
const node_mod = @import("node.zig");
const Node = node_mod.Node;
const SourceInfo = node_mod.SourceInfo;
const Value = @import("../value.zig").Value;
const err = @import("../error.zig");
const env_mod = @import("../env.zig");
const Env = env_mod.Env;
const var_mod = @import("../var.zig");
const Var = var_mod.Var;
const macro = @import("../macro.zig");
const collections = @import("../collections.zig");
const bootstrap = @import("../bootstrap.zig");
const value_mod = @import("../value.zig");
const regex_matcher = @import("../regex/matcher.zig");

/// Analyzer — stateful Form -> Node transformer.
pub const Analyzer = struct {
    allocator: Allocator,
    error_ctx: *err.ErrorContext,

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

    pub fn init(allocator: Allocator, error_ctx: *err.ErrorContext) Analyzer {
        return .{ .allocator = allocator, .error_ctx = error_ctx };
    }

    pub fn initWithEnv(allocator: Allocator, error_ctx: *err.ErrorContext, env: *Env) Analyzer {
        return .{ .allocator = allocator, .error_ctx = error_ctx, .env = env };
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

    fn analysisError(self: *Analyzer, kind: err.Kind, message: []const u8, form: Form) AnalyzeError {
        return self.error_ctx.setError(.{
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
        n.* = .{ .constant = val };
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
        return self.makeConstant(.{ .regex = pat });
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
        .{ "defrecord", analyzeDefrecord },
        .{ "defmulti", analyzeDefmulti },
        .{ "defmethod", analyzeDefmethod },
        .{ "lazy-seq", analyzeLazySeq },
        .{ "var", analyzeVarForm },
    });

    // === Main entry point ===

    /// Analyze a Form, producing a Node.
    pub fn analyze(self: *Analyzer, form: Form) AnalyzeError!*Node {
        return switch (form.data) {
            .nil => self.makeConstant(.nil),
            .boolean => |b| self.makeConstant(.{ .boolean = b }),
            .integer => |n| self.makeConstant(.{ .integer = n }),
            .float => |n| self.makeConstant(.{ .float = n }),
            .char => |c| self.makeConstant(.{ .char = c }),
            .string => |s| self.makeConstant(.{ .string = s }),
            .keyword => |sym| self.makeConstant(.{ .keyword = .{ .ns = sym.ns, .name = sym.name } }),
            .symbol => |sym| self.analyzeSymbol(sym, form),
            .list => |items| self.analyzeList(items, form),
            .vector => |items| self.analyzeVector(items, form),
            .map => |items| self.analyzeMap(items, form),
            .set => |items| self.analyzeSet(items, form),
            .regex => |pattern| self.analyzeRegex(pattern, form),
            .tag => self.makeConstant(.nil), // tagged literals deferred
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
        // Fall through to var_ref (name-based in Phase 1c)
        return self.makeVarRef(sym, form);
    }

    // === List analysis ===

    fn analyzeList(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        if (items.len == 0) {
            // Empty list () -> empty list (self-evaluating in Clojure)
            const empty_list = self.allocator.create(value_mod.PersistentList) catch return error.OutOfMemory;
            empty_list.* = .{ .items = &.{} };
            return self.makeConstant(.{ .list = empty_list });
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

        // Function call
        return self.analyzeCall(items, form);
    }

    /// Resolve a symbol to a Var if possible (via env).
    fn resolveMacroVar(self: *const Analyzer, sym: SymbolRef) ?*Var {
        const env = self.env orelse return null;
        const ns = env.current_ns orelse return null;
        if (sym.ns) |ns_name| {
            return ns.resolveQualified(ns_name, sym.name);
        }
        return ns.resolve(sym.name);
    }

    /// Expand a macro call: execute macro function with raw Form args, re-analyze result.
    fn expandMacro(self: *Analyzer, v: *Var, arg_forms: []const Form, form: Form) AnalyzeError!*Node {
        const root = v.deref();

        // Convert arg Forms to Values for the macro function
        var arg_vals: [256]Value = undefined;
        if (arg_forms.len > arg_vals.len) {
            return self.analysisError(.arity_error, "too many macro arguments", form);
        }
        for (arg_forms, 0..) |af, i| {
            arg_vals[i] = macro.formToValue(self.allocator, af) catch return error.OutOfMemory;
        }

        // Call the macro function via unified dispatch
        const result_val: Value = bootstrap.callFnVal(self.allocator, root, arg_vals[0..arg_forms.len]) catch {
            return self.analysisError(.value_error, "macro expansion failed", form);
        };

        // Convert result Value back to Form
        const expanded_form = macro.valueToForm(self.allocator, result_val) catch return error.OutOfMemory;

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
            return self.makeConstant(.nil);
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

    fn analyzeFn(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (fn name? docstring? [params] body...) or (fn name? docstring? ([params] body...) ...)
        if (items.len < 2) {
            return self.analysisError(.arity_error, "fn requires parameter vector", form);
        }

        var idx: usize = 1;
        var name: ?[]const u8 = null;

        // Optional name
        if (items[idx].data == .symbol) {
            name = items[idx].data.symbol.name;
            idx += 1;
        }

        if (idx >= items.len) {
            return self.analysisError(.arity_error, "fn requires parameter vector", form);
        }

        // Optional docstring (skip it, metadata support deferred)
        if (items[idx].data == .string) {
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

        // Single arity: [params] body...
        if (items[idx].data == .vector) {
            const arity = try self.analyzeFnArity(items[idx].data.vector, items[idx + 1 ..], form);
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
            if (arity_items.len == 0 or arity_items[0].data != .vector) {
                return self.analysisError(.arity_error, "fn arity must start with parameter vector", form);
            }

            const arity = try self.analyzeFnArity(arity_items[0].data.vector, arity_items[1..], form);
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

    fn analyzeFnArity(self: *Analyzer, params_form: []const Form, body_forms: []const Form, form: Form) AnalyzeError!node_mod.FnArity {
        var params: std.ArrayList([]const u8) = .empty;
        var variadic = false;

        // Track which params need destructuring (pattern_index -> synthetic_name)
        var destructure_patterns: std.ArrayList(DestructureEntry) = .empty;
        var has_destructuring = false;

        const start_locals = self.locals.items.len;

        var param_idx: usize = 0;
        for (params_form) |p| {
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
        // (def name) or (def name value)
        if (items.len < 2 or items.len > 3) {
            return self.analysisError(.arity_error, "def requires 1 or 2 arguments", form);
        }

        if (items[1].data != .symbol) {
            return self.analysisError(.value_error, "def name must be a symbol", items[1]);
        }

        const sym_name = items[1].data.symbol.name;
        const init_node: ?*Node = if (items.len == 3)
            try self.analyze(items[2])
        else
            null;

        const def_data = self.allocator.create(node_mod.DefNode) catch return error.OutOfMemory;
        def_data.* = .{
            .sym_name = sym_name,
            .init = init_node,
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

        const val = macro.formToValue(self.allocator, items[1]) catch return error.OutOfMemory;

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
        // (defmacro name docstring? [params] body...) - treated like def + fn with is_macro flag
        if (items.len < 3) {
            return self.analysisError(.arity_error, "defmacro requires name and body", form);
        }

        if (items[1].data != .symbol) {
            return self.analysisError(.value_error, "defmacro name must be a symbol", items[1]);
        }

        const sym_name = items[1].data.symbol.name;

        // Skip optional docstring
        var body_start: usize = 2;
        if (items[body_start].data == .string) {
            body_start += 1;
        }

        if (body_start >= items.len) {
            return self.analysisError(.arity_error, "defmacro requires parameter vector", form);
        }

        // Build fn node from remaining forms (params + body)
        // Synthesize a fn form: (fn [params] body...)
        const fn_node = try self.analyzeFnBody(items[body_start..], form);

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

        const start_locals = self.locals.items.len;

        // Process bindings with destructuring support
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
                    // :while is complex (early termination), skip for now
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
        const coll_node = try self.analyze(coll_form);

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

        // Build fn body
        var fn_body: *Node = undefined;

        if (is_last) {
            fn_body = try self.analyzeBody(body_forms, form);
        } else {
            fn_body = try self.expandForBindings(remaining_bindings, body_forms, form);
        }

        // Wrap with :let bindings if any
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

        // Wrap with :when guards
        for (when_forms.items) |when_form| {
            const test_node = try self.analyze(when_form);
            if (is_last) {
                // For innermost level with :when, wrap in (when test body) => (if test (list body) (list))
                // We need to return a list for filter-like behavior
                // Actually: (for [x coll :when pred] body) should only include x when pred is true
                // Strategy: wrap body in (if test [body] []) and then mapcat
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

        // If destructuring needed, wrap body in let
        if (needs_destructure) {
            const ref = try self.makeTempLocalRef(param_name, param_idx);
            var destr_bindings: std.ArrayList(node_mod.LetBinding) = .empty;
            try self.expandBindingPattern(sym_form, ref, &destr_bindings, form);
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

        // Build the call: map or mapcat
        // For nested/when cases, use (apply concat (map fn coll)) directly
        // instead of (mapcat fn coll) to avoid dependency on core.clj's mapcat
        const use_flatten = !is_last or when_forms.items.len > 0;

        const map_args = self.allocator.alloc(*Node, 2) catch return error.OutOfMemory;
        map_args[0] = fn_node;
        map_args[1] = coll_node;
        const map_call = try self.makeBuiltinCall("map", map_args);

        if (!use_flatten) {
            return map_call;
        }

        // (apply concat (map fn coll))
        const concat_ref = self.allocator.create(Node) catch return error.OutOfMemory;
        concat_ref.* = .{ .var_ref = .{ .ns = null, .name = "concat", .source = .{} } };
        const apply_args = self.allocator.alloc(*Node, 2) catch return error.OutOfMemory;
        apply_args[0] = concat_ref;
        apply_args[1] = map_call;
        return self.makeBuiltinCall("apply", apply_args);
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
            sigs.append(self.allocator, .{
                .name = m_items[0].data.symbol.name,
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
        if (items[1].data != .symbol) {
            return self.analysisError(.value_error, "extend-type type must be a symbol", items[1]);
        }
        const type_name = items[1].data.symbol.name;

        // Protocol name
        if (items[2].data != .symbol) {
            return self.analysisError(.value_error, "extend-type protocol must be a symbol", items[2]);
        }
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
            .protocol_name = protocol_name,
            .methods = methods.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            .source = self.sourceFromForm(form),
        };

        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .extend_type_node = et };
        return n;
    }

    fn analyzeDefrecord(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (defrecord Name [fields])
        // Expand to Form: (def ->Name (fn ->Name [field1 field2] (hash-map :field1 field1 ...)))
        // Then re-analyze the constructed Form.
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

        // Build (hash-map :field1 field1 :field2 field2 ...) as Forms
        const hm_form_count = 1 + fields.len * 2; // hash-map + pairs
        const hm_forms = self.allocator.alloc(Form, hm_form_count) catch return error.OutOfMemory;
        hm_forms[0] = .{ .data = .{ .symbol = .{ .ns = null, .name = "hash-map" } } };
        for (fields, 0..) |field, i| {
            hm_forms[1 + i * 2] = .{ .data = .{ .keyword = .{ .ns = null, .name = field.data.symbol.name } } };
            hm_forms[1 + i * 2 + 1] = field; // symbol ref
        }

        // Build (fn ->Name [fields...] (hash-map ...))
        const fn_forms = self.allocator.alloc(Form, 4) catch return error.OutOfMemory;
        fn_forms[0] = .{ .data = .{ .symbol = .{ .ns = null, .name = "fn" } } };
        fn_forms[1] = .{ .data = .{ .symbol = .{ .ns = null, .name = ctor_name } } };
        fn_forms[2] = items[2]; // [fields] vector
        fn_forms[3] = .{ .data = .{ .list = hm_forms } };

        // Build (def ->Name (fn ...))
        const def_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        def_forms[0] = .{ .data = .{ .symbol = .{ .ns = null, .name = "def" } } };
        def_forms[1] = .{ .data = .{ .symbol = .{ .ns = null, .name = ctor_name } } };
        def_forms[2] = .{ .data = .{ .list = fn_forms } };

        const def_form = Form{ .data = .{ .list = def_forms } };
        return self.analyze(def_form);
    }

    fn analyzeDefmulti(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (defmulti name dispatch-fn)
        if (items.len < 3) {
            return self.analysisError(.arity_error, "defmulti requires name and dispatch-fn", form);
        }
        if (items[1].data != .symbol) {
            return self.analysisError(.value_error, "defmulti name must be a symbol", items[1]);
        }

        const name = items[1].data.symbol.name;
        const dispatch_node = try self.analyze(items[2]);

        const dm = self.allocator.create(node_mod.DefMultiNode) catch return error.OutOfMemory;
        dm.* = .{
            .name = name,
            .dispatch_fn = dispatch_node,
            .source = self.sourceFromForm(form),
        };

        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .defmulti_node = dm };
        return n;
    }

    fn analyzeDefmethod(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        // (defmethod name dispatch-val [args] body)
        if (items.len < 5) {
            return self.analysisError(.arity_error, "defmethod requires name, dispatch-val, args, body", form);
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
        const the_var = if (sym.ns) |ns_name|
            ns.resolveQualified(ns_name, sym.name)
        else
            ns.resolve(sym.name);
        if (the_var) |v| {
            return self.makeConstant(.{ .var_ref = v });
        }
        return self.analysisError(.syntax_error, "Unable to resolve var", form);
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
        var catch_clause: ?node_mod.CatchClause = null;
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
                        // sub_items[1] = ExType (ignored in Phase 1c)
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

                        catch_clause = .{
                            .binding_name = binding_name,
                            .body = handler_body,
                        };
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

        const try_data = self.allocator.create(node_mod.TryNode) catch return error.OutOfMemory;
        try_data.* = .{
            .body = body_node,
            .catch_clause = catch_clause,
            .finally_body = finally_body,
            .source = self.sourceFromForm(form),
        };

        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .try_node = try_data };
        return n;
    }

    /// Analyze fn body starting from params vector (helper for defmacro).
    fn analyzeFnBody(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        if (items.len == 0 or items[0].data != .vector) {
            return self.analysisError(.arity_error, "expected parameter vector", form);
        }

        const arity = try self.analyzeFnArity(items[0].data.vector, items[1..], form);
        const arities = self.allocator.alloc(node_mod.FnArity, 1) catch return error.OutOfMemory;
        arities[0] = arity;

        const fn_data = self.allocator.create(node_mod.FnNode) catch return error.OutOfMemory;
        fn_data.* = .{
            .name = null,
            .arities = arities,
            .source = self.sourceFromForm(form),
        };

        const n = self.allocator.create(Node) catch return error.OutOfMemory;
        n.* = .{ .fn_node = fn_data };
        return n;
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
        _ = form;
        // For Phase 1c, analyze each element; wrap as call to "vector" builtin.
        // Since we don't have builtins yet, produce constant if all elements are constant,
        // otherwise produce a call node with var_ref to "vector".
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
                values[i] = n.constant;
            }
            const vec = self.allocator.create(@import("../value.zig").PersistentVector) catch return error.OutOfMemory;
            vec.* = .{ .items = values };
            return self.makeConstant(.{ .vector = vec });
        }

        // Non-constant: produce call to "vector"
        return self.makeBuiltinCall("vector", nodes);
    }

    fn analyzeMap(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        _ = form;
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
                values[i] = n.constant;
            }
            const m = self.allocator.create(@import("../value.zig").PersistentArrayMap) catch return error.OutOfMemory;
            m.* = .{ .entries = values };
            return self.makeConstant(.{ .map = m });
        }

        return self.makeBuiltinCall("hash-map", nodes);
    }

    fn analyzeSet(self: *Analyzer, items: []const Form, form: Form) AnalyzeError!*Node {
        _ = form;
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
                values[i] = n.constant;
            }
            const s = self.allocator.create(@import("../value.zig").PersistentHashSet) catch return error.OutOfMemory;
            s.* = .{ .items = values };
            return self.makeConstant(.{ .set = s });
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
    /// [a b & rest]  -> a = (nth coll 0), b = (nth coll 1), rest = (rest (rest coll))
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

        var pos: usize = 0;
        var i: usize = 0;
        while (i < elems.len) : (i += 1) {
            const elem = elems[i];

            // & rest check
            if (elem.data == .symbol and std.mem.eql(u8, elem.data.symbol.name, "&")) {
                if (i + 1 >= elems.len) {
                    return self.analysisError(.value_error, "& must be followed by a binding", form);
                }
                const rest_pattern = elems[i + 1];

                // rest = chained rest calls (pos times)
                const rest_init = try self.makeNthRest(temp_ref, pos);
                try self.expandBindingPattern(rest_pattern, rest_init, bindings, form);

                i += 1; // skip rest pattern

                // Check for :as after & rest
                if (i + 1 < elems.len) {
                    if (elems[i + 1].data == .keyword and std.mem.eql(u8, elems[i + 1].data.keyword.name, "as")) {
                        if (i + 2 >= elems.len) {
                            return self.analysisError(.value_error, ":as must be followed by a symbol", form);
                        }
                        try self.expandBindingPattern(elems[i + 2], temp_ref, bindings, form);
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
        // Bind whole collection to temp var
        const temp_name = "__destructure_map__";
        const temp_idx: u32 = @intCast(self.locals.items.len);
        self.locals.append(self.allocator, .{ .name = temp_name, .idx = temp_idx }) catch return error.OutOfMemory;
        bindings.append(self.allocator, .{ .name = temp_name, .init = init_node }) catch return error.OutOfMemory;

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
                    // :keys [a b c] -> each symbol becomes a keyword-keyed get
                    if (val.data != .vector) {
                        return self.analysisError(.value_error, ":keys must be followed by a vector", val);
                    }
                    for (val.data.vector) |sym_form| {
                        const sym_name = if (sym_form.data == .symbol)
                            sym_form.data.symbol.name
                        else if (sym_form.data == .keyword)
                            sym_form.data.keyword.name
                        else
                            return self.analysisError(.value_error, ":keys elements must be symbols or keywords", sym_form);
                        const get_init = try self.makeGetKeywordCall(temp_ref, sym_name, defaults);
                        const bind_idx: u32 = @intCast(self.locals.items.len);
                        self.locals.append(self.allocator, .{ .name = sym_name, .idx = bind_idx }) catch return error.OutOfMemory;
                        bindings.append(self.allocator, .{ .name = sym_name, .init = get_init }) catch return error.OutOfMemory;
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
                const get_init = try self.makeGetKeywordCall(temp_ref, val.data.keyword.name, null);
                const bind_idx: u32 = @intCast(self.locals.items.len);
                self.locals.append(self.allocator, .{ .name = sym_name, .idx = bind_idx }) catch return error.OutOfMemory;
                bindings.append(self.allocator, .{ .name = sym_name, .init = get_init }) catch return error.OutOfMemory;
            } else if (key.data == .map or key.data == .vector) {
                // Nested destructuring: {{x :x} :b} or {[a b] :items}
                // val is the lookup key, key is the nested pattern
                if (val.data != .keyword) {
                    return self.analysisError(.value_error, "nested destructuring: value must be a keyword", val);
                }
                const get_init = try self.makeGetKeywordCall(temp_ref, val.data.keyword.name, defaults);
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

    /// Generate (nth coll idx) call node.
    fn makeNthCall(self: *Analyzer, coll_node: *Node, idx: usize) AnalyzeError!*Node {
        const idx_node = try self.makeConstant(.{ .integer = @intCast(idx) });
        const args = self.allocator.alloc(*Node, 2) catch return error.OutOfMemory;
        args[0] = coll_node;
        args[1] = idx_node;
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

    /// Generate (get coll :keyword) or (get coll :keyword default) call node.
    fn makeGetKeywordCall(self: *Analyzer, coll_node: *Node, key_name: []const u8, defaults: ?[]const Form) AnalyzeError!*Node {
        const key_node = try self.makeConstant(.{ .keyword = .{ .ns = null, .name = key_name } });
        const default_node = try self.findDefault(key_name, defaults);
        return self.makeGetCallNode(coll_node, key_node, default_node);
    }

    /// Generate (get coll "string") or (get coll "string" default) call node.
    fn makeGetStringCall(self: *Analyzer, coll_node: *Node, key_name: []const u8, defaults: ?[]const Form) AnalyzeError!*Node {
        const key_node = try self.makeConstant(.{ .string = key_name });
        const default_node = try self.findDefault(key_name, defaults);
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
            return self.makeConstant(.nil);
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
};

// === formToValue (for quote) ===

/// Convert a Form to a runtime Value (used by quote).
/// Collections are converted recursively.
pub fn formToValue(form: Form) Value {
    return switch (form.data) {
        .nil => .nil,
        .boolean => |b| .{ .boolean = b },
        .integer => |n| .{ .integer = n },
        .float => |n| .{ .float = n },
        .char => |c| .{ .char = c },
        .string => |s| .{ .string = s },
        .symbol => |sym| .{ .symbol = .{ .ns = sym.ns, .name = sym.name } },
        .keyword => |sym| .{ .keyword = .{ .ns = sym.ns, .name = sym.name } },
        // Collections require allocation; for Phase 1c, return nil placeholder.
        // Full collection quote support requires allocator (deferred).
        .list, .vector, .map, .set => .nil,
        .regex => |pattern| .{ .string = pattern },
        .tag => .nil,
    };
}

// === Tests ===

var test_error_ctx: err.ErrorContext = .{};

test "analyze nil literal" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
    defer a.deinit();

    const result = try a.analyze(.{ .data = .nil });
    try std.testing.expectEqualStrings("constant", result.kindName());
    try std.testing.expect(result.constant.isNil());
}

test "analyze boolean literals" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
    defer a.deinit();

    const t = try a.analyze(.{ .data = .{ .boolean = true } });
    try std.testing.expect(t.constant.eql(.{ .boolean = true }));

    const f = try a.analyze(.{ .data = .{ .boolean = false } });
    try std.testing.expect(f.constant.eql(.{ .boolean = false }));
}

test "analyze integer literal" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
    defer a.deinit();

    const result = try a.analyze(.{ .data = .{ .integer = 42 } });
    try std.testing.expect(result.constant.eql(.{ .integer = 42 }));
}

test "analyze string literal" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
    defer a.deinit();

    const result = try a.analyze(.{ .data = .{ .string = "hello" } });
    try std.testing.expect(result.constant.eql(.{ .string = "hello" }));
}

test "analyze keyword" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
    defer a.deinit();

    const result = try a.analyze(.{ .data = .{ .keyword = .{ .ns = null, .name = "foo" } } });
    try std.testing.expectEqualStrings("constant", result.kindName());
}

test "analyze unresolved symbol -> var_ref" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
    defer a.deinit();

    const result = try a.analyze(.{ .data = .{ .symbol = .{ .ns = null, .name = "+" } } });
    try std.testing.expectEqualStrings("var-ref", result.kindName());
    try std.testing.expectEqualStrings("+", result.var_ref.name);
}

test "analyze (if true 1 2)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
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
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
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
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
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
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
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
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
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
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
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
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
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
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
    defer a.deinit();

    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "quote" } } },
        .{ .data = .{ .symbol = .{ .ns = null, .name = "foo" } } },
    };
    const result = try a.analyze(.{ .data = .{ .list = &items } });
    try std.testing.expectEqualStrings("quote", result.kindName());
    switch (result.quote_node.value) {
        .symbol => |sym| try std.testing.expectEqualStrings("foo", sym.name),
        else => unreachable,
    }
}

test "analyze (defmacro m [x] x)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
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
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
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
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
    defer a.deinit();

    const items = [_]Form{
        .{ .data = .{ .integer = 1 } },
        .{ .data = .{ .integer = 2 } },
        .{ .data = .{ .integer = 3 } },
    };
    const result = try a.analyze(.{ .data = .{ .vector = &items } });
    // All constants -> should be a constant vector
    try std.testing.expectEqualStrings("constant", result.kindName());
    try std.testing.expect(result.constant == .vector);
}

test "analyze error: if with wrong arity" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
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
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
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
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
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
    const val = formToValue(.{ .data = .{ .integer = 42 } });
    try std.testing.expect(val.eql(.{ .integer = 42 }));

    const sym = formToValue(.{ .data = .{ .symbol = .{ .ns = null, .name = "foo" } } });
    try std.testing.expect(sym == .symbol);
    try std.testing.expectEqualStrings("foo", sym.symbol.name);
}

test "analyze (loop [x 0] x)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
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
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
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
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
    defer a.deinit();

    const items = [_]Form{
        .{ .data = .{ .symbol = .{ .ns = null, .name = "throw" } } },
        .{ .data = .{ .string = "error" } },
    };
    const result = try a.analyze(.{ .data = .{ .list = &items } });
    try std.testing.expectEqualStrings("throw", result.kindName());
    try std.testing.expect(result.throw_node.expr.constant.eql(.{ .string = "error" }));
}

test "analyze (try 1 (catch Exception e 2))" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
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
    try std.testing.expect(result.try_node.body.constant.eql(.{ .integer = 1 }));
}

test "analyze (try 1 (finally 3))" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
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
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
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
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
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
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
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
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
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
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
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
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
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
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
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
            items[0] = Value{ .symbol = .{ .ns = null, .name = "do" } };
            for (args, 0..) |arg, i| {
                items[1 + i] = arg;
            }
            const lst = try allocator.create(collections.PersistentList);
            lst.* = .{ .items = items };
            return Value{ .list = lst };
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
    v.bindRoot(.{ .builtin_fn = &TestMacro.expandFn });

    var a = Analyzer.initWithEnv(alloc, &test_error_ctx, &env);
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
    var a = Analyzer.init(arena.allocator(), &test_error_ctx);
    defer a.deinit();

    const items = [_]Form{};
    const result = try a.analyze(.{ .data = .{ .list = &items } });
    // Empty list () is self-evaluating in Clojure
    try std.testing.expect(result.constant == .list);
    try std.testing.expectEqual(@as(usize, 0), result.constant.list.items.len);
}
