# ClojureWasm

Full-scratch Clojure implementation in Zig 0.15.2. Behavioral compatibility target.
Reference: ClojureWasmBeta (via add-dir). Design: `.dev/future.md`. Memo: `.dev/memo.md`.

## Language Policy

- **All code in English**: identifiers, comments, docstrings, commit messages, markdown

## Zone Architecture (D109)

Strict 4-zone layered architecture. **Lower layers NEVER import from higher layers.**

```
Layer 0: src/runtime/   — foundational types (Value, collections, Env, GC)
                          NO imports from engine/, lang/, or app/
Layer 1: src/engine/    — processing pipeline (Reader, Analyzer, Compiler, VM, TreeWalk)
                          imports runtime/ only
Layer 2: src/lang/      — Clojure language (builtins, interop, lib namespaces)
                          imports runtime/ + engine/
Layer 3: src/app/       — application (main, CLI, REPL, deps, Wasm)
                          imports anything
```

Plan: `.dev/refactoring-plan.md`. Rules: `.claude/rules/zone-deps.md` (auto-loads on src/ edits).

## TDD (t-wada style)

1. **Red**: Write exactly one failing test first
2. **Green**: Write minimum code to pass
3. **Refactor**: Improve code while keeping tests green

- Never write production code before a test (1 test → 1 impl → verify cycle)
- Progress: "Fake It" → "Triangulate" → "Obvious Implementation"
- Zig file layout: imports → pub types/fns → private helpers → tests at bottom

## Implementation Quality

- **Root-cause fixes only.** Never patch symptoms. Trace the real cause, fix it cleanly.
- **Understand before changing.** Read the full call chain before modifying. Know why the
  current code exists and what invariants it maintains.
- **Minimal, correct diffs.** Change only what's needed. Don't scatter unrelated changes.
- **Prototype → discard → implement.** For non-trivial changes, spike first to understand
  the problem space, then revert and implement cleanly with the knowledge gained.

## Structural Integrity Rules

From NextClojureWasm retrospective. Enforced from Phase 97 onward.

1. **No semantic aliasing.** Never register function X under name Y when they have
   different semantics (e.g., `sorted-set` → `hash-set`). If the real implementation
   doesn't exist, keep the var as `todo` or `skip`.
2. **No evaluator special cases for library features.** Evaluator (tree_walk.zig, vm.zig)
   handles ONLY special forms. Library features (thrown?, are, run-tests) must be
   macros or builtin functions — never `if (sym == "thrown?")` in the evaluator.
3. **Zone dependency direction is absolute.** See Zone Architecture above.
   Verified by `scripts/zone_check.sh`. Use vtable pattern when lower layer needs
   to call higher layer (see `runtime/dispatch.zig`).

## Critical Rules

- **One task = one commit**. Never batch multiple tasks.
- **Structure changes and logic changes in separate commits.** During refactoring,
  each commit is EITHER a pure structural move OR a logic change — never both.
