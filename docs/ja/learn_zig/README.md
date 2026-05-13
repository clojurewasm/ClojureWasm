# learn_zig — ClojureWasm に登場する Zig 0.16.0 を基礎から

> 本リポジトリ（`cw-from-scratch` ブランチ）の Zig ソース（`build.zig` /
> `build.zig.zon` / `src/**/*.zig`、合計約 9,100 行）を **隅々まで** 読みきる
> ために必要な Zig 0.16.0 の文法・型・組込関数・標準ライブラリを、
> 登場順ではなく **教科書順** に並べ直した補助教材です。
>
> Phase 4 開始前のコードリーディング期間中、`docs/ja/learn_clojurewasm/0001`〜`0020` を
> 読み進めるあいだに、Zig 側で詰まらないようにするための副読本という
> 位置付けです。本リポジトリの ROADMAP / フェーズ進行とは独立しています。

各章は **解説 → 問題 → 解答** の 3 段構成になっています。

- **解説**: その章のテーマ（型・構文・組込関数・標準ライブラリ API）の
  紹介と、本リポジトリでの登場箇所への参照。
- **問題**: 自分の手で書いて定着させるための演習。雛形は用意しません。
  問題ごとに `01_hello.zig` のような `.zig` ファイルを好きな場所に作り、
  `zig run` または `zig test` で動作確認してください。変数名・表示文・
  入力値は自由ですが、指定された型・構文・組込関数・標準ライブラリ API
  を必ず使ってください。
- **解答**: 一例です。条件を満たしていれば、変数名・表示文・入力値は
  同じでなくて構いません。コードはすべて Zig 0.16.0 でグリーン確認済み、
  deprecated API は使っていません。

```sh
# 例: 自分で書いた解答を実行・テスト
zig run 01_hello.zig
zig test 27_tests.zig
zig build --build-file 00b_build.zig run
```

出題範囲は本リポジトリの Zig コードに登場する要素に絞っています。逆に
末尾の「付録: 本リポジトリで扱わない Zig 機能」で挙げた機能は、解説も
問題も載せていません。

---

## 目次

