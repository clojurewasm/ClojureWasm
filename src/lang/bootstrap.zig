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
//! ### Loader contract
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
const build_options = @import("build_options");

const Reader = @import("../eval/reader.zig").Reader;
const macro_dispatch = @import("../eval/macro_dispatch.zig");
const driver = @import("../eval/driver.zig");
const primitive = @import("primitive.zig");
const macro_transforms = @import("macro_transforms.zig");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const ResolvedSource = @import("../runtime/runtime.zig").ResolvedSource;
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const Value = @import("../runtime/value/value.zig").Value;
const error_context = @import("../runtime/error/context.zig");
const map_collection = @import("../runtime/collection/map.zig");
const symbol_mod = @import("../runtime/symbol.zig");
const print_mod = @import("../runtime/print.zig");
const writer_value = @import("../runtime/writer_value.zig");
const uuid_prim = @import("primitive/uuid.zig");
const inst_prim = @import("primitive/inst.zig");
const startup_profile = @import("../runtime/startup_profile.zig");
const serialize = @import("../eval/bytecode/serialize.zig");

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
/// Namespaces replayed EAGERLY at startup (ADR-0163 D-516) — exactly the set JVM
/// Clojure makes usable WITHOUT an explicit `require` (measured via
/// `(find-ns 'X)` in a fresh `clj`: clojure.core + the set clojure.core/spec.alpha
/// transitively load). Eager-loading exactly these keeps `clojure.string/upper-case`
/// etc. working require-free (F-011 parity); every OTHER bootstrap ns is lazy — a
/// `require` is needed, matching clj (e.g. clj's `clojure.set` is NOT auto-loaded
/// either). `clojure.spec.alpha`'s own deps (spec.gen.alpha / core.specs.alpha) load
/// transitively when its eager region's `(:require …)` runs. Run in FILES order.
pub const EAGER_NS = std.StaticStringMap(void).initComptime(.{
    .{"clojure.core"},      .{"clojure.string"},  .{"clojure.walk"},
    .{"clojure.edn"},       .{"clojure.java.io"}, .{"clojure.core.protocols"},
    .{"clojure.uuid"},      .{"clojure.instant"}, .{"clojure.spec.alpha"},
    .{"clojure.core-meta"},
    // cljw-SPECIFIC (not in clj's auto-set): the Wasm-component `:require` desugar
    // (ADR-0135 am1) emits `(cljw.wasm/require-component-libspec …)` which is resolved
    // at ANALYZE time — before its own `(require 'cljw.wasm)` prelude EVALs — so the
    // ns must already be loaded. Eager (91 lines, def-only top level — its `wasm/`
    // primitive refs are resolved at call time, so loading is safe in any build).
    .{"cljw.wasm"},
});

