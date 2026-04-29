# learn_zig — ClojureWasm に登場する Zig 0.16.0 を基礎から

> 本リポジトリ（`cw-from-scratch` ブランチ）の Zig ソース（`build.zig` /
> `build.zig.zon` / `src/**/*.zig`、合計約 9,100 行）を **隅々まで** 読みきる
> ために必要な Zig 0.16.0 の文法・型・組込関数・標準ライブラリを、
> 登場順ではなく **教科書順** に並べ直した補助教材です。
>
> Phase 4 開始前のコードリーディング期間中、`docs/ja/0001`〜`0020` を
> 読み進めるあいだに、Zig 側で詰まらないようにするための副読本という
> 位置付けです。本リポジトリの ROADMAP / フェーズ進行とは独立しています。

各章末には対応する **「単独で実行できる Zig コード」** へのリンクが
付いています。すべて `zig run` で動作確認済み（Zig 0.16.0）。
コード中の識別子・型名・コメントは英語、章本文は日本語というプロジェクト
方針に揃えています。

```sh
# 章ごとのサンプルを単体で実行
zig run docs/ja/learn_zig/samples/01_hello.zig
zig run docs/ja/learn_zig/samples/06_conversions.zig
zig run docs/ja/learn_zig/samples/26_stdio_writer.zig

# 第 27 章のテストブロックを実行
zig test docs/ja/learn_zig/samples/27_tests.zig
```

---

## 目次

