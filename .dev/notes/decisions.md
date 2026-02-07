# Design Decisions

Architectural decisions for ClojureWasm. Append-only; reference by searching `## D##`.
Only architectural decisions (new Value variant, subsystem design, etc.) — not bug fixes.

---

## D1: Value Representation — Tagged Union First, NaN Boxing Later

**Decision**: Start with a standard Zig tagged union for Value. Defer NaN boxing
to a later optimization phase.

**Rationale** (.dev/future.md SS3, SS5, SS7):

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

**Rationale** (.dev/future.md SS5):

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

**Rationale** (.dev/future.md SS15.5):

- Beta used 8 threadlocal variables in defs.zig, making embedding impossible
- Instantiated VM enables: multiple VMs in one process, library embedding mode,
  clean testing (each test gets fresh VM)
- Removing threadlocal after the fact was identified as the "biggest design change"
  needed for the library mode (SS15.5)

**Consequence**: Every function that needs VM context must receive it as a parameter
(or through a Context struct). Slightly more verbose but much cleaner.

---

## D3a: Error Module — ErrorContext Instance

**Status**: Superseded by D63 (Phase 19, BE1).

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

**Rationale** (.dev/future.md SS10):

- Beta had special forms as hardcoded string comparisons in analyze.zig
- comptime table enables: exhaustiveness checking, automatic `(doc if)` support,
  metadata tagging, and mechanical enumeration
- Adding a new special form requires exactly one table entry (not hunting through code)

**Initial special forms** (7): if, do, let, fn, def, quote, defmacro
**Added incrementally**: loop, recur, try, catch, throw, var, set!

---

## D5: core.clj AOT — But Start with Zig-Only Builtins

**Decision**: The AOT pipeline (core.clj -> bytecode -> @embedFile) is a Phase 3
goal. Phase 1-2 uses Zig-only builtins to get the system running.

**Rationale** (.dev/future.md SS9.6):

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

**Rationale** (.dev/future.md SS9.2):

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

## D7: Directory Structure — .dev/future.md SS17

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

## D9: Collection Implementation — Array-Based Initially

**Decision**: Start with array-based collections (like Beta), add persistent
data structures later as an optimization.

**Rationale** (.dev/future.md SS9.5):

- Beta's ArrayList-based Vector/Map worked for correctness
- Persistent data structures (HAMT, RRB-Tree) are complex and interact with GC
- Profile first, optimize the bottleneck collection (likely Vector)

**Interface requirement**: All collection operations must go through a protocol/trait
so the backing implementation can be swapped without API changes.

---

## D10: English-Only Codebase

**Decision**: All source code, comments, commit messages, PR descriptions,
and documentation are in English.

**Rationale** (.dev/future.md SS0, CLAUDE.md):

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

**References**: .dev/future.md SS15.5, D3

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
0x40-0x4F  Vars         var_load=0x40, var_load_dynamic=0x41, def=0x42, def_macro=0x43,
                        defmulti=0x44, defmethod=0x45, lazy_seq=0x46
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

## D15: Macro Expansion Architecture (T3.10)

**Note**: Partially superseded by D36. `macro_eval_fn` callback and
`initWithMacroEval` removed. Analyzer now imports `bootstrap.callFnVal` directly.
The `env: ?*Env` field and macro expansion via TreeWalk bridge remain valid.

**Decision**: Macro expansion happens in the Analyzer via Env lookup + TreeWalk
execution bridge. fn_val macros are executed through `bootstrap.callFnVal`.

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
architecture described in .dev/future.md SS8/SS17.

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

**Schema** (vars.yaml — updated by D31):

```yaml
vars:
  clojure_core:
    "+":
      type: function # upstream Clojure classification
      status: done # todo | wip | partial | done | skip
      note: "VM intrinsic opcode" # optional free text
```

Three fields: `type` (upstream classification), `status` (implementation
state), `note` (optional developer notes for deviations, constraints, etc.).

The former `impl` field (special_form, intrinsic, host, bridge, clj, none)
was removed in D31. Useful information migrated to `note`.

**Differences from Beta's status/vars.yaml**:

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
code was removed in T8.R1 (dead code cleanup).

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
- atom_swap originally used reset!/deref pattern (swap! fn_val support added later)

**Categories**: computation (4), collections (4), HOF (2), state (1)

**Removed benchmarks**:

- `ackermann`: Stack depth limit in TreeWalk (segfault at ack(3,6)) — unfair comparison
- `str_concat`: Fixed 4KB buffer in `str` builtin limits scale to 1K — too trivial

**Parameter sizing**: All benchmarks complete in 10ms-1s on ClojureWasm, ideal for
hyperfine statistical measurement rather than wall-clock timing of long runs.

---

## D28: VM Deferred for defmulti, defmethod, lazy-seq (T7.4, T7.6)

**Status**: **Fully superseded** — defmulti/defmethod in VM (D60),
lazy-seq in VM (D61), defprotocol/extend-type in VM (F96). All features on both backends.

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

---

## D29: nREPL Server — eval_arena for Code String Persistence (T7.8)

**Date**: 2026-02-02
**Context**: T7.8 (nREPL Server) — bencode-decoded code strings and eval lifetime

**Problem**: In the nREPL message loop, each bencode message is decoded into
a per-request arena that is freed after `dispatchOp` returns. However, the
`code` string extracted from the bencode dict points into this arena memory.
When `bootstrap.evalString` processes `def`/`defn`, it may intern symbol names
or source references that outlive the request arena — causing use-after-free
(segfault) on subsequent evals that reference those vars.

**Decision**: Copy the code string to `state.eval_arena` (which accumulates
and is never reset during the server lifetime) before passing it to
`evalString`. This ensures all source strings referenced by interned vars
remain valid for the lifetime of the server.

**Trade-off**: The eval_arena grows monotonically. For a development-time
nREPL server this is acceptable — typical sessions evaluate kilobytes of
code, not gigabytes. A future optimization could use a dedicated string
interning arena separate from the eval arena.

**Impact**: Cross-eval `def`/`defn` persistence works correctly. Verified
with integration tests (def x, defn square, multi-form defs).

---

## D30: Unified Arithmetic Helpers in arithmetic.zig (T8.R3)

**Date**: 2026-02-02
**Context**: Arithmetic/comparison logic was duplicated in three places:
`arithmetic.zig` (BuiltinFn variadic path), `vm.zig` (binary opcode
dispatch), and `tree_walk.zig` (removed in T8.R1). The `arithmetic.zig`
version also used wrapping operators (`+%`, `-%`, `*%`), which silently
wrapped on overflow instead of producing Zig's overflow behavior.

**Decision**: Make `arithmetic.zig` the single source of truth for
binary arithmetic, comparison, division, mod, and rem operations.
VM delegates to these shared helpers instead of maintaining its own
copies. Fixed wrapping operators to non-wrapping (`+`, `-`, `*`).

**Impact**: ~50 lines removed from VM. Semantics unified across
all evaluation paths. Wrapping arithmetic bug in first-class usage
(e.g., `(reduce + ...)`) is fixed.

---

## D31: VarKind Removal + vars.yaml impl Field Removal

