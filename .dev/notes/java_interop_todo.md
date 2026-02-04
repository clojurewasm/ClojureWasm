# ClojureWasm Java Interop 実装リスト

議論結果に基づき、実装項目を整理。Done/Todo両方を記載。

---

## Priority 1: Beta実績あり・高価値

### 階層システム (Hierarchy)

| Var              | Status | Note                     |
| ---------------- | ------ | ------------------------ |
| `make-hierarchy` | todo   | Zig builtin              |
| `derive`         | todo   | Zig builtin              |
| `underive`       | todo   | Zig builtin              |
| `parents`        | todo   | Zig builtin              |
| `ancestors`      | todo   | Zig builtin              |
| `descendants`    | todo   | Zig builtin              |
| `isa?`           | done   | → フル版にアップグレード |

### マルチメソッド

| Var                  | Status | Note            |
| -------------------- | ------ | --------------- |
| `defmulti`           | done   | TreeWalk実装    |
| `defmethod`          | done   | TreeWalk実装    |
| `get-method`         | todo   | Zig builtin     |
| `methods`            | todo   | Zig builtin     |
| `remove-method`      | todo   | Zig builtin     |
| `remove-all-methods` | todo   | Zig builtin     |
| `prefer-method`      | todo   | Zig builtin     |
| `prefers`            | todo   | Zig builtin     |
| `dispatch-fn`        | todo   | vars.yaml未登録 |
| `hierarchy`          | todo   | vars.yaml未登録 |

### プロトコル

| Var               | Status | Note                         |
| ----------------- | ------ | ---------------------------- |
| `defprotocol`     | done   | analyzer special form        |
| `extend-type`     | done   | analyzer special form        |
| `extend`          | todo   | extend-typeのプリミティブ版  |
| `extend-protocol` | todo   | core.cljマクロ               |
| `extenders`       | todo   | プロトコル実装型リスト       |
| `extends?`        | todo   | 型がプロトコル実装しているか |
| `satisfies?`      | done   | Zig builtin                  |

### 例外処理

| Var              | Status | Note         |
| ---------------- | ------ | ------------ |
| `try`            | done   | special form |
| `catch`          | done   | special form |
| `throw`          | done   | special form |
| `ex-info`        | done   | Zig builtin  |
| `ex-message`     | done   | Zig builtin  |
| `ex-data`        | done   | Zig builtin  |
| `ex-cause`       | todo   | Zig builtin  |
| `Throwable->map` | todo   | Zig builtin  |

### 型・メタデータ

| Var           | Status  | Note                   |
| ------------- | ------- | ---------------------- |
| `type`        | done    | Zig builtin            |
| `class`       | done    | Zig builtin            |
| `instance?`   | done    | core.clj               |
| `with-meta`   | done    | Zig builtin            |
| `alter-meta!` | done    | Zig builtin            |
| `defrecord`   | done    | ->Name生成             |
| `deftype`     | partial | マップベース簡略版     |
| `record?`     | todo    | 常にfalse (真の型なし) |

---

## Priority 2: System/Math Analyzer書き換え

### System/ メソッド

| Java Syntax                  | 内部関数                  | Status | Note                        |
| ---------------------------- | ------------------------- | ------ | --------------------------- |
| `(System/nanoTime)`          | `(__nano-time)`           | todo   | Zig std.time.nanoTimestamp  |
| `(System/currentTimeMillis)` | `(__current-time-millis)` | todo   | Zig std.time.milliTimestamp |
| `(System/getenv k)`          | `(__getenv k)`            | todo   | Zig std.process.getEnvMap   |
| `(System/exit n)`            | `(__exit n)`              | todo   | Zig std.process.exit        |

### Math/ メソッド

