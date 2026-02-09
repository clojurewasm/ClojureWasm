// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

// Namespace operations — all-ns, find-ns, ns-name, create-ns, the-ns.
//
// Namespaces are represented as symbols (their name) in the Value system.
// This avoids adding a new Value variant while providing functional API (D47).

const std = @import("std");
const Allocator = std.mem.Allocator;
const var_mod = @import("../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const Value = @import("../runtime/value.zig").Value;
const collections = @import("../runtime/collections.zig");
const bootstrap = @import("../runtime/bootstrap.zig");
const err = @import("../runtime/error.zig");

// ============================================================
// Load path infrastructure
// ============================================================

/// Load paths for file-based namespace loading (classpath equivalent).
/// Default: just "." (current working directory).
var load_paths: []const []const u8 = &default_load_paths;
const default_load_paths = [_][]const u8{"."};

/// Dynamic load path list (allocated when addLoadPath is used).
var dynamic_load_paths: std.ArrayList([]const u8) = .empty;

/// Loaded libs tracking (simple set, replaces *loaded-libs* Ref).
var loaded_libs: std.StringHashMapUnmanaged(void) = .empty;
var loaded_libs_allocator: ?Allocator = null;

/// Libs currently being loaded (for circular dependency detection).
var loading_libs: std.StringHashMapUnmanaged(void) = .empty;

/// Record of files loaded by require (for cljw build source bundling).
pub const LoadedFileRecord = struct {
    content: []const u8,
};
var loaded_file_records: std.ArrayList(LoadedFileRecord) = .empty;
var track_loaded_files: bool = false;

/// Enable file tracking for cljw build. Call before evaluating entry file.
pub fn enableFileTracking() void {
    track_loaded_files = true;
}

/// Get all files loaded since tracking was enabled.
pub fn getLoadedFiles() []const LoadedFileRecord {
    return loaded_file_records.items;
}

/// Initialize the load infrastructure. Call once at startup.
pub fn init(allocator: Allocator) void {
    loaded_libs_allocator = allocator;
    loaded_libs = .empty;
    dynamic_load_paths = .empty;
    loaded_file_records = .empty;
    track_loaded_files = false;
    // Start with default "." path
    dynamic_load_paths.append(allocator, ".") catch {};
    load_paths = dynamic_load_paths.items;
}

/// Release load infrastructure resources.
pub fn deinit() void {
    const alloc = loaded_libs_allocator orelse return;
    // Free loaded_libs keys
    var iter = loaded_libs.iterator();
    while (iter.next()) |entry| {
        alloc.free(entry.key_ptr.*);
    }
    loaded_libs.deinit(alloc);
    loaded_libs = .empty;

    // Free loading_libs keys
    var loading_iter = loading_libs.iterator();
    while (loading_iter.next()) |entry| {
        alloc.free(entry.key_ptr.*);
    }
    loading_libs.deinit(alloc);
    loading_libs = .empty;

    // Free loaded file records
    for (loaded_file_records.items) |rec| {
        alloc.free(rec.content);
    }
    loaded_file_records.deinit(alloc);
    loaded_file_records = .empty;
    track_loaded_files = false;

    // Free dynamic path strings (skip "." which is static)
    for (dynamic_load_paths.items) |p| {
        if (!std.mem.eql(u8, p, ".")) {
            alloc.free(p);
        }
    }
    dynamic_load_paths.deinit(alloc);
    dynamic_load_paths = .empty;
    load_paths = &default_load_paths;
    loaded_libs_allocator = null;
}

/// Add a path to the load path list.
pub fn addLoadPath(path: []const u8) !void {
    const alloc = loaded_libs_allocator orelse return;
    // Avoid duplicates
    for (dynamic_load_paths.items) |existing| {
        if (std.mem.eql(u8, existing, path)) return;
    }
    const owned = try alloc.dupe(u8, path);
    try dynamic_load_paths.append(alloc, owned);
    load_paths = dynamic_load_paths.items;
}

/// Detect and add src/ directory to load paths.
/// Two strategies:
/// 1. Walk up the path to find a component named "src" (file is inside src/)
/// 2. Walk up parent directories looking for a src/ subdirectory
pub fn detectAndAddSrcPath(start_dir: []const u8) !void {
    _ = loaded_libs_allocator orelse return;

    // Strategy 1: Check if start_dir itself is inside a src/ directory.
    // e.g., "src/app" → add "src", "/abs/project/src/app/lib" → add "/abs/project/src"
    {
        var current = start_dir;
        for (0..20) |_| {
            const basename = std.fs.path.basename(current);
            if (std.mem.eql(u8, basename, "src")) {
                try addLoadPath(current);
                return;
            }
            const parent = std.fs.path.dirname(current) orelse break;
            if (std.mem.eql(u8, parent, current)) break;
            current = parent;
        }
    }

    // Strategy 2: Look for a src/ subdirectory in parent directories.
    // e.g., start_dir = "app" and ./src/ exists → add "./src" or "app/../src"
    {
        var buf: [4096]u8 = undefined;
        var current = start_dir;
        for (0..10) |_| {
            const src_path = std.fmt.bufPrint(&buf, "{s}/src", .{current}) catch break;
            if (std.fs.cwd().openDir(src_path, .{})) |dir| {
                var d = dir;
                d.close();
                try addLoadPath(src_path);
                return;
            } else |_| {}

            const parent = std.fs.path.dirname(current) orelse break;
            if (std.mem.eql(u8, parent, current)) break;
            current = parent;
        }
    }
}

pub fn isLibLoaded(name: []const u8) bool {
    return loaded_libs.contains(name);
}

pub fn markLibLoaded(name: []const u8) !void {
    const alloc = loaded_libs_allocator orelse return;
    if (!loaded_libs.contains(name)) {
        const owned = try alloc.dupe(u8, name);
        try loaded_libs.put(alloc, owned, {});
    }
}

// ============================================================
// Path resolution
// ============================================================

/// Convert namespace name to resource path: clojure.string → /clojure/string
/// Replaces '-' with '_' and '.' with '/'.
fn rootResource(buf: []u8, ns_name: []const u8) ?[]const u8 {
    if (ns_name.len + 1 > buf.len) return null;
    buf[0] = '/';
    var i: usize = 1;
    for (ns_name) |c| {
        if (i >= buf.len) return null;
        buf[i] = switch (c) {
            '.' => '/',
            '-' => '_',
            else => c,
        };
        i += 1;
    }
    return buf[0..i];
}

/// Load a namespace by name: convert to path, search load paths, eval.
/// Returns true if file was found and loaded, false otherwise.
fn loadLib(allocator: Allocator, env: *@import("../runtime/env.zig").Env, ns_name: []const u8) !bool {
    var path_buf: [4096]u8 = undefined;
    const resource_path = rootResource(&path_buf, ns_name) orelse return false;

    // Strip leading slash for loadResource
    const resource = if (resource_path.len > 0 and resource_path[0] == '/')
        resource_path[1..]
    else
        resource_path;

    return loadResource(allocator, env, resource);
}

/// Load a resource file by searching load paths. Saves/restores *ns*.
fn loadResource(allocator: Allocator, env: *@import("../runtime/env.zig").Env, resource: []const u8) !bool {
    const saved_ns = env.current_ns;

    for (load_paths) |base| {
        var buf: [4096]u8 = undefined;
        const full_path = std.fmt.bufPrint(&buf, "{s}/{s}.clj", .{ base, resource }) catch continue;

        const cwd = std.fs.cwd();
        if (cwd.openFile(full_path, .{})) |file| {
            defer file.close();
            const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch continue;

            // Dupe content for build tracking before evaluation (content
            // allocated by GC allocator may not survive evaluation).
            var tracked_content: ?[]const u8 = null;
            if (track_loaded_files) {
                if (loaded_libs_allocator) |tracking_alloc| {
                    tracked_content = tracking_alloc.dupe(u8, content) catch null;
                }
            }

            _ = bootstrap.evalString(allocator, env, content) catch {
                env.current_ns = saved_ns;
                bootstrap.syncNsVar(env);
                if (tracked_content) |tc| {
                    if (loaded_libs_allocator) |ta| ta.free(tc);
                }
                err.ensureInfoSet(.eval, .internal_error, .{}, "error loading resource: {s}", .{resource});
                return error.EvalError;
            };

            // Record AFTER evaluation so nested deps are recorded first
            // (depth-first order: lib.util.math before lib.core).
            if (tracked_content) |tc| {
                if (loaded_libs_allocator) |tracking_alloc| {
                    loaded_file_records.append(tracking_alloc, .{ .content = tc }) catch {};
                }
            }

            env.current_ns = saved_ns;
            bootstrap.syncNsVar(env);
            return true;
        } else |_| {
            continue;
        }
    }

    env.current_ns = saved_ns;
    bootstrap.syncNsVar(env);
    return false;
}

// ============================================================
// load
// ============================================================

/// (load & paths)
/// Loads Clojure code from resources relative to load paths.
/// Path is classpath-relative (e.g. "/clojure/string" → searches for clojure/string.clj).
/// Saves and restores *ns*.
pub fn loadFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args (0) passed to load", .{});

    const env = bootstrap.macro_eval_env orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "eval environment not initialized", .{});
        return error.EvalError;
    };

    for (args) |arg| {
        const path_str = switch (arg.tag()) {
            .string => arg.asString(),
            else => return err.setErrorFmt(.eval, .type_error, .{}, "load expects string paths, got {s}", .{@tagName(arg.tag())}),
        };

        // Strip leading slash if present
        const resource = if (path_str.len > 0 and path_str[0] == '/')
            path_str[1..]
        else
            path_str;

        const loaded = loadResource(allocator, env, resource) catch {
            err.ensureInfoSet(.eval, .io_error, .{}, "error loading resource: {s}", .{resource});
            return error.EvalError;
        };
        if (!loaded) {
            return err.setErrorFmt(.eval, .io_error, .{}, "Could not locate {s}.clj on load path", .{resource});
        }
    }

    return Value.nil_val;
}

