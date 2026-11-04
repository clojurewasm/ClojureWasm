// SPDX-License-Identifier: EPL-2.0
//! Stage-1 bootstrap — read+analyse+evaluate the embedded Clojure
//! source files (currently `clj/clojure/core.clj` and
//! `clj/clojure/string.clj`) after `primitive.registerAll` populates
//! the kernel namespaces and `macro_transforms.registerInto` populates
//! the analyzer's macro Table.
//!
//! ### Multi-file loader (ADR-0032)
//!
//! `loadCore` iterates `ACTIVE_FILES` — `FILES` (a flat table of
//! `{label, source, wasm_only}`) minus the entries this build's options
//! gate out. The loader carries **no** namespace knowledge — each `.clj`
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
const string_collection = @import("../runtime/collection/string.zig");
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
    /// The namespace this file defines. The load-bearing identity: it is what
    /// `require` looks up, what `loaded_libs` is keyed by, and what the region
    /// blob is keyed by. `label` is presentation.
    ns: []const u8,
    /// How the file names itself in an error frame / the sources blob —
    /// `<clojure.set>`. Derived from `ns` by `defaultLabel` except for
    /// `clojure.core`, which renders as `<bootstrap>`.
    label: []const u8,
    /// Raw source text — non-null only in `embed_raw_clj_sources` mode
    /// (cache_gen, the host tool). The shipped cljw carries the sources
    /// flate-compressed in the `bootstrap_sources` blob; read via
    /// `sourceText` (C5'-b, ADR-0173).
    source: ?[]const u8,
    /// The file rides the `wasm/` primitive namespace, which is registered
    /// only under `-Dwasm`. Its `wasm/…` call sites resolve at ANALYZE time,
    /// so a build without the flag cannot compile it at all.
    wasm_only: bool = false,
    /// The file rides the `cljw.ffi` leaves (`-open`, `-invoke`, ...), which
    /// are registered only where `build_options.ffi` is set (ADR-0202).
    ffi_only: bool = false,
};

/// Is `entry` part of THIS build's bundled set? The ONE predicate behind both
/// the walks (`ACTIVE_FILES`) and the resolver (`lookupEmbeddedFile`), so a
/// gated file can never be active in one and inactive in the other.
/// `<ns>` — the label a file gets unless it names itself otherwise.
fn defaultLabel(comptime ns: []const u8) []const u8 {
    return "<" ++ ns ++ ">";
}

/// One row of the bundled-source table. `ns` is the fact; the label follows
/// from it.
fn f(comptime ns: []const u8, comptime path: []const u8) FileEntry {
    return .{ .ns = ns, .label = defaultLabel(ns), .source = embedSrc(path) };
}

pub fn isActiveFile(entry: FileEntry) bool {
    return (build_options.wasm or !entry.wasm_only) and (build_options.ffi or !entry.ffi_only);
}

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
    // ns must already be loaded. Eager only where it EXISTS: its own `wasm/…` refs
    // are likewise analyze-time, so the file is `wasm_only` and leaves ACTIVE_FILES
    // (hence this eager set, which is only ever consulted per ACTIVE_FILES entry)
    // in a build without `-Dwasm`.
    .{"cljw.wasm"},
});

/// True when `ns_name` is eager-loaded at startup (see `EAGER_NS`).
pub fn isEagerNs(ns_name: []const u8) bool {
    return EAGER_NS.has(ns_name);
}

/// Raw @embedFile in cache_gen (raw mode); null in the shipped cljw, whose
/// text lives flate-compressed in the `bootstrap_sources` blob (C5'-b).
/// The comptime-known flag prunes the untaken branch, so the shipped binary
/// never embeds the raw bytes.
fn embedSrc(comptime path: []const u8) ?[]const u8 {
    return if (build_options.embed_raw_clj_sources) @embedFile(path) else null;
}

