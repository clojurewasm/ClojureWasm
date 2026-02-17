# ClojureWasm Development Memo

Session handover document. Read at session start.

## Note: zwasm v1.0.0 API Change (APPLIED)

zwasm `loadWasi()` default changed to `Capabilities.cli_default`.
CW updated to use `loadWasiWithOptions(..., .{ .caps = .all })` in `src/wasm/types.zig:82`.

## Current State

- **All phases through 76 COMPLETE** (Type System & Reader Enhancements)
- Coverage: 880+ vars (651/706 core, 10/11 protocols, 22/22 reducers, 25 embedded CLJ namespaces)
- Wasm engine: zwasm v1.0.0 (GitHub URL dependency, build.zig.zon).
- Bridge: `src/wasm/types.zig` (751 lines, thin wrapper over zwasm)
- 52 upstream test files, all passing. 6/6 e2e tests pass. 14/14 deps e2e pass.
- Benchmarks: `bench/history.yaml` (v1.0.0 entry = latest baseline)
- Binary: 4.07MB ReleaseSafe (Mac ARM64). See `.dev/binary-size-audit.md`.
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
Sub-phase 77.10: Skip recovery (per-var, beep-and-ask)

## Previous Task

77.6: spec.gen.alpha completion — 27 TODO vars done. All generators (int, double, char, string,
keyword, symbol, boolean, uuid, ratio, large-integer, any, simple-type, etc.) now functional.
Also fixed: analyzer vector literal bug (makeBuiltinCall now qualifies to clojure.core),
char builtin returns char type not string. Binary: 4.07MB.

## Task Queue

```
77.10 Skip recovery (per-var, beep-and-ask) ← CURRENT
skip recorvery にくわえて、以下が解消されているかも確認。その場で判断というより、コードベースの実態をチェックしてから進める
(0) status: todoが0件かどうか
(1) 本家テストポート
(2) CLJW:
(3) UPSTREAM-DIFF:
(4) 各種ベンチマーク・バイナリサイズが許容範囲内
(5) stub実装が残ってないか
(6) . や ..などのメソッドコール, URI. などインスタンス機能の対応範囲を確認(要するにpanicになるのだけは避けたく、特定のClass以外は未対応的なユーザーへの親切メッセージが欲しい)
現時点で確認すると、すでに実装済みのものがあったりするはずなのでそちらを使って解消できるものもあるはず
(7) また、zig run test, run_e2e.sh, run_deps_e2e.shも確実にとおす(/tmpにテスト残骸のこってそう。参考になる？)
(8) かなり色々と機能が追加されたのでベンチマークに不足がないかチェックして、必要に応じて有用なベンチマークを他言語もアルゴリズム等価で用意して比較に加える
(9) それでもskipとして残ったものについては、noteが確実に書かれているか
(10) ドキュメント群のvars言及箇所を最新化
```

## Known Issues

- F140: GC crash in dissocFn (keyword pointer freed under heavy allocation pressure)
- F139: case macro fails with mixed body types (shift-mask error)

## Next Phase Queue

After Phase 77 completes, proceed to Phase 78 (Bug Fixes & Correctness).
Read `.dev/roadmap.md` Phase 78 section for sub-tasks.

```
78.1 Fix F140: GC crash in dissocFn
78.2 Fix F139: case macro with mixed body types
78.3 F94 upstream alignment pass (87 markers in src/clj/)
78.4 Audit unreachable in production paths
```

## Notes

- CONTRIBUTING.md at `.dev/CONTRIBUTING.md` — restore to repo root when accepting contributions
- Batch 0 = clojure.jar-bundled → embed in CW, UPSTREAM-DIFF/CLJW markers OK
- Batch 1+ = external libraries → test as-is, fix CW side, do NOT fork
- Batch 1 (medley, CSK, honeysql) already tested correctly with as-is approach
- clojure.xml now implemented (pure Clojure XML parser, 13/13 tests pass)
