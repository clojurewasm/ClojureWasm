# Phase 30: Production Robustness

## Goal

Make ClojureWasm usable for real projects. Four pillars:
error quality, project model, editor integration, var coverage.

## Sub-phases

### Phase 30.1: Error Reporting (Babashka-quality)

Current state: error.zig has Kind/Phase/SourceLocation, but no call stack
tracking, no source context display, no structured ex-data.

| Task  | Description                                              |
|-------|----------------------------------------------------------|
| 30.1a | Call stack tracking — capture fn name + location per frame |
| 30.1b | Source context display — show 3 lines around error location |
| 30.1c | Throwable->map + ex-data — structured error data for nREPL |
| 30.1d | REPL error formatting — Babashka-style colored output     |

**Design: Call stack tracking (30.1a)**

Add a threadlocal call stack to error.zig:

```zig
const StackFrame = struct {
    fn_name: ?[]const u8 = null,
    file: ?[]const u8 = null,
    line: u32 = 0,
    column: u32 = 0,
};

threadlocal var call_stack: [64]StackFrame = @splat(StackFrame{});
threadlocal var stack_depth: u8 = 0;

pub fn pushFrame(frame: StackFrame) void { ... }
pub fn popFrame() void { ... }
pub fn getCallStack() []const StackFrame { ... }
```

Push/pop in VM `performCall()` and TreeWalk `evalFnCall()`.
Bootstrap functions (core.clj) get fn name from Var metadata.

**Design: Source context (30.1b)**

When error has location and source text is cached (REPL/-e/file mode),
display surrounding lines:

```
ArityError in user/foo (foo.clj:12:5)
  10 | (defn foo [a b]
  11 |   (let [c (+ a b)]
> 12 |     (bar c d e)))
  13 |
Wrong number of args (3) passed to user/bar, expected 2
```

**Design: Throwable->map (30.1c)**

```clojure
(try (/ 1 0)
  (catch Exception e
    (Throwable->map e)))
;=> {:cause "Divide by zero"
;    :data {:type :ArithmeticError :phase :eval}
;    :trace [{:fn "user/foo" :file "foo.clj" :line 12} ...]}
```

### Phase 30.2: nREPL/CIDER Compatibility

Current: 14 ops implemented. CIDER needs stacktrace + info extension.

| Task  | Description                                              |
|-------|----------------------------------------------------------|
| 30.2a | stacktrace op — return call stack on error (needs 30.1)  |
| 30.2b | info extension — add :file, :line, :column to var info   |
| 30.2c | Test with CIDER — end-to-end CIDER connection test       |

**stacktrace op format** (CIDER protocol):

```bencode
{"op": "stacktrace", "session": "..."}
=>
{"stacktrace": [
  {"name": "foo", "file": "foo.clj", "line": 12, "ns": "user", "type": "clj"},
  ...
]}
```

**info extension**: Vars need `:file` and `:line` metadata from their
definition site. Reader already tracks SourceLocation — propagate to
Var metadata during `def`/`defn` analysis.

### Phase 30.3: Zero-config Project Model

Enable multi-file projects without build tool setup.

| Task  | Description                                              |
|-------|----------------------------------------------------------|
| 30.3a | require file resolution — require ns -> find .clj file   |
| 30.3b | src/ path auto-detect — walk up from entry file to find src/ |
| 30.3c | cljw.edn support — {:paths ["src"] :main my-app.core}   |

**Design: require file resolution (30.3a)**

```
(require 'my-app.util)
;; Search order:
;; 1. Already loaded namespace -> skip
;; 2. cljw.edn :paths entries -> src/my_app/util.clj
;; 3. Relative to entry file -> ./my_app/util.clj
;; 4. Current working directory -> my_app/util.clj
```

Namespace `my-app.util` maps to path `my_app/util.clj`
(dots -> path separators, hyphens -> underscores).

**Design: cljw.edn (30.3c)**

```edn
;; Optional. If absent, defaults to {:paths ["."] :main nil}
{:paths ["src" "resources"]
 :main my-app.core}
```

`cljw run` with no args: read cljw.edn, evaluate `:main` namespace.
`cljw build -o app`: embed source from `:paths`, entry from `:main`.

### Phase 30.4: Skip Var Recovery

Re-evaluate 178 skipped vars. Focus on high-value recoverable ones.

Research summary (from vars.yaml analysis):
- 72 truly JVM-only (class system, arrays, STM, agents) — keep skip
- 106 potentially recoverable — prioritize by user impact

| Task  | Description                                              |
|-------|----------------------------------------------------------|
| 30.4a | letfn implementation — mutual recursion support          |
| 30.4b | with-open macro — resource cleanup (try/finally)         |
| 30.4c | tagged-literal + reader-conditional — EDN portability    |
| 30.4d | with-local-vars + with-in-str — macro completeness       |
| 30.4e | Remaining type predicates — bytes?, uri?, uuid?          |

**Priority rationale**: letfn and with-open are used in real Clojure code.
tagged-literal/reader-conditional enable portable .cljc files.
Agent/future/pmap are Phase 31+ (need multi-threading, deferred to F6).

## Task Queue (execution order)

1. 30.1a — Call stack tracking
2. 30.1b — Source context display
3. 30.1c — Throwable->map + ex-data
4. 30.1d — REPL error formatting
5. 30.2a — nREPL stacktrace op
6. 30.2b — nREPL info extension (:file, :line)
7. 30.2c — CIDER end-to-end test
8. 30.3a — require file resolution
9. 30.3b — src/ path auto-detect
10. 30.3c — cljw.edn support
11. 30.4a — letfn implementation
12. 30.4b — with-open macro
13. 30.4c — tagged-literal + reader-conditional
14. 30.4d — with-local-vars + with-in-str
15. 30.4e — Remaining type predicates

## Dependencies

- 30.2a depends on 30.1a (stack frames needed for stacktrace op)
- 30.2b depends on 30.1c (var metadata propagation)
- 30.3c builds on 30.3a + 30.3b

## Success Criteria

- [ ] Errors show file:line and 3-line source context
- [ ] Throwable->map returns structured error data
- [ ] CIDER connects, evaluates, and shows stack traces
- [ ] `require` resolves namespaces from src/ directory
- [ ] cljw.edn configures project paths
- [ ] letfn, with-open, tagged-literal work in both backends
- [ ] All tests pass after every commit

## Skipped Var Categories (for reference)

### True JVM-only (72 vars — keep skip)

Java arrays (16): aclone, aget, alength, amap, areduce, aset, *-array, etc.
Class system (17): deftype*, gen-class, proxy, reify, bases, bean, etc.
STM/Agents (9): ref, dosync, commute, alter, monitor-enter/exit, etc.
Java interop (30): import, .., memfn, send, send-off, etc.

### Deferred recoverable (remaining ~85 vars)

Threading (15): agent, future, send, pmap — needs F6 (multi-thread)
I/O extensions (12): stream-*, load-reader, line-seq — low priority
Dynamic var stubs (8): *agent*, *compile-path*, etc. — trivial but low value
Deprecated (5): struct system — Clojure 1.3+ deprecated
Internal (7): case*, destructure, etc. — compiler handles

## References

- `.dev/future.md` SS20 — Error classification (D3b)
- `.dev/future.md` SS21 — Developer experience gap
- `src/common/error.zig` — Current error infrastructure
- `src/repl/nrepl.zig` — Current nREPL implementation
- `.dev/checklist.md` F107-F109 — Related checklist items
