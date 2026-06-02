// SPDX-License-Identifier: EPL-2.0
//! `clojure.edn` Tier-A surface (§9.11 row 9.2).
//!
//! cw v1's reader already parses EDN syntax (Clojure IS EDN-shaped);
//! this module exposes `clojure.edn/read-string` as a thin Layer-2
//! primitive that runs `eval/reader.readOne` followed by
//! `analyzer.formToValue` (recursively lifted at row 9.2 to cover
//! vector / map / set literals).
//!
//! Only the 1-arity `(read-string s)` form lands at row 9.2. The
//! `(read-string opts s)` 2-arity form (data-readers / readers /
//! eof / default) is a follow-up debt row.
//!
//! **Location note (D-095)**: this Zig primitive lives under
//! `src/lang/primitive/` (mirroring `string.zig` / `walk.zig`)
//! rather than `modules/edn/` because Zig 0.16's `@import` +
//! `@embedFile` reject cross-module-path access. The matching
//! `.clj` source sits at `src/lang/clj/clojure/edn.clj` (also
//! mirroring `clojure.string` / `clojure.set` precedent). The
//! top-level `modules/` reservation is documented at
//! `modules/_README.md` + tracked for future build.zig migration
//! (= declare `modules/` as a separate Zig module with
//! `addImport`) via D-095.

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const reader_mod = @import("../../eval/reader.zig");
const analyzer_mod = @import("../../eval/analyzer/analyzer.zig");
const string_collection = @import("../../runtime/collection/string.zig");

/// Implements clojure.edn/read-string.
/// Spec: `(read-string s)` reads one EDN form from `s` and returns
///   it as a Value. An empty / whitespace-only input returns `nil`.
/// JVM reference: clojure.edn/read-string
/// cw v1 tier: A (Phase 9 row 9.2)
pub fn readStringFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("read-string", args, 1, loc);
    const arg = args[0];
    if (arg.tag() != .string) {
        return error_catalog.raise(.type_arg_not_string, loc, .{
            .fn_name = "read-string",
            .actual = @tagName(arg.tag()),
        });
    }
    const source = string_collection.asString(arg);

    var arena = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena.deinit();

    const form_opt = reader_mod.readOne(arena.allocator(), source) catch {
        return error_catalog.raise(.feature_not_supported, loc, .{
            .name = "EDN reader error in clojure.edn/read-string",
        });
    };
    const form = form_opt orelse return Value.nil_val;
    return try analyzer_mod.formToValue(rt, env, form);
}

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "read-string", .f = &readStringFn },
};

/// Register `clojure.edn` primitives into the dedicated namespace.
/// Mirrors the row 6.9 pattern from `lang/primitive/string.zig`:
/// creates `clojure.edn` ns if missing + interns each Var. The
/// `(ns clojure.edn ...)` head in `src/lang/clj/clojure/edn.clj`
/// finds an already-populated ns when bootstrap evaluates it.
pub fn register(env: *Env) !void {
    const ns = try env.findOrCreateNs("clojure.edn");
    for (ENTRIES) |it| {
        _ = try env.intern(ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
