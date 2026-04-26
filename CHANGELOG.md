# Changelog

## v0.5.0 (2026-04-27)

### Toolchain
- Migrate from Zig 0.15.2 to Zig 0.16.0 (D111). All `std.Io` reshapes
  centralized behind `runtime/io_default.zig`: process-wide io accessor
  populated by `main(init: std.process.Init)` from `init.io` /
  `init.environ_map`, with helper wrappers (`lockMutex`, `unlockMutex`,
  `condWait`, `condTimedWait`, `condSignal`, `condBroadcast`, `sleep`,
  `getEnv`, `nanoTimestamp`, `milliTimestamp`) so existing module-level
  mutexes, time helpers, env lookups, and sleeps don't have to thread
  `io` through every call site.
- Bump zwasm dependency from v1.9.1 to v1.11.0 (first 0.16-compatible
  tag). The wasm bridge in `src/runtime/wasm_types.zig` migrates inline
  with the rest of the codebase; all six wasm e2e tests stay green.
- `flake.nix` pin moved from 0.15.2 to 0.16.0; `build.zig.zon`
  `minimum_zig_version = "0.16.0"`; `.github/workflows/{ci,nightly,release}.yml`
  setup-zig version pin → 0.16.0.
- `link_libc = true` is enabled (inherited from zwasm v1.11.0). Several
  std stdlib removals (`std.posix.{getenv,write,isatty,mprotect}`,
  `std.fs.cwd().realpath`) are bridged to libc via `std.c.*` for now;
  stripping libc back out is tracked as F146.
- `-Dwasm` build option (default true) was confirmed working under 0.16;
  the `--no-wasm` flag in `bash test/run_all.sh` / `test/e2e/run_e2e.sh`
  / `bench/run_bench.sh` / `bench/wasm_bench.sh` propagates it through
  test/bench harnesses.

### Migration test gate
- 1324 / 1324 unit tests (`zig build test`) — green
- 83 / 83 namespaces in `cljw test` — green
- 6 / 6 wasm e2e tests + deps.edn e2e — green
- `bench/history.yaml` records `pre-zig-016` and `post-zig-016` entries;
  no individual benchmark regressed beyond noise (`lazy_chain` actually
  improved).

### Performance (post-migration ReleaseSafe, macOS aarch64)
- Binary: 4.12 MB (smaller than 0.15.2 because four features below are
  temporarily stubbed; expect ~+300-500 KB once they are restored).
- Startup: 4.1 ms
- RSS: 8.2 MB

### Temporarily disabled, tracked as Phase 7 follow-ups
The 0.16 stdlib reshapes are large enough that four features were
collapsed to runtime-error stubs to land the migration cleanly. Each
returns a clear error message and is preserved either in source or in
git history.
- `cljw.http/run-server` (Ring-compatible HTTP server) — F140
- `cljw.http/get|post|put|delete` (HTTP client built on `std.http.Client`) — F141
- `--nrepl-server` (CIDER-compatible nREPL with bencode dispatch and
  14 ops) — F142
- Raw-mode line editor (Emacs keybindings, history, multiline) — F143
- `cljw build` standalone-binary self-bundling — F144
- OrbStack Ubuntu re-validation under 0.16 — F145
- Strip `link_libc = true` once `std.Io` and the `std.c.*` shims have
  pure-Zig replacements — F146

### `|_|` switch capture syntax
- Two switch prongs (`analyzer.zig`, `node.zig`) updated for Zig 0.16's
  rule that switch arms which don't actually use the capture must omit
  the `|...|` clause entirely.

### Misc renames
- `std.mem.{trimLeft,trimRight}` → `std.mem.{trimStart,trimEnd}`
- `std.process.Child.run(.{...})` → `std.process.run(allocator, io, .{...})`
- `std.process.Child.Term` variants are now lowercase
  (`.exited`/`.signal`/`.stopped`/`.unknown`) and signal/stopped carry
  `std.posix.SIG` instead of raw integers.
- `std.testing.fuzz`'s `testOne` now takes `*std.testing.Smith`
  instead of `[]const u8`.

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
