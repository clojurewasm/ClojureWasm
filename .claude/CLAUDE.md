# ClojureWasm

Full-scratch Clojure implementation in Zig 0.15.2. Behavioral compatibility target.
Reference: ClojureWasmBeta (via add-dir). Design: `.dev/future.md`. Memo: `.dev/plan/memo.md`.

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
- **Architectural decisions only** → `.dev/notes/decisions.md` (D## entry).
  Bug fixes and one-time migrations do NOT need D## entries.
- **Update `.dev/checklist.md`** when deferred items are resolved or added.

## Autonomous Workflow

**Default mode: Continuous autonomous execution.**
After session resume, continue automatically from where you left off.

### Loop: Orient → Plan → Execute → Commit → Repeat

**1. Orient** (every iteration)

```bash
git log --oneline -3 && git status --short
yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' .dev/status/vars.yaml
```

Read: `.dev/plan/memo.md` (current state, task queue, handover notes)

**2. Plan**

1. Move current `## Current Task` content → `## Previous Task` (overwrite previous)
2. Write new task design in `## Current Task`
3. Check `roadmap.md` Phase Notes and `.dev/future.md` for context on new subsystems

**3. Execute**

- TDD cycle: Red → Green → Refactor
- Run tests: `zig build test`
- `compiler.zig` modified → `.claude/rules/compiler-check.md` auto-loads

**4. Complete** (per task)

1. Run **Commit Gate Checklist** (below)
2. Single git commit
3. Update memo.md: advance Current State and Task Queue
4. **Immediately loop back to Orient** — do NOT stop, do NOT summarize,
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

See `.dev/plan/memo.md` for task queue and current state.
Do NOT stop between tasks within a phase.

**Phase order**: ... → 22c(test gaps) → **24(optimize)** → 25(wasm)

Stop **only** when:

- User explicitly requests stop
- Ambiguous requirements with multiple valid directions (rare)
- **Phase 24 is complete** (24B.4 done, or 24C if pursued — loop ends here)
- Phase 25 is complete (all planned phases done)

Do NOT stop for:

- Task Queue becoming empty (plan next task and continue)
- Session context getting large (compress and continue)
- "Good stopping points" — there are none until the current phase is done

When in doubt, **continue** — pick the most reasonable option and proceed.

### Commit Gate Checklist

Run before every commit:

1. **decisions.md**: D## entry only for architectural decisions (new Value variant, new subsystem, etc.)
2. **checklist.md**: Remove resolved F##, add new F##
3. **vars.yaml**: Mark implemented vars `done`
4. **memo.md**: Advance to next task
   - Update `## Current Task` with next task details
   - Remove completed task from Task Queue
   - Update Handover Notes if status changed (done/architecture/new info)
5. **test-porting.md**: When changing test/upstream/ files:
   - All changes have CLJW markers
   - No assertion deletions — implement missing features instead
   - File header statistics updated
   - Both backends verified

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

**Always use ReleaseSafe for benchmarks.** Never use Debug or ReleaseFast.

```bash
# Run all benchmarks (display only)
bash bench/run_bench.sh --release-safe --backend=vm
# Single benchmark
bash bench/run_bench.sh --release-safe --backend=vm --bench=lazy_chain

# Record to history (hyperfine, auto-builds ReleaseSafe)
bash bench/record.sh --id="24C.1" --reason="Closure specialization"
# Single benchmark record
bash bench/record.sh --id="24C.1" --reason="test" --bench=fib_recursive
# Overwrite existing entry
bash bench/record.sh --id="24C.1" --reason="re-measure" --overwrite
# Delete entry
bash bench/record.sh --delete="24C.1"

# Manual ReleaseSafe build
zig build -Doptimize=ReleaseSafe
```

History: `bench/history.yaml` — all entries with id, date, reason, commit, time_ms, mem_mb.
**Record after every optimization task.** Use task ID as entry id (e.g. "24C.1").

## Notice

**Shell escaping**: For `swap!`, `nil?` etc., write a temp .clj file instead of `-e`.
**yq and `!` keys**: Never use `yq -i` for keys containing `!` — use Edit tool directly.

## Dual Backend (D6)

| Backend    | Path                                 | Role                   |
| ---------- | ------------------------------------ | ---------------------- |
| VM         | `src/native/vm/vm.zig`               | Bytecode compiler + VM |
| TreeWalk   | `src/native/evaluator/tree_walk.zig` | Direct AST evaluator   |
| EvalEngine | `src/common/eval_engine.zig`         | Runs both, compares    |

**Rules**: Implement in both backends. Add `EvalEngine.compare()` test.
If Compiler emits a direct opcode, TreeWalk must handle via builtin dispatch.
When editing `compiler.zig`, `.claude/rules/compiler-check.md` auto-loads.
Always verify on **both VM + TreeWalk** when porting tests or fixing bugs.

## vars.yaml

```bash
# Coverage summary (use at Orient)
yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' .dev/status/vars.yaml
# Update: yq -i '.vars.clojure_core["name"].status = "done"' .dev/status/vars.yaml
```

Status values: `done`, `todo`, `skip`.
Notes: `"JVM interop"`, `"builtin (upstream is pure clj)"`, `"UPSTREAM-DIFF: ..."`.

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

| Topic            | Location                             | When to read                               |
| ---------------- | ------------------------------------ | ------------------------------------------ |
| Zig tips         | `.claude/references/zig-tips.md`     | Before writing Zig code, on compile errors |
| Impl tiers       | `.claude/references/impl-tiers.md`   | When implementing a new function           |
| Java interop     | `.claude/rules/java-interop.md`      | Auto-loads on .clj/analyzer/builtin edits  |
| Test porting     | `.claude/rules/test-porting.md`      | Auto-loads on test file edits              |
| Test gap analysis| `.dev/plan/test-gap-analysis.md`     | Phase 22c planning and execution           |
| Roadmap          | `.dev/plan/roadmap.md`               | Phase planning, future phase notes         |
| Deferred items   | `.dev/checklist.md`                  | F## items — blockers to resolve            |
| Design document  | `.dev/future.md`                     | When planning new phases or major features |
| Bench history    | `bench/history.yaml`                 | Benchmark progression across optimizations |
| Bytecode debug   | `./zig-out/bin/cljw --dump-bytecode` | When VM tests fail or bytecode looks wrong |