**Date**: 2026-02-02
**Context**: VarKind (7-value enum) was only used in tests, not in
production code paths. The vars.yaml `impl` field (7 values) had
undocumented categories that kept growing. Upstream Clojure classifies
vars with only `:macro`, `:special-form`, and `:dynamic` metadata.

**Decision**: Remove VarKind enum entirely. Remove `impl` field from
vars.yaml. Useful implementation details move to `note` (free text).

**Changes**:

- `VarKind` enum deleted from `var.zig`
- `BuiltinDef.kind` and `Var.kind` fields removed
- All `BuiltinDef` definitions (97 occurrences) updated
- `vars.yaml` reduced to 3 fields: `type`, `status`, `note`
- `impl` values migrated to `note` where they add value:
  - `intrinsic` -> `"VM intrinsic opcode"` (12 entries)
  - `special_form` + `type: macro` -> `"analyzer special form in CW"` (8 entries)
  - `bridge` -> `"portable to clj"` (3 entries)
  - `host`, `clj`, `core_clj`, `zig_builtin` -> no note (standard, no deviation)

**Rationale**: Metadata like `macro`, `dynamic`, `doc`, `arglists`
already exists as explicit Var fields. VarKind added no runtime value.
The `impl` field in vars.yaml served a similar tracking purpose but
with categories that didn't map cleanly to upstream Clojure concepts.
Free-text `note` is more flexible and easier to maintain.

**Future**: Generic metadata map (T9.4) will handle arbitrary user
metadata. The remaining Var fields (macro, dynamic, doc, arglists,
added, since_cw) are sufficient for the Clojure metadata protocol.

## D32: Phase 9.5 Infrastructure Fixes before var expansion

**Date**: 2026-02-02
**Context**: Phase 9 complete (209/702 vars). Before continuing var expansion,
several infrastructure issues limit productivity and correctness.

**Problem**:

1. VM evalStringVM has use-after-free: compiler.deinit() frees fn objects
   still referenced by Env vars. Multi-form programs crash with
   "switch on corrupt value" panic on any program with `def` + subsequent call.
2. swap! only accepts builtin_fn, not fn_val (user closures). Workarounds
   needed throughout core.clj (e.g., `(swap! a + 1)` instead of `(swap! a inc)`).
3. `(seq map)` not implemented — blocks natural map iteration in HOFs like
   reduce-kv (currently uses keys+get loop workaround).
4. VM benchmarks cannot run (blocked by #1). No performance baseline exists.
5. `bound?` missing — defonce deferred in T9.11.

**Decision**: Insert Phase 9.5 (5 tasks) as a stabilization phase before
Phase 10 (next var expansion). Fix foundations first, measure VM perf second.

**Impact**: Delays var count growth temporarily but improves velocity afterward.
All 5 items are small, focused fixes rather than architectural changes.

## D36: Unified fn_val dispatch via callFnVal (T10.4)

**Context**: T10.4 (fn_val dispatch unification). Follow-up to D34.

**Problem**: 5 separate dispatch mechanisms for calling fn_val, each with its own
callback wiring and inconsistent kind-checking. Error-prone when adding new features.

**Solution**: Single `callFnVal(allocator, fn_val, args)` function in bootstrap.zig.
Routes by Value tag and Fn.kind:

- `builtin_fn` -> direct call
- `fn_val(.bytecode)` -> bytecodeCallBridge (creates new VM instance)
- `fn_val(.treewalk)` -> treewalkCallBridge (creates new TreeWalk)

All 5 callback sites now receive `&callFnVal` instead of `&macroEvalBridge`:

- vm.zig fn_val_dispatcher, tree_walk.zig bytecode_dispatcher
- atom.zig call_fn, value.zig realize_fn, analyzer.zig macro_eval_fn

**Alternatives considered**:

1. Keep callback pattern, unify the callback function (initial approach)
2. Create new fn_dispatch.zig module -> unnecessary file for one function
3. **Chosen**: Direct import of bootstrap.callFnVal from all sites

Zig 0.15.2 supports circular imports (verified with test project), so the
assumed circular dependency was not actually a problem. All module vars and
callback fields removed:

- atom.zig: `call_fn` module var removed, imports bootstrap directly
- value.zig: `realize_fn` module var removed, imports bootstrap directly
- analyzer.zig: `macro_eval_fn` field + `initWithMacroEval` removed
- vm.zig: `fn_val_dispatcher` field removed, imports bootstrap directly
- tree_walk.zig: `bytecode_dispatcher` field removed, imports bootstrap directly

bootstrap.zig setupMacroEnv/restoreMacroEnv simplified: only manages
macro_eval_env and predicates.current_env (2 remaining D3 exceptions).

**Impact**: Closes D34 follow-up. 5 dispatchers -> 1 function, 4 module
vars/fields eliminated, 3 D3 known exceptions removed.

## D37: Metadata System — `?*const Value` Map Approach (T11.1)

**Date**: 2026-02-02
**Context**: T11.1 — implementing Clojure metadata system

**Decision**: Store metadata as `?*const Value` (pointer to a map Value)
on all types that support Clojure's IMeta protocol. Collections already
had this field; added it to Fn and Atom.

**Design choices**:

- Collections (list, vector, map, set): `meta: ?*const Value = null` (immutable)
- Fn: `meta: ?*const Value = null` (immutable; with-meta returns new copy)
- Atom: `meta: ?*Value = null` (mutable; alter-meta!/reset-meta! mutate in place)
- Var: keeps specialized fields (doc, arglists, added, etc.) — no generic meta
  field added yet. Var is not a Value variant, so alter-meta! on Vars is deferred.
- Symbol/Keyword: no metadata support (rarely used in Clojure practice)

**Alternatives considered**:

1. **Specialized metadata structs per type** (FnMeta, AtomMeta, etc.):
   Type-safe but inflexible; doesn't match Clojure's generic map protocol.
2. **External metadata table** (identity -> meta map): Avoids struct changes
   but requires identity-based lookup and GC coordination.
3. **Chosen**: Inline `?*const Value` pointer — zero cost when null,
   consistent across types, matches Clojure's `(meta obj)` -> map semantics.

**Deferred**: ~~Var as Value variant (T11.2) — needed for `(meta #'var)`
and `(alter-meta! #'var f args)`.~~ Resolved in D39.

## D38: Reader Input Validation — Limits (T11.1b)

**Date**: 2026-02-02
**Context**: nREPL server (Phase 7c) is publicly accessible. Without Reader
input limits, malicious input can cause OOM or stack overflow.

**Decision**: Add Reader.Limits struct with configurable safety bounds applied
by default to all Reader instances:

- max_depth (1024): prevents stack overflow from deeply nested forms
- max_string_size (1MB): prevents memory exhaustion from huge strings
- max_collection_count (100K): prevents allocation pressure from massive literals
- File size: 10MB at CLI, 1MB at nREPL

**Implementation**: `enterDepth()` helper tracks nesting across readDelimited,
readWrapped, readDiscard, readMeta. Reader.initWithLimits for custom limits.

## D39: Var as Value Variant (T11.2)

**Date**: 2026-02-02
**Context**: T11.2 — making Var a first-class Value for `(var foo)`, `#'foo`,
and metadata operations on Vars.

**Decision**: Add `.var_ref: *Var` to the Value tagged union. The `var` special
form is handled by the Analyzer (not TreeWalk): it resolves the symbol to a Var
in the current Env and returns a constant node with `.var_ref` value.

**Key changes**:

- Value union: added `var_ref: *Var` variant (21st variant)
- Var struct: added `meta: ?*PersistentArrayMap` field for mutable metadata
- Analyzer: `var` special form resolves symbol -> Var at analysis time
- meta/alter-meta!/reset-meta!: extended to handle var_ref
- New builtins: var?, var-get, var-set (113 total, was 110)

**Alternatives considered**:

1. **New node type** (the_var node) evaluated at runtime: More consistent with
   how var_ref works, but unnecessary since Analyzer already has Env access.
2. **Chosen**: constant node with .var_ref value — simpler, works with both
   TreeWalk and VM (constant load opcode handles it automatically).

---

## D42: Regex Engine — Port from Beta + Analysis-Time Compilation (T11.5)

**Context**: Zig has no stdlib regex. Clojure regex literals `#"..."` need
a compiled regex engine for `re-find`, `re-matches`, `re-seq`.

**Decision**:

1. Port Beta's hand-rolled regex engine (recursive descent parser +
   backtracking matcher) into `src/common/regex/`.
