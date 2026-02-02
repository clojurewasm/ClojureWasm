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

## Critical Rules (read every session)

- **One task = one commit**. Never batch multiple tasks into a single commit.
  Each task gets its own `git commit` covering plan + impl + status updates.
- **Design decisions → `.dev/notes/decisions.md` immediately**. If you chose
  between alternatives, added global state, deferred VM support, or introduced
  a new architectural pattern, record a D## entry _before_ moving to the next task.
- **D6 exceptions require both a decision record and a checklist entry**.
  If a feature is TreeWalk-only (VM deferred), add a D## entry in decisions.md
  explaining why, _and_ add a corresponding F## item in `.dev/checklist.md`.
- **Update `.dev/checklist.md` when deferred items are resolved or added**.
  Strike-through resolved items, add new F## entries for newly deferred work,
  and keep the "Last updated" line current.

## Session Workflow

### On Start

1. Read `.dev/plan/memo.md` — **the single source of "what to do next"**
2. Read `.dev/checklist.md` (deferred work + invariants — scan for newly relevant items)
3. Quick status check: `yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' .dev/status/vars.yaml`
4. Follow memo.md instructions:
   - **Task file exists** → read it, resume from `## Log`
   - **Task file = "(none)"** → create task file (read roadmap + Beta refs, write plan)
   - **Phase planning needed** → see "Phase Planning" below

### Phase Planning

When memo.md says "phase planning needed" or no next task is defined:

1. Read `.dev/plan/roadmap.md` + `.dev/checklist.md` for context
2. Evaluate priorities: bugs > blockers > feature expansion
3. **Create a new phase section** in roadmap.md with task table
4. Update memo.md: set Current task to first task of new phase
5. Commit the plan: `git commit -m "Add Phase X to roadmap"`
6. Then start the first task normally

### During Development

1. TDD cycle: Red -> Green -> Refactor
2. Append progress to task file `## Log`
3. Do NOT commit intermediate steps — all changes go into one commit per task
4. Design decisions / deferred items → record in `.dev/notes/decisions.md`

### On Task Completion

**CRITICAL: Always commit before moving to the next task.**

