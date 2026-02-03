# T14.8: atoms.clj 等価テスト作成

## Goal

Clojure本家の`test/clojure/test_clojure/atoms.clj`に基づく等価テストを作成する。
Java依存部分を除外し、ClojureWasm実装の動作を検証する。

## Analysis

### 本家atoms.cljの内容 (64 lines)

| テスト名                      | Java依存度 | 移植方針                                |
| ----------------------------- | ---------- | --------------------------------------- |
| swap-vals-returns-old-value   | 低         | swap-vals!未実装 → 除外 (F38)           |
| deref-swap-arities            | 低         | swap-vals!未実装 → 除外 (F38)           |
| deref-reset-returns-old-value | 低         | reset-vals!未実装 → 除外 (F39)          |
| reset-on-deref-reset-equality | 低         | reset-vals!未実装 → 除外 (F39)          |
| atoms-are-suppliers           | 高         | java.util.function.\* → 除外 (Java固有) |

### ClojureWasmの実装状況

- `atom` — done (Zig builtin)
- `deref` — done (Zig builtin)
- `swap!` — done (Zig builtin, builtin-fn only)
- `reset!` — done (Zig builtin)
- `compare-and-set!` — done (Zig builtin, misc.zig)
- `swap-vals!` — todo
- `reset-vals!` — todo

### 作成するテスト

本家のテストはすべてswap-vals!/reset-vals!/Java依存なので、ClojureWasm固有のatom
テストを作成する:

1. atom creation and deref
2. swap! with various functions
3. reset! behavior
4. compare-and-set! success/failure
5. atom with collection values
6. nested swap! operations

## Plan

1. test/upstream/clojure/test_clojure/atoms.clj を作成
2. 基本的なatom操作テスト作成 (6-8 tests)
3. zig build test で検証
4. vars.yaml の compare-and-set! ステータスを done に更新

## Log

- Created test/upstream/clojure/test_clojure/atoms.clj
- 14 tests, 39 assertions covering:
  - atom creation with various types
  - deref / @
  - swap! (basic, return value, with args, with collections)
  - reset! (basic, return value)
  - compare-and-set! (success, failure, with nil)
  - nested atom operations
- All tests pass on TreeWalk
- VM has pre-existing issue (not atom-specific)
- Updated vars.yaml: compare-and-set! todo -> done
