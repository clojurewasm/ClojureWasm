// Misc builtins — gensym, compare-and-set!, format.
//
// Small standalone utilities that don't fit neatly into other domain files.

const std = @import("std");
const Allocator = std.mem.Allocator;
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const err = @import("../error.zig");
const bootstrap = @import("../bootstrap.zig");

// ============================================================
// gensym
// ============================================================

var gensym_counter: u64 = 0;

/// (gensym) => G__42
/// (gensym prefix-string) => prefix42
pub fn gensymFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len > 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to gensym", .{args.len});

    const prefix: []const u8 = if (args.len == 1) switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "gensym expects a string prefix, got {s}", .{@tagName(args[0].tag())}),
    } else "G__";

    gensym_counter += 1;

    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll(prefix);
    try w.print("{d}", .{gensym_counter});
    const name = try allocator.dupe(u8, w.buffered());
    return Value.initSymbol(allocator, .{ .ns = null, .name = name });
}

// ============================================================
// compare-and-set!
// ============================================================

/// (compare-and-set! atom oldval newval)
/// Atomically sets the value of atom to newval if and only if the
/// current value of the atom is identical to oldval. Returns true
/// if set happened, else false.
pub fn compareAndSetFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to compare-and-set!", .{args.len});
    const atom_ptr = switch (args[0].tag()) {
        .atom => args[0].asAtom(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "compare-and-set! expects an atom, got {s}", .{@tagName(args[0].tag())}),
    };
    const oldval = args[1];
    const newval = args[2];

    // Single-threaded: simple compare and swap
    if (atom_ptr.value.eql(oldval)) {
        atom_ptr.value = newval;
        return Value.true_val;
    }
    return Value.false_val;
}

// ============================================================
// format
// ============================================================

/// (format fmt & args)
/// Formats a string using java.lang.String/format-style placeholders.
/// Supported: %s (string), %d (integer), %f (float), %% (literal %).
fn writePadded(w: anytype, s: []const u8, width: ?usize, left_align: bool) !void {
    const min_width = width orelse 0;
    if (s.len >= min_width) {
        try w.writeAll(s);
        return;
    }
    const pad = min_width - s.len;
    if (left_align) {
        try w.writeAll(s);
        for (0..pad) |_| try w.writeByte(' ');
    } else {
        for (0..pad) |_| try w.writeByte(' ');
        try w.writeAll(s);
    }
}

fn formatFloat(w: anytype, val: f64, precision: usize) !void {
    // Format float with specified precision using Zig's fmt
    // We can't use runtime precision with std.fmt directly, so we manual-round
    const is_neg = val < 0;
    const abs_val = @abs(val);
    const multiplier = std.math.pow(f64, 10.0, @floatFromInt(precision));
    const rounded = @round(abs_val * multiplier);
    const int_part: u64 = @intFromFloat(@floor(abs_val));
    const frac_part: u64 = @intFromFloat(rounded - @floor(abs_val) * multiplier);

    if (is_neg) try w.writeByte('-');
    try w.print("{d}", .{int_part});
    if (precision > 0) {
        try w.writeByte('.');
        // Zero-pad fractional part to `precision` digits
        var frac_digits: usize = 0;
        var tmp = frac_part;
        if (tmp == 0) {
            frac_digits = 1;
        } else {
            while (tmp > 0) : (tmp /= 10) frac_digits += 1;
        }
        if (frac_digits < precision) {
            for (0..precision - frac_digits) |_| try w.writeByte('0');
        }
        try w.print("{d}", .{frac_part});
    }
}

