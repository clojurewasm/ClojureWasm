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

| Language     | Approach                          | Granularity         |
| ------------ | --------------------------------- | ------------------- |
| Python       | Hierarchical exception classes    | ~15 leaf classes    |
| Raku         | `X::` namespace, Phase × Category | ~50 types           |
| Rust         | Numbered codes (E0001+)           | ~800, no categories |
| Go           | Sentinel values, no taxonomy      | ad hoc              |
| Elm          | Phase-based, struct per error     | no enum             |
| SCI/Babashka | 2 types + message string          | minimal             |

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

| Current (18)          | New (12)           | Notes                             |
| --------------------- | ------------------ | --------------------------------- |
| `unexpected_eof`      | `syntax_error`     | Phase=parse distinguishes         |
| `invalid_token`       | `syntax_error`     |                                   |
| `unmatched_delimiter` | `syntax_error`     |                                   |
| `invalid_number`      | `number_error`     | Kept separate: common, actionable |
| `invalid_character`   | `string_error`     |                                   |
| `invalid_string`      | `string_error`     |                                   |
| `invalid_regex`       | `string_error`     |                                   |
| `invalid_keyword`     | `name_error`       |                                   |
| `undefined_symbol`    | `name_error`       |                                   |
| `invalid_arity`       | `arity_error`      |                                   |
| `invalid_binding`     | `value_error`      |                                   |
| `duplicate_key`       | `value_error`      |                                   |
| `division_by_zero`    | `arithmetic_error` |                                   |
| `index_out_of_bounds` | `index_error`      |                                   |
| `type_error`          | `type_error`       |                                   |
| `internal_error`      | `internal_error`   |                                   |
| `out_of_memory`       | `out_of_memory`    |                                   |

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
2. core.clj Phase 1: use fn\* and def only (no destructuring)
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

| Component  | Path                                 |
| ---------- | ------------------------------------ |
| VM         | `src/native/vm/vm.zig`               |
| TreeWalk   | `src/native/evaluator/tree_walk.zig` |
| EvalEngine | `src/common/eval_engine.zig`         |

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

| Expression  | Result     | Type                |
| ----------- | ---------- | ------------------- |
| `(/ 6 3)`   | `2`        | Long                |
| `(/ 1 3)`   | `1/3`      | Ratio               |
| `(/ 1.0 3)` | `0.333...` | Double              |
| `(/ 1 0)`   | throws     | ArithmeticException |

Clojure JVM's `Numbers.divide()` computes GCD, returns Long if denominator
becomes 1, otherwise constructs `clojure.lang.Ratio` (BigInteger numerator +
BigInteger denominator, always in lowest terms).

**Our behavior** (simplified):

| Expression  | Result     | Type           |
| ----------- | ---------- | -------------- |
| `(/ 6 3)`   | `2.0`      | float          |
| `(/ 1 3)`   | `0.333...` | float          |
| `(/ 1.0 3)` | `0.333...` | float          |
| `(/ 1 0)`   | error      | DivisionByZero |

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

---

## D14: Phase 3a Roadmap Revision — VM Parity Block

**Decision**: Restructure Phase 3a to address VM implementation gaps before
adding builtins. Delete redundant T3.2 (comparison intrinsics), add VM parity
tasks, and reorder BuiltinDef registry earlier.

**Problem** (discovered after T3.1 completion):

1. T3.2 (comparison intrinsics) was redundant — =, not=, <, >, <=, >= were
   all implemented as part of T3.1 alongside arithmetic intrinsics.
2. VM coverage was only 55% (21/38 opcodes). The Compiler can emit bytecode
   for all 13 Node types, but the VM cannot execute many of them.
3. Non-intrinsic builtins (first, rest, nil?, etc.) rely on `var_load` + `call`,
   but `var_load` was not implemented in the VM — D6 rule violation risk.
4. BuiltinDef registry (T3.7) was positioned after builtin implementations,
   but it is the registration infrastructure they depend on.

**Changes**:

| Action  | Task                      | Detail                                              |
| ------- | ------------------------- | --------------------------------------------------- |
| DELETE  | T3.2 (old)                | Comparison intrinsics — already done in T3.1        |
| ADD     | T3.2 (new)                | VM var/def opcodes: var_load, var_load_dynamic, def |
| ADD     | T3.3 (new)                | VM recur + tail_call opcodes                        |
| ADD     | T3.4 (new)                | VM collection + exception opcodes                   |
| REORDER | T3.7 -> T3.5              | BuiltinDef registry moved before builtins           |
| RENUM   | T3.3-T3.6 -> T3.6-T3.9    | Remaining builtins renumbered                       |
| RENUM   | T3.8-T3.15 -> T3.10-T3.17 | Phases 3b, 3c shifted by +2                         |

