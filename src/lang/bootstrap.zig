//! Stage-1 bootstrap — read+analyse+evaluate the embedded Clojure
//! source files (currently `clj/clojure/core.clj` and
//! `clj/clojure/string.clj`) after `primitive.registerAll` populates
//! the kernel namespaces and `macro_transforms.registerInto` populates
//! the analyzer's macro Table.
//!
//! ### Multi-file loader (ADR-0032)
//!
//! `loadCore` iterates `FILES`, a flat table of `{label, source}`
//! pairs. The loader carries **no** namespace knowledge — each `.clj`
//! file declares its own namespace via a leading `(in-ns 'foo.bar)`
//! form (analyzer special form per ADR-0032). After the last file,
//! `current_ns` resets to `user/` so the REPL prompt lands there.
//!
//! ### Phase 3.12 → Phase 6.9 scope
//!
//! - `loadCore` accepts an arena (caller-owned), runs the loop, and
//!   propagates errors via the standard `runtime/error.zig` pipeline.
//!   Errors surface with the file's label so the renderer's
//!   `<file>:<line>:<col>: …` formatting points at the right source
//!   (ADR-0032 + D-058 caveat: the renderer's `SourceContext.text`
//!   slice still points at the first file's bytes until the renderer
//!   learns about multi-file context — a known cosmetic gap for
//!   non-first-file errors).

const std = @import("std");

