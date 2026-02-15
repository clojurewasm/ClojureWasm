# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 76 COMPLETE** (Type System & Reader Enhancements)
- Coverage: 871+ vars (637/706 core, 10/11 protocols, 22/22 reducers, 25 embedded CLJ namespaces)
- Wasm engine: zwasm v0.2.0 (GitHub URL dependency, build.zig.zon).
- Bridge: `src/wasm/types.zig` (751 lines, thin wrapper over zwasm)
- 52 upstream test files, all passing. 6/6 e2e tests pass. 14/14 deps e2e pass.
- Benchmarks: `bench/history.yaml` (v0.2.0 entry = latest baseline)
- Binary: 4.00MB ReleaseSafe (Mac ARM64). See `.dev/binary-size-audit.md`.
- Java interop: `src/interop/` module with URI, File, UUID, PushbackReader, StringBuilder, StringWriter, BufferedWriter classes (D101)

## Strategic Direction

Native production-grade Clojure runtime. **NOT a JVM reimplementation.**
CW embodies "you don't really want Java interop" — minimal shims for high-frequency
patterns only. Libraries requiring heavy Java interop are out of scope.

Differentiation vs Babashka:
- Ultra-fast execution (19/20 benchmark wins)
- Tiny single binary (3.85MB macOS, ~14MB Linux static)
- Wasm FFI (unique: call .wasm modules from Clojure)
- deps.edn compatible project model (Clojure CLI subset)

Java interop policy: Library-driven. Test real libraries as-is (no forking/embedding).
When behavior differs from upstream Clojure, trace CW's processing pipeline to find
and fix the root cause. Add Java interop shims only when 3+ libraries need the same
pattern AND it's <100 lines of Zig. If a library requires heavy Java interop that
CW won't implement, that library is out of scope — document and move on.
See `.dev/library-port-targets.md` for targets and decision guide.

## Current Task

Phase 77: Var Coverage Completion
Sub-phase 77.3: STM/Ref system (9 vars)

## Previous Task

77.7: clojure.java.io completion — 12 vars done. Created io.clj with Coercions/IOFactory
protocols, BufferedWriter interop class, PushbackReader .readLine/.ready methods. Fixed
close() to dispatch .close via __java-method. Fixed serializer to walk collections for
FnProto collection. Binary: 4.02MB.

## Task Queue

```
77.3 STM/Ref system (9 vars) ← CURRENT
77.6 test.check + spec.gen.alpha (27 vars)
77.10 Skip recovery (per-var, beep-and-ask)
skip recorvery にくわえて、以下が解消されているかも確認。その場で判断というより、コードベースの実態をチェックしてから進める
(0) status: todoが0件かどうか
(1) 本家テストポート
(2) CLJW:
(3) UPSTREAM-DIFF:
(4) 各種ベンチマーク・バイナリサイズが許容範囲内
(5) stub実装が残ってないか
(6) . や ..などのメソッドコール機能の対応範囲を確認(要するにpanicになるのだけは避けたく、特定のClass以外は未対応的なユーザーへの親切メッセージが欲しい)
現時点で確認すると、すでに実装済みのものがあったりするはずなのでそちらを使って解消できるものもあるはず
また、zig run test, run_e2e.sh, run_deps_e2e.shも確実にとおす
判断必要な場合は、afplay /System/Library/Sounds/Funk.aiff をならして、止める
```

## Known Issues

(none currently)

## Notes

- CONTRIBUTING.md at `.dev/CONTRIBUTING.md` — restore to repo root when accepting contributions
- Batch 0 = clojure.jar-bundled → embed in CW, UPSTREAM-DIFF/CLJW markers OK
- Batch 1+ = external libraries → test as-is, fix CW side, do NOT fork
- Batch 1 (medley, CSK, honeysql) already tested correctly with as-is approach
- clojure.xml now implemented (pure Clojure XML parser, 13/13 tests pass)