pub fn formatFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to format", .{args.len});
    const fmt_str = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "format expects a string as first argument, got {s}", .{@tagName(args[0].tag())}),
    };
    const fmt_args = args[1..];

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var w = &aw.writer;

    var arg_idx: usize = 0;
    var i: usize = 0;
    while (i < fmt_str.len) {
        if (fmt_str[i] == '%') {
            i += 1;
            if (i >= fmt_str.len) return error.FormatError;

            // %% — literal percent
            if (fmt_str[i] == '%') {
                try w.writeByte('%');
                i += 1;
                continue;
            }

            // Parse optional flags, width, precision
            var left_align = false;
            if (i < fmt_str.len and fmt_str[i] == '-') {
                left_align = true;
                i += 1;
            }

            var width: ?usize = null;
            while (i < fmt_str.len and fmt_str[i] >= '0' and fmt_str[i] <= '9') {
                width = (width orelse 0) * 10 + @as(usize, fmt_str[i] - '0');
                i += 1;
            }

            var precision: ?usize = null;
            if (i < fmt_str.len and fmt_str[i] == '.') {
                i += 1;
                precision = 0;
                while (i < fmt_str.len and fmt_str[i] >= '0' and fmt_str[i] <= '9') {
                    precision = precision.? * 10 + @as(usize, fmt_str[i] - '0');
                    i += 1;
                }
            }

            if (i >= fmt_str.len) return error.FormatError;

            switch (fmt_str[i]) {
                's' => {
                    if (arg_idx >= fmt_args.len) return error.FormatError;
                    // Format value to temporary buffer
                    var tmp = std.Io.Writer.Allocating.init(allocator);
                    defer tmp.deinit();
                    try fmt_args[arg_idx].formatStr(&tmp.writer);
                    const s = tmp.writer.buffered();
                    try writePadded(w, s, width, left_align);
                    arg_idx += 1;
                },
                'd' => {
                    if (arg_idx >= fmt_args.len) return error.FormatError;
                    var tmp = std.Io.Writer.Allocating.init(allocator);
                    defer tmp.deinit();
                    switch (fmt_args[arg_idx].tag()) {
                        .integer => try tmp.writer.print("{d}", .{fmt_args[arg_idx].asInteger()}),
                        .float => try tmp.writer.print("{d}", .{@as(i64, @intFromFloat(fmt_args[arg_idx].asFloat()))}),
                        else => return error.FormatError,
                    }
                    try writePadded(w, tmp.writer.buffered(), width, left_align);
                    arg_idx += 1;
                },
                'f' => {
                    if (arg_idx >= fmt_args.len) return error.FormatError;
                    var tmp = std.Io.Writer.Allocating.init(allocator);
                    defer tmp.deinit();
                    const prec = precision orelse 6;
                    const fval: f64 = switch (fmt_args[arg_idx].tag()) {
                        .float => fmt_args[arg_idx].asFloat(),
                        .integer => @as(f64, @floatFromInt(fmt_args[arg_idx].asInteger())),
                        else => return error.FormatError,
                    };
                    try formatFloat(&tmp.writer, fval, prec);
                    try writePadded(w, tmp.writer.buffered(), width, left_align);
                    arg_idx += 1;
                },
                else => {
                    // Unsupported format specifier — pass through
                    try w.writeByte('%');
                    try w.writeByte(fmt_str[i]);
                },
            }
        } else {
            try w.writeByte(fmt_str[i]);
        }
        i += 1;
    }

    const result = try allocator.dupe(u8, aw.writer.buffered());
    return Value.initString(allocator, result);
}

// ============================================================
// BuiltinDef table
// ============================================================

// ============================================================
// Dynamic binding support
// ============================================================

/// (create-local-var) — Creates a fresh dynamic Var (for with-local-vars).
pub fn createLocalVarFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "create-local-var takes no arguments, got {d}", .{args.len});
    const v = allocator.create(var_mod.Var) catch return error.OutOfMemory;
    v.* = .{
        .sym = .{ .ns = null, .name = "__local" },
        .ns_name = "__local",
        .dynamic = true,
    };
    return Value.initVarRef(v);
}

/// (push-thread-bindings {var1 val1, var2 val2, ...})
/// Takes a map of Var refs to values, pushes a new binding frame.
pub fn pushThreadBindingsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "push-thread-bindings requires 1 argument, got {d}", .{args.len});
    const m = switch (args[0].tag()) {
        .map => args[0].asMap(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "push-thread-bindings requires a map", .{}),
    };
    const n_pairs = m.entries.len / 2;
    if (n_pairs == 0) return Value.nil_val;

    const entries = allocator.alloc(var_mod.BindingEntry, n_pairs) catch return error.OutOfMemory;
    var idx: usize = 0;
    var i: usize = 0;
    while (i < m.entries.len) : (i += 2) {
        const key = m.entries[i];
        const val = m.entries[i + 1];
        const v: *var_mod.Var = switch (key.tag()) {
            .var_ref => key.asVarRef(),
            else => return err.setErrorFmt(.eval, .type_error, .{}, "push-thread-bindings keys must be Vars", .{}),
        };
        if (!v.dynamic) return err.setErrorFmt(.eval, .value_error, .{}, "Can't dynamically bind non-dynamic var: {s}", .{v.sym.name});
        entries[idx] = .{ .var_ptr = v, .val = val };
        idx += 1;
    }

    const frame = allocator.create(var_mod.BindingFrame) catch return error.OutOfMemory;
    frame.* = .{ .entries = entries, .prev = null };
    var_mod.pushBindings(frame);
    return Value.nil_val;
}

/// (pop-thread-bindings) — pops the current binding frame.
pub fn popThreadBindingsFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "pop-thread-bindings takes no arguments, got {d}", .{args.len});
    var_mod.popBindings();
    return Value.nil_val;
}

/// (get-thread-bindings) — Returns a map of Var/value pairs for current thread bindings.
pub fn getThreadBindingsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "get-thread-bindings takes no arguments, got {d}", .{args.len});
    var frame = var_mod.getCurrentBindingFrame();
    if (frame == null) {
        // No bindings — return empty map
        const map = try allocator.create(value_mod.PersistentArrayMap);
        map.* = .{ .entries = &.{} };
        return Value.initMap(map);
    }
    // Collect effective bindings (innermost frame wins per Var)
    var seen_vars = std.ArrayList(*var_mod.Var).empty;
    var entries = std.ArrayList(Value).empty;
    while (frame) |f| {
        for (f.entries) |e| {
            // Check if we've already seen this Var (from an inner frame)
            var already_seen = false;
            for (seen_vars.items) |sv| {
                if (sv == e.var_ptr) {
                    already_seen = true;
                    break;
                }
            }
            if (!already_seen) {
                try seen_vars.append(allocator, e.var_ptr);
                try entries.append(allocator, Value.initVarRef(e.var_ptr));
                try entries.append(allocator, e.val);
            }
        }
        frame = f.prev;
    }
    const map = try allocator.create(value_mod.PersistentArrayMap);
    map.* = .{ .entries = entries.items };
    return Value.initMap(map);
}

