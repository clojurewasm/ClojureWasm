// SPDX-License-Identifier: EPL-2.0
//! `cljw` entry point. Row 8.1 (D-031, ADR-equivalent via survey +
//! DA fork) extracted the argv-dispatcher / source-runner / error-
//! render bodies into `src/app/{cli,runner,error_render}.zig`; this
//! file is now a thin Juicy-Main wrapper that hands off to
//! `app.cli.dispatch`. The Zig 0.16 entry-point signature stays
//! `pub fn main(init: std.process.Init)` so `build.zig` does not
//! need a `root_source_file` change.
//!
//! The `test {}` aggregator at the bottom intentionally stays here:
//! it is the second-`addTest()` orphan-fix per `zig_tips.md` "Test
//! discovery via @import (lazy-decl-analysis trap)" + the
//! survey-confirmed D-055 second-`addTest()` avoidance rule.
//! Moving the aggregator to a dedicated file would re-trigger the
//! discovery-graph warning.

const std = @import("std");

const cli = @import("app/cli.zig");
const error_render = @import("app/error_render.zig");
const io_default = @import("runtime/concurrency/io_default.zig");

pub fn main(init: std.process.Init) !void {
    // Upgrade the process-wide `io_default` singleton from its lazy
    // single-threaded default to the real process io BEFORE any runtime work,
    // so Phase-B concurrency sync (`std.Io.Mutex`/`Io.Condition` reached by
    // no-`io` call sites — the GC alloc lock, the safepoint, future/promise
    // result cells) blocks for real across spawned worker threads (D-244 #4).
    // Production-only: tests go through `Runtime.init` directly and keep the
    // single-threaded default (a per-test threaded io is set where needed), so
    // `io_default` never dangles at a freed test-local `Threaded`.
    io_default.set(init.io);
    try cli.dispatch(init);
}

test "smoke: main module loads" {
    try std.testing.expect(true);
}

// ADR-0056 Cycle 2 Step 2a: the build-time cache_gen tool AOT-compiled
// clojure.core to a bytecode envelope and build.zig embedded it. This
// verifies the whole generate→embed pipeline produced a non-empty blob,
// WITHOUT yet changing the production startup (setupCore still uses
// loadCore; the restore swap is Step 2b).
test "aot: embedded bootstrap_cache blob is present and non-empty" {
    const blob = @import("bootstrap_cache").data;
    try std.testing.expect(blob.len > 0);
    // The envelope carries the "CLJW" chunk magic somewhere in its bytes.
    try std.testing.expect(std.mem.find(u8, blob, "CLJW") != null);
}

test "kindToExitCode maps internal_error → 70 and others → 1 (ADR-0019)" {
    try std.testing.expectEqual(@as(u8, 70), error_render.kindToExitCode(.internal_error));
    try std.testing.expectEqual(@as(u8, 1), error_render.kindToExitCode(.type_error));
    try std.testing.expectEqual(@as(u8, 1), error_render.kindToExitCode(.syntax_error));
    try std.testing.expectEqual(@as(u8, 1), error_render.kindToExitCode(.arity_error));
    try std.testing.expectEqual(@as(u8, 1), error_render.kindToExitCode(.name_error));
    try std.testing.expectEqual(@as(u8, 1), error_render.kindToExitCode(.not_implemented));
    try std.testing.expectEqual(@as(u8, 1), error_render.kindToExitCode(.out_of_memory));
}

test "build_options exposes phase_at_least_N comptime bools (ADR-0023)" {
    const build_options = @import("build_options");
    try std.testing.expect(@TypeOf(build_options.phase_at_least_5) == bool);
    try std.testing.expect(@TypeOf(build_options.phase_at_least_6) == bool);
    try std.testing.expect(@TypeOf(build_options.phase_at_least_7) == bool);
    try std.testing.expect(@TypeOf(build_options.phase_at_least_11) == bool);
    try std.testing.expect(@TypeOf(build_options.phase_at_least_14) == bool);
    try std.testing.expect(@TypeOf(build_options.phase_at_least_15) == bool);
    try std.testing.expect(@TypeOf(build_options.phase_at_least_17) == bool);
    try std.testing.expect(build_options.phase_at_least_5 == true);
    try std.testing.expect(build_options.phase_at_least_6 == true);
    try std.testing.expect(build_options.phase_at_least_7 == true);
    try std.testing.expect(build_options.phase_at_least_11 == true);
    try std.testing.expect(build_options.phase_at_least_14 == false);
    try std.testing.expect(build_options.phase_at_least_15 == false);
    try std.testing.expect(build_options.phase_at_least_17 == false);
}