/// True when `ns_name` is eager-loaded at startup (see `EAGER_NS`).
pub fn isEagerNs(ns_name: []const u8) bool {
    return EAGER_NS.has(ns_name);
}

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
    // clojure.math — thin Math wrappers; appended last so earlier FILES[N]
    // indices in `lookupEmbeddedFile` stay stable (D-232).
    .{ .label = "<clojure.math>", .source = @embedFile("clj/clojure/math.clj") },
    // clojure.core.protocols (D-282) — reduce/datafy protocol surface; require-on-
    // demand (lookupEmbeddedFile), needed by deftypes implementing IKVReduce etc.
    .{ .label = "<clojure.core.protocols>", .source = @embedFile("clj/clojure/core/protocols.clj") },
    // clojure.template — do-template / apply-template over clojure.walk; loads
    // after walk (FILES[3]). Surfaced by honeysql's honey.sql require.
    .{ .label = "<clojure.template>", .source = @embedFile("clj/clojure/template.clj") },
    // clojure.java.io — file/stream I/O over the java.io.File host type (ADR-0126);
    // appended last so earlier FILES[N] indices in `lookupEmbeddedFile` stay stable.
    .{ .label = "<clojure.java.io>", .source = @embedFile("clj/clojure/java/io.clj") },
    // cljw.json / cljw.fs — handy cljw.* wrappers over data.json + clojure.java.io
    // (ADR-0126 Cycle 7); load after their targets (data.json/walk/clojure.java.io).
    .{ .label = "<cljw.json>", .source = @embedFile("clj/cljw/json.clj") },
    .{ .label = "<cljw.fs>", .source = @embedFile("clj/cljw/fs.clj") },
    // clojure.stacktrace (D-273) — pure-Clojure cause-chain printer over the
    // ex-info model; appended last so earlier FILES[N] indices stay stable.
    .{ .label = "<clojure.stacktrace>", .source = @embedFile("clj/clojure/stacktrace.clj") },
    // clojure.uuid (D-273) — require-compat shim; the #uuid reader + UUID print
    // are cljw built-ins. Appended last so earlier FILES[N] indices stay stable.
    .{ .label = "<clojure.uuid>", .source = @embedFile("clj/clojure/uuid.clj") },
    // clojure.instant (D-273) — read-instant-* over the built-in #inst parser;
    // single Date type (no Timestamp/Calendar = AD-030). Appended last.
    .{ .label = "<clojure.instant>", .source = @embedFile("clj/clojure/instant.clj") },
    // clojure.test.tap (D-273) — TAP reporter for clojure.test; loads after
    // clojure.test (FILES[10]) + clojure.stacktrace (FILES[19]). Appended last.
    .{ .label = "<clojure.test.tap>", .source = @embedFile("clj/clojure/test/tap.clj") },
    // cljw.wasm (W1, D-404) — require-a-component over the wasm/ primitives.
    // Require-on-demand AND wasm-gated (the lookup below only serves it under
    // `-Dwasm`, since the wasm/ ns it rides is absent otherwise). Appended last.
    .{ .label = "<cljw.wasm>", .source = @embedFile("clj/cljw/wasm.clj") },
    // clojure.spec.gen.alpha + clojure.spec.alpha — official stdlib (ships in
    // clojure.jar), so eager-bundled (the stdlib-eager / contrib-completeness
    // policy). gen loads FIRST (alpha `(:require clojure.spec.gen.alpha)`).
    // Reproduced from spec.alpha with 4 no-JVM adaptations (see each file's header).
    // Appended last so earlier FILES[N] indices stay stable. The list stays
    // data-driven so a future eager→lazy switch (lazy-AOT, deferred) is local.
    .{ .label = "<clojure.spec.gen.alpha>", .source = @embedFile("clj/clojure/spec/gen/alpha.clj") },
    .{ .label = "<clojure.spec.alpha>", .source = @embedFile("clj/clojure/spec/alpha.clj") },
    // clojure.core.specs.alpha — official stdlib (ships in clojure.jar); specs
    // for clojure.core macros. Loads after spec.alpha (it `(:require …spec.alpha)`).
    // Verbatim upstream (no adaptations). Appended last.
    .{ .label = "<clojure.core.specs.alpha>", .source = @embedFile("clj/clojure/core/specs/alpha.clj") },
    // clojure.datafy — official stdlib (datafy/nav over core.protocols). Loads
    // after clojure.core.protocols (FILES[14]). One no-JVM adaptation (the
    // warn-on-reflection set! dropped); its Datafiable extend over IRef/Namespace/
    // Throwable/Class rides D-478. Re-landed once D-481 (gc.deinit ordering) fixed.
    .{ .label = "<clojure.datafy>", .source = @embedFile("clj/clojure/datafy.clj") },
    // clojure.test.junit — official stdlib (JUnit-XML reporter extending
    // clojure.test's `report` multimethod, like clojure.test.tap). Loads after
    // clojure.test (FILES[10]). Verbatim upstream. Appended last.
    .{ .label = "<clojure.test.junit>", .source = @embedFile("clj/clojure/test/junit.clj") },
    .{ .label = "<clojure.core-meta>", .source = @embedFile("clj/clojure/core_meta.clj") },
    // clojure.repl (D-513) — doc/dir/apropos/find-doc/demunge over the D-305
    // :doc/:arglists metadata; require-on-demand (NOT eager). Appended last.
    .{ .label = "<clojure.repl>", .source = @embedFile("clj/clojure/repl.clj") },
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
    if (std.mem.eql(u8, ns_name, "clojure.math")) return FILES[13];
    if (std.mem.eql(u8, ns_name, "clojure.core.protocols")) return FILES[14];
    if (std.mem.eql(u8, ns_name, "clojure.template")) return FILES[15];
    if (std.mem.eql(u8, ns_name, "clojure.java.io")) return FILES[16];
    if (std.mem.eql(u8, ns_name, "cljw.json")) return FILES[17];
    if (std.mem.eql(u8, ns_name, "cljw.fs")) return FILES[18];
    if (std.mem.eql(u8, ns_name, "clojure.stacktrace")) return FILES[19];
    if (std.mem.eql(u8, ns_name, "clojure.uuid")) return FILES[20];
    if (std.mem.eql(u8, ns_name, "clojure.instant")) return FILES[21];
    if (std.mem.eql(u8, ns_name, "clojure.test.tap")) return FILES[22];
    // cljw.wasm rides the `wasm/` primitive ns, which only exists in a `-Dwasm`
    // build — so it is resolvable only there (a non-wasm build reports the ns as
    // not found, honest, rather than failing on an unresolvable `wasm/…` later).
    if (build_options.wasm and std.mem.eql(u8, ns_name, "cljw.wasm")) return FILES[23];
    if (std.mem.eql(u8, ns_name, "clojure.spec.gen.alpha")) return FILES[24];
    if (std.mem.eql(u8, ns_name, "clojure.spec.alpha")) return FILES[25];
    if (std.mem.eql(u8, ns_name, "clojure.core.specs.alpha")) return FILES[26];
    if (std.mem.eql(u8, ns_name, "clojure.datafy")) return FILES[27];
    if (std.mem.eql(u8, ns_name, "clojure.test.junit")) return FILES[28];
    return null;
}

