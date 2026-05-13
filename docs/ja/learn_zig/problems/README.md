# learn_zig problems

このディレクトリは、`../README.md` と `../samples/*.zig` に出てきた Zig の要素を、自分の手で書いて定着させるための問題集です。

雛形ソースコードは用意しません。各問題ごとに `problems/01_hello.zig` のような `.zig` ファイルをこのディレクトリ直下に作り、`zig run` または `zig test` で動作確認してください。変数名や表示文は自由ですが、指定された型・構文・組込関数・標準ライブラリ API を必ず使い、`std.debug.print` や `std.Io.Writer` などで結果を目で確認してください。

例:

```sh
zig run docs/ja/learn_zig/problems/01_hello.zig
zig test docs/ja/learn_zig/problems/27_tests.zig
zig build --build-file docs/ja/learn_zig/problems/00b_build.zig run
```

出題範囲は `../samples/*.zig` に出てきたものを中心に、`../README.md` だけで説明されているものも足しています。逆に README の付録で「本リポジトリでは扱わない」と明記されている機能は、問題にしません。

## 問題

### 0a. `build.zig.zon`

`problems/00a_build.zig.zon` を手書きしてください。`.name`、`.version`、`.minimum_zig_version`、`.dependencies`、`.paths` を持つ Zig Object Notation の匿名 struct リテラルにし、`.dependencies` には `zlinter` 風の `url` と `hash` のペアを 1 つ入れてください。`zig run` は不要ですが、Zig の struct リテラルとして読める形になっているか確認してください。

### 0b. `build.zig`

`problems/00b_build.zig` と、それが参照する小さな `problems/00b_main.zig` を手書きしてください。`pub fn build(b: *std.Build) void`、`standardTargetOptions`、`standardOptimizeOption`、`createModule`、`addExecutable`、`installArtifact`、`addRunArtifact`、`b.args`、`b.step`、`dependOn`、`addTest` を使い、`zig build --build-file docs/ja/learn_zig/problems/00b_build.zig run` と `... test` で動作確認してください。zlinter の外部依存はここでは実際に import しなくて構いませんが、README の lint step と同じ「step は依存グラフ」という形を意識してください。

### 01. Hello とフォーマット出力

`@import("std")` と `pub fn main() !void` を使い、文字列だけの出力と、`{s}` / `{d}` を使ったフォーマット出力を 1 回ずつ行ってください。フォーマット引数は `.{}` と `.{ ... }` の両方を使ってください。

### 02. 3 種類のコメントと関数

ファイル先頭に `//!`、関数の直前に `///`、関数本体内に `//` を書いてください。整数を 2 乗する関数を作り、`main` から呼んで結果を表示してください。

### 03. 基本型と `@sizeOf`

`u8`、`u16`、`u32`、`u64`、`usize`、`i32`、`i64`、`f64`、`bool`、`void` の値をそれぞれ作ってください。任意ビット幅整数として `u3` と `u21` も 1 つずつ作ってください。`usize` の値には `@sizeOf(u64)` を使い、比較演算の結果を `bool` に入れて、各値を表示してください。`type` は実行時の値として表示するのではなく、`const T: type = u21;` のように型を値として束縛し、`@sizeOf(T)` で確認してください。

### 04. 数値リテラル、ビット演算、比較

16 進リテラルと桁区切り `_` を使ってタグ値と payload を作り、`|`、`&`、`^`、`~`、`<<`、`>>`、`@truncate` で合成値・上位 16 bit・payload 部分などを表示してください。あわせて `+`、`-`、`*`、`/`、`%`、`==`、`!=`、`<`、`<=`、`>`、`>=`、`and`、`or`、`!` の結果も表示してください。

### 05. `const` と `var`

`const` の文字列と整数、`var` のカウンタを作ってください。カウンタは再代入と `+=` の両方で更新し、可変配列の要素も 1 つ書き換えて表示してください。最後に `while` で 0, 1, 2 を表示してください。

### 06. 明示的な型変換

`@as`、`@intCast`、`@truncate`、`@floatFromInt`、`@bitCast`、`@intFromBool`、`@sizeOf`、`@alignOf` をすべて使ってください。整数、浮動小数、bool、型サイズ、アラインメントの結果を表示してください。

### 07. 配列

長さ明示の配列、`[_]T{}` による長さ推論、`** N` による繰り返し配列、多次元配列を作ってください。`.len`、添字アクセス、`while` による合計計算を使い、結果を表示してください。

