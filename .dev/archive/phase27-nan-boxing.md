# Phase 27: NaN Boxing — Value 48B → 8B

## Overview

Replace Value tagged union (48 bytes) with NaN-boxed u64 (8 bytes).
Staged API migration per D72: accessor layer → call site migration → representation switch.

## Current Value

```zig
pub const Value = union(enum) {
    // Inline (small)
    nil,                // 0 bytes payload
    boolean: bool,      // 1 byte
    integer: i64,       // 8 bytes
    float: f64,         // 8 bytes
    char: u21,          // 4 bytes

    // Inline structs (LARGE — force Value to 48B)
    string: []const u8,    // 16 bytes (ptr + len)
    symbol: Symbol,        // 40 bytes (ns + name + meta)
    keyword: Keyword,      // 32 bytes (ns + name)

    // Pointers (8 bytes each)
    list: *const PersistentList,
    vector: *const PersistentVector,
    // ... 24 more pointer variants ...
};
```

@sizeOf(Value) = 48 bytes (dominated by Symbol at 40 bytes + tag).

## NaN Boxing Encoding (D72)

IEEE 754 double: sign(1) + exponent(11) + mantissa(52).
Quiet NaN: exponent=0x7FF, mantissa MSB=1. This leaves 51 bits for payload.

Top 16 bits of u64 encode the type:

| Tag bits | Type       | Payload (lower 48 bits)        |
|----------|------------|--------------------------------|
| < 0xFFF9 | float      | Raw f64 bits (pass-through)    |
| 0xFFF9   | integer    | i48 signed (±140 trillion)     |
| 0xFFFA   | heap ptr   | HeapTag[47:40] + address[39:0] |
| 0xFFFB   | constant   | 0=nil, 1=true, 2=false         |
| 0xFFFC   | char       | u21 codepoint                  |
| 0xFFFD   | builtin_fn | 48-bit function pointer        |

HeapTag (8 bits, 256 slots) encodes the specific heap type:
string, symbol, keyword, list, vector, map, hash_map, set,
fn_val, atom, volatile_ref, regex, protocol, protocol_fn,
multi_fn, lazy_seq, cons, var_ref, delay, reduced,
transient_vector, transient_map, transient_set,
chunked_cons, chunk_buffer, array_chunk, wasm_module, wasm_fn.

## Impact

| Metric           | Before (48B) | After (8B) | Improvement |
|------------------|--------------|------------|-------------|
| Value size       | 48 bytes     | 8 bytes    | 6x smaller  |
| VM stack (32K)   | 1.5 MB       | 256 KB     | 6x smaller  |
| Vector element   | 48 bytes     | 8 bytes    | 6x smaller  |
| Cache line (64B) | 1.3 values   | 8 values   | 6x denser   |

## Sub-phases

### 27.1: API Layer Design + Implementation

Add accessor methods to Value that abstract the internal representation.
All methods are trivial one-liners wrapping current union access.

**Deliverables**:
1. Explicit `Tag` enum (matches union tags)
2. Constructor methods: `initInteger(i64)`, `initFloat(f64)`, etc.
3. Extractor methods: `asInteger()`, `asFloat()`, etc.
4. Tag query: `tag()`, `isNil()`
5. Constants: `Value.nil`, `Value.true_val`, `Value.false_val`
6. Tests for all API methods

**API Design**:

```
// Tag query
pub fn tag(self: Value) Tag;
pub fn isNil(self: Value) bool;

// Constants
pub const nil: Value;
pub const true_val: Value;
pub const false_val: Value;

// Constructors — inline types
pub fn initBoolean(b: bool) Value;
pub fn initInteger(i: i64) Value;
pub fn initFloat(f: f64) Value;
pub fn initChar(c: u21) Value;

// Constructors — currently inline, become heap after NaN boxing
pub fn initString(s: []const u8) Value;
pub fn initSymbol(s: Symbol) Value;
pub fn initKeyword(k: Keyword) Value;

// Constructors — pointer types (signature unchanged after NaN boxing)
pub fn initList(l: *const PersistentList) Value;
pub fn initVector(v: *const PersistentVector) Value;
pub fn initMap(m: *const PersistentArrayMap) Value;
pub fn initHashMap(m: *const PersistentHashMap) Value;
pub fn initSet(s: *const PersistentHashSet) Value;
pub fn initFn(f: *const Fn) Value;
pub fn initBuiltinFn(f: BuiltinFnType) Value;
pub fn initAtom(a: *Atom) Value;
pub fn initVolatile(v: *Volatile) Value;
pub fn initRegex(r: *Pattern) Value;
pub fn initProtocol(p: *Protocol) Value;
pub fn initProtocolFn(pf: *const ProtocolFn) Value;
pub fn initMultiFn(m: *MultiFn) Value;
pub fn initLazySeq(ls: *LazySeq) Value;
pub fn initCons(c: *Cons) Value;
pub fn initVarRef(v: *Var) Value;
pub fn initDelay(d: *Delay) Value;
pub fn initReduced(r: *const Reduced) Value;
pub fn initTransientVector(tv: *TransientVector) Value;
pub fn initTransientMap(tm: *TransientArrayMap) Value;
pub fn initTransientSet(ts: *TransientHashSet) Value;
pub fn initChunkedCons(cc: *const ChunkedCons) Value;
pub fn initChunkBuffer(cb: *ChunkBuffer) Value;
pub fn initArrayChunk(ac: *const ArrayChunk) Value;
pub fn initWasmModule(m: *WasmModule) Value;
pub fn initWasmFn(f: *const WasmFn) Value;

// Extractors — return same types as constructors take
pub fn asBoolean(self: Value) bool;
pub fn asInteger(self: Value) i64;
pub fn asFloat(self: Value) f64;
pub fn asChar(self: Value) u21;
pub fn asString(self: Value) []const u8;
pub fn asSymbol(self: Value) Symbol;
pub fn asKeyword(self: Value) Keyword;
pub fn asList(self: Value) *const PersistentList;
pub fn asVector(self: Value) *const PersistentVector;
// ... (one per heap type)
```