const Reader = @import("../eval/reader.zig").Reader;
const analyzeForm = @import("../eval/analyzer/analyzer.zig").analyze;
const macro_dispatch = @import("../eval/macro_dispatch.zig");
const driver = @import("../eval/driver.zig");
const primitive = @import("primitive.zig");
const macro_transforms = @import("macro_transforms.zig");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const Value = @import("../runtime/value/value.zig").Value;
const error_context = @import("../runtime/error/context.zig");
const map_collection = @import("../runtime/collection/map.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const uuid_prim = @import("primitive/uuid.zig");

/// One entry in the bootstrap file table. `label` is the synthetic
/// source label the renderer attributes to errors raised while
/// evaluating this file (e.g. `<bootstrap>` for `core.clj`,
/// `<clojure.string>` for `string.clj`).
pub const FileEntry = struct {
    label: []const u8,
    source: []const u8,
};

/// Bootstrap source table — load order matters. `core.clj` must be
/// first because it lands `(def not ...)` and the future
/// `clojure.core` companions that subsequent files may reference.
/// Each non-first file is expected to open with `(in-ns 'foo.bar)`.
pub const FILES: []const FileEntry = &.{
    .{ .label = "<bootstrap>", .source = @embedFile("clj/clojure/core.clj") },
    .{ .label = "<clojure.string>", .source = @embedFile("clj/clojure/string.clj") },
    .{ .label = "<clojure.set>", .source = @embedFile("clj/clojure/set.clj") },
    .{ .label = "<clojure.walk>", .source = @embedFile("clj/clojure/walk.clj") },
    .{ .label = "<clojure.zip>", .source = @embedFile("clj/clojure/zip.clj") },
    .{ .label = "<clojure.edn>", .source = @embedFile("clj/clojure/edn.clj") },
    .{ .label = "<clojure.data.json>", .source = @embedFile("clj/clojure/data/json.clj") },
    .{ .label = "<clojure.data.csv>", .source = @embedFile("clj/clojure/data/csv.clj") },
    .{ .label = "<clojure.tools.cli>", .source = @embedFile("clj/clojure/tools/cli.clj") },
    .{ .label = "<clojure.pprint>", .source = @embedFile("clj/clojure/pprint.clj") },
    .{ .label = "<clojure.test>", .source = @embedFile("clj/clojure/test.clj") },
    .{ .label = "<cljw.error>", .source = @embedFile("clj/cljw/error.clj") },
    // clojure.data calls clojure.set/* fully-qualified, so it loads last
    // (after FILES[2] clojure.set has interned those vars).
    .{ .label = "<clojure.data>", .source = @embedFile("clj/clojure/data.clj") },
};

/// First file's source — exposed so `main.zig`'s renderer can fall
/// back to it when a bootstrap-time error fires (per D-058 the
/// renderer does not yet thread per-file context; this kept the
/// renderer call sites unchanged from the single-file era).
pub const CORE_SOURCE: []const u8 = FILES[0].source;

/// First file's source label — same compatibility purpose as
/// `CORE_SOURCE`.
pub const SOURCE_LABEL: []const u8 = FILES[0].label;

/// Map a bootstrap-embedded namespace name (e.g. `clojure.set`) to
/// the corresponding `FileEntry`. Returns `null` for names the
/// embedded table does not cover. Pure lookup; no allocator use.
fn lookupEmbeddedFile(ns_name: []const u8) ?FileEntry {
    // Internal name table: bootstrap source file labels are
    // `<ns_name>`-shaped except for `<bootstrap>` aliasing
    // `clojure.core`. Keep the table here (not as a separate map)
    // so it stays paired with `FILES` for grep-discovery.
    if (std.mem.eql(u8, ns_name, "clojure.core")) return FILES[0];
    if (std.mem.eql(u8, ns_name, "clojure.string")) return FILES[1];
    if (std.mem.eql(u8, ns_name, "clojure.set")) return FILES[2];
    if (std.mem.eql(u8, ns_name, "clojure.walk")) return FILES[3];
    if (std.mem.eql(u8, ns_name, "clojure.zip")) return FILES[4];
    if (std.mem.eql(u8, ns_name, "clojure.edn")) return FILES[5];
    if (std.mem.eql(u8, ns_name, "clojure.data.json")) return FILES[6];
    if (std.mem.eql(u8, ns_name, "clojure.data.csv")) return FILES[7];
    if (std.mem.eql(u8, ns_name, "clojure.tools.cli")) return FILES[8];
    if (std.mem.eql(u8, ns_name, "clojure.pprint")) return FILES[9];
    if (std.mem.eql(u8, ns_name, "clojure.test")) return FILES[10];
    if (std.mem.eql(u8, ns_name, "cljw.error")) return FILES[11];
    if (std.mem.eql(u8, ns_name, "clojure.data")) return FILES[12];
    return null;
}

/// ADR-0035 D8 embedded resolver: serves the 4 bootstrap
/// namespaces (`clojure.core` / `clojure.set` / `clojure.string` /
/// `clojure.walk`) from `@embedFile`'d byte slices. Returns `null`
/// for everything else — the caller (`requireOne`) maps `null` to
/// `lib_not_found`. Phase 12+ adds a `cljw_path` resolver that
/// swaps this slot; Phase 16+ adds a Wasm pod resolver.
pub fn embeddedResolver(
    rt: *Runtime,
    ns_name: []const u8,
) anyerror!?[]const u8 {
    _ = rt;
    if (lookupEmbeddedFile(ns_name)) |entry| return entry.source;
    return null;
}

/// Install `embeddedResolver` onto `rt.require_resolver`. Called at
/// boot from `main.zig` after `Runtime.init`. Tests that exercise
/// the resolver directly call this themselves.
pub fn installEmbeddedResolver(rt: *Runtime) void {
    rt.require_resolver = embeddedResolver;
}

/// Iterate `FILES`, read + analyse + evaluate each form, and reset
/// `current_ns` to `user/` at the end so REPL / file-eval callers
/// see their expected starting namespace. Caller-supplied arena
/// holds Forms / Nodes for the duration; the GC owns Values.
pub fn loadCore(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    macro_table: *const macro_dispatch.Table,
) !void {
    try loadCoreFiles(arena, rt, env, macro_table, FILES);
    try finalizeUserNs(env);
}

/// Read+analyze+eval each `.clj` file in `files` (a sub-slice of `FILES`).
/// Extracted from `loadCore` so the AOT path (`setupCoreAot`) can restore
/// core.clj from bytecode and run only the remaining files from source.
fn loadCoreFiles(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    macro_table: *const macro_dispatch.Table,
    files: []const FileEntry,
) !void {
    for (files) |file| {
        // ADR-0035 D7: register the file's bytes so the renderer's
        // per-file SourceContext lookup hits during bootstrap-time
        // errors. Idempotent — re-running reuses the first-writer entry.
        try rt.registerSource(file.label, file.source);
        var reader = Reader.init(arena, file.source);
        while (true) {
            const form_opt = try reader.read();
            const form = form_opt orelse break;

            const node = try analyzeForm(arena, rt, env, null, form, macro_table);

            var locals: [driver.MAX_LOCALS]Value = [_]Value{.nil_val} ** driver.MAX_LOCALS;
            _ = try driver.evalForm(rt, env, &locals, arena, node);
        }
    }
}

/// ADR-0035 D9: each `.clj` head's `(ns foo (:refer-clojure))` installs the
/// clojure.core refer per file via evalNs; the `user/` REPL-prompt ns is
/// not a `.clj` file, so it gets the explicit refer + becomes current here.
/// Shared by the source (`loadCore`) and AOT (`setupCoreAot`) paths so both
/// leave the env in the identical final state.
fn finalizeUserNs(env: *Env) !void {
    if (env.findNs("clojure.core")) |clojure_core_ns| {
        if (env.findNs("user")) |target| {
            try env.referAll(clojure_core_ns, target);
        }
    }
    if (env.findNs("user")) |user_ns| {
        env.current_ns = user_ns;
    }
}

/// Bootstrap an already-init'd runtime in one shared chain (F-009):
/// install the embedded require resolver, register the kernel primitives +
/// bootstrap macros, then load the `clojure.core` prologue. The CALLER
/// installs the backend vtable (tree_walk / vm) BEFORE calling this —
/// `loadCore`'s per-form eval needs it — and owns the rt/env/macro_table
/// lifetimes. The runner, the `cljw build` core, and the embedded-run
/// startup all share this instead of re-deriving the chain inline.
pub fn setupCore(arena: std.mem.Allocator, rt: *Runtime, env: *Env, macro_table: *macro_dispatch.Table) !void {
    try setupCorePrefix(rt, env, macro_table);
    try loadCore(arena, rt, env, macro_table);
    // cw v1's first dynamic var — interned after loadCore creates the
    // `cljw.error` ns (via the embedded file's `(in-ns ...)`), then the
    // raise-time snapshot provider is wired (ADR-0055 D2/D3).
    try error_context.register(env);
}

/// Intern `clojure.core/*data-readers*` (root `{}`) and
/// `*default-data-reader-fn*` (root `nil`) as `^:dynamic` Vars and cache
/// their pointers on the Runtime (ADR-0073). `formToValue`'s `.tagged` arm
/// reads them via `Var.deref()`, so a `(binding [*data-readers* …] …)`
/// frame or the `clojure.edn/read-string` 2-arity install is honoured. The
/// root tables are EMPTY — `#uuid`/`#inst` land with the value-type ADR.
/// Called from `setupCorePrefix` (BEFORE `loadCore`'s `finalizeUserNs`
/// `referAll`) so the unqualified `*data-readers*` is referred into `user`.
fn registerDataReaders(rt: *Runtime, env: *Env) !void {
    const core = try env.findOrCreateNs("clojure.core");
    // Root table carries the built-in `#uuid` reader (ADR-0074) so it works
    // without a `binding`; `#inst` joins when its value-type ADR lands.
    const sym_uuid = try symbol_mod.intern(rt, null, "uuid");
    const root_readers = try map_collection.assoc(rt, map_collection.empty(), sym_uuid, Value.initBuiltinFn(&uuid_prim.uuidReader));
    const dr = try env.intern(core, "*data-readers*", root_readers, null);
    dr.flags.dynamic = true;
    rt.data_readers_var = dr;
    const ddrf = try env.intern(core, "*default-data-reader-fn*", Value.nil_val, null);
    ddrf.flags.dynamic = true;
    rt.default_data_reader_fn_var = ddrf;
}

/// The bootstrap prefix WITHOUT `loadCore`: install the embedded require
/// resolver + register the kernel primitives + bootstrap macros. Splitting
/// this out lets the AOT-bootstrap path (ADR-0056) build a fresh env to
/// the same pre-`.clj`-eval state, then run the embedded bytecode envelope
/// (`driver.runEnvelope`) in place of `loadCore`'s parse+analyze+eval.
/// Macros + primitives are Zig-side, so they register identically on the
/// source-eval and AOT paths.
pub fn setupCorePrefix(rt: *Runtime, env: *Env, macro_table: *macro_dispatch.Table) !void {
    installEmbeddedResolver(rt);
    try primitive.registerAll(env);
    try macro_transforms.registerInto(env, macro_table);
    // D-197: borrow the entry point's table so the `eval` primitive's
    // `driver.evalValue` verb can analyse forms with the canonical macros.
    // The comment on `Runtime.macro_table` documented this but the
    // assignment was missing (eval was dead until D-197 wired it).
    rt.macro_table = macro_table;
    // ADR-0073: intern the data-reader dynamic vars here (before loadCore's
    // user-ns refer) so `*data-readers*` resolves unqualified in user code.
    try registerDataReaders(rt, env);
}

/// AOT bootstrap (ADR-0056 Cycle 2b): restore `clojure.core` from the
/// embedded bytecode envelope `core_blob` (no parse/analyze/eval of
/// core.clj — the edge cold-start win), then load the remaining `.clj`
/// files from source and finalize identically to `loadCore`. The caller
/// (a runtime startup path in exe_mod) passes `@import("bootstrap_cache").data`.
/// The build path keeps `setupCore` (source) — it can't use the blob to
/// build the blob. `core.clj` source is still registered so AOT-core error
/// frames keep their SourceContext.
pub fn setupCoreAot(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    macro_table: *macro_dispatch.Table,
    core_blob: []const u8,
) !void {
    try setupCorePrefix(rt, env, macro_table);
    try loadCoreAot(arena, rt, env, macro_table, core_blob);
    try error_context.register(env);
}

/// The AOT analog of `loadCore` (no prefix, no error_context — same scope
/// as `loadCore`): restore clojure.core from `core_blob`, load the
/// remaining `.clj` files from source, finalize the user ns. Callers that
/// already ran their own prefix (the REPL / nREPL) use this directly, just
/// as they used `loadCore`; `setupCoreAot` is prefix + this + error_context.
pub fn loadCoreAot(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    macro_table: *const macro_dispatch.Table,
    core_blob: []const u8,
) !void {
    try rt.registerSource(FILES[0].label, FILES[0].source);
    try driver.runEnvelope(rt, env, arena, core_blob);
    try loadCoreFiles(arena, rt, env, macro_table, FILES[1..]);
    try finalizeUserNs(env);
}

// --- tests ---

const testing = std.testing;

const Fixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,
    env: Env,
    arena: std.heap.ArenaAllocator,
    table: macro_dispatch.Table,

    fn init(self: *Fixture, alloc: std.mem.Allocator) !void {
        self.threaded = std.Io.Threaded.init(alloc, .{});
        self.rt = Runtime.init(self.threaded.io(), alloc);
        self.env = try Env.init(&self.rt);
        self.arena = std.heap.ArenaAllocator.init(alloc);
        self.table = macro_dispatch.Table.init(alloc);

        driver.installVTable(&self.rt);
        try primitive.registerAll(&self.env);
        try macro_transforms.registerInto(&self.env, &self.table);
    }

    fn deinit(self: *Fixture) void {
        self.table.deinit();
        self.arena.deinit();
        self.env.deinit();
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "loadCore evaluates `(def not ...)` so 'not' resolves in user/" {
    var fix: Fixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try loadCore(fix.arena.allocator(), &fix.rt, &fix.env, &fix.table);

    const user = fix.env.findNs("user") orelse return error.TestUnexpectedResult;
    const not_var = user.resolve("not") orelse return error.TestUnexpectedResult;
    try testing.expect(!not_var.root.isNil());
}

test "loadCore leaves current_ns at user/ after multi-file load" {
    var fix: Fixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try loadCore(fix.arena.allocator(), &fix.rt, &fix.env, &fix.table);

    try testing.expect(fix.env.current_ns != null);
    try testing.expectEqualStrings("user", fix.env.current_ns.?.name);
}

test "loadCore pulls in clojure.string namespace (ADR-0032 + Phase 6.9)" {
    var fix: Fixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try loadCore(fix.arena.allocator(), &fix.rt, &fix.env, &fix.table);

    const cs = fix.env.findNs("clojure.string") orelse return error.TestUnexpectedResult;
    try testing.expect(cs.resolve("upper-case") != null);
    try testing.expect(cs.resolve("lower-case") != null);
    try testing.expect(cs.resolve("blank?") != null);
}

test "embeddedResolver serves the 4 bootstrap namespaces (ADR-0035 D8)" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const core = try embeddedResolver(&rt, "clojure.core") orelse return error.TestUnexpectedResult;
    try testing.expect(core.len > 0);
    // The first form is the `(ns clojure.core (:refer-clojure))`
    // head landed at Phase 6.16.b-4 sub-cycle d (ADR-0035 D9
    // discharge) — confirms we returned the right source.
    try testing.expect(std.mem.find(u8, core, "(ns clojure.core") != null);

    const set = try embeddedResolver(&rt, "clojure.set") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.find(u8, set, "(ns clojure.set") != null);
    const string = try embeddedResolver(&rt, "clojure.string") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.find(u8, string, "(ns clojure.string") != null);
    const walk = try embeddedResolver(&rt, "clojure.walk") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.find(u8, walk, "(ns clojure.walk") != null);
}

test "embeddedResolver returns null for unknown namespaces" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    try testing.expect((try embeddedResolver(&rt, "no.such.ns")) == null);
    try testing.expect((try embeddedResolver(&rt, "")) == null);
    try testing.expect((try embeddedResolver(&rt, "clojure")) == null);
}

test "installEmbeddedResolver sets rt.require_resolver" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    try testing.expect(rt.require_resolver == null);
    installEmbeddedResolver(&rt);
    try testing.expect(rt.require_resolver != null);

    // Round-trip the installed resolver through the slot.
    const core = try rt.require_resolver.?(&rt, "clojure.core") orelse return error.TestUnexpectedResult;
    try testing.expect(core.len > 0);
}