/// ADR-0035 D8 embedded resolver: serves the bootstrap-embedded namespaces
/// (clojure.core/string/set/walk/zip/edn/data.json/csv/tools.cli/pprint/test/
/// cljw.error/data — see `FILES`) from `@embedFile`'d byte slices, as a
/// `ResolvedSource{source, label}`. Returns `null` for everything else. Per
/// ADR-0084 the CLI wraps this in `require_resolver.chainedResolver`
/// (embedded-FIRST, then the filesystem) so user libs load off disk while these
/// can never be shadowed; Phase 16+ adds a Wasm pod resolver to the chain.
pub fn embeddedResolver(
    rt: *Runtime,
    ns_name: []const u8,
) anyerror!?ResolvedSource {
    _ = rt;
    if (lookupEmbeddedFile(ns_name)) |entry|
        return .{ .source = entry.source, .label = entry.label };
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
    // ADR-0163: pre-register before the source files eval so each file's
    // intra-bootstrap `(:require other-bootstrap-lib)` is a loaded_libs no-op
    // (mirrors the AOT path; without it the new loadOrFindNs guard re-parses).
    try markFilesLoaded(rt, FILES);
    try loadCoreFiles(arena, rt, env, macro_table, FILES);
    try finalizeUserNs(rt, env);
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
        var locals: [driver.MAX_LOCALS]Value = [_]Value{.nil_val} ** driver.MAX_LOCALS;
        while (true) {
            const form_opt = try reader.read();
            const form = form_opt orelse break;
            // D-374: unroll a top-level `(do …)` (clj parity); semantically a
            // no-op for the hand-written core (no effect-dependent top-level do),
            // kept here so every form-loading path shares one rule.
            _ = try driver.evalTopLevelForm(rt, env, &locals, arena, form, macro_table);
        }
    }
}

