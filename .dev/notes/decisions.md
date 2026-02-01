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

## D3a: Error Module — Threadlocal as Temporary Compromise

**Status**: Known violation of D3. Scheduled for resolution in Phase 2a (Task 2.1).

**Current state**: `src/common/error.zig` uses `threadlocal var last_error` and
`threadlocal var msg_buf` to pass error details alongside Zig error unions.
This was carried over from Beta's pattern for expediency during Phase 1.

**Why it exists**: Zig error unions carry no payload. When Reader returns
`error.NumberError`, the caller needs to know *which* number and *where*.
Threadlocal storage is the simplest bridge.

**When to fix**: Phase 2a, Task 2.1 (Create Env). When VM/Env becomes an
explicit instance, error context should move into it:

```zig
// Current (threadlocal — violates D3):
threadlocal var last_error: ?Info = null;
pub fn setError(...) Error { last_error = ...; return ...; }

// Target (instance-based — satisfies D3):
pub const ErrorContext = struct {
    last_error: ?Info = null,
    msg_buf: [512]u8 = undefined,
};
// Reader, Analyzer, VM each hold *ErrorContext (or own one)
```

**Migration difficulty**: Low. `setError`/`getLastError` call sites
just add a context parameter. The refactoring is mechanical.

**Why not fix now**: Reader and Analyzer (Phase 1) don't have an instance
context yet. Introducing ErrorContext before Env exists would create a
standalone struct with no clear owner. Better to unify when Env is built.

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