| Java Syntax      | 内部関数      | Status | Note             |
| ---------------- | ------------- | ------ | ---------------- |
| `(Math/abs x)`   | `(abs x)`     | done   | Zig builtin      |
| `(Math/ceil x)`  | `(__ceil x)`  | todo   | Zig @ceil        |
| `(Math/floor x)` | `(__floor x)` | todo   | Zig @floor       |
| `(Math/round x)` | `(__round x)` | todo   | Zig @round       |
| `(Math/sqrt x)`  | `(__sqrt x)`  | todo   | Zig @sqrt        |
| `(Math/pow x y)` | `(__pow x y)` | todo   | Zig std.math.pow |
| `(Math/sin x)`   | `(__sin x)`   | todo   | Zig @sin         |
| `(Math/cos x)`   | `(__cos x)`   | todo   | Zig @cos         |
| `(Math/tan x)`   | `(__tan x)`   | todo   | Zig @tan         |
| `(Math/log x)`   | `(__log x)`   | todo   | Zig @log         |
| `(Math/exp x)`   | `(__exp x)`   | todo   | Zig @exp         |
| `Math/PI`        | 定数          | todo   | 3.14159...       |
| `Math/E`         | 定数          | todo   | 2.71828...       |
| `(Math/random)`  | `(rand)`      | done   | Zig builtin      |

---

## Priority 3: UUID・時間

| Var           | Status | Note                 |
| ------------- | ------ | -------------------- |
| `random-uuid` | todo   | Zig random + format  |
| `parse-uuid`  | todo   | UUID文字列パース     |
| `time`        | todo   | マクロ(経過時間表示) |
| `inst?`       | todo   | instant判定          |
| `inst-ms`     | todo   | instant→ミリ秒       |

---

## Priority 4: IO操作

### ファイルIO

| Var           | Status | Note                    |
| ------------- | ------ | ----------------------- |
| `slurp`       | todo   | Zig fs.readFileAlloc    |
| `spit`        | todo   | Zig fs.writeFile        |
| `line-seq`    | todo   | lazy行読み (Beta stub)  |
| `file-seq`    | todo   | ディレクトリ走査        |
| `load-file`   | todo   | Clojureファイル読込評価 |
| `delete-file` | todo   | Zig fs.deleteFile       |
| `*file*`      | todo   | 現在ロード中ファイル    |

### 標準入出力

| Var         | Status | Note          |
| ----------- | ------ | ------------- |
| `println`   | done   | Zig builtin   |
| `print`     | todo   | Zig builtin   |
| `pr`        | todo   | readably出力  |
| `prn`       | todo   | pr + 改行     |
| `printf`    | todo   | 書式付き出力  |
| `newline`   | todo   | 改行出力      |
| `read-line` | todo   | stdin読み取り |
| `flush`     | todo   | stdout flush  |

### 動的出力先

| Var            | Status | Note                  |
| -------------- | ------ | --------------------- |
| `*in*`         | todo   | stdin (動的バインド)  |
| `*out*`        | todo   | stdout (動的バインド) |
| `*err*`        | todo   | stderr (動的バインド) |
| `with-out-str` | todo   | 出力キャプチャマクロ  |
| `with-open`    | todo   | リソース管理マクロ    |

### 文字列IO

| Var           | Status | Note            |
| ------------- | ------ | --------------- |
| `pr-str`      | todo   | readably→文字列 |
| `prn-str`     | todo   | pr-str + 改行   |
| `print-str`   | todo   | print→文字列    |
| `println-str` | todo   | println→文字列  |

### clojure.java.io 相当

| Var                   | Status | Note                      |
| --------------------- | ------ | ------------------------- |
| `io/reader`           | todo   | ファイル→読み取りハンドル |
| `io/writer`           | todo   | ファイル→書き込みハンドル |
| `io/input-stream`     | todo   | バイナリ入力ストリーム    |
| `io/output-stream`    | todo   | バイナリ出力ストリーム    |
| `io/copy`             | todo   | 入力→出力コピー           |
| `io/file`             | todo   | パス→Fileオブジェクト相当 |
| `io/make-parents`     | todo   | 親ディレクトリ作成        |
| `io/resource`         | todo   | リソースパス解決          |
| `io/as-relative-path` | todo   | 相対パス変換              |

