// SPDX-License-Identifier: EPL-2.0
//! In-Zig chunk drain for the lazy `map`/`filter` PRODUCER side (O-032 / 9.2.S).
//!
//! `-chunk-map-step` / `-chunk-filter-step` process a whole source 32-chunk in
//! Zig — read `currentChunkNth`, call the user `f`/`pred` via `invokeCallable`,
//! `chunkAppend` into a fresh `ChunkBuffer` — and return the filled buffer. The
//! `.clj` `-map-lazy`/`-filter-lazy` chunked arm keeps `chunk-cons` + the lazy
//! tail recursion + O-023 fuse stamping, so this is a pure per-chunk inner-loop
//! replacement: the ~32×(`-chunk-nth` + `chunk-append`) `.clj` prim calls + the
//! tree-walked `loop`/`recur` glue collapse to ONE prim call per chunk.
//!
//! This is the producer-side analogue of `reduceFn`'s in-Zig chunk drain (O-004);
//! it mirrors that frame discipline exactly (the one new root site is the growing
//! output `ChunkBuffer`). F-011: chunk size follows the SOURCE chunk
//! (`currentChunkCount`, NOT a fixed 32); `f`/`pred` runs over every element in
//! ascending index order, once each, matching clj's 32-at-a-time chunk realization.
//!
//! ## Backend: impl-only (no surface delegation)
//! Impl deps: chunked_cons (Layer 0), higher_order.invokeCallable (Layer 2)
//! Clojure peer: -map-lazy / -filter-lazy chunked arms (core.clj)

const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const chunked_cons = @import("../../runtime/collection/chunked_cons.zig");
const root_set = @import("../../runtime/gc/root_set.zig");
const invokeCallable = @import("higher_order.zig").invokeCallable;

/// PERF: in-Zig chunk-map drain — `f` over all of `s`'s current chunk → a filled
/// ChunkBuffer (the `.clj` arm does `(chunk-cons <buf> (-map-lazy f (chunk-rest
/// s)))`). [refs: O-032, O-004]
pub fn chunkMapStepFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("-chunk-map-step", args, 2, loc);
    const f = args[0];
    const s = args[1];
    const cnt = chunked_cons.currentChunkCount(s);

    // GC-ROOT: O-032 — reentrant-primitive frame [f, s, buf] (mirrors reduceFn,
    // ADR-0094) [ref: .dev/gc_rooting.md]. Push BEFORE the buf alloc (slot 2 nil)
    // so the alloc's own potential collect already roots f + s; slot 1 (s) keeps
    // the source chunk live so `currentChunkNth` stays valid across each `f`;
    // slot 2 (buf) keeps the half-filled output buffer alive across each `f`.
    var gc_roots: [3]Value = .{ f, s, .nil_val };
    var gc_sp: u16 = 3;
    var gc_frame: root_set.EvalFrame = .{ .stack = &gc_roots, .sp = &gc_sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;

    const buf = try chunked_cons.newChunkBuffer(rt);
    gc_roots[2] = buf;

    var i: u32 = 0;
    while (i < cnt) : (i += 1) {
        const elt = chunked_cons.currentChunkNth(s, i);
        const mapped = try invokeCallable(rt, env, f, &.{elt}, loc);
        // chunkAppend is non-allocating + runs AFTER the call returns, so `mapped`
        // is never live-across-collect unrooted.
        _ = chunked_cons.chunkAppend(buf, mapped);
    }
    return buf;
}

/// PERF: in-Zig chunk-filter drain — `pred` over all of `s`'s current chunk →
/// a ChunkBuffer of survivors (partial; empty → the `.clj` `chunk-cons` returns
/// the tail directly). [refs: O-032, O-004]
pub fn chunkFilterStepFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("-chunk-filter-step", args, 2, loc);
    const pred = args[0];
    const s = args[1];
    const cnt = chunked_cons.currentChunkCount(s);

    // GC-ROOT: O-032 — frame [pred, s, buf]; same discipline as chunkMapStepFn.
    var gc_roots: [3]Value = .{ pred, s, .nil_val };
    var gc_sp: u16 = 3;
    var gc_frame: root_set.EvalFrame = .{ .stack = &gc_roots, .sp = &gc_sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;

    const buf = try chunked_cons.newChunkBuffer(rt);
    gc_roots[2] = buf;

    var i: u32 = 0;
    while (i < cnt) : (i += 1) {
        const elt = chunked_cons.currentChunkNth(s, i);
        if ((try invokeCallable(rt, env, pred, &.{elt}, loc)).isTruthy()) {
            _ = chunked_cons.chunkAppend(buf, elt);
        }
    }
    return buf;
}
