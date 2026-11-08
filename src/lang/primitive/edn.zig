// SPDX-License-Identifier: EPL-2.0
//! `clojure.edn` Tier-A surface (§9.11 row 9.2).
//!
//! cw v1's reader already parses EDN syntax (Clojure IS EDN-shaped);
//! this module exposes `clojure.edn/read-string` as a thin Layer-2
//! primitive that runs `eval/reader.readOne` followed by
//! `analyzer.formToValue` (recursively lifted at row 9.2 to cover
//! vector / map / set literals).
//!
//! Both the 1-arity `(read-string s)` and the 2-arity
//! `(read-string opts s)` form (`:readers` / `:default` / `:eof`)
//! are implemented (D-200).
//!
//! **Location note (D-095)**: this Zig primitive lives under
//! `src/lang/primitive/` (mirroring `string.zig` / `walk.zig`); the
//! matching `.clj` source sits at `src/lang/clj/clojure/edn.clj`
//! (mirroring `clojure.string` / `clojure.set` precedent). The former
//! top-level `modules/` reservation for a co-located `modules/edn/`
//! layout was retired (D-095 — the migration was never warranted;
//! primitives stay in `src/lang/`).

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const reader_mod = @import("../../eval/reader.zig");
const analyzer_mod = @import("../../eval/analyzer/analyzer.zig");
const string_collection = @import("../../runtime/collection/string.zig");
const map_collection = @import("../../runtime/collection/map.zig");
const keyword = @import("../../runtime/keyword.zig");
const Var = env_mod.Var;
const text_io = @import("../../runtime/io/text_io.zig");
const host_stream = @import("../../runtime/io/host_stream.zig");

/// Implements clojure.edn/read-string.
/// Spec: `(read-string s)` reads one EDN form from `s` and returns it as
///   a Value. Empty / whitespace-only / comment-only input: `clojure.edn`
///   returns nil, `clojure.core` THROWS EOF — measured, they differ (D-581).
///   The two-argument overload WITHOUT `:eof` throws on empty input;
///   an explicit `:eof` opt supplies a sentinel. `(read-string opts s)`
///   honours an opts map: `:readers` (a `{tag-symbol reader-fn}` map bound
///   to `*data-readers*` for the read), `:default` (a `(fn [tag value])`
///   bound to `*default-data-reader-fn*`), `:eof` (value returned on empty
///   input instead of `nil`). The readers/default install via a
///   `BindingFrame` (ADR-0073) so the `formToValue` `.tagged` arm sees them.
/// JVM reference: clojure.edn/read-string (note: opts is the FIRST arg)
/// cw v1 tier: A (Phase 9 row 9.2 + Phase 14 D-200 cycle 2)
/// `clojure.core/read-string` — EOF on empty input is an ERROR (clj:
/// `RuntimeException: EOF while reading`).
pub fn readStringFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    return readStringImpl(rt, env, args, loc, .raise, .clojure);
}

/// `clojure.edn/read-string` — EOF on empty input is nil, NOT an error.
/// Measured against clj: `(edn/read-string "")` => nil while
/// `(core/read-string "")` throws. The two readers differ on exactly this
/// input, which is why they cannot share one entry point (D-581; D-269 was
/// discharged against the core behaviour and made edn throw too).
/// It reads clj's EdnReader dialect (ADR-0200 Layer B), so `` ` `` `~` `@`
/// `#'` `#(` `#"` `#=` `#?` `#!` `::kw` `#::{}` are errors, `'a` is a
/// symbol, and `#ns.Rec{}` resolves only through `:readers` / `:default`.
/// A nil source reads as nil (clj: `(when s ...)`).
/// JVM reference: clojure.edn/read-string in clojure/edn.clj, over
/// clojure.lang.EdnReader.
pub fn readStringEdnFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    if (args.len >= 1 and args.len <= 2 and args[args.len - 1].tag() == .nil) return Value.nil_val;
    return readStringImpl(rt, env, args, loc, .nil_on_eof, .edn);
}

/// What an empty / whitespace-only / comment-only source means to the caller.
const EofPolicy = enum { raise, nil_on_eof };