// ============================================================
// the-ns
// ============================================================

/// (the-ns x)
/// If x is a symbol, finds namespace by name and returns the symbol.
/// Throws if namespace not found.
pub fn theNsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to the-ns", .{args.len});
    const name = switch (args[0].tag()) {
        .symbol => args[0].asSymbol().name,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "the-ns expects a symbol, got {s}", .{@tagName(args[0].tag())}),
    };
    const env = bootstrap.macro_eval_env orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "eval environment not initialized", .{});
        return error.EvalError;
    };
    if (env.findNamespace(name) == null) return error.NamespaceNotFound;
    return Value.initSymbol(allocator, .{ .ns = null, .name = name });
}

// ============================================================
// all-ns
// ============================================================

/// (all-ns)
/// Returns a list of all namespace names as symbols.
pub fn allNsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to all-ns", .{args.len});
    const env = bootstrap.macro_eval_env orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "eval environment not initialized", .{});
        return error.EvalError;
    };

    var ns_iter = env.namespaces.iterator();
    var count: usize = 0;
    while (ns_iter.next()) |_| {
        count += 1;
    }

    const items = try allocator.alloc(Value, count);
    ns_iter = env.namespaces.iterator();
    var i: usize = 0;
    while (ns_iter.next()) |entry| {
        items[i] = Value.initSymbol(allocator, .{ .ns = null, .name = entry.key_ptr.* });
        i += 1;
    }

    const lst = try allocator.create(collections.PersistentList);
    lst.* = .{ .items = items };
    return Value.initList(lst);
}

// ============================================================
// find-ns
// ============================================================

/// (find-ns sym)
/// Returns the namespace named by symbol, or nil if not found.
pub fn findNsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to find-ns", .{args.len});
    const name = switch (args[0].tag()) {
        .symbol => args[0].asSymbol().name,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "find-ns expects a symbol, got {s}", .{@tagName(args[0].tag())}),
    };
    const env = bootstrap.macro_eval_env orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "eval environment not initialized", .{});
        return error.EvalError;
    };
    if (env.findNamespace(name)) |ns| {
        return Value.initSymbol(allocator, .{ .ns = null, .name = ns.name });
    }
    return Value.nil_val;
}

// ============================================================
// ns-name
// ============================================================

/// (ns-name ns)
/// Returns the name of the namespace as a symbol.
pub fn nsNameFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to ns-name", .{args.len});
    return switch (args[0].tag()) {
        .symbol => Value.initSymbol(allocator, .{ .ns = null, .name = args[0].asSymbol().name }),
        else => err.setErrorFmt(.eval, .type_error, .{}, "ns-name expects a symbol, got {s}", .{@tagName(args[0].tag())}),
    };
}

