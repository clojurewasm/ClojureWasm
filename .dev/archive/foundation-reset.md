# Foundation Reset Plan: Upstream Fidelity

## Goal

Eliminate test workarounds and build a foundation faithful to upstream
Clojure/SCI implementations and tests. Var expansion resumes after this
foundation is solid.

## Phases

### Phase A: Audit & Document (vars.yaml full audit)

Audit all 405 "done" vars against upstream, annotating every var with
appropriate notes. Currently ~269 vars have no note.

**Batches** (1 batch = 1 commit):

| Batch | Target                  | Est. | Method                           |
|-------|-------------------------|------|----------------------------------|
| A1    | Special Forms           | 16   | analyzer.zig handlers            |
| A2    | Arithmetic & Comparison | 20   | arithmetic.zig + numeric.zig     |
| A3    | Collection Operations   | 80   | sequences.zig + collections.zig  |
| A4    | String Operations       | 15   | strings.zig + clj_string.zig     |
| A5    | Predicates              | 30   | predicates.zig                   |
| A6    | Macros (core.clj)       | 17   | core.clj vs upstream core.clj    |
| A7    | HOF & Lazy Sequences    | 40   | core.clj + sequences.zig         |
| A8    | State & Concurrency     | 10   | atom.zig + volatile etc          |
| A9    | Remaining               | 50   | various builtins                 |

**Per-var procedure**:
1. Check upstream Clojure source
2. Check ClojureWasm implementation (builtin/*.zig or core.clj)
3. Classify: matches upstream / builtin (upstream is pure clj) /
   UPSTREAM-DIFF / partial → update vars.yaml
4. If partial → change status, add F## entry

**Completion**: All done vars annotated, new issues in checklist.md

### Phase BE: Error System Overhaul

Current error output is `"Error: evaluation failed"` with zero diagnostics.
This blocks effective debugging of B0-B4 and Phase C test porting.
ClojureWasmBeta has a comprehensive error reporting system (babashka-style)
that we port here.

**Target output** (after this phase):
```
----- Error -----------------------------------------------
Type:     arity_error
Message:  Wrong number of args (3) passed to my-fn
Phase:    eval
Location: test.clj:5:1

   3 | (defn my-fn [x] x)
   4 |
   5 | (my-fn 1 2 3)
       ^--- error here
```

**Architecture change**: ErrorContext switches from instance-based (D3a)
to threadlocal — same pattern as Beta. This eliminates error info loss
when errors propagate across scope boundaries.

| Task | Description                           | Files             | Sites | Est. commits |
|------|---------------------------------------|-------------------|-------|-------------|
| BE1  | Threadlocal infrastructure + display  | error.zig, main.zig, bootstrap.zig, analyzer.zig, reader.zig, env.zig, nrepl.zig, eval.zig | ~30 | 2-3 |
| BE2  | Builtin error messages                | 17 builtin/*.zig  | ~314  | 4-5          |
| BE3  | Runtime source location propagation   | vm.zig, tree_walk.zig | ~27 | 2-3        |

**BE1: Threadlocal infrastructure + display** (2-3 commits)
- `error.zig`: Add threadlocal `last_error`, `source_text`, convenience
  helpers (`evalError`, `evalErrorFmt`, `setTypeError`, `setArityError`)
- `main.zig`: Add `reportError()` (babashka-style format), `showSourceContext()`
  (±2 lines with column pointer), replace all generic catch messages
- `bootstrap.zig`: Remove local `ErrorContext` vars, use threadlocal
- `analyzer.zig`, `reader.zig`, `env.zig`, `nrepl.zig`, `eval.zig`:
  Update to use threadlocal instead of `*ErrorContext` parameter

**BE2: Builtin error messages** (4-5 commits, batch by group)
- Each `return error.TypeError` → `return err.setTypeError("Expected number, got ...")`
- Batch plan:
  - BE2a: Core (arithmetic.zig, numeric.zig, predicates.zig) — ~85 sites
  - BE2b: Collections + Sequences (collections.zig, sequences.zig) — ~86 sites
  - BE2c: Strings (strings.zig, clj_string.zig) — ~63 sites
  - BE2d: Other (atom, metadata, multimethods, ns_ops, misc, io,
    file_io, regex, system, eval) — ~80 sites

**BE3: Runtime source location propagation** (2-3 commits)
- TreeWalk: When a Node evaluation fails, annotate error with Node's
  SourceInfo (line/column) before propagating
- VM: Map instruction pointer back to source location via debug info
  stored at compile time (or capture current Node source in call frames)

**Completion**: All error paths produce kind + message + location.
`reportError()` displays diagnostics with source context.

**Estimated total: 8-11 commits**

### Phase B: Fix Known Issues

Fix checklist.md F## items in test-porting-impact order.

**B0**: test.clj enhancement (is pattern dispatch, thrown?, thrown-with-msg?)
**B1**: Core Semantics (F29/F33, F34, F30, F31, F32)
**B2**: Macro Enhancement (F27/F28, F93, F92, F25/F26)
**B3**: Seq/String Operations (F41, F45, F48, F49)
**B4**: defn/ns Enhancement (F90, F85)

### Phase C: Faithful Test Porting

Port upstream tests with minimal changes, all marked with CLJW markers.
See `.claude/rules/test-porting.md` for rules.

**Order**: C1 (small/low-Java) → C2 (medium) → C3 (large) → C4 (new) → C5 (SCI)

### Phase D: Parallel Expansion

Prerequisite: Phase A-C complete.
New var implementation preceded by upstream test porting.
CLJW-SKIP → implement → unblock → commit.

## Reference Files

| File                                    | Purpose                        |
|-----------------------------------------|--------------------------------|
| `.dev/memo.md`                          | Session handover               |
| `.dev/status/audit-progress.yaml`       | Audit progress tracker         |
| `.claude/rules/test-porting.md`         | Test porting rules (auto-load) |
| `.claude/references/interop-patterns.md`| Java→CW pattern mapping        |
| `.dev/checklist.md`                     | Deferred items (F##)           |
