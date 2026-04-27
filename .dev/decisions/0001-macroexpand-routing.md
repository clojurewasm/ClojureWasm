  # 0001 — Route macroexpansion through a Layer-1 MacroTable, not the Runtime VTable

- **Status**: Accepted
- **Date**: 2026-04-27
- **Author**: Shota Kudo (with Claude Opus 4.7)
- **Tags**: macros, analyzer, layering, dispatch

## Context

Phase 3.7 (`§9.5 / 3.7` in ROADMAP) introduces Zig-level expansions for the
bootstrap macros (`let → let*`, `when`, `cond`, `if-let`, `when-let`,
`and`, `or`, `->`, `->>`). The question: **where does macro expansion
live, and how does the analyzer reach the impl?**

Constraints in scope:

- **`zone_deps.md`** — `eval/` (Layer 1) cannot import `lang/` (Layer 2).
  Any analyzer-to-`lang/macro_transforms` call must go through some
  inversion of control.
- **`zone_deps.md` Guard 3** — `pub var` vtables are forbidden.
- **ROADMAP P3** — "Core stays stable; new features go in new files".
  Macroexpansion belongs in a dedicated module, not crammed into
  analyzer or backend.
- **ROADMAP P12** — TreeWalk and VM must agree on every test from
  Phase 8 onward. Macroexpansion must be **backend-agnostic**.
- **ROADMAP P6** — Error quality is non-negotiable. Macro errors must
  attribute to the call-site `SourceLocation`.
- **ROADMAP §13** — "vtable on `Runtime`" is the project's chosen IoC
  pattern, but only when the inverted dependency is genuinely a
  Layer-0-level concern.

Carrying state into the decision:

- The current `runtime/dispatch.zig::VTable` already has an
  `expandMacro` slot, installed as `expandMacroStub` in
  `eval/backend/tree_walk.zig::installVTable`. This pre-existing slot
  is **vestigial** from an early sketch where backend and macro
  expansion were intermixed.
- The Step-0 survey for 3.7
  (`private/notes/phase3-3.7-survey.md`, gitignored) found that
  ClojureWasm v1 implements the same nine macros (and 48 more) as
  Form→Form transforms, dispatched inline from `analyzeList()` via a
  `StaticStringMap` lookup, with **no backend coupling**. Clojure JVM
  invokes `Compiler.macroexpand1` from inside `analyzeSeq`, again
  without backend involvement. Babashka/SCI runs all macros through
  the SCI evaluator (no host fast path), but is interpreter-only and
  does not separate analysis from execution.

## Decision

Macroexpansion is **invoked from the analyzer** via an explicitly
threaded `MacroTable`, declared in a new Layer-1 module
`eval/macro_dispatch.zig`. The Zig-level transforms live in
`lang/macro_transforms.zig` (Layer 2) and register themselves into the
table at startup. The table is constructed in `main.zig`, populated
once, and passed to `analyze` as a parameter alongside `*Runtime` and
`*Env`.

```
Layer 0 (runtime):  no macro concerns
Layer 1 (eval):     macro_dispatch.Table (type)  +  analyzer consults it
Layer 2 (lang):     macro_transforms.zig populates the Table
Layer 3 (app):      main.zig builds the Table at startup
```

Concrete shape:

```zig
// eval/macro_dispatch.zig
pub const ZigExpandFn = *const fn (
    rt: *Runtime,
    env: *Env,
    args: []const *const Form,   // call-site argument forms (not lifted)
    loc: SourceLocation,         // call-site loc for error attribution
) anyerror!*const Form;          // expanded form, ready for re-analysis

pub const Table = struct {
    entries: std.StringHashMapUnmanaged(ZigExpandFn) = .empty,
    // … register / lookup / deinit
};

pub fn expandIfMacro(
    rt: *Runtime,
    env: *Env,
    table: *const Table,
    head_var: *const Var,         // already resolved by analyzer
    args: []const *const Form,
    loc: SourceLocation,
) anyerror!?*const Form;          // null = not a macro Var; non-null = expanded
```

Concurrently, **`runtime/dispatch.zig::VTable.expandMacro` is removed**,
along with `ExpandMacroFn`, `mockExpandMacro`, and
`tree_walk.zig::expandMacroStub`. The `VTable` shrinks to
`{ callFn, valueTypeKey }`.

The user-defined `defmacro` path (Phase 3.12) reuses the same
`expandIfMacro` entry point; when the head Var has `flags.macro_` set
but is not in the Zig `Table`, `expandIfMacro` falls back to invoking
`vtable.callFn` on the macro Var's fn-Value with `args` lifted to
Values, then converts the returned Value back to a Form. The
Form↔Value boundary therefore exists in **exactly one place** — the
user-fn invocation site — and never crosses zone boundaries.

## Alternatives considered

### Alternative A — Inline `lang/macro_transforms` import in analyzer

- **Sketch**: `eval/analyzer.zig` directly imports
  `lang/macro_transforms.zig` and calls into a `StaticStringMap` at
  comptime, the way v1 does.
- **Why rejected**: Violates `zone_deps` (Layer 1 → Layer 2). v1
  predates the explicit zone contract, and v1's code organization is
  one of the things this v2 redesign is fixing. ROADMAP §4.1 makes the
  upward-import prohibition load-bearing.