// ============================================================
// create-ns
// ============================================================

/// (create-ns sym)
/// Finds or creates a namespace named by symbol. Returns the namespace symbol.
pub fn createNsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to create-ns", .{args.len});
    const name = switch (args[0].tag()) {
        .symbol => args[0].asSymbol().name,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "create-ns expects a symbol, got {s}", .{@tagName(args[0].tag())}),
    };
    const env = bootstrap.macro_eval_env orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "eval environment not initialized", .{});
        return error.EvalError;
    };
    const ns = try env.findOrCreateNamespace(name);
    return Value.initSymbol(allocator, .{ .ns = null, .name = ns.name });
}

// ============================================================
// set-ns-doc (internal — called by ns macro)
// ============================================================

/// (set-ns-doc ns-sym docstring)
/// Sets the docstring on the named namespace.
fn setNsDocFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to set-ns-doc", .{args.len});
    const name = switch (args[0].tag()) {
        .symbol => args[0].asSymbol().name,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "set-ns-doc expects a symbol, got {s}", .{@tagName(args[0].tag())}),
    };
    const doc = switch (args[1].tag()) {
        .string => args[1].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "set-ns-doc expects a string, got {s}", .{@tagName(args[1].tag())}),
    };
    const env_ptr = bootstrap.macro_eval_env orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "eval environment not initialized", .{});
        return error.EvalError;
    };
    if (env_ptr.findNamespace(name)) |ns| {
        ns.doc = doc;
    }
    return Value.nil_val;
}

// ============================================================
// in-ns
// ============================================================

/// (in-ns name)
/// Switches to the namespace named by symbol (creating it if needed).
/// Also refers all clojure.core vars into the new namespace.
pub fn inNsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to in-ns", .{args.len});
    const name = switch (args[0].tag()) {
        .symbol => args[0].asSymbol().name,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "in-ns expects a symbol, got {s}", .{@tagName(args[0].tag())}),
    };
    const env = bootstrap.macro_eval_env orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "eval environment not initialized", .{});
        return error.EvalError;
    };
    const ns = try env.findOrCreateNamespace(name);

    // Refer clojure.core bindings into the new namespace
    if (env.findNamespace("clojure.core")) |core_ns| {
        var iter = core_ns.mappings.iterator();
        while (iter.next()) |entry| {
            ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
    }

    // Copy refers from current namespace to new namespace.
    // This ensures functions from loaded libraries (clojure.walk, clojure.set, etc.)
    // remain accessible after namespace switch.
    if (env.current_ns) |current| {
        var ref_iter = current.refers.iterator();
        while (ref_iter.next()) |entry| {
            ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
    }

    // Switch current namespace
    env.current_ns = ns;

    // Sync *ns* dynamic var
    if (env.findNamespace("clojure.core")) |core| {
        if (core.resolve("*ns*")) |ns_var| {
            ns_var.bindRoot(Value.initSymbol(allocator, .{ .ns = null, .name = ns.name }));
        }
    }

    return Value.initSymbol(allocator, .{ .ns = null, .name = ns.name });
}

// ============================================================
// Helpers
// ============================================================

const Namespace = @import("../runtime/namespace.zig").Namespace;
const Var = var_mod.Var;

/// Resolve a symbol arg to a Namespace via Env.
fn resolveNs(args: []const Value) !*Namespace {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to ns-resolve", .{args.len});
    const name = switch (args[0].tag()) {
        .symbol => args[0].asSymbol().name,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "ns-resolve expects a symbol, got {s}", .{@tagName(args[0].tag())}),
    };
    const env = bootstrap.macro_eval_env orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "eval environment not initialized", .{});
        return error.EvalError;
    };
    return env.findNamespace(name) orelse return error.NamespaceNotFound;
}

/// Build a {symbol -> var_ref} map from a VarMap (symbol name -> *Var).
fn varMapToValue(allocator: Allocator, map: anytype) !Value {
    var count: usize = 0;
    {
        var iter = map.iterator();
        while (iter.next()) |_| count += 1;
    }

    // Map entries are key/value pairs flattened: [k1, v1, k2, v2, ...]
    const entries = try allocator.alloc(Value, count * 2);
    var iter = map.iterator();
    var i: usize = 0;
    while (iter.next()) |entry| {
        entries[i] = Value.initSymbol(allocator, .{ .ns = null, .name = entry.key_ptr.* });
        entries[i + 1] = Value.initVarRef(entry.value_ptr.*);
        i += 2;
    }

    const m = try allocator.create(collections.PersistentArrayMap);
    m.* = .{ .entries = entries };
    return Value.initMap(m);
}

// ============================================================
// ns-interns
// ============================================================

/// (ns-interns ns)
/// Returns a map of the intern mappings for the namespace.
pub fn nsInternsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    const ns = try resolveNs(args);
    return varMapToValue(allocator, ns.mappings);
}

// ============================================================
// ns-publics
// ============================================================

/// (ns-publics ns)
/// Returns a map of the public intern mappings for the namespace.
/// (Currently all interned vars are public — no private vars yet.)
pub fn nsPublicsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    const ns = try resolveNs(args);
    return varMapToValue(allocator, ns.mappings);
}

// ============================================================
// ns-map
// ============================================================

/// (ns-map ns)
/// Returns a map of all the mappings for the namespace (interned + referred).
pub fn nsMapFn(allocator: Allocator, args: []const Value) anyerror!Value {
    const ns = try resolveNs(args);

    // Count total entries from both maps
    var count: usize = 0;
    {
        var iter = ns.mappings.iterator();
        while (iter.next()) |_| count += 1;
    }
    {
        var iter = ns.refers.iterator();
        while (iter.next()) |_| count += 1;
    }

    const entries = try allocator.alloc(Value, count * 2);
    var i: usize = 0;

    // Interned vars first
    {
        var iter = ns.mappings.iterator();
        while (iter.next()) |entry| {
            entries[i] = Value.initSymbol(allocator, .{ .ns = null, .name = entry.key_ptr.* });
            entries[i + 1] = Value.initVarRef(entry.value_ptr.*);
            i += 2;
        }
    }

    // Referred vars
    {
        var iter = ns.refers.iterator();
        while (iter.next()) |entry| {
            entries[i] = Value.initSymbol(allocator, .{ .ns = null, .name = entry.key_ptr.* });
            entries[i + 1] = Value.initVarRef(entry.value_ptr.*);
            i += 2;
        }
    }

    const m = try allocator.create(collections.PersistentArrayMap);
    m.* = .{ .entries = entries };
    return Value.initMap(m);
}