pub const FILES: []const FileEntry = &.{
    .{ .ns = "clojure.core", .label = "<bootstrap>", .source = embedSrc("clj/clojure/core.clj") },
    f("clojure.string", "clj/clojure/string.clj"),
    f("clojure.set", "clj/clojure/set.clj"),
    f("clojure.walk", "clj/clojure/walk.clj"),
    f("clojure.zip", "clj/clojure/zip.clj"),
    f("clojure.edn", "clj/clojure/edn.clj"),
    f("clojure.data.json", "clj/clojure/data/json.clj"),
    f("clojure.data.csv", "clj/clojure/data/csv.clj"),
    f("clojure.tools.cli", "clj/clojure/tools/cli.clj"),
    f("clojure.pprint", "clj/clojure/pprint.clj"),
    f("clojure.test", "clj/clojure/test.clj"),
    f("cljw.error", "clj/cljw/error.clj"),
    // clojure.data calls clojure.set/* fully-qualified, so it loads last
    // (after FILES[2] clojure.set has interned those vars).
    f("clojure.data", "clj/clojure/data.clj"),
    // clojure.math — thin Math wrappers; appended last so earlier FILES[N]
    // indices in `lookupEmbeddedFile` stay stable (D-232).
    f("clojure.math", "clj/clojure/math.clj"),
    // clojure.core.protocols (D-282) — reduce/datafy protocol surface; require-on-
    // demand (lookupEmbeddedFile), needed by deftypes implementing IKVReduce etc.
    f("clojure.core.protocols", "clj/clojure/core/protocols.clj"),
    // clojure.template — do-template / apply-template over clojure.walk; loads
    // after walk (FILES[3]). Surfaced by honeysql's honey.sql require.
    f("clojure.template", "clj/clojure/template.clj"),
    // clojure.java.io — file/stream I/O over the java.io.File host type (ADR-0126);
    // appended last so earlier FILES[N] indices in `lookupEmbeddedFile` stay stable.
    f("clojure.java.io", "clj/clojure/java/io.clj"),
    // cljw.json / cljw.fs — handy cljw.* wrappers over data.json + clojure.java.io
    // (ADR-0126 Cycle 7); load after their targets (data.json/walk/clojure.java.io).
    f("cljw.json", "clj/cljw/json.clj"),
    f("cljw.fs", "clj/cljw/fs.clj"),
    // clojure.stacktrace (D-273) — pure-Clojure cause-chain printer over the
    // ex-info model; appended last so earlier FILES[N] indices stay stable.
    f("clojure.stacktrace", "clj/clojure/stacktrace.clj"),
    // clojure.uuid (D-273) — require-compat shim; the #uuid reader + UUID print
    // are cljw built-ins. Appended last so earlier FILES[N] indices stay stable.
    f("clojure.uuid", "clj/clojure/uuid.clj"),
    // clojure.instant (D-273) — read-instant-* over the built-in #inst parser;
    // single Date type (no Timestamp/Calendar = AD-030). Appended last.
    f("clojure.instant", "clj/clojure/instant.clj"),
    // clojure.test.tap (D-273) — TAP reporter for clojure.test; loads after
    // clojure.test (FILES[10]) + clojure.stacktrace (FILES[19]). Appended last.
    f("clojure.test.tap", "clj/clojure/test/tap.clj"),
    // cljw.wasm (W1, D-404) — require-a-component over the wasm/ primitives.
    // Require-on-demand AND wasm-gated: `wasm_only` drops it from ACTIVE_FILES
    // and from the lookup below in a build without `-Dwasm`. Its `wasm/…` call
    // sites resolve at ANALYZE time, so a non-`-Dwasm` build cannot compile it
    // at all — the file must leave every walk, not merely the resolver.
    .{ .ns = "cljw.wasm", .label = defaultLabel("cljw.wasm"), .source = embedSrc("clj/cljw/wasm.clj"), .wasm_only = true },
    // clojure.spec.gen.alpha + clojure.spec.alpha — official stdlib (ships in
    // clojure.jar), so eager-bundled (the stdlib-eager / contrib-completeness
    // policy). gen loads FIRST (alpha `(:require clojure.spec.gen.alpha)`).
    // Reproduced from spec.alpha with 4 no-JVM adaptations (see each file's header).
    // Appended last so earlier FILES[N] indices stay stable. The list stays
    // data-driven so a future eager→lazy switch (lazy-AOT, deferred) is local.
    f("clojure.spec.gen.alpha", "clj/clojure/spec/gen/alpha.clj"),
    f("clojure.spec.alpha", "clj/clojure/spec/alpha.clj"),
    // clojure.core.specs.alpha — official stdlib (ships in clojure.jar); specs
    // for clojure.core macros. Loads after spec.alpha (it `(:require …spec.alpha)`).
    // Verbatim upstream (no adaptations). Appended last.
    f("clojure.core.specs.alpha", "clj/clojure/core/specs/alpha.clj"),
    // clojure.datafy — official stdlib (datafy/nav over core.protocols). Loads
    // after clojure.core.protocols (FILES[14]). One no-JVM adaptation (the
    // warn-on-reflection set! dropped); its Datafiable extend over IRef/Namespace/
    // Throwable/Class rides D-478. Re-landed once D-481 (gc.deinit ordering) fixed.
    f("clojure.datafy", "clj/clojure/datafy.clj"),
    // clojure.test.junit — official stdlib (JUnit-XML reporter extending
    // clojure.test's `report` multimethod, like clojure.test.tap). Loads after
    // clojure.test (FILES[10]). Verbatim upstream. Appended last.
    f("clojure.test.junit", "clj/clojure/test/junit.clj"),
    f("clojure.core-meta", "clj/clojure/core_meta.clj"),
    // clojure.repl (D-513) — doc/dir/apropos/find-doc/demunge over the D-305
    // :doc/:arglists metadata; require-on-demand (NOT eager). Appended last.
    f("clojure.repl", "clj/clojure/repl.clj"),
    // clojure.core.reducers (D-513 (1)) — the reducer/folder ops over IReduce,
    // plus a SEQUENTIAL fold (AD-058: no ForkJoinPool). require-on-demand; clj
    // does not auto-load it either, so eager here would break F-011 parity.
    f("clojure.core.reducers", "clj/clojure/core/reducers.clj"),
    // cljw.test — source-path test discovery + runner over clojure.test
    // (`cljw -m cljw.test`). Loads after clojure.test (FILES[10]) and cljw.fs;
    // require-on-demand. Appended last so earlier FILES[N] indices stay stable.
    f("cljw.test", "clj/cljw/test.clj"),
    // cljw.proxy (D-298) — runtime support for `clojure.core/proxy` over the
    // registered proxyable base classes (ThreadLocal is entry 1). deftype +
    // protocol, no JVM class extension; require-on-demand (the proxy macro
    // requiring-resolves it). Appended last so earlier FILES[N] indices stay stable.
    f("cljw.proxy", "clj/cljw/proxy.clj"),
    // clojure.java.shell (ADR-0199, D-273) — `sh` over the native
    // `cljw.process/run`, resolved at call time so a WASI build (no
    // cljw.process) still loads it. require-on-demand, as in clj. Appended last.
    f("clojure.java.shell", "clj/clojure/java/shell.clj"),
    // cljw.ffi (ADR-0202): the C FFI API over the native `cljw.ffi/-*` leaves.
    // require-on-demand AND ffi-gated: the leaves exist only where
    // `build_options.ffi` is set. Appended last.
    .{ .ns = "cljw.ffi", .label = defaultLabel("cljw.ffi"), .source = embedSrc("clj/cljw/ffi.clj"), .ffi_only = true },
};