fn readStringImpl(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation, eof_policy: EofPolicy, dialect: reader_mod.Dialect) anyerror!Value {
    try error_catalog.checkArityRange("read-string", args, 1, 2, loc);
    const opts: ?Value = if (args.len == 2) args[0] else null;
    // clojure.edn/read-string's single-argument overload uses a nil EOF
    // sentinel. Its two-argument overload delegates directly to the reader:
    // with no :eof key even {} throws at EOF (including comments/discards).
    if (opts) |o| switch (o.tag()) {
        .array_map, .hash_map => {},
        else => return error_catalog.raise(.edn_string_invalid, loc, .{ .reason = if (o.tag() == .nil) "nil options" else "options must be a map" }),
    };
    const str_arg = args[args.len - 1];
    if (str_arg.tag() != .string) {
        return error_catalog.raise(.type_arg_not_string, loc, .{
            .fn_name = "read-string",
            .actual = @tagName(str_arg.tag()),
        });
    }
    const source = string_collection.asString(str_arg);
    return readSource(rt, env, opts, source, loc, eof_policy, null, dialect);
}

/// Read one form and advance the reader by exactly the consumed bytes.
/// Zero arity uses the dynamically bound *in*; explicit reader arities use
/// the same option binding and strict EDN value conversion as read-string.
pub fn readEdnFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArityRange("read", args, 0, 2, loc);
    const opts: ?Value = if (args.len == 2) args[0] else null;
    const input = if (args.len == 0) blk: {
        const core_ns = env.findNs("clojure.core") orelse return error_catalog.raise(.edn_string_invalid, loc, .{ .reason = "missing *in*" });
        const in_var = core_ns.resolve("*in*") orelse return error_catalog.raise(.edn_string_invalid, loc, .{ .reason = "missing *in*" });
        break :blk in_var.deref();
    } else args[args.len - 1];
    if (opts) |o| switch (o.tag()) {
        .array_map, .hash_map => {},
        else => return error_catalog.raise(.edn_string_invalid, loc, .{ .reason = "options must be a map" }),
    };
    if (try text_io.remainingReader(rt, input)) |source|
        return readSource(rt, env, opts, source, loc, .raise, input, .edn);
    if (try host_stream.remainingReader(rt, input)) |source|
        return readSource(rt, env, opts, source, loc, .raise, input, .edn);
    return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "read", .expected = "a PushbackReader", .actual = @tagName(input.tag()) });
}

fn readSource(rt: *Runtime, env: *Env, opts: ?Value, source: []const u8, loc: SourceLocation, eof_policy: EofPolicy, stream: ?Value, dialect: reader_mod.Dialect) anyerror!Value {
    // EOF (no form in `source`): clj THROWS `RuntimeException: EOF while
    // reading` UNLESS an `:eof` opt is supplied, in which case that value is
    // returned (D-269 — was a silent nil-default that masked "nothing to read").
    // `:eof` may be explicitly bound to nil, so detect KEY PRESENCE, not a
    // non-nil value.
    var eof_provided = false;
    var eof_val: Value = Value.nil_val;
    if (opts) |o| switch (o.tag()) {
        .array_map, .hash_map => {
            const k = try keyword.intern(rt, null, "eof");
            if (try map_collection.contains(o, k)) {
                eof_provided = true;
                eof_val = try map_collection.get(o, k);
            }
        },
        else => {},
    };

    // Install `:readers` / `:default` as a dynamic-binding frame for the
    // read so the data-reader dispatch in `formToValue` sees them.
    var frame: env_mod.BindingFrame = .{};
    defer frame.bindings.deinit(rt.gpa);
    if (opts) |o| {
        if (try optGet(rt, o, "readers")) |readers| {
            if (rt.data_readers_var) |p|
                try frame.bindings.put(rt.gpa, @as(*const Var, @ptrCast(@alignCast(p))), readers);
        }
        if (try optGet(rt, o, "default")) |default_fn| {
            if (rt.default_data_reader_fn_var) |p|
                try frame.bindings.put(rt.gpa, @as(*const Var, @ptrCast(@alignCast(p))), default_fn);
        }
    }
    env_mod.pushFrame(&frame);
    defer env_mod.popFrame();

    var arena = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena.deinit();

    // D-457(3): a data read rejects `#?` (clj: "Conditional read not allowed")
    // unless the caller opts in with `:read-cond :allow`. Source-loading
    // (require/load/eval) keeps allowing `#?` via the Reader's default; only this
    // DATA-read path flips it off.
    var allow_cond = false;
    if (opts) |o| {
        if (try optGet(rt, o, "read-cond")) |rc| {
            if (rc == try keyword.intern(rt, null, "allow")) allow_cond = true;
        }
    }
    var reader = reader_mod.Reader.initDialect(arena.allocator(), source, dialect);
    reader.allow_reader_cond = allow_cond;
    // ADR-0200: every form is lifted with formToValueStrict below, which
    // checks duplicate keys by value and in source order, so the reader's
    // Form-level approximation stays off.
    reader.form_checks = false;
    // ADR-0200 A4: a `#_` target is lifted (its tag readers run, its
    // duplicates raise) the moment it is read, inside this binding frame,
    // so the source-order error is the one raised, then dropped.
    var discard: DiscardLift = .{ .rt = rt, .env = env, .dialect = dialect };
    reader.discard_hook = .{ .ctx = &discard, .f = DiscardLift.hook };
    const form_opt = reader.read() catch |e| {
        if (discard.err) |de| return de;
        // A specific reader diagnostic (e.g. reader_cond_not_allowed, or an
        // IllegalArgumentException such as a duplicate key) carries its own
        // catalog Info; re-raise it so the message and kind survive rather
        // than being flattened to the generic EDN-reader-error wrapper. A bad
        // number token (`12x`) is NumberError: clj NumberFormatException
        // "Invalid number: 12x" from read-string and edn/read-string alike.
        if (e == error.SyntaxError or e == error.ValueError or e == error.NumberError) return e;
        // Malformed EDN is bad DATA — clj throws a catchable RuntimeException,
        // and parsing untrusted EDN is exactly when the caller needs the catch.
        return error_catalog.raise(.edn_string_invalid, loc, .{ .reason = @errorName(e) });
    };
    // Tokenizer may have looked ahead at a delimiter; for a complete form
    // its cursor is precisely the boundary before the next form. Consume
    // whitespace on EOF as well so repeated reads remain at EOF.
    if (stream) |s| {
        const consumed: usize = if (reader.peeked) |tok| tok.start else reader.tokenizer.pos;
        if (text_io.isTextReader(s)) text_io.advanceReader(s, consumed) else host_stream.advanceReader(s, consumed);
    }
    const form = form_opt orelse {
        if (eof_provided) return eof_val;
        // An explicit `:eof` wins for both readers; absent it, the policy decides.
        if (eof_policy == .nil_on_eof and opts == null) return Value.nil_val;
        return error_catalog.raise(.eof_unexpected, loc, .{});
    };
    return try liftData(rt, env, form, dialect);
}