// ============================================================
// ns-resolve
// ============================================================

/// (ns-resolve ns sym)
/// (ns-resolve ns env sym) — env is a map of local bindings (ignored for resolution).
/// Returns the var to which a symbol will be resolved in the namespace, else nil.
pub fn nsResolveFn(allocator: Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 2 or args.len > 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to ns-resolve", .{args.len});

    // First arg: namespace (symbol or namespace)
    const ns_name = switch (args[0].tag()) {
        .symbol => args[0].asSymbol().name,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "ns-resolve expects a symbol as first argument, got {s}", .{@tagName(args[0].tag())}),
    };
    const env = bootstrap.macro_eval_env orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "eval environment not initialized", .{});
        return error.EvalError;
    };
    const ns = env.findNamespace(ns_name) orelse return Value.nil_val;

    // Last arg is always the symbol to resolve
    const sym_arg = args[args.len - 1];
    const sym_name = switch (sym_arg.tag()) {
        .symbol => sym_arg.asSymbol().name,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "ns-resolve expects a symbol, got {s}", .{@tagName(sym_arg.tag())}),
    };

    // If 3-arg form, second arg is local env map — if symbol is in that map, return nil
    if (args.len == 3) {
        if (args[1].tag() == .map) {
            // Check if sym is a key in the local env map
            const map_entries = args[1].asMap().entries;
            var i: usize = 0;
            while (i + 1 < map_entries.len) : (i += 2) {
                if (map_entries[i].tag() == .symbol) {
                    if (std.mem.eql(u8, map_entries[i].asSymbol().name, sym_name)) {
                        return Value.nil_val; // Symbol is locally bound, not resolved
                    }
                }
            }
        }
    }

    // Try to resolve in the namespace: mappings first, then refers
    if (ns.resolve(sym_name)) |v| {
        return Value.initVarRef(v);
    }
    if (ns.refers.get(sym_name)) |v| {
        return Value.initVarRef(v);
    }

    return Value.nil_val;
}

// ============================================================
// ns-aliases
// ============================================================

/// (ns-aliases ns)
/// Returns a map of the aliases for the namespace.
pub fn nsAliasesFn(allocator: Allocator, args: []const Value) anyerror!Value {
    const ns = try resolveNs(args);
    var count: usize = 0;
    {
        var iter = ns.aliases.iterator();
        while (iter.next()) |_| count += 1;
    }
    if (count == 0) {
        const m = try allocator.create(collections.PersistentArrayMap);
        m.* = .{ .entries = &.{} };
        return Value.initMap(m);
    }
    const entries = try allocator.alloc(Value, count * 2);
    var iter = ns.aliases.iterator();
    var i: usize = 0;
    while (iter.next()) |entry| {
        entries[i] = Value.initSymbol(allocator, .{ .ns = null, .name = entry.key_ptr.* });
        // Represent the aliased namespace as a symbol of its name
        entries[i + 1] = Value.initSymbol(allocator, .{ .ns = null, .name = entry.value_ptr.*.name });
        i += 2;
    }
    const m = try allocator.create(collections.PersistentArrayMap);
    m.* = .{ .entries = entries };
    return Value.initMap(m);
}

// ============================================================
// ns-refers
// ============================================================

/// (ns-refers ns)
/// Returns a map of the refer mappings for the namespace.
pub fn nsRefersFn(allocator: Allocator, args: []const Value) anyerror!Value {
    const ns = try resolveNs(args);
    return varMapToValue(allocator, ns.refers);
}

// ============================================================
// refer
// ============================================================

/// (refer ns-sym)
/// Refers all public vars from the specified namespace into the current namespace.
/// (refer ns-sym :only [sym1 sym2]) — refer only specified vars.
pub fn referFn(allocator: Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to refer", .{args.len});
    const ns_name = switch (args[0].tag()) {
        .symbol => args[0].asSymbol().name,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "refer expects a symbol, got {s}", .{@tagName(args[0].tag())}),
    };
    const env = bootstrap.macro_eval_env orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "eval environment not initialized", .{});
        return error.EvalError;
    };
    const source_ns = env.findNamespace(ns_name) orelse return error.NamespaceNotFound;
    const current_ns = env.current_ns orelse {
            err.setInfoFmt(.eval, .internal_error, .{}, "no current namespace set", .{});
            return error.EvalError;
        };

    // Check for :only and :exclude filters
    var only_list: ?[]const Value = null;
    var exclude_list: ?[]const Value = null;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        if (args[i].tag() == .keyword) {
            if (std.mem.eql(u8, args[i].asKeyword().name, "only")) {
                if (args[i + 1].tag() == .vector) {
                    only_list = args[i + 1].asVector().items;
                } else if (args[i + 1].tag() == .list) {
                    only_list = args[i + 1].asList().items;
                }
            } else if (std.mem.eql(u8, args[i].asKeyword().name, "exclude")) {
                if (args[i + 1].tag() == .vector) {
                    exclude_list = args[i + 1].asVector().items;
                } else if (args[i + 1].tag() == .list) {
                    exclude_list = args[i + 1].asList().items;
                }
            }
        }
    }

    // When :only or :exclude is specified, first remove all existing refers
    // from the source namespace (in-ns auto-refers core, so we must undo it).
    if (only_list != null or exclude_list != null) {
        var rm_iter = source_ns.mappings.iterator();
        while (rm_iter.next()) |entry| {
            _ = current_ns.refers.remove(entry.key_ptr.*);
        }
    }

    if (only_list) |syms| {
        // Refer only specified symbols — validate existence and accessibility
        for (syms) |sym| {
            if (sym.tag() == .symbol) {
                if (source_ns.resolve(sym.asSymbol().name)) |v| {
                    if (v.isPrivate()) {
                        return err.setErrorFmt(.eval, .name_error, .{}, "{s} is not public", .{sym.asSymbol().name});
                    }
                    current_ns.refer(sym.asSymbol().name, v) catch {};
                } else {
                    return err.setErrorFmt(.eval, .name_error, .{}, "{s} does not exist", .{sym.asSymbol().name});
                }
            }
        }
    } else if (exclude_list) |excludes| {
        // Refer all public vars, minus excluded
        var iter = source_ns.mappings.iterator();
        while (iter.next()) |entry| {
            var excluded = false;
            for (excludes) |ex| {
                if (ex.tag() == .symbol and std.mem.eql(u8, ex.asSymbol().name, entry.key_ptr.*)) {
                    excluded = true;
                    break;
                }
            }
            if (!excluded) {
                current_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
            }
        }
    } else {
        // Refer all public vars
        var iter = source_ns.mappings.iterator();
        while (iter.next()) |entry| {
            current_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
    }

    return Value.nil_val;
}