/// The build-active subset of `FILES`. **Every walk that compiles, emits, or
/// replays bundled files iterates this, never `FILES`** — `FILES` keeps its
/// full shape (and its stable indices) so `lookupEmbeddedFile` stays index-keyed.
pub const ACTIVE_FILES: []const FileEntry = blk: {
    var active: [FILES.len]FileEntry = undefined;
    var n: usize = 0;
    for (FILES) |file| {
        if (!isActiveFile(file)) continue;
        active[n] = file;
        n += 1;
    }
    const frozen = active;
    break :blk frozen[0..n];
};

/// The bundled `.clj` text for `label` (C5'-b). Raw mode (cache_gen)
/// returns the embedded slice; the shipped cljw decompresses from the
/// `bootstrap_sources` blob into `rt.load_arena` (session lifetime — the
/// text backs SourceContext renders and source replays). Returns null for
/// labels outside the bundled set.
pub fn sourceText(rt: *Runtime, label: []const u8) ?[]const u8 {
    for (ACTIVE_FILES) |file| {
        if (!std.mem.eql(u8, file.label, label)) continue;
        if (file.source) |raw| return raw;
        break;
    }
    // Compressed mode: linear index scan of the sources blob
    // ([count u32] then per file: label, uncompressed_len, compressed bytes).
    const blob = @import("bootstrap_sources").data;
    if (blob.len < 4) return null;
    var pos: usize = 0;
    const count = std.mem.readInt(u32, blob[pos..][0..4], .little);
    pos += 4;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const label_len = std.mem.readInt(u32, blob[pos..][0..4], .little);
        pos += 4;
        const entry_label = blob[pos .. pos + label_len];
        pos += label_len;
        const ulen = std.mem.readInt(u32, blob[pos..][0..4], .little);
        pos += 4;
        const clen = std.mem.readInt(u32, blob[pos..][0..4], .little);
        pos += 4;
        const compressed = blob[pos .. pos + clen];
        pos += clen;
        if (std.mem.eql(u8, entry_label, label)) {
            return serialize.flateDecompress(rt.load_arena.allocator(), compressed, ulen) catch null;
        }
    }
    return null;
}

