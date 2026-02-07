# Optimization Backlog

All deferred and future optimization items, organized by effort/impact.

## Quick Reference

| ID     | Item                          | Effort | Impact | Target | Status      |
|--------|-------------------------------|--------|--------|--------|-------------|
| F101   | into() transient optimization | LOW    | MEDIUM | any    | New         |
| F102   | map/filter chunked processing | MEDIUM | MEDIUM | any    | New         |
| ~~F1~~ | ~~NaN boxing (Value 48->8B)~~ | ~~HIGH~~ | ~~HIGH~~ | — | **DONE (Ph.27)** |
| F99    | Iterative lazy-seq realize    | MEDIUM | HIGH   | Ph.26  | Partial     |
| F103   | Escape analysis               | HIGH   | MEDIUM | Ph.32  | New         |
| F104   | Profile-guided opt (IC ext)   | MEDIUM | MEDIUM | Ph.32  | New         |
| F7     | Bootstrap AOT                 | HIGH   | MEDIUM | Ph.31  | Blocked     |
| 24C.8  | Constant folding              | LOW    | LOW    | future | Skipped     |
| F98    | ReleaseFast anomaly           | LOW    | LOW    | future | Investigate |
| F105   | JIT compilation               | HUGE   | HIGH   | Ph.32  | Planned     |

## Tier 1: Small Effort / High Impact

### F101: into() Transient Optimization

Current: (reduce conj to from) — every conj creates a new persistent copy.
Target: (persistent! (reduce conj! (transient to) from)).
Transient collections already exist (Phase 20).

Impact: 2-5x for (into [] large-coll), (into {} pairs).
Effort: ~1 hour — modify core.clj into function.
File: src/clj/clojure/core.clj line 1582

### F102: map/filter Chunked Processing

Current: map/filter process one element at a time via lazy-seq/cons.
chunk.zig infrastructure (ChunkedCons, chunk-buffer, etc.) exists (Phase 20).

Target: map/filter detect IChunkedSeq and process in 32-element chunks.
Impact: 2-4x for map/filter over chunked sources (vector, range).
Effort: ~2-4 hours — modify core.clj map/filter, add chunked-seq detection.
File: src/clj/clojure/core.clj, src/common/builtin/chunk.zig

## Tier 2: Medium Effort / High Impact

### F1/D72: NaN Boxing (Value 48 -> 8 bytes)

Design complete (D72, decisions.md). 600+ call sites need migration.
Portable — f64 bit ops work on wasm32 too.
Impact: 6x smaller Values, dramatically better cache locality on ALL benchmarks.
Effort: ~2-3 days — massive cross-cutting migration.

### F99: Iterative Lazy-Seq Realization (General Case)

D74 filter chain collapsing fixes sieve (168 nested filters).
General realize->realizeMeta->seqFn mutual recursion remains for map/take chains.
CRITICAL for Phase 26 — Wasm has ~1MB stack (vs native 512MB).
Effort: ~4-8 hours — add heap-based work stack to realize/realizeMeta.
File: src/common/value.zig

## Tier 3: High Effort / Future

### F103: Escape Analysis
Compiler detects local-only Values, avoids GC tracking. Effort: ~1-2 days.

### F104: Profile-Guided Optimization
Extend inline caching beyond monomorphic. Effort: ~4-8 hours.

### F7: Bootstrap AOT
Pre-compile core.clj to bytecode at build time. Blocked by macro serialization.

### 24C.8: Constant Folding
Low priority — benchmarks don't contain enough constant expressions.

### F98: ReleaseFast Anomaly
fib_recursive slower in ReleaseFast than Debug. Investigation only.

### F105: JIT Compilation
Trace-based or method-based JIT. Major subsystem. Phase 28+.
Options: trace JIT, method JIT, Cranelift backend, Zig comptime codegen.