/// ADR-0035 D9: each `.clj` head's `(ns foo (:refer-clojure))` installs the
/// clojure.core refer per file via evalNs; the `user/` REPL-prompt ns is
/// not a `.clj` file, so it gets the explicit refer + becomes current here.
/// Shared by the source (`loadCore`) and AOT (`setupCoreAot`) paths so both
/// leave the env in the identical final state.
fn finalizeUserNs(rt: *Runtime, env: *Env) !void {
    if (env.findNs("clojure.core")) |clojure_core_ns| {
        if (env.findNs("user")) |target| {
            // Refresh user's refers after core.clj finished loading (the
            // boot-time refer ran before the .clj defs existed; overriding
            // keeps any collision pointing at the final Var).
            try env.referAllOverriding(clojure_core_ns, target, &.{}, null);
        }
    }
    if (env.findNs("user")) |user_ns| {
        env.setCurrentNs(user_ns);
    }
    // O-031: re-cache the arith intrinsics now that core.clj is fully loaded, so
    // the `.clj`-defined ops (`not=`) are interned and recognised by the VM
    // compiler. setupCorePrefix's earlier pass only saw the Zig builtins
    // (+/-/*/<.../mod/rem/quot); `not=` did not exist yet. Re-resolving is safe:
    // core.clj does NOT redefine any arith op, so every builtin slot re-resolves
    // to the same referred Var (idempotent), and the `not=` slot fills in.
    cacheArithIntrinsics(rt, env);
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
    try installPrintMethod(rt, env);
    // cw v1's first dynamic var — interned after loadCore creates the
    // `cljw.error` ns (via the embedded file's `(in-ns ...)`), then the
    // raise-time snapshot provider is wired (ADR-0055 D2/D3).
    try error_context.register(env);
    try installBaselineBindings(arena, env);
}

/// Cache the `clojure.core/print-method` Var (D-370, ADR-0127), AFTER core.clj
/// defines the defmulti, so the native pr path can consult it. The writer-handle
/// descriptor is a comptime static (writer_value.zig), so nothing to init here.
fn installPrintMethod(rt: *Runtime, env: *Env) !void {
    _ = rt;
    writer_value.initWriterType();
    if (env.findNs("clojure.core")) |core| {
        print_mod.initPrintMethodVar(core.resolve("print-method"));
    }
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
    // Root table carries the built-in `#uuid` (ADR-0074) + `#inst` (ADR-0079,
    // → java.util.Date) readers so both work without a `binding`.
    const sym_uuid = try symbol_mod.intern(rt, null, "uuid");
    var root_readers = try map_collection.assoc(rt, map_collection.empty(), sym_uuid, Value.initBuiltinFn(&uuid_prim.uuidReader));
    const sym_inst = try symbol_mod.intern(rt, null, "inst");
    root_readers = try map_collection.assoc(rt, root_readers, sym_inst, Value.initBuiltinFn(&inst_prim.instReader));
    // `#queue (…)` — cljw extension (ADR-0087) so the queue print form
    // round-trips (clj has no `#queue` reader).
    const sym_queue = try symbol_mod.intern(rt, null, "queue");
    root_readers = try map_collection.assoc(rt, root_readers, sym_queue, Value.initBuiltinFn(&@import("primitive/collection.zig").queueReader));
    const dr = try env.intern(core, "*data-readers*", root_readers, null);
    dr.flags.dynamic = true;
    rt.data_readers_var = dr;
    const ddrf = try env.intern(core, "*default-data-reader-fn*", Value.nil_val, null);
    ddrf.flags.dynamic = true;
    rt.default_data_reader_fn_var = ddrf;
}

/// Intern `clojure.core/*ns*` as a `^:dynamic` Var holding the current namespace
/// as an `.ns` Value, and cache it on `env.ns_var` so `setCurrentNs` keeps the
/// root in sync (ADR-0083). Called from `setupCorePrefix` BEFORE `loadCore`'s
/// `finalizeUserNs` `referAll`, so unqualified `*ns*` is referred into `user`.
fn registerNsVar(env: *Env) !void {
    const core = try env.findOrCreateNs("clojure.core");
    const cur = env.current_ns orelse core;
    const nv = try env.intern(core, "*ns*", Env.nsValue(cur), null);
    nv.flags.dynamic = true;
    env.ns_var = nv;
}

