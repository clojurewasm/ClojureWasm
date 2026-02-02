# ClojureWasm Development Memo

## Current State

- Phase: 9.5 (Infrastructure Fixes)
- Roadmap: .dev/plan/roadmap.md
- Current task: T9.5.1 VM evalStringVM fn_val lifetime fix
- Task file: (none — create on start)
- Last completed: T9.15 type, class, instance?, isa?
- Note: T4.7 (AOT bytecode startup) deferred — needs macro serialization
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### T9.5.1: VM fn_val lifetime

- Root cause: src/common/bootstrap.zig:125-133
  evalStringVM loop creates Compiler per form, defer deinit frees fn_protos/fn_objects
  But def stores fn_val in Env → use-after-free on next form
- Single form works: `(+ 1 2)` OK, `(def f (fn [x] x))` OK
- Multi form crashes: `(def f (fn [x] x)) (f 5)` → "switch on corrupt value"
- Fix direction: stop freeing fn objects owned by Env (arena allocator or ownership transfer)