**Note on string/symbol/keyword**: In 27.1, `initString`/`initSymbol`/`initKeyword`
take inline values (same as current union payload). When switching to NaN boxing in
27.3, these become heap pointers — the init methods will need allocator parameters.
This signature change is a small delta since all call sites already use the API.

### 27.2: Call Site Migration

Migrate ALL Value access outside value.zig to use API methods.

**Migration patterns**:

| Before                         | After                                                       |
|--------------------------------|-------------------------------------------------------------|
| `Value{ .integer = 42 }`       | `Value.initInteger(42)`                                     |
| `.{ .integer = 42 }`           | `Value.initInteger(42)`                                     |
| `.nil`                         | `Value.nil`                                                 |
| `.{ .boolean = true }`         | `Value.true_val`                                            |
| `switch (v) { .int => \|i\| }` | `switch (v.tag()) { .int => { const i = v.asInteger(); } }` |
| `v == .nil`                    | `v == Value.nil`                                            |
| `v != .nil`                    | `v != Value.nil`                                            |
| `v.integer`                    | `v.asInteger()`                                             |
| `v.string`                     | `v.asString()`                                              |

**File migration order** (4 groups, roughly by complexity):

Group 1 — Leaf builtins (simple, few patterns):
atom, regex_builtins, system, file_io, transient, chunk,
keyword_intern, bencode, wasm/types, wasm/builtins

Group 2 — Core builtins (medium):
arithmetic, numeric, math, strings, clj_string, predicates,
io, metadata, misc, multimethods, ns_ops, eval, registry

Group 3 — Infrastructure (complex):
sequences, collections (builtin), collections (common),
analyzer, node, form, error, gc, macro, namespace, var, eval_engine

Group 4 — Execution core (critical):
value.zig (internal methods), compiler, chunk (bytecode),
opcodes, bootstrap, vm, tree_walk, main, nrepl

**Strategy**: One file per commit (small files may batch). Test after each.
Estimated ~15-20 commits.

### 27.3: NaN Boxing Switch

Change Value from union(enum) to NaN-boxed u64. Only value.zig internals change.

**Sub-steps**:
1. Create HeapString wrapper for `[]const u8` slices
2. Heap-allocate Symbol and Keyword (change init* signatures to take allocator)
3. Rewrite Value as `pub const Value = enum(u64) { ... }` or opaque u64 wrapper
4. Implement all tag()/init*/as* methods with bit manipulation
5. Handle integer i64→i48 narrowing (overflow → float promotion)
6. Update GC to trace NaN-boxed heap pointers
7. Update value.zig internal methods (formatPrStr, eql, hash, etc.)

**Key design decisions for 27.3**:
- HeapString = struct { data: []const u8 } — simple wrapper, one extra indirection
- Symbol/Keyword heap-allocated via GC — immutable, sharing via pointer is safe
- i48 range: ±140,737,488,355,327 — overflow promotes to float (matches D72/24A.4)
- GC tracing: HeapTag encodes type → GC knows how to trace each heap object

### 27.4: Benchmark + Verify

Run full benchmark suite, compare with Phase 24 baseline.

**Expected gains**:
- Memory: 6x reduction in Value-heavy structures
- Speed: Better cache utilization → faster collection operations
- VM: Stack fits in L1/L2 cache more often

## Scope Estimate

| Sub-phase | Commits | Effort |
|-----------|---------|--------|
| 27.1      | 1       | Small  |
| 27.2      | 15-20   | Large  |
| 27.3      | 3-5     | Medium |
| 27.4      | 1       | Small  |

## Risks

1. **String/Symbol/Keyword heap migration** (27.3): Adding allocator to init methods
   requires updating all call sites again. Mitigated: call sites already use API,
   so change is mechanical (add allocator arg).

2. **i48 integer narrowing**: Some code may assume i64 range. Need to audit
   integer operations for overflow handling.

3. **GC changes**: Heap pointer encoding changes how GC discovers roots.
   Need to update GC tracing to understand NaN-boxed values.

4. **Performance regression during 27.2**: Adding method calls (even inline) may
   change codegen. Monitor with periodic benchmark checks.

5. **40-bit address space**: macOS ARM64 currently uses <33 bits. If future OS
   uses more, HeapTag bits may conflict. Mitigated: monitor and adjust.
