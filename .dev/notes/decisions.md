# Design Decisions

Key design decisions for ClojureWasm production version.
Each decision references future.md sections and Beta lessons.

These will eventually be promoted to formal ADRs in `docs/adr/` at release time.

---

## D1: Value Representation — Tagged Union First, NaN Boxing Later

**Decision**: Start with a standard Zig tagged union for Value. Defer NaN boxing
to a later optimization phase.

**Rationale** (future.md SS3, SS5, SS7):
- NaN boxing is a native-route optimization that doesn't apply to wasm_rt
- Getting correctness right with a simple tagged union is easier to debug
- Beta's 28+ variant tagged union worked; the issue was maintenance cost, not performance
- NaN boxing can be introduced as a comptime switch without changing the API surface

**Consequence**: Initial performance will be similar to Beta. NaN boxing optimization
becomes a Phase 4 task with measurable benchmarks before/after.

**Fallback**: If NaN boxing proves too complex, the tagged union remains viable
(Beta proved this at 1036 tests, 545 functions).

---

## D2: GC Strategy — Arena Stub First, Real GC Later

**Decision**: Start with ArenaAllocator + no-op GC (allocate only, bulk free at
program exit). Implement real GC when memory pressure testing demands it.

**Rationale** (future.md SS5):
- Beta's GC lessons (fixup exhaustiveness, safe point, deep clone) are complex
- Getting Reader/Analyzer/VM correct without GC interference reduces bug surface
- GcStrategy trait (SS5) allows swapping in real GC without API changes
- Arena-only is sufficient for short-lived evaluations and tests

**Consequence**: Long-running programs will leak memory until real GC is implemented.
This is acceptable for Phase 1-3 development.

**When to implement real GC**: When benchmark suite (Phase 3.15) shows memory
usage exceeding reasonable bounds for test workloads.

---

## D3: Instantiated VM — No Threadlocal from Day One

**Decision**: VM is an explicit struct instance passed as parameter. No global
or threadlocal state anywhere.

**Rationale** (future.md SS15.5):
- Beta used 8 threadlocal variables in defs.zig, making embedding impossible
- Instantiated VM enables: multiple VMs in one process, library embedding mode,
  clean testing (each test gets fresh VM)
- Removing threadlocal after the fact was identified as the "biggest design change"
  needed for the library mode (SS15.5)

**Consequence**: Every function that needs VM context must receive it as a parameter
(or through a Context struct). Slightly more verbose but much cleaner.

---

## D3a: Error Module — ErrorContext Instance

**Status**: Done (Phase 2a, Task 2.1).

**Problem**: `src/common/error.zig` used `threadlocal var last_error` and
`threadlocal var msg_buf` to pass error details alongside Zig error unions.
This violated D3 (no threadlocal).

**Solution**: Introduced `ErrorContext` struct with instance methods
(`setError`, `setErrorFmt`, `getLastError`). Reader and Analyzer now hold
`*ErrorContext` and route all error operations through it. Env owns the
ErrorContext, and all threadlocal variables have been removed.

```zig
pub const ErrorContext = struct {
    last_error: ?Info = null,
    msg_buf: [512]u8 = undefined,

    pub fn setError(self: *ErrorContext, info: Info) Error { ... }
    pub fn setErrorFmt(self: *ErrorContext, ...) Error { ... }
    pub fn getLastError(self: *ErrorContext) ?Info { ... }
};
// Reader, Analyzer each hold *ErrorContext
// Env owns ErrorContext
```

---

## D3b: Error Kind Redesign — Python-Style Categories

**Status**: Done (Phase 1c). Implemented as standalone cleanup task.

**Problem**: Current `Kind` enum has 18 entries at inconsistent granularity.
Some are too fine (`invalid_string`, `invalid_character`, `invalid_regex` are
all "string-like parse errors"), while important categories are missing
(`io_error` for future slurp/spit). The mapping from Kind to Zig `error`
also has lossy collapses (`invalid_regex` → `error.InvalidToken`).