### Alternative B — Keep `expandMacro` on `Runtime.vtable`, impl in `lang/`

- **Sketch**: Retain `runtime.vtable.expandMacro`, but install the impl
  from `lang/macro_transforms.zig` instead of TreeWalk. The signature
  uses `Value` (not `Form`) since Layer 0 cannot reference Layer 1
  types.
- **Why rejected**: (1) Macroexpansion is not a Layer-0 concern;
  carrying it on `Runtime.vtable` misnames the responsibility.
  (2) Forces a Form→Value→Form round-trip even for Zig-level transforms
  that have no semantic reason to traverse the Value domain.
  (3) Makes `Runtime` look like it knows about macros, polluting the
  Layer-0 interface for tests and embedders.

### Alternative C — Put `expandMacro` on TreeWalk's `installVTable`

- **Sketch**: Treat macro expansion as a backend concern, the way the
  current `expandMacroStub` does.
- **Why rejected**: Violates ROADMAP P12 (dual-backend equivalence).
  Phase 4+ adds the VM backend; macroexpansion would have to be
  duplicated or factored back out — exactly the rework this ADR
  forecloses.

### Alternative D — Separate macroexpand pass before analyze

- **Sketch**: `Reader → MacroExpand (Form→Form) → Analyze` as three
  distinct passes, mirroring naive Lisp pedagogy.
- **Why rejected**: Macros depend on the lexical scope established
  during analysis (e.g., a `let` binding can shadow a global macro
  Var). Running macroexpand as a standalone pass would either
  re-implement the analyzer's Var-resolution logic or be limited to
  global macros. Inlining the expansion check into `analyzeList`
  matches Clojure JVM and ClojureWasm v1.

### Alternative E — Module-level `pub var` registry in `eval/macro_dispatch`

- **Sketch**: `pub var registry: ?Table = null;` in
  `eval/macro_dispatch.zig`, populated at startup, consulted by
  analyzer.
- **Why rejected**: `zone_deps.md` Guard 3 forbids `pub var` for
  vtables. The rule exists because mutable module-level state breaks
  multi-tenant test isolation and conflates one Runtime with another.

## Consequences

### Positive

- **Zone-clean**. analyzer (Layer 1) imports only `eval/macro_dispatch`
  (Layer 1). `lang/macro_transforms` (Layer 2) imports `eval/...` and
  `runtime/...` per the contract. No upward imports.
- **Backend-agnostic**. TreeWalk and VM see only the post-expansion
  Node tree. The Phase 8 dual-backend `--compare` gate is automatically
  satisfied for the macro path.
- **Single dispatch entry point** for both Zig transforms and Phase
  3.12 user `defmacro`. Adding user macros at 3.12 requires no change
  to analyzer wiring — only a fallback branch inside `expandIfMacro`.
- **Form↔Value boundary is localised** to the user-fn invocation site.
  Zig transforms operate on Forms throughout; no allocation overhead
  for the static cases.
- **`(macroexpand-1 form)` primitive** (Phase 5+) is trivial: the
  builtin resolves the head Var and calls `expandIfMacro` directly.
- **`Runtime.vtable` simplifies** to `{ callFn, valueTypeKey }`,
  shrinking the Layer-0 surface and making the contract clearer.

### Negative

- **Threading change**: `analyze` gains a `macro_table` parameter.
  Every call site (5 internal recursive calls in analyzer, plus
  `main.zig` and the test fixtures in `analyzer.zig` and
  `tree_walk.zig`) needs updating in one commit. This is a deliberate
  surgical change, not a workaround — see ROADMAP P3.
- **Two error-attribution locations** for macros: the Zig transform's
  own arity / shape errors (attributed to call-site `loc`) and the
  user-fn macro path's `vtable.callFn` errors. Both will route through
  `setErrorFmt` so the renderer shape is uniform.

### Neutral / follow-ups

- The Form→Value→Form bridge for user `defmacro` is deferred to Phase
  3.12. The `expandIfMacro` skeleton in 3.7 returns `error.NotImplemented`
  for the user-macro branch with a `not_implemented` Kind so the
  failure mode is clean.
- A `(macroexpand-1 form)` primitive is **not** in 3.7 scope; it
  becomes natural after Phase 3.10 (ex-info) lands and is logged as a
  Phase 5+ candidate.
- `lang/macro_transforms.zig` will grow as more macros land in Phases
  3–5; ROADMAP A6 (≤ 1000 lines per file) means we may split it
  thematically (`bool.zig` for and/or, `threading.zig` for `->`/`->>`,
  etc.) when we cross ~600 lines.

## References

- ROADMAP §2 (P3, P6, P12), §4.1 (Zone), §9.5 (Phase 3 task list),
  §13 (Reject patterns)
- `.claude/rules/zone_deps.md` — zone contract
- `.claude/rules/textbook-survey.md` — Step 0 procedure
- `private/notes/phase3-3.7-survey.md` — Step 0 survey for this ADR
  (gitignored)
- v1 reference: `~/Documents/MyProducts/ClojureWasm/src/lang/macro_transforms.zig`
- Clojure JVM: `clojure/src/jvm/clojure/lang/Compiler.java::macroexpand1`
  (line ~7566) and `analyzeSeq` (line ~7673)