2. Add `Pattern` struct to Value: `{ source, compiled (*const anyopaque), group_count }`.
   New Value variant `regex: *Pattern`.
3. Compile regex at **analysis time** (not runtime): `Form.regex` → `analyzeRegex` →
   Pattern constant. This means `#"\d+"` is compiled once during analysis,
   not on each evaluation.

**Rationale**:

- PCRE/POSIX dependency adds external C dep — unacceptable for Wasm target
- Beta's engine is proven and covers Java regex subset (classes, quantifiers,
  groups, backreferences, lookahead, inline flags)
- Analysis-time compilation matches Clojure semantics (regex literals are compiled once)

**Consequence**: New Value variant requires exhaustive switch updates across
10+ files. `anyopaque` for compiled field avoids circular imports between
value.zig and matcher.zig.

---

## D43: pop on Empty / nil — IllegalState Error (T12.1)

**Context**: Clojure `(pop [])` and `(pop nil)` throw IllegalStateException.
`(peek [])` and `(peek nil)` return nil.

**Decision**: `popFn` returns `error.IllegalState` for empty collections and
nil. `peekFn` returns `.nil` for the same cases. This asymmetry matches
Clojure's behavior: peek is safe (returns nil), pop is unsafe (throws).

---

## D44: empty on Non-Collection — Return nil (T12.1)

**Context**: Clojure `(empty "abc")` returns nil, `(empty 42)` returns nil.
Only ICollection types return an empty collection.

**Decision**: `emptyFn` returns `.nil` for all non-collection types (string,
integer, etc.) rather than TypeError. This matches Clojure semantics where
`empty` is defined on `IPersistentCollection` and returns nil for others.

---

## D45: sorted-map — Sorted PersistentArrayMap, Not Tree (T12.2)

**Context**: Clojure's `sorted-map` returns a `PersistentTreeMap` (red-black tree)
that maintains key ordering for all operations (assoc, dissoc, seq).

**Decision**: Implement `sorted-map` as a `PersistentArrayMap` with entries
sorted by key at construction time using insertion sort + `compareValues`.
Not a tree-based structure — subsequent `assoc` will append (not maintain
sort order). This matches Beta's approach and is sufficient for current needs.

**Trade-off**: `(assoc (sorted-map :b 2 :a 1) :aa 0)` won't maintain sort
order. A full `PersistentTreeMap` is deferred until SCI tests or user code
require sorted-map invariants across mutations.

**Ref**: Beta `src/lib/core/eval.zig:sortedMapFn` — same approach.

---

## D46: Reduced Value Variant + F23 Verification (T12.4)

**Context**: Adding `.reduced` as the 21st Value variant for early termination
in `reduce`. F23 required comptime verification that all critical switch
statements handle every variant.

**Decision**: Zig's exhaustive switch enforcement IS the comptime verification.
Adding `.reduced` to the Value union caused 8 compile errors at all switch
statements that didn't have `else =>` catch-alls, forcing explicit handling:

- `value.zig:formatPrStr` — print inner value (transparent)
- `value.zig:eql` — compare inner values
- `predicates.zig:typeFn` — returns `:reduced`
- `predicates.zig:satisfiesPred` — type key "reduced"
- `tree_walk.zig:valueTypeKey` — "reduced"
- `macro.zig:valueToForm` — maps to nil (non-data)
- `nrepl.zig:writeValue` — print inner value
- `main.zig:writeValue` — print inner value

**F23 resolution**: No separate comptime test needed. Zig's type system already
provides exhaustive verification. The 8 compile errors prove it works.
Mark F23 as resolved in checklist.

## D47: Namespace as Symbol in Value (T12.6)

**Context**: Implementing `all-ns`, `find-ns`, `ns-name`, `create-ns`, `the-ns`.
Clojure returns namespace objects from these functions, but ClojureWasm has
no `namespace` Value variant.

**Options considered**:

1. Add `.namespace` as 22nd Value variant — requires 8+ exhaustive switch updates
2. Represent namespace as symbol (its name) — simple, no structural changes

**Decision**: Option 2 — represent namespaces as symbols. Since namespace names
are unique in Env, a symbol unambiguously identifies a namespace. `find-ns`
returns a symbol or nil, `ns-name` returns its input symbol, `all-ns` returns
a list of symbols.

**Limitation**: No namespace identity — `(identical? (find-ns 'user) (find-ns 'user))`
returns false (symbol comparison, not reference equality). Acceptable for current
usage patterns. Can upgrade to a real Value variant later if protocols/records
need namespace objects.

## D48: SCI Test Port Methodology + compat_test.yaml (T12.9)

**Context**: Porting SCI core_test.cljc to ClojureWasm for compatibility validation.

**Decision**: Port SCI tests with inline test framework (no separate test.clj),
TreeWalk-only execution, and YAML-based test tracking.

**Key methodology**:

1. Inline test framework in test file (deftest/is/testing macros + run-tests)
2. Porting rules: `eval*` -> direct expr, `tu/native?` -> true branch, skip JVM-only
3. Helper functions defined outside `deftest` bodies (workaround for var resolution)
4. Binary search to find crash-causing tests in large file
5. Skip/workaround pattern for missing features rather than blocking on them

**Results**: 70/74 tests pass (248 assertions), 4 tests skipped.

**Missing features categorized**:

- Tier 1 (Zig builtin): list?, int?, reduce/2, set-as-function, deref delay,
  into map from pairs
- Tier 2 (core.clj): clojure.string namespace, {:keys [:a]} destructuring
- Behavioral: named fn self-ref identity, fn param shadowing, var :name meta

