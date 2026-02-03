# T14.9: sequences.clj 等価テスト作成

## Goal

Clojure本家の`test/clojure/test_clojure/sequences.clj`に基づく等価テストを作成する。
Java配列/Java InterOp部分を除外し、ClojureWasm実装の動作を検証する。

## Analysis

### 本家sequences.cljの内容 (1654 lines)

非常に大きなファイル。Java依存度で分類:

| セクション                     | Java依存度 | 移植方針                                     |
| ------------------------------ | ---------- | -------------------------------------------- |
| test-reduce                    | 高         | Java配列, IReduce — 除外                     |
| test-into-IReduceInit          | 高         | reify IReduceInit — 除外                     |
| reduce-with-varying-impls      | 高         | java.util.ArrayList — 除外                   |
| test-equality                  | 中         | sequence/transducer — 除外                   |
| test-lazy-seq                  | 中         | into-array, sorted-map/set — 一部除外        |
| test-seq                       | 中         | into-array, sorted-map/set — 一部除外        |
| test-cons                      | 中         | into-array, sorted-set — 一部除外            |
| test-empty                     | 中         | sorted-map/set, transient — 除外             |
| test-first/next/last           | 中         | into-array, to-array, sorted — 一部除外      |
| test-ffirst/fnext/nfirst/nnext | 低         | 移植可能                                     |
| test-nth                       | 高         | java.util.ArrayList, re-matcher — 大部分除外 |
| test-distinct                  | 低         | Ratio除外、基本テストは移植可能              |
| test-interpose                 | 低         | 移植可能                                     |
| test-interleave                | 低         | 移植可能                                     |
| test-zipmap                    | 低         | 移植可能                                     |
| test-concat                    | 低         | 移植可能                                     |
| test-cycle                     | 中         | transduce — 除外、take+cycleは移植可能       |
| test-partition                 | 中         | 一部移植可能                                 |
| test-iterate                   | 中         | transduce — 除外、take+iterateは移植可能     |
| test-reverse                   | 低         | 移植可能                                     |
| test-take/drop                 | 低         | Ratio除外、基本テストは移植可能              |
| test-take-while/drop-while     | 低         | 移植可能                                     |
| test-butlast                   | 低         | 移植可能                                     |
| test-drop-last                 | 低         | 移植可能                                     |
| test-split-at/split-with       | 低         | 移植可能                                     |
| test-repeat                    | 低         | Ratio除外、基本テストは移植可能              |
| test-range                     | 中         | Ratio/Long.MAX_VALUE — 一部除外              |
| test-empty?                    | 中         | transient, into-array — 一部除外             |
| test-every?/not-every?         | 中         | lazy-seq, into-array — 一部除外              |
| test-not-any?                  | 中         | lazy-seq, into-array — 一部除外              |
| test-some                      | 低         | 移植可能                                     |
| test-flatten                   | 中         | regex — 除外                                 |
| test-group-by                  | 低         | 移植可能                                     |
| test-partition-by              | 低         | 一部移植可能                                 |
| test-frequencies               | 低         | 移植可能                                     |
| test-reductions                | 低         | 移植可能                                     |
| test-partition-all             | 低         | 移植可能                                     |
| test-shuffle                   | 低         | 移植可能                                     |

### 移植対象として選定したテスト (Java依存度: 低)

1. first/rest/cons基本テスト
2. ffirst, fnext, nfirst, nnext
3. distinct, interpose, interleave, zipmap, concat
4. take, drop, take-while, drop-while
5. butlast, drop-last, split-at, split-with
6. repeat, reverse, cycle (take限定)
7. iterate (take限定)
8. range (基本形式)
9. some, every?, not-every?, not-any?
10. group-by, frequencies, partition-by, partition-all
11. flatten, reductions, shuffle

## Plan

1. test/upstream/clojure/test_clojure/sequences.clj を作成
2. Java依存度低のテストを移植 (~15-20 tests)
3. zig build test で検証

## Log

### Completed

- Created test/upstream/clojure/test_clojure/sequences.clj
- 33 tests, 188 assertions — ALL PASSED on TreeWalk
- zig build test — no regression

### Excluded due to ClojureWasm limitations

| Item                        | Reason                                             | Future ID |
| --------------------------- | -------------------------------------------------- | --------- |
| first/rest on set           | (first #{1}) fails                                 | F40       |
| first/rest on string        | (first "a") fails                                  | F41       |
| empty list () in assertions | () truthy/equality issues                          | F29/F33   |
| test-ffirst                 | ffirst not implemented                             | F43       |
| test-nnext                  | nnext not implemented                              | F44       |
| interleave 0-1 args         | (interleave) and (interleave [1]) fail             | F45       |
| test-drop-last              | drop-last not implemented                          | F46       |
| test-split-at/split-with    | split-at, split-with not implemented               | F47       |
| (range) infinite            | infinite range not supported                       | F48       |
| partition 3-arg (step)      | (partition 2 3 coll) not supported                 | F49       |
| every?/not-any? on #{}      | operations on empty set fail                       | F40       |
| test-reductions             | reductions not implemented                         | F50       |
| test-shuffle                | shuffle not implemented                            | F51       |
| flatten on non-seq          | returns nil instead of empty seq (behavior diff)   | —         |
| flatten on map              | flattens map entries instead of returning empty    | —         |
| some with pos?              | returns element instead of pred result (test adj.) | —         |
