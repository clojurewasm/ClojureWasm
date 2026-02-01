# ClojureWasm

Full-scratch Clojure implementation in Zig. Targeting behavioral compatibility (black-box).

Reference implementation: ClojureWasmBeta repository (via add-dir)
Design document: ClojureWasmBeta's docs/future.md

Current state: see .dev/plan/memo.md

## Language Policy

- **All code in English**: identifiers, comments, docstrings, commit messages, PR descriptions
- No non-English text in source code or version control history
- Zig 0.15.2 conventions apply (see Beta's docs/reference/zig_guide.md)
- Agent response language is a personal preference — configure in `~/.claude/CLAUDE.md`

> **Note for contributors**: to receive agent responses in your preferred language,
> add a directive to your personal `~/.claude/CLAUDE.md` (not committed to the repo).
> Example: `Respond in Japanese.` or `Respond in Korean.`

## Development Method: TDD (t-wada style)

IMPORTANT: Strictly follow the TDD approach recommended by t-wada (Takuto Wada).

1. **Red**: Write exactly one failing test first
2. **Green**: Write the minimum code to make it pass
3. **Refactor**: Improve code while keeping tests green

- Never write production code before a test
- Never add multiple tests at once (1 test -> 1 impl -> verify cycle)
- Always confirm the test is Red before moving to Green
- Progress: "Fake It" -> "Triangulate" -> "Obvious Implementation"
- Refactoring must not change behavior (revert immediately if tests break)

### Zig File Layout Convention

During TDD, tests are written first. However, in the Refactor phase,
arrange the final file in standard Zig order:

1. `const` / `@import` declarations
2. `pub const` / `pub fn` — public types and functions
3. Private helpers
4. `test "..." { ... }` blocks — **always at the bottom**

This matches Zig standard library conventions and keeps files readable.

## Session Workflow

### On Start
1. Read `.dev/plan/memo.md` (current task + task file path)
2. If task file exists: read it, resume from `## Log`
3. If task file missing: create it (read roadmap + Beta refs, write plan)

### During Development
1. TDD cycle: Red -> Green -> Refactor
2. Append progress to task file `## Log`
3. Do NOT commit intermediate steps — all changes go into one commit per task
4. Design decisions / deferred items → record in `.dev/notes/decisions.md`

### On Task Completion

**CRITICAL: Always commit before moving to the next task.**

1. Move task file from `active/` to `archive/`
2. Update roadmap.md Archive column
3. Advance memo.md to next task (clear Task file path)
4. `git add` + `git commit` — **single commit covering plan + impl + status**
5. Verify commit succeeded before proceeding to the next task

## Build & Test

> Available after build.zig is created (Phase 0, Task 5).

```bash
# Enter dev shell (all tools on PATH)
nix develop

# Build
zig build

# Run tests
zig build test

# Specific test only
zig build test -- "Reader basics"
```

## Differences from Beta

Production version is a full redesign from Beta. Key changes:
- Instantiated VM (no threadlocal) -> future.md SS15.5
- GcStrategy trait for GC abstraction -> future.md SS5
- BuiltinDef with metadata (doc, arglists, added) -> future.md SS10
- core.clj AOT compilation -> future.md SS9.6
- Design decisions recorded as ADRs in docs/adr/

## Dual Backend Development (D6, SS9.2)

Two evaluation backends exist and **must be kept in sync**:

| Component   | Path                                     | Role                          |
|-------------|------------------------------------------|-------------------------------|
| VM          | `src/native/vm/vm.zig`                   | Bytecode compiler + VM (fast) |
| TreeWalk    | `src/native/evaluator/tree_walk.zig`     | Direct Node -> Value (correct)|
| EvalEngine  | `src/common/eval_engine.zig`             | Runs both, compares results   |

**Rules when adding new features** (builtins, special forms, operators, etc.):
1. Implement in **both** VM and TreeWalk
2. Add `EvalEngine.compare()` test to verify both backends produce the same result
3. If the Compiler emits a direct opcode (e.g. `+` -> `add`), TreeWalk must
   handle the equivalent via its builtin dispatch

Design rationale: `.dev/notes/decisions.md` D6

## IDE Integration (ZLS / Emacs MCP)

Use IDE tools actively when exploring/modifying Zig code to reduce context consumption.

| Tool                   | Purpose                          | Usage                            |
|------------------------|----------------------------------|----------------------------------|
| `imenu-list-symbols`   | List functions/structs in a file | Understand structure before Read |
| `xref-find-references` | Find all references to a symbol  | Assess impact before refactoring |
| `getDiagnostics`       | Get compile errors/warnings      | Detect errors before `zig build` |

### Usage Patterns

**File structure overview (before Read):**

```
imenu-list-symbols(file_path: "src/lib/core.zig")
-> Returns all function names and line numbers -> Read only needed functions
```

**Impact analysis before refactoring:**

```
xref-find-references(identifier: "Value", file_path: "src/runtime/value.zig")
-> Returns all files/lines using Value -> Understand change scope
```

**Immediate error detection after edits:**

```
getDiagnostics(uri: "file:///path/to/edited.zig")
-> Detect compile errors before building
```

### Notes

- `xref-find-apropos` and `treesit-info` are not functional for Zig (tags / tree-sitter not configured)
- `xref-find-references` may return many results for core types (Value, etc.)

## Debugging Bytecode

`Chunk.dump(writer)` and `FnProto.dump(writer)` in `src/common/bytecode/chunk.zig`
produce human-readable bytecode disassembly. No CLI entry point yet (comes in T3.13),
so use these within tests:

```zig
// In any test — dump to stderr for quick visual inspection
var buf: [4096]u8 = undefined;
var w: std.Io.Writer = .fixed(&buf);
try chunk.dump(&w);
std.debug.print("\n{s}\n", .{w.buffered()});
```

When a compiler or VM test fails unexpectedly, add a dump call before the
failing assertion to see what was actually compiled. Remove after debugging.

## Zig 0.15.2 Quick Reference

Full guide: Beta's docs/reference/zig_guide.md
Tips & pitfalls: @.claude/references/zig-tips.md

## Design Principles

- **comptime**: Build tables at compile time
- **ArenaAllocator**: Bulk free per phase
- **Arrays > pointers**: NodeId = u32 for index references
- **Small structs**: Token should be 8-16 bytes
