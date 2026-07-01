// SPDX-License-Identifier: EPL-2.0
//! Closed-set SSOT of the java.io stream class names cljw's ONE buffer-backed
//! host_stream (ADR-0126 Cycle 3) reports for `class` / `instance?`. cljw has
//! no real class hierarchy (no-JVM, ADR-0059), so this models the OBSERVABLE
//! clj behaviour with two distinct sets, verified against `clj`
//! (test/diff/clj_corpus/io_stream_class.txt):
//!
//!   1. CONCRETE + supertype chain (per kind) — the `instance?`-TRUE set. clj's
//!      coercion fns return a concrete buffered type, and `instance?` is true
//!      only for that concrete and its java.io superclasses:
//!        io/reader        -> BufferedReader  : {BufferedReader, Reader}
//!        io/writer        -> BufferedWriter  : {BufferedWriter, Writer}
//!        io/input-stream  -> BufferedInputStream  : {BufferedInputStream, FilterInputStream, InputStream}
//!        io/output-stream -> BufferedOutputStream : {BufferedOutputStream, FilterOutputStream, OutputStream}
//!      chain[0] is the concrete class — host_stream stamps it as the
//!      descriptor `fqcn` (so `(class s)` returns it, clj-faithful) and the
//!      whole chain as `protocol_impls` (the `class_name.matchUserType` arm).
//!   2. SIBLING leaves — REAL java.io stream classes cljw never produces
//!      (FileReader, PrintWriter, FileInputStream, …). They are KNOWN (so
//!      `(instance? java.io.FileReader rdr)` is a clj-faithful FALSE, not a
//!      `class_name_unknown` error) but never in any chain, so instance? is
//!      false. `class_name.isKnown` accepts chain ∪ sibling.
//!
//! Names are fully-qualified (`java.io.*`): cljw never auto-imports java.io, so
//! the FQCN is what flows through `normalizeClassName` unchanged. A bare
//! imported simple name (`(import java.io.BufferedReader)` / `(ns …(:import …))`)
//! is resolved to its FQCN at the `instance?` primitive via `ns.imports` (the
//! same D-235 map `resolveJavaSurface` uses) BEFORE reaching here. This module
//! imports only `std`, so `class_name → stream_classes` cannot cycle (D-358).

const std = @import("std");

/// Stream family — the SSOT for the enum so host_stream re-exports it and the
/// chain accessors below stay keyed to the same four kinds.
pub const Kind = enum(u8) { reader, writer, input, output };

/// Concrete class first, then its java.io superclass chain. clj-faithful
/// `instance?` membership (the buffered concrete cljw's coercion implies).
pub const READER_CHAIN = [_][]const u8{ "java.io.BufferedReader", "java.io.Reader" };
pub const WRITER_CHAIN = [_][]const u8{ "java.io.BufferedWriter", "java.io.Writer" };
pub const INPUT_CHAIN = [_][]const u8{ "java.io.BufferedInputStream", "java.io.FilterInputStream", "java.io.InputStream" };
pub const OUTPUT_CHAIN = [_][]const u8{ "java.io.BufferedOutputStream", "java.io.FilterOutputStream", "java.io.OutputStream" };

/// The OTHER concrete/abstract java.io stream classes cljw never produces —
/// KNOWN (so `(instance? java.io.FileReader rdr)` is a clj-faithful false, not
/// class_name_unknown) but matched by no chain. This is the COMPREHENSIVE
/// java.io stream surface (F-013 clause 4: 網羅 the recognition table — cheap
/// rows, no impl), derived from the java.io package definition (every public
/// Reader/Writer/InputStream/OutputStream subtype), NOT a per-library allowlist.
/// A name outside chain∪sibling still raises class_name_unknown — cljw has no
/// classpath to confirm an arbitrary FQCN is a real class (D-358 note; clj would
/// resolve it or ClassNotFound, which cljw cannot replicate without a classpath).
pub const SIBLING_NAMES = [_][]const u8{
    // Reader subtree (minus the BufferedReader/Reader chain)
    "java.io.LineNumberReader",      "java.io.CharArrayReader",   "java.io.FilterReader",        "java.io.PushbackReader",
    "java.io.InputStreamReader",     "java.io.FileReader",        "java.io.PipedReader",         "java.io.StringReader",
    // Writer subtree (minus the BufferedWriter/Writer chain)
    "java.io.CharArrayWriter",       "java.io.FilterWriter",      "java.io.OutputStreamWriter",  "java.io.FileWriter",
    "java.io.PipedWriter",           "java.io.PrintWriter",       "java.io.StringWriter",
    // InputStream subtree (minus the Buffered/Filter/InputStream chain)
           "java.io.ByteArrayInputStream",
    "java.io.FileInputStream",       "java.io.DataInputStream",   "java.io.PushbackInputStream", "java.io.LineNumberInputStream",
    "java.io.ObjectInputStream",     "java.io.PipedInputStream",  "java.io.SequenceInputStream", "java.io.StringBufferInputStream",
    // OutputStream subtree (minus the Buffered/Filter/OutputStream chain)
    "java.io.ByteArrayOutputStream", "java.io.FileOutputStream",  "java.io.DataOutputStream",    "java.io.PrintStream",
    "java.io.ObjectOutputStream",    "java.io.PipedOutputStream",
};