/// Intern `clojure.core/*agent*` as a `^:dynamic` Var (root nil) and cache it on
/// `rt.agent_var` so the agent drainer can bind it to the running agent around
/// each action body (clj `binding [*agent* a]`; ADR-0155 / D-442). Called from
/// `setupCorePrefix` BEFORE `loadCore`'s `finalizeUserNs` `referAll`, so
/// unqualified `*agent*` resolves in user code.
fn registerAgentVar(rt: *Runtime, env: *Env) !void {
    const core = try env.findOrCreateNs("clojure.core");
    const av = try env.intern(core, "*agent*", Value.nil_val, null);
    av.flags.dynamic = true;
    rt.agent_var = av;
}

/// Intern `clojure.core/*math-context*` `^:dynamic` (root nil) + cache it on
/// `rt.math_context_var` so BigDecimal division can read the `with-precision`
/// binding (D-467). Called from `setupCorePrefix` before the user-ns refer.
fn registerMathContextVar(rt: *Runtime, env: *Env) !void {
    const core = try env.findOrCreateNs("clojure.core");
    const mc = try env.intern(core, "*math-context*", Value.nil_val, null);
    mc.flags.dynamic = true;
    rt.math_context_var = mc;
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
    // ADR-0083: intern *ns* + cache on env.ns_var before the user-ns refer.
    try registerNsVar(env);
    // ADR-0155 / D-442: intern *agent* + cache on rt.agent_var before the
    // user-ns refer so the drainer can bind it inside each action body.
    try registerAgentVar(rt, env);
    // D-467: intern *math-context* + cache on rt.math_context_var so BigDecimal
    // division can honour a `with-precision` binding.
    try registerMathContextVar(rt, env);
    // ADR-0088: intern *print-length* / *print-level* (root nil = unlimited)
    // + cache pointers so the renderer honours a user `binding`.
    try registerPrintLimitVars(rt, env);
    // ADR-0130: cache clojure.core/+ for the arithmetic-intrinsic fast path.
    cacheArithIntrinsics(rt, env);
}

/// ADR-0130: cache the canonical `clojure.core` arith/comparison Vars (+ - * <
/// <= > >= =) so the VM compiler recognises `(<op> a b)` by pointer identity and
/// emits the matching intrinsic opcode. Each is interned in `rt/` and referred
/// into `clojure.core`, so `resolve` finds the same Var from either ns. A null
/// slot (op absent) means the compiler never emits that opcode. Sets pristine =
/// true; `alter-var-root` on any cached op clears it.
pub fn cacheArithIntrinsics(rt: *Runtime, env: *Env) void {
    const intrinsic = @import("../eval/backend/intrinsic.zig");
    const core = env.findNs("clojure.core");
    inline for (std.meta.tags(intrinsic.ArithOp)) |op| {
        const name = intrinsic.coreName(op);
        const v: ?*env_mod.Var = if (core) |c| c.resolve(name) else null;
        if (v) |p| rt.arith_vars[@intFromEnum(op)] = p;
    }
    rt.core_arith_pristine = true;

    // Collection-accessor intrinsics (op_get / op_nth; ADR-0130 extended, O-043).
    inline for (std.meta.tags(intrinsic.CollOp)) |op| {
        const name = intrinsic.collCoreName(op);
        const v: ?*env_mod.Var = if (core) |c| c.resolve(name) else null;
        if (v) |p| rt.coll_vars[@intFromEnum(op)] = p;
    }
    rt.core_coll_pristine = true;
}