**F22 resolved**: `.dev/status/compat_test.yaml` introduced for test tracking.
**F24 deferred**: vars.yaml status refinement (stub/defer) not needed yet —
current `done/todo/skip` is sufficient. Will add when stub functions appear.

## D49: Local Bindings Shadow Special Forms (T13.2)

In Clojure, local bindings (fn params, let bindings) shadow special forms.
`(fn [if] (if 1))` treats `if` as the parameter value, not the special form.

**Implementation**: In `analyzer.zig:analyzeList`, check `findLocal(sym_name)`
before `special_forms.get(sym_name)`. If the head symbol is a local binding,
skip the special form handler and treat it as a regular function call.

This matches Clojure's behavior where locals always take priority.

## D50: Nested Map Destructuring Limitation (T14.5)

ClojureWasm destructuring supports single-level map patterns but not nested:

```clojure
;; Works
(let [{a :a b :b} m] ...)
(defn f [{x :x}] ...)

;; Not supported (F58)
(let [{{x :x} :b} m] ...)
(defn f [{{x :x} :nested}] ...)
```

**Scope**: Both `let` bindings and function arguments use the same `destructure`
function in core.clj. The limitation applies to both contexts.

**Workaround**: Use sequential bindings:

```clojure
(let [{b :b} m
      {x :x} b]
  x)
```

**Implementation path**: Modify `destructure` in core.clj to recursively process
map patterns when a binding form is itself a map. Requires detecting map patterns
vs symbol bindings during the binding pair iteration.

## D54: Namespace Separation — clojure.walk, clojure.template (T15.3)

Separated walk and template functions from core.clj into proper namespaces,
matching upstream Clojure directory structure:

| File                         | Content                             |
| ---------------------------- | ----------------------------------- |
| src/clj/clojure/core.clj     | (moved from src/clj/core.clj)       |
| src/clj/clojure/walk.clj     | walk, postwalk, prewalk, \*-replace |
| src/clj/clojure/template.clj | apply-template, do-template         |

**Bootstrap order** (in main.zig and bootstrap.zig):

1. loadCore() — clojure.core
2. loadWalk() — clojure.walk (depends on core)
3. loadTemplate() — clojure.template (depends on core + walk)
4. loadTest() — clojure.test (depends on core + walk for `are` macro)

**Design**: Each load function:

- Creates the namespace via `findOrCreateNamespace`
- Refers required bindings (core, and walk for template)
- Evaluates the embedded .clj source
- Re-refers new bindings into user namespace for convenience

**Limitation**: Fully-qualified references (`clojure.walk/postwalk`) do not work
without explicit require. This is a namespace resolution issue to address later.
Current workaround: Functions are auto-referred to user namespace at bootstrap.

---

## D56: VM Closure Capture — Per-Slot Array (T15.5.1)

**Problem**: The original `capture_base + capture_count` contiguous capture
approach failed when locals occupied non-contiguous stack slots. Example:

```
(defn outer []
  (myid (do (let [y 1] (defn inner [] y)) (inner))))
```

Here self-ref is at slot 0, `myid` var_load at slot 1 (not in locals),
`y` let binding at slot 2. The compiler sees `capture_base=0, capture_count=1`
but the VM reads slot 0 (self-ref) instead of slot 2 (the actual let binding).

**Decision**: Replace `capture_base: u16` with `capture_slots: []const u16`
in `FnProto`. Each slot index is recorded individually, allowing the VM to
capture from arbitrary non-contiguous stack positions.

**Changes**:

- `chunk.zig`: Added `capture_slots: []const u16 = &.{}` to FnProto
- `compiler.zig`: `emitFn` builds `capture_slots` array from `locals[].slot`
- `vm.zig`: Closure op reads `proto.capture_slots[i]` for each binding
- `compiler.zig`: `deinit` frees `capture_slots` when non-empty

**Consequence**: Resolves F75 (VM closure capture with named fn self-ref).
The closure instruction operand is simplified to just the constant index
(no more encoded capture_base).

---

## D57: Map-as-function and in-ns refers inheritance

**Context**: T16.1 — clojure.set implementation revealed two gaps:

1. Maps could not be called as functions in TreeWalk (`({:a 1} :key)`)
2. `(ns ...)` / `in-ns` created new namespaces that lost refers from
   loaded libraries (clojure.walk, clojure.set, etc.)

**Decision**:

1. Add `.map` IFn dispatch to TreeWalk `callValue` and `runCall`.
   VM already had this (performCall line 501-509).
2. Add refers inheritance to `inNsFn`: when creating a new namespace,
   copy `current_ns.refers` to the new namespace in addition to
   `clojure.core.mappings`.

**Rationale**: Both are standard Clojure behaviors. Maps implementing IFn
is fundamental to idiomatic Clojure. The refers inheritance ensures that
`are` macro (which uses `postwalk-replace` from clojure.walk) works after
`(ns ...)`.

**Note**: The proper fix for macro symbol resolution (macros should resolve
symbols in the namespace where they were defined) is a larger change.
The refers inheritance is a pragmatic workaround that covers most cases.

## D58: VM def_macro Opcode for User-Defined Macros (T16.6)

**Problem**: VM `def` opcode didn't preserve `is_macro` flag from DefNode.
User-defined macros registered via `defmacro` were stored as regular functions.
When subsequently called, they returned their expansion (a list) instead of
the expansion being evaluated.

**Root Cause**: Compiler's `emitDef` emitted `.def` for both regular defs and
macros. The `is_macro` flag was lost at compile time. TreeWalk handled this
correctly in `runDef` by checking `def_n.is_macro`.

**Fix**: Added `.def_macro` opcode (0x43) in the Var ops range. Compiler emits
`.def_macro` when `node.is_macro == true`. VM handles both `.def` and
`.def_macro` identically except `.def_macro` calls `v.setMacro(true)`.

**Impact**: Fixes F77. User-defined macros now work in all contexts including
threading macros (`->`, `->>`).

---

## D59: VM/TreeWalk Runtime Error → Exception Routing (T17.5.1)

**Problem**: try/catch only handled explicit `throw` (UserException). Zig runtime errors
(DivisionByZero, TypeError, ArityError) from builtins/arithmetic propagated through Zig error
mechanism, bypassing the VM/TreeWalk exception handler entirely.

**Solution**: Two-part fix:

1. **VM**: Extract `execute` loop body into `stepInstruction`, catch errors at loop level.
   `isUserError()` filter + `dispatchErrorToHandler()` synthesizes ex-info map and jumps to
   catch handler. Also fixed catch cleanup: `pop` → `pop_under` for correct body result.
2. **TreeWalk**: `runTry` checks `isUserError()` instead of only `error.UserException`.
   `createRuntimeException()` synthesizes ex-info map for non-throw errors.

**Error categories**:

- Catchable: TypeError, ArityError, UndefinedVar, DivisionByZero, Overflow, UserException
- Non-catchable: StackOverflow, OutOfMemory, InvalidInstruction

**Impact**: Unblocks `thrown?` macro, enables proper exception testing in test suite.

## D60: VM Multimethod Opcodes — defmulti/defmethod (T17.5.6)

