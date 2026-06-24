// SPDX-License-Identifier: EPL-2.0
//! Host surface for `clojure.lang.Compiler` static fields (ADR-0108 tree).
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: none
//!
//! Real pure-Clojure macro libraries (`org.clojure/tools.macro`, and the
//! libs that ride it — `algo.monads` etc.) read `clojure.lang.Compiler/specials`
//! to learn the set of special-form symbols: `tools.macro` does
//! `(into #{} (keys clojure.lang.Compiler/specials))`. Only `(keys …)` is used,
//! so the map's VALUES may be `nil`.
//!
//! `specials` resolves (via the `.compiler_specials` Singleton tag) to a map
//! `{<special-form-symbol> nil …}` whose keys are cljw's ACTUAL special forms —
//! derived from `SPECIAL_FORMS` (the analyzer's SSOT) so the surface can never
//! drift from the real set. The map BUILD lives in `eval/analyzer/analyzer.zig`
//! (`buildCompilerSpecials`) because the runtime/ zone may not import eval/;
//! only the Singleton TAG lives in `type_descriptor.zig`. Registered as
//! `cljw.clojure.lang.Compiler`, so `resolveJavaSurface("clojure.lang.Compiler")`
//! hits via the `cljw.<fqcn>` path.

const type_descriptor = @import("../../type_descriptor.zig");
const host_api = @import("../../java/_host_api.zig");

const compiler_static_fields = [_]type_descriptor.TypeDescriptor.StaticField{
    .{ .name = "specials", .value = .{ .singleton = .compiler_specials } },
};

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.clojure.lang.Compiler",
    .descriptor = &descriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.clojure.lang.Compiler",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &compiler_static_fields,
    .parent = null,
    .meta = .nil_val,
};
