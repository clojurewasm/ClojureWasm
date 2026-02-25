# Changelog

## v0.4.0 (2026-02-25)

### Architecture
- 4-zone layered architecture (D109): runtime → engine → lang → app
- Zone dependencies enforced by CI gate (0 violations, down from 126)
- Vtable pattern for dependency inversion (runtime/dispatch.zig)
- HAMT (Hash Array Mapped Trie) for persistent hash maps with collision nodes

### Coverage
- 1,130/1,243 vars implemented (90.9%), 651/706 clojure.core (92.2%)
- clojure.pprint: 26/26 (was 22/26), full cl-format support
- clojure.spec.alpha: 87/87, clojure.spec.gen.alpha: 54/54
- clojure.core.reducers: 22/22, clojure.datafy: 2/2, clojure.instant: 3/5

### Testing
- 83 Clojure test namespaces (68 upstream ports), all passing
- Full Mac/Linux test symmetry (macOS aarch64 + Linux x86_64)
- 6 e2e tests, 14 deps.edn e2e tests

### Bug Fixes
- HAMT crash when function values used as map keys (>8 entries promote to HashMap)
- Identity hash (splitmix64) for function types replacing constant hash
- HAMT collision node support for full 32-bit hash collisions

### Performance
- Binary: 4.76MB (ReleaseSafe)
- Startup: ~4ms
- RSS: ~7.6MB

### CI
- Cross-platform CI: macOS 14 + Ubuntu 24.04 + 4 cross-compile targets
- Benchmark smoke tests with portable timeout (perl alarm)

## v0.3.0 (2026-02-20)

### Architecture v2
- Exception system unification: `Exception.` returns maps with hierarchy and `.getMessage`
- ClassDef registry for unified interop dispatch (protocol-based)
- UTF-8 codepoint correctness for all string operations
- Handle memory safety with use-after-close detection
- Scope-reduced All-Zig migration: hybrid architecture (Zig primitives + .clj composition) confirmed optimal

### Crash Hardening
- Coverage-guided fuzzing harnesses for Reader, Analyzer, Compiler, and VM
- Structure-aware Clojure form generator for fuzzing
- Differential testing harness (CW vs JVM Clojure): 146 static + 100 random expressions
- Resource limits for format, str, and analyzer depth
- Internal error audit and panic removal
- Vulnerability audit with VM hardening

### Error System
- Layered error catalog (docs/errors.md)
- Improved class/method error messages with suggestions

### Testing
- 63 upstream test files (62/63 passing)
- 13 CW-specific test files (exceptions, sorted collections, threading, destructuring, etc.)
- Reader round-trip, stability, REPL output, and GC stress tests
- Differential testing expanded to 146 expressions

### Library Compatibility
- `cljw.io`, `cljw.shell`, `cljw.browse`, `cljw.process` namespace aliases
- Library compatibility matrix: medley (82.5%), clojure.walk (100%), clojure.set (100%), data.csv (100%)

### Developer Experience
- `cljw new <name>`: project scaffolding with deps.edn, src/, test/
- nREPL macroexpand op (supports macroexpand, macroexpand-1, macroexpand-all)
- REPL namespace-qualified tab completion (e.g., `str/tri<TAB>`)
- REPL special commands: `:quit`, `:help`
- Fixed nREPL cons cell rendering (sequences, not dotted pairs)
- Fixed nREPL server shutdown panic

### CI/CD
- GitHub Actions CI/CD foundation

### Bug Fixes
- def/defn now returns var (Clojure compatibility)
- macroexpand-1 qualified names
- apply variadic dispatch
- list* with cons/lazy-seq tails
- Lazy-seq display uses formatPrStr

## v0.2.0 (2026-02-13)

Initial public release with zwasm v1.1.0 integration.

## v0.1.0 (2026-02-13)

First tagged release.