### 08. スライス

`[]const u8` を引数に取って長さを返す関数を作ってください。固定長配列から `[start..end]`、`[start..]`、`[0..]` でスライスを切り出して表示し、可変スライス `[]i32` 経由で元配列を書き換えてください。

### 09. オプショナル

文字列キーを受け取って `?u32` を返す lookup 関数を作ってください。`if (opt) |v|`、`orelse`、`.?`、`orelse break :label` をそれぞれ使い、存在する値・存在しない値・既定値・ラベル付きブロックの戻り値を表示してください。

### 10. エラーと error union

独自の `error{ ... }` を定義し、文字列を正の整数として解析する関数を作ってください。空文字、数字以外、オーバーフローをエラーにし、`try`、`catch`、`catch |err|`、`defer`、`errdefer` を使って結果とエラー名を表示してください。

### 11. 制御構文

`if` を式として使い、`while` で合計し、スライスの `for` とインデックス付き `for` を使い、レンジ `for` で階乗を求めてください。整数レンジの `switch` と enum の `switch` も使い、結果を表示してください。

### 12. ラベル付きブロック

`blk: { break :blk value; }` を使って、時間帯から挨拶文字列を作ってください。さらに `std.fmt.bufPrint` を `catch blk:` で受け、失敗時の代替文字列を返す形も書いてください。最後にブロック内で複数の局所値からスコアを作って表示してください。

### 13. `struct` とメソッド

ラベル、カウント、真偽値フラグを持つ `struct` を作ってください。`init`、`self: *T` の更新メソッド、`self: T` の読み取りメソッド、`self: *const T` の読み取りメソッドを定義し、メソッド呼び出しとフィールドのデフォルト値を確認してください。

### 14. `enum`

整数バックエンド付き enum と非網羅 enum を作ってください。`@intFromEnum`、`@enumFromInt`、`@tagName` を使い、予約語と衝突するタグは `@"..."` で書いてください。enum の `switch` が網羅されていることも確認してください。

### 15. タグ付き `union`

`union(enum)` で整数、文字列、ペア構造体を持つ値を表してください。配列に複数 variant を入れ、`switch` の payload capture `|v|` で分岐ごとに表示してください。タグごとのラベルを返すメソッドも作ってください。余裕があれば、各 variant が同じ名前のサブフィールドを持つ別 union を作り、`inline else => |payload| payload.loc` の形も確認してください。

### 16. `packed struct`、`extern struct`、`align`

`packed struct(u8)` で bool 2 個と padding を持つフラグを作り、それを含む `extern struct` を作ってください。`@sizeOf`、`@alignOf`、フィールド更新を確認し、`var x: u64 align(8)` のアドレスが 8 で割り切れることを `@intFromPtr` で表示してください。

### 17. ポインタと `anyopaque`

`*u32` で値を書き換える関数、`*const u32` で読む関数、`[*]u8` の many-item ポインタ、`?*T` の nullable ポインタ、`@intFromPtr` / `@ptrFromInt` の往復を試してください。さらに `*anyopaque` を受け取り、`@ptrCast(@alignCast(ctx))` で具体型に戻してフィールドを更新する関数を書いてください。

### 18. 関数ポインタと vtable

足し算・引き算の関数を作り、`*const fn (i32, i32) i32` の型エイリアスにしてください。関数ポインタを持つ vtable struct、関数ポインタを引数に取る `applyTwice`、条件式で選んだ関数ポインタを使って結果を表示してください。

### 19. `comptime`、`inline for`、`anytype`

`comptime T: type` の最大値関数、`comptime pred: fn (...) bool` を受ける隣接ペア検査関数、`args: anytype` を `std.fmt.bufPrint` に転送する関数、`ptr: anytype` を受けて `@intFromPtr` する関数を作ってください。comptime 既知のエントリ配列を `inline for` で表示し、`comptime { std.debug.assert(...) }` のブロックも 1 つ書いてください。

### 20. マルチライン文字列

`\\` で始まるマルチライン文字列を定義し、長さと本文を表示してください。内部の `\n` が改行ではなく 2 文字として扱われることが分かる行も出力してください。

### 21. `undefined` と `unreachable`

`undefined` の固定バッファに `std.fmt.bufPrint` で文字列を書いて表示してください。enum と `switch` を使い、呼び出し側の契約外の値では `else => unreachable` になる関数を作ってください。ただし panic する入力は実行しないでください。