**Reference survey** (2026-02):

| Language    | Approach                          | Granularity       |
|-------------|-----------------------------------|--------------------|
| Python      | Hierarchical exception classes    | ~15 leaf classes   |
| Raku        | `X::` namespace, Phase × Category | ~50 types          |
| Rust        | Numbered codes (E0001+)           | ~800, no categories|
| Go          | Sentinel values, no taxonomy      | ad hoc             |
| Elm         | Phase-based, struct per error     | no enum            |
| SCI/Babashka| 2 types + message string          | minimal            |

**Decision**: Adopt Python-style categories. Two orthogonal axes:

1. `Phase` — when the error occurred (unchanged: parse, analysis, macroexpand, eval)
2. `Kind` — what went wrong (reorganized into ~12 Python-inspired categories)

**Target Kind enum**:

```zig
pub const Kind = enum {
    // Parse phase (Reader/Tokenizer)
    syntax_error,       // Structural: unexpected EOF, unmatched delimiters, invalid tokens
    number_error,       // Number literal parse failure (hex, radix, ratio, etc.)
    string_error,       // String/char/regex literal issues (bad escape, unterminated)

    // Analysis phase (Analyzer)
    name_error,         // Undefined symbol, unresolved var, invalid keyword
    arity_error,        // Wrong number of arguments
    value_error,        // Invalid binding form, duplicate map key, bad metadata

    // Eval phase (VM/TreeWalk)
    type_error,         // Operation applied to wrong type: (+ "a" 1)
    arithmetic_error,   // Division by zero, overflow
    index_error,        // nth/get out of bounds

    // IO (future: slurp, spit, file operations)
    io_error,

    // System
    internal_error,     // Implementation bug (unreachable reached)
    out_of_memory,      // Allocator failure
};
```

**Mapping from current → new**:

| Current (18)             | New (12)          | Notes                              |
|--------------------------|-------------------|------------------------------------|
| `unexpected_eof`         | `syntax_error`    | Phase=parse distinguishes          |
| `invalid_token`          | `syntax_error`    |                                    |
| `unmatched_delimiter`    | `syntax_error`    |                                    |
| `invalid_number`         | `number_error`    | Kept separate: common, actionable  |
| `invalid_character`      | `string_error`    |                                    |
| `invalid_string`         | `string_error`    |                                    |
| `invalid_regex`          | `string_error`    |                                    |
| `invalid_keyword`        | `name_error`      |                                    |
| `undefined_symbol`       | `name_error`      |                                    |
| `invalid_arity`          | `arity_error`     |                                    |
| `invalid_binding`        | `value_error`     |                                    |
| `duplicate_key`          | `value_error`     |                                    |
| `division_by_zero`       | `arithmetic_error`|                                    |
| `index_out_of_bounds`    | `index_error`     |                                    |
| `type_error`             | `type_error`      |                                    |
| `internal_error`         | `internal_error`  |                                    |
| `out_of_memory`          | `out_of_memory`   |                                    |

**Zig error union alignment**: Each Kind maps 1:1 to a Zig error tag.
`ReadError` becomes a subset: `{SyntaxError, NumberError, StringError, OutOfMemory}`.

**Error display direction** (Babashka-inspired, implement incrementally):

```
----- Error -------------------------------------------
Phase:    parse
Kind:     syntax_error
Message:  Unexpected end of input while reading list
Location: foo.clj:3:10
Context:
  2: (defn add [a b]
  3:   (+ a b)
              ^--- here
```

**Why Python-style**: Familiar to most developers. Categories are coarse
enough to stay stable (no need to add new Kinds for every new error message),
fine enough that programmatic handling (`catch SyntaxError`) is meaningful.

**Implementation summary** (Phase 1c):
- Kind: 18 -> 12 entries, 1:1 with Error tags (no lossy collapse)
- Removed: ReadError, AnalysisError type aliases
- Removed: parseError, parseErrorFmt, analysisError, analysisErrorFmt helpers
- Added: setErrorFmt (phase, kind, location, fmt, args) as single formatted helper
- Reader/Analyzer: simplified makeError/analysisError to call setError directly