**Problem**: D28 left defmulti/defmethod as TreeWalk-only. VM compiler returned
`error.InvalidNode` for these nodes, causing VM mode to fail on any multimethod code.

**Solution**: Two new opcodes + callFnVal IFn extension:

1. **Opcodes**: `defmulti` (0x44) pops dispatch_fn, creates MultiFn, binds to var.
   `defmethod` (0x45) pops method_fn + dispatch_val, adds to multimethod methods map.
2. **VM performCall**: `multi_fn` case calls dispatch_fn via `callFnVal`, looks up method
   in methods map (with `:default` fallback), calls matched method.
3. **bootstrap.callFnVal**: Extended with `multi_fn`, `keyword`, `map`, `set` IFn cases.
   This enables dispatch functions that are keywords (e.g., `(defmulti area :shape)`).

**Supersedes**: D28 TreeWalk-only restriction for defmulti/defmethod.
D28 is now fully superseded: lazy-seq (D61), defprotocol/extend-type (F96) also in VM.

**Impact**: F13 resolved. VM mode now supports full multimethod dispatch.

## D61: VM lazy-seq Opcode + collectSeqItems (T18.5.1)

**Context**: lazy-seq was TreeWalk-only (D28). VM compiler returned `error.InvalidNode` for
`lazy_seq_node`. Additionally, `concat`, `into`, `apply` only handled list/vector/nil,
causing TypeError when receiving lazy-seq or cons values.

**Decision**:

1. Added `lazy_seq = 0x46` opcode (Var operations range). Stack: [thunk_fn] → [lazy_seq_value].
2. Compiler `emitLazySeq`: compiles body_fn via `emitFn` (zero-arg closure), emits `.lazy_seq`.
3. VM handler: pops fn_val, creates `LazySeq{.thunk=fn, .realized=null}`, pushes.
4. Added `collectSeqItems` helper: walks cons chains, realizes lazy-seqs, handles all seq types.
5. Rewrote `concatFn`, `intoFn`, `applyFn`, `vecFn` to use `collectSeqItems`.

**Rationale**: Follows same pattern as D60 (defmulti/defmethod). The thunk is a closure
compiled by the existing `emitFn` path. Realization happens via `bootstrap.callFnVal`
which works for both VM and TreeWalk closures.

**Supersedes**: D28 lazy-seq TreeWalk-only restriction.

**Impact**: F14 + F95 resolved. tree-seq enabled. All lazy-seq operations work on both backends.

## D62: Transducer Foundation

**Context**: Transducers require map/filter to support 1-arity (transducer) form, conj to
support 0/1-arity, and deref to support reduced values. None of these were implemented.

**Decision**:

1. Added transducer (1-arity) forms to `map` and `filter` in core.clj.
2. Extended `conjFn` to support 0-arity (returns []) and 1-arity (returns coll).
3. Extended `derefFn` to support `.reduced` values (returns inner value).
4. Added `transduce` (pure Clojure, uses `reduce` instead of protocol-based coll-reduce).
5. Added `into` override in core.clj for 3-arity transducer support.
6. Added `cat`, `halt-when`, `dedupe`, `preserving-reduced`, `sequence` (1-arity).
7. `halt-when` uses `:__halt` instead of `::halt` (auto-qualified keywords not supported).

**Rationale**: Transducers are fundamental to Clojure's composable data transformation model.
The simplified `transduce` (plain reduce) works because our reduce already handles `reduced?`
early termination. The `into` override in core.clj shadows the Zig builtin to add 3-arity.

**Impact**: 383 done vars. Foundation for further transducer-returning functions.

---

## D63: Error System — Threadlocal (Supersedes D3a)

**Context**: D3a introduced instance-based ErrorContext to avoid threadlocal.
However, this caused error info loss: ErrorContext lived on evalString()'s stack,
and when errors propagated to main(), the context was out of scope. Users saw only
"Error: evaluation failed" with zero diagnostics.

**Decision**: Switch back to threadlocal error state (same pattern as Beta).

1. `error.zig`: Replaced `ErrorContext` struct with threadlocal `last_error`,
   `msg_buf`, `source_text_cache` and module-level functions `setError()`,
   `setErrorFmt()`, `getLastError()`, `setSourceText()`, `getSourceText()`.
2. Removed `*ErrorContext` parameter from Reader, Analyzer, bootstrap functions.
3. Removed `error_ctx` field from Env.
4. Added `reportError()` to main.zig — babashka-style error display with
   Type, Message, Phase, Location, and source context (±2 lines with pointer).

**Rationale**: Threadlocal eliminates the scope boundary problem. Error info survives
across function call boundaries without needing explicit parameter threading. Single-
threaded execution means no thread safety concerns. Zig test runner uses per-thread
state so test isolation is preserved.

**Impact**: Analysis and parse errors now display full diagnostics. Runtime errors
still show fallback (BE2/BE3 will add error info to builtins and VM/TreeWalk).

## D64: Macro Expansion Source Preservation (BE5)

**Context**: Macro expansion pipeline loses source info: Form→Value→macro→Value→Form.
`valueToForm()` creates Forms with line=0 because Values carry no source info.
Errors in macro-expanded code (e.g. defn, when, cond) reported no location.

**Decision**: Add `source_line: u32` and `source_column: u16` fields to
PersistentList and PersistentVector (default 0). formToValue copies Form source
fields to collection source fields; valueToForm restores them. expandMacro stamps
original call source on top-level expanded form when it has line=0.

**Rationale**: Same approach as JVM Clojure (metadata with :line/:column on
collections), but lighter — dedicated fields instead of full metadata map.
Minimal overhead: +6 bytes per list/vector instance, defaults to 0 so all
existing code is unaffected.

**Impact**: TreeWalk now points to exact sub-expression inside macro bodies
(e.g. `(+ x y)` inside `defn`). VM gets line-level precision through macros.

---

## D65: Lazy Sequence Infrastructure

**Context**: Core seq functions (map, filter, take, take-while, concat, range, mapcat)
were eager, preventing `(range 100000000)` and `for` comprehensions with large ranges.

**Decision**: Replace eager loop/recur implementations of core seq functions with
lazy-seq/cons based implementations in core.clj. Add `realizeValue()` utility in
collections.zig for transparent lazy→eager conversion at system boundaries
(equality, printing, string conversion, metadata, macro expansion).

**Architecture**:
- core.clj: map, filter, take, take-while, concat, range, mapcat all use lazy-seq/cons
- collections.zig: `realizeValue(alloc, val)` converts lazy_seq/cons to PersistentList
- Transparent realization at boundaries: eqFn/neqFn, VM .eq/.neq opcodes,
  print/pr/println/prn, str/pr-str, valueToForm, withMetaFn
- `for` analyzer: uses mapcat instead of (apply concat (map ...))
- `for` analyzer: :when/:while ordering — :when guards :while via
  `(fn [a] (if when-cond while-cond true))` take-while predicate

**Rationale**: Clojure semantics require lazy sequences. Eager implementations
break `(take 5 (range 100000000))` and `for` comprehensions. The realize-at-boundaries
pattern keeps lazy seq transparent: no changes needed in most code.