/// Registry-miss fallback installed onto `rt.source_resolver` (C5'-b): an
/// error render touching a bundled `.clj` decompresses its text on demand
/// and memoizes via `registerSource` so a repeat render is a registry hit.
fn resolveBundledSource(rt: *Runtime, label: []const u8) ?@import("../runtime/error/print.zig").SourceContext {
    const text = sourceText(rt, label) orelse return null;
    rt.registerSource(label, text) catch return .{ .file = label, .text = text };
    return rt.source_registry.get(label);
}

/// First file's label — the renderer's fallback SourceContext label for
/// bootstrap-time errors (the text itself now resolves through
/// `rt.source_resolver`, so the eager fallback carries no source bytes).
pub const SOURCE_LABEL: []const u8 = FILES[0].label;

/// Map a bootstrap-embedded namespace name (e.g. `clojure.set`) to
/// the corresponding `FileEntry`. Returns `null` for names the
/// embedded table does not cover. Pure lookup; no allocator use.
fn lookupEmbeddedFile(ns_name: []const u8) ?FileEntry {
    for (ACTIVE_FILES) |file| {
        if (std.mem.eql(u8, file.ns, ns_name)) return file;
    }
    return null;
}

// First match wins in every namespace lookup here — `lookupEmbeddedFile`, the
// region-blob key, `markFilesLoaded`. A duplicate `ns` would therefore shadow
// silently rather than fail. Neither this nor the hand-written table it
// replaced could detect that, so assert it where a violation is a compile
// error rather than a mystery at runtime.
comptime {
    @setEvalBranchQuota(FILES.len * FILES.len * 32);
    for (FILES, 0..) |a, i| {
        for (FILES[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.ns, b.ns))
                @compileError("two bundled files claim the namespace " ++ a.ns);
        }
    }
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
    if (lookupEmbeddedFile(ns_name)) |entry| {
        // C5'-b: decompress the bundled text on demand (session arena).
        const text = entry.source orelse (sourceText(rt, entry.label) orelse return error.MissingBootstrapSource);
        return .{ .source = text, .label = entry.label };
    }
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
    try markFilesLoaded(rt, ACTIVE_FILES);
    try loadCoreFiles(arena, rt, env, macro_table, ACTIVE_FILES);
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
        const text = file.source orelse (sourceText(rt, file.label) orelse return error.MissingBootstrapSource);
        try rt.registerSource(file.label, text);
        var reader = Reader.init(arena, text);
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