// ============================================================
// alias
// ============================================================

/// (alias alias-sym ns-sym)
/// Adds an alias in the current namespace to another namespace.
pub fn aliasFn(allocator: Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to alias", .{args.len});
    const alias_name = switch (args[0].tag()) {
        .symbol => args[0].asSymbol().name,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "alias expects a symbol as first argument, got {s}", .{@tagName(args[0].tag())}),
    };
    const ns_name = switch (args[1].tag()) {
        .symbol => args[1].asSymbol().name,
        else => return err.setErrorFmt(.eval, .type_error, .{}, "alias expects a symbol as second argument, got {s}", .{@tagName(args[1].tag())}),
    };
    const env = bootstrap.macro_eval_env orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "eval environment not initialized", .{});
        return error.EvalError;
    };
    const target_ns = env.findNamespace(ns_name) orelse
        return err.setErrorFmt(.eval, .name_error, .{}, "No namespace: {s} found", .{ns_name});
    const current_ns = env.current_ns orelse {
            err.setInfoFmt(.eval, .internal_error, .{}, "no current namespace set", .{});
            return error.EvalError;
        };
    try current_ns.setAlias(alias_name, target_ns);
    return Value.nil_val;
}

// ============================================================
// require
// ============================================================

/// (require 'ns-sym)
/// (require '[ns-sym :as alias :refer [sym1 sym2]])
/// (require '[ns-sym :refer :all])
/// (require 'ns :reload)
/// Loads namespace from file if not already loaded. Supports :reload/:reload-all.
pub fn requireFn(allocator: Allocator, args: []const Value) anyerror!Value {
    const env = bootstrap.macro_eval_env orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "eval environment not initialized", .{});
        return error.EvalError;
    };

    if (args.len == 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args (0) passed to require", .{});

    // Scan for top-level :reload / :reload-all flags
    var reload = false;
    var has_lib_spec = false;
    for (args) |arg| {
        if (arg.tag() == .keyword) {
            if (std.mem.eql(u8, arg.asKeyword().name, "reload")) {
                reload = true;
            } else if (std.mem.eql(u8, arg.asKeyword().name, "reload-all")) {
                reload = true;
            } else {
                return err.setErrorFmt(.eval, .type_error, .{}, "require expects a symbol or vector, got keyword", .{});
            }
        } else {
            has_lib_spec = true;
        }
    }

    // If only flags and no lib specs, that's an error (e.g. (require :foo))
    if (!has_lib_spec) return err.setErrorFmt(.eval, .type_error, .{}, "require expects a symbol or vector, got keyword", .{});

    for (args) |arg| {
        switch (arg.tag()) {
            .keyword => continue, // Skip :reload/:reload-all flags
            .symbol => {
                try requireLib(allocator, env, arg.asSymbol().name, reload);
            },
            .vector => {
                const v = arg.asVector();
                if (v.items.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to require", .{args.len});
                const ns_name = switch (v.items[0].tag()) {
                    .symbol => v.items[0].asSymbol().name,
                    else => return err.setErrorFmt(.eval, .type_error, .{}, "require expects a symbol, got {s}", .{@tagName(v.items[0].tag())}),
                };
                try requireLib(allocator, env, ns_name, reload);
                const source_ns = env.findNamespace(ns_name) orelse
                    return err.setErrorFmt(.eval, .io_error, .{}, "Could not locate {s} on load path", .{ns_name});
                const current_ns = env.current_ns orelse {
            err.setInfoFmt(.eval, .internal_error, .{}, "no current namespace set", .{});
            return error.EvalError;
        };

                var j: usize = 1;
                while (j + 1 < v.items.len) : (j += 2) {
                    if (v.items[j].tag() == .keyword) {
                        const kw = v.items[j].asKeyword().name;
                        if (std.mem.eql(u8, kw, "as")) {
                            if (v.items[j + 1].tag() == .symbol) {
                                try current_ns.setAlias(v.items[j + 1].asSymbol().name, source_ns);
                            }
                        } else if (std.mem.eql(u8, kw, "refer")) {
                            if (v.items[j + 1].tag() == .vector) {
                                for (v.items[j + 1].asVector().items) |sym| {
                                    if (sym.tag() == .symbol) {
                                        if (source_ns.resolve(sym.asSymbol().name)) |var_ref| {
                                            current_ns.refer(sym.asSymbol().name, var_ref) catch {};
                                        }
                                    }
                                }
                            } else if (v.items[j + 1].tag() == .keyword) {
                                if (std.mem.eql(u8, v.items[j + 1].asKeyword().name, "all")) {
                                    var iter = source_ns.mappings.iterator();
                                    while (iter.next()) |entry| {
                                        current_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
                                    }
                                }
                            }
                        }
                    }
                }
            },
            else => return err.setErrorFmt(.eval, .type_error, .{}, "require expects a symbol or vector, got {s}", .{@tagName(arg.tag())}),
        }
    }

    return Value.nil_val;
}

/// Core require logic: ensure namespace is loaded (from file if needed).
fn requireLib(allocator: Allocator, env: *@import("../runtime/env.zig").Env, ns_name: []const u8, reload: bool) !void {
    // Skip if already loaded and no reload flag
    if (!reload and env.findNamespace(ns_name) != null and isLibLoaded(ns_name)) return;

    // If namespace exists but not marked loaded (bootstrap namespace), just mark it
    if (!reload and env.findNamespace(ns_name) != null) {
        try markLibLoaded(ns_name);
        return;
    }

    // Circular dependency detection: if this lib is currently being loaded
    // (i.e., we're in a nested require from within its own source file),
    // skip loading. The namespace was already created by (ns ...) at the
    // top of the file. This matches JVM Clojure behavior where circular
    // requires see partially-loaded namespaces.
    if (loading_libs.contains(ns_name)) {
        return;
    }

    // Mark as currently loading (for circular dependency detection)
    const alloc = loaded_libs_allocator orelse return;
    const loading_key = try alloc.dupe(u8, ns_name);
    try loading_libs.put(alloc, loading_key, {});
    defer {
        // Remove from loading set when done (whether success or error)
        if (loading_libs.fetchRemove(ns_name)) |kv| {
            alloc.free(kv.key);
        }
    }

    // Try to load from file
    const loaded = try loadLib(allocator, env, ns_name);
    if (loaded) {
        if (env.findNamespace(ns_name) == null) {
            return err.setErrorFmt(.eval, .io_error, .{}, "Namespace {s} not found after loading file", .{ns_name});
        }
        try markLibLoaded(ns_name);
        return;
    }

    // File not found — check if namespace already exists (e.g. bootstrap)
    if (env.findNamespace(ns_name) != null) {
        try markLibLoaded(ns_name);
        return;
    }

    return err.setErrorFmt(.eval, .io_error, .{}, "Could not locate {s} on load path", .{ns_name});
}

// ============================================================
// use
// ============================================================

/// (use 'ns-sym)
/// (use '[ns-sym :only [sym1 sym2]])
/// Equivalent to require + refer :all (or :only).
/// Loads namespace from file if not already loaded.
pub fn useFn(allocator: Allocator, args: []const Value) anyerror!Value {
    const env = bootstrap.macro_eval_env orelse {
        err.setInfoFmt(.eval, .internal_error, .{}, "eval environment not initialized", .{});
        return error.EvalError;
    };
    const current_ns = env.current_ns orelse {
            err.setInfoFmt(.eval, .internal_error, .{}, "no current namespace set", .{});
            return error.EvalError;
        };

    if (args.len == 0) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args (0) passed to use", .{});

    for (args) |arg| {
        switch (arg.tag()) {
            .symbol => {
                const s = arg.asSymbol();
                // (use 'ns) — load if needed, then refer all
                try requireLib(allocator, env, s.name, false);
                const source_ns = env.findNamespace(s.name) orelse
                    return err.setErrorFmt(.eval, .io_error, .{}, "Could not locate {s} on load path", .{s.name});
                var iter = source_ns.mappings.iterator();
                while (iter.next()) |entry| {
                    current_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
                }
            },
            .vector => {
                const v = arg.asVector();
                if (v.items.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to use", .{args.len});
                const ns_name = switch (v.items[0].tag()) {
                    .symbol => v.items[0].asSymbol().name,
                    else => return err.setErrorFmt(.eval, .type_error, .{}, "use expects a symbol, got {s}", .{@tagName(v.items[0].tag())}),
                };
                try requireLib(allocator, env, ns_name, false);
                const source_ns = env.findNamespace(ns_name) orelse
                    return err.setErrorFmt(.eval, .io_error, .{}, "Could not locate {s} on load path", .{ns_name});

                var only_filter: ?[]const Value = null;
                var j: usize = 1;
                while (j + 1 < v.items.len) : (j += 2) {
                    if (v.items[j].tag() == .keyword) {
                        if (std.mem.eql(u8, v.items[j].asKeyword().name, "only")) {
                            if (v.items[j + 1].tag() == .vector) {
                                only_filter = v.items[j + 1].asVector().items;
                            }
                        }
                    }
                }

                if (only_filter) |syms| {
                    for (syms) |sym| {
                        if (sym.tag() == .symbol) {
                            if (source_ns.resolve(sym.asSymbol().name)) |var_ref| {
                                current_ns.refer(sym.asSymbol().name, var_ref) catch {};
                            }
                        }
                    }
                } else {
                    var iter = source_ns.mappings.iterator();
                    while (iter.next()) |entry| {
                        current_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
                    }
                }
            },
            else => return err.setErrorFmt(.eval, .type_error, .{}, "use expects a symbol or vector, got {s}", .{@tagName(arg.tag())}),
        }
    }

    return Value.nil_val;
}

// ============================================================
// BuiltinDef table
// ============================================================

pub const builtins = [_]BuiltinDef{
    .{
        .name = "the-ns",
        .func = theNsFn,
        .doc = "If passed a namespace, returns it. Else, when passed a symbol, returns the namespace named by it, throwing an exception if not found.",
        .arglists = "([x])",
        .added = "1.0",
    },
    .{
        .name = "all-ns",
        .func = allNsFn,
        .doc = "Returns a sequence of all namespaces.",
        .arglists = "([])",
        .added = "1.0",
    },
    .{
        .name = "find-ns",
        .func = findNsFn,
        .doc = "Returns the namespace named by the symbol or nil if it doesn't exist.",
        .arglists = "([sym])",
        .added = "1.0",
    },
    .{
        .name = "ns-name",
        .func = nsNameFn,
        .doc = "Returns the name of the namespace, a symbol.",
        .arglists = "([ns])",
        .added = "1.0",
    },
    .{
        .name = "create-ns",
        .func = createNsFn,
        .doc = "Create a new namespace named by the symbol if one doesn't already exist, returns it or the already-existing namespace of the same name.",
        .arglists = "([sym])",
        .added = "1.0",
    },
    .{
        .name = "in-ns",
        .func = inNsFn,
        .doc = "Sets *ns* to the namespace named by the symbol, creating it if needed.",
        .arglists = "([name])",
        .added = "1.0",
    },
    .{
        .name = "ns-interns",
        .func = nsInternsFn,
        .doc = "Returns a map of the intern mappings for the namespace.",
        .arglists = "([ns])",
        .added = "1.0",
    },
    .{
        .name = "ns-publics",
        .func = nsPublicsFn,
        .doc = "Returns a map of the public intern mappings for the namespace.",
        .arglists = "([ns])",
        .added = "1.0",
    },
    .{
        .name = "ns-map",
        .func = nsMapFn,
        .doc = "Returns a map of all the mappings for the namespace.",
        .arglists = "([ns])",
        .added = "1.0",
    },
    .{
        .name = "refer",
        .func = referFn,
        .doc = "Refers to all public vars of ns, subject to filters.",
        .arglists = "([ns-sym & filters])",
        .added = "1.0",
    },
    .{
        .name = "alias",
        .func = aliasFn,
        .doc = "Add an alias in the current namespace to another namespace.",
        .arglists = "([alias namespace-sym])",
        .added = "1.0",
    },
    .{
        .name = "require",
        .func = requireFn,
        .doc = "Loads libs, skipping any that are already loaded. For already-loaded namespaces, sets up aliases and refers.",
        .arglists = "([& args])",
        .added = "1.0",
    },
    .{
        .name = "use",
        .func = useFn,
        .doc = "Like require, but also refers to each lib's namespace.",
        .arglists = "([& args])",
        .added = "1.0",
    },
    .{
        .name = "load",
        .func = loadFn,
        .doc = "Loads Clojure code from resources in classpath. A path is interpreted as classpath-relative if it begins with a slash.",
        .arglists = "([& paths])",
        .added = "1.0",
    },
    .{
        .name = "ns-resolve",
        .func = nsResolveFn,
        .doc = "Returns the var or Class to which a symbol will be resolved in the namespace (unless found in the environment), else nil.",
        .arglists = "([ns sym] [ns env sym])",
        .added = "1.0",
    },
    .{
        .name = "ns-aliases",
        .func = nsAliasesFn,
        .doc = "Returns a map of the aliases for the namespace.",
        .arglists = "([ns])",
        .added = "1.0",
    },
    .{
        .name = "ns-refers",
        .func = nsRefersFn,
        .doc = "Returns a map of the refer mappings for the namespace.",
        .arglists = "([ns])",
        .added = "1.0",
    },
    .{
        .name = "set-ns-doc",
        .func = setNsDocFn,
        .doc = "Sets the docstring on the named namespace. Internal — called by ns macro.",
        .arglists = "([ns-sym docstring])",
        .added = "1.0",
    },
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const Env = @import("../runtime/env.zig").Env;
const registry = @import("registry.zig");

fn setupTestEnv(alloc: Allocator) !*Env {
    const env = try alloc.create(Env);
    env.* = Env.init(alloc);
    try registry.registerBuiltins(env);
    bootstrap.macro_eval_env = env;
    return env;
}

test "find-ns - existing namespace" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const env = try setupTestEnv(alloc);
    defer {
        bootstrap.macro_eval_env = null;
        env.deinit();
    }

    const result = try findNsFn(alloc, &[_]Value{Value.initSymbol(alloc, .{ .ns = null, .name = "clojure.core" })});
    try testing.expect(result.tag() == .symbol);
    try testing.expectEqualStrings("clojure.core", result.asSymbol().name);
}

test "find-ns - nonexistent namespace returns nil" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const env = try setupTestEnv(alloc);
    defer {
        bootstrap.macro_eval_env = null;
        env.deinit();
    }

    const result = try findNsFn(alloc, &[_]Value{Value.initSymbol(alloc, .{ .ns = null, .name = "nonexistent" })});
    try testing.expectEqual(Value.nil_val, result);
}

test "all-ns - contains clojure.core and user" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const env = try setupTestEnv(alloc);
    defer {
        bootstrap.macro_eval_env = null;
        env.deinit();
    }

    const result = try allNsFn(alloc, &[_]Value{});
    try testing.expect(result.tag() == .list);
    try testing.expect(result.asList().items.len >= 2); // at least clojure.core and user

    var found_core = false;
    var found_user = false;
    for (result.asList().items) |item| {
        if (item.tag() == .symbol) {
            if (std.mem.eql(u8, item.asSymbol().name, "clojure.core")) found_core = true;
            if (std.mem.eql(u8, item.asSymbol().name, "user")) found_user = true;
        }
    }
    try testing.expect(found_core);
    try testing.expect(found_user);
}