### 22. `threadlocal var`

`threadlocal var` の深さカウンタと最後のメッセージ `?[]const u8` を作ってください。`enter` と `leave` の関数で値を更新し、`orelse` を使って null 時の表示も確認してください。

### 23. アロケータ

`std.heap.ArenaAllocator` を `std.heap.page_allocator` で初期化し、`defer arena.deinit()` してください。`alloc.alloc`、`alloc.free`、`alloc.dupe`、`alloc.create`、`alloc.destroy` を使い、optional ポインタで連結した小さなリストを作って合計を表示してください。追加で `test` ブロックを書き、`std.testing.allocator` でも小さな `dupe` / `free` を確認してください。`std.heap.DebugAllocator` や旧 `GeneralPurposeAllocator` は使わないでください。

### 24. `ArrayList` と `StringHashMapUnmanaged`

Arena の allocator を使い、`std.ArrayList(i32) = .empty` に `append` して `pop` と `items` を表示してください。`std.StringHashMapUnmanaged(u32)` に 3 件入れ、`count`、`get`、`iterator` で結果を表示してください。README に出ている `std.array_hash_map.String(V)` と `std.AutoHashMapUnmanaged(K, V)` も小さく使ってください。deprecated な `std.ArrayListUnmanaged` や `StringArrayHashMapUnmanaged` は使わないでください。

### 25. `StaticStringMap`

`std.StaticStringMap` と `initComptime` で記号から enum への表を作ってください。`get` が返す `?V` を `if` でアンラップし、`@tagName` で分類名を表示してください。`kvs.len` も表示してください。

### 26. `std.Io.Writer`

`pub fn main(init: std.process.Init) !void` を使い、`std.Io.File.stdout().writer(init.io, &buf).interface` から `*std.Io.Writer` を得てください。`writeAll`、`print`、ヘルパー関数への writer 渡し、`.fixed(&buf)` の固定バッファ writer、最後の `flush()` を確認してください。

### 27. テストブロック

足し算関数と `comptime T: type` の最大値関数を作ってください。`main` では `std.debug.assert` で確認し、`test "..." {}` では `try std.testing.expect(...)` だけで同じ性質を確認してください。`expectEqual`、`expectEqualStrings`、`expectError` は使わず、`zig run` と `zig test` の両方で動かしてください。

### 28. `std.mem` と `@memcpy`

`std.mem.eql`、`std.mem.startsWith`、`std.mem.find`、`std.mem.findScalar` を使って文字列スライスを調べてください。`?usize` は `if (opt) |i|` で表示してください。最後に固定バッファへ `@memcpy` で短い文字列を書き込んで表示してください。

### 29. `std.fmt`

`std.fmt.bufPrint`、`std.fmt.allocPrint`、`std.fmt.parseInt`、`std.fmt.parseFloat` を使ってください。10 進整数、16 進整数、浮動小数を解析し、フォーマット指定子 `{}`、`{s}`、`{d}`、`{x}`、`{X}`、`{any}`、`{?d}`、`{:0>16}`、`{d:.2}` を含めて表示してください。失敗する `parseInt` は error union を `if (result) |v| ... else |err| ...` で処理してください。

### 30. `@embedFile`、`anyerror`、`@errorName`

自分自身の `.zig` ファイルを `@embedFile` で埋め込み、長さと先頭の一部を表示してください。別々の error set を 2 つ定義し、`anyerror!void` の関数からどちらのエラーも返せることを `catch |err|` と `@errorName` で確認してください。先頭表示の長さ制限には `@min` を使ってください。

## 解答例

以下は一例です。問題文の条件を満たしていれば、変数名・表示文・入力値は同じでなくて構いません。

### 0a

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

### 0b

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

### 01

```zig
const std = @import("std");

pub fn main() !void {
    std.debug.print("[01] hello\n", .{});
    std.debug.print("[01] {s} = {d}\n", .{ "answer", 42 });
}
```

### 02

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

### 03

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

### 04

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

### 05

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

### 06

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

### 07

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

### 08

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

### 09

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

### 10

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

### 11

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

### 12

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

### 13

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

### 14

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

### 15

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

### 16

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

### 17

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

### 18

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

### 19

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

### 20

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

### 21

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

### 22

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

### 23

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

### 24

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

### 25

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

### 26

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

### 27

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

### 28

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

### 29

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

### 30

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