- **Architectural decisions only** → `.dev/decisions.md` (D## entry).
  Bug fixes and one-time migrations do NOT need D## entries.
- **Update `.dev/checklist.md`** when deferred items are resolved or added.

## Autonomous Workflow

**Default mode: Continuous autonomous execution.**
After session resume, continue automatically from where you left off.

### Loop: Orient → Plan → Execute → Commit → Repeat

**1. Orient** (every iteration)

```bash
git log --oneline -3 && git status --short
```

Read: `.dev/memo.md` (current state, next task pointer)

If memo.md has no active task:
1. Check `## Next Phase Queue` in memo.md — if populated, promote it
2. Otherwise: read `.dev/roadmap.md` **Phase Tracker** → find first PENDING → read that phase section only

If implementing functions, check coverage:
```bash
yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' .dev/status/vars.yaml
```

**2. Plan**

1. Move current `## Current Task` content → `## Previous Task` (overwrite previous)
2. Write new task design in `## Current Task`
3. Check `roadmap.md` Phase Notes for context on the sub-task
4. For Phase 97 tasks: read `.dev/refactoring-plan.md` for the specific sub-task details

**3. Execute**

- TDD cycle: Red → Green → Refactor
- Run tests during development: `zig build test`
- `compiler.zig` modified → `.claude/rules/compiler-check.md` auto-loads
- `src/**/*.zig` modified → `.claude/rules/zone-deps.md` auto-loads
- **Upstream test porting** (Phase 42+): Follow `.dev/test-porting-plan.md`
  - Port relevant upstream tests for each sub-task

**4. Complete** (per task)

1. Run **Commit Gate Checklist** (below) — includes memo.md update
2. Single git commit (all changes including memo.md)
3. **Immediately loop back to Orient** — do NOT stop, do NOT summarize,
   do NOT ask for confirmation. The next task starts now.

### No-Workaround Rule

1. **Fix root causes, never work around.** If a feature is missing and needed,
   implement it first (as a separate commit), then build on top.
2. **Upstream fidelity over expedience.** Never simplify API shape to avoid gaps.
3. **Checklist new blockers.** Add F## entry for missing features discovered mid-task.

### Test Porting Guardrails

See `.claude/rules/test-porting.md` (auto-loads on test file edits) for full rules.
Key points: implement don't skip, no assertion reduction, both backends, CLJW markers.

### When to Stop

See `.dev/memo.md` for task queue and current state.
See `.dev/roadmap.md` for phase order and future plans.
Do NOT stop between tasks within a phase.

Stop **only** when:

- User explicitly requests stop
- Ambiguous requirements with multiple valid directions (rare)
- **Current phase's Task Queue is empty AND next phase requires user input**

Do NOT stop for:

- Task Queue becoming empty (plan next task and continue)
- Session context getting large (compress and continue)
- "Good stopping points" — there are none until the current phase is done

When in doubt, **continue** — pick the most reasonable option and proceed.

### Commit Gate Checklist

Run before every commit:

1. **All tests** (MANDATORY — every commit, no exceptions):
   - `bash test/run_all.sh` — unified runner (all suites below in one command)
   - Or individually: `zig build test`, `zig build -Doptimize=ReleaseSafe`,
     `./zig-out/bin/cljw test`, `bash test/e2e/run_e2e.sh`, `bash test/e2e/deps/run_deps_e2e.sh`
   - `cljw test`: 83 namespaces. Pre-existing failures in reducers/spec/macros
     tracked in `.dev/known-issues.md`. No crashes allowed.
   - **Hard block**: Do NOT commit if any test fails (pre-existing WARN is OK).
2. **decisions.md**: D## entry only for architectural decisions (new Value variant, new subsystem, etc.)
3. **checklist.md**: Remove resolved F##, add new F##
4. **vars.yaml**: Mark implemented vars `done` (when implementing vars)
5. **memo.md**: Advance to next task
   - Update `## Current Task` with next task details
   - Remove completed task from Task Queue
   - Update Handover Notes if status changed (done/architecture/new info)
6. **test-porting.md**: When changing test/upstream/ files:
   - All changes have CLJW markers
   - No assertion deletions — implement missing features instead
   - File header statistics updated
   - Both backends verified
7. **Wasm bridge** (D92): When modifying `src/wasm/types.zig` (zwasm bridge):
   - Wasm engine changes go in zwasm repo (`../zwasm/`), not CW
   - `bash bench/wasm_bench.sh --quick` — verify wasm benchmarks still work
8. **Non-functional regression** (when changing execution code: src/ core files):
   - **Binary size**: `stat -f%z zig-out/bin/cljw` — ≤ 4.8MB
   - **Startup**: `hyperfine -N --warmup 3 --runs 5 './zig-out/bin/cljw -e nil'` — ≤ 6ms
   - **RSS**: `/usr/bin/time -l ./zig-out/bin/cljw -e nil 2>&1 | grep 'maximum resident'` — ≤ 10MB
   - **Benchmarks**: `bash bench/run_bench.sh --quick` — no CW benchmark > 1.2x baseline
   - **Hard block**: Do NOT commit if any threshold exceeded.
     Benchmark regression → stop, profile, fix in place or insert optimization phase first.
   - Baselines & policy: `.dev/baselines.md`.
9. **Zone check** (when modifying src/**/*.zig):
   - `bash scripts/zone_check.sh --gate` — **hard block** if violations increase
   - Baseline: 126 (stored in `scripts/zone_check.sh`). Update baseline when violations decrease.
   - New upward imports are forbidden. Use vtable pattern (`runtime/dispatch.zig`) instead.

### Phase Completion

When Task Queue empty:

1. Check memo.md `## Next Phase Queue` — if populated, promote to Task Queue
2. If Next Phase Queue empty: read `roadmap.md` **Phase Tracker table only** (top of file)
   - Find first PENDING phase
   - Read **only that phase's section** (not the whole file — save context)
   - Copy sub-tasks to memo.md Task Queue
   - Update Phase Tracker: mark current phase DONE, next phase IN-PROGRESS
   - Commit: `Plan Phase X: [name]`
3. Continue to first task

## Build & Test

```bash
zig build              # Build (Debug)
zig build test         # Run all tests
zig build test -- "X"  # Specific test only
./zig-out/bin/cljw -e '(+ 1 2)'              # VM (default)
./zig-out/bin/cljw --tree-walk -e '(+ 1 2)'  # TreeWalk
./zig-out/bin/cljw path/to/file.clj           # File execution
```

## Benchmarks

**Always use ReleaseSafe for benchmarks.** All scripts auto-build ReleaseSafe.
All measurement uses hyperfine (warmup + multiple runs).

```bash
bash bench/run_bench.sh              # All benchmarks (3 runs + 1 warmup)
bash bench/run_bench.sh --quick      # Fast check (1 run, no warmup)
bash bench/record.sh --id="X" --reason="description"  # Record to history
bash bench/compare_langs.sh --bench=fib_recursive --lang=cw,c,bb  # Cross-language
bash bench/wasm_bench.sh --quick     # CW interpreter vs wasmtime JIT
```

History: `bench/history.yaml` — CW native benchmark progression.
Wasm history: `bench/wasm_history.yaml` — CW vs wasmtime wasm benchmark progression.
**Record after every optimization task.** Use task ID as entry id (e.g. "36.7").
**Regression check on execution code changes.** See Commit Gate #8 and `.dev/baselines.md`.

## Notice

**Shell escaping**: For `swap!`, `nil?` etc., write a temp .clj file instead of `-e`.
**yq and `!` keys**: Never use `yq -i` for keys containing `!` — use Edit tool directly.

## Dual Backend (D6)

| Backend    | Path                                | Role                   |
| ---------- | ----------------------------------- | ---------------------- |
| VM         | `src/engine/vm/vm.zig`              | Bytecode compiler + VM |
| TreeWalk   | `src/engine/evaluator/tree_walk.zig`| Direct AST evaluator   |
| EvalEngine | `src/engine/eval_engine.zig`        | Runs both, compares    |

**Rules**: Implement in both backends. Add `EvalEngine.compare()` test.
If Compiler emits a direct opcode, TreeWalk must handle via builtin dispatch.
When editing `compiler.zig`, `.claude/rules/compiler-check.md` auto-loads.
Always verify on **both VM + TreeWalk** when porting tests or fixing bugs.

## vars.yaml

**CRITICAL: Always update vars.yaml when implementing new vars or namespaces.**
Every new `defn`, `def`, `defmacro` in any `.clj` file or Zig builtin must be
reflected in vars.yaml. When adding a new namespace, add the full section.
When marking vars done/skip, also update `note:` with the reason (especially for skip).
README.md namespace tables are derived from vars.yaml — keep it the source of truth.

```bash
# Coverage summary (use at Orient)
yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' .dev/status/vars.yaml
# Update: yq -i '.vars.clojure_core["name"].status = "done"' .dev/status/vars.yaml
```

Status values: `done`, `todo`, `skip`.
Notes: `"JVM interop"`, `"builtin (upstream is pure clj)"`, `"stub"`, `"UPSTREAM-DIFF: ..."`.

## Clojure Implementation Rule

1. **Place in correct namespace** — see `.claude/references/impl-tiers.md`
2. **Read JVM upstream** source first (add-dir: `clojure/src/clj/clojure/`)
3. **Use upstream verbatim** if no Java interop. If simplified: add `UPSTREAM-DIFF:` note.

## Java Interop Policy

See `.claude/rules/java-interop.md` (auto-loads on .clj/analyzer/builtin edits).
Do NOT skip features that look JVM-specific — try Zig equivalents first.

## Zig 0.15.2 Pitfalls

Check `.claude/references/zig-tips.md` first, then Zig stdlib at
`/opt/homebrew/Cellar/zig/0.15.2/lib` or Beta's `docs/reference/zig_guide.md`.

## References

| Topic             | Location                             | When to read                               |
| ----------------- | ------------------------------------ | ------------------------------------------ |
| Refactoring plan  | `.dev/refactoring-plan.md`           | Phase 97 task details (R0-R12)             |
| Zone deps rule    | `.claude/rules/zone-deps.md`         | Auto-loads on src/ edits                   |
| Zig tips          | `.claude/references/zig-tips.md`     | Before writing Zig code, on compile errors |
| Impl tiers        | `.claude/references/impl-tiers.md`   | When implementing a new function           |
| Java interop      | `.claude/rules/java-interop.md`      | Auto-loads on .clj/analyzer/builtin edits  |
| Test porting      | `.claude/rules/test-porting.md`      | Auto-loads on test file edits              |
| Roadmap           | `.dev/roadmap.md`                    | Phase Tracker (top) for next task; phase section for details |
| Deferred items    | `.dev/checklist.md`                  | F## items — blockers to resolve            |
| Decisions         | `.dev/decisions.md` (D3-D109)        | Architectural decisions reference          |
| Design document   | `.dev/future.md`                     | When planning new phases or major features |
| All-Zig plan      | `.dev/all-zig-plan.md`               | Full .clj→Zig migration plan (Phases A-E)  |
| Optimizations     | `.dev/optimizations.md`              | Completed + future optimization catalog    |
| Known issues      | `.dev/known-issues.md`               | Bug/workaround/debt tracking (P0-P3)       |
| Baselines         | `.dev/baselines.md`                  | Non-functional regression thresholds       |
| Bytecode debug    | `./zig-out/bin/cljw --dump-bytecode` | When VM tests fail or bytecode looks wrong |