/// The instance?-true chain for `kind` (concrete at index 0).
pub fn chainFor(kind: Kind) []const []const u8 {
    return switch (kind) {
        .reader => &READER_CHAIN,
        .writer => &WRITER_CHAIN,
        .input => &INPUT_CHAIN,
        .output => &OUTPUT_CHAIN,
    };
}

/// The concrete class cljw reports for `kind` (the descriptor fqcn / `(class s)`).
pub fn concreteFor(kind: Kind) []const u8 {
    return chainFor(kind)[0];
}

/// True iff `fqcn` is the concrete class of some stream kind — i.e. a live
/// stream value's descriptor fqcn. Used by host_stream's rt/ prim type guards.
pub fn isConcrete(fqcn: []const u8) bool {
    inline for (.{ Kind.reader, Kind.writer, Kind.input, Kind.output }) |k| {
        if (std.mem.eql(u8, concreteFor(k), fqcn)) return true;
    }
    return false;
}

/// True iff `fqcn` names ANY recognised java.io stream class (chain or sibling).
/// Drives `class_name.isKnown`: a name accepted here returns instance? false
/// (not class_name_unknown) when the value isn't in its chain.
pub fn isStreamClass(fqcn: []const u8) bool {
    inline for (.{ READER_CHAIN, WRITER_CHAIN, INPUT_CHAIN, OUTPUT_CHAIN, SIBLING_NAMES }) |list| {
        for (list) |n| if (std.mem.eql(u8, n, fqcn)) return true;
    }
    return false;
}

const testing = std.testing;

test "concreteFor matches clj coercion return types" {
    try testing.expectEqualStrings("java.io.BufferedReader", concreteFor(.reader));
    try testing.expectEqualStrings("java.io.BufferedWriter", concreteFor(.writer));
    try testing.expectEqualStrings("java.io.BufferedInputStream", concreteFor(.input));
    try testing.expectEqualStrings("java.io.BufferedOutputStream", concreteFor(.output));
}

test "isStreamClass: chains + siblings known, others not" {
    // chain members (instance?-true set)
    try testing.expect(isStreamClass("java.io.Reader"));
    try testing.expect(isStreamClass("java.io.BufferedInputStream"));
    try testing.expect(isStreamClass("java.io.FilterOutputStream"));
    // siblings (known → instance? false, not an error) — comprehensive java.io set
    try testing.expect(isStreamClass("java.io.FileReader"));
    try testing.expect(isStreamClass("java.io.PrintWriter"));
    try testing.expect(isStreamClass("java.io.FileInputStream"));
    try testing.expect(isStreamClass("java.io.LineNumberReader"));
    try testing.expect(isStreamClass("java.io.DataInputStream"));
    try testing.expect(isStreamClass("java.io.PrintStream"));
    // not a java.io STREAM class (RandomAccessFile is java.io but not a stream),
    // not the simple form → still class_name_unknown (no classpath to confirm).
    try testing.expect(!isStreamClass("java.io.RandomAccessFile"));
    try testing.expect(!isStreamClass("BufferedReader"));
    try testing.expect(!isStreamClass("java.lang.String"));
}

test "isConcrete: only the 4 buffered concretes" {
    try testing.expect(isConcrete("java.io.BufferedReader"));
    try testing.expect(isConcrete("java.io.BufferedOutputStream"));
    // a chain SUPERCLASS is not the concrete (a value's fqcn is the concrete)
    try testing.expect(!isConcrete("java.io.Reader"));
    try testing.expect(!isConcrete("java.io.FileReader"));
}
