# ClojureWasm

Full-scratch Clojure implementation in Zig 0.15.2. Behavioral compatibility target.
Reference: ClojureWasmBeta (via add-dir). Design: `.dev/future.md`. State: `.dev/plan/memo.md`.

## Language Policy

- **All code in English**: identifiers, comments, docstrings, commit messages
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
- **Design decisions → `.dev/notes/decisions.md` immediately** (D## entry).
- **D6 exceptions**: TreeWalk-only features need both a D## entry AND an F## in `.dev/checklist.md`.
- **Update `.dev/checklist.md`** when deferred items are resolved or added.

## Session Workflow

Autonomous task execution uses `/next` (single task) or `/continue` (loop).
**On invocation, read the full skill file** for the detailed workflow:

- `/next`: @.claude/skills/next/SKILL.md
- `/continue`: @.claude/skills/continue/SKILL.md

### Commit Gate Checklist (mandatory for every task commit)

This checklist applies to **all** commits — autonomous (`/next`, `/continue`) and manual:

1. **decisions.md**: Any design decisions made? (New Value variant, error type,
   architectural choice, API design) → append D## entry to `.dev/notes/decisions.md`
2. **checklist.md**: Any deferred items resolved or created?
   → Strike through resolved F##, add new F## with trigger condition
   → Update "Last updated" line to current phase/task
3. **vars.yaml**: Any new vars implemented? → mark `done`
4. **memo.md**: Advance current task, update Technical Notes with context for next session

### Manual Work

1. Read `.dev/plan/memo.md` first — the single source of "what to do next"
2. TDD cycle during development; append progress to task file `## Log`
3. On completion: move task file to archive, advance memo.md, **run Commit Gate above**, single git commit

### Phase Planning

When creating a new phase, read **all three**:

1. `.dev/plan/roadmap.md` — completed phases, future considerations
2. `.dev/future.md` — SS sections relevant to new phase (architecture, security, compatibility)
3. `.dev/checklist.md` — deferred items that may now be triggered

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

When editing `compiler.zig`, PostToolUse hook will remind you.
Run `/compiler-check` before commit to verify stack_depth/scope/backend sync.

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

Query reference: `.claude/references/yq-queries.md`

### core.clj Upstream Deviation Rule

When adding a function/macro to `src/clj/core.clj`:

1. **Read upstream** (`src/clj/clojure/core.clj`) first
2. **Use upstream verbatim** if no Java interop / JVM-specific code
3. **If simplified**: add `UPSTREAM-DIFF:` note to vars.yaml
   - Format: `UPSTREAM-DIFF: <what changed>; missing: <dep list>`

## IDE Tools

Use `imenu-list-symbols`, `xref-find-references`, `getDiagnostics` actively
for Zig code exploration. Details: `.claude/references/ide-patterns.md`

## Zig 0.15.2 Pitfalls

When unsure about Zig 0.15.2 API usage,
check `.claude/references/zig-tips.md` first, then the Zig 0.15.2 stdlib
source at `/opt/homebrew/Cellar/zig/0.15.2/lib` or Beta's `docs/reference/zig_guide.md`.

## References

| Topic              | Location                                   |
| ------------------ | ------------------------------------------ |
| Zig tips/pitfalls  | `.claude/references/zig-tips.md`           |
| yq query examples  | `.claude/references/yq-queries.md`         |
| IDE usage patterns | `.claude/references/ide-patterns.md`       |
| Debugging bytecode | `.claude/references/debugging-bytecode.md` |
| Benchmark suite    | `bench/README.md`                          |
| Design document    | `.dev/future.md`                           |
| Zig 0.15.2 guide   | Beta's `docs/reference/zig_guide.md`       |