| 章                                                                | 主題                                                             |
|-------------------------------------------------------------------|------------------------------------------------------------------|
| [0a](#0a-buildzigzon--パッケージマニフェスト)                     | `build.zig.zon` — パッケージマニフェスト                        |
| [0b](#0b-buildzig--ビルドスクリプト)                              | `build.zig` — ビルドスクリプト                                  |
| [01](#01-hello-とフォーマット出力)                                | Hello とフォーマット出力                                         |
| [02](#02-3-種類のコメントと関数)                                  | 3 種類のコメントと関数                                           |
| [03](#03-基本型と-sizeof)                                         | 基本型と `@sizeOf`                                               |
| [04](#04-数値リテラルビット演算比較)                              | 数値リテラル・ビット演算・比較                                   |
| [05](#05-const-と-var)                                            | `const` と `var`                                                 |
| [06](#06-明示的な型変換)                                          | 明示的な型変換                                                   |
| [07](#07-配列)                                                    | 配列 `[N]T` / `[_]T{}` / `** N`                                  |
| [08](#08-スライス)                                                | スライス `[]T` / `[]const T`                                     |
| [09](#09-オプショナル-t)                                          | オプショナル `?T`                                                |
| [10](#10-エラーと-error-union)                                    | エラーと error union                                             |
| [11](#11-制御構文)                                                | `if` / `while` / `for` / `switch`                                |
| [12](#12-ラベル付きブロック)                                      | ラベル付きブロック `blk:`                                        |
| [13](#13-struct-とメソッド)                                       | `struct` とメソッド                                              |
| [14](#14-enum)                                                    | `enum` / `enum(uN)` / 非網羅 `_`                                 |
| [15](#15-タグ付き-union)                                          | タグ付き union `union(enum)`                                     |
| [16](#16-packed-struct--extern-struct--alignn)                    | `packed struct` / `extern struct` / `align(N)`                   |
| [17](#17-ポインタと-anyopaque)                                    | ポインタと `anyopaque`                                           |
| [18](#18-関数ポインタと-vtable)                                   | 関数と関数ポインタ・vtable パターン                              |
| [19](#19-comptime-inline-for-anytype)                             | `comptime` / `inline for` / `anytype`                            |
| [20](#20-マルチライン文字列)                                      | マルチライン文字列                                               |
| [21](#21-undefined-と-unreachable)                                | `undefined` と `unreachable`                                     |
| [22](#22-threadlocal-var)                                         | `threadlocal var`                                                |
| [23](#23-アロケータ)                                              | アロケータ抽象                                                   |
| [24](#24-arraylist--stringhashmapunmanaged--array_hash_mapstring) | `ArrayList` / `StringHashMapUnmanaged` / `array_hash_map.String` |
| [25](#25-staticstringmap)                                         | `StaticStringMap.initComptime`                                   |
| [26](#26-stdiowriter)                                             | `std.Io.Writer` と Juicy Main                                    |
| [27](#27-テストブロック)                                          | テストブロック `test "..." {}`                                   |
| [28](#28-stdmem-と-memcpy)                                        | `std.mem` ユーティリティと `@memcpy`                             |
| [29](#29-stdfmt)                                                  | `std.fmt` — `bufPrint` / `parseInt` / `parseFloat`              |
| [30](#30-embedfile-anyerror-errorname)                            | `@embedFile` / `anyerror` / `@errorName`                         |

---

## 0a. `build.zig.zon` — パッケージマニフェスト

#### 解説

Zig パッケージのメタデータです。本リポジトリの実物（`build.zig.zon`）：

```zig
.{
    .name = .cljw,
    .version = "0.0.0",
    .fingerprint = 0x1869d207073beffa,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .zlinter = .{
            .url = "git+https://github.com/kurtwagner/zlinter?ref=0.16.x#9b4d67b9725e7137ac876cc628fe5dd2ca5a2681",
            .hash = "zlinter-0.0.1-OjQ08c7oCwDIwhlde7eDKMACNTsqAhGXy5vB7GdfGobG",
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "LICENSE",
        "README.md",
    },
}
```

`.zon` は **Zig Object Notation** で、Zig コードの匿名 struct リテラル
構文をそのままデータ形式として使っています。重要な点：

- `.cljw` のような **先頭ドットの識別子** は enum-like なシンボルで、
  パッケージ名にはこれを使います。
- `.dependencies` は外部パッケージ宣言。本リポジトリは現在 zlinter
  （`no_deprecated` 等の lint ルール、ADR-0003）を 1 つだけ依存して
  います。`zig fetch --save <git URL>` を実行すると、`url` と `hash`
  のペアがこの形でこのファイルに追記されます。
- `.paths` は配布アーカイブに含めるパス。tarball に同梱するファイル
  集合を明示します。
- `.fingerprint` は Zig 0.12 以降のパッケージマネージャがハッシュ衝突を
  防ぐために使うランダム 64-bit 値。

#### 問題

`00a_build.zig.zon` を手書きしてください。`.name`、`.version`、
`.minimum_zig_version`、`.dependencies`、`.paths` を持つ Zig Object
Notation の匿名 struct リテラルにし、`.dependencies` には `zlinter`
風の `url` と `hash` のペアを 1 つ入れてください。`zig run` は不要
ですが、Zig の struct リテラルとして読める形になっているか確認して
ください。

#### 解答

```zig
.{
    .name = .learn_zig_problem,
    .version = "0.0.0",
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .zlinter = .{
            .url = "git+https://github.com/kurtwagner/zlinter?ref=0.16.x#9b4d67b9725e7137ac876cc628fe5dd2ca5a2681",
            .hash = "zlinter-0.0.1-OjQ08c7oCwDIwhlde7eDKMACNTsqAhGXy5vB7GdfGobG",
        },
    },
    .paths = .{
        "00b_build.zig",
        "00b_main.zig",
        "README.md",
    },
}
```

## 0b. `build.zig` — ビルドスクリプト

#### 解説

ビルドそのものも Zig コードです。本リポジトリの `build.zig`：

```zig
const std = @import("std");
const zlinter = @import("zlinter");   // ADR-0003: lint ルール DB

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "cljw",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the executable");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    // `zig build lint -- --max-warnings 0` が Mac の pre-commit ゲート
    // (ADR-0003)。Linux runner では test/run_all.sh が skip する。
    const lint_step = b.step("lint", "Lint source code (zlinter).");
    lint_step.dependOn(blk: {
        var builder = zlinter.builder(b, .{});
        builder.addRule(.{ .builtin = .no_deprecated }, .{});
        builder.addRule(.{ .builtin = .no_orelse_unreachable }, .{});
        builder.addRule(.{ .builtin = .no_empty_block }, .{});
        builder.addRule(.{ .builtin = .no_unused }, .{});
        break :blk builder.build();
    });
}
```

要点：

- **エントリポイントは `pub fn build(b: *std.Build) void`**。`zig build`
  は内部でこの関数を呼び、`b` の上にビルドグラフを組み上げます。
- `b.standardTargetOptions(.{})` / `b.standardOptimizeOption(.{})` で
  `--target` / `--release=...` などの CLI フラグを自動受信します。
- **モジュール → アーティファクト** の二段階：まず `b.createModule`
  でソースツリーをモジュール化し、それを `addExecutable` / `addTest`
  に渡します。同じモジュールを複数のアーティファクトで共有できるのが
  ポイント（本リポジトリでは `exe` と `exe_tests` が `exe_mod` を共有）。
- **ステップは依存グラフ**。`run_step.dependOn(&run_cmd.step)` のように
  「ステップ A が走るには B が完了済みであること」を宣言します。
- `b.args` は `?[][]u8`。`zig build run -- foo bar` の `--` 以降が
  `args` として届くので、`if (b.args) |args| run_cmd.addArgs(args)` で
  実行時引数を引き渡しています（→ 第 09 章のオプショナル）。
- 末尾の **`lint` ステップ** は zlinter の `builder` API を使い、`zig
  build lint -- --max-warnings 0` で deprecated stdlib API などを
  検出します。詳細は ADR-0003。

#### 問題

`00b_build.zig` と、それが参照する小さな `00b_main.zig` を手書きして
ください。`pub fn build(b: *std.Build) void`、`standardTargetOptions`、
`standardOptimizeOption`、`createModule`、`addExecutable`、
`installArtifact`、`addRunArtifact`、`b.args`、`b.step`、`dependOn`、
`addTest` を使い、`zig build --build-file 00b_build.zig run` と
`... test` で動作確認してください。zlinter の外部依存はここでは実際に
import しなくて構いませんが、上の lint step と同じ「step は依存グラフ」
という形を意識してください。

#### 解答

`00b_main.zig`:

```zig
const std = @import("std");

pub fn main() !void {
    std.debug.print("[00b] hello from build step\n", .{});
}

test "main file is discoverable" {
    try std.testing.expect(true);
}
```

`00b_build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("00b_main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "learn-zig-problem",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the executable");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
```

## 01. Hello とフォーマット出力

#### 解説

最小プログラム：

```zig
const std = @import("std");

pub fn main() !void {
    std.debug.print("[01] Hello from Zig 0.16!\n", .{});
}
```

要点：

- `@import("std")` は **コンパイル時** に標準ライブラリ struct を取り込む
  組込関数。戻り値はすべて comptime 既知の型なので、`const std = ...` は
  実質「名前空間のエイリアス」です（→ 第 19 章 comptime）。
- `pub fn main() !void` の `!void` は **error union 型**（→ 第 10 章）。
  `!` の左辺を省略しているのは「推論された error set を使う」の意。
- `std.debug.print` は stderr へバッファなしで書き込むデバッグ用関数。
  プロダクション用途では `std.Io.Writer`（→ 第 26 章）を使います。
- `.{...}` は **匿名タプル / 匿名 struct リテラル**。フォーマット引数
  リストはこれで渡します。空なら `.{}`。
- 本リポジトリの `src/main.zig` は **Juicy Main**（`pub fn main(init:
  std.process.Init) !void`）を採用しているので、`io` / `gpa` / `arena`
  を一括で受け取ります。詳細は第 26 章。

#### 問題

`@import("std")` と `pub fn main() !void` を使い、文字列だけの出力と、
`{s}` / `{d}` を使ったフォーマット出力を 1 回ずつ行ってください。
フォーマット引数は `.{}` と `.{ ... }` の両方を使ってください。

#### 解答

```zig
const std = @import("std");

pub fn main() !void {
    std.debug.print("[01] hello\n", .{});
    std.debug.print("[01] {s} = {d}\n", .{ "answer", 42 });
}
```

## 02. 3 種類のコメントと関数

#### 解説

Zig のコメントは 3 種類あります：

| 記号  | 用途                                                       |
|-------|------------------------------------------------------------|
| `//`  | 通常のコメント。コードフロー内のメモ。                     |
| `///` | **宣言ドキュメント**。直後の `pub` 宣言に紐づく。          |
| `//!` | **モジュールドキュメント**。ファイル先頭、`@import` の前。 |

ZLS（Zig Language Server）は `///` と `//!` をホバー表示で見せるので、
本リポジトリではすべての `pub` 宣言に `///` を、すべての `.zig` 先頭に
`//!` を付ける方針です（`.claude/rules/zig_tips.md`）。

```zig
//! Tokenizer — module-level overview goes here.

const std = @import("std");

/// Token classification — used by `Reader` (../reader.zig).
pub const TokenKind = enum(u8) { ... };
```

#### 問題

ファイル先頭に `//!`、関数の直前に `///`、関数本体内に `//` を書いて
ください。整数を 2 乗する関数を作り、`main` から呼んで結果を表示して
ください。

#### 解答

```zig
//! Comment practice.

const std = @import("std");

/// Returns x squared.
fn square(x: i32) i32 {
    // Debug builds panic on integer overflow.
    return x * x;
}

pub fn main() !void {
    std.debug.print("[02] square(7) = {d}\n", .{square(7)});
}
```

## 03. 基本型と `@sizeOf`

#### 解説

本リポジトリで実際に登場する基本型：

| 型      | 幅         | 用途例（本リポジトリ）                               |
|---------|------------|------------------------------------------------------|
| `u8`    | 1 バイト   | 生バイト、ASCII 文字、`HeapTag` の格納整数           |
| `u16`   | 2 バイト   | カラム位置、トークン長                               |
| `u32`   | 4 バイト   | 行番号、コレクション要素数                           |
| `u64`   | 8 バイト   | NaN-boxed `Value`、ハッシュ                          |
| `usize` | ポインタ幅 | 長さ・オフセット（プラットフォーム依存）             |
| `i32`   | 4 バイト   | 一般の符号付き整数                                   |
| `i64`   | 8 バイト   | Clojure 整数の中間計算（i48 範囲のチェック）         |
| `f64`   | 8 バイト   | Clojure 浮動小数                                     |
| `bool`  | 1 バイト   | `true` / `false`                                     |
| `void`  | 0 バイト   | 値を返さない関数の戻り値、`{}` がその唯一の値        |
| `type`  | -          | comptime のみ。型自体を値として扱う（→ 第 19 章）。 |

Zig は `u1` `u3` `u21` のような **任意ビット幅整数** も持ちます。本
リポジトリでは `u3`（NaN-box 整数の 3-bit シフト）、`u21`（Unicode
コードポイント、`initChar(c: u21)`）が登場します。

#### 問題

`u8`、`u16`、`u32`、`u64`、`usize`、`i32`、`i64`、`f64`、`bool`、
`void` の値をそれぞれ作ってください。任意ビット幅整数として `u3` と
`u21` も 1 つずつ作ってください。`usize` の値には `@sizeOf(u64)` を
使い、比較演算の結果を `bool` に入れて、各値を表示してください。
`type` は実行時の値として表示するのではなく、`const T: type = u21;` の
ように型を値として束縛し、`@sizeOf(T)` で確認してください。

#### 解答

```zig
const std = @import("std");

pub fn main() !void {
    const a: u8 = 255;
    const b: u16 = 65_535;
    const c: u32 = 1_000_000;
    const d: u64 = 0xFFFF_FFFF_FFFF_FFFF;
    const e: usize = @sizeOf(u64);
    const f: i32 = -1234;
    const g: i64 = -123_456;
    const h: f64 = 3.14;
    const i: bool = a < c;
    const shift: u3 = 3;
    const codepoint: u21 = 'あ';
    const CodepointType: type = u21;
    const nothing: void = {};
    _ = nothing;

    std.debug.print("[03] u8={d} u16={d} u32={d} u64={d}\n", .{ a, b, c, d });
    std.debug.print("[03] usize={d} i32={d} i64={d} f64={d} bool={}\n", .{ e, f, g, h, i });
    std.debug.print("[03] u3={d} u21={d} sizeOf(type)={d}\n", .{ shift, codepoint, @sizeOf(CodepointType) });
}
```

## 04. 数値リテラル・ビット演算・比較

#### 解説

リテラル形式（本リポジトリで実際に登場するもの）：

```zig
const dec  = 1_234_567;        // 10 進、_ で桁区切り
const hex  = 0xFFFC_0000_0000; // 16 進、_ も使える
const flt  = 3.14e-2;          // 浮動小数
```

> Zig には 2 進 `0b...` / 8 進 `0o...` のリテラルも存在しますが、本
> リポジトリでは使われていないので本書では扱いません。

演算子：

- 算術: `+ - * / %`（整数除算は切り捨て、`%` は剰余）
- ビット: `& | ^ ~ << >>`
- 比較: `== != < <= > >=`
- 論理: `and or !`（短絡評価）
- ポインタ参照外し: `p.*`（→ 第 17 章）

本リポジトリの `runtime/value.zig` がほぼ全部の演算子を NaN ボックス
のタグ操作で使っています：`tag | payload` で詰め、`>> 48` で取り出し、
`& 0x0000_FFFF_FFFF_FFFF` でマスク。

#### 問題

16 進リテラルと桁区切り `_` を使ってタグ値と payload を作り、`|`、
`&`、`^`、`~`、`<<`、`>>`、`@truncate` で合成値・上位 16 bit・payload
部分などを表示してください。あわせて `+`、`-`、`*`、`/`、`%`、`==`、
`!=`、`<`、`<=`、`>`、`>=`、`and`、`or`、`!` の結果も表示してください。

#### 解答

```zig
const std = @import("std");

pub fn main() !void {
    const tag: u64 = 0xFFFC_0000_0000_0000;
    const payload: u64 = 1_234_567;
    const packed_value: u64 = tag | payload;
    const top16: u16 = @truncate(packed_value >> 48);
    const masked: u64 = packed_value & 0x0000_FFFF_FFFF_FFFF;
    const toggled: u64 = payload ^ 0xFF;
    const inverted_low: u8 = ~@as(u8, 0b1010_0000);
    const shifted_left: u64 = payload << 3;

    const sum: i32 = 2 + 3 * 4 - 1;
    const div: i32 = 17 / 5;
    const rem: i32 = 17 % 5;
    const eq = sum == 13;
    const ne = div != rem;
    const cmp = sum >= 10 and sum <= 20 and !(sum < 0) or false;

    std.debug.print("[04] packed=0x{X:0>16} top16=0x{X} masked={d}\n", .{ packed_value, top16, masked });
    std.debug.print("[04] xor={d} not=0x{X} left={d}\n", .{ toggled, inverted_low, shifted_left });
    std.debug.print("[04] sum={d} div={d} rem={d} eq={} ne={} cmp={}\n", .{ sum, div, rem, eq, ne, cmp });
}
```

## 05. `const` と `var`

#### 解説

Zig はデフォルト不変です：

- **`const`**: 再代入できない束縛。型は推論可能ですが、**境界をまたぐ
  値は型注釈** が本リポジトリ方針。
- **`var`**: 再代入可能。初期化必須（`undefined` で「あとで埋める」を
  明示することは可能、→ 第 21 章）。
- ローカル変数はすべて関数スコープ。グローバルは `pub const` /
  `pub var` / `threadlocal var`（→ 第 22 章）。

```zig
const max_iter: u32 = 100;       // 注釈付き const
var counter: u32 = 0;            // var、初期化済み
counter += 1;                    // 再代入 OK

const greeting = "hi";           // 推論：*const [2:0]u8 → []const u8 互換
var arr: [3]i32 = .{ 10, 20, 30 };
arr[1] = 99;                     // 配列要素の書き換えは var なら可
```

> ROADMAP §13 で `pub var` のグローバル可変状態は禁止されています。
> Vtable のような「初期化後に固定する一回書き」も `Runtime.vtable:
> ?VTable` のように構造体フィールド側へ持たせるのが本リポジトリ方針。

#### 問題

`const` の文字列と整数、`var` のカウンタを作ってください。カウンタは
再代入と `+=` の両方で更新し、可変配列の要素も 1 つ書き換えて表示して
ください。最後に `while` で 0, 1, 2 を表示してください。

#### 解答

```zig
const std = @import("std");

pub fn main() !void {
    const greeting = "hi";
    const max_iter: u32 = 100;
    var counter: u32 = 0;
    counter = counter + 1;
    counter += 5;

    var arr: [3]i32 = .{ 10, 20, 30 };
    arr[1] = 99;

    std.debug.print("[05] {s} max={d} counter={d} arr={any}\n", .{ greeting, max_iter, counter, arr });

    var tick: u32 = 0;
    while (tick < 3) : (tick += 1) {
        std.debug.print("[05] tick={d}\n", .{tick});
    }
}
```

## 06. 明示的な型変換

#### 解説

Zig は暗黙の縮小変換も符号またぎも許しません。**「`@`-組込関数で
明示する」** のが Zig の文化です。本リポジトリのソースで実際に登場する
のは以下の 20 個（grep で網羅確認済み）。本章ではこのうち「整数・
浮動小数・bool・型サイズ」に関わるものに絞って手を動かします。
他は登場章で再度扱います。

| 組込関数        | 役割                                                     | 詳述章   |
|-----------------|----------------------------------------------------------|----------|
| `@import`       | ソースを取り込む                                         | 第 01 章 |
| `@as(T, x)`     | 互換型への明示的キャスト（最も無害）                     | 本章     |
| `@intCast`      | 整数の縮小変換、debug ビルドでレンジチェック             | 本章     |
| `@truncate`     | レンジチェックなしで上位ビット切り捨て                   | 本章     |
| `@bitCast`      | 同サイズで bit パターン再解釈（`f64 ↔ u64`）            | 本章     |
| `@floatFromInt` | 整数 → 浮動小数                                         | 本章     |
| `@intFromBool`  | `bool` → `0` / `1`                                      | 本章     |
| `@sizeOf(T)`    | バイトサイズ                                             | 本章     |
| `@alignOf(T)`   | アラインメント要件                                       | 本章     |
| `@intFromEnum`  | enum → 整数                                             | 第 14 章 |
| `@enumFromInt`  | 整数 → enum                                             | 第 14 章 |
| `@tagName`      | enum / error のタグ名 `[]const u8`                       | 第 14 章 |
| `@intFromPtr`   | ポインタ → `usize`（NaN ボックスの payload 詰め）       | 第 17 章 |
| `@ptrFromInt`   | `usize` → ポインタ                                      | 第 17 章 |
| `@ptrCast`      | ポインタ型の付け替え                                     | 第 17 章 |
| `@alignCast`    | アラインメント情報付け替え                               | 第 17 章 |
| `@memcpy`       | バッファコピー（同サイズ必須）                           | 第 28 章 |
| `@min`          | 最小値                                                   | 第 30 章 |
| `@embedFile`    | ファイル内容をコンパイル時に `[]const u8` として埋め込む | 第 30 章 |
| `@errorName`    | エラー値のタグ名                                         | 第 30 章 |

> 上記 20 個が **このリポジトリに登場するすべて** です。`@memset`
> `@max` `@branchHint` `@panic` `@call` などの他の `@` 組込関数は
> 登場しないので本書では扱いません。

`runtime/value.zig` の NaN ボクシング実装はこのうち多くを駆使しています。

#### 問題

`@as`、`@intCast`、`@truncate`、`@floatFromInt`、`@bitCast`、
`@intFromBool`、`@sizeOf`、`@alignOf` をすべて使ってください。整数、
浮動小数、bool、型サイズ、アラインメントの結果を表示してください。

#### 解答

```zig
const std = @import("std");

pub fn main() !void {
    const a = @as(i64, 42);
    const b: u16 = @intCast(a);
    const big: u64 = 0xDEAD_BEEF_CAFE_BABE;
    const low16: u16 = @truncate(big);
    const f: f64 = @floatFromInt(@as(i64, 7));
    const bits: u64 = @bitCast(@as(f64, 1.5));
    const truthy: u8 = @intFromBool(true);
    const falsy: u8 = @intFromBool(false);

    std.debug.print("[06] as={d} cast={d} low16=0x{X}\n", .{ a, b, low16 });
    std.debug.print("[06] float={d} bits=0x{X:0>16} bool={d}/{d}\n", .{ f, bits, truthy, falsy });
    std.debug.print("[06] size={d} align={d}\n", .{ @sizeOf(u64), @alignOf(u64) });
}
```

## 07. 配列

#### 解説

固定長配列の書き方：

```zig
const fib: [6]u32 = .{ 1, 1, 2, 3, 5, 8 };  // 長さを明示
const primes = [_]u32{ 2, 3, 5, 7, 11 };    // 長さを推論
const zeros: [4]u32 = [_]u32{0} ** 4;        // ** N で反復
```

`** N` は **配列の繰り返し**。`main.zig` の
`var locals: [tree_walk.MAX_LOCALS]Value = [_]Value{.nil_val} ** tree_walk.MAX_LOCALS;`
は「`MAX_LOCALS` 個の `nil_val` で初期化」の定型です。

`.len` でコンパイル時長さが取れます。配列はそのままだとサイズ込みの型
（`[6]u32` と `[8]u32` は別の型）なので、関数の引数として受け渡す場合は
**スライス**（→ 第 08 章）にします。

#### 問題

長さ明示の配列、`[_]T{}` による長さ推論、`** N` による繰り返し配列、
多次元配列を作ってください。`.len`、添字アクセス、`while` による合計
計算を使い、結果を表示してください。

#### 解答

```zig
const std = @import("std");

pub fn main() !void {
    const fib: [6]u32 = .{ 1, 1, 2, 3, 5, 8 };
    const primes = [_]u32{ 2, 3, 5, 7, 11 };
    const zeros: [4]u32 = [_]u32{0} ** 4;
    const grid: [2][3]u8 = .{ .{ 1, 2, 3 }, .{ 4, 5, 6 } };

    var i: usize = 0;
    var sum: u32 = 0;
    while (i < primes.len) : (i += 1) sum += primes[i];

    std.debug.print("[07] fib[5]={d} primes.len={d}\n", .{ fib[5], primes.len });
    std.debug.print("[07] zeros={any} grid[1][2]={d} sum={d}\n", .{ zeros, grid[1][2], sum });
}
```

## 08. スライス

#### 解説

スライス `[]T` は `(ポインタ, 長さ)` のペアです。**Zig で文字列を
扱う標準は `[]const u8`**（本リポジトリの `[]const u8` 出現は数百箇所）。

```zig
const buffer: [10]u8 = .{ 'H', 'e', 'l', 'l', 'o', ',', ' ', 'C', 'L', 'J' };
const all:  []const u8 = buffer[0..];
const head: []const u8 = buffer[0..5];
const tail: []const u8 = buffer[7..];
```

可変スライス `[]T` は要素を書き換え可能、`[]const T` は読み取り専用。
文字列リテラル `"hello"` の型は厳密には `*const [5:0]u8` ですが、
`[]const u8` への暗黙変換が効きます（だから関数引数を `[]const u8` に
すればリテラルを直接渡せます）。

#### 問題

`[]const u8` を引数に取って長さを返す関数を作ってください。固定長
配列から `[start..end]`、`[start..]`、`[0..]` でスライスを切り出して
表示し、可変スライス `[]i32` 経由で元配列を書き換えてください。

#### 解答

```zig
const std = @import("std");

fn lengthOf(s: []const u8) usize {
    return s.len;
}

pub fn main() !void {
    const buffer: [10]u8 = .{ 'H', 'e', 'l', 'l', 'o', ',', ' ', 'Z', 'i', 'g' };
    const all: []const u8 = buffer[0..];
    const head: []const u8 = buffer[0..5];
    const tail: []const u8 = buffer[7..];

    var nums: [5]i32 = .{ 1, 2, 3, 4, 5 };
    const view: []i32 = nums[1..4];
    view[0] = 99;

    std.debug.print("[08] all={s} head={s} tail={s}\n", .{ all, head, tail });
    std.debug.print("[08] len={d} nums={any}\n", .{ lengthOf("hello"), nums });
}
```

## 09. オプショナル `?T`

#### 解説

Zig には暗黙の null がありません。「null かもしれない」を表すには
**型として** `?T` と書きます。

```zig
const a: ?u32 = lookup("alpha");

if (a) |v| { ... }            // 値捕捉
const x = a orelse default;   // null なら default
const y = a.?;                // null なら panic（safe build）
```

本リポジトリの典型例：

- `Keyword.ns: ?[]const u8`（unqualified キーワードは `null`）
- `last_error: ?Info`（エラー未発生時は `null`）
- `current_frame: ?*BindingFrame`（dynamic binding スタック先頭）

`orelse` は値返しだけでなく **制御フロー脱出** にも使えます：

```zig
const expr = args.next() orelse {
    try stderr.print("Error: -e requires arg\n", .{});
    std.process.exit(1);
};
```

#### 問題

文字列キーを受け取って `?u32` を返す lookup 関数を作ってください。
`if (opt) |v|`、`orelse`、`.?`、`orelse break :label` をそれぞれ使い、
存在する値・存在しない値・既定値・ラベル付きブロックの戻り値を表示
してください。

#### 解答

```zig
const std = @import("std");

fn lookup(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "alpha")) return 1;
    if (std.mem.eql(u8, name, "beta")) return 2;
    return null;
}

pub fn main() !void {
    const a = lookup("alpha");
    const z = lookup("zeta");

    if (a) |v| {
        std.debug.print("[09] alpha={d}\n", .{v});
    }

    std.debug.print("[09] zeta default={d}\n", .{z orelse 999});
    std.debug.print("[09] alpha unwrap={d}\n", .{a.?});

    const result = blk: {
        const v = lookup("beta") orelse break :blk 0;
        break :blk v * 10;
    };
    std.debug.print("[09] result={d} z-null={}\n", .{ result, z == null });
}
```

## 10. エラーと error union

#### 解説

Zig のエラーは **値** です。エラー集合 `error{...}` を定義し、`!T` で
「エラー or T」の error union を表します。

```zig
const ParseError = error{ Empty, NotANumber, Overflow };

fn parse(s: []const u8) ParseError!u32 { ... }

const n = try parse(input);                      // エラー伝搬
const n2 = parse(input) catch 0;                 // 既定値
const n3 = parse(input) catch |err| handle(err); // 検査
```

本リポジトリの `runtime/error.zig` は `Error` 集合を 13 タグで定義し、
意味カテゴリ `Kind` enum と 1:1 で対応させています。`anyerror`
（→ 第 30 章）は「あらゆる error union を受け取る何でも箱」です。

`defer` と `errdefer`：

| 構文          | いつ走る                                   |
|---------------|--------------------------------------------|
| `defer X;`    | スコープ離脱時、**常に**。                 |
| `errdefer X;` | スコープが **エラーで** 離脱したときのみ。 |

```zig
errdefer self.alloc.free(owned_name);  // 登録に失敗したら名前解放
errdefer self.alloc.destroy(ns);       // 同じく ns ノード解放
try self.put(...);                     // 失敗するとここで上の 2 つが走る
```

#### 問題

独自の `error{ ... }` を定義し、文字列を正の整数として解析する関数を
作ってください。空文字、数字以外、オーバーフローをエラーにし、`try`、
`catch`、`catch |err|`、`defer`、`errdefer` を使って結果とエラー名を
表示してください。

#### 解答

```zig
const std = @import("std");

const ParseError = error{ Empty, NotANumber, Overflow };

fn parsePositive(s: []const u8) ParseError!u32 {
    if (s.len == 0) return ParseError.Empty;
    var n: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return ParseError.NotANumber;
        const digit: u32 = c - '0';
        if (n > (std.math.maxInt(u32) - digit) / 10) return ParseError.Overflow;
        n = n * 10 + digit;
    }
    return n;
}

fn doubleIt(s: []const u8) ParseError!u32 {
    const n = try parsePositive(s);
    if (n > std.math.maxInt(u32) / 2) return ParseError.Overflow;
    return n * 2;
}

pub fn main() !void {
    defer std.debug.print("[10] defer\n", .{});
    errdefer std.debug.print("[10] errdefer\n", .{});

    const fallback = doubleIt("xyz") catch @as(u32, 0);
    std.debug.print("[10] fallback={d}\n", .{fallback});

    const result = doubleIt("21") catch |err| blk: {
        std.debug.print("[10] err={s}\n", .{@errorName(err)});
        break :blk @as(u32, 0);
    };
    std.debug.print("[10] result={d}\n", .{result});

    std.debug.print("[10] 100*2={d}\n", .{try doubleIt("100")});
}
```

## 11. 制御構文

#### 解説

すべて **式** です。値を返す代入の右辺に書けます。

`if`:

```zig
const sign: []const u8 = if (x > 0) "+" else if (x < 0) "-" else "0";
```

`while` の **continue 節**：ループ末尾の `i += 1` を分離して書く形が
Zig 流です。`for` よりも本リポジトリは `while` を多用しています（条件
判定が複雑だから）。

```zig
var i: usize = 0;
while (i < args.len) : (i += 1) {
    ...
}
```

`for`：レンジ `0..n` とスライスの両方に使えます。インデックスは別
スロット。

```zig
for (words) |w| { ... }
for (words, 0..) |w, idx| { ... }
for (1..6) |n| { ... }   // Zig 0.11+ のレンジ for
```

`switch`：**網羅必須**。整数レンジ、enum、タグ付き union（→ 第 15 章）
すべて取れます。`else =>` でフォールバック、`unreachable` で不可能宣言
（→ 第 21 章）。

```zig
return switch (n) {
    0 => "zero",
    1...9 => "single digit",
    else => "large",
};
```

`switch` 内で **値を捕捉**：`|v|` で payload を、`|*p|` でポインタを。

#### 問題

`if` を式として使い、`while` で合計し、スライスの `for` とインデックス
付き `for` を使い、レンジ `for` で階乗を求めてください。整数レンジの
`switch` と enum の `switch` も使い、結果を表示してください。

#### 解答

```zig
const std = @import("std");

const Op = enum { add, sub, mul };

fn classify(n: i32) []const u8 {
    return switch (n) {
        0 => "zero",
        1...9 => "single digit",
        10...99 => "two digits",
        else => "large",
    };
}

pub fn main() !void {
    const x: i32 = 7;
    const sign = if (x > 0) "positive" else if (x < 0) "negative" else "zero";

    var i: u32 = 0;
    var sum: u32 = 0;
    while (i < 5) : (i += 1) sum += i;

    const words = [_][]const u8{ "alpha", "beta", "gamma" };
    for (words) |w| std.debug.print("[11] word={s}\n", .{w});
    for (words, 0..) |w, idx| std.debug.print("[11] #{d}={s}\n", .{ idx, w });

    var product: u32 = 1;
    for (1..6) |n| product *= @intCast(n);

    const op: Op = .mul;
    const label = switch (op) { .add => "+", .sub => "-", .mul => "*" };

    std.debug.print("[11] sign={s} sum={d} product={d}\n", .{ sign, sum, product });
    std.debug.print("[11] classes={s}/{s}/{s} op={s}\n", .{ classify(5), classify(42), classify(9999), label });
}
```

## 12. ラベル付きブロック

#### 解説

`label:` を付けたブロックは **値を返す式** です。`break :label value` で
脱出と値返しを兼ねます。本リポジトリの定番イディオム：

```zig
// main.zig: catch ハンドラに blk: で復帰値を作る
const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch blk: {
    @memcpy(msg_buf[509..512], "...");
    break :blk msg_buf[0..512];
};
```

> Zig はラベル付きループ（`outer:` のような labeled `for` / `while`）
> もサポートしていますが、本リポジトリでは labeled loop は使われて
> いません（`blk:` ブロックラベルのみ）。本書もブロックラベルのみを
> 扱います。

#### 問題

`blk: { break :blk value; }` を使って、時間帯から挨拶文字列を作って
ください。さらに `std.fmt.bufPrint` を `catch blk:` で受け、失敗時の
代替文字列を返す形も書いてください。最後にブロック内で複数の局所値
からスコアを作って表示してください。

#### 解答

```zig
const std = @import("std");

pub fn main() !void {
    const greeting: []const u8 = blk: {
        const hour: u8 = 9;
        if (hour < 12) break :blk "good morning";
        if (hour < 18) break :blk "good afternoon";
        break :blk "good evening";
    };

    var buf: [16]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "n={d}", .{99}) catch blk: {
        break :blk "fmt-overflow";
    };

    const score: i32 = blk: {
        const base: i32 = 10;
        const bonus: i32 = 3;
        const penalty: i32 = 1;
        break :blk base + bonus - penalty;
    };

    std.debug.print("[12] {s} {s} score={d}\n", .{ greeting, msg, score });
}
```

## 13. `struct` とメソッド

#### 解説

Zig の `struct` は名前付きフィールドの集合です。フィールドにデフォルト
値、メソッドとして任意の `fn`、定数として任意の `pub const` を持てます。
メソッドの第 1 引数は次のいずれか：

| シグネチャ       | 用途                                     |
|------------------|------------------------------------------|
| `self: T`        | 値で受ける（読み取り専用、コピーが渡る） |
| `self: *T`       | ポインタで受ける（書き換え可能）         |
| `self: *const T` | ポインタだが書き換え不可                 |

```zig
const Counter = struct {
    label: []const u8,
    count: u32 = 0,                       // デフォルト
    bumped_at_least_once: bool = false,

    pub fn init(label: []const u8) Counter {
        return .{ .label = label };       // .{...} は型推論
    }

    pub fn bump(self: *Counter) void {    // *T で書き換え可
        self.count += 1;
    }

    pub fn isFresh(self: Counter) bool {  // T で読み取り
        return self.count == 0;
    }
};
```

`init` / `deinit` 命名は本リポジトリ全域の慣例（`Tokenizer.init`、
`Env.init`、`ArenaGc.init` ...）。`init` の戻り値は **新しいインスタンス
そのもの** であり、ヒープ確保とは独立した概念です。

匿名 struct リテラル `.{ .field = value }` は型を **代入先 / 戻り値型 /
引数型** から推論します。`runtime/runtime.zig` の `Runtime.init` も
`return .{ .gpa = gpa, ... };` の形で書かれています。

> 構造体メソッドの引数として `anytype` を取る形（`fn describe(self,
> w: anytype) !void` のような Writer 受け）は、第 19 章で `anytype` を、
> 第 26 章で `std.Io.Writer` を導入したあとに自然に書けるようになります。
> 本章では `anytype` を使わず `std.debug.print` で完結させます。

#### 問題

ラベル、カウント、真偽値フラグを持つ `struct` を作ってください。
`init`、`self: *T` の更新メソッド、`self: T` の読み取りメソッド、
`self: *const T` の読み取りメソッドを定義し、メソッド呼び出しと
フィールドのデフォルト値を確認してください。

#### 解答

```zig
const std = @import("std");

const Counter = struct {
    label: []const u8,
    count: u32 = 0,
    bumped: bool = false,

    pub fn init(label: []const u8) Counter {
        return .{ .label = label };
    }

    pub fn bump(self: *Counter) void {
        self.count += 1;
        self.bumped = true;
    }

    pub fn isFresh(self: Counter) bool {
        return self.count == 0;
    }

    pub fn currentValue(self: *const Counter) u32 {
        return self.count;
    }
};

pub fn main() !void {
    var c = Counter.init("hits");
    c.bump();
    c.bump();
    const fresh: Counter = .{ .label = "fresh" };

    std.debug.print("[13] {s} count={d} bumped={} fresh?={} current={d}\n", .{ c.label, c.count, c.bumped, c.isFresh(), c.currentValue() });
    std.debug.print("[13] {s} count={d} fresh?={}\n", .{ fresh.label, fresh.count, fresh.isFresh() });
}
```

## 14. `enum`

#### 解説

`enum` の 3 形態：

```zig
const Phase = enum { parse, analysis, eval };       // ふつうの enum
const HeapTag = enum(u8) { string = 0, list = 3 };  // 整数バックエンド付き
const RawByte = enum(u8) { zero = 0, _, };          // 非網羅（_ で締める）
```

非網羅形式はバックエンド整数の **任意** ビットパターンを許容するので、
NaN ボクシングのように「タグそのものが値」のとき便利です。本リポ
ジトリの `Value` がまさにこの形：

```zig
pub const Value = enum(u64) {
    nil_val = NB_CONST_TAG | 0,
    true_val = NB_CONST_TAG | 1,
    false_val = NB_CONST_TAG | 2,
    _,                                    // 任意の u64 を許す
};
```

`@"identifier"` は **エスケープ識別子**。Zig 予約語と被る名前を
ユーザ定義で使いたいときに必須です：本リポジトリの
`HeapTag.@"volatile"` が代表例。

enum 関連の組込関数（第 06 章で「enum 関連は 14 章」と予告した分）：

| 組込関数       | 役割                                                   |
|----------------|--------------------------------------------------------|
| `@intFromEnum` | enum → 整数（バックエンド型）                         |
| `@enumFromInt` | 整数 → enum。範囲外は安全ビルドで panic               |
| `@tagName`     | タグ名を `[]const u8` で取得（フォーマット出力に便利） |

#### 問題

整数バックエンド付き enum と非網羅 enum を作ってください。`@intFromEnum`、
`@enumFromInt`、`@tagName` を使い、予約語と衝突するタグは `@"..."` で
書いてください。enum の `switch` が網羅されていることも確認してください。

#### 解答

```zig
const std = @import("std");

const HeapTag = enum(u8) {
    string = 0,
    symbol = 1,
    keyword = 2,
    list = 3,
    @"volatile" = 23,
};

const RawByte = enum(u8) { zero = 0, one = 1, _ };

pub fn main() !void {
    const t: HeapTag = .keyword;
    const t_num: u8 = @intFromEnum(t);
    const t_back: HeapTag = @enumFromInt(@as(u8, 23));
    const raw: RawByte = @enumFromInt(@as(u8, 99));

    const desc = switch (t) {
        .string => "string",
        .symbol => "symbol",
        .keyword => "keyword",
        .list => "list",
        .@"volatile" => "volatile",
    };

    std.debug.print("[14] tag={s} int={d} back={s} raw={d} desc={s}\n", .{ @tagName(t), t_num, @tagName(t_back), @intFromEnum(raw), desc });
}
```

## 15. タグ付き `union`

#### 解説

`union(enum)` は **タグ付き共用体**。タグ用 enum はコンパイラが自動生成
し、`switch` での網羅判定が効きます。本リポジトリの `Node`（解析後
AST）と `FormData`（読み取り後の生形）が代表例です。

```zig
const Node = union(enum) {
    integer: i64,
    name: []const u8,
    pair: struct { lhs: i64, rhs: i64 },
};

switch (n) {
    .integer => |v| ...,                  // payload 捕捉
    .name => |s| ...,
    .pair => |p| ...,
}
```

**`inline else` で全分岐共通の処理** を書くこともできます。本リポ
ジトリの `Node.loc()` がまさにこれ：

```zig
pub fn loc(self: Node) SourceLocation {
    return switch (self) {
        inline else => |n| n.loc,         // 各 payload の `.loc` を返す
    };
}
```

#### 問題

`union(enum)` で整数、文字列、ペア構造体を持つ値を表してください。
配列に複数 variant を入れ、`switch` の payload capture `|v|` で
分岐ごとに表示してください。タグごとのラベルを返すメソッドも作って
ください。余裕があれば、各 variant が同じ名前のサブフィールドを持つ
別 union を作り、`inline else => |payload| payload.loc` の形も
確認してください。

#### 解答

```zig
const std = @import("std");

const Node = union(enum) {
    integer: i64,
    name: []const u8,
    pair: Pair,

    const Pair = struct { lhs: i64, rhs: i64 };

    pub fn label(self: Node) []const u8 {
        return switch (self) {
            .integer => "integer",
            .name => "name",
            .pair => "pair",
        };
    }
};

const Located = union(enum) {
    integer: LocatedInt,
    name: LocatedName,

    const LocatedInt = struct { loc: u32, value: i64 };
    const LocatedName = struct { loc: u32, value: []const u8 };

    pub fn loc(self: Located) u32 {
        return switch (self) {
            inline else => |payload| payload.loc,
        };
    }
};

pub fn main() !void {
    const items = [_]Node{
        .{ .integer = 42 },
        .{ .name = "hello" },
        .{ .pair = .{ .lhs = 3, .rhs = 4 } },
    };

    for (items) |n| {
        switch (n) {
            .integer => |v| std.debug.print("[15] {s}: {d}\n", .{ n.label(), v }),
            .name => |s| std.debug.print("[15] {s}: {s}\n", .{ n.label(), s }),
            .pair => |p| std.debug.print("[15] {s}: {d},{d}\n", .{ n.label(), p.lhs, p.rhs }),
        }
    }

    const located: Located = .{ .name = .{ .loc = 123, .value = "x" } };
    std.debug.print("[15] located loc={d}\n", .{located.loc()});
}
```

## 16. `packed struct` / `extern struct` / `align(N)`

#### 解説

通常の `struct` はフィールド順とアラインを **コンパイラ任せ**。
レイアウトを制御したいときに 2 種類の修飾があります。

| 形式                | レイアウト規則                                 |
|---------------------|------------------------------------------------|
| `struct`            | コンパイラ任意（再配置・パディング自由）。     |
| `extern struct`     | C ABI と同じ。フィールド順・パディングが安定。 |
| `packed struct(uN)` | bit-precise。総ビット幅 = `uN`。               |

本リポジトリの `HeapHeader` は `extern struct`（GC が読むレイアウト
を固定）、`Flags` は `packed struct(u8)`（marked / frozen / 予約 6
ビットを u8 に詰める）。

```zig
pub const HeapHeader = extern struct {
    tag: u8,
    flags: Flags,

    pub const Flags = packed struct(u8) {
        marked: bool = false,
        frozen: bool = false,
        _pad: u6 = 0,
    };
};
```

`align(N)` 修飾は変数や型に対して **アラインメント要求** を付けます。
NaN ボックスは「ポインタが 8 バイト境界」を仮定して下位 3 ビットを
タグ用に取るので、対象の `var` に `align(8)` を要求するわけです。

#### 問題

`packed struct(u8)` で bool 2 個と padding を持つフラグを作り、それを
含む `extern struct` を作ってください。`@sizeOf`、`@alignOf`、
フィールド更新を確認し、`var x: u64 align(8)` のアドレスが 8 で割り
切れることを `@intFromPtr` で表示してください。

#### 解答

```zig
const std = @import("std");

const Flags = packed struct(u8) {
    marked: bool = false,
    frozen: bool = false,
    _pad: u6 = 0,
};

const Header = extern struct {
    tag: u8,
    flags: Flags,
};

pub fn main() !void {
    var h: Header = .{ .tag = 3, .flags = .{ .marked = true } };
    std.debug.print("[16] sizes {d}/{d} align={d}\n", .{ @sizeOf(Flags), @sizeOf(Header), @alignOf(Header) });
    std.debug.print("[16] tag={d} marked={} frozen={}\n", .{ h.tag, h.flags.marked, h.flags.frozen });
    h.flags.frozen = true;

    var aligned: u64 align(8) = 0xCAFEBABE;
    std.debug.print("[16] frozen={} addr%8={d}\n", .{ h.flags.frozen, @intFromPtr(&aligned) % 8 });
}
```

## 17. ポインタと `anyopaque`

#### 解説

Zig のポインタ：

| 形式         | 意味                                                                 |
|--------------|----------------------------------------------------------------------|
| `*T`         | 単一要素ポインタ。                                                   |
| `*const T`   | 読み取り専用。                                                       |
| `[*]T`       | many-item ポインタ（C の `T*`、長さ非保持）。                        |
| `[*]const T` | 読み取り専用 many-item。                                             |
| `?*T`        | nullable ポインタ。                                                  |
| `*anyopaque` | 型消去ポインタ（`void*` 相当）。`@ptrCast(@alignCast(...))` で復元。 |

参照外しは `p.*`、アドレス取得は `&x`。

`std.mem.Allocator` の vtable は `*anyopaque` を `ctx` で受け取り、
コールバック側で `@ptrCast(@alignCast(ctx))` 経由で具体型に戻す形。
本リポジトリの `runtime/gc/arena.zig` の `arenaAlloc` などが教科書例
です。

```zig
fn arenaAlloc(ctx: *anyopaque, len: usize, ...) ?[*]u8 {
    const self: *ArenaGc = @ptrCast(@alignCast(ctx));
    ...
}
```

ポインタ ↔ 整数往復（NaN ボックス）：

```zig
const addr: u64 = @intFromPtr(ptr);     // ポインタ → 整数
const back: *T = @ptrFromInt(addr);     // 整数 → ポインタ
```

#### 問題

`*u32` で値を書き換える関数、`*const u32` で読む関数、`[*]u8` の
many-item ポインタ、`?*T` の nullable ポインタ、`@intFromPtr` /
`@ptrFromInt` の往復を試してください。さらに `*anyopaque` を受け取り、
`@ptrCast(@alignCast(ctx))` で具体型に戻してフィールドを更新する関数
を書いてください。

#### 解答

```zig
const std = @import("std");

fn bumpThrough(p: *u32) void {
    p.* += 1;
}

fn readOnly(p: *const u32) u32 {
    return p.*;
}

const Counter = struct {
    n: u32,

    fn bump(ctx: *anyopaque) void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.n += 1;
    }
};

pub fn main() !void {
    var x: u32 = 10;
    bumpThrough(&x);
    bumpThrough(&x);

    var bytes = [_]u8{ 10, 20, 30 };
    const many: [*]u8 = &bytes;
    many[1] = 99;

    var maybe: ?*u32 = &x;
    if (maybe) |p| p.* += 1;
    maybe = null;

    const addr = @intFromPtr(&x);
    const back: *u32 = @ptrFromInt(addr);

    var ctr: Counter = .{ .n = 0 };
    Counter.bump(&ctr);
    Counter.bump(&ctr);

    std.debug.print("[17] x={d} read={d} bytes={any} maybe-null={}\n", .{ x, readOnly(&x), bytes, maybe == null });
    std.debug.print("[17] addr%align={d} back={d} ctr={d}\n", .{ addr % @alignOf(u32), back.*, ctr.n });
}
```

## 18. 関数ポインタと vtable

#### 解説

関数定義の基本：

```zig
fn name(arg1: T1, arg2: T2) ReturnT { ... }
pub fn name(...) ReturnT { ... }     // モジュール外から見える
```

関数ポインタ型は **`*const fn(args) Return`** です：

```zig
pub const BuiltinFn = *const fn (
    rt: *Runtime,
    env: *Env,
    args: []const Value,
    loc: SourceLocation,
) anyerror!Value;
```

これを構造体フィールドに置けば「**vtable**」になります。本リポジトリの
`runtime/dispatch.zig`：

```zig
pub const VTable = struct {
    callFn: CallFn,
    valueTypeKey: ValueTypeKeyFn,
};
```

**Layer 0 が型だけを定義し、Layer 1 が関数を起動時に流し込む** —
これが本リポジトリのアーキテクチャ層分離の中心装置です（ROADMAP §4.1
zone deps）。

#### 問題

足し算・引き算の関数を作り、`*const fn (i32, i32) i32` の型エイリアス
にしてください。関数ポインタを持つ vtable struct、関数ポインタを引数
に取る `applyTwice`、条件式で選んだ関数ポインタを使って結果を表示して
ください。

#### 解答

```zig
const std = @import("std");

fn add(a: i32, b: i32) i32 {
    return a + b;
}

fn sub(a: i32, b: i32) i32 {
    return a - b;
}

const BinaryOp = *const fn (i32, i32) i32;

const VTable = struct {
    add: BinaryOp,
    sub: BinaryOp,
};

fn applyTwice(op: BinaryOp, a: i32, b: i32) i32 {
    const x = op(a, b);
    return op(x, b);
}

pub fn main() !void {
    const vt: VTable = .{ .add = add, .sub = sub };
    const f: BinaryOp = if (true) add else sub;

    std.debug.print("[18] add={d} sub={d}\n", .{ vt.add(2, 3), vt.sub(10, 4) });
    std.debug.print("[18] twice={d}/{d} f={d}\n", .{ applyTwice(add, 1, 1), applyTwice(sub, 10, 1), f(7, 8) });
}
```

## 19. `comptime` / `inline for` / `anytype`

#### 解説

`comptime` は「**コンパイル時に評価**」を表すキーワード。

- 値: `const SIZE = comptime @sizeOf(u64) * 2;`
- 型パラメータ: `fn maxOf(comptime T: type, a: T, b: T) T`
- フォーマット文字列: `comptime fmt: []const u8`（`std.fmt.bufPrint` の形）
- `comptime { ... }` ブロック: モジュール内のアサーション。本リポジトリ
  の `Cons` には `comptime { std.debug.assert(@alignOf(Cons) >= 8); }` が
  あり、ヒープ確保がアライン要件を満たすことをコンパイル時に保証します。

`inline for` は **コンパイル時既知** の配列を **アンロール** します。
本リポジトリの primitive 登録ループ：

```zig
inline for (ENTRIES) |it| {
    try registerOne(env, rt, it.name, it.handler);
}
```

これは「`ENTRIES` の要素ごとにそのままループ本体を展開する」ので、
ループ変数も型も comptime で固定されます。

`anytype` は **ad-hoc ジェネリクス**：呼び出し元の型を後付けで受け取る
パラメータ。本リポジトリの典型例は 2 つ：

- `args: anytype` — `std.fmt.bufPrint(buf, fmt, args)` に転送する
  ためのタプル受け（`runtime/error.zig` の `setErrorFmt`）
- `ptr: anytype` — 任意のポインタ型を受けて `@intFromPtr` で整数化
  （`runtime/value.zig` の `Value.encodeHeapPtr(ht, ptr: anytype)`）

`comptime pred: fn (a: f64, b: f64) bool` のように **関数を comptime
引数で受け取る** 形も `lang/primitive/math.zig` の `pairwise` で使われ
ています。型制約は「呼び出し側が実際に使う形」で実質的に決まる（いわゆる
duck typing）ので、コンパイラはモノモルフ化のたびに型を確定させます。

> `std.Io.Writer` を `anytype` 経由で受け取る形は本リポジトリでも
> 一部使われていますが（テストで `*Writer` を渡しつつ `.fixed(&buf)` を
> 受ける）、本書では Writer の本格紹介を第 26 章に置いた都合で、
> 本章では Writer を扱わず `args: anytype` のパターンに集中します。

#### 問題

`comptime T: type` の最大値関数、`comptime pred: fn (...) bool` を
受ける隣接ペア検査関数、`args: anytype` を `std.fmt.bufPrint` に転送
する関数、`ptr: anytype` を受けて `@intFromPtr` する関数を作って
ください。comptime 既知のエントリ配列を `inline for` で表示し、
`comptime { std.debug.assert(...) }` のブロックも 1 つ書いてください。

#### 解答

```zig
const std = @import("std");

fn maxOf(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}

fn allPairs(comptime T: type, items: []const T, comptime pred: fn (a: T, b: T) bool) bool {
    if (items.len < 2) return true;
    var i: usize = 0;
    while (i + 1 < items.len) : (i += 1) {
        if (!pred(items[i], items[i + 1])) return false;
    }
    return true;
}

fn lessThan(a: i32, b: i32) bool {
    return a < b;
}

fn formatToBuf(buf: []u8, comptime fmt: []const u8, args: anytype) ![]u8 {
    return std.fmt.bufPrint(buf, fmt, args);
}

fn addressOf(ptr: anytype) usize {
    return @intFromPtr(ptr);
}

const Entry = struct { name: []const u8, value: i32 };
const ENTRIES = [_]Entry{
    .{ .name = "one", .value = 1 },
    .{ .name = "two", .value = 2 },
    .{ .name = "three", .value = 3 },
};

comptime {
    std.debug.assert(@sizeOf(u64) == 8);
}

pub fn main() !void {
    const SIZE = comptime @sizeOf(u64) * 2;
    const sorted = [_]i32{ 1, 2, 3, 4 };
    const unsorted = [_]i32{ 1, 3, 2 };

    std.debug.print("[19] size={d} max={d}/{d}\n", .{ SIZE, maxOf(i32, 3, 7), maxOf(f64, 1.5, 0.9) });
    std.debug.print("[19] pairs={}/{}\n", .{ allPairs(i32, &sorted, lessThan), allPairs(i32, &unsorted, lessThan) });

    inline for (ENTRIES) |it| {
        std.debug.print("[19] {s}={d}\n", .{ it.name, it.value });
    }

    var buf: [64]u8 = undefined;
    const out = try formatToBuf(&buf, "name={s} count={d}", .{ "alpha", 7 });
    const addr = addressOf(&buf);
    std.debug.print("[19] {s} addr%align={d}\n", .{ out, addr % @alignOf(@TypeOf(buf)) });
}
```

## 20. マルチライン文字列

#### 解説

`\\` で始まる行を連ねると、その行の改行込みで一つの文字列になります。
**エスケープ処理されない**（`\n` は 2 文字）のがポイント。

```zig
const HELP =
    \\Usage: cljw [options] [<file.clj> | -]
    \\  -e, --eval <expr>  ...
    \\
;
```

本リポジトリの `main.zig` のヘルプ表示はこの形です。長文 SQL や生成
テンプレートにも便利です。

#### 問題

`\\` で始まるマルチライン文字列を定義し、長さと本文を表示してください。
内部の `\n` が改行ではなく 2 文字として扱われることが分かる行も出力
してください。

#### 解答

```zig
const std = @import("std");

const HELP =
    \\Usage: demo [options]
    \\  -e, --eval <expr>
    \\  -h, --help
    \\
;

pub fn main() !void {
    std.debug.print("[20] len={d}\n", .{HELP.len});
    std.debug.print("[20] body:\n{s}", .{HELP});
    std.debug.print("[20] literal \\n stays two bytes\n", .{});
}
```

## 21. `undefined` と `unreachable`

#### 解説

`undefined` は **「あとで埋めるから初期化しないで」** のプレースホルダ
です。バッファを `bufPrint` などで全面上書きする場合、ゼロ初期化を
省けるので速度を稼げます。

```zig
var buf: [32]u8 = undefined;
const out = try std.fmt.bufPrint(&buf, ...);
```

`unreachable` は **「ここには到達しない」契約**。debug ビルドでは到達
すると panic、ReleaseFast では未定義動作（最適化のヒント）。本リポ
ジトリでは **網羅 switch のフォールバック** に多用されます：

```zig
const tag_base: u64 = switch (group) {
    0 => NB_HEAP_TAG_A,
    1 => NB_HEAP_TAG_B,
    2 => NB_HEAP_TAG_C,
    3 => NB_HEAP_TAG_D,
    else => unreachable,                 // group は u2 由来なので 0..3
};
```

#### 問題

`undefined` の固定バッファに `std.fmt.bufPrint` で文字列を書いて表示
してください。enum と `switch` を使い、呼び出し側の契約外の値では
`else => unreachable` になる関数を作ってください。ただし panic する
入力は実行しないでください。

#### 解答

```zig
const std = @import("std");

const Group = enum(u8) { a, b, c, d };

fn groupName(g: Group) []const u8 {
    return switch (g) {
        .a => "Group A",
        .b => "Group B",
        .c => "Group C",
        .d => "Group D",
    };
}

fn outOfBand(g: u8) []const u8 {
    return switch (g) {
        0...3 => groupName(@enumFromInt(g)),
        else => unreachable,
    };
}

pub fn main() !void {
    var buf: [32]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf, "n={d}", .{1234});
    std.debug.print("[21] len={d} value={s}\n", .{ out.len, out });
    std.debug.print("[21] valid={s}\n", .{outOfBand(2)});
    std.debug.print("[21] invalid input is intentionally not called\n", .{});
}
```

## 22. `threadlocal var`

#### 解説

スレッドごとに独立したインスタンスを持つグローバル変数。
`runtime/error.zig` の `last_error` / `call_stack` / `msg_buf` が本
リポジトリの主な用途です：

```zig
threadlocal var last_error: ?Info = null;
threadlocal var msg_buf: [512]u8 = undefined;
threadlocal var call_stack: [max_call_depth]StackFrame =
    [_]StackFrame{.{}} ** max_call_depth;
```

Phase 1 はシングルスレッドですが、API シグネチャに `*Info` を渡し
回らずに済むので、エラー発生地点と捕捉地点が遠い場合に便利です。
Phase 15 で並列化したとき、ロックを足さずにスレッドごとに自然分離
されるのも利点。

#### 問題

`threadlocal var` の深さカウンタと最後のメッセージ `?[]const u8` を
作ってください。`enter` と `leave` の関数で値を更新し、`orelse` を
使って null 時の表示も確認してください。

#### 解答

```zig
const std = @import("std");

threadlocal var depth: u32 = 0;
threadlocal var last_msg: ?[]const u8 = null;

fn enter(name: []const u8) void {
    depth += 1;
    last_msg = name;
    std.debug.print("[22] enter {s} depth={d}\n", .{ name, depth });
}

fn leave() void {
    std.debug.print("[22] leave depth={d}\n", .{depth});
    depth -= 1;
}

pub fn main() !void {
    std.debug.print("[22] before {s}\n", .{last_msg orelse "(null)"});
    enter("read");
    enter("eval");
    leave();
    leave();
    std.debug.print("[22] after {s}\n", .{last_msg orelse "(null)"});
}
```

## 23. アロケータ

#### 解説

Zig には **グローバル `malloc` がありません**。すべての確保は
明示的な `std.mem.Allocator` 引数を取ります。本リポジトリで実際に
登場するアロケータ：

| 種類                      | 役割                                                               |
|---------------------------|--------------------------------------------------------------------|
| `std.heap.ArenaAllocator` | バルク解放。本リポジトリの per-eval arena の中核                   |
| `std.heap.page_allocator` | OS ページを直接確保するバッキング。ArenaAllocator の下敷きに使う   |
| `init.gpa` / `init.arena` | `std.process.Init`（Juicy Main、第 26 章）が提供する同種アロケータ |
| `std.testing.allocator`   | テスト時のリーク検出器                                             |

主要 API：

```zig
const buf = try alloc.alloc(u8, n);    // []T を確保
defer alloc.free(buf);

const t = try alloc.create(MyStruct);  // *T を確保
defer alloc.destroy(t);

const owned = try alloc.dupe(u8, src); // スライスを複製
defer alloc.free(owned);
```

`ArenaAllocator` はバッキングアロケータの上に「**まとめて解放**」を
重ねる薄いラッパーです。`runtime/gc/arena.zig` の `ArenaGc` がさらに
統計を取る vtable を被せたものです。

> Zig 0.16 では旧 `std.heap.GeneralPurposeAllocator` が
> `std.heap.DebugAllocator` に改名されましたが、**本リポジトリは
> どちらも使っていません**（GPA は `std.process.Init.gpa` 経由でしか
> 触りません）。本書もこの方針に従うので、本章と次章の問題では
> `page_allocator` を `ArenaAllocator` のバッキングに使う形に統一して
> います。

#### 問題

`std.heap.ArenaAllocator` を `std.heap.page_allocator` で初期化し、
`defer arena.deinit()` してください。`alloc.alloc`、`alloc.free`、
`alloc.dupe`、`alloc.create`、`alloc.destroy` を使い、optional ポインタ
で連結した小さなリストを作って合計を表示してください。追加で `test`
ブロックを書き、`std.testing.allocator` でも小さな `dupe` / `free`
を確認してください。`std.heap.DebugAllocator` や旧
`GeneralPurposeAllocator` は使わないでください。

#### 解答

```zig
const std = @import("std");

const Cons = struct {
    head: i32,
    tail: ?*Cons,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const buf = try alloc.alloc(u8, 8);
    defer alloc.free(buf);
    var i: usize = 0;
    while (i < buf.len) : (i += 1) buf[i] = '*';

    const owned = try alloc.dupe(u8, "hello");
    defer alloc.free(owned);

    const c1 = try alloc.create(Cons);
    defer alloc.destroy(c1);
    c1.* = .{ .head = 1, .tail = null };
    const c2 = try alloc.create(Cons);
    defer alloc.destroy(c2);
    c2.* = .{ .head = 2, .tail = c1 };
    const c3 = try alloc.create(Cons);
    defer alloc.destroy(c3);
    c3.* = .{ .head = 3, .tail = c2 };

    var node: ?*Cons = c3;
    var sum: i32 = 0;
    while (node) |n| {
        sum += n.head;
        node = n.tail;
    }

    std.debug.print("[23] buf={s} owned={s} sum={d}\n", .{ buf, owned, sum });
}

test "std.testing.allocator dupe/free" {
    const alloc = std.testing.allocator;
    const owned = try alloc.dupe(u8, "test");
    defer alloc.free(owned);
    try std.testing.expect(std.mem.eql(u8, owned, "test"));
}
```

## 24. `ArrayList` / `StringHashMapUnmanaged` / `array_hash_map.String`

#### 解説

Zig 0.16 のコレクションは **「unmanaged」がデフォルト** ：自分の中に
アロケータを保持せず、操作のたびに引数で受け取ります。これにより
複数のコレクションが同じアロケータを共有しても重複保持しません。

```zig
var list: std.ArrayList(i32) = .empty;
defer list.deinit(alloc);
try list.append(alloc, 10);
const popped = list.pop();             // ?T を返す（空なら null）

var map: std.StringHashMapUnmanaged(u32) = .empty;
defer map.deinit(alloc);
try map.put(alloc, "key", 42);
if (map.get("key")) |v| { ... }
```

> Zig 0.16 では `std.ArrayList(T)` 自体が「unmanaged」を指すように
> 改められ、`std.ArrayListUnmanaged` は **deprecated エイリアス** に
> なりました（lint ゲート `no_deprecated` で検出されます）。本書と
> ソースはすべて新しい `ArrayList` を使う統一にしてあります。

本リポジトリは：

- `std.array_hash_map.String(*Keyword)` — `KeywordInterner.table`
  （挿入順を保つ array hash map。`StringArrayHashMapUnmanaged` は
  この別名で deprecated）
- `std.StringHashMapUnmanaged(*Var)` — `Namespace.vars`
- `std.AutoHashMapUnmanaged(*const Var, Value)` — `BindingFrame.bindings`

の 3 種類を主に使います（→ ROADMAP §13 で `StringHashMap` ではなく
`Unmanaged` を推奨）。

#### 問題

Arena の allocator を使い、`std.ArrayList(i32) = .empty` に `append`
して `pop` と `items` を表示してください。`std.StringHashMapUnmanaged(u32)`
に 3 件入れ、`count`、`get`、`iterator` で結果を表示してください。上に
出ている `std.array_hash_map.String(V)` と `std.AutoHashMapUnmanaged(K, V)`
も小さく使ってください。deprecated な `std.ArrayListUnmanaged` や
`StringArrayHashMapUnmanaged` は使わないでください。

#### 解答

```zig
const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(alloc);
    try list.append(alloc, 10);
    try list.append(alloc, 20);
    try list.append(alloc, 30);
    const last = list.pop();

    var map: std.StringHashMapUnmanaged(u32) = .empty;
    defer map.deinit(alloc);
    try map.put(alloc, "alpha", 1);
    try map.put(alloc, "beta", 2);
    try map.put(alloc, "gamma", 3);

    std.debug.print("[24] popped={?d} len={d} items={any}\n", .{ last, list.items.len, list.items });
    std.debug.print("[24] count={d}\n", .{map.count()});
    if (map.get("beta")) |v| std.debug.print("[24] beta={d}\n", .{v});

    var it = map.iterator();
    while (it.next()) |e| {
        std.debug.print("[24] {s}->{d}\n", .{ e.key_ptr.*, e.value_ptr.* });
    }

    var ordered: std.array_hash_map.String(u32) = .empty;
    defer ordered.deinit(alloc);
    try ordered.put(alloc, "first", 1);
    try ordered.put(alloc, "second", 2);
    std.debug.print("[24] ordered.count={d}\n", .{ordered.count()});

    var auto: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    defer auto.deinit(alloc);
    try auto.put(alloc, 1, "one");
    try auto.put(alloc, 2, "two");
    if (auto.get(2)) |v| std.debug.print("[24] auto.get(2)={s}\n", .{v});
}
```

## 25. `StaticStringMap`

#### 解説

**コンパイル時に確定する** 文字列キー → 値の対応表。実行時のハッシュ
計算なしでルックアップできるので、トークナイザのキーワードや特殊
フォーム判定で使います。

```zig
const OPS = std.StaticStringMap(Op).initComptime(.{
    .{ "+", .add },
    .{ "-", .sub },
    .{ "*", .mul },
});

if (OPS.get(sym)) |op| { ... }
```

#### 問題

`std.StaticStringMap` と `initComptime` で記号から enum への表を作って
ください。`get` が返す `?V` を `if` でアンラップし、`@tagName` で
分類名を表示してください。`kvs.len` も表示してください。

#### 解答

```zig
const std = @import("std");

const Op = enum { add, sub, mul, div };

const OPS = std.StaticStringMap(Op).initComptime(.{
    .{ "+", .add },
    .{ "-", .sub },
    .{ "*", .mul },
    .{ "/", .div },
});

fn classify(sym: []const u8) []const u8 {
    return if (OPS.get(sym)) |op| @tagName(op) else "unknown";
}

pub fn main() !void {
    const samples = [_][]const u8{ "+", "*", "%", "/", "?" };
    for (samples) |s| {
        std.debug.print("[25] {s} -> {s}\n", .{ s, classify(s) });
    }
    std.debug.print("[25] size={d}\n", .{OPS.kvs.len});
}
```

## 26. `std.Io.Writer`

#### 解説

Zig 0.16 で `std.io` → `std.Io` に大移動しました。`std.io.AnyWriter` は
廃止。**書き込み API は `*std.Io.Writer` 一本** です：

```zig
const Writer = std.Io.Writer;

var stdout_buf: [4096]u8 = undefined;
var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
const stdout = &stdout_writer.interface;       // type-erased *Writer

try stdout.print("hello {s}\n", .{"world"});
try stdout.writeAll("raw bytes\n");
try stdout.flush();                             // 忘れると出ない
```

`io` は **`std.Io`** 型で、ファイル / ソケット / バッファのバックエンド
を抽象化します。プロセス用のものは **Juicy Main** で受け取れます：

```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;          // std.Io
    const gpa = init.gpa;        // 汎用アロケータ
    const arena = init.arena.allocator();  // プロセス寿命の arena
    var args = init.minimal.args.iterate();
    ...
}
```

本リポジトリの `src/main.zig` がこの形ちょうど。テスト内で書き出し先を
バッファにしたいときは `var w: Writer = .fixed(&buf);` を使えば
アロケータ不要で完結します。

#### 問題

`pub fn main(init: std.process.Init) !void` を使い、
`std.Io.File.stdout().writer(init.io, &buf).interface` から
`*std.Io.Writer` を得てください。`writeAll`、`print`、ヘルパー関数への
writer 渡し、`.fixed(&buf)` の固定バッファ writer、最後の `flush()` を
確認してください。

#### 解答

```zig
const std = @import("std");
const Writer = std.Io.Writer;

fn writeReport(w: *Writer, label: []const u8, value: i32) Writer.Error!void {
    try w.print("[26] {s} = {d}\n", .{ label, value });
}

pub fn main(init: std.process.Init) !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("[26] hello\n");
    try writeReport(stdout, "alpha", 100);
    try writeReport(stdout, "beta", 200);

    var scratch: [64]u8 = undefined;
    var fixed: Writer = .fixed(&scratch);
    try fixed.print("captured={d}", .{42});
    try stdout.print("[26] fixed: {s}\n", .{fixed.buffered()});

    try stdout.flush();
}
```

## 27. テストブロック

#### 解説

**テストはコードと同じファイルに書く** のが Zig 流。`zig test` で
すべての `test "name" { ... }` ブロックが走ります。本リポジトリは
**`std.testing.expect(cond)` だけ** を使う方針（grep でも他は出てきません）：

```zig
test "add: small integers" {
    try std.testing.expect(add(2, 3) == 5);
    try std.testing.expect(add(-1, 1) == 0);
}
```

`try` を前置するのは、条件が偽のときアサーション関数がエラーを返す
ためです。テスト関数の戻り値型は暗黙に error union 扱い。

> Zig stdlib には `std.testing.expectEqual(a, b)` /
> `std.testing.expectEqualStrings(a, b)` / `std.testing.expectError(...)`
> など便利な比較関数も用意されていますが、**本リポジトリでは `expect`
> だけ** を使う統一が採られています。本書もこの方針に従います。

本リポジトリは `src/main.zig` の最後に：

```zig
test {
    _ = @import("runtime/value.zig");
    _ = @import("runtime/error.zig");
    ...
}
```

を置き、`zig build test` 一発で全テストを発見させる構成です。

#### 問題

足し算関数と `comptime T: type` の最大値関数を作ってください。`main`
では `std.debug.assert` で確認し、`test "..." {}` では
`try std.testing.expect(...)` だけで同じ性質を確認してください。
`expectEqual`、`expectEqualStrings`、`expectError` は使わず、`zig run`
と `zig test` の両方で動かしてください。

#### 解答

```zig
const std = @import("std");

fn add(a: i32, b: i32) i32 {
    return a + b;
}

fn maxOf(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}

pub fn main() !void {
    std.debug.assert(add(2, 3) == 5);
    std.debug.assert(maxOf(i32, 7, 4) == 7);
    std.debug.assert(maxOf(f64, 1.5, 2.5) == 2.5);
    std.debug.print("[27] asserts passed\n", .{});
}

test "add" {
    try std.testing.expect(add(2, 3) == 5);
    try std.testing.expect(add(-1, 1) == 0);
}

test "maxOf" {
    try std.testing.expect(maxOf(i32, 7, 4) == 7);
    try std.testing.expect(maxOf(f64, 1.5, 2.5) == 2.5);
}
```

## 28. `std.mem` と `@memcpy`

#### 解説

スライス操作の標準関数。argv 解析（`main.zig`）やトークン読み取り
（`tokenizer.zig`）で多用します：

| 関数                                 | 役割                           |
|--------------------------------------|--------------------------------|
| `std.mem.eql(T, a, b)`               | 2 つのスライスが等しいか       |
| `std.mem.startsWith(T, hay, prefix)` | `prefix` から始まるか          |
| `std.mem.find(T, hay, needle)`       | 部分列の最初の位置（`?usize`） |
| `std.mem.findScalar(T, hay, c)`      | 単一要素の最初の位置           |
| `@memcpy(dst, src)`                  | バッファコピー（同サイズ必須） |

> Zig 0.16 で `std.mem.indexOf` 系は `find*` に改名されました。旧名は
> deprecated エイリアスとして残っており、`zig build lint` の
> `no_deprecated` で検出されます。本書とソースは新名に統一済みです。

```zig
if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) { ... }
```

> Zig には `@memset(slice, byte)` も存在しますが、本リポジトリでは
> 使われていない（バッファ初期化は `dupe` / `bufPrint` 経由で済むこと
> が多い）ので、本書では扱いません。

#### 問題

`std.mem.eql`、`std.mem.startsWith`、`std.mem.find`、`std.mem.findScalar`
を使って文字列スライスを調べてください。`?usize` は `if (opt) |i|` で
表示してください。最後に固定バッファへ `@memcpy` で短い文字列を書き
込んで表示してください。

#### 解答

```zig
const std = @import("std");

pub fn main() !void {
    const a = "hello";
    const b = "hello";
    const c = "world";

    std.debug.print("[28] eql={}/{}\n", .{ std.mem.eql(u8, a, b), std.mem.eql(u8, a, c) });
    std.debug.print("[28] starts={}/{}\n", .{ std.mem.startsWith(u8, a, "hel"), std.mem.startsWith(u8, a, "wor") });

    if (std.mem.findScalar(u8, "abcdef", 'd')) |i| {
        std.debug.print("[28] findScalar={d}\n", .{i});
    }
    if (std.mem.find(u8, "the quick brown fox", "brown")) |i| {
        std.debug.print("[28] find={d}\n", .{i});
    }

    var buf: [8]u8 = .{ '.', '.', '.', '.', '.', '.', '.', '.' };
    @memcpy(buf[0..3], "Zig");
    std.debug.print("[28] buf={s}\n", .{&buf});
}
```

## 29. `std.fmt`

#### 解説

文字列の整形・解析。本リポジトリでは：

- `std.fmt.bufPrint(buf, fmt, args)` — 固定バッファに書き出して
  `[]u8` を返す。`runtime/error.zig` の `setErrorFmt` の中核。
- `std.fmt.parseInt(T, s, base)` — トークナイザの整数リテラル解析。
- `std.fmt.parseFloat(T, s)` — 同じく浮動小数。

```zig
const msg = std.fmt.bufPrint(&buf, "{s}: count={d}", .{label, n}) catch ...;
const n = try std.fmt.parseInt(i64, "12345", 10);
const f = try std.fmt.parseFloat(f64, "2.71828");
```

フォーマット指定子の代表：

| 指定        | 意味                                                              |
|-------------|-------------------------------------------------------------------|
| `{}`        | デフォルト（型ごとに自動）。                                      |
| `{d}`       | 整数 / 浮動小数を 10 進。                                         |
| `{s}`       | `[]const u8` を文字列として。                                     |
| `{x}` `{X}` | 16 進（`X` は大文字）。                                           |
| `{any}`     | デバッグ表示。                                                    |
| `{f}`       | 型のカスタム `format` メソッドを呼ぶ（`{}` だと曖昧と言われる）。 |
| `{:0>16}`   | 幅 16・`0` パディング。                                           |

#### 問題

`std.fmt.bufPrint`、`std.fmt.allocPrint`、`std.fmt.parseInt`、
`std.fmt.parseFloat` を使ってください。10 進整数、16 進整数、浮動
小数を解析し、フォーマット指定子 `{}`、`{s}`、`{d}`、`{x}`、`{X}`、
`{any}`、`{?d}`、`{:0>16}`、`{d:.2}` を含めて表示してください。失敗
する `parseInt` は error union を `if (result) |v| ... else |err| ...`
で処理してください。

#### 解答

```zig
const std = @import("std");

pub fn main() !void {
    var buf: [64]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "{s}: count={d} ratio={d:.2}", .{ "demo", 17, 0.4321 });
    const owned = try std.fmt.allocPrint(std.heap.page_allocator, "owned {s} {}", .{ "flag", true });
    defer std.heap.page_allocator.free(owned);

    const n_dec = try std.fmt.parseInt(i64, "12345", 10);
    const n_hex = try std.fmt.parseInt(u64, "DEADBEEF", 16);
    const f = try std.fmt.parseFloat(f64, "2.71828");
    const maybe: ?u32 = 99;
    const pair = .{ @as(u8, 1), @as(u8, 2) };

    std.debug.print("[29] {s}\n", .{msg});
    std.debug.print("[29] {s}\n", .{owned});
    std.debug.print("[29] dec={d} hex=0x{x}/0x{X} padded={:0>16} float={d}\n", .{ n_dec, n_hex, n_hex, n_hex, f });
    std.debug.print("[29] optional={?d} any={any}\n", .{ maybe, pair });

    const bad = std.fmt.parseInt(i64, "not-a-number", 10);
    if (bad) |v| {
        std.debug.print("[29] unexpected={d}\n", .{v});
    } else |err| {
        std.debug.print("[29] err={s}\n", .{@errorName(err)});
    }
}
```

## 30. `@embedFile` / `anyerror` / `@errorName`

#### 解説

**`@embedFile("path")`** は指定ファイルの中身を **コンパイル時に**
`[]const u8` として埋め込む組込関数。本リポジトリでは
`clj/clojure/core.clj` を `cljw` バイナリに同梱するために使っています：

```zig
pub const CORE_SOURCE: []const u8 = @embedFile("clj/clojure/core.clj");
```

これによりインストール後、ソースツリーがディスク上になくてもブート
ストラップが動きます。

**`anyerror`** は「いずれかのエラー集合に属する任意のエラー値」を表す
特別な型。`Reader` / `Analyzer` / `TreeWalk` などフェーズが違っても
同じ `try` チェーンで運べるよう、本リポジトリの公開 API 戻り値型は
`anyerror!Value` に揃えてあります（`BuiltinFn` も同じ）：

```zig
pub const BuiltinFn = *const fn (
    rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation,
) anyerror!Value;
```

**`@errorName(err)`** はエラー値の **タグ名文字列** です。`main.zig` の
最終フォールバックは `Info` が無いとき `@errorName(err)` を使って
何かしら出力します。

```zig
catch |err| {
    try stderr.print("Error: {s}\n", .{@errorName(err)});
    std.process.exit(1);
}
```

#### 問題

自分自身の `.zig` ファイルを `@embedFile` で埋め込み、長さと先頭の
一部を表示してください。別々の error set を 2 つ定義し、`anyerror!void`
の関数からどちらのエラーも返せることを `catch |err|` と `@errorName`
で確認してください。先頭表示の長さ制限には `@min` を使ってください。

#### 解答

```zig
const std = @import("std");

const SELF_SOURCE: []const u8 = @embedFile("30_embed_anyerror.zig");

const ParseError = error{ Empty, NotANumber };
const IoError = error{ Closed };

fn either(flag: bool) anyerror!void {
    if (flag) return ParseError.Empty;
    return IoError.Closed;
}

pub fn main() !void {
    std.debug.print("[30] len={d}\n", .{SELF_SOURCE.len});
    std.debug.print("[30] head={s}\n", .{SELF_SOURCE[0..@min(60, SELF_SOURCE.len)]});

    either(true) catch |err| std.debug.print("[30] true err={s}\n", .{@errorName(err)});
    either(false) catch |err| std.debug.print("[30] false err={s}\n", .{@errorName(err)});

    const e: ParseError = ParseError.NotANumber;
    std.debug.print("[30] tag={s}\n", .{@errorName(e)});
}
```

---



## 付録: 本リポジトリで扱わない Zig 機能

学習効率のため、ここまでの章は **本リポジトリの Zig コードに登場する
ものだけ** を扱いました。逆に **登場しないので本書では触れない** Zig
機能（参考まで）：

- `async` / `await` / `anyframe` — 非同期。
- `noasync` / `suspend` / `resume`。
- `asm volatile { ... }` — インラインアセンブリ。
- `usingnamespace` — 名前空間の継ぎ足し（ROADMAP §13 で禁止）。
- `opaque {}` — 不透明型宣言（`anyopaque` は使うが `opaque` は未使用）。
- `noalias` / `callconv()` / `export` / `noinline` — ABI まわり。
- `@branchHint` / `@prefetch` / `@call` — マイクロ最適化系。
- `@cImport` / C interop — Wasm Component で隔離する方針（Phase 14+）。

これらが必要になる時点で、対応する ADR と章を `docs/ja/` に追加する
方針です。

## 付録: 動作環境

- Zig: **0.16.0** （`flake.nix` でピン留め）。
- 検証コマンド: 各章の解答に対して `zig run <file>`、第 27 章のみ
  `zig test <file>`、第 0b 章のみ `zig build --build-file <file> run`。
- 全章の解答が Mac (aarch64-darwin) でグリーン確認済み。