/// Intern `clojure.core/*print-length*` and `*print-level*` as `^:dynamic`
/// Vars (root nil = unlimited) and cache their pointers in `print.zig` so the
/// pure renderer reads the user's current binding via `Var.deref()` (ADR-0088).
/// Interned in the prefix (before `loadCore`'s user-ns refer) so they resolve
/// unqualified in user code, uniformly across the source + AOT paths.
fn registerPrintLimitVars(rt: *Runtime, env: *Env) !void {
    _ = rt;
    const core = try env.findOrCreateNs("clojure.core");
    const len_v = try env.intern(core, "*print-length*", Value.nil_val, null);
    len_v.flags.dynamic = true;
    const lvl_v = try env.intern(core, "*print-level*", Value.nil_val, null);
    lvl_v.flags.dynamic = true;
    // *print-namespace-maps* root true (clj `-e`/REPL default); a false binding
    // disables the compact `#:ns{…}` form (D-222 residual a).
    const nsmaps_v = try env.intern(core, "*print-namespace-maps*", Value.true_val, null);
    nsmaps_v.flags.dynamic = true;
    // *print-readably* root true (pr/prn default); a false binding makes pr emit
    // the raw (print-style) form (D-222 residual a).
    const readably_v = try env.intern(core, "*print-readably*", Value.true_val, null);
    readably_v.flags.dynamic = true;
    // *print-meta* root false; a truthy binding prefixes metadata-bearing values.
    const meta_v = try env.intern(core, "*print-meta*", Value.false_val, null);
    meta_v.flags.dynamic = true;
    // *print-dup* root false (D-222 residual c). A false binding prints
    // normally; a TRUE binding fail-louds at the pr surface — clj emits JVM
    // `#=(class/create …)` ctor forms cljw cannot represent (ADR-0059).
    const dup_v = try env.intern(core, "*print-dup*", Value.false_val, null);
    dup_v.flags.dynamic = true;
    // *flush-on-newline* root true (D-222 residual c). cljw's text_io writers
    // flush per call, so the true contract always holds; a false binding
    // permits (does not require) buffering — flushing anyway is a valid
    // implementation, so no Zig-side consumer exists.
    const fon_v = try env.intern(core, "*flush-on-newline*", Value.true_val, null);
    fon_v.flags.dynamic = true;
    print_mod.initPrintLimitVars(len_v, lvl_v, nsmaps_v, readably_v, meta_v, dup_v);
}

/// ADR-0096: push a process-lifetime baseline binding frame (clojure.main
/// parity) thread-binding the standard config / print dynamic vars to their
/// roots, so `(set! *warn-on-reflection* true)` & co. work at top level (the
/// var is genuinely thread-bound) — while `set!` on an unbound user var raises.
/// `user_pushed = false` protects it from `pop-thread-bindings` (a stray pop
/// correctly raises unmatched). Arena-owned (the frame + its map ride the
/// bootstrap arena, freed wholesale at teardown — no per-entry free). Excludes
/// `*ns*` (materialized-view machinery, ADR-0085) and `*out*/*in*/*err*`
/// (D-238). Standard vars cljw lacks (`*assert*`, `*math-context*`, …) are NOT
/// fabricated — they land with their features (D-241 stays open for them).
fn installBaselineBindings(arena: std.mem.Allocator, env: *Env) !void {
    const core = try env.findOrCreateNs("clojure.core");
    const names = [_][]const u8{
        "*warn-on-reflection*", "*unchecked-math*",
        "*print-meta*",         "*print-length*",
        "*print-level*",        "*print-namespace-maps*",
        "*data-readers*",       "*default-data-reader-fn*",
        "*print-dup*",          "*flush-on-newline*",
        // D-241: clojure.main's with-bindings set also thread-binds these,
        // so top-level `(set! *assert* false)` works like the JVM REPL.
        "*assert*",             "*math-context*",
    };
    const frame = try arena.create(env_mod.BindingFrame);
    frame.* = .{};
    for (names) |nm| {
        const v = core.resolve(nm) orelse continue;
        try frame.bindings.put(arena, v, v.root);
    }
    env_mod.pushFrame(frame);
}