// ============================================================
// thread-bound?, var-raw-root
// ============================================================

/// (thread-bound? & vars) — true if all given vars have thread-local bindings.
pub fn threadBoundPredFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args (0) passed to thread-bound?", .{});
    for (args) |arg| {
        const v = switch (arg.tag()) {
            .var_ref => arg.asVarRef(),
            else => return err.setErrorFmt(.eval, .type_error, .{}, "thread-bound? expects Var args, got {s}", .{@tagName(arg.tag())}),
        };
        if (!v.dynamic or !var_mod.hasThreadBinding(v)) return Value.false_val;
    }
    return Value.true_val;
}

/// (var-raw-root v) — returns the root value of a Var, bypassing thread-local bindings.
fn varRawRootFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to var-raw-root", .{args.len});
    const v = switch (args[0].tag()) {
        .var_ref => args[0].asVarRef(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "var-raw-root expects a Var, got {s}", .{@tagName(args[0].tag())}),
    };
    return v.getRawRoot();
}

/// (__var-bind-root v val) — sets the root binding of a Var directly.
/// Used by with-redefs-fn (JVM equivalent of .bindRoot).
fn varBindRootFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to __var-bind-root", .{args.len});
    const v = switch (args[0].tag()) {
        .var_ref => args[0].asVarRef(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "__var-bind-root expects a Var, got {s}", .{@tagName(args[0].tag())}),
    };
    v.bindRoot(args[1]);
    return args[1];
}

// ============================================================
// alter-var-root
// ============================================================

/// (alter-var-root var f & args) — atomically alters the root binding of var
/// by applying f to its current value plus any args.
pub fn alterVarRootFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to alter-var-root", .{args.len});
    const v = switch (args[0].tag()) {
        .var_ref => args[0].asVarRef(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "alter-var-root expects a var, got {s}", .{@tagName(args[0].tag())}),
    };
    const f = args[1];
    const old_val = v.deref();

    // Build call args: [old_val, extra_args...]
    const call_args = allocator.alloc(Value, 1 + (args.len - 2)) catch return error.OutOfMemory;
    call_args[0] = old_val;
    for (args[2..], 0..) |a, i| {
        call_args[1 + i] = a;
    }

    const new_val = bootstrap.callFnVal(allocator, f, call_args) catch |e| return e;
    v.bindRoot(new_val);
    return new_val;
}

// ============================================================
// ex-cause
// ============================================================

/// (ex-cause ex)
/// Returns the cause of an exception (currently always nil — no nested cause chain).
pub fn exCauseFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to ex-cause", .{args.len});
    // Check for :cause key in ex-info map
    if (args[0].tag() == .map) {
        const m = args[0].asMap();
        const cause_kw = Value.initKeyword(allocator, .{ .ns = null, .name = "cause" });
        if (m.get(cause_kw)) |cause_val| {
            return cause_val;
        }
    } else if (args[0].tag() == .hash_map) {
        const hm = args[0].asHashMap();
        const cause_kw = Value.initKeyword(allocator, .{ .ns = null, .name = "cause" });
        if (hm.get(cause_kw)) |cause_val| {
            return cause_val;
        }
    }
    return Value.nil_val;
}

// ============================================================
// Throwable->map
// ============================================================