---

## D4: Special Forms as comptime Table

**Decision**: Special forms are defined in a comptime array of BuiltinDef,
not as string comparisons in if-else chains.

**Rationale** (future.md SS10):
- Beta had special forms as hardcoded string comparisons in analyze.zig
- comptime table enables: exhaustiveness checking, automatic `(doc if)` support,
  VarKind tagging, and mechanical enumeration
- Adding a new special form requires exactly one table entry (not hunting through code)

**Initial special forms** (7): if, do, let, fn, def, quote, defmacro
**Added incrementally**: loop, recur, try, catch, throw, var, set!

---

## D5: core.clj AOT — But Start with Zig-Only Builtins

**Decision**: The AOT pipeline (core.clj -> bytecode -> @embedFile) is a Phase 3
goal. Phase 1-2 uses Zig-only builtins to get the system running.

**Rationale** (future.md SS9.6):
- AOT pipeline requires a working Compiler + VM first (chicken-and-egg)
- Beta proved that all-Zig builtins work (545 functions)
- The migration path is: Zig builtins -> add AOT pipeline -> move macros to core.clj
- This avoids blocking Phase 1-2 on a complex build system feature

**Bootstrap sequence** (SS9.6):
1. defmacro stays as special form in Zig Analyzer
2. core.clj Phase 1: use fn* and def only (no destructuring)
3. core.clj Phase 2: define defn using defmacro
4. core.clj Phase 3: use defn for everything else

---

## D6: Dual Backend with --compare from Phase 2

**Decision**: Implement TreeWalk evaluator alongside VM from Phase 2.
Wire --compare mode immediately.

**Rationale** (future.md SS9.2):
- Beta's --compare mode was "the most effective bug-finding tool"
- TreeWalk is simpler to implement correctly (direct Node -> Value)
- VM bugs often produce wrong values silently (not crashes)
- Catching mismatches early prevents compounding errors

**TreeWalk scope**: Minimal — correct but slow. Not optimized, not maintained
beyond reference correctness. If maintenance cost is too high, can be replaced
with a test oracle approach.

**Development rule** (enforced from Phase 3 onward):
When adding any new feature (builtin, special form, operator), implement it
in **both** backends and add an `EvalEngine.compare()` test verifying they
produce the same result. The Compiler may emit direct opcodes for performance
(e.g. `+` -> `add`); TreeWalk handles the same operations via builtin dispatch.

**File locations** (established in T2.9 / T2.10):

| Component  | Path                                   |
|------------|----------------------------------------|
| VM         | `src/native/vm/vm.zig`                 |
| TreeWalk   | `src/native/evaluator/tree_walk.zig`   |
| EvalEngine | `src/common/eval_engine.zig`           |

---

## D7: Directory Structure — future.md SS17

**Decision**: Follow SS17 directory layout exactly.

```
src/
  api/        # Public embedding API
  common/     # Shared between native and wasm_rt
    reader/
    analyzer/
    bytecode/
    value/
    builtin/
  native/     # Native fast-binary route
    vm/
    gc/
    optimizer/
    main.zig
  wasm_rt/    # Wasm runtime freeride route (stub initially)
    main.zig
  wasm/       # Wasm interop (both routes)
```

**Rationale**: Established in SS8 and SS17. comptime switching between
native/ and wasm_rt/ at build time. common/ holds all shared code.

---

## D8: VarKind Classification

**Decision**: Every Var is tagged with a VarKind indicating its dependency layer.

```
special_form  -> Compiler layer (if, do, let, fn, def, quote, defmacro, ...)
vm_intrinsic  -> VM layer (+, -, first, rest, conj, assoc, get, nth, ...)
runtime_fn    -> Runtime/OS layer (slurp, spit, re-find, atom, swap!, ...)
core_fn       -> Pure (core.clj AOT) (map, filter, take, drop, str, ...)
core_macro    -> Pure (core.clj AOT) (defn, when, cond, ->, and, or, ...)
user_fn       -> User-defined
user_macro    -> User-defined
```

