# Missing clojure.jar Namespaces

Reference for Phase 75 Batch 0. These are namespaces bundled in upstream `clojure.jar`
that CW does not yet provide. Since they are clojure.jar-bundled, they should be
**embedded** in CW (via `@embedFile` or Zig builtin), with UPSTREAM-DIFF/CLJW markers
where CW adaptation is needed.

## Embed Rule

- clojure.jar-bundled namespace → embed in CW (`@embedFile` or Zig builtin)
- Separate Maven artifact (org.clojure/data.json etc.) → external (deps.edn)

## Implementation Targets

### Small (1 task each)

#### clojure.uuid (20 lines)
- `#uuid` data reader + `print-method` for UUID type
- CW already has UUID type (`random-uuid`, `uuid?`, `parse-uuid`)
- Upstream uses `java.util.UUID/fromString` → replace with CW's `parse-uuid`
- Upstream `print-method java.util.UUID` → CW's print dispatch for UUID type
- **Action**: Verify CW already covers this, add `clojure.uuid` ns if needed

#### clojure.test.tap (123 lines)
- TAP (Test Anything Protocol) output formatter for clojure.test
- Nearly pure Clojure: only Java dep is `.split` (1 call)
- Uses: `clojure.test` (report multimethods), `clojure.stacktrace`
- `.split` → `clojure.string/split` replacement
- `instance? Throwable` → `instance? Exception`
- **Action**: Port with minimal CLJW markers

#### clojure.java.browse (89 lines)
- `browse-url` — open URL in default system browser
- Core: calls `open` (macOS) or `xdg-open` (Linux) via shell
- CW has `clojure.java.shell/sh` already
- Java Desktop API fallback → skip (CW doesn't have AWT)
- Swing fallback (`browse-ui`) → skip
- `System/getProperty "os.name"` → CW equivalent
- ProcessBuilder → Zig `std.process` equivalent
- **Action**: Port, shell-based path only, skip AWT/Swing fallbacks

#### clojure.datafy (62 lines)
- `datafy` and `nav` — protocols for turning objects into navigable data
- Depends on `clojure.core.protocols` (already in CW)
- `clojure.lang.IObj` → CW metadata check
- `clojure.lang.IRef` → CW atom/ref check
- `clojure.lang.Namespace` → CW namespace operations
- `java.lang.Class` extend → skip (uses clojure.reflect)
- **Action**: Port core datafy/nav, skip Class extension, CLJW markers

### Medium (2-3 tasks each)

#### clojure.instant (294 lines)
- `#inst` reader tag + RFC3339 date/time parser + print methods
- Parser part (`parse-timestamp`, `validated`, helpers) = **pure Clojure** (~120 lines)
- Constructor part (construct-date/calendar/timestamp) = Java Calendar/Date/Timestamp
- Print part = Java SimpleDateFormat, ThreadLocal, proxy
- CW approach: Keep pure Clojure parser. Replace Java date types with Zig
  `std.time`-based implementation. Drop ThreadLocal/proxy (not needed in CW).
- Key deliverable: `#inst "2024-01-15T10:30:00Z"` works as data reader
- **Action**: Pure Clojure parser + Zig date type. Multi-task.

#### clojure.java.process (196 lines)
- Process invocation API: `start`, `exec`, `stdin`, `stdout`, `stderr`, `exit-ref`
- More flexible than `clojure.java.shell/sh` (async, stream control, env vars)
- ProcessBuilder → Zig `std.process.Child`
- reify IDeref/IBlockingDeref for `exit-ref` → CW deref protocol
- ThreadFactory/ExecutorService for `io-task` → simplify for CW
- Clojure 1.12 addition — forward-looking
- **Action**: Zig builtin process API + Clojure wrapper. Multi-task.

### Large (phase-level, plan separately)

#### clojure.main (676 lines)
- Top-level REPL, script loading, error reporting
- Heavy Java deps: Compiler, RT, LineNumberingPushbackReader
- CW already has equivalent Zig-side functionality for most of this
- Useful functions: `repl`, `load-script`, `with-bindings`, `repl-exception`
- **Action**: Create CW equivalent ns. Map CW's existing REPL/script features
  into this namespace for API compatibility. Does NOT need to port upstream
  verbatim — CW-native implementation wrapping existing functionality.

#### clojure.core.server (341 lines)
- Socket REPL server + prepl (structured REPL for tooling)
- ServerSocket, Thread, ReentrantLock, LineNumberingPushbackReader
- CW has `cljw.http` (HTTP server) but socket REPL is different concept
- prepl is valuable for tooling integration (structured eval results)
- Zig `std.net.Stream` for socket server, `std.Thread` for connections
- Depends on `clojure.main` (for repl-init, with-bindings, etc.)
- **Action**: Zig socket server + Clojure-side prepl. After clojure.main.

#### clojure.repl.deps (97 lines)
- Dynamic library addition at REPL (`add-lib`, `sync-deps`)
- Upstream: DynamicClassLoader + tools.deps.interop (pure JVM)
- CW opportunity: CW has deps.edn resolver. Could implement CW-native version
  that resolves → downloads → loads via CW's `requireLib` mechanism.
- Not a port — a CW-native reimplementation of the concept
- **Action**: Design CW-native REPL deps. After deps.edn stabilization.

#### clojure.xml
- XML parsing via SAXParser (Java)
- No Zig stdlib XML parser. Would need pure Zig XML parser or pure Clojure parser.
- Scope is significant. Low priority unless a tested library needs it.
- **Action**: Defer. Implement only if library testing surfaces demand.

### Skip (not implementing)

| namespace | Reason |
|---|---|
| clojure.reflect | 100% Java reflection API, no CW equivalent |
| clojure.inspector | 100% Swing GUI, no value without GUI |
| clojure.java.javadoc | Opens Javadoc URLs, irrelevant to CW |
| clojure.test.junit | JUnit XML output, JVM testing infra |

## Task Order

Small items first (quick wins, unblock testing), then medium, then large:

```
0a  clojure.uuid — verify/complete UUID ns coverage
0b  clojure.test.tap — TAP output formatter
0c  clojure.java.browse — browse-url (shell-based)
0d  clojure.datafy — datafy/nav protocols
0e  clojure.instant — #inst reader + date type (multi-task)
0f  clojure.java.process — process API (multi-task)
0g  clojure.main — CW-native main ns (large)
0h  clojure.core.server — socket REPL + prepl (large, after 0g)
0i  clojure.repl.deps — REPL deps (large, after deps.edn stable)
```

clojure.xml deferred until library testing surfaces demand.
