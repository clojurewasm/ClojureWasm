// SPDX-License-Identifier: EPL-2.0
//! Regex primitives for the `rt/` namespace — Clojure-ns surface.
//!
//! `re-find`, `re-matches`, `re-seq`, `re-groups`, `re-pattern`
//! from clojure.core; `clojure.string/replace` and
//! `clojure.string/split` also dispatch here. All wrap
//! `runtime/regex/{compile,match}.zig` per F-009 — the same impl
//! is shared with the Java surface in
//! `runtime/java/util/regex/Pattern.zig`.
//!
//! Status: Phase 6.6 cycle 1 — parser + Pike VM driver landed in
//! `runtime/regex/`. Primitive registration (re-find / re-matches /
//! re-seq / re-groups / re-pattern) lands once the regex `Value`
//! wrap path through the reader reaches green; the imports below
//! pull the impl files into the test graph so their unit tests
//! actually run.

const env_mod = @import("../../runtime/env.zig");

// Pulls runtime/regex/{compile,match}.zig into the compile +
// test graph. Both modules are reachable from this Clojure-ns
// surface; registering the five core primitives lands once the
// reader-side regex Value wiring is in place.
pub const _regex_compile = @import("../../runtime/regex/compile.zig");
pub const _regex_match = @import("../../runtime/regex/match.zig");

/// Phase 6.6 cycle 1 — no entries registered yet. The shape
/// mirrors `lang/primitive/uuid.zig` (Entry struct + ENTRIES
/// array) so the next commit appends rows once `re-pattern`'s
/// Value wrap reaches green.
pub fn register(env: *env_mod.Env, rt_ns: *env_mod.Namespace) !void {
    _ = env;
    _ = rt_ns;
}

// Zig 0.16 analyses decls lazily — an unreferenced `pub const X
// = @import(...)` does not pull X's test blocks into the
// discovery set. The refAllDecls calls below force analysis of
// every decl in compile.zig and match.zig so their unit tests
// run as part of `zig build test`.
test {
    @import("std").testing.refAllDecls(_regex_compile);
    @import("std").testing.refAllDecls(_regex_match);
}
