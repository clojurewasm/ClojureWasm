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
| `.dev/plan/memo.md`                     | Session handover               |
| `.dev/status/audit-progress.yaml`       | Audit progress tracker         |
| `.claude/rules/test-porting.md`         | Test porting rules (auto-load) |
| `.claude/references/interop-patterns.md`| Java→CW pattern mapping        |
| `.dev/checklist.md`                     | Deferred items (F##)           |