**Rationale** (future.md SS10): Enables tracking what layer each function
depends on, which is critical for: impact analysis during refactoring,
migration progress from Zig to core.clj, and compatibility testing priority.

---

## D9: Collection Implementation — Array-Based Initially

**Decision**: Start with array-based collections (like Beta), add persistent
data structures later as an optimization.

**Rationale** (future.md SS9.5):
- Beta's ArrayList-based Vector/Map worked for correctness
- Persistent data structures (HAMT, RRB-Tree) are complex and interact with GC
- Profile first, optimize the bottleneck collection (likely Vector)

**Interface requirement**: All collection operations must go through a protocol/trait
so the backing implementation can be swapped without API changes.

---

## D10: English-Only Codebase

**Decision**: All source code, comments, commit messages, PR descriptions,
and documentation are in English.

**Rationale** (future.md SS0, CLAUDE.md):
- OSS readiness from day one
- Beta used Japanese comments/commits, which limited accessibility
- Agent response language is personal preference (configured in ~/.claude/CLAUDE.md)

---

## D11: Dynamic Binding — Global Frame Stack (Not Per-Var)

**Decision**: Dynamic bindings (`binding` macro) use a global frame stack,
not per-Var binding stacks.

**Alternatives considered**:
1. **Per-Var stack** (Clojure JVM style): Each Var holds its own ThreadLocal
   binding stack. Thread-safe by design.
2. **Global frame stack** (Beta style, chosen): A single stack of BindingFrame,
   each frame holding a map of Var -> Value overrides. push/pop per `binding` block.

**Rationale** (Task 2.2):
- Single-thread target (Wasm) makes per-Var ThreadLocal unnecessary overhead
- Global frame stack is simpler: one push/pop per `binding`, O(n) lookup on
  frame depth (typically shallow)
- Beta proved this works for all SCI tests and builtin functions

**Consequence**: Multi-thread support (future native mode) will require
redesigning this to either per-Var stacks or a concurrent frame structure.
This is acceptable since Wasm is the primary target.

**References**: future.md SS15.5, D3

---

## D12: Division Semantics — Float Now, Ratio Later

**Decision**: The `/` operator always returns float, even for `int / int`.
This is a deliberate simplification; Ratio type is deferred.

**Clojure JVM behavior** (reference):

| Expression    | Result       | Type     |
|---------------|--------------|----------|
| `(/ 6 3)`     | `2`          | Long     |
| `(/ 1 3)`     | `1/3`        | Ratio    |
| `(/ 1.0 3)`   | `0.333...`   | Double   |
| `(/ 1 0)`     | throws       | ArithmeticException |

Clojure JVM's `Numbers.divide()` computes GCD, returns Long if denominator
becomes 1, otherwise constructs `clojure.lang.Ratio` (BigInteger numerator +
BigInteger denominator, always in lowest terms).

**Our behavior** (simplified):

| Expression    | Result       | Type     |
|---------------|--------------|----------|
| `(/ 6 3)`     | `2.0`        | float    |
| `(/ 1 3)`     | `0.333...`   | float    |
| `(/ 1.0 3)`   | `0.333...`   | float    |
| `(/ 1 0)`     | error        | DivisionByZero |

**Beta behavior**: Same as ours — always float. Comment in Beta's vm.zig says:
"Clojure の / は常に有理数/浮動小数点を返すが、簡略化".

**Why not divTrunc**: The initial production VM used `@divTrunc` for `int / int`,
which made `(/ 1 3)` return `0`. This is incorrect for any Clojure semantics.
Always-float is a strictly better approximation than truncated integer division.

**Ratio type implications** (future):
- Requires BigInteger (or at least i128) for numerator/denominator
- GCD algorithm for automatic reduction to lowest terms
- Ratio participates in numeric promotion: `Ratio + int → Ratio`, `Ratio + float → float`
- Significant implementation effort; deferred until SCI test suite requires it