| 章                                               | 主題                                                | サンプル                                                             |
|--------------------------------------------------|-----------------------------------------------------|----------------------------------------------------------------------|
| [0a](#0a-buildzigzon--パッケージマニフェスト)    | `build.zig.zon` — パッケージマニフェスト           | （プロジェクトファイル直接）                                         |
| [0b](#0b-buildzig--ビルドスクリプト)             | `build.zig` — ビルドスクリプト                     | （プロジェクトファイル直接）                                         |
| [01](#01-hello-world-と-main-関数)               | Hello, world と `main` 関数                         | [01_hello.zig](samples/01_hello.zig)                                 |
| [02](#02-コメント---)                            | コメント `//` `///` `//!`                           | [02_comments.zig](samples/02_comments.zig)                           |
| [03](#03-基本型--整数浮動小数boolvoid)           | 基本型 — 整数・浮動小数・bool・void                | [03_primitive_types.zig](samples/03_primitive_types.zig)             |
| [04](#04-数値リテラルと演算子)                   | 数値リテラルと演算子                                | [04_literals_operators.zig](samples/04_literals_operators.zig)       |
| [05](#05-const-と-var)                           | `const` と `var`                                    | [05_const_var.zig](samples/05_const_var.zig)                         |
| [06](#06-明示的な型変換と-組込関数)              | 明示的な型変換と `@`-組込関数                       | [06_conversions.zig](samples/06_conversions.zig)                     |
| [07](#07-配列)                                   | 配列 `[N]T` / `[_]T{}` / `** N`                     | [07_arrays.zig](samples/07_arrays.zig)                               |
| [08](#08-スライス)                               | スライス `[]T` / `[]const T`                        | [08_slices.zig](samples/08_slices.zig)                               |
| [09](#09-オプショナル-t)                         | オプショナル `?T`                                   | [09_optionals.zig](samples/09_optionals.zig)                         |
| [10](#10-エラーと-error-union)                   | エラーと error union                                | [10_errors.zig](samples/10_errors.zig)                               |
| [11](#11-制御構文-if--while--for--switch)        | 制御構文 `if` / `while` / `for` / `switch`          | [11_control_flow.zig](samples/11_control_flow.zig)                   |
| [12](#12-ラベル付きブロック)                     | ラベル付きブロック `blk:` `outer:`                  | [12_labeled_blocks.zig](samples/12_labeled_blocks.zig)               |
| [13](#13-struct-と-メソッド)                     | `struct` とメソッド                                 | [13_structs.zig](samples/13_structs.zig)                             |
| [14](#14-enum)                                   | `enum` / `enum(uN)` / 非網羅 `_`                    | [14_enums.zig](samples/14_enums.zig)                                 |
| [15](#15-タグ付き-union)                         | タグ付き union `union(enum)`                        | [15_tagged_union.zig](samples/15_tagged_union.zig)                   |
| [16](#16-packed-struct--extern-struct--alignn)   | `packed struct` / `extern struct` / `align`         | [16_packed_extern.zig](samples/16_packed_extern.zig)                 |
| [17](#17-ポインタと-anyopaque)                   | ポインタと `anyopaque`                              | [17_pointers.zig](samples/17_pointers.zig)                           |
| [18](#18-関数と関数ポインタvtable-パターン)      | 関数と関数ポインタ・vtable パターン                 | [18_functions_fnptr.zig](samples/18_functions_fnptr.zig)             |
| [19](#19-comptime--inline-for--anytype)          | `comptime` / `inline for` / `anytype`               | [19_comptime_anytype.zig](samples/19_comptime_anytype.zig)           |
| [20](#20-マルチライン文字列)                     | マルチライン文字列                                  | [20_multiline_strings.zig](samples/20_multiline_strings.zig)         |
| [21](#21-undefined-と-unreachable)               | `undefined` と `unreachable`                        | [21_undefined_unreachable.zig](samples/21_undefined_unreachable.zig) |
| [22](#22-threadlocal-var)                        | `threadlocal var`                                   | [22_threadlocal.zig](samples/22_threadlocal.zig)                     |
| [23](#23-アロケータ)                             | アロケータ抽象                                      | [23_allocator.zig](samples/23_allocator.zig)                         |
| [24](#24-arraylist--stringhashmapunmanaged)      | `ArrayList` / `StringHashMapUnmanaged`              | [24_arraylist_hashmap.zig](samples/24_arraylist_hashmap.zig)         |
| [25](#25-staticstringmapinitcomptime)            | `StaticStringMap.initComptime`                      | [25_static_string_map.zig](samples/25_static_string_map.zig)         |
| [26](#26-stdiowriter-と-juicy-main)              | `std.Io.Writer` と Juicy Main                       | [26_stdio_writer.zig](samples/26_stdio_writer.zig)                   |
| [27](#27-テストブロック)                         | テストブロック `test "..." {}`                      | [27_tests.zig](samples/27_tests.zig)                                 |
| [28](#28-stdmem-ユーティリティ)                  | `std.mem` ユーティリティ                            | [28_mem_utilities.zig](samples/28_mem_utilities.zig)                 |
| [29](#29-stdfmt--bufprint--parseint--parsefloat) | `std.fmt` — `bufPrint` / `parseInt` / `parseFloat` | [29_format_parse.zig](samples/29_format_parse.zig)                   |
| [30](#30-embedfile--anyerror--errorname)         | `@embedFile` / `anyerror` / `@errorName`            | [30_embed_anyerror.zig](samples/30_embed_anyerror.zig)               |

---

## 0a. `build.zig.zon` — パッケージマニフェスト

Zig パッケージのメタデータです。本リポジトリの実物（`build.zig.zon`）：

```zig
.{
    .name = .cljw,
    .version = "0.0.0",
    .fingerprint = 0x1869d207073beffa,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{},
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
- `.dependencies = .{}` は空の匿名 struct（依存ゼロ）。Zig 0.16 では
  匿名 struct リテラルが至るところに登場します（→ 第 13 章）。
- `.paths` は配布アーカイブに含めるパス。tarball に同梱するファイル
  集合を明示します。
- `.fingerprint` は Zig 0.12 以降のパッケージマネージャがハッシュ衝突を
  防ぐために使うランダム 64-bit 値。

## 0b. `build.zig` — ビルドスクリプト

ビルドそのものも Zig コードです。本リポジトリの `build.zig`：

```zig
const std = @import("std");

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
  実行時引数を引き渡しています（→ 第 9 章のオプショナル）。

> このスクリプト自身はサンプル化していません（`zig build` を持つ
> 完全なプロジェクトが必要なため）。本リポジトリの `build.zig` を
> そのまま読んで挙動を追ってください。

## 01. Hello, world と `main` 関数

サンプル: [01_hello.zig](samples/01_hello.zig)

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

## 02. コメント `//` `///` `//!`

サンプル: [02_comments.zig](samples/02_comments.zig)

3 種類あります：

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

## 03. 基本型 — 整数・浮動小数・bool・void

サンプル: [03_primitive_types.zig](samples/03_primitive_types.zig)

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

## 04. 数値リテラルと演算子

サンプル: [04_literals_operators.zig](samples/04_literals_operators.zig)

リテラル形式（本リポジトリで実際に登場するもの）：

```zig
const dec  = 1_234_567;        // 10 進、_ で桁区切り
const hex  = 0xFFFC_0000_0000; // 16 進、_ も使える
const flt  = 3.14e-2;          // 浮動小数
```

> Zig には 2 進 `0b...` / 8 進 `0o...` のリテラルも存在するが、本
> リポジトリでは使われていないので本書では扱わない。

演算子：

- 算術: `+ - * / %`（整数除算は切り捨て、`%` は剰余）
- ビット: `& | ^ ~ << >>`
- 比較: `== != < <= > >=`
- 論理: `and or !`（短絡評価）
- ポインタ参照外し: `p.*`（→ 第 17 章）

本リポジトリの `runtime/value.zig` がほぼ全部の演算子を NaN ボックス
のタグ操作で使っています：`tag | payload` で詰め、`>> 48` で取り出し、
`& 0x0000_FFFF_FFFF_FFFF` でマスク。

## 05. `const` と `var`

サンプル: [05_const_var.zig](samples/05_const_var.zig)

Zig はデフォルト不変です：

- **`const`**: 再代入できない束縛。型は推論可能だが、**境界をまたぐ
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

## 06. 明示的な型変換と `@`-組込関数

サンプル: [06_conversions.zig](samples/06_conversions.zig)

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

> 上記 20 個が **このリポジトリに登場するすべて**。`@memset` `@max`
> `@branchHint` `@panic` `@call` などの他の `@` 組込関数は登場しない
> ので本書では扱わない。

`runtime/value.zig` の NaN ボクシング実装はこのうち多くを駆使しています。

## 07. 配列

サンプル: [07_arrays.zig](samples/07_arrays.zig)

固定長配列の書き方：

```zig
const fib: [6]u32 = .{ 1, 1, 2, 3, 5, 8 };  // 長さを明示
const primes = [_]u32{ 2, 3, 5, 7, 11 };    // 長さを推論
const zeros: [4]u32 = [_]u32{0} ** 4;        // ** N で反復
```

`** N` は **配列の繰り返し**。`main.zig` の
`var locals: [tree_walk.MAX_LOCALS]Value = [_]Value{.nil_val} ** tree_walk.MAX_LOCALS;`
は「`MAX_LOCALS` 個の `nil_val` で初期化」の定型。

`.len` でコンパイル時長さが取れます。配列はそのままだとサイズ込みの型
（`[6]u32` と `[8]u32` は別の型）なので、関数の引数として受け渡す場合は
**スライス**（→ 第 8 章）にします。

## 08. スライス

サンプル: [08_slices.zig](samples/08_slices.zig)

スライス `[]T` は `(ポインタ, 長さ)` のペアです。**Zig で文字列を
扱う標準は `[]const u8`**（本リポジトリの `[]const u8` 出現は数百箇所）。

```zig
const buffer: [10]u8 = .{ 'H', 'e', 'l', 'l', 'o', ',', ' ', 'C', 'L', 'J' };
const all:  []const u8 = buffer[0..];
const head: []const u8 = buffer[0..5];
const tail: []const u8 = buffer[7..];
```

可変スライス `[]T` は要素を書き換え可能、`[]const T` は読み取り専用。
文字列リテラル `"hello"` の型は厳密には `*const [5:0]u8` ですが、`[]const u8`
への暗黙変換が効きます（だから関数引数を `[]const u8` にすればリテラル
を直接渡せる）。

## 09. オプショナル `?T`

サンプル: [09_optionals.zig](samples/09_optionals.zig)

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

## 10. エラーと error union

サンプル: [10_errors.zig](samples/10_errors.zig)

Zig のエラーは **値**。エラー集合 `error{...}` を定義し、`!T` で
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
（→ 第 30 章）は「あらゆる error union を受け取る何でも箱」。

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

## 11. 制御構文 `if` / `while` / `for` / `switch`

サンプル: [11_control_flow.zig](samples/11_control_flow.zig)

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

`for`：レンジ `0..n` とスライスの両方に使える。インデックスは別スロット。

```zig
for (words) |w| { ... }
for (words, 0..) |w, idx| { ... }
for (1..6) |n| { ... }   // Zig 0.11+ のレンジ for
```

`switch`：**網羅必須**。整数レンジ、enum、タグ付き union（→ 第 15 章）
すべて取れる。`else =>` でフォールバック、`unreachable` で不可能宣言
（→ 第 21 章）。

```zig
return switch (n) {
    0 => "zero",
    1...9 => "single digit",
    else => "large",
};
```

`switch` 内で **値を捕捉**：`|v|` で payload を、`|*p|` でポインタを。

## 12. ラベル付きブロック

サンプル: [12_labeled_blocks.zig](samples/12_labeled_blocks.zig)

`label:` を付けたブロックは **値を返す式**。`break :label value` で
脱出と値返しを兼ねます。本リポジトリの定番イディオム：

```zig
// main.zig: catch ハンドラに blk: で復帰値を作る
const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch blk: {
    @memcpy(msg_buf[509..512], "...");
    break :blk msg_buf[0..512];
};
```

> Zig はラベル付きループ（`outer:` のような labeled `for` / `while` ）
> もサポートしているが、本リポジトリでは labeled loop は使われていない
> （`blk:` ブロックラベルのみ）。本書もブロックラベルのみを扱う。

## 13. `struct` とメソッド

サンプル: [13_structs.zig](samples/13_structs.zig)

Zig の `struct` は名前付きフィールドの集合。フィールドにデフォルト値、
メソッドとして任意の `fn`、定数として任意の `pub const` を持てます。
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

`init` / `deinit` 命名は本リポジトリ全域の慣例（`Tokenizer.init`,
`Env.init`, `ArenaGc.init` ...）。`init` の戻り値は **新しいインスタンス
そのもの** であり、ヒープ確保とは独立した概念。

匿名 struct リテラル `.{ .field = value }` は型を **代入先 / 戻り値型 /
引数型** から推論します。`runtime/runtime.zig` の `Runtime.init` も
`return .{ .gpa = gpa, ... };` の形で書かれています。

> 構造体メソッドの引数として `anytype` を取る形（`fn describe(self,
> w: anytype) !void` のような Writer 受け）は、第 19 章で `anytype` を、
> 第 26 章で `std.Io.Writer` を導入したあとに自然に書けるようになる。
> 本章のサンプル 13 は `anytype` を使わず `std.debug.print` で完結。

## 14. `enum`

サンプル: [14_enums.zig](samples/14_enums.zig)

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
ユーザ定義で使いたいときに必須：本リポジトリの `HeapTag.@"volatile"`
が代表例。

enum 関連の組込関数（第 6 章で「enum 関連は 14 章」と予告した分）：

| 組込関数       | 役割                                                   |
|----------------|--------------------------------------------------------|
| `@intFromEnum` | enum → 整数（バックエンド型）                         |
| `@enumFromInt` | 整数 → enum。範囲外は安全ビルドで panic               |
| `@tagName`     | タグ名を `[]const u8` で取得（フォーマット出力に便利） |

## 15. タグ付き union

サンプル: [15_tagged_union.zig](samples/15_tagged_union.zig)

`union(enum)` は **タグ付き共用体**。タグ用 enum はコンパイラが自動生成
し、`switch` での網羅判定が効きます。本リポジトリの `Node`（解析後
AST）と `FormData`（読み取り後の生形）が代表例。

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

**`inline else` で全分岐共通の処理**を書くこともできます。本リポ
ジトリの `Node.loc()` がまさにこれ：

```zig
pub fn loc(self: Node) SourceLocation {
    return switch (self) {
        inline else => |n| n.loc,         // 各 payload の `.loc` を返す
    };
}
```

## 16. `packed struct` / `extern struct` / `align(N)`

サンプル: [16_packed_extern.zig](samples/16_packed_extern.zig)

通常の `struct` はフィールド順とアラインを **コンパイラ任せ**。レイアウト
を制御したいときに 2 種類の修飾があります。

| 形式                | レイアウト規則                                 |
|---------------------|------------------------------------------------|
| `struct`            | コンパイラ任意（再配置・パディング自由）。     |
| `extern struct`     | C ABI と同じ。フィールド順・パディングが安定。 |
| `packed struct(uN)` | bit-precise。総ビット幅 = `uN`。               |

本リポジトリの `HeapHeader` は `extern struct`（GC が読むレイアウト
を固定）、`Flags` は `packed struct(u8)`（marked / frozen / 予約 6 ビット
を u8 に詰める）。

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

## 17. ポインタと `anyopaque`

サンプル: [17_pointers.zig](samples/17_pointers.zig)

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
本リポジトリの `runtime/gc/arena.zig` の `arenaAlloc` などが教科書例。

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

## 18. 関数と関数ポインタ・vtable パターン

サンプル: [18_functions_fnptr.zig](samples/18_functions_fnptr.zig)

関数定義の基本：

```zig
fn name(arg1: T1, arg2: T2) ReturnT { ... }
pub fn name(...) ReturnT { ... }     // モジュール外から見える
```

関数ポインタ型は **`*const fn(args) Return`**：

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

## 19. `comptime` / `inline for` / `anytype`

サンプル: [19_comptime_anytype.zig](samples/19_comptime_anytype.zig)

`comptime` は「**コンパイル時に評価**」を表すキーワード。

- 値: `const SIZE = comptime @sizeOf(u64) * 2;`
- 型パラメータ: `fn maxOf(comptime T: type, a: T, b: T) T`
- フォーマット文字列: `comptime fmt: []const u8`（`std.fmt.bufPrint` の形）
- `comptime { ... }` ブロック: モジュール内のアサーション。本リポジトリ
  の `Cons` には `comptime { std.debug.assert(@alignOf(Cons) >= 8); }` が
  あり、ヒープ確保がアライン要件を満たすことをコンパイル時に保証。

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
引数で受け取る** 形も `lang/primitive/math.zig` の `pairwise` で使われて
います。型制約は「呼び出し側が実際に使う形」で実質的に決まる（いわゆる
duck typing）ので、コンパイラはモノモルフ化のたびに型を確定させます。

> `std.Io.Writer` を `anytype` 経由で受け取る形は本リポジトリでも
> 一部使われていますが（テストで `*Writer` を渡しつつ `.fixed(&buf)` を
> 受ける）、本書では Writer の本格紹介を第 26 章に置いた都合で、
> 本章のサンプルでは Writer を扱わず `args: anytype` のパターンに集中
> します。

## 20. マルチライン文字列

サンプル: [20_multiline_strings.zig](samples/20_multiline_strings.zig)

`\\` で始まる行を連ねると、その行の改行込みで一つの文字列になります。
**エスケープ処理されない**（`\n` は 2 文字）のがポイント。

```zig
const HELP =
    \\Usage: cljw [options] [<file.clj> | -]
    \\  -e, --eval <expr>  ...
    \\
;
```

本リポジトリの `main.zig` のヘルプ表示はこの形。長文 SQL や生成テンプ
レートにも便利です。

## 21. `undefined` と `unreachable`

サンプル: [21_undefined_unreachable.zig](samples/21_undefined_unreachable.zig)

`undefined` は **「あとで埋めるから初期化しないで」** のプレースホルダ。
バッファを `bufPrint` などで全面上書きする場合、ゼロ初期化を省けるので
速度を稼げます。

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

## 22. `threadlocal var`

サンプル: [22_threadlocal.zig](samples/22_threadlocal.zig)

スレッドごとに独立したインスタンスを持つグローバル変数。`runtime/error.zig`
の `last_error` / `call_stack` / `msg_buf` が本リポジトリの主な用途：

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

## 23. アロケータ

サンプル: [23_allocator.zig](samples/23_allocator.zig)

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
重ねる薄いラッパー。`runtime/gc/arena.zig` の `ArenaGc` がさらに統計
を取る vtable を被せたもの。

> Zig 0.16 では旧 `std.heap.GeneralPurposeAllocator` が
> `std.heap.DebugAllocator` に改名されたが、**本リポジトリはどちらも
> 使っていない**（GPA は `std.process.Init.gpa` 経由でしか触らない）。
> 本書もこの方針に従うので、サンプル 23/24 は `page_allocator` を
> ArenaAllocator のバッキングに使う形に統一している。

## 24. `ArrayList` / `StringHashMapUnmanaged`

サンプル: [24_arraylist_hashmap.zig](samples/24_arraylist_hashmap.zig)

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

本リポジトリは：

- `std.StringArrayHashMapUnmanaged(*Keyword)` — `KeywordInterner.table`
- `std.StringHashMapUnmanaged(*Var)` — `Namespace.vars`
- `std.AutoHashMapUnmanaged(*const Var, Value)` — `BindingFrame.bindings`

の 3 種類を主に使います（→ ROADMAP §13 で `StringHashMap` ではなく
`Unmanaged` を推奨）。

## 25. `StaticStringMap.initComptime`

サンプル: [25_static_string_map.zig](samples/25_static_string_map.zig)

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

## 26. `std.Io.Writer` と Juicy Main

サンプル: [26_stdio_writer.zig](samples/26_stdio_writer.zig)

Zig 0.16 で `std.io` → `std.Io` に大移動しました。`std.io.AnyWriter` は
廃止。**書き込み API は `*std.Io.Writer` 一本**：

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
アロケータ不要で完結します（→ サンプル 26）。

## 27. テストブロック

サンプル: [27_tests.zig](samples/27_tests.zig)

**テストはコードと同じファイルに書く** のが Zig 流。`zig test` で
すべての `test "name" { ... }` ブロックが走ります。本リポジトリは
**`std.testing.expect(cond)` だけ** を使う方針（grep でも他は出てこない）：

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
> など便利な比較関数も用意されているが、**本リポジトリでは `expect`
> だけ** を使う統一が採られている。本書もこの方針に従う。

本リポジトリは `src/main.zig` の最後に：

```zig
test {
    _ = @import("runtime/value.zig");
    _ = @import("runtime/error.zig");
    ...
}
```

を置き、`zig build test` 一発で全テストを発見させる構成。

## 28. `std.mem` ユーティリティ

サンプル: [28_mem_utilities.zig](samples/28_mem_utilities.zig)

スライス操作の標準関数。argv 解析（`main.zig`）やトークン読み取り
（`tokenizer.zig`）で多用：

| 関数                                 | 役割                           |
|--------------------------------------|--------------------------------|
| `std.mem.eql(T, a, b)`               | 2 つのスライスが等しいか       |
| `std.mem.startsWith(T, hay, prefix)` | `prefix` から始まるか          |
| `std.mem.indexOf(T, hay, needle)`    | 部分列の最初の位置（`?usize`） |
| `std.mem.indexOfScalar(T, hay, c)`   | 単一要素の最初の位置           |
| `@memcpy(dst, src)`                  | バッファコピー（同サイズ必須） |

```zig
if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) { ... }
```

> Zig には `@memset(slice, byte)` も存在するが、本リポジトリでは
> 使われていない（バッファ初期化は `dupe` / `bufPrint` 経由で済むこと
> が多い）ので、本書では扱わない。

## 29. `std.fmt` — `bufPrint` / `parseInt` / `parseFloat`

サンプル: [29_format_parse.zig](samples/29_format_parse.zig)

文字列ⅼ整形・解析。本リポジトリでは：

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

## 30. `@embedFile` / `anyerror` / `@errorName`

サンプル: [30_embed_anyerror.zig](samples/30_embed_anyerror.zig)

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

**`@errorName(err)`** はエラー値の **タグ名文字列**。`main.zig` の
最終フォールバックは `Info` が無いとき `@errorName(err)` を使って
何かしら出力します。

```zig
catch |err| {
    try stderr.print("Error: {s}\n", .{@errorName(err)});
    std.process.exit(1);
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
- 検証コマンド: 各章サンプルに対して `zig run path/to/NN-*.zig`、
  第 27 章のみ `zig test path/to/27_tests.zig`。
- 全 30 サンプルが Mac (aarch64-darwin) でグリーン確認済み。