**upvalue_load/upvalue_store note**: These opcodes exist in opcodes.zig but
are unused — the VM uses closure_bindings (stack injection) instead, and
captured variables are accessed via local_load. Removal is out of scope for
this revision but noted as future cleanup.

**Total task count**: 37 -> 39 (added 3, deleted 1)

---

## D8: swap! — Builtin-only Function Dispatch (T3.9)

**Decision**: `swap!` currently only supports calling `builtin_fn` values.
Calling user-defined `fn_val` (closures) returns TypeError.

**Rationale**:

- BuiltinFn signature is `fn(Allocator, []const Value) anyerror!Value` — no
  access to the evaluator context (VM or TreeWalk)
- Calling fn_val requires the VM to push a call frame or TreeWalk to invoke
  `runCall`, which BuiltinFn cannot do
- Beta solved this with a global `defs.call_fn` function pointer, but that
  couples builtins to the evaluator and is not compatible with instantiated VM

**Future path** (Phase 3b+):

- When higher-order functions (map, filter, reduce) are implemented in core.clj,
  they will be Clojure-level functions that the compiler can emit call opcodes for
- For swap! with user-defined functions, options:
  (a) Add EvaluatorContext parameter to BuiltinFn (breaking change)
  (b) Compile swap! as a special form (compiler handles the call)
  (c) Implement swap! in core.clj using lower-level atom primitives

---

## D15: Macro Expansion Architecture (T3.10)

**Decision**: Macro expansion happens in the Analyzer via Env lookup + TreeWalk
execution bridge. fn_val macros are executed through a `macro_eval_fn` callback.

**Key design choices**:

1. **Analyzer holds `env: ?*Env`**: Optional to preserve backward compat with
   env-less analysis (Phase 1c tests). When present, enables macro resolution.

2. **macro_eval_fn callback**: Analyzer cannot depend on TreeWalk directly
   (would create circular dependency common/ -> native/). Instead, the host
   provides a callback `fn(Allocator, Value, []const Value) anyerror!Value`.

3. **Module-level macro_eval_env**: The macroEvalBridge function needs an Env
   to create a TreeWalk instance for fn_val execution. Since the bridge has
   a fixed signature, Env is passed via module-level variable (set/restored
   in evalString). This is acceptable for single-threaded execution.

4. **core.clj via @embedFile**: Source is compiled into the binary. No runtime
   file I/O needed for bootstrap.

5. **loadCore namespace switching**: core.clj is evaluated with current_ns set
   to clojure.core, then new bindings are re-referred into user namespace.

**Deferred**:

- cond, ->, ->> macros require loop/let/seq?/next (implement when available)
- loadCore macro_names list is hardcoded (generalize when more macros added)
- VM-side macro expansion not needed (macros expand at Analyzer level)

---

## D16: Directory Structure Revision (T4.0)

**Decision**: Revise the project directory structure to match the dual-track
architecture described in future.md SS8/SS17.

**Key changes from Phase 1-3 layout**:

1. `src/wasm_rt/gc/` — Unified GC directory (bridge + backend) instead of
   separate gc/ under native/ only
2. `src/repl/` — New top-level directory for REPL + nREPL subsystem
   (not a subdirectory of native/ since REPL is shared)
3. `src/api/` — Public embedding API (eval, plugin), clearly separated from
   internal modules
4. `src/wasm/` — FFI for external .wasm modules, distinct from `wasm_rt/`
   which is the internal Wasm runtime track

**Rationale**: README.md was rewritten to show the target directory structure.
Physical directory creation is deferred to Phase 4f (T4.14/T4.15) to avoid
touching working code. The structure is documented first, implemented later.

**Note**: Some `common/` modules may need track-specific variants as the Wasm
track matures (value, bytecode, builtins), due to different Value representations
(externref/i31ref) and GC strategies.

---

## D17: YAML Status Management (T4.0)

**Decision**: Introduce structured YAML files in `.dev/status/` for tracking
implementation progress and benchmarks.

**Files**:

| File         | Content                                    |
| ------------ | ------------------------------------------ |
| `vars.yaml`  | Var implementation status (29 namespaces)  |
| `bench.yaml` | Benchmark results and optimization history |
| `README.md`  | Schema definitions, yq query examples      |

**Schema** (vars.yaml):

```yaml
vars:
  clojure_core:
    "+":
      type: function # upstream Clojure classification
      status: done # todo | wip | partial | done | skip
      impl: intrinsic # special_form | intrinsic | host | bridge | clj | none
      note: "optional"
```

**`impl` field** (unified from former `impl_type` + `layer`):

| impl           | Meaning                                        |
| -------------- | ---------------------------------------------- |
| `special_form` | Analyzer direct dispatch                       |
| `intrinsic`    | VM opcode fast path                            |
| `host`         | Zig BuiltinFn — Zig required (Value internals) |
| `bridge`       | Zig BuiltinFn — .clj migration candidate       |
| `clj`          | Defined in .clj source                         |
| `none`         | Not yet implemented                            |

The former `impl_type` + `layer` two-field system was consolidated because
most combinations were fixed (intrinsic→host, special_form→host, clj→pure).
Only `builtin` had a meaningful host/bridge split, now expressed directly.

**Differences from Beta's status/vars.yaml**:

- `impl: intrinsic` — new (VM opcode direct execution; Beta lumped into builtin)
- `impl: clj` — new (Clojure source definitions; Beta was all-Zig)
- `impl: bridge` — explicit .clj migration candidates (Beta had no such distinction)
- 29 namespaces (Beta had ~15), including JVM-specific ones marked as skip
- All comments and notes in English (D10 compliance)

**Workflow integration** (CLAUDE.md):

- Session start: check vars.yaml for coverage stats
- Task completion: update vars.yaml if new Vars were implemented
- Performance tasks: append to bench.yaml history

**Generation**: `scripts/generate_vars_yaml.clj` generates the initial YAML
from Clojure JVM's `ns-publics`. Status is then manually updated based on
registry.zig, core.clj, and analyzer cross-reference.

**Query tool**: `yq` (available in nix develop). See `.dev/status/README.md`
for query examples.

---

## D14: VM-TreeWalk Closure Incompatibility

**Date**: 2026-02-02
**Context**: T4.5 — attempting to run SCI tests with EvalEngine.compare()

**Problem**: TreeWalk creates Node-based closures (fn_val wrapping FnNode).
VM creates bytecode-based closures (Fn wrapping FnProto). These are
incompatible — VM cannot execute TreeWalk closures and vice versa.

**Impact**: `loadCore()` evaluates core.clj via TreeWalk, defining macros
and functions as TreeWalk closures. When the VM encounters a `call` opcode
for these Vars, it finds a fn_val it cannot execute.

**Decision**: Defer full SCI compare-mode validation (T4.5) until the AOT
pipeline (T4.6/T4.7) compiles core.clj to bytecode that both backends can
use. The 67+ existing EvalEngine.compare() tests provide strong builtin
parity validation in the interim.

**Alternatives considered**:

- Dual-bootstrap (run core.clj in both backends separately): would diverge
  macro expansion state and complicate Env sharing
- Interpreter-neutral closure representation: too invasive for current phase

---

## D18: evalStringVM — Hybrid Bootstrap Architecture (T4.6)

**Date**: 2026-02-02
**Context**: T4.6 — AOT-less pipeline for running user code through VM

**Problem**: core.clj defines macros (defn, when, cond, etc.) that must be
available before user code runs. Full AOT compilation (core.clj -> bytecode
-> @embedFile) requires macro serialization which is unsolved. How to run
user code through the VM when core.clj bootstrap depends on TreeWalk?

**Decision**: Hybrid approach — bootstrap core.clj via TreeWalk (as before),
then compile+run user code through Reader -> Analyzer -> Compiler -> VM.
The VM receives a `fn_val_dispatcher` callback that routes calls to
TreeWalk-defined closures (macros, core fns) back through TreeWalk.

**Key mechanism**: `FnKind` discriminator on Fn struct (`.bytecode` vs
`.treewalk`). When the VM encounters a `.treewalk` fn_val during `call`,
it delegates to `fn_val_dispatcher` instead of interpreting bytecode.

**Alternatives considered**:

1. **Full AOT** (T4.7): Compile core.clj to bytecode at build time, embed
   via @embedFile. Blocked by macro serialization — defmacro bodies are
   fn_val closures that reference the Analyzer/Env, not easily serializable
   to bytecode constants.
2. **Dual bootstrap** (run core.clj through VM too): Would require the VM
   to already support all special forms and builtins that core.clj uses
   during its own bootstrap — circular dependency.
3. **Re-evaluate core.clj per call**: Too slow. core.clj defines 40+ vars.

**Consequence**: Performance is suboptimal — TreeWalk dispatch for core fns
adds overhead vs native bytecode execution. This is acceptable because:
(a) most computation happens in user code (VM-compiled), (b) the hybrid
approach validates VM correctness against TreeWalk, and (c) full AOT (T4.7)
remains the planned optimization path.

**Future direction**: T4.7 (AOT bytecode startup) will eliminate the hybrid
by compiling core.clj to bytecode at build time. This requires solving
macro body serialization — likely by storing macro bodies as bytecode
FnProto references rather than TreeWalk Node references.

---

## D19: Multi-Arity Fn — Multiple FnProto Approach (T4.8)

**Date**: 2026-02-02
**Context**: T4.8 — implementing multi-arity function dispatch

**Problem**: Clojure supports multi-arity functions:
`(fn ([x] x) ([x y] (+ x y)))`. Each arity has a different parameter
count and body. How to represent this in bytecode?

**Decision**: Store additional arities as `extra_arities: ?[]const *const anyopaque`
on the Fn struct. The primary arity is in `proto`, extras are FnProto pointers.
At call time, `findProtoByArity` selects the matching FnProto by argument count.

**Alternatives considered**:

1. **Embedded jump table in single FnProto**: One bytecode chunk with a
   dispatch header that jumps to the right arity body. Smaller allocation
   (one FnProto), but complicates: local_count (must be max across arities),
   bytecode layout (offset calculations), and debugging (dump shows merged code).
2. **Wrapper fn with if-else**: Emit a single FnProto that checks arg count
   and branches. Similar problems to jump table, plus wastes cycles on
   runtime branching even for single-arity fns.
3. **Fn subtype**: Create a separate MultiArityFn struct. Increases type
   complexity in Value union; every fn call site needs type dispatch.

**Why multiple FnProtos**: Each arity compiles independently with its own
local_count, constants, and code. No special bytecode layout needed.
The dispatch cost (linear scan of extra_arities) is negligible since
Clojure functions rarely have more than 3-4 arities.

**Closure interaction**: All arities share the same closure_bindings.
The `closure` opcode preserves extra_arities from the template Fn.

**Variadic in multi-arity**: `findProtoByArity` tries exact match first,
then falls back to variadic arities (where `arg_count >= arity - 1`).
This matches Clojure semantics where `& rest` catches overflow args.

---

## D20: vm_intrinsic Runtime Fallbacks (T4.6 bugfix)

**Date**: 2026-02-02
**Context**: Discovered during T4.6 — `(reduce + [1 2 3])` failed

**Problem**: Arithmetic/comparison operators (+, -, \*, /, <, >, etc.) are
registered as `vm_intrinsic` with `func = null`. The Compiler emits direct
opcodes (add, sub, mul) for `(+ 1 2)`, so no function call happens. But
when these operators are used as first-class values — `(reduce + [1 2 3])`,
`(map inc xs)`, `(apply + args)` — the VM does `var_load "+"` which
returns nil because func is null.

**Decision**: Add runtime fallback functions to all 12 arithmetic/comparison
intrinsics. Each vm_intrinsic now has a `func` field pointing to a Zig
function that implements the variadic version of the operation.

**Why not compile-time specialization**: The Compiler could detect
`(reduce + ...)` and emit specialized bytecode. But this would require
the Compiler to understand higher-order function semantics, which is
complex and fragile. The simpler solution is to make the operator values
callable.

**Implementation detail**: Fallback functions reuse the same `binaryArith`
and `compareValues` helpers as the VM opcodes. For variadic calls,
they fold left: `(+ 1 2 3)` -> `binaryArith(binaryArith(1,2), 3)`.
Zero-arg cases return identity values: `(+)` -> 0, `(*)` -> 1.

**Performance note**: First-class usage goes through `var_load` + `call`
(function dispatch), which is slower than the direct opcode path. This
is intentional — the common case `(+ a b)` still uses the fast `add`
opcode. The fallback only activates for higher-order patterns.

