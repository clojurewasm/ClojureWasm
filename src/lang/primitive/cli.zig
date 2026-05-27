// SPDX-License-Identifier: EPL-2.0
//! `clojure.tools.cli` Tier-A surface (§9.11 row 9.5).
//!
//! Minimum-viable `parse-opts` over the JVM `clojure.tools.cli`
//! API subset. Future cycles add `:parse-fn` / `:validate-fn` /
//! `:default` / `:missing` / `:assoc-fn` per JVM tools.cli 1.1+.
//!
//! ## Supported option-spec shape
//!
//! Each option-spec is a 3-element vector `[short long desc]`:
//!
//! - `short`: `-x` (single-dash + single char) or `nil` / `""` to skip.
//! - `long`: `--xxx` (boolean flag) OR `--xxx VALUE` (takes one
//!   string argument). The `:id` for the parsed map is the keyword
//!   form of the long flag's name (e.g. `--port PORT` → `:port`).
//! - `desc`: free-text description used in `:summary`.
//!
//! ## Returned map
//!
//! `{:options {...} :arguments [...] :errors [...] :summary "..."}`
//!
//! - `:options` — `{:id value}` map for each matched option.
//!   Boolean flags map to `true`; value-flags map to the string arg.
//! - `:arguments` — non-flag positional args (in order).
//! - `:errors` — vector of error strings (empty vector on success).
//! - `:summary` — formatted multi-line string of the option specs.
//!
//! **Location note (D-095)**: lives at `src/lang/primitive/` per
//! the cw v1 modules-deferred convention.

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const string_collection = @import("../../runtime/collection/string.zig");
const vector_collection = @import("../../runtime/collection/vector.zig");
const map_collection = @import("../../runtime/collection/map.zig");
const keyword_mod = @import("../../runtime/keyword.zig");

const Spec = struct {
    short: ?[]const u8 = null,
    long_name: []const u8, // e.g. "port"
    takes_value: bool,
    value_placeholder: ?[]const u8 = null,
    desc: []const u8,
};