// Pull in tests from the source tree. As more files appear under
// src/, add them here so the unified `zig build test` discovers them.
test {
    _ = @import("app/cli.zig");
    _ = @import("app/deps/parse.zig");
    _ = @import("app/deps/resolve.zig");
    _ = @import("app/deps/git_fetch.zig");
    _ = @import("app/deps/run_mode.zig");
    _ = @import("app/runner.zig");
    _ = @import("app/builder.zig");
    _ = @import("app/error_render.zig");
    _ = @import("app/render_error.zig");
    _ = @import("runtime/value/value.zig");
    _ = @import("runtime/error/info.zig");
    _ = @import("runtime/error/catalog.zig");
    _ = @import("runtime/error/print.zig");
    _ = @import("runtime/error/host_class.zig");
    _ = @import("runtime/class_name.zig");
    _ = @import("runtime/interface_membership.zig");
    _ = @import("runtime/gc/arena.zig");
    _ = @import("runtime/gc/tag_ops.zig");
    _ = @import("runtime/gc/gc_heap.zig");
    _ = @import("runtime/gc/mark_sweep.zig");
    _ = @import("runtime/gc/free_pool.zig");
    _ = @import("runtime/gc/root_set.zig");
    _ = @import("runtime/gc/gc_torture.zig");
    _ = @import("runtime/concurrency/io_default.zig");
    _ = @import("runtime/concurrency/safepoint.zig");
    _ = @import("runtime/concurrency/eval_budget.zig");
    _ = @import("runtime/concurrency/lock_tx.zig");
    _ = @import("runtime/concurrency/object_monitor.zig");
    _ = @import("runtime/agent.zig");
    _ = @import("runtime/value/heap_tag.zig");
    _ = @import("runtime/value/heap_header.zig");
    _ = @import("runtime/value/nan_box.zig");
    _ = @import("runtime/collection/ex_info.zig");
    _ = @import("runtime/collection/list.zig");
    _ = @import("runtime/collection/string.zig");
    _ = @import("runtime/collection/vector.zig");
    _ = @import("runtime/collection/map.zig");
    _ = @import("runtime/collection/set.zig");
    _ = @import("runtime/collection/chunked_cons.zig");
    _ = @import("runtime/collection/range.zig");
    _ = @import("runtime/collection/persistent_queue.zig");
    _ = @import("runtime/collection/transient/transient_vector.zig");
    _ = @import("runtime/collection/transient/transient_array_map.zig");
    _ = @import("runtime/collection/transient/transient_hash_set.zig");
    _ = @import("runtime/hash.zig");
    _ = @import("runtime/keyword.zig");
    _ = @import("runtime/symbol.zig");
    _ = @import("runtime/print.zig");
    _ = @import("runtime/runtime.zig");
    _ = @import("runtime/dispatch.zig");
    _ = @import("runtime/env.zig");
    _ = @import("runtime/io/interface.zig");
    _ = @import("runtime/type_descriptor.zig");
    _ = @import("runtime/protocol.zig");
    _ = @import("runtime/multimethod.zig");
    _ = @import("runtime/dispatch/method_table.zig");
    _ = @import("runtime/stm/tval.zig");
    _ = @import("runtime/stm/ref.zig");
    _ = @import("runtime/java/_host_api.zig");
    _ = @import("runtime/numeric/big_int.zig");
    _ = @import("runtime/lazy_seq.zig");
    _ = @import("eval/form.zig");
    _ = @import("eval/tokenizer.zig");
    _ = @import("eval/reader.zig");
    _ = @import("eval/node.zig");
    _ = @import("eval/analyzer/analyzer.zig");
    _ = @import("eval/macro_dispatch.zig");
    _ = @import("eval/backend/tree_walk.zig");
    _ = @import("eval/backend/vm.zig");
    _ = @import("eval/driver.zig");
    _ = @import("eval/evaluator.zig");
    _ = @import("lang/diff_test.zig");
    _ = @import("eval/backend/vm/opcode.zig");
    _ = @import("eval/backend/vm/compiler.zig");
    _ = @import("lang/primitive/math.zig");
    _ = @import("lang/primitive/core.zig");
    _ = @import("lang/primitive/error.zig");
    _ = @import("lang/primitive/transient.zig");
    _ = @import("lang/primitive/edn.zig");
    _ = @import("lang/primitive/json.zig");
    _ = @import("lang/primitive/csv.zig");
    _ = @import("lang/primitive/cli.zig");
    _ = @import("lang/primitive/namespace.zig");
    _ = @import("eval/bytecode/serialize.zig");
    _ = @import("lang/primitive/multimethod.zig");
    _ = @import("lang/primitive/protocol.zig");
    _ = @import("lang/primitive.zig");
    _ = @import("lang/macro_transforms.zig");
    _ = @import("lang/bootstrap.zig");
    // Phase 6 impl files that ship unit tests but have no
    // in-graph referrer yet (Clojure-ns peer / Java-surface
    // method dispatch land at Phase 6.9+ / Phase 7). Without
    // these lines Zig 0.16's lazy decl analysis silently skips
    // their tests. See .claude/rules/zig_tips.md "Test
    // discovery via @import".
    _ = @import("runtime/charset.zig");
    _ = @import("runtime/clock.zig");
    _ = @import("runtime/random.zig");
    _ = @import("runtime/regex/value.zig");
    _ = @import("runtime/time/instant.zig");
    _ = @import("runtime/bencode/bencode.zig");
}
