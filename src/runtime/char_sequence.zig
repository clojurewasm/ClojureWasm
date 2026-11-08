// SPDX-License-Identifier: EPL-2.0
//! The `java.lang.CharSequence` boundary: clj's `RT.seqFrom` / `RT.countFrom`
//! / `RT.nthFrom` arms, and the `^CharSequence` clojure.string and regex fns,
//! read every CharSequence alike, whatever carries it.
//!
//! A String is the native CharSequence and each consumer keeps its own fast
//! `.string` arm. The open set is a host surface (`java.lang.StringBuilder`)
//! or a deftype / reify declaring `java.lang.CharSequence` (instaparse's
//! Segment). Both implement the `CharSequence` protocol (`-cs-length` /
//! `-char-at` / `-sub-sequence`, declared in core.clj): a deftype through the
//! host_interface CHAR_SEQUENCE remap, a host surface by registering the
//! entries on its descriptor. `instance?` membership follows from the type's
//! declaration (CharSequence among a deftype's `protocol_impls`, a host
//! surface's `host_supertypes`), so nothing here enumerates implementors and a
//! new CharSequence needs no edit in this file.
//!
//! Content is read through the type's `toString` (the CharSequence contract:
//! its characters, in order), rendered by `print.writeStrValue`, the one
//! source `str` and `.toString` share. A consumer that needs the whole text
//! (a seq, a regex scan, `blank?`) therefore sees a SNAPSHOT taken when it
//! asks, where clj's StringSeq reads the live object through `charAt`: only a
//! builder mutated after `seq` can tell the two apart.
//!
//! The seq / count / nth arms are the miss paths of their callers (the value
//! was not a native collection and not Seqable / Counted / Indexed), and
//! `textArg` answers a String with one tag check and no copy, so none of this
//! sits on a hot path.
//!
//! Backend: impl-only
//! Impl deps: dispatch, class_name, print, error_catalog
//! Clojure peer: none (clojure.lang.RT's CharSequence arms)

const std = @import("std");
const Value = @import("value/value.zig").Value;
const Runtime = @import("runtime.zig").Runtime;
const Env = @import("env.zig").Env;
const SourceLocation = @import("error/info.zig").SourceLocation;
const error_catalog = @import("error/catalog.zig");
const dispatch = @import("dispatch.zig");
const class_name = @import("class_name.zig");
const print = @import("print.zig");
const string_collection = @import("collection/string.zig");

/// The protocol a non-string CharSequence implements. Bootstrap declares it in
/// `lang/clj/clojure/core.clj`, so the bare name is what its method entries
/// carry; host_interface's CHAR_SEQUENCE remap targets the same name.
pub const PROTOCOL: []const u8 = "CharSequence";

/// True iff `v` is a `java.lang.CharSequence`: a String, or an open-set value
/// whose type declares it.
pub fn isCharSequence(v: Value) bool {
    return class_name.isInstance(v, PROTOCOL);
}

/// The characters of CharSequence `v` as UTF-8 bytes, or null when `v` is not
/// a CharSequence. A String answers its own bytes with no copy (the caller's
/// root on `v` keeps them alive). Any other CharSequence is rendered through
/// its `toString` into `aw`, which owns the slice until the caller deinits it;
/// that is gpa memory, so a collection during the caller's later allocations
/// cannot free it.
pub fn textOrNull(rt: *Runtime, env: *Env, v: Value, aw: *std.Io.Writer.Allocating) anyerror!?[]const u8 {
    if (v.tag() == .string) return string_collection.asString(v);
    if (!isCharSequence(v)) return null;
    try print.writeStrValue(rt, env, &aw.writer, v);
    return aw.writer.buffered();
}

/// A `^CharSequence` parameter of `fn_name` (a clojure.string fn that calls
/// CharSequence methods on it, or a regex fn handing it to a Matcher): its
/// characters as `textOrNull` answers them, else the type_arg_not_string raise
/// (clj's ClassCastException). Same slice ownership as `textOrNull`.
pub fn textArg(rt: *Runtime, env: *Env, v: Value, fn_name: []const u8, loc: SourceLocation, aw: *std.Io.Writer.Allocating) anyerror![]const u8 {
    return (try textOrNull(rt, env, v, aw)) orelse
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = fn_name, .actual = @tagName(v.tag()) });
}

/// clj `RT.countFrom`'s CharSequence arm: `(.length v)` through the protocol,
/// or null when `v` does not implement it.
pub fn lengthOrNull(rt: *Runtime, env: *Env, v: Value, loc: SourceLocation) anyerror!?Value {
    var cs: dispatch.CallSite = .{};
    return dispatch.dispatchOrNull(rt, env, &cs, v, PROTOCOL, "-cs-length", &.{v}, loc);
}

/// clj `RT.nthFrom`'s CharSequence arm: `(.charAt v i)` when `0 <= i <
/// (.length v)`; otherwise `not_found` when the caller has one, else an
/// index_out_of_range raise (clj StringIndexOutOfBoundsException). `i_val` is
/// an integer Value. Null when `v` does not implement the protocol.
pub fn nthOrNull(rt: *Runtime, env: *Env, v: Value, i_val: Value, not_found: ?Value, loc: SourceLocation) anyerror!?Value {
    const len = (try lengthOrNull(rt, env, v, loc)) orelse return null;
    const i = i_val.asInteger();
    if (i >= 0 and len.tag() == .integer and i < len.asInteger()) {
        var cs: dispatch.CallSite = .{};
        return try dispatch.dispatch(rt, env, &cs, v, PROTOCOL, "-char-at", &.{ v, i_val }, loc);
    }
    if (not_found) |d| return d;
    return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = "nth" });
}
