# ClojureWasm

Full-scratch Clojure implementation in Zig 0.15.2. Behavioral compatibility target.
Reference: ClojureWasmBeta (via add-dir). Design: `.dev/future.md`. State: `.dev/plan/memo.md`.

## Language Policy

- **All code in English**: identifiers, comments, docstrings, commit messages, markdown
- Agent response language: configure in `~/.claude/CLAUDE.md`

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

### Loop: Orient → Execute → Commit → Repeat

**1. Orient** (every iteration)

```bash
git log --oneline -3 && git status --short
yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' .dev/status/vars.yaml
```

Read: `.dev/plan/memo.md` (current task, next task, technical notes)

**2. Prepare**

- **Task file exists** in `.dev/plan/active/`: resume from `## Log`
- **Task file missing**: create from `memo.md` Task Queue
  1. Read `roadmap.md` Phase Notes for context
  2. Check `.dev/future.md` if task touches new subsystem (IO, GC, etc.)
  3. Write task file: `## Plan` + empty `## Log`

**3. Execute**

- TDD cycle: Red → Green → Refactor
- Run tests: `zig build test`
- Append progress to task file `## Log`
- `compiler.zig` modified → `.claude/rules/compiler-check.md` auto-loads

**4. Complete** (per task)

1. Move task file: `active/` → `archive/`
2. Run **Commit Gate Checklist** (below)
3. Single git commit
4. **Loop back to Orient** — do NOT stop

### When to Stop

Stop **only** when:

- User explicitly requests stop
- Ambiguous requirements with multiple valid directions (rare)
- Phase queue empty AND next phase undefined in `roadmap.md`

When in doubt, **continue** — pick the most reasonable option and proceed.

### Commit Gate Checklist

Run before every commit:

1. **decisions.md**: D## entry only for architectural decisions (new Value variant, new subsystem, etc.)
2. **checklist.md**: Strike resolved F##, add new F##
3. **vars.yaml**: Mark implemented vars `done`
4. **memo.md**: Advance task, update Technical Notes

### Phase Completion

When Task Queue empty:

1. If next phase exists in `roadmap.md`: create Task Queue in `memo.md`
2. If not: plan new phase:
   - Read `roadmap.md` Phase Notes, `.dev/future.md`, `checklist.md`
   - Priority: bugs > blockers > deferred items > features
   - Update `memo.md` with new Task Queue
   - Commit: `Plan Phase X: [name]`
3. Continue to first task

## Build & Test

```bash
zig build              # Build
zig build test         # Run all tests
zig build test -- "X"  # Specific test only
./zig-out/bin/cljw -e '(+ 1 2)'              # VM (default)
./zig-out/bin/cljw --tree-walk -e '(+ 1 2)'  # TreeWalk
./zig-out/bin/cljw path/to/file.clj           # File execution
```

**Shell escaping with `!` and `?`**: Claude Code escapes `!` in single quotes.
For expressions with `swap!`, `nil?` etc., **write a temp .clj file** and run
via `./zig-out/bin/cljw file.clj`. Never use `-e` for these.

## Dual Backend (D6)

| Backend    | Path                                 | Role                   |
| ---------- | ------------------------------------ | ---------------------- |
| VM         | `src/native/vm/vm.zig`               | Bytecode compiler + VM |
| TreeWalk   | `src/native/evaluator/tree_walk.zig` | Direct AST evaluator   |
| EvalEngine | `src/common/eval_engine.zig`         | Runs both, compares    |

**Rules when adding new features**:

1. Implement in **both** VM and TreeWalk
2. Add `EvalEngine.compare()` test
3. If Compiler emits a direct opcode, TreeWalk must handle via builtin dispatch

When editing `compiler.zig`, `.claude/rules/compiler-check.md` auto-loads into context.

### Test Evaluation Policy

Always run tests on **both backends** to catch backend-specific bugs:

```bash
./zig-out/bin/cljw test.clj              # VM (default)
./zig-out/bin/cljw --tree-walk test.clj  # TreeWalk
```

Testing only one backend may hide bugs in the other. When porting tests or
verifying fixes, confirm behavior matches on both VM and TreeWalk.

## Status Tracking

| File         | Content                   | Update When                     |
| ------------ | ------------------------- | ------------------------------- |
| `vars.yaml`  | Var implementation status | After implementing new Vars     |
| `bench.yaml` | Benchmark results         | After performance optimizations |

### vars.yaml Usage

**Check implementation status** (use at session start):

```bash
# Coverage summary
yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' .dev/status/vars.yaml
yq '.vars.clojure_core | to_entries | length' .dev/status/vars.yaml

# Check specific var
yq '.vars.clojure_core["var-name"]' .dev/status/vars.yaml
```

**Update after implementation**:

```bash
# Set status to done
yq -i '.vars.clojure_core["var-name"].status = "done"' .dev/status/vars.yaml

# Add note for non-upstream implementation
yq -i '.vars.clojure_core["var-name"].note = "builtin (upstream is pure clj)"' .dev/status/vars.yaml
```

**Status values**: `done`, `todo`, `skip`

**Note conventions**:

- `"JVM interop"` — JVM-specific, not applicable
- `"builtin (upstream is pure clj)"` — Zig builtin, upstream is pure Clojure
- `"VM intrinsic opcode"` — Optimized VM instruction
- `"UPSTREAM-DIFF: <what>; missing: <deps>"` — Simplified implementation

Use `yq` for queries (e.g. `yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length'`).

### Clojure Implementation Rule

When adding a function/macro to any `.clj` file:

1. **Place in correct namespace** — see `.claude/references/impl-tiers.md` for mapping
   - `clojure.core` → `src/clj/clojure/core.clj`
   - `clojure.walk` → `src/clj/clojure/walk.clj`
   - `clojure.set` → `src/clj/clojure/set.clj`
   - `clojure.string` → `src/clj/clojure/string.clj`
2. **Read upstream** first (e.g., `src/clj/clojure/core.clj` for core functions)
3. **Use upstream verbatim** if no Java interop / JVM-specific code
4. **If simplified**: add `UPSTREAM-DIFF:` note to vars.yaml
   - Format: `UPSTREAM-DIFF: <what changed>; missing: <dep list>`

### Java Interop Policy

Java interop patterns → `.claude/rules/java-interop.md` (auto-loads on .clj/analyzer/builtin edits).
Do NOT skip features that look JVM-specific — implement Zig equivalents first.

## Zig 0.15.2 Pitfalls

When unsure about Zig 0.15.2 API usage,
check `.claude/references/zig-tips.md` first, then the Zig 0.15.2 stdlib
source at `/opt/homebrew/Cellar/zig/0.15.2/lib` or Beta's `docs/reference/zig_guide.md`.

## References

| Topic             | Location                             | When to read                               |
| ----------------- | ------------------------------------ | ------------------------------------------ |
| Zig tips/pitfalls | `.claude/references/zig-tips.md`     | Before writing Zig code, on compile errors |
| Impl tier guide   | `.claude/references/impl-tiers.md`   | When implementing a new function           |
| Java interop      | `.claude/rules/java-interop.md`      | Auto-loads on .clj/analyzer/builtin edits  |
| Design document   | `.dev/future.md`                     | When planning new phases or major features |
| Zig 0.15.2 guide  | Beta's `docs/reference/zig_guide.md` | When Zig 0.15 API is unclear               |
| Bytecode debug    | `./zig-out/bin/cljw --dump-bytecode` | When VM tests fail or bytecode looks wrong |
