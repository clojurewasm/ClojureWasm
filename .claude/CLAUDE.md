# ClojureWasm

Full-scratch Clojure implementation in Zig 0.15.2. Behavioral compatibility target.
Reference: ClojureWasmBeta (via add-dir). Design: `.dev/future.md`. Memo: `.dev/memo.md`.

## Language Policy

- **All code in English**: identifiers, comments, docstrings, commit messages, markdown

## TDD (t-wada style)

1. **Red**: Write exactly one failing test first
2. **Green**: Write minimum code to pass
3. **Refactor**: Improve code while keeping tests green

- Never write production code before a test (1 test → 1 impl → verify cycle)
- Progress: "Fake It" → "Triangulate" → "Obvious Implementation"
- Zig file layout: imports → pub types/fns → private helpers → tests at bottom

## Critical Rules

- **One task = one commit**. Never batch multiple tasks.
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

If memo.md has no active task: read `.dev/roadmap.md` → pick first pending phase sub-task.

If implementing functions, check coverage:
```bash
yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' .dev/status/vars.yaml
```

**2. Plan**

1. Move current `## Current Task` content → `## Previous Task` (overwrite previous)
2. Write new task design in `## Current Task`
3. Check `roadmap.md` Phase Notes for context on the sub-task

**3. Execute**

- TDD cycle: Red → Green → Refactor
- Run tests: `zig build test`
- Run e2e tests: `bash test/e2e/run_e2e.sh`
- **Upstream test porting** (Phase 42+): Follow `.dev/test-porting-plan.md`
  - Port relevant upstream tests for each sub-task
  - Run full upstream regression suite before committing
- `compiler.zig` modified → `.claude/rules/compiler-check.md` auto-loads

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

1. **decisions.md**: D## entry only for architectural decisions (new Value variant, new subsystem, etc.)
2. **checklist.md**: Remove resolved F##, add new F##
3. **vars.yaml**: Mark implemented vars `done` (when implementing vars)
4. **e2e tests**: `bash test/e2e/run_e2e.sh` passes (when changing execution code)
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
   - `zig build test` — verify CW tests pass (bridge delegates to zwasm)
   - Wasm engine changes go in zwasm repo (`../zwasm/`), not CW
   - `bash bench/wasm_bench.sh --quick` — verify wasm benchmarks still work
8. **Non-functional regression** (when changing execution code: src/vm/, src/evaluator/,
   src/compiler/, src/runtime/, src/builtins/, src/wasm/, bootstrap):
   - **Binary size**: `zig build -Doptimize=ReleaseSafe && stat -f%z zig-out/bin/cljw` — ≤ 4.2MB
   - **Startup**: `hyperfine -N --warmup 3 --runs 5 './zig-out/bin/cljw -e nil'` — ≤ 5ms
   - **RSS**: `/usr/bin/time -l ./zig-out/bin/cljw -e nil 2>&1 | grep 'maximum resident'` — ≤ 12MB
   - **Benchmarks**: `bash bench/run_bench.sh --quick` — no CW benchmark > 1.2x baseline
   - **Hard block**: Do NOT commit if any threshold exceeded.
     Benchmark regression → stop, profile, fix in place or insert optimization phase first.
   - Baselines & policy: `.dev/baselines.md`.

### Phase Completion

When Task Queue empty:

1. If next phase exists in `roadmap.md`: create Task Queue in memo.md
2. If not: plan new phase:
   - Read `roadmap.md` Phase Notes, `.dev/future.md`, `checklist.md`
   - Priority: bugs > blockers > deferred items > features
   - Update memo.md with new Task Queue
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

| Backend    | Path                            | Role                   |
| ---------- | ------------------------------- | ---------------------- |
| VM         | `src/vm/vm.zig`                 | Bytecode compiler + VM |
| TreeWalk   | `src/evaluator/tree_walk.zig`   | Direct AST evaluator   |
| EvalEngine | `src/runtime/eval_engine.zig`   | Runs both, compares    |

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
| Zig tips          | `.claude/references/zig-tips.md`     | Before writing Zig code, on compile errors |
| Impl tiers        | `.claude/references/impl-tiers.md`   | When implementing a new function           |
| Java interop      | `.claude/rules/java-interop.md`      | Auto-loads on .clj/analyzer/builtin edits  |
| Test porting      | `.claude/rules/test-porting.md`      | Auto-loads on test file edits              |
| Roadmap           | `.dev/roadmap.md`                    | Phase planning — always read for next task |
| Deferred items    | `.dev/checklist.md`                  | F## items — blockers to resolve            |
| Decisions         | `.dev/decisions.md` (D3-D101+)       | Architectural decisions reference          |
| Design document   | `.dev/future.md`                     | When planning new phases or major features |
| Optimizations     | `.dev/optimizations.md`              | Completed + future optimization catalog    |
| Skip recovery     | `.dev/skip-recovery.md`              | When implementing skip vars                |
| Test porting plan | `.dev/test-porting-plan.md`          | When porting upstream tests                |
| Baselines         | `.dev/baselines.md`                  | Non-functional regression thresholds       |
| Bytecode debug    | `./zig-out/bin/cljw --dump-bytecode` | When VM tests fail or bytecode looks wrong |