**VM fast-path concern**: The `div` opcode cannot use the same integer fast
path as `add`/`sub`/`mul`. Division always promotes to float first, making it
inherently slower. If Ratio is implemented, div becomes even more complex
(GCD computation per division). The bytecode compiler could potentially
strength-reduce known constant divisions, but error propagation (zero divisor)
makes this tricky — the error must surface at the right point in evaluation.

**When to implement Ratio**: When SCI Tier 1 tests (Phase 3.14) fail due to
precision loss from float approximation. Specifically, tests involving
`(= (/ 1 3) 1/3)` or ratio arithmetic.

---

## D13: OpCode Values — Beta-Compatible Layout

**Decision**: Production OpCode enum uses the same u8 values as Beta for all
shared opcodes. Category ranges are preserved identically.

**Layout** (both Beta and production):

```
0x00-0x0F  Constants    const_load=0x00, nil=0x01, true=0x02, false=0x03
0x10-0x1F  Stack        pop=0x10, dup=0x11
0x20-0x2F  Locals       local_load=0x20, local_store=0x21
0x30-0x3F  Upvalues     upvalue_load=0x30, upvalue_store=0x31
0x40-0x4F  Vars         var_load=0x40, var_load_dynamic=0x41, def=0x42
0x50-0x5F  Control      jump=0x50, jump_if_false=0x51, jump_back=0x54
0x60-0x6F  Functions    call=0x60, tail_call=0x65, ret=0x67, closure=0x68
0x70-0x7F  Loop/recur   recur=0x71
0x80-0x8F  Collections  list_new=0x80..set_new=0x83
0xA0-0xAF  Exceptions   try_begin=0xA0..throw_ex=0xA4
0xB0-0xBF  Arithmetic   add=0xB0..ge=0xB7
0xF0-0xFF  Debug        nop=0xF0, debug_print=0xF1
```

**Why keep Beta's values**:
- No technical reason to renumber. The category ranges are logical and have
  room for expansion (each category has 16 slots, we use 2-8).
- Preserves mental model when cross-referencing Beta's bytecode dumps.
- The gaps within categories (e.g., 0x52-0x53 reserved for jump_if_true/nil,
  0x61-0x64 for call_0..call_3) mark exactly where Beta's optimized variants
  live, making it clear what we intentionally deferred.

**Considered alternative — contiguous numbering**:
Could pack all 30 opcodes into 0x00-0x1D for a smaller switch jump table.
Rejected because: (a) Zig's switch on enum(u8) is already efficient regardless
of value distribution, (b) loses the category grouping which aids debugging,
(c) every future opcode addition would shift values and break any serialized
bytecode (not a concern yet, but free to avoid).

**Bug found during review**: `Chunk.emitLoop()` originally stored a negative
i16 bitcast to u16 for `jump_back`, but the VM interpreted `jump_back`'s operand
as unsigned (`frame.ip -= instr.operand`). This meant a distance of 3 became
65533 after bitcast, causing ip underflow. Beta avoids this because `emitLoop`
emits `.jump` (which uses `signedOperand()`), not `.jump_back`.

**Fix applied**: `emitLoop` now stores the positive distance directly.
`jump_back`'s contract is: operand = unsigned forward distance, VM subtracts it.
This is simpler and avoids the signed/unsigned confusion.

```zig
// Before (buggy): operand = @bitCast(-@as(i16, dist))  → 65533 for dist=3
// After (fixed):  operand = @intCast(dist)              → 3 for dist=3
// VM:             frame.ip -= instr.operand             → works correctly
```

**`jump` vs `jump_back` role clarification**:
- `jump`: signed operand via `signedOperand()`, can go forward or backward
- `jump_back`: unsigned operand, always backward (VM subtracts from ip)
- `jump_back` exists as a separate opcode so the VM can distinguish loop
  back-edges for future profiling/JIT hints, not for encoding reasons