/// (Throwable->map ex)
/// Constructs a data representation for an exception with keys:
///   :cause - root cause message
///   :via - cause chain (single entry for ClojureWasm)
///   :trace - call stack elements as [ns/fn file line] vectors
///   :data - ex-data if present
pub fn throwableToMapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to Throwable->map", .{args.len});

    const collections = @import("../collections.zig");
    const ex = args[0];

    // Extract message, data from exception
    var cause_msg: ?[]const u8 = null;
    var ex_data_val: Value = Value.nil_val;
    var ex_type: []const u8 = "Exception";

    if (ex.tag() == .map) {
        const m = ex.asMap();
        // Check for ex-info map
        const msg_kw = Value.initKeyword(allocator, .{ .ns = null, .name = "message" });
        if (m.get(msg_kw)) |msg_val| {
            if (msg_val.tag() == .string) cause_msg = msg_val.asString();
        }
        const data_kw = Value.initKeyword(allocator, .{ .ns = null, .name = "data" });
        if (m.get(data_kw)) |dv| ex_data_val = dv;
        // __ex_type (set by runtime exceptions) takes priority
        const et_kw = Value.initKeyword(allocator, .{ .ns = null, .name = "__ex_type" });
        if (m.get(et_kw)) |et_val| {
            if (et_val.tag() == .string) ex_type = et_val.asString();
        } else {
            // No __ex_type: check for __ex_info (user-thrown ex-info)
            const ei_kw = Value.initKeyword(allocator, .{ .ns = null, .name = "__ex_info" });
            if (m.get(ei_kw) != null) ex_type = "ExceptionInfo";
        }
    } else if (ex.tag() == .string) {
        cause_msg = ex.asString();
    }

    // If no message from exception, try last error
    if (cause_msg == null) {
        if (err.getLastError()) |info| {
            cause_msg = info.message;
        }
    }

    // Build :trace vector from saved call stack (snapshot taken at catch time)
    const saved = err.getSavedCallStack();
    const live = err.getCallStack();
    const stack = if (saved.len > 0) saved else live;
    const trace_items = allocator.alloc(Value, stack.len) catch return error.OutOfMemory;
    // Reverse: innermost frame first
    for (0..stack.len) |i| {
        const f = stack[stack.len - 1 - i];
        const ns_name = f.ns orelse "?";
        const fn_name = f.fn_name orelse "anonymous";
        // Build qualified name: ns/fn
        const qual_name = std.fmt.allocPrint(allocator, "{s}/{s}", .{ ns_name, fn_name }) catch return error.OutOfMemory;
        const file_str = f.file orelse "<unknown>";

        // [ns/fn file line]
        const vec_items = allocator.alloc(Value, 3) catch return error.OutOfMemory;
        vec_items[0] = Value.initSymbol(allocator, .{ .ns = null, .name = qual_name });
        vec_items[1] = Value.initString(allocator, file_str);
        vec_items[2] = Value.initInteger(@intCast(f.line));

        const vec = allocator.create(collections.PersistentVector) catch return error.OutOfMemory;
        vec.* = .{ .items = vec_items };
        trace_items[i] = Value.initVector(vec);
    }
    const trace_vec = allocator.create(collections.PersistentVector) catch return error.OutOfMemory;
    trace_vec.* = .{ .items = trace_items };

    // Build :via entry
    const via_entries = allocator.alloc(Value, if (ex_data_val.isNil()) 4 else 6) catch return error.OutOfMemory;
    via_entries[0] = Value.initKeyword(allocator, .{ .ns = null, .name = "type" });
    via_entries[1] = Value.initSymbol(allocator, .{ .ns = null, .name = ex_type });
    via_entries[2] = Value.initKeyword(allocator, .{ .ns = null, .name = "message" });
    via_entries[3] = if (cause_msg) |m| Value.initString(allocator, m) else Value.nil_val;
    if (!ex_data_val.isNil()) {
        via_entries[4] = Value.initKeyword(allocator, .{ .ns = null, .name = "data" });
        via_entries[5] = ex_data_val;
    }
    const via_map = allocator.create(value_mod.PersistentArrayMap) catch return error.OutOfMemory;
    via_map.* = .{ .entries = via_entries };
    const via_vec_items = allocator.alloc(Value, 1) catch return error.OutOfMemory;
    via_vec_items[0] = Value.initMap(via_map);
    const via_vec = allocator.create(collections.PersistentVector) catch return error.OutOfMemory;
    via_vec.* = .{ .items = via_vec_items };

    // Build result map: {:cause msg :via [...] :trace [...] :data data}
    var entry_count: usize = 6; // :cause, :via, :trace (3 pairs = 6)
    if (!ex_data_val.isNil()) entry_count += 2; // :data
    const result_entries = allocator.alloc(Value, entry_count) catch return error.OutOfMemory;
    result_entries[0] = Value.initKeyword(allocator, .{ .ns = null, .name = "cause" });
    result_entries[1] = if (cause_msg) |m| Value.initString(allocator, m) else Value.nil_val;
    result_entries[2] = Value.initKeyword(allocator, .{ .ns = null, .name = "via" });
    result_entries[3] = Value.initVector(via_vec);
    result_entries[4] = Value.initKeyword(allocator, .{ .ns = null, .name = "trace" });
    result_entries[5] = Value.initVector(trace_vec);
    if (!ex_data_val.isNil()) {
        result_entries[6] = Value.initKeyword(allocator, .{ .ns = null, .name = "data" });
        result_entries[7] = ex_data_val;
    }
    const result_map = allocator.create(value_mod.PersistentArrayMap) catch return error.OutOfMemory;
    result_map.* = .{ .entries = result_entries };

    return Value.initMap(result_map);
}

// ============================================================
// find-var
// ============================================================

/// (find-var sym)
/// Returns the Var mapped to the qualified symbol, or nil if not found.
pub fn findVarFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to find-var", .{args.len});
    const sym = switch (args[0].tag()) {
        .symbol => args[0].asSymbol(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "find-var expects a symbol, got {s}", .{@tagName(args[0].tag())}),
    };
    const env = bootstrap.macro_eval_env orelse return error.EvalError;
    const ns_name = sym.ns orelse {
        // Unqualified — look in current ns
        const current = env.current_ns orelse return Value.nil_val;
        if (current.resolve(sym.name)) |_| {
            return args[0]; // return the symbol (we don't expose Var as Value)
        }
        return Value.nil_val;
    };
    const ns = env.findNamespace(ns_name) orelse return Value.nil_val;
    if (ns.resolve(sym.name)) |_| {
        return args[0];
    }
    return Value.nil_val;
}