/// Intern `clojure.core/*file*` as a `^:dynamic` Var whose root is clj's exact
/// `"NO_SOURCE_PATH"` sentinel, and cache it on `rt.file_var`. JVM Clojure
/// reports that string when there is no source file (`clj -M -e '…'`), the
/// script path when one is run, and the classpath-relative resource name while
/// a namespace loads — all three verified against clj 2026-08-04. cljw had no
/// `*file*` at all, which is why the error renderer and any macro that wants
/// its own source location had nothing to read.
fn registerFileVar(rt: *Runtime, env: *Env) !void {
    const core = try env.findOrCreateNs("clojure.core");
    const sentinel = try string_collection.alloc(rt, "NO_SOURCE_PATH");
    const fv = try env.intern(core, "*file*", sentinel, null);
    fv.flags.dynamic = true;
    rt.file_var = fv;
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
    try registerFileVar(rt, env);
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
    // Unary inc/dec intrinsics share the arith pristine flag.
    inline for (std.meta.tags(intrinsic.UnaryOp)) |op| {
        const name = intrinsic.unaryCoreName(op);
        const v: ?*env_mod.Var = if (core) |c| c.resolve(name) else null;
        if (v) |p| rt.unary_vars[@intFromEnum(op)] = p;
    }
    rt.core_arith_pristine = true;

    // Collection-accessor intrinsics (op_get / op_nth; ADR-0130 extended, O-043).
    inline for (std.meta.tags(intrinsic.CollOp)) |op| {
        const name = intrinsic.collCoreName(op);
        const v: ?*env_mod.Var = if (core) |c| c.resolve(name) else null;
        if (v) |p| rt.coll_vars[@intFromEnum(op)] = p;
    }
    rt.core_coll_pristine = true;

    // *unchecked-math* (CLJW-UNCHECKED-MATH): cache the Var so the analyzer can
    // read its current value and rewrite pristine core arith to wrapping
    // unchecked-* ops while it is truthy. Resolved from clojure.core (interned
    // in core.clj); null if absent (the rewrite then never fires).
    if (core) |c| rt.unchecked_math_var = c.resolve("*unchecked-math*");
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
    // C5'-b: sources are flate-compressed in the shipped binary — install
    // the on-demand resolver instead of eagerly duplicating ~450KB of raw
    // text into gpa at every startup (errors are cold; first render pays
    // one decompress, then the registry memoizes).
    rt.source_resolver = &resolveBundledSource;
    prof.mark("    registerSource");
    // ADR-0163 D-516: pre-register the EAGER set (EAGER_NS = clj's no-require set)
    // as loaded BEFORE running, so an intra-eager `(:require eager-lib)` is a no-op
    // (e.g. spec.alpha requires walk — both eager). Without this the loaded_libs
    // guard would re-parse. Run only the eager regions; every other ns replays from
    // its region on first `require` (loadOrFindNs → loadRegionNamespace).
    for (ACTIVE_FILES) |file| {
        const ns_name = file.ns;
        if (isEagerNs(ns_name)) try markOneLoaded(rt, ns_name);
    }
    // v7 (ADR-0173): the blob-level shared constant pool — parsed once for
    // the whole eager set; lazy requires re-parse per replay (cheap slice walk).
    var blob_pool = try serialize.readBlobPool(rt.gpa, bootstrap_blob);
    defer if (blob_pool) |*cp| cp.deinit(rt.gpa);
    for (ACTIVE_FILES) |file| {
        const ns_name = file.ns;
        if (!isEagerNs(ns_name)) continue;
        // A missing region means the embedded blob is malformed (build bug).
        const ref = serialize.findRegion(bootstrap_blob, ns_name) orelse return error.MissingBootstrapRegion;
        // Eager regions are stored RAW by construction (builder flags only
        // the lazy set) — a compressed eager region is a build bug.
        if (ref.compressed) return error.MissingBootstrapRegion;
        try driver.runEnvelope(rt, env, arena, ref.bytes, if (blob_pool) |*cp| cp else null);
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
        const ns_name = file.ns;
        // A missing region means the embedded blob is malformed (a build-time
        // bug, never user input) — fail loudly rather than silently skipping a ns.
        const ref = serialize.findRegion(blob, ns_name) orelse return error.MissingBootstrapRegion;
        const region = try serialize.decompressRegion(rt.load_arena.allocator(), ref);
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
    for (files) |file| try markOneLoaded(rt, file.ns);
}

/// Record a single namespace as loaded in `rt.loaded_libs` (idempotent). Key is
/// gpa-owned (freed at `rt.deinit`), mirroring `loader.loadNamespace`.
pub fn markOneLoaded(rt: *Runtime, ns_name: []const u8) !void {
    if (rt.loaded_libs.contains(ns_name)) return;
    const key = try rt.gpa.dupe(u8, ns_name);
    errdefer rt.gpa.free(key);
    try rt.loaded_libs.put(rt.gpa, key, {});
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

test "ACTIVE_FILES and lookupEmbeddedFile gate on the same predicate" {
    // The non-wasm bootstrap break: cache_gen AOT-compiled every FILES entry
    // while lookupEmbeddedFile refused to serve `cljw.wasm` without `-Dwasm`,
    // so a build with the flag off died analysing a file it could never load
    // ("No namespace: 'wasm'"). Both sides now read `isActiveFile`, and this
    // test pins the coupling in EITHER build config — so the next gated file
    // cannot be added to one walk and forgotten in the other.
    //
    // BOTH directions (ADR-0180). The inactive one is what the break violated.
    // The active one is close to a tautology now that the lookup iterates
    // `ACTIVE_FILES` — that is the point: it is a TRIPWIRE against
    // reintroducing a hand-written second table, not a correctness check.
    // Do not delete it as vacuous. It was the assertion's ABSENCE that let a
    // 30-`if` chain sit beside `FILES` and disagree with it.
    for (ACTIVE_FILES) |file| {
        const found = lookupEmbeddedFile(file.ns) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(file.label, found.label);
    }
    for (FILES) |file| {
        if (isActiveFile(file)) continue;
        // Inactive ⇒ unresolvable, and absent from the walked set.
        try testing.expect(lookupEmbeddedFile(file.ns) == null);
        for (ACTIVE_FILES) |active| {
            try testing.expect(!std.mem.eql(u8, active.label, file.label));
        }
    }
    // Exactly one gated file today; ACTIVE_FILES is FILES under `-Dwasm`.
    try testing.expectEqual(
        @as(usize, if (build_options.wasm) FILES.len else FILES.len - 1),
        ACTIVE_FILES.len,
    );
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