test "ns-name - returns symbol" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try nsNameFn(alloc, &[_]Value{Value.initSymbol(alloc, .{ .ns = null, .name = "user" })});
    try testing.expect(result.tag() == .symbol);
    try testing.expectEqualStrings("user", result.asSymbol().name);
}

test "create-ns - creates new namespace" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const env = try setupTestEnv(alloc);
    defer {
        bootstrap.macro_eval_env = null;
        env.deinit();
    }

    // Verify namespace doesn't exist yet
    try testing.expect(env.findNamespace("test.new") == null);

    const result = try createNsFn(alloc, &[_]Value{Value.initSymbol(alloc, .{ .ns = null, .name = "test.new" })});
    try testing.expect(result.tag() == .symbol);
    try testing.expectEqualStrings("test.new", result.asSymbol().name);

    // Verify namespace was created
    try testing.expect(env.findNamespace("test.new") != null);
}

test "the-ns - existing namespace" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const env = try setupTestEnv(alloc);
    defer {
        bootstrap.macro_eval_env = null;
        env.deinit();
    }

    const result = try theNsFn(alloc, &[_]Value{Value.initSymbol(alloc, .{ .ns = null, .name = "user" })});
    try testing.expect(result.tag() == .symbol);
    try testing.expectEqualStrings("user", result.asSymbol().name);
}