**Impact**: Infinite sequences work. `for` comprehensions with large ranges work.
Syntax-quote expansion (which uses concat) now returns lazy seqs, handled
transparently by valueToForm and withMetaFn.

## D66: Delay Value Type

**Context**: Delay was implemented as a map with `:__delay` sentinel key. This was
fragile (type predicates relied on map key checks) and didn't support exception caching
with identity preservation (identical? on re-thrown exceptions).

**Decision**: Add dedicated `Delay` struct and `delay: *Delay` variant to Value union.
Replace map-based delay in core.clj with `__delay-create` builtin.

**Architecture**:
- value.zig: `Delay { fn_val, cached, error_cached, realized }` struct + union variant
- atom.zig: `forceDelay()` handles evaluation, caching, and exception caching
- atom.zig: `delayCreateFn()` as `__delay-create` builtin
- predicates.zig: `__delay?`, `__delay-realized?`, `__lazy-seq-realized?` builtins
- core.clj: `delay` macro uses `__delay-create`, `force`/`delay?`/`realized?` use builtins
- tree_walk.zig: `callBuiltinFn` now propagates UserException to self.exception

**Rationale**: Proper Value variant enables correct type predicates, efficient dispatch,
and exception caching with identity preservation (JVM Delay semantics).

## D67: Multi-Arity defmacro Support

**Decision**: Extend `analyzeDefmacro` in analyzer.zig to support multi-arity forms,
matching the existing `analyzeFn` pattern. Also handle `^{metadata}` reader syntax
on defmacro name (reader expands to `(with-meta name metadata)`).

**Architecture**:
- analyzer.zig `analyzeDefmacro`: supports both `[params] body` and `([params] body) ...` forms
- analyzer.zig `analyzeDefmacro`: extracts name from `(with-meta sym map)` list when present
- Removed unused `analyzeFnBody` helper (single-arity only, superseded)

**Rationale**: Upstream Clojure macros like `assert`, `if-let`, `if-some` use multi-arity
forms. Without this, core.clj cannot define these macros in their upstream shape.

## D68: Namespace-Isolated Function Execution

**Decision**: Capture the defining namespace on `Fn` objects and restore it during
function calls, so that unqualified symbol resolution happens in the defining namespace
rather than the caller's runtime namespace.

**Architecture**:
- `value.zig`: `Fn.defining_ns: ?[]const u8` — captures namespace name at definition time
- `compiler.zig`: `current_ns_name` field propagated from bootstrap/eval_engine; set on Fn
  objects in `emitFn`
- `vm.zig`: `CallFrame.saved_ns` saves caller's namespace; `performCall` switches
  `env.current_ns` to Fn's defining namespace; `ret` restores saved namespace
- `tree_walk.zig`: `makeClosure` captures `env.current_ns.name`; `callClosure` saves/restores
  `env.current_ns` around closure execution
- `namespace.zig`: `resolveQualified` for own namespace uses `resolve()` (mappings + refers)
  instead of just `mappings.get()`

**Rationale**: JVM Clojure captures Var references at compile time, so function bodies
always see the Var bindings from their defining namespace. Our runtime-resolved approach
caused cross-namespace shadowing — e.g. `(deftest walk ...)` created a `walk` var that
shadowed `clojure.walk/walk` when called from within clojure.walk functions. This
namespace isolation is fundamental to Clojure's module system semantics.

## D69: Mark-Sweep GC Allocator (Phase 23)

**Decision**: Implement `MarkSweepGc` in `src/common/gc.zig` using HashMap-based
allocation tracking rather than intrusive linked lists.

**Architecture**:
- `gc.zig`: `MarkSweepGc` wraps a backing `std.mem.Allocator`
- Tracks all allocations in `AutoArrayHashMapUnmanaged(usize, AllocInfo)` keyed by pointer address
- Provides `std.mem.Allocator` interface (alloc/resize/remap/free vtable) for runtime use
- Provides `GcStrategy` interface (alloc/collect/shouldCollect/stats vtable)
- `markPtr(ptr)`: marks a tracked allocation as live
- `sweep()`: frees all unmarked allocations, resets marks for next cycle
- HashMap uses backing allocator (not GC allocator) to avoid circular dependency
- Allocation threshold controls `shouldCollect()` trigger

**Rationale**: HashMap-based tracking is simpler and safer than intrusive linked lists
(no pointer arithmetic, no alignment padding). Performance can be optimized in Phase 24
if needed. The `std.mem.Allocator` wrapper enables drop-in replacement for the existing
`ArenaGc.allocator()` throughout the runtime.

## D70: Three-Allocator Architecture (Phase 23.5)

**Decision**: Use three allocator tiers to separate GC-tracked Values from
infrastructure and AST Nodes.

**Architecture**:
- **GPA (infra_alloc)**: Env, Namespace, Var, HashMap backings — stable infrastructure
- **node_arena (GPA-backed ArenaAllocator in Env)**: Reader Forms, Analyzer Nodes —
  AST data referenced by TreeWalk closures, not GC-tracked, persists for program lifetime
- **GC allocator (gc_alloc)**: Values (Fn, collections, strings) — mark-sweep collected
- VM: GC safe points work correctly — bytecode/constants marked in root set
- TreeWalk: GC safe points in run() deferred to Phase 24 (need Node tree tracing)
- REPL: GC safe point between form evaluations (root set = env namespaces)
- Threshold reset after bootstrap prevents immediate sweep

**Rationale**: GC sweep frees ALL unmarked allocations. AST Nodes are not Values and
cannot be traced by the GC. Moving reader/analyzer output to a GPA-backed arena
ensures Nodes survive GC cycles. The arena is owned by Env and freed at program exit.
For REPL, per-form reader/analyzer output accumulates in the arena (acceptable tradeoff).