/// AOT bootstrap (ADR-0056 Cycle 2b + Cycle 3 / D-452 Part B): restore the WHOLE
/// eager bootstrap (`clojure.core` + the 23 non-core bundled `.clj` libs) from
/// the embedded bytecode envelope `bootstrap_blob` — no parse/analyze/eval of
/// ANY bundled `.clj` (the edge cold-start win), finalizing identically to
/// `loadCore`. The caller (a runtime startup path in exe_mod) passes
/// `@import("bootstrap_cache").data`. The build path keeps `setupCore` (source)
/// — it can't use the blob to build the blob. Every bundled file's source is
/// still registered so AOT error frames keep their SourceContext.
pub fn setupCoreAot(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    macro_table: *macro_dispatch.Table,
    bootstrap_blob: []const u8,
) !void {
    var prof = startup_profile.Profiler.start(rt.io);
    try setupCorePrefix(rt, env, macro_table);
    prof.mark("  prefix(registerAll)");
    try loadCoreAot(arena, rt, env, bootstrap_blob);
    prof.mark("  loadCoreAot(envelope)");
    try installPrintMethod(rt, env);
    try error_context.register(env);
    try installBaselineBindings(arena, env);
    prof.mark("  print+errctx+baseline");
}

/// The AOT analog of `loadCore` (no prefix, no error_context — same scope
/// as `loadCore`): restore the WHOLE eager bootstrap (core + the 23 non-core
/// libs) from `bootstrap_blob`, finalize the user ns. Callers that already ran
/// their own prefix (the REPL / nREPL) use this directly, just as they used
/// `loadCore`; `setupCoreAot` is prefix + this + error_context.
pub fn loadCoreAot(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    bootstrap_blob: []const u8,
) !void {
    // D-452 Part B: `bootstrap_blob` is now the WHOLE eager bootstrap (core +
    // the 23 non-core libs), so the non-core libs no longer re-parse from
    // source every startup. Register every bundled file's source first so a
    // runtime error frame in an AOT-restored lib keeps its per-file
    // SourceContext (the bytecode carries none) — cheap (@embedFile slices into
    // a hashmap, no parse). `macro_table` is no longer needed: the blob is
    // post-macro bytecode, replayed by the VM without expansion.
    var prof = startup_profile.Profiler.start(rt.io);
    // ADR-0163 D-516: publish the region blob so loadOrFindNs can replay a lazy ns
    // on first require. Register EVERY file's source (cheap — a slice into a hashmap)
    // so a lazy ns's runtime error frame keeps its per-file SourceContext.
    rt.bootstrap_region_blob = bootstrap_blob;
    for (FILES) |file| try rt.registerSource(file.label, file.source);
    prof.mark("    registerSource");
    // ADR-0163 D-516: pre-register the EAGER set (EAGER_NS = clj's no-require set)
    // as loaded BEFORE running, so an intra-eager `(:require eager-lib)` is a no-op
    // (e.g. spec.alpha requires walk — both eager). Without this the loaded_libs
    // guard would re-parse. Run only the eager regions; every other ns replays from
    // its region on first `require` (loadOrFindNs → loadRegionNamespace).
    for (FILES) |file| {
        const ns_name = nsNameFromLabel(file.label);
        if (isEagerNs(ns_name)) try markOneLoaded(rt, ns_name);
    }
    // v7 (ADR-0173): the blob-level shared constant pool — parsed once for
    // the whole eager set; lazy requires re-parse per replay (cheap slice walk).
    var blob_pool = try serialize.readBlobPool(rt.gpa, bootstrap_blob);
    defer if (blob_pool) |*cp| cp.deinit(rt.gpa);
    for (FILES) |file| {
        const ns_name = nsNameFromLabel(file.label);
        if (!isEagerNs(ns_name)) continue;
        // A missing region means the embedded blob is malformed (build bug).
        const region = serialize.findRegion(bootstrap_blob, ns_name) orelse return error.MissingBootstrapRegion;
        try driver.runEnvelope(rt, env, arena, region, if (blob_pool) |*cp| cp else null);
    }
    prof.mark("    runEnvelope");
    try finalizeUserNs(rt, env);
    prof.mark("    finalizeUserNs");
}