test "the-ns - nonexistent namespace errors" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const env = try setupTestEnv(alloc);
    defer {
        bootstrap.macro_eval_env = null;
        env.deinit();
    }

    const result = theNsFn(alloc, &[_]Value{Value.initSymbol(alloc, .{ .ns = null, .name = "nonexistent" })});
    try testing.expectError(error.NamespaceNotFound, result);
}

test "ns-interns - returns map with interned vars" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const env = try setupTestEnv(alloc);
    defer {
        bootstrap.macro_eval_env = null;
        env.deinit();
    }

    // clojure.core has interned vars (from registerBuiltins)
    const result = try nsInternsFn(alloc, &[_]Value{Value.initSymbol(alloc, .{ .ns = null, .name = "clojure.core" })});
    try testing.expect(result.tag() == .map);
    // Should have entries (at least the builtins)
    try testing.expect(result.asMap().entries.len > 0);
    // Entries are key-value pairs, so length is even
    try testing.expect(result.asMap().entries.len % 2 == 0);
}

test "ns-publics - same as ns-interns (no private vars)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const env = try setupTestEnv(alloc);
    defer {
        bootstrap.macro_eval_env = null;
        env.deinit();
    }

    const interns = try nsInternsFn(alloc, &[_]Value{Value.initSymbol(alloc, .{ .ns = null, .name = "clojure.core" })});
    const publics = try nsPublicsFn(alloc, &[_]Value{Value.initSymbol(alloc, .{ .ns = null, .name = "clojure.core" })});
    try testing.expectEqual(interns.asMap().entries.len, publics.asMap().entries.len);
}

