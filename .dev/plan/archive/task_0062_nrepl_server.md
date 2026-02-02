# T7.8: nREPL Server (TCP Socket)

## Goal

Implement a TCP-based nREPL server for editor integration (CIDER/Calva/Conjure).
Wire protocol: bencode (from T7.7). Minimum viable ops for editor connectivity.

## Design

Reference: ClojureWasmBeta/src/nrepl/server.zig (850 lines)

### Architecture

- `src/repl/nrepl.zig` — nREPL server module
- TCP listen on 127.0.0.1 (port configurable, 0 = OS auto-assign)
- `.nrepl-port` file for editor auto-detection
- Thread-per-client with mutex-serialized eval
- Session management (UUID v4, per-session namespace tracking)

### Ops (minimum viable)

| Op          | Description                 |
| ----------- | --------------------------- |
| clone       | Create new session          |
| close       | Destroy session             |
| describe    | Server info + supported ops |
| eval        | Evaluate code (multi-form)  |
| load-file   | Evaluate file content       |
| ls-sessions | List active sessions        |
| completions | Symbol prefix completion    |
| info/lookup | Symbol doc/arglists         |
| eldoc       | Function signature info     |
| ns-list     | List all namespaces         |

### API Differences from Beta

| Feature            | ClojureWasm                                | Beta                           |
| ------------------ | ------------------------------------------ | ------------------------------ |
| Output capture     | `io.setOutputCapture(alloc, buf)`          | `core.setOutputCapture(buf)`   |
| Find namespace     | `env.findNamespace(name)`                  | `env.findNs(name)`             |
| Current namespace  | `env.current_ns` (field)                   | `env.getCurrentNs()`           |
| All namespaces     | `env.namespaces.iterator()`                | `env.getAllNamespaces()`       |
| Ns vars iterator   | `ns.mappings.iterator()`                   | `ns.getAllVars()`              |
| Ns refers iterator | `ns.refers.iterator()`                     | `ns.getAllRefers()`            |
| Var namespace name | `v.ns_name`                                | same                           |
| Eval string        | `bootstrap.evalString(alloc, env, source)` | via Reader+Analyzer+EvalEngine |
| Error context      | `env.error_ctx` (instance-based)           | global `getLastError()`        |
| Value print        | `writeValue()` in main.zig (not public)    | `core.printValueToBuf()`       |

### Key Design Decisions

- Use `bootstrap.evalString` for eval (TreeWalk backend) — simple, correct
- Need to extract `writeValue` from main.zig or reimplement in nrepl module
- Single-threaded eval with mutex (same as Beta)
- No Allocators abstraction — use arena per request + GPA for persistent data

## Plan (TDD)

1. Red: test UUID generation
2. Green: implement generateUUID
3. Red: test sendBencode helper (encode dict + write to buffer)
4. Green: implement sendBencode, sendDone, sendError, idEntry, sessionEntry, statusDone
5. Red: test opClone (session creation)
6. Green: implement ServerState + opClone
7. Red: test opDescribe (server info response)
8. Green: implement opDescribe
9. Red: test opEval (simple expression evaluation)
10. Green: implement opEval with output capture + multi-form
11. Red: test opCompletions (prefix matching)
12. Green: implement opCompletions + collectCompletions
13. Red: test opInfo (symbol lookup)
14. Green: implement opInfo + resolveSymbol
15. Integrate: CLI --nrepl-server flag, startServer, messageLoop, dispatchOp
16. Wire remaining ops: close, load-file, ls-sessions, eldoc, ns-list
17. Integration test: start server, send bencode via TCP, verify response

## Log

### Session 1

1. Red: UUID generation test — PASS (test fails without impl)
2. Green: generateUUID using std.crypto.random — PASS
3. Red: helper tests (idEntry, sessionEntry, statusDone) — PASS
4. Green: sendBencode, sendDone, sendError helpers — PASS
5. Green: Full ServerState + all 11 ops implemented (clone, close, describe,
   eval, load-file, ls-sessions, completions, info, eldoc, ns-list)
6. Green: TCP integration test (describe op via localhost) — PASS
7. Integrated: CLI --nrepl-server and --port= flags in main.zig
8. Integration tested with clj-nrepl-eval:
   - `(+ 1 2)` → 3 ✓
   - `(def x 42)` + `x` → 42 ✓ (after segfault fix: copy code to eval_arena)
   - `(defn square [n] (* n n))` + `(square 5)` → 25 ✓
   - Multi-form `(def a 10) (def b 20) (+ a b)` → 30 ✓
   - `(println "hello world")` → output captured ✓
   - `(into [] (range 5))` → [0 1 2 3 4] ✓
   - `(let [x 10 y 20] (+ x y))` → 30 ✓

### Design Decision: D29

Code string from bencode decode arena must be copied to eval_arena before
passing to evalString. The decode arena is freed after each message, but
evalString may intern symbols/vars referencing the source string.
