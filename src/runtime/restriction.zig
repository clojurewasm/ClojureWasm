// SPDX-License-Identifier: EPL-2.0
//! The single "is this runtime restricted?" predicate (ADR-0199). A surface
//! that reaches past the in-process containment mechanisms (a spawned child
//! process escapes both the filesystem jail and the eval budget) asks here
//! instead of re-deriving the set, so a new containment mechanism is added in
//! one place and every such surface refuses under it.
//!
//! Backend: impl-only
//! Impl deps: eval_budget
//! Clojure peer: none
const Runtime = @import("runtime.zig").Runtime;
const eval_budget = @import("concurrency/eval_budget.zig");

pub const Restriction = enum {
    /// `CLJW_FS_ROOT` confines file access (ADR-0123).
    fs_jail,
    /// A `cljw.eval/with-budget` extent is active on this thread.
    eval_budget,

    pub fn describe(r: Restriction) []const u8 {
        return switch (r) {
            .fs_jail => "a filesystem root (CLJW_FS_ROOT) is configured",
            .eval_budget => "a cljw.eval/with-budget budget is active",
        };
    }
};

/// The first active restriction, or null when the runtime is unrestricted.
pub fn active(rt: *const Runtime) ?Restriction {
    if (rt.fs_jail_root != null) return .fs_jail;
    if (eval_budget.current != null) return .eval_budget;
    return null;
}
