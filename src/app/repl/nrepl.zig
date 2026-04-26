// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! nREPL server — stubbed during the Zig 0.16 migration.
//!
//! The full implementation (~1800 lines covering bencode dispatch,
//! session/state, eval/load-file/completions/info/eldoc ops, lookup,
//! ns-list, stacktrace) was built on std.net.{Server,Stream}, std.Thread.{
//! Mutex,Condition} and std.posix.poll — all of which were removed or
//! reshaped in Zig 0.16. The original code is preserved in git history
//! (`git show develop/zig-016-migration~N:src/app/repl/nrepl.zig`) and
//! will be ported back in a Phase 7 follow-up F## task once the std.Io.net
//! migration patterns are established. The accept loop, in particular,
//! needs to integrate with the new lifecycle.acceptWithShutdownCheck
//! (also stubbed) on top of std.Io.net.Server.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Env = @import("../../runtime/env.zig").Env;
const gc_mod = @import("../../runtime/gc.zig");

pub const StartError = error{NreplDisabledDuringMigration};

pub fn startServer(gpa_allocator: Allocator, port: u16) StartError!void {
    _ = gpa_allocator;
    _ = port;
    std.debug.print(
        \\nrepl: temporarily disabled while the std.net → std.Io.net migration
        \\       lands. Tracked as a Phase 7 follow-up. Use cljw -e/--repl in
        \\       the meantime.
        \\
    , .{});
    return error.NreplDisabledDuringMigration;
}

pub fn startServerWithEnv(
    gpa_allocator: Allocator,
    env: *Env,
    gc: *gc_mod.MarkSweepGc,
    port: u16,
) StartError!void {
    _ = .{ gpa_allocator, env, gc, port };
    return startServer(gpa_allocator, port);
}