// ============================================================
// resolve
// ============================================================

/// (resolve sym) or (resolve env sym)
/// Returns the var or Class to which sym will be resolved in the current namespace, else nil.
pub fn resolveFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to resolve", .{args.len});
    const sym = switch (args[args.len - 1].tag()) {
        .symbol => args[args.len - 1].asSymbol(),
        else => return Value.nil_val,
    };
    const env = bootstrap.macro_eval_env orelse return error.EvalError;

    // 2-arity: (resolve ns sym) — first arg is ns
    const ns = if (args.len == 2) blk: {
        const ns_arg = switch (args[0].tag()) {
            .symbol => args[0].asSymbol().name,
            else => return Value.nil_val,
        };
        break :blk env.findNamespace(ns_arg) orelse return Value.nil_val;
    } else blk: {
        // 1-arity: use *ns* dynamic var (like JVM Clojure)
        const core = env.findNamespace("clojure.core") orelse break :blk env.current_ns orelse return Value.nil_val;
        const ns_var = core.resolve("*ns*") orelse break :blk env.current_ns orelse return Value.nil_val;
        const ns_val = ns_var.deref();
        const ns_name = switch (ns_val.tag()) {
            .symbol => ns_val.asSymbol().name,
            else => break :blk env.current_ns orelse return Value.nil_val,
        };
        break :blk env.findNamespace(ns_name) orelse env.current_ns orelse return Value.nil_val;
    };

    // Qualified symbol
    if (sym.ns) |ns_name| {
        // Check alias first
        if (ns.getAlias(ns_name)) |target_ns| {
            if (target_ns.resolve(sym.name)) |v| {
                return Value.initVarRef(v);
            }
        }
        // Try direct namespace
        if (env.findNamespace(ns_name)) |target_ns| {
            if (target_ns.resolve(sym.name)) |v| {
                return Value.initVarRef(v);
            }
        }
        return Value.nil_val;
    }

    // Unqualified — search ns
    if (ns.resolve(sym.name)) |v| {
        return Value.initVarRef(v);
    }
    return Value.nil_val;
}

// ============================================================
// intern
// ============================================================

/// (intern ns name) or (intern ns name val)
/// Finds or creates a var named by the symbol name in the namespace ns, setting root to val if supplied.
pub fn internFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to intern", .{args.len});
    const ns_name = switch (args[0].tag()) {
        .symbol => args[0].asSymbol().name,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "intern expects a symbol for namespace, got {s}", .{@tagName(args[0].tag())}),
    };
    const var_name = switch (args[1].tag()) {
        .symbol => args[1].asSymbol().name,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "intern expects a symbol for name, got {s}", .{@tagName(args[1].tag())}),
    };
    const env = bootstrap.macro_eval_env orelse return error.EvalError;
    const ns = env.findNamespace(ns_name) orelse {
        return err.setErrorFmt(.eval, .value_error, .{}, "No namespace: {s}", .{ns_name});
    };
    const v = try ns.intern(var_name);
    if (args.len == 3) {
        v.bindRoot(args[2]);
    }
    // Return the qualified symbol representing the var
    return Value.initSymbol(allocator, .{ .ns = ns_name, .name = var_name });
}

// ============================================================
// loaded-libs
// ============================================================

const ns_ops = @import("ns_ops.zig");

/// (loaded-libs)
/// Returns a sorted set of symbols naming loaded libs.
pub fn loadedLibsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to loaded-libs", .{args.len});
    // Build a set of loaded lib names
    const env = bootstrap.macro_eval_env orelse return error.EvalError;
    // Return all namespace names as a set
    var count: usize = 0;
    var iter = env.namespaces.iterator();
    while (iter.next()) |_| count += 1;

    const items = allocator.alloc(Value, count) catch return Value.nil_val;
    var i: usize = 0;
    iter = env.namespaces.iterator();
    while (iter.next()) |entry| {
        items[i] = Value.initSymbol(allocator, .{ .ns = null, .name = entry.key_ptr.* });
        i += 1;
    }
    const set = try allocator.create(value_mod.PersistentHashSet);
    set.* = .{ .items = items };
    return Value.initSet(set);
}

// ============================================================
// map-entry?
// ============================================================

/// (map-entry? x)
/// Returns true if x is a map entry (2-element vector from map seq).
pub fn mapEntryFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to map-entry?", .{args.len});
    // In our implementation, map entries are 2-element vectors
    return switch (args[0].tag()) {
        .vector => if (args[0].asVector().items.len == 2) Value.true_val else Value.false_val,
        else => Value.false_val,
    };
}

// ============================================================
// Hashing
// ============================================================

const predicates_mod = @import("predicates.zig");
const collections_mod = @import("collections.zig");

/// Murmur3 constants (matches JVM Clojure)
const M3_C1: i32 = @bitCast(@as(u32, 0xcc9e2d51));
const M3_C2: i32 = @bitCast(@as(u32, 0x1b873593));

