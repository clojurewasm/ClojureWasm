// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! ClojureWasm CLI entry point.
//!
//! Usage:
//!   cljw -e "expr"           Evaluate expression and print result
//!   cljw file.clj            Evaluate file and print last result
//!   cljw                     Start interactive REPL
//!   cljw build file.clj -o app  Build single binary with embedded code

const std = @import("std");
const gc_mod = @import("runtime/gc.zig");
const vm_mod = @import("engine/vm/vm.zig");
const keyword_intern = @import("runtime/keyword_intern.zig");
const ns_ops = @import("lang/builtins/ns_ops.zig");
const lifecycle = @import("runtime/lifecycle.zig");
const runner = @import("app/runner.zig");
const cli = @import("app/cli.zig");
const test_runner = @import("app/test_runner.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Two allocators:
    //   allocator (GPA)   — for infrastructure (Env, Namespace, Var, HashMaps)
    //   alloc (GC)        — for Values (Fn, collections, strings, reader/analyzer)
    var gc = gc_mod.MarkSweepGc.init(allocator);
    defer gc.deinit();
    defer vm_mod.dumpOpcodeProfile(); // 37.1: dump opcode profile at exit
    defer gc.dumpAllocProfile(); // 37.1: dump allocation profile at exit
    const alloc = gc.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Initialize keyword intern table (uses GPA for permanent keyword strings)
    keyword_intern.init(allocator);
    defer keyword_intern.deinit();

    // Initialize load path infrastructure for require/load
    ns_ops.init(allocator);
    defer ns_ops.deinit();

    // Install signal handlers for graceful shutdown (SIGINT/SIGTERM/SIGPIPE)
    lifecycle.installSignalHandlers();

    // Check for embedded payload (built binary via `cljw build`).
    // If this binary has a CLJW trailer, run the embedded payload and exit.
    if (runner.readEmbeddedSource(allocator)) |payload| {
        defer allocator.free(payload);
        runner.handleEmbedded(alloc, allocator, &gc, payload, args);
        return;
    }

    // Subcommand dispatch
    if (args.len >= 2) {
        if (std.mem.eql(u8, args[1], "build")) {
            runner.handleBuildCommand(alloc, allocator, &gc, args[2..]);
            return;
        }
        if (std.mem.eql(u8, args[1], "test")) {
            test_runner.handleTestCommand(alloc, allocator, &gc, args[2..]);
            return;
        }
        if (std.mem.eql(u8, args[1], "new")) {
            cli.handleNewCommand(args[2..]);
            return;
        }
    }

    // Main CLI dispatch (arg parsing → deps → execution)
    cli.run(alloc, allocator, &gc, args);
}