/// Run each namespace region in `files` order from a multi-region `blob`
/// (ADR-0163). Each region is a self-contained envelope consumed via
/// `driver.runEnvelope`. Regions must run in dependency order so a later region's
/// `var_ref` to an earlier region's `def` resolves at run time. Shared by
/// `loadCoreAot` and the build-tool round-trip test.
pub fn runEagerRegions(rt: *Runtime, env: *Env, arena: std.mem.Allocator, blob: []const u8, files: []const FileEntry) !void {
    // v7 (ADR-0173): the blob-level shared constant pool, parsed once per run.
    var blob_pool = try serialize.readBlobPool(rt.gpa, blob);
    defer if (blob_pool) |*cp| cp.deinit(rt.gpa);
    for (files) |file| {
        const ns_name = nsNameFromLabel(file.label);
        // A missing region means the embedded blob is malformed (a build-time
        // bug, never user input) — fail loudly rather than silently skipping a ns.
        const region = serialize.findRegion(blob, ns_name) orelse return error.MissingBootstrapRegion;
        try driver.runEnvelope(rt, env, arena, region, if (blob_pool) |*cp| cp else null);
    }
}

/// Mark every namespace in `files` as loaded in `rt.loaded_libs` (ADR-0163).
/// The eager bootstrap paths (AOT `runEnvelope`, source `loadCoreFiles`, and the
/// build-time `buildBootstrapEnvelope`) bypass `loader.loadNamespace`, so their
/// namespaces are not otherwise recorded. Called BEFORE the files run so each
/// file's intra-bootstrap `(:require other-bootstrap-lib)` is a no-op. Keys are
/// gpa-owned (freed at `rt.deinit`), mirroring `loader.loadNamespace`. Takes a
/// slice so the lazy split (ADR-0163 commit 3) can pass only the trimmed eager set.
pub fn markFilesLoaded(rt: *Runtime, files: []const FileEntry) !void {
    for (files) |file| try markOneLoaded(rt, nsNameFromLabel(file.label));
}

/// Record a single namespace as loaded in `rt.loaded_libs` (idempotent). Key is
/// gpa-owned (freed at `rt.deinit`), mirroring `loader.loadNamespace`.
pub fn markOneLoaded(rt: *Runtime, ns_name: []const u8) !void {
    if (rt.loaded_libs.contains(ns_name)) return;
    const key = try rt.gpa.dupe(u8, ns_name);
    errdefer rt.gpa.free(key);
    try rt.loaded_libs.put(rt.gpa, key, {});
}

/// FileEntry labels are `<ns-name>` except core's, which is `<bootstrap>`. Map a
/// label to the namespace name used as the `require` / `loaded_libs` / region key.
pub fn nsNameFromLabel(label: []const u8) []const u8 {
    if (std.mem.eql(u8, label, "<bootstrap>")) return "clojure.core";
    if (label.len >= 2 and label[0] == '<' and label[label.len - 1] == '>')
        return label[1 .. label.len - 1];
    return label;
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
        // Full bootstrap prefix (registerAll + macros + data-readers + *ns* var
        // + embedded resolver), matching the real binary. test.clj's run-tests
        // / are reference *ns* / clojure.walk at def-time analysis, so the
        // prefix's registerNsVar is required (a bare registerAll is not enough).
        try setupCorePrefix(&self.rt, &self.env, &self.table);
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
    try testing.expect(core.source.len > 0);
    // The first form is the `(ns clojure.core (:refer-clojure))`
    // head landed at Phase 6.16.b-4 sub-cycle d (ADR-0035 D9
    // discharge) — confirms we returned the right source.
    try testing.expect(std.mem.find(u8, core.source, "(ns clojure.core") != null);

    const set = try embeddedResolver(&rt, "clojure.set") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.find(u8, set.source, "(ns clojure.set") != null);
    const string = try embeddedResolver(&rt, "clojure.string") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.find(u8, string.source, "(ns clojure.string") != null);
    const walk = try embeddedResolver(&rt, "clojure.walk") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.find(u8, walk.source, "(ns clojure.walk") != null);
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
    try testing.expect(core.source.len > 0);
}