fn mixK1(k: i32) i32 {
    var k1: u32 = @bitCast(k);
    k1 *%= @bitCast(M3_C1);
    k1 = std.math.rotl(u32, k1, 15);
    k1 *%= @bitCast(M3_C2);
    return @bitCast(k1);
}

fn mixH1(h: i32, k1: i32) i32 {
    var h1: u32 = @bitCast(h);
    h1 ^= @as(u32, @bitCast(k1));
    h1 = std.math.rotl(u32, h1, 13);
    h1 = h1 *% 5 +% @as(u32, 0xe6546b64);
    return @bitCast(h1);
}

fn fmix(h: i32, length: i32) i32 {
    var h1 = h;
    h1 ^= length;
    h1 ^= @as(i32, @intCast(@as(u32, @bitCast(h1)) >> 16));
    h1 = h1 *% @as(i32, @bitCast(@as(u32, 0x85ebca6b)));
    h1 ^= @as(i32, @intCast(@as(u32, @bitCast(h1)) >> 13));
    h1 = h1 *% @as(i32, @bitCast(@as(u32, 0xc2b2ae35)));
    h1 ^= @as(i32, @intCast(@as(u32, @bitCast(h1)) >> 16));
    return h1;
}

fn mixCollHash(hash_val: i32, count: i32) i32 {
    var h1: i32 = 0; // seed
    const k1 = mixK1(hash_val);
    h1 = mixH1(h1, k1);
    return fmix(h1, count);
}

/// (mix-collection-hash hash-basis count)
pub fn mixCollectionHashFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to mix-collection-hash", .{args.len});
    const hash_basis: i32 = switch (args[0].tag()) {
        .integer => @truncate(args[0].asInteger()),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "mix-collection-hash expects integer, got {s}", .{@tagName(args[0].tag())}),
    };
    const count: i32 = switch (args[1].tag()) {
        .integer => @truncate(args[1].asInteger()),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "mix-collection-hash expects integer count, got {s}", .{@tagName(args[1].tag())}),
    };
    return Value.initInteger(@as(i64, mixCollHash(hash_basis, count)));
}

/// (hash-ordered-coll coll)
pub fn hashOrderedCollFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to hash-ordered-coll", .{args.len});
    var n: i32 = 0;
    var hash: i32 = 1;
    // Walk the seq
    var s = try collections_mod.seqFn(allocator, &.{args[0]});
    while (!s.isNil()) {
        const first = try collections_mod.firstFn(allocator, &.{s});
        const h = predicates_mod.computeHash(first);
        hash = hash *% 31 +% @as(i32, @truncate(h));
        n += 1;
        s = try collections_mod.restFn(allocator, &.{s});
        // restFn returns empty list, not nil, so check for empty
        s = try collections_mod.seqFn(allocator, &.{s});
    }
    return Value.initInteger(@as(i64, mixCollHash(hash, n)));
}

/// (hash-unordered-coll coll)
pub fn hashUnorderedCollFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to hash-unordered-coll", .{args.len});
    var n: i32 = 0;
    var hash: i32 = 0;
    var s = try collections_mod.seqFn(allocator, &.{args[0]});
    while (!s.isNil()) {
        const first = try collections_mod.firstFn(allocator, &.{s});
        const h = predicates_mod.computeHash(first);
        hash +%= @as(i32, @truncate(h));
        n += 1;
        s = try collections_mod.restFn(allocator, &.{s});
        s = try collections_mod.seqFn(allocator, &.{s});
    }
    return Value.initInteger(@as(i64, mixCollHash(hash, n)));
}

/// (hash-combine x y) — à la boost::hash_combine
pub fn hashCombineFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to hash-combine", .{args.len});
    const x: i32 = switch (args[0].tag()) {
        .integer => @truncate(args[0].asInteger()),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "hash-combine expects integer, got {s}", .{@tagName(args[0].tag())}),
    };
    const y_hash: i32 = @truncate(predicates_mod.computeHash(args[1]));
    // a la boost: seed ^= hash + 0x9e3779b9 + (seed << 6) + (seed >> 2)
    var seed: i32 = x;
    seed ^= y_hash +% @as(i32, @bitCast(@as(u32, 0x9e3779b9))) +% (seed << 6) +% @as(i32, @intCast(@as(u32, @bitCast(seed)) >> 2));
    return Value.initInteger(@as(i64, seed));
}

// ============================================================
// random-uuid
// ============================================================

/// (random-uuid) — returns a random UUID v4 string.
pub fn randomUuidFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to random-uuid", .{args.len});

    // Generate 16 random bytes
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    // Set version 4: byte[6] = (byte[6] & 0x0f) | 0x40
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    // Set variant 10: byte[8] = (byte[8] & 0x3f) | 0x80
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    // Format as UUID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (36 chars)
    const hex = "0123456789abcdef";
    var buf: [36]u8 = undefined;
    var pos: usize = 0;
    for (bytes, 0..) |b, i| {
        buf[pos] = hex[b >> 4];
        pos += 1;
        buf[pos] = hex[b & 0x0f];
        pos += 1;
        // Dashes after bytes 3, 5, 7, 9
        if (i == 3 or i == 5 or i == 7 or i == 9) {
            buf[pos] = '-';
            pos += 1;
        }
    }

    const result = try allocator.dupe(u8, &buf);
    return Value.initString(allocator, result);
}

