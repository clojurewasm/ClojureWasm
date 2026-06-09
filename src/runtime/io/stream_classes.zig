// SPDX-License-Identifier: EPL-2.0
//! Closed-set SSOT of the java.io stream class names cljw's ONE buffer-backed
//! host_stream (ADR-0126 Cycle 3) answers `instance?` for. The four families
//! (Reader / Writer / InputStream / OutputStream) plus their common JVM leaf
//! classes (BufferedReader / FileInputStream / …). cljw has no real class
//! hierarchy (no-JVM, ADR-0059), so one reader stream is `instance?`-true for
//! ANY reader-family leaf — matching what ported JVM code branches on
//! (`(instance? java.io.BufferedReader rdr)`), without a parent chain.
//!
//! Single source so the two readers cannot drift (the host_interfaces.yaml /
//! ADR-0102 closed-set pattern in its lightweight Zig form — a fixed internal
//! set, not a user-extensible surface, so no yaml + gate is warranted):
//!   - host_stream.zig stamps each list into its family descriptor's
//!     `protocol_impls`, the `class_name.matchUserType` arm that answers a
//!     leaf `instance?` on a live stream value.
//!   - class_name.zig's `isKnown` accepts them so the `__instance?` precheck
//!     does not raise `class_name_unknown` before the match runs.
//!
//! Names are fully-qualified (`java.io.*`): cljw never auto-imports java.io, so
//! user / ported code writes the FQCN, and `class_name.normalizeClassName`
//! leaves an unrecognised FQCN unchanged — so the same FQCN flows unmodified to
//! both readers and they stay aligned. This module imports only `std`, so a
//! `class_name → stream_classes` import cannot cycle back (D-358).

const std = @import("std");

pub const READER_NAMES = [_][]const u8{
    "java.io.Reader",     "java.io.BufferedReader", "java.io.InputStreamReader",
    "java.io.FileReader", "java.io.StringReader",   "java.io.PushbackReader",
};
pub const WRITER_NAMES = [_][]const u8{
    "java.io.Writer",     "java.io.BufferedWriter", "java.io.OutputStreamWriter",
    "java.io.FileWriter", "java.io.PrintWriter",    "java.io.StringWriter",
};
pub const INPUT_NAMES = [_][]const u8{
    "java.io.InputStream",          "java.io.BufferedInputStream",
    "java.io.FileInputStream",      "java.io.ByteArrayInputStream",
};
pub const OUTPUT_NAMES = [_][]const u8{
    "java.io.OutputStream",         "java.io.BufferedOutputStream",
    "java.io.FileOutputStream",     "java.io.ByteArrayOutputStream",
};

/// True iff `fqcn` names one of the recognised java.io stream classes (family
/// or leaf). The membership the closed set guarantees: a name `isKnown`
/// accepts here is exactly a name some family descriptor's `protocol_impls`
/// can match, so the precheck and the match never disagree.
pub fn isStreamClass(fqcn: []const u8) bool {
    inline for (.{ READER_NAMES, WRITER_NAMES, INPUT_NAMES, OUTPUT_NAMES }) |list| {
        for (list) |n| if (std.mem.eql(u8, n, fqcn)) return true;
    }
    return false;
}

const testing = std.testing;

test "isStreamClass recognises families + leaves, rejects others" {
    try testing.expect(isStreamClass("java.io.Reader"));
    try testing.expect(isStreamClass("java.io.BufferedReader"));
    try testing.expect(isStreamClass("java.io.FileInputStream"));
    try testing.expect(isStreamClass("java.io.ByteArrayOutputStream"));
    try testing.expect(isStreamClass("java.io.PrintWriter"));
    // The simple form is NOT recognised — cljw never auto-imports java.io, so
    // the FQCN is the only surface the precheck and the match agree on.
    try testing.expect(!isStreamClass("BufferedReader"));
    try testing.expect(!isStreamClass("java.io.Reader2"));
    try testing.expect(!isStreamClass("java.lang.String"));
}