pub fn parseOptsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("parse-opts", args, 2, loc);
    const args_vec = args[0];
    const specs_vec = args[1];
    if (args_vec.tag() != .vector or specs_vec.tag() != .vector) {
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "parse-opts",
            .expected = "vector of args + vector of option-specs",
            .actual = @tagName(args_vec.tag()),
        });
    }

    var arena = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena.deinit();
    const aalloc = arena.allocator();

    // Parse spec vector into typed Spec list (arena-owned).
    var specs = std.ArrayList(Spec).empty;
    const spec_count = vector_collection.count(specs_vec);
    var si: u32 = 0;
    while (si < spec_count) : (si += 1) {
        const spec_form = vector_collection.nth(specs_vec, si);
        if (spec_form.tag() != .vector) {
            return error_catalog.raise(.type_arg_invalid, loc, .{
                .fn_name = "parse-opts",
                .expected = "each option-spec must be a vector",
                .actual = @tagName(spec_form.tag()),
            });
        }
        const n = vector_collection.count(spec_form);
        if (n < 3) {
            return error_catalog.raise(.type_arg_invalid, loc, .{
                .fn_name = "parse-opts",
                .expected = "option-spec [short long desc] (3 elements)",
                .actual = "fewer than 3 elements",
            });
        }
        const short_v = vector_collection.nth(spec_form, 0);
        const long_v = vector_collection.nth(spec_form, 1);
        const desc_v = vector_collection.nth(spec_form, 2);
        if (long_v.tag() != .string or desc_v.tag() != .string) {
            return error_catalog.raise(.type_arg_invalid, loc, .{
                .fn_name = "parse-opts",
                .expected = "long flag and desc must be strings",
                .actual = "non-string",
            });
        }
        const short_str: ?[]const u8 = blk: {
            if (short_v.isNil()) break :blk null;
            if (short_v.tag() != .string) break :blk null;
            const s = string_collection.asString(short_v);
            if (s.len == 0) break :blk null;
            break :blk try aalloc.dupe(u8, s);
        };
        const long_raw = string_collection.asString(long_v);
        const sp = try parseSpec(aalloc, short_str, long_raw, string_collection.asString(desc_v));
        try specs.append(aalloc, sp);
    }

    // Walk args.
    var options_pairs = std.ArrayList(Value).empty;
    var arguments = std.ArrayList(Value).empty;
    var errors = std.ArrayList([]const u8).empty;

    const arg_count = vector_collection.count(args_vec);
    var ai: u32 = 0;
    while (ai < arg_count) : (ai += 1) {
        const a_val = vector_collection.nth(args_vec, ai);
        if (a_val.tag() != .string) {
            try errors.append(aalloc, try std.fmt.allocPrint(aalloc, "non-string arg at position {d}", .{ai}));
            continue;
        }
        const a = string_collection.asString(a_val);

        if (a.len == 0 or a[0] != '-') {
            try arguments.append(aalloc, try string_collection.alloc(rt, a));
            continue;
        }

        // Find matching spec.
        var matched_spec: ?Spec = null;
        var value_str: ?[]const u8 = null;
        if (std.mem.startsWith(u8, a, "--")) {
            // Long flag form: --name or --name=value or --name (value as next arg).
            const rest = a[2..];
            const eq_idx = std.mem.findScalar(u8,rest, '=');
            const name = if (eq_idx) |i| rest[0..i] else rest;
            for (specs.items) |s| {
                if (std.mem.eql(u8, s.long_name, name)) {
                    matched_spec = s;
                    if (eq_idx) |i| value_str = rest[i + 1 ..];
                    break;
                }
            }
        } else {
            // Short flag form: -x or -xvalue (no equals).
            if (a.len < 2) {
                try errors.append(aalloc, try std.fmt.allocPrint(aalloc, "malformed short flag '{s}'", .{a}));
                continue;
            }
            const short_str = a[0..2];
            for (specs.items) |s| {
                if (s.short) |ss| {
                    if (std.mem.eql(u8, ss, short_str)) {
                        matched_spec = s;
                        if (s.takes_value and a.len > 2) value_str = a[2..];
                        break;
                    }
                }
            }
        }

        if (matched_spec) |s| {
            if (s.takes_value) {
                if (value_str == null) {
                    // Consume the next arg as the value.
                    if (ai + 1 >= arg_count) {
                        try errors.append(aalloc, try std.fmt.allocPrint(aalloc, "missing argument for '{s}'", .{a}));
                        continue;
                    }
                    ai += 1;
                    const next_val = vector_collection.nth(args_vec, ai);
                    if (next_val.tag() != .string) {
                        try errors.append(aalloc, try std.fmt.allocPrint(aalloc, "non-string value for '{s}'", .{a}));
                        continue;
                    }
                    value_str = string_collection.asString(next_val);
                }
                const k_kw = try keyword_mod.intern(rt, null, s.long_name);
                const v_str = try string_collection.alloc(rt, value_str.?);
                try options_pairs.append(aalloc, k_kw);
                try options_pairs.append(aalloc, v_str);
            } else {
                // Boolean flag → true.
                const k_kw = try keyword_mod.intern(rt, null, s.long_name);
                try options_pairs.append(aalloc, k_kw);
                try options_pairs.append(aalloc, Value.true_val);
            }
        } else {
            try errors.append(aalloc, try std.fmt.allocPrint(aalloc, "Unknown option: '{s}'", .{a}));
        }
    }

    // Build the result map.
    var options_map = map_collection.empty();
    var op_i: usize = 0;
    while (op_i + 1 < options_pairs.items.len) : (op_i += 2) {
        options_map = map_collection.assoc(rt, options_map, options_pairs.items[op_i], options_pairs.items[op_i + 1]) catch |err| switch (err) {
            error.HashMapNotImplemented, error.HashMapPromotionNotImplemented => return error_catalog.raise(.feature_not_supported, loc, .{
                .name = "parse-opts result map beyond ArrayMap capacity (HAMT pending D-045)",
            }),
            else => |e| return e,
        };
    }

    var args_vec_out = vector_collection.empty();
    for (arguments.items) |a| {
        args_vec_out = try vector_collection.conj(rt, args_vec_out, a);
    }

    var errors_vec_out = vector_collection.empty();
    for (errors.items) |estr| {
        const ev = try string_collection.alloc(rt, estr);
        errors_vec_out = try vector_collection.conj(rt, errors_vec_out, ev);
    }

    // Build summary string.
    var aw: std.Io.Writer.Allocating = .init(aalloc);
    defer aw.deinit();
    for (specs.items, 0..) |s, idx| {
        if (idx > 0) try aw.writer.writeAll("\n");
        if (s.short) |ss| {
            try aw.writer.print("  {s}, --{s}", .{ ss, s.long_name });
        } else {
            try aw.writer.print("      --{s}", .{s.long_name});
        }
        if (s.takes_value) {
            try aw.writer.print(" {s}", .{s.value_placeholder orelse "VALUE"});
        }
        try aw.writer.print("  {s}", .{s.desc});
    }
    const summary_str = try string_collection.alloc(rt, aw.writer.buffered());

    // Assemble the 4-key result.
    var result = map_collection.empty();
    const k_options = try keyword_mod.intern(rt, null, "options");
    const k_arguments = try keyword_mod.intern(rt, null, "arguments");
    const k_errors = try keyword_mod.intern(rt, null, "errors");
    const k_summary = try keyword_mod.intern(rt, null, "summary");
    result = map_collection.assoc(rt, result, k_options, options_map) catch |err| switch (err) {
        else => |e| return e,
    };
    result = map_collection.assoc(rt, result, k_arguments, args_vec_out) catch |err| switch (err) {
        else => |e| return e,
    };
    result = map_collection.assoc(rt, result, k_errors, errors_vec_out) catch |err| switch (err) {
        else => |e| return e,
    };
    result = map_collection.assoc(rt, result, k_summary, summary_str) catch |err| switch (err) {
        else => |e| return e,
    };
    return result;
}

fn parseSpec(alloc: std.mem.Allocator, short: ?[]const u8, long_raw: []const u8, desc: []const u8) !Spec {
    // long_raw is "--name" (boolean) or "--name PLACEHOLDER" (value).
    var trimmed = long_raw;
    if (std.mem.startsWith(u8, trimmed, "--")) trimmed = trimmed[2..];
    const space_idx = std.mem.findScalar(u8,trimmed, ' ');
    if (space_idx) |si| {
        const name = try alloc.dupe(u8, trimmed[0..si]);
        const placeholder = try alloc.dupe(u8, trimmed[si + 1 ..]);
        return Spec{
            .short = short,
            .long_name = name,
            .takes_value = true,
            .value_placeholder = placeholder,
            .desc = try alloc.dupe(u8, desc),
        };
    }
    return Spec{
        .short = short,
        .long_name = try alloc.dupe(u8, trimmed),
        .takes_value = false,
        .desc = try alloc.dupe(u8, desc),
    };
}

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "parse-opts", .f = &parseOptsFn },
};

pub fn register(env: *Env) !void {
    const ns = try env.findOrCreateNs("clojure.tools.cli");
    for (ENTRIES) |it| {
        _ = try env.intern(ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