1. Move task file from `active/` to `archive/`
2. Update roadmap.md Archive column
3. Advance memo.md — **forward-looking only**:
   - Set Current task + Task file to the NEXT task
   - Update Technical Notes with context the next task needs
   - Do NOT list completed work (that's in roadmap/archive)
4. If new Vars were implemented, update `.dev/status/vars.yaml` (status/note)
5. If any deferred item was resolved or became relevant, update `.dev/checklist.md`
6. `git add` + `git commit` — **single commit covering plan + impl + status**
7. Verify commit succeeded before proceeding to the next task

### memo.md Role

memo.md is **the instruction sheet for the next session**. It must always answer:

- "What task should I work on?" (Current task + Task file)
- "What context do I need?" (Technical Notes)
- "Are there blockers?" (Blockers field)

It is NOT a history log. Completed work goes to roadmap.md + archive/.
When a phase ends, memo.md must either point to the next task OR say
"phase planning needed" so the next session knows to plan.

## Build & Test

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

### CLI Evaluation

```bash
# -e flag for simple expressions
./zig-out/bin/cljw -e '(+ 1 2)'

# File execution (preferred for complex expressions)
./zig-out/bin/cljw path/to/file.clj

# Backend selection
./zig-out/bin/cljw -e '(+ 1 2)'                # VM (default)
./zig-out/bin/cljw --tree-walk -e '(+ 1 2)'   # TreeWalk
```

**IMPORTANT — Shell escaping with `!` and `?`**:
Claude Code's Bash tool escapes `!` inside single quotes (`swap!` → `swap\!`),
breaking Clojure symbols like `swap!`, `reset!`, `nil?`, `empty?`.
When testing expressions containing `!` or `?`:

1. **Write a temp .clj file** and execute via `./zig-out/bin/cljw file.clj`
2. **Never use `-e`** for expressions with `!` — the shell will mangle them
3. Clean up temp files after testing

## Differences from Beta

Production version is a full redesign from Beta. Key changes:

- Instantiated VM (no threadlocal) -> future.md SS15.5
- GcStrategy trait for GC abstraction -> future.md SS5 (currently arena stub; real GC deferred)
- BuiltinDef with metadata (doc, arglists, added) -> future.md SS10
- core.clj loaded at startup via read+eval (AOT @embedFile pipeline deferred to Phase 4)
- Design decisions recorded in `.dev/notes/decisions.md` (ADR in docs/adr/ has one entry)

## Dual Backend Development (D6, SS9.2)

Two evaluation backends exist and **should be kept in sync**:

| Component  | Path                                 | Role                           |
| ---------- | ------------------------------------ | ------------------------------ |
| VM         | `src/native/vm/vm.zig`               | Bytecode compiler + VM (fast)  |
| TreeWalk   | `src/native/evaluator/tree_walk.zig` | Direct Node -> Value (correct) |
| EvalEngine | `src/common/eval_engine.zig`         | Runs both, compares results    |

**Current status**: TreeWalk is the primary backend (used by CLI).
VM has basic opcodes (arithmetic, var, closures, recur) but lacks Phase 3
builtins (variadic arith, predicates, collection ops). VM parity is P1 in
`.dev/checklist.md`.

**Rules when adding new features** (builtins, special forms, operators, etc.):

1. Implement in **both** VM and TreeWalk
2. Add `EvalEngine.compare()` test to verify both backends produce the same result
3. If the Compiler emits a direct opcode (e.g. `+` -> `add`), TreeWalk must
   handle the equivalent via its builtin dispatch

Design rationale: `.dev/notes/decisions.md` D6

## Status Tracking (.dev/status/)

YAML-based progress tracking for Clojure compatibility. See `.dev/status/README.md`
for full schema documentation.

| File         | Content                                    |
| ------------ | ------------------------------------------ |
| `vars.yaml`  | Var implementation status (29 namespaces)  |
| `bench.yaml` | Benchmark results and optimization history |

### Quick Queries (yq)

```bash
# Implementation coverage (clojure.core)
yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' .dev/status/vars.yaml

# All namespaces
yq '.vars | keys' .dev/status/vars.yaml

# Unimplemented functions
yq '.vars.clojure_core | to_entries[] | select(.value.status == "todo" and .value.type == "function") | .key' .dev/status/vars.yaml

# Entries with notes
yq '.vars.clojure_core | to_entries[] | select(.value.note) | .key + " -> " + .value.note' .dev/status/vars.yaml

# Count by type (done only)
yq '[.vars.clojure_core | to_entries[] | select(.value.status == "done") | .value.type] | group_by(.) | map({(.[0]): length})' .dev/status/vars.yaml
```

### When to Update

- **vars.yaml**: After implementing new Vars (builtins, core.clj fns/macros)
- **bench.yaml**: After performance optimizations (append to history)
- **Generation**: `clj scripts/generate_vars_yaml.clj` regenerates from upstream
  (status fields reset to todo — use only for adding new namespaces)

## IDE Integration (ZLS / Emacs MCP)

Use IDE tools actively when exploring/modifying Zig code to reduce context consumption.

| Tool                   | Purpose                          | Usage                            |
| ---------------------- | -------------------------------- | -------------------------------- |
| `imenu-list-symbols`   | List functions/structs in a file | Understand structure before Read |
| `xref-find-references` | Find all references to a symbol  | Assess impact before refactoring |
| `getDiagnostics`       | Get compile errors/warnings      | Detect errors before `zig build` |

### Usage Patterns

**File structure overview (before Read):**

```
imenu-list-symbols(file_path: "src/common/builtin/registry.zig")
-> Returns all function names and line numbers -> Read only needed functions
```

**Impact analysis before refactoring:**

```
xref-find-references(identifier: "Value", file_path: "src/common/value.zig")
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
produce human-readable bytecode disassembly. Use within tests:

```zig
// In any test — dump to stderr for quick visual inspection
var buf: [4096]u8 = undefined;
var w: std.Io.Writer = .fixed(&buf);
try chunk.dump(&w);
std.debug.print("\n{s}\n", .{w.buffered()});
```

When a compiler or VM test fails unexpectedly, add a dump call before the
failing assertion to see what was actually compiled. Remove after debugging.

## Benchmark Suite

11 benchmarks across 5 categories (computation, collections, HOF, state).
Compares ClojureWasm against C, Zig, Java, Python, Ruby, Clojure JVM, Babashka.
Parameters sized for hyperfine precision (10ms-1s per run).

```bash
# ClojureWasm only
bash bench/run_bench.sh

# All languages
bash bench/run_bench.sh --all

# Record baseline
bash bench/run_bench.sh --all --record --version="Phase 5 baseline"

# Single benchmark with hyperfine
bash bench/run_bench.sh --bench=fib_recursive --hyperfine

# ReleaseFast build
bash bench/run_bench.sh --release
```

**When to run**:

- After performance optimizations → `bash bench/run_bench.sh --record`
- After adding new builtins/features that affect evaluation → ClojureWasm-only
- Before recording a new baseline → `--record --version="..."`
- Other languages rarely change → only run `--all` for initial baseline or language upgrades

**Recording**: `--record` rotates `latest` → `previous` and shows ±% delta.
Two generations kept in bench.yaml for quick regression check.

Results go to `.dev/status/bench.yaml`. See `bench/README.md` for full docs.

## Zig 0.15.2 Quick Reference

Full guide: Beta's docs/reference/zig_guide.md
Tips & pitfalls: @.claude/references/zig-tips.md

## Design Principles

- **comptime**: Build tables at compile time
- **ArenaAllocator**: Bulk free per phase
- **Arrays > pointers**: NodeId = u32 for index references
- **Small structs**: Token should be 8-16 bytes