pub const builtins = [_]BuiltinDef{
    .{
        .name = "gensym",
        .func = gensymFn,
        .doc = "Returns a new symbol with a unique name. If a prefix string is supplied, the name is prefix# where # is some unique number. If no prefix is supplied, the prefix is 'G__'.",
        .arglists = "([] [prefix-string])",
        .added = "1.0",
    },
    .{
        .name = "compare-and-set!",
        .func = compareAndSetFn,
        .doc = "Atomically sets the value of atom to newval if and only if the current value of the atom is identical to oldval. Returns true if set happened, else false.",
        .arglists = "([atom oldval newval])",
        .added = "1.0",
    },
    .{
        .name = "format",
        .func = formatFn,
        .doc = "Formats a string using java.lang.String/format-style placeholders. Supports %s, %d, %f, %%.",
        .arglists = "([fmt & args])",
        .added = "1.0",
    },
    .{
        .name = "create-local-var",
        .func = createLocalVarFn,
        .doc = "Creates a fresh dynamic Var. Used by with-local-vars.",
        .arglists = "([])",
        .added = "1.0",
    },
    .{
        .name = "push-thread-bindings",
        .func = pushThreadBindingsFn,
        .doc = "Pushes a new frame of bindings for dynamic vars. bindings-map is a map of Var/value pairs.",
        .arglists = "([bindings-map])",
        .added = "1.0",
    },
    .{
        .name = "pop-thread-bindings",
        .func = popThreadBindingsFn,
        .doc = "Pops the frame of bindings most recently pushed with push-thread-bindings.",
        .arglists = "([])",
        .added = "1.0",
    },
    .{
        .name = "get-thread-bindings",
        .func = getThreadBindingsFn,
        .doc = "Get a map with the Var/value pairs which is currently in effect for the current thread.",
        .arglists = "([])",
        .added = "1.1",
    },
    .{
        .name = "thread-bound?",
        .func = threadBoundPredFn,
        .doc = "Returns true if all given vars have thread-local bindings.",
        .arglists = "([& vars])",
        .added = "1.0",
    },
    .{
        .name = "var-raw-root",
        .func = varRawRootFn,
        .doc = "Returns the root value of a Var, bypassing thread-local bindings.",
        .arglists = "([v])",
        .added = "1.0",
    },
    .{
        .name = "__var-bind-root",
        .func = varBindRootFn,
        .doc = "Sets the root binding of a Var directly. Internal use by with-redefs.",
        .arglists = "([v val])",
        .added = "1.0",
    },
    .{
        .name = "alter-var-root",
        .func = &alterVarRootFn,
        .doc = "Atomically alters the root binding of var by applying f to its current value plus any args.",
        .arglists = "([v f & args])",
        .added = "1.0",
    },
    .{
        .name = "ex-cause",
        .func = exCauseFn,
        .doc = "Returns the cause of an exception.",
        .arglists = "([ex])",
        .added = "1.0",
    },
    .{
        .name = "Throwable->map",
        .func = throwableToMapFn,
        .doc = "Constructs a data representation for an exception with keys: :cause, :via, :trace, :data.",
        .arglists = "([ex])",
        .added = "1.7",
    },
    .{
        .name = "find-var",
        .func = findVarFn,
        .doc = "Returns the global var named by the namespace-qualified symbol, or nil if no var with that name.",
        .arglists = "([sym])",
        .added = "1.0",
    },
    .{
        .name = "resolve",
        .func = resolveFn,
        .doc = "Returns the var or Class to which a symbol will be resolved in the namespace, else nil.",
        .arglists = "([sym] [env sym])",
        .added = "1.0",
    },
    .{
        .name = "intern",
        .func = internFn,
        .doc = "Finds or creates a var named by the symbol name in the namespace ns, optionally setting root binding.",
        .arglists = "([ns name] [ns name val])",
        .added = "1.0",
    },
    .{
        .name = "loaded-libs",
        .func = loadedLibsFn,
        .doc = "Returns a sorted set of symbols naming the currently loaded libs.",
        .arglists = "([])",
        .added = "1.0",
    },
    .{
        .name = "map-entry?",
        .func = mapEntryFn,
        .doc = "Return true if x is a map entry.",
        .arglists = "([x])",
        .added = "1.9",
    },
    .{
        .name = "mix-collection-hash",
        .func = mixCollectionHashFn,
        .doc = "Mix final collection hash for ordered or unordered collections. hash-basis is the combined collection hash, count is the number of elements included in the basis.",
        .arglists = "([hash-basis count])",
        .added = "1.6",
    },
    .{
        .name = "hash-ordered-coll",
        .func = hashOrderedCollFn,
        .doc = "Returns the hash code, consistent with =, for an external ordered collection implementing Iterable.",
        .arglists = "([coll])",
        .added = "1.6",
    },
    .{
        .name = "hash-unordered-coll",
        .func = hashUnorderedCollFn,
        .doc = "Returns the hash code, consistent with =, for an external unordered collection implementing Iterable.",
        .arglists = "([coll])",
        .added = "1.6",
    },
    .{
        .name = "hash-combine",
        .func = hashCombineFn,
        .doc = "Utility function for combining hash values.",
        .arglists = "([x y])",
        .added = "1.2",
    },
    .{
        .name = "random-uuid",
        .func = randomUuidFn,
        .doc = "Returns a pseudo-randomly generated java.util.UUID (as string in ClojureWasm).",
        .arglists = "([])",
        .added = "1.11",
    },
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "gensym - no prefix" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const r1 = try gensymFn(alloc, &[_]Value{});
    try testing.expect(r1.tag() == .symbol);
    // Should start with G__
    try testing.expect(std.mem.startsWith(u8, r1.asSymbol().name, "G__"));

    const r2 = try gensymFn(alloc, &[_]Value{});
    // Should be different from r1
    try testing.expect(!std.mem.eql(u8, r1.asSymbol().name, r2.asSymbol().name));
}