test "ns-map - includes interns and refers" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const env = try setupTestEnv(alloc);
    defer {
        bootstrap.macro_eval_env = null;
        env.deinit();
    }

    // user namespace has refers from clojure.core
    const result = try nsMapFn(alloc, &[_]Value{Value.initSymbol(alloc, .{ .ns = null, .name = "user" })});
    try testing.expect(result.tag() == .map);
    // user namespace should have referred vars (from registerBuiltins)
    try testing.expect(result.asMap().entries.len > 0);
}

test "ns-interns - user namespace is initially empty" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const env = try setupTestEnv(alloc);
    defer {
        bootstrap.macro_eval_env = null;
        env.deinit();
    }

    // user namespace has no interned vars (only refers)
    const result = try nsInternsFn(alloc, &[_]Value{Value.initSymbol(alloc, .{ .ns = null, .name = "user" })});
    try testing.expect(result.tag() == .map);
    try testing.expectEqual(@as(usize, 0), result.asMap().entries.len);
}

test "rootResource - converts ns name to resource path" {
    var buf: [256]u8 = undefined;
    const path = rootResource(&buf, "my-app.util").?;
    try testing.expectEqualStrings("/my_app/util", path);
}

test "rootResource - single segment" {
    var buf: [256]u8 = undefined;
    const path = rootResource(&buf, "utils").?;
    try testing.expectEqualStrings("/utils", path);
}

test "rootResource - deeply nested" {
    var buf: [256]u8 = undefined;
    const path = rootResource(&buf, "com.example.my-lib.core").?;
    try testing.expectEqualStrings("/com/example/my_lib/core", path);
}

test "init and deinit - loaded_libs tracking" {
    const alloc = std.heap.page_allocator;
    init(alloc);
    defer deinit();

    try testing.expect(!isLibLoaded("test.ns"));
    try markLibLoaded("test.ns");
    try testing.expect(isLibLoaded("test.ns"));
}

test "addLoadPath - adds to load paths" {
    const alloc = std.heap.page_allocator;
    init(alloc);
    defer deinit();

    try addLoadPath("/tmp/myproject/src");
    // load_paths should now include "." and the new path
    try testing.expect(load_paths.len >= 2);

    var found = false;
    for (load_paths) |p| {
        if (std.mem.eql(u8, p, "/tmp/myproject/src")) found = true;
    }
    try testing.expect(found);
}

test "detectAndAddSrcPath - finds src/ directory" {
    const alloc = std.heap.page_allocator;
    init(alloc);
    defer deinit();

    // Create temp project structure: .zig-cache/test-src-detect/src/
    std.fs.cwd().makePath(".zig-cache/test-src-detect/src") catch {};
    defer std.fs.cwd().deleteTree(".zig-cache/test-src-detect") catch {};

    try detectAndAddSrcPath(".zig-cache/test-src-detect");

    var found = false;
    for (load_paths) |p| {
        if (std.mem.eql(u8, p, ".zig-cache/test-src-detect/src")) found = true;
    }
    try testing.expect(found);
}

test "detectAndAddSrcPath - walks up to find src/" {
    const alloc = std.heap.page_allocator;
    init(alloc);
    defer deinit();

    // Create: .zig-cache/test-src-walk/src/ and .zig-cache/test-src-walk/deep/nested/
    std.fs.cwd().makePath(".zig-cache/test-src-walk/src") catch {};
    std.fs.cwd().makePath(".zig-cache/test-src-walk/deep/nested") catch {};
    defer std.fs.cwd().deleteTree(".zig-cache/test-src-walk") catch {};

    // Starting from deep/nested, should walk up and find src/
    try detectAndAddSrcPath(".zig-cache/test-src-walk/deep/nested");

    var found = false;
    for (load_paths) |p| {
        if (std.mem.eql(u8, p, ".zig-cache/test-src-walk/src")) found = true;
    }
    try testing.expect(found);
}

test "require - loads file from load path" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    init(alloc);
    defer deinit();

    const env = try setupTestEnv(alloc);
    defer {
        bootstrap.macro_eval_env = null;
        env.deinit();
    }
    try bootstrap.loadCore(alloc, env);

    // Create a temp directory with a .clj file
    const tmp_dir = std.fs.cwd().makeOpenPath("zig-cache/test-require", .{}) catch return;
    defer std.fs.cwd().deleteTree("zig-cache/test-require") catch {};

    // Write test_util.clj: (ns test-util) (def greeting "hello from test-util")
    tmp_dir.writeFile(.{
        .sub_path = "test_util.clj",
        .data = "(ns test-util)\n(def greeting \"hello from test-util\")\n",
    }) catch return;

    // Add temp dir to load paths
    try addLoadPath("zig-cache/test-require");

    // require should find and load the file
    _ = try requireFn(alloc, &[_]Value{
        Value.initSymbol(alloc, .{ .ns = null, .name = "test-util" }),
    });

    // Namespace should now exist with the var
    const ns = env.findNamespace("test-util");
    try testing.expect(ns != null);
    const v = ns.?.resolve("greeting");
    try testing.expect(v != null);
}

test "set-ns-doc sets namespace doc field" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const env = try setupTestEnv(alloc);
    defer {
        bootstrap.macro_eval_env = null;
        env.deinit();
    }

    // Create a namespace
    const ns = try env.findOrCreateNamespace("my.test.ns");
    try testing.expect(ns.doc == null);

    // Call set-ns-doc
    _ = try setNsDocFn(alloc, &[_]Value{
        Value.initSymbol(alloc, .{ .ns = null, .name = "my.test.ns" }),
        Value.initString(alloc, "A documented namespace"),
    });

    // Doc should now be set
    try testing.expect(ns.doc != null);
    try testing.expectEqualStrings("A documented namespace", ns.doc.?);
}