## D21: for macro as Analyzer special form

**Decision**: Implement `for` as an Analyzer special form rather than a
macro in core.clj.

**Rationale**: The `for` expansion requires structural recursion over
binding pairs and modifier keywords (:when, :let, :while), generating
nested map/apply/concat calls. Doing this at the Node level in the
Analyzer is more straightforward than generating Forms in a core.clj macro.

**Expansion**:

- Single binding: `(for [x coll] body)` -> `(map (fn [x] body) coll)`
- Nested: `(for [x c1 y c2] body)` -> `(apply concat (map (fn [x] <inner>) c1))`
- `:when test` -> `(if test (list body) (list))` + flatten via apply/concat
- `:let [binds]` -> `(let [binds] body)` wrapping

## D22: TreeWalk callClosure must save/restore recur state

**Bug**: Nested fn calls that internally use loop/recur (e.g., `map`
calling a fn that itself calls `map`) corrupted the outer loop's
`recur_args` buffer. The outer recur partially writes args, then a nested
fn call's inner loop overwrites `recur_args[0..N]`. When the outer recur
resumes, its earlier arg values are gone.

**Fix**: `callClosure` now saves/restores `recur_pending`, `recur_arg_count`,
and the entire `recur_args` array, same as it already did for `locals`.

**Impact**: This was blocking nested `map`, `reduce`, and any higher-order
fn that uses loop/recur internally when called from within another such fn.

## D23: Protocol dispatch via type-keyed PersistentArrayMap

**Decision**: Protocols use PersistentArrayMap for implementation dispatch.
`Protocol.impls` maps type-key strings ("string", "integer", etc.) to
method maps (PersistentArrayMap of method-name → fn_val).

**Type keys**: Runtime Value tags map to fixed strings via `valueTypeKey()`.
User-facing type names (String, Integer) map via `mapTypeKey()` in
extend-type. This follows Beta's pattern.

**Keyword-as-function**: Added (:key map) → (get map :key) dispatch in
TreeWalk.runCall. Keywords with 1-2 args perform map lookup on the first
arg. This was needed for defrecord field access.

## D24: defrecord as Form expansion

**Decision**: `defrecord` expands into Forms (not Nodes) and re-analyzes
through the normal pipeline: `(def ->Name (fn ->Name [fields] (hash-map ...)))`.
This ensures proper local tracking via the Analyzer.

## D26: Remove TreeWalk vm_intrinsic Sentinel Dispatch (T6.6)

**Date**: 2026-02-02
**Context**: `(apply + [1 2])` failed because TreeWalk returned a keyword
sentinel for vm_intrinsic Vars instead of the `builtin_fn` pointer.

**Problem**: TreeWalk used `__builtin__` keyword sentinels to dispatch
arithmetic/comparison intrinsics in call position. When these Vars were
used as first-class values (e.g., `(apply + args)`, `(partial + 10)`),
the sentinel keyword was passed to `apply` which only accepted `builtin_fn`.

**Decision**: Remove sentinel dispatch from `resolveVar`. All Vars
(including vm_intrinsic) now return `v.deref()` — the `builtin_fn`
pointer set by D20's runtime fallback functions. TreeWalk's `runCall`
dispatches via `callBuiltinFn` for all builtins uniformly.

**Impact**: Arithmetic operators now go through the BuiltinFn variadic
path instead of the hand-coded `variadicArith`/`variadicCmp` fast path.
This may be slightly slower for multi-arg arithmetic, but is correct
for all use patterns. The `builtinLookup`/`isBuiltin`/`callBuiltin`
code remains for env-less fallback but is no longer reached in normal
operation.

**Consequence**: `apply`, `partial`, `comp`, `juxt`, `map`, `reduce`,
and any higher-order pattern with intrinsic operators now works correctly.

---

## D25: Benchmark System Design

**Decision**: 13 benchmarks across 5 categories with multi-language comparison.

**Context**: Phase 3 had 4 ad-hoc benchmarks (startup, fib30, arith_loop, higher_order).
As the implementation matured through Phase 4, a systematic benchmark suite was needed
to track performance regressions and guide optimization.

**Design choices**:

- `bench/` directory with per-benchmark subdirectories (self-contained)
- `meta.yaml` per benchmark for machine-readable metadata
- `run_bench.sh` as single entry point with option flags
- 8 comparison languages: C, Zig, Java, Python, Ruby, Clojure JVM, Babashka
- `--record` appends to `.dev/status/bench.yaml` (append-only history)
- `--hyperfine` for high-precision measurement when needed
- `clj_warm_bench.clj` for JIT-warmed JVM comparison
- `.clj` files shared between ClojureWasm, Clojure JVM, and Babashka runners
- `range` not available in ClojureWasm, so all benchmarks use loop/recur
- `swap!` limited to builtins (D8), so atom_swap uses reset!/deref pattern

**Categories**: computation (4), collections (4), HOF (2), state (1)

**Removed benchmarks**:

- `ackermann`: Stack depth limit in TreeWalk (segfault at ack(3,6)) — unfair comparison
- `str_concat`: Fixed 4KB buffer in `str` builtin limits scale to 1K — too trivial

**Parameter sizing**: All benchmarks complete in 10ms-1s on ClojureWasm, ideal for
hyperfine statistical measurement rather than wall-clock timing of long runs.

---

## D27: Lazy Sequence Global realize_fn Callback (T7.6)

**Date**: 2026-02-02
**Context**: T7.6 — implementing lazy sequences

**Problem**: LazySeq thunks need to be realized (evaluated) by builtins like
`first`, `rest`, `seq`. But builtins are `fn(Allocator, []Value) !Value` —
they have no access to the evaluator (TreeWalk/VM). How can a builtin
trigger evaluation of a zero-arg closure?

**Decision**: Use a module-level `pub var realize_fn` in value.zig. The host
(bootstrap.zig) sets this to `macroEvalBridge` before evaluation begins.
Builtins call `lazy_seq.realize(allocator)` which delegates to `realize_fn`.

**D3 tension**: This introduces a global mutable variable, which conflicts
with D3 (no threadlocal/global state). The precedent is D15's `macro_eval_env`
module-level variable, which was accepted for single-threaded execution.

**Alternatives considered**:

1. **Pass evaluator context to builtins**: Would require changing BuiltinFn
   signature to include EvaluatorContext. Invasive change affecting all 40+
   builtins, and creates coupling between common/ and native/.
2. **Realize in evaluator only**: TreeWalk/VM would realize before calling
   builtins. Would require wrapping every builtin call site with realization
   logic, and breaks composition (a builtin returning a lazy seq to another
   builtin wouldn't realize).
3. **Eager realization at cons boundary**: Defeats the purpose of laziness.

**Consequence**: The global callback works for single-threaded use. For future
multi-VM embedding (D3), realize_fn would need to be per-Env or per-context.
This is consistent with the D15 approach and can be refactored when needed.

**Additional design**: Added `Cons` value type (linked cell with first+rest)
to preserve laziness when `cons` is called with a lazy-seq rest. Without this,
`consFn` would realize the entire lazy chain eagerly.

---

## D28: VM Deferred for defmulti, defmethod, lazy-seq (T7.4, T7.6)

**Date**: 2026-02-02
**Context**: T7.4 (Multimethod) and T7.6 (Lazy sequences) — TreeWalk only

**Problem**: D6 requires new features in both TreeWalk and VM. However,
defmulti/defmethod and lazy-seq are high-level features that the VM cannot
currently support without significant work:

- **defmulti/defmethod**: Requires VM to handle MultiFn dispatch, method
  table lookup, and dynamic dispatch-fn evaluation. The Compiler would need
  new opcodes or a call-indirect mechanism.
- **lazy-seq**: Requires VM to create closures for thunks and realize them
  on demand. The realize callback architecture (D27) bridges to TreeWalk,
  which wouldn't work if the VM is the active evaluator for the thunk.

**Decision**: Implement in TreeWalk only. Compiler marks these node types
as `InvalidNode` (compile error if reached). This is consistent with D14
(VM-TreeWalk Closure Incompatibility) — the hybrid architecture (D18)
already accepts that core.clj features run through TreeWalk.

**Impact**: These features work in the default TreeWalk CLI mode and REPL.
VM mode (`evalStringVM`) cannot use them directly, but user code compiled
to VM bytecode can call core.clj functions that internally use multimethods
or lazy sequences (via the fn_val_dispatcher bridge from D18).

**Future**: When the AOT pipeline (T4.7) is implemented, these features
would need VM opcodes or a call-convention for dispatching through the VM.
This is tracked as a future extension of P1 (VM parity) in checklist.md.