---

## Priority 5: 型変換

| Var      | Status | Note                  |
| -------- | ------ | --------------------- |
| `int`    | todo   | 整数変換              |
| `long`   | todo   | = int (ClojureWasm)   |
| `float`  | todo   | 浮動小数点変換        |
| `double` | todo   | = float (ClojureWasm) |
| `char`   | todo   | 文字変換              |
| `num`    | todo   | 数値identity          |

---

## Priority 6: 単一スレッド簡略版

| Var       | Status | Note                            |
| --------- | ------ | ------------------------------- |
| `future`  | todo   | 即時評価版(delay的)             |
| `promise` | todo   | 1回設定可能な値                 |
| `deliver` | todo   | promise設定                     |
| `ref`     | todo   | 単一スレッド: atom的            |
| `dosync`  | todo   | 単一スレッド: 空マクロ          |
| `alter`   | todo   | ref更新                         |
| `commute` | todo   | ref更新(単一スレッドでは=alter) |
| `ensure`  | todo   | 単一スレッド: 空操作            |
| `atom`    | done   | Zig builtin                     |
| `deref`   | done   | Zig builtin                     |
| `reset!`  | done   | Zig builtin                     |
| `swap!`   | done   | Zig builtin                     |

---

## Priority 7: ビット演算

| Var                        | Status | Note   |
| -------------------------- | ------ | ------ |
| `bit-and`                  | done   | Zig    |
| `bit-or`                   | done   | Zig    |
| `bit-xor`                  | done   | Zig    |
| `bit-not`                  | done   | Zig    |
| `bit-shift-left`           | done   | Zig    |
| `bit-shift-right`          | done   | Zig    |
| `bit-and-not`              | todo   | a & ~b |
| `bit-clear`                | todo   |        |
| `bit-flip`                 | todo   |        |
| `bit-set`                  | todo   |        |
| `bit-test`                 | todo   |        |
| `unsigned-bit-shift-right` | todo   | >>>    |

---

## Priority 8: Require/Namespace

| Var       | Status | Note                        |
| --------- | ------ | --------------------------- |
| `ns`      | done   | → :require/:use対応追加     |
| `in-ns`   | done   | Zig builtin                 |
| `require` | todo   | ClojureWasmブートストラップ |
| `use`     | todo   | require + refer             |
| `refer`   | todo   | vars取り込み                |
| `alias`   | todo   | namespace alias             |

---

## Deferred: 将来フェーズ

| Var      | Note                                   |
| -------- | -------------------------------------- |
| `bigint` | 任意精度整数 (Reader + Value型 + 演算) |
| `bigdec` | 任意精度小数 (同上)                    |
| `ratio`  | 分数型 (F3)                            |

---

## Skip: 実装しない

- `Boolean/TRUE`, `Boolean/FALSE` — `true`/`false`で十分
- `clojure.lang.MapEntry.` — `(vector k v)`で代替
- `.getMessage`, `.getCause` — `ex-message`, `ex-cause`で対応
- `reify`, `proxy`, `gen-class`, `gen-interface` — JVM必須
- `definterface`, `init-proxy`, `proxy-super`, `proxy-mappings` — proxy依存
- `lock`, `unlock` — 非標準/JVM依存

---

## Summary

| Priority  | Todo   | Done   | Category             |
| --------- | ------ | ------ | -------------------- |
| P1        | 15     | 20     | 階層・Multi・Proto等 |
| P2        | 15     | 2      | System/Math書き換え  |
| P3        | 5      | 0      | UUID・時間           |
| P4        | 32     | 1      | IO操作 (拡充)        |
| P5        | 6      | 0      | 型変換               |
| P6        | 8      | 4      | 単一スレッド並行     |
| P7        | 6      | 6      | ビット演算           |
| P8        | 4      | 2      | Require/Namespace    |
| P9        | 0      | 8      | 制御構造 (参考)      |
| **Total** | **91** | **43** |                      |