test "gensym - with prefix" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try gensymFn(alloc, &[_]Value{Value.initString(alloc, "foo")});
    try testing.expect(result.tag() == .symbol);
    try testing.expect(std.mem.startsWith(u8, result.asSymbol().name, "foo"));
}

test "compare-and-set! - successful swap" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var atom = value_mod.Atom{ .value = Value.initInteger(1) };
    const result = try compareAndSetFn(alloc, &[_]Value{
        Value.initAtom(&atom),
        Value.initInteger(1),
        Value.initInteger(2),
    });
    try testing.expectEqual(Value.true_val, result);
    try testing.expectEqual(Value.initInteger(2), atom.value);
}

test "compare-and-set! - failed swap" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var atom = value_mod.Atom{ .value = Value.initInteger(1) };
    const result = try compareAndSetFn(alloc, &[_]Value{
        Value.initAtom(&atom),
        Value.initInteger(99), // doesn't match current value
        Value.initInteger(2),
    });
    try testing.expectEqual(Value.false_val, result);
    try testing.expectEqual(Value.initInteger(1), atom.value); // unchanged
}

test "format - %s" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try formatFn(alloc, &[_]Value{
        Value.initString(alloc, "hello %s"),
        Value.initString(alloc, "world"),
    });
    try testing.expectEqualStrings("hello world", result.asString());
}

test "format - %d" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try formatFn(alloc, &[_]Value{
        Value.initString(alloc, "count: %d"),
        Value.initInteger(42),
    });
    try testing.expectEqualStrings("count: 42", result.asString());
}

test "format - %%" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try formatFn(alloc, &[_]Value{
        Value.initString(alloc, "100%%"),
    });
    try testing.expectEqualStrings("100%", result.asString());
}

test "format - mixed" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try formatFn(alloc, &[_]Value{
        Value.initString(alloc, "%s is %d"),
        Value.initString(alloc, "x"),
        Value.initInteger(10),
    });
    try testing.expectEqualStrings("x is 10", result.asString());
}

test "random-uuid - format" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try randomUuidFn(alloc, &[_]Value{});
    try testing.expect(result.tag() == .string);
    const uuid = result.asString();
    // UUID v4 format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx (36 chars)
    try testing.expectEqual(@as(usize, 36), uuid.len);
    try testing.expectEqual(@as(u8, '-'), uuid[8]);
    try testing.expectEqual(@as(u8, '-'), uuid[13]);
    try testing.expectEqual(@as(u8, '-'), uuid[18]);
    try testing.expectEqual(@as(u8, '-'), uuid[23]);
    // Version 4
    try testing.expectEqual(@as(u8, '4'), uuid[14]);
    // Variant: y must be 8, 9, a, or b
    try testing.expect(uuid[19] == '8' or uuid[19] == '9' or uuid[19] == 'a' or uuid[19] == 'b');
}

test "format - width specifier %5s" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try formatFn(alloc, &[_]Value{
        Value.initString(alloc, "%5s"),
        Value.initString(alloc, "hi"),
    });
    try testing.expectEqualStrings("   hi", result.asString());
}

test "format - left-align %-5s" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try formatFn(alloc, &[_]Value{
        Value.initString(alloc, "%-5s"),
        Value.initString(alloc, "hi"),
    });
    try testing.expectEqualStrings("hi   ", result.asString());
}

test "format - width %3d" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try formatFn(alloc, &[_]Value{
        Value.initString(alloc, "%3d"),
        Value.initInteger(1),
    });
    try testing.expectEqualStrings("  1", result.asString());
}

test "format - precision %.2f" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try formatFn(alloc, &[_]Value{
        Value.initString(alloc, "%.2f"),
        Value.initFloat(3.14159),
    });
    try testing.expectEqualStrings("3.14", result.asString());
}

test "random-uuid - uniqueness" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const r1 = try randomUuidFn(alloc, &[_]Value{});
    const r2 = try randomUuidFn(alloc, &[_]Value{});
    try testing.expect(!std.mem.eql(u8, r1.asString(), r2.asString()));
}
