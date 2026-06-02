// SPDX-License-Identifier: EPL-2.0
//! Java-compat surface registry contract (ADR-0029, supersedes ADR-0011).
//!
//! Each Java-stdlib equivalent under `src/runtime/java/<pkg>/<Class>.zig`
//! exports a top-level `___HOST_EXTENSION` declaration whose type is
//! `Extension`. A future aggregator (Phase 6+) uses Zig comptime
//! introspection to collect every such declaration into the Java
//! surface registry without a central edit per addition.
//!
//! Phase 5 entry lands the contract only (this file). The first
//! `<Class>.zig` lands at Phase 6 entry; until then `runtime/java/`
//! holds only this aggregator file. `runtime/cljw/<area>/<Item>.zig`
//! mirrors the same marker pattern for cljw-original surfaces; the
//! two trees share the same `Extension` shape and registry contract
//! per ADR-0029 D1.

const std = @import("std");
const type_descriptor = @import("../type_descriptor.zig");
const env_mod = @import("../env.zig");
const Env = env_mod.Env;

/// Marker symbol every Java- and cljw-surface file exports under
/// this exact name. See the module docstring for the aggregator
/// scan contract.
pub const MARKER_NAME: []const u8 = "___HOST_EXTENSION";

/// One surface extension entry. Carries the user-facing Clojure name
/// (`cljw.java.util.UUID` for Java surface; `cljw.<area>.<Item>` for
/// cljw-original surface), the corresponding native `TypeDescriptor`,
/// and an optional init function for any one-time setup. The `init`
/// is invoked once at Runtime startup.
pub const Extension = struct {
    /// Clojure-side namespace this entry exposes:
    ///   - Java surface: `cljw.java.<java-pkg>.<Class>` (e.g.,
    ///     `cljw.java.util.UUID`).
    ///   - cljw-original: `cljw.<area>.<Item>` (e.g., `cljw.wasm.Engine`).
    /// Used by Clojure `(:require [cljw.java.util :refer [UUID]])` or
    /// `(:require [cljw.wasm :refer [Engine]])`.
    cljw_ns: []const u8,
    /// Pre-allocated `TypeDescriptor` for this surface entry. Lifetime
    /// is the Runtime — the descriptor lives in the namespace it is
    /// registered into.
    descriptor: *const type_descriptor.TypeDescriptor,
    /// Optional initialiser. `null` means no setup required beyond
    /// descriptor registration. Receives the heap-copied descriptor
    /// and the runtime's GPA so the init callback can populate fields
    /// that cannot be initialised at module-scope comptime (notably
    /// `method_table` entries — `Value.initBuiltinFn(&fn)` calls
    /// `@intFromPtr(fn)` which is not comptime-known on Mac targets —
    /// and `field_layout` slices whose names must match the GPA-owned
    /// invariant that `Runtime.deinit` enforces).
    ///
    /// Allocator ownership contract: any heap allocation the init
    /// callback makes (method_table slice + each MethodEntry's
    /// method_name dup; field_layout slice + each FieldEntry's name
    /// dup) MUST be on the passed `gpa` so `Runtime.deinit`'s pass
    /// over `rt.types` frees it via the same allocator.
    /// `MethodEntry.protocol_name` stays a borrowed slice (process-
    /// lifetime literal or process-lifetime ProtocolDescriptor —
    /// `Runtime.deinit` does not free it).
    init: ?*const fn (td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void = null,
};

/// All Java-surface modules whose `___HOST_EXTENSION` declarations
/// `installAll` walks. **Hand-maintained**: a new
/// `runtime/java/<pkg>/<Class>.zig` lands on this list in the same
/// commit that creates the file (ADR-0029 D5 schema + F-009). Zig
/// 0.16 has no directory `@import`; this list is the explicit
/// alternative to a generated build.zig codegen step.
const java_surfaces = [_]type{
    @import("io/File.zig"),
    @import("lang/Boolean.zig"),
    @import("lang/Character.zig"),
    @import("lang/Double.zig"),
    @import("lang/Integer.zig"),
    @import("lang/Long.zig"),
    @import("lang/Math.zig"),
    @import("lang/System.zig"),
    // D-198 / clj-parity C5 — Throwable-family constructors (`(Exception.
    // msg)` etc. mint an `.ex_info` tagged with the class name).
    @import("lang/Throwable.zig"),
    @import("lang/Exception.zig"),
    @import("lang/RuntimeException.zig"),
    // Phase 14 row 14.2 (D-097) second wave begins ↓
    @import("math/BigDecimal.zig"),
    // Phase 14 row 14.3 (D-097) third wave — backing impls under
    // runtime/net/ + runtime/crypto/ deferred to D-106.
    @import("net/Socket.zig"),
    @import("security/MessageDigest.zig"),
    @import("time/Instant.zig"),
    // Phase 14 row 14.2 (D-097) second wave (time) — backing impls
    // for LocalDateTime / Duration / ZonedDateTime are deferred to
    // D-105 (a focused runtime/time/ landing cycle).
    @import("time/LocalDateTime.zig"),
    @import("time/Duration.zig"),
    @import("time/ZonedDateTime.zig"),
    @import("util/Date.zig"),
    @import("util/Random.zig"),
    @import("util/UUID.zig"),
    // Phase 14 row 14.2 (D-097) second wave (regex) — backing impl
    // shipped by Pattern's regex/match.zig.
    @import("util/regex/Matcher.zig"),
    @import("util/regex/Pattern.zig"),
};

/// Walk every enumerated surface's `___HOST_EXTENSION` declaration,
/// create its `cljw_ns` namespace, register its `TypeDescriptor` into
/// `rt.types`, and run any `init` callback. Idempotent — re-running
/// against the same Env is a no-op (existing ns / descriptor entries
/// are reused; `init` runs once per call but surfaces that need
/// single-shot setup carry their own latch).
///
/// Phase 14 row 14.1 (D-079) wires this from `lang/primitive.zig::
/// registerAll`; the second-wave surfaces (D-097 row 14.2 — Matcher /
/// LocalDateTime / Duration / ZonedDateTime / BigDecimal Java wrapper)
/// land by appending entries to `java_surfaces` above.
pub fn installAll(env: *Env) !void {
    const rt = env.rt;
    inline for (java_surfaces) |S| {
        const ext: Extension = S.___HOST_EXTENSION;
        _ = try env.findOrCreateNs(ext.cljw_ns);
        if (ext.descriptor.fqcn) |fqcn_lit| {
            const gop = try rt.types.getOrPut(fqcn_lit);
            if (!gop.found_existing) {
                // `rt.deinit` (runtime.zig:290-312) frees every
                // `types` entry — key, fqcn, and the TypeDescriptor
                // itself — via `rt.gpa`. Surface descriptors are
                // module-scoped statics (string literals + empty
                // slices), so heap-copy them on install so the
                // ownership uniformity holds at deinit. The cost is
                // ~1 KB total across the entire surface set.
                const td = try rt.gpa.create(type_descriptor.TypeDescriptor);
                td.* = ext.descriptor.*;
                td.fqcn = try rt.gpa.dupe(u8, fqcn_lit);
                gop.key_ptr.* = try rt.gpa.dupe(u8, fqcn_lit);
                gop.value_ptr.* = td;
            }
        }
        if (ext.init) |f| {
            // Look the heap td back up so `init` operates on the
            // canonical descriptor (idempotent re-runs: the heap td
            // exists already on second call, so `gop.value_ptr.*`
            // above just re-resolved it). For idempotency, init
            // callbacks check `td.method_table.len == 0` (or the
            // equivalent for field_layout) before populating;
            // otherwise the second `installAll` would leak the
            // first call's allocation.
            const td_ptr = rt.types.get(ext.descriptor.fqcn.?).?;
            try f(@constCast(td_ptr), rt.gpa);
        }
    }
}

const testing = std.testing;

test "Extension struct shape" {
    var td: type_descriptor.TypeDescriptor = .{
        .fqcn = "cljw.java.util.UUID",
        .kind = .native,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = .nil_val,
    };
    const ext: Extension = .{
        .cljw_ns = "cljw.java.util.UUID",
        .descriptor = &td,
    };
    try testing.expectEqualStrings("cljw.java.util.UUID", ext.cljw_ns);
    try testing.expect(ext.init == null);
}

test "MARKER_NAME constant matches the ADR-0029 contract" {
    try testing.expectEqualStrings("___HOST_EXTENSION", MARKER_NAME);
}

const Runtime = @import("../runtime.zig").Runtime;

test "installAll registers every Java surface's cljw_ns + TypeDescriptor" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var rt = Runtime.init(threaded.io(), testing.allocator);
    defer rt.deinit();
    var env = try Env.init(&rt);
    defer env.deinit();

    try installAll(&env);

    // Every enumerated surface lands its cljw_ns + descriptor.
    inline for (java_surfaces) |S| {
        const ext: Extension = S.___HOST_EXTENSION;
        try testing.expect(env.findNs(ext.cljw_ns) != null);
        if (ext.descriptor.fqcn) |fqcn| {
            try testing.expect(rt.types.get(fqcn) != null);
        }
    }
}

test "installAll is idempotent" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var rt = Runtime.init(threaded.io(), testing.allocator);
    defer rt.deinit();
    var env = try Env.init(&rt);
    defer env.deinit();

    try installAll(&env);
    const types_after_first = rt.types.count();
    try installAll(&env);
    const types_after_second = rt.types.count();
    try testing.expectEqual(types_after_first, types_after_second);
}