/// The data lift for `dialect`: EDN never reads `#ns.Rec{}` as a record.
fn liftData(rt: *Runtime, env: *Env, form: reader_mod.ReadForm, dialect: reader_mod.Dialect) anyerror!Value {
    return switch (dialect) {
        .clojure => analyzer_mod.formToValueStrict(rt, env, form),
        .edn => analyzer_mod.formToValueEdn(rt, env, form),
    };
}

/// Reader discard hook state. The lift can fail with errors outside the
/// reader's error set (a user reader fn's thrown value), so the hook parks
/// the real error here and aborts the read with a placeholder that
/// `readSource` swaps back.
const DiscardLift = struct {
    rt: *Runtime,
    env: *Env,
    dialect: reader_mod.Dialect,
    err: ?anyerror = null,

    fn hook(ctx: *anyopaque, form: reader_mod.ReadForm) reader_mod.ReadError!void {
        const self: *DiscardLift = @ptrCast(@alignCast(ctx));
        _ = liftData(self.rt, self.env, form, self.dialect) catch |e| {
            self.err = e;
            return error.SyntaxError;
        };
    }
};

/// Look up `:key` in an opts map, returning the bound value or null when
/// absent / nil. Returns null (no error) if `opts` is not a map, so a
/// non-map opts is simply treated as "no options".
fn optGet(rt: *Runtime, opts: Value, key: []const u8) !?Value {
    switch (opts.tag()) {
        .array_map, .hash_map => {},
        else => return null,
    }
    const k = try keyword.intern(rt, null, key);
    const v = try map_collection.get(opts, k);
    return if (v.tag() == .nil) null else v;
}

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "read", .f = &readEdnFn },
    .{ .name = "read-string", .f = &readStringEdnFn },
};

/// Register `clojure.edn` primitives into the dedicated namespace.
/// Mirrors the row 6.9 pattern from `lang/primitive/string.zig`:
/// creates `clojure.edn` ns if missing + interns each Var. The
/// `(ns clojure.edn ...)` head in `src/lang/clj/clojure/edn.clj`
/// finds an already-populated ns when bootstrap evaluates it.
pub fn register(env: *Env) !void {
    const ns = try env.findOrCreateNs("clojure.edn");
    for (ENTRIES) |it| {
        _ = try env.intern(ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
