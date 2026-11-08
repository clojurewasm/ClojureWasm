// SPDX-License-Identifier: EPL-2.0
//! Class value → Form, for macro expansions that contain a class object.
//!
//! clj macros may put Class objects into their expansion: `(defmacro m []
//! [String])`, `` `(f ~clojure.lang.Keyword) ``, or Emmy's `defgeneric`,
//! which splices `Keyword`/`RT`/`BigInt` classes into its output. A Form has
//! no slot for a runtime value, so `valueToForm` hands the class back as the
//! class-name SYMBOL that the analyzer re-resolves (`resolveClassValue`) to
//! the same interned descriptor.

const std = @import("std");
const Form = @import("../form.zig").Form;
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const Env = @import("../../runtime/env.zig").Env;
const type_descriptor = @import("../../runtime/type_descriptor.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = @import("../../runtime/error/info.zig").SourceLocation;
const analyzer = @import("analyzer.zig");

/// Prefixes tried for a dot-free class name. cljw prints native classes by
/// their simple name (ADR-0059), so the package must be found again.
const PACKAGES = [_][]const u8{ "java.lang.", "clojure.lang.", "java.util." };

/// Re-form a class VALUE (`.type_descriptor`) as the symbol naming it.
///
/// A name is emitted only when it ROUND-TRIPS: each candidate is resolved
/// against the expansion's namespace and must give back the very same
/// interned descriptor ref (ADR-0059 identity), so an `(:import …)` that
/// shadows a bare name, or a same-named type in another namespace, can never
/// silently swap the class.
///
/// Candidates, most specific first (a qualified name is immune to locals and
/// to import shadowing):
///   1. a user deftype/defrecord's `<defining_ns>.<Name>`: its `rt.types`
///      key, an exact-key hit from ANY namespace (ADR-0198);
///   2. a dotted fqcn as-is (`java.util.HashMap`);
///   3. a dot-free name under `java.lang.` / `clojure.lang.` / `java.util.`;
///   4. the bare name.
/// A class none of these reach (an anonymous `reify`, or a value class such
/// as `Fn` / `Atom` with no class symbol) raises `macro_return_class_unnamed`
/// naming the class, instead of mis-resolving to something else.
pub fn classValueToForm(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    v: Value,
    call_loc: SourceLocation,
) anyerror!Form {
    const td = type_descriptor.asTypeDescriptorRef(v);
    const fqcn = td.fqcn orelse
        return error_catalog.raise(.macro_return_class_unnamed, call_loc, .{ .name = "#<type>" });

    var cands: [2 + PACKAGES.len]?[]const u8 = .{null} ** (2 + PACKAGES.len);
    if (td.defining_ns) |dns| {
        if (td.kind == .deftype or td.kind == .defrecord)
            cands[0] = try std.fmt.allocPrint(arena, "{s}.{s}", .{ dns, fqcn });
    }
    if (std.mem.findScalar(u8, fqcn, '.') != null) {
        cands[1] = fqcn;
    } else {
        inline for (PACKAGES, 0..) |pkg, i| {
            cands[1 + i] = try std.fmt.allocPrint(arena, "{s}{s}", .{ pkg, fqcn });
        }
        cands[1 + PACKAGES.len] = fqcn;
    }

    for (cands) |maybe| {
        const name = maybe orelse continue;
        const resolved = (try analyzer.resolveClassValue(rt, env, null, name)) orelse continue;
        if (resolved == v) {
            return .{ .data = .{ .symbol = .{ .name = try arena.dupe(u8, name) } }, .location = call_loc };
        }
    }
    return error_catalog.raise(.macro_return_class_unnamed, call_loc, .{ .name = fqcn });
}

test "native class values re-form as a symbol resolving to the same class" {
    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var rt = Runtime.init(threaded.io(), testing.allocator);
    defer rt.deinit();
    var env = try Env.init(&rt);
    defer env.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{ "String", "clojure.lang.Keyword", "java.lang.Long" }) |src| {
        const cls = (try analyzer.resolveClassValue(&rt, &env, null, src)) orelse return error.TestUnexpectedResult;
        const form = try classValueToForm(arena, &rt, &env, cls, .{});
        try testing.expect(form.data == .symbol);
        const back = (try analyzer.resolveClassValue(&rt, &env, form.data.symbol.ns, form.data.symbol.name)) orelse
            return error.TestUnexpectedResult;
        try testing.expectEqual(cls, back);
    }
}
