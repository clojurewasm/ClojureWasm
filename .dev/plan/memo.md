# ClojureWasm Development Memo

## Current State

- Phase: 12 (Zig Foundation Completion + SCI Test Port)
- Roadmap: .dev/plan/roadmap.md
- Current task: T12.6 — Namespace ops I: all-ns, find-ns, ns-name, create-ns
- Task file: (none — create on start)
- Last completed: T12.5 — eval, macroexpand, macroexpand-1, read-string
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### T12.5 completed — eval/macroexpand/read-string builtins

Added 4 builtins in `src/common/builtin/eval.zig`:

- `read-string`: Reader -> Form -> Value pipeline
- `eval`: Value -> Form -> Analyzer -> TreeWalk eval (uses `bootstrap.macro_eval_env`)
- `macroexpand-1`: Single macro expansion via Var resolution + callFnVal
- `macroexpand`: Repeated expansion until stable (eql fixpoint, max 1000 iters)
- `bootstrap.macro_eval_env` made pub for eval builtin access
- Registry: 141 builtins, 256/702 vars done (+ 4 new)

### T12.6 scope

Namespace introspection basics: all-ns, find-ns, ns-name, create-ns

- `all-ns` — return list of all namespaces in Env
- `find-ns` — find namespace by symbol name
- `ns-name` — return name of namespace as symbol
- `create-ns` — create or find namespace
- These need access to Env (same pattern as eval.zig — use `bootstrap.macro_eval_env`)
- Reference: `src/common/env.zig` for Env.namespaces, `src/common/namespace.zig`

### Deferred items to watch

- **F24**: Before T12.9 (SCI triage), refine vars.yaml status values
  to include `stub` and `defer`. See SS10 (549-564).
- **F22**: T12.9 introduces compat_test.yaml for test tracking. See SS10 (495-509).

### Builtin Count

141 builtins registered
256/702 vars done