**Future**: Phase 24 may add `traceNode` to GC for proper Node collection, or use
per-form arenas for VM (which doesn't need Nodes after compilation).

## D71: Heap-Allocated VM Struct

**Decision**: Always heap-allocate VM structs (via `allocator.create(VM)`) instead
of placing them on the C call stack.

**Rationale**: The VM struct is ~1.5MB due to its fixed-size operand stack
(`[32768]Value`, Value=48 bytes). When allocated on the C call stack in
`evalStringVM`, it consumes most of the available 8MB native stack. Nested calls
through builtins → `callFnVal` → `bytecodeCallBridge` add additional stack frames,
causing native stack overflow (SIGILL) for programs with enough total code.
`bytecodeCallBridge` already heap-allocated; now `evalStringVM` and
`EvalEngine.runVM` do the same.

**Impact**: Fixes crash on larger Clojure programs (e.g., multimethods test suite).
No performance impact — VM allocation is once per top-level form evaluation.

## D72: NaN Boxing — Value from 48 bytes to 8 bytes

**Decision**: Replace Value tagged union (48 bytes) with NaN-boxed packed struct(u64)
(8 bytes). Use IEEE 754 quiet NaN space to encode non-float values.

**Encoding** (top 16 bits of u64):
- `< 0xFFF9`: float (raw f64 bits, canonical NaN for actual NaN results)
- `0xFFF9`: integer (48-bit signed, float promotion for overflow)
- `0xFFFA`: heap pointer (bits 47-40 = HeapTag, bits 39-0 = address)
- `0xFFFB`: constant (0=nil, 1=true, 2=false)
- `0xFFFC`: char (u21 codepoint in lower bits)
- `0xFFFD`: builtin function pointer (48-bit fn address)

**HeapTag in pointer bits**: Instead of modifying heap struct layouts, encode the
type tag (HeapTag enum) in bits 47-40 of the pointer payload. 40-bit address space
(1TB) is sufficient for macOS ARM64 (measured: all addresses fit in 33 bits).

**Integer range**: i48 (±140 trillion). Values outside this range promote to float,
matching existing overflow-to-float semantics from 24A.4. Boxed i64 deferred (F99).

**API migration**: Value.tag() method returns Tag enum for switch dispatch.
- `switch (value)` → `switch (value.tag())`
- `.integer => |i|` → `.integer => { const i = value.asInteger(); }`
- `value == .nil` → `value.isNil()` or `value == Value.nil`
- `.{ .integer = 42 }` → `Value.initInteger(42)`

**Impact**: VM stack 1.5MB → 256KB (6x). Collection elements 6x smaller.
Dramatically better cache utilization. No heap struct modifications needed.

**Status: DEFERRED**. Migration requires changing 600+ call sites across 30+ files
(every switch on Value, every Value literal construction, every field access). Attempted
in Phase 24B.1 — value.zig rewrite compiles but call-site migration proved too invasive
for incremental execution. Preserve design for future dedicated migration phase.
Prototype saved at `/tmp/vp1.zig` + `/tmp/vp2.zig`.

---

## D73: Two-Phase Bootstrap — TreeWalk + VM Hot Recompilation

**Date**: 2026-02-07
**Context**: core.clj is loaded via TreeWalk (fast, ~10ms), but ALL core functions
become TreeWalk closures. When VM calls these closures (e.g., transducer step functions
in reduce hot loops), each call dispatches through treewalkCallBridge creating a new
TreeWalk instance — ~200x slower than bytecode execution.

**Decision**: Two-phase bootstrap in loadCore:
1. Phase 1: Evaluate core.clj via TreeWalk (fast startup, all functions defined)
2. Phase 2: Re-evaluate hot transducer functions (map, filter, comp) via VM compiler
   (`evalStringVMBootstrap`), replacing TreeWalk closures with bytecode closures.

**evalStringVMBootstrap**: Compiles and evaluates forms via Compiler+VM but intentionally
does NOT deinit Compiler or VM — FnProtos and allocated Fn objects must persist because
they are stored in Vars via def/defn.

**Trade-offs**:
- transduce: 2134→15ms (142x improvement, beats Babashka)
- Startup overhead: +5ms (10→15ms)
- nested_update regression: 42→72ms (cache/allocator indirect effect from additional
  bytecode objects — investigated, confirmed as bytecode footprint side effect, not a bug)

**Key finding**: The regression affects benchmarks that don't use map/filter/comp because
bytecode Fn objects + FnProtos occupy cache/GPA space, impacting tight allocation loops.

**VM variadic rest args fix** (concurrent bug fix): When rest_count==0, VM now returns
`.nil` instead of empty PersistentList `()`. Matches Clojure spec and TreeWalk behavior.

## D74: Filter Chain Collapsing + Active VM Call Bridge

**Decision**: Add `lazy_filter_chain` Meta variant to flatten nested filter chains,
and route bytecode calls through the active VM in callFnVal.

**Problem**: Sieve of Eratosthenes creates 168 nested filter layers (one per prime ≤ 1000).
Each element access required 168 levels of recursive realize() calls. Additionally,
callFnVal allocated a new ~500KB VM struct for every bytecode function call via
bytecodeCallBridge, even when a running VM was already available.

**Solution** (two parts):

1. **Filter chain collapsing** (value.zig): New `lazy_filter_chain` Meta variant stores
   a flat `[]const Value` of predicates + source. When `filter(pred, filter_chain(...))` is
   called, predicates are appended to a single flat array instead of nesting.
   Realization checks all predicates in a flat loop.

2. **Active VM call bridge** (bootstrap.zig): callFnVal checks `vm_mod.active_vm` before
   allocating a new VM. When a VM is already executing (which it always is during
   lazy-seq realization from within VM execution), uses `vm.callFunction()` to reuse
   the existing VM's stack and frames. Eliminates ~500KB heap allocation per call.

**Result**: sieve 1645→21ms (78x improvement, matches Babashka's 22ms).
Memory: 2997MB → 23.8MB (125x improvement).

## D75: Phase Ordering — Refactoring After wasm_rt

**Date**: 2026-02-07
**Context**: Transition planning from Phase 24 to Phase 25-27

**Decision**: Large-scale refactoring deferred to Phase 27 (after wasm_rt).
Only mini-cleanup in Phase 24.5.

**Rationale**:
1. wasm_rt (Phase 26) reveals true common/native/wasm_rt boundaries
2. Premature refactoring creates false abstractions that wasm_rt would undo
3. Current 39K+ lines of Zig work correctly with full test coverage
4. File splitting before understanding sharing patterns wastes effort

**Phase 24.5 scope** (mini-refactor): dead code, naming, D3 audit, file size docs
**Phase 27 scope** (full refactor): file splitting, D3 resolution, directory restructuring

## D76: Wasm InterOp Value Variants — wasm_module + wasm_fn

**Date**: 2026-02-07
**Context**: Phase 25.1 — First-class Wasm values in ClojureWasm

**Decision**: Add two new Value union variants: `wasm_module` and `wasm_fn`.
- `wasm_module: *WasmModule` — heap-allocated, owns zware Store/Module/Instance
- `wasm_fn: *const WasmFn` — bound export name + signature, callable via callFnVal

**Wasm namespace**: `wasm` (not `clojure.wasm`), registered in registry.zig.
- `(wasm/load "path.wasm")` => WasmModule
- `(wasm/fn mod "name" {:params [:i32 :i32] :results [:i32]})` => WasmFn

**Call dispatch**: WasmFn handled in 3 places:
1. `bootstrap.callFnVal` — unified fallback
2. `vm.performCall` — VM-specific fast path
3. `tree_walk.runCall` + `tree_walk.callValue` — TreeWalk dispatch

**Type conversion**: integer<->i32/i64, float<->f32/f64, boolean/nil->i32(0/1)

**Rationale**: First-class Value variants (vs wrapping in maps) enable:
1. Direct dispatch in switch statements (no map lookup overhead)
2. GC integration via traceValue
3. Type-safe signature checking at wasm/fn creation time
4. Proper pr-str formatting (#<WasmModule>, #<WasmFn name>)

## D77: Host Function Injection — Clojure→Wasm Callbacks

**Date**: 2026-02-07
**Context**: Phase 25.4 — Clojure functions callable from Wasm guest code

**Decision**: Global trampoline + context table for host function injection.
- `(wasm/load "m.wasm" {:imports {"env" {"log" clj-fn}}})` registers Clojure fns as Wasm imports
- Global `host_contexts[256]` table maps context IDs to HostContext structs
- Single `hostTrampoline(vm, ctx_id)` function handles all callbacks
- Trampoline pops args from zware VM stack, calls `bootstrap.callFnVal`, pushes result

**Design**:
1. `HostContext` stores: Clojure fn Value, param/result counts, allocator
2. `allocContext` assigns slots with wrap-around reuse
3. `registerHostFunctions` scans module imports, matches against nested Clojure map
4. `lookupImportFn` does two-level map lookup: `{module {func clj-fn}}`

**Rationale**: Context table (vs closures) because zware's `exposeHostFunction` takes
a function pointer + usize context — Zig closures cannot be passed as fn pointers.
256 slots is sufficient for practical use (host modules rarely export >50 imports).

---

## D78: wasm_rt Code Organization — Separate Entry + Comptime Guards

**Decision**: Use separate `main_wasm.zig` entry point + minimal comptime branches
in shared files. No separate `wasm_rt/` file copies for common/ code.

**Context** (26.R.1 compile probe):
- 10 compile errors across 7 files for wasm32-wasi target
- 5 files need only 1-3 comptime branches each (trivial)
- 2 critical files (bootstrap.zig, eval_engine.zig) import from native/
- User preference: minimize comptime in common/; separate files over heavy branching

**Architecture**:
```
src/
  main.zig          — native entry (full: REPL, nREPL, wasm-interop, VM+TW)
  main_wasm.zig     — wasm_rt entry (eval-only, no nREPL, no wasm/, VM or TW)
  root.zig          — library root (comptime skip nrepl/wasm on wasi)
  common/
    bootstrap.zig   — comptime import guard: TreeWalk/VM → void on wasi
    eval_engine.zig — comptime import guard: TreeWalk/VM → void on wasi
    builtin/
      registry.zig  — comptime skip wasm_builtins on wasi
      system.zig    — comptime getenv → std.process on wasi
```

**Entry Point Strategy** (Option C from 26.R.2):
- `main.zig` unchanged (native-only features: nREPL, --dump-bytecode, --tree-walk)
- `main_wasm.zig` is minimal: init GC/Env → bootstrap core.clj → eval stdin or embedded
- `build.zig` wasm step uses `main_wasm.zig` as root_source_file

**Why not Option A (single main.zig + comptime)**:
- main.zig has nREPL mode, --dump-bytecode, file reading logic irrelevant to wasm
- Branching every feature with `if (is_wasm)` clutters the native code path
- Clean separation = easier to reason about both entry points

**Why not Option B (generic bootstrap)**:
- bootstrap.zig is 3374 lines; converting to generic struct = huge refactor
- D75 already defers this to Phase 27 (after wasm_rt reveals real boundaries)

**Comptime branch count per file**:

| File | Branches | Nature |
|------|----------|--------|
| main.zig | 0 | Not used by wasm_rt |
| main_wasm.zig | N/A | New file |
| root.zig | 3 | Skip nrepl, wasm_types, wasm_builtins |
| bootstrap.zig | 2-3 | Import void for TW/VM on wasi; guard VM-specific fns |
| eval_engine.zig | 2-3 | Import void for TW/VM on wasi; guard compare mode |
| registry.zig | 1 | Skip wasm_builtins import |
| system.zig | 1 | getenv API swap |

Total: ~12 comptime branches across 5 files. Well under the ">=3 per file → separate copy" threshold for any individual file.

**Consequence**: Phase 26 implementation adds main_wasm.zig and ~12 comptime guards.
Phase 27 may restructure further based on actual wasm_rt experience.

**Status**: Archived. Phase 26 implementation deferred (D79).

---

## D79: Strategic Pivot — Native Production Track

**Date**: 2026-02-07
**Context**: Phase 26.R research complete. Wasm ecosystem assessment reveals:

1. **WasmGC**: LLVM cannot emit WasmGC types. No timeline for support.
   All WasmGC languages (Kotlin, Dart, Go) bypass LLVM with custom backends.
2. **Wasmtime GC**: Cycle collection unimplemented. Long-running programs leak.
3. **WASI Threads**: Specification in flux (wasi-threads withdrawn).

**Decision**: Defer wasm_rt implementation. Pivot to native production track.

**Rationale**:
- "Compile Zig runtime to Wasm" produces a working but unexciting result
  (linear memory + self-managed GC = same as CPython/CRuby on Wasm)
- True Wasm advantage (host GC cooperation, compact binaries, sandboxing)
  requires WasmGC, which is inaccessible from Zig/LLVM
- Native track has immediate high-value opportunities:
  - NaN boxing: 6x memory reduction, cache efficiency
  - Single binary builder: unique differentiator vs Babashka
  - cider-nrepl: developer experience parity
  - Skip var recovery: broader Clojure compatibility

**New phase order**:
- Phase 27: NaN Boxing (Value 48B -> 8B)
- Phase 28: Single Binary Builder (`cljw build`)
- Phase 29: Codebase Restructuring (core/eval/cli)
- Phase 30: Production Robustness (errors, nREPL, skip vars)
- Phase 31: Wasm FFI Deep (Phase 25 extension)
- Future: wasm_rt revival when ecosystem matures

---

## D80: nREPL Memory Model — GPA-only, no ArenaAllocator

**Context**: Phase 30.2d discovered a Var memory corruption bug in nREPL.
When `Env.init(eval_arena.allocator())` was used, Namespace.intern() allocated
Vars on the same ArenaAllocator used for eval. During `(defn ...)`, fn* eval
triggered alloc/free cycles inside the arena. ArenaAllocator.free() rolls back
end_index when the freed buffer is the most recent allocation, causing
subsequent allocs to reuse memory occupied by the Var struct. Result: Var.sym.name
corrupted with 0xAA (Zig undefined sentinel).

**Root cause**: ArenaAllocator.free() in Zig 0.15.2 performs a "last allocation
rollback" optimization (arena_allocator.zig:263-264). When persistent data (Vars)
and transient data (eval intermediates) share the same arena, free/alloc cycles
for transient data can overwrite persistent allocations.

**Decision**: nREPL uses GPA directly for all allocations — both Env (persistent)
and evalString (transient). No ArenaAllocator. This matches main.zig's REPL pattern.

- Persistent data (Namespace, Var, FnVal bound to Vars): GPA, survives correctly
- Transient data (intermediate Values): GPA, accumulates (inherent without GC)
- Memory growth: proportional to evaluated code, bounded for typical REPL sessions
- GC integration (F113) will resolve transient accumulation in the future

**Alternatives rejected**:
- Per-eval arena with reset: FnVals bound to Vars would dangle after reset
- Per-eval arena without reset: equivalent to one large arena, no benefit
- Deep-copy persistent values to GPA: complex (closures have captured locals, etc.)

**Positioning**: ClojureWasm = "Clojure expression power + Go distribution simplicity"
- Ultra-fast (19/20 Babashka benchmark wins)
- Tiny single binary (< 2MB with user code)
- Wasm FFI (unique: no other Clojure runtime has this)
- Zero-config (no deps.edn required, auto-detect src/)
