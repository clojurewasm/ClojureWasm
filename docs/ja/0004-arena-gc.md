---
chapter: 4
commits:
  - c22f900
related-tasks:
  - §9.3 / 1.3
related-chapters:
  - 0003
  - 0005
date: 2026-04-27
---

# 0004 — Arena GC — suppress_count と gc-stress

> 対応 task: §9.3 / 1.3 / 所要時間: 60〜80 分

Phase 1 のメモリ管理は **arena 1 本**。確保するだけして個別に
free しない、`deinit()` で全部解放。最小だが、**Phase 5 で
mark-sweep に乗り換える日**を見越して、Day 1 から
`suppress_count` (マクロ展開中の collection 阻止) と `gc_stress`
flag (Phase 5 のテストで「毎 alloc collection」を強制するため) の
**フックだけ**を埋めておく。

「足りない機能を入れる」ではなく「いつか入れる機能の入口を作る」、
これが ROADMAP **原則 P2 (See the final shape on day 1)** の実践。

---

## この章で学ぶこと

- Phase 1 で `std.heap.ArenaAllocator` を採用するメリット (bulk
  free、cache-friendly な bump pointer)
- `ArenaGc` を `std.mem.Allocator` の vtable adapter として **見せる**
  仕掛け（`stats` を自動収集）
- `suppress_count: u32` がなぜ Day 1 から要るのか — マクロ展開で
  作る中間 Value は GC で消えてはいけない
- `gc_stress` comptime flag が Phase 5 mark-sweep のためにある理由
- Phase 1 が **single-thread 限定**である理由 — `std.Thread.Mutex`
  が Zig 0.16 で削除され、`std.mem.Allocator.VTable` callback には
  `Io` を渡せない

---

## 1. なぜ arena が Phase 1 に十分なのか

### Reader / Analyzer の lifetime は「1 eval」

Phase 1 の主作業は `(+ 1 2)` のような短文を読んで Form ツリーに
する Reader と、Form を Node ツリーに直す Analyzer。**この 2 段は
1 回の `cljw -e` で終わる**。

```
cljw -e "(+ 1 2)" の流れ:
  read  → Form ツリー作成     ── arena に積まれる
  analyse → Node ツリー作成    ── arena に積まれる
  eval  → Value を計算         ── arena に積まれる
  print → stdout に書く
  exit  → arena.deinit() で全部捨てる
```

**個別 free がいらない**。`arena.deinit()` 1 発で全部消える。
`free` の n^2 lookup（v1 の Phase 1 で発生したパフォーマンス問題）が
そもそも存在しない。

### bump pointer の cache locality

`std.heap.ArenaAllocator` は内部で page をまとめて取り、線形に
書き進む。新規 alloc は **「今のポインタを `len` 進めて返す」だけ**。

```
arena memory:
  [used][used][used][used][.....free.....]
                          ^ next alloc target
```

連続したメモリレイアウトはキャッシュ局所性に優れ、GC 関連の `marked`
bit を後段でセットする (Phase 5) ときも cache miss が少ない。

### ROADMAP の 3 階層 memory tier

§4.8:

| Tier        | Contents                         | GC?  | Lifetime    |
|-------------|----------------------------------|------|-------------|
| GPA         | Env, Namespace, Var              | No   | Process     |
| node_arena  | Reader Form, Analyzer Node       | No   | Per-eval    |
| GC alloc    | Runtime Values                   | Yes  | Mark-sweep  |

Phase 1 ではこの **GC alloc も arena で代用**している（mark-sweep は
Phase 5）。「同じ alloc に 2 役」だが、`ArenaGc` という名前を
**Phase 1 から付ける**ことで、Phase 5 で mark-sweep に乗せ換える時に
**呼び出し側の `gc.allocator()` 呼び出しは不変**で済む。

---

## 2. `std.mem.Allocator` の vtable adapter として見せる

```zig
//! src/runtime/gc/arena.zig
pub const ArenaGc = struct {
    arena: std.heap.ArenaAllocator,
    suppress_count: u32 = 0,
    stats: Stats = .{},

    pub fn init(backing: std.mem.Allocator) ArenaGc {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn allocator(self: *ArenaGc) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = arenaAlloc,
        .resize = arenaResize,
        .remap = arenaRemap,
        .free = arenaFree,
    };
    // ...
};
```

ポイント:

- 内部に **本物の `std.heap.ArenaAllocator`** を持つ。
- `allocator()` は **vtable 付きの薄いラッパ**を返す。
- 4 つの callback (`alloc` / `resize` / `remap` / `free`) は中で
  `self.arena.allocator().rawAlloc(...)` を呼びつつ、**`stats` を
  更新する**。

### `Stats` で alloc を計測する

```zig
pub const Stats = struct {
    bytes_allocated: usize = 0,
    alloc_count: u64 = 0,
};

fn arenaAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *ArenaGc = @ptrCast(@alignCast(ctx));
    const result = self.arena.allocator().rawAlloc(len, alignment, ret_addr);
    if (result != null) {
        self.stats.bytes_allocated += len;
        self.stats.alloc_count += 1;
    }
    return result;
}
```

つまり **「allocator を `ArenaGc` 経由で取った瞬間、自動的に
プロファイル計測が回る」**。`zig build test` で
`gc.stats.bytes_allocated` を見れば、テストが何 byte 触ったか
すぐ判る。

### 演習 4.1: vtable adapter のしかけ (L1 — 予測検証)

以下のテストの **alloc_count** がどうなるか予測してください:

```zig
test "predict" {
    var gc = ArenaGc.init(testing.allocator);
    defer gc.deinit();
    const alloc = gc.allocator();

    _ = try alloc.alloc(u8, 10);
    _ = try alloc.alloc(u8, 20);
    _ = try alloc.alloc(u8, 30);

    // Q: gc.stats.alloc_count は？
    // Q: gc.stats.bytes_allocated は？
}
```

<details>
<summary>答え</summary>

- `gc.stats.alloc_count == 3` (3 回 alloc した)
- `gc.stats.bytes_allocated == 60` (10 + 20 + 30)

注意: `alloc_count` は **試行成功時のみ +1** (`if (result != null)`
ブロック内)。`alloc` が `null` を返した場合は計上しない設計。

このしかけにより、benchmarks (`bench/quick.sh`) で alloc プロファ
イルを取るのが「`gc.stats` を eval 前後で読むだけ」になる。

</details>

---

## 3. `suppress_count` — マクロ展開中の collection 阻止

Phase 5 で mark-sweep を入れたとき、`gc.collect(rt)` は heap を
スキャンして到達不能な `HeapHeader.marked == false` のセルを回収
する。**ここで困るのが「マクロ展開中の中間値」**。

### 問題: 中間 Value はどこからも参照されない

`(when (= x 1) (println "yes"))` を `(if (= x 1) (do (println "yes")) nil)`
に展開する流れを考える:

```
1. Reader が Form を読む
2. Analyzer が Form を Node に変換
3. その途中で macro `when` を展開
   → 新しい Form (`(if ...)`) を作る
   → さらに sub-macro があれば再帰展開
4. 展開済み Form を Analyser が Node 化
```

ステップ 3 で作る **中間 Form**は、次の Form を作った瞬間に
「ローカル変数 only」になり、**スタックや再帰の最深部でしか
参照されない**。Phase 5 の mark-sweep が走ると root でない =
回収対象になる可能性がある。

### 解決: nest できる suppress カウンタ

```zig
suppress_count: u32 = 0,

pub fn suppressCollection(self: *ArenaGc) void {
    self.suppress_count += 1;
}

pub fn unsuppressCollection(self: *ArenaGc) void {
    std.debug.assert(self.suppress_count > 0);
    self.suppress_count -= 1;
}

pub fn isSuppressed(self: *const ArenaGc) bool {
    return self.suppress_count > 0;
}
```

マクロ展開はこう囲う:

```zig
fn expandMacroAndAnalyze(...) !*Node {
    rt.gc.suppressCollection();
    defer rt.gc.unsuppressCollection();
    // ... 展開と analyse ...
}
```

`bool` ではなく **`u32` カウンタ**にしているのが要点。マクロが
さらにマクロを呼び出す **入れ子展開**で、外側の `defer` が `unsuppress`
を呼んでも、内側がまだ走っているので suppress 状態を維持できる。

### 演習 4.2: suppress カウンタを書く (L2 — 部分再構成)

シグネチャだけ与えるので本体を書いてください:

```zig
pub const ArenaGc = struct {
    suppress_count: u32 = 0,

    pub fn suppressCollection(self: *ArenaGc) void {
        // ここから書く
    }
    pub fn unsuppressCollection(self: *ArenaGc) void {
        // ここから書く（不正な unsuppress を assert で潰す）
    }
    pub fn isSuppressed(self: *const ArenaGc) bool {
        // ここから書く
    }
    // ...
};
```

要件:

- `unsuppressCollection` は `suppress_count == 0` で呼ばれたら
  panic（`std.debug.assert`）
- `isSuppressed` は `*const ArenaGc` を取り、副作用を持たない

<details>
<summary>答え</summary>

```zig
pub fn suppressCollection(self: *ArenaGc) void {
    self.suppress_count += 1;
}

pub fn unsuppressCollection(self: *ArenaGc) void {
    std.debug.assert(self.suppress_count > 0);
    self.suppress_count -= 1;
}

pub fn isSuppressed(self: *const ArenaGc) bool {
    return self.suppress_count > 0;
}
```

ポイント:

- Phase 1 では mark-sweep がないので **suppress を見るコードは
  まだ無い**。それでも API を埋めておくのは P2 の精神。
- assert を debug でだけ効かせる: release ビルドではそもそも
  GC 自体が違う実装になっているので assert は spec の役割。

</details>

---

## 4. `gc_stress` flag — Phase 5 mark-sweep のテスト用

```zig
/// Comptime flag for collect-on-every-alloc stress mode (Phase 5+).
/// Wired to a build option once mark-sweep lands.
pub const gc_stress = false;
```

これは **comptime const** で、まだ何にも使われていない。Phase 5 で
mark-sweep が入ったとき、こう使う:

```zig
fn arenaAlloc(...) ?[*]u8 {
    if (gc_stress) {
        gc.collect(rt);    // ← alloc 毎に collection (テスト用)
    }
    // ...
}
```

何のため？: GC のバグは **collect されない限り顕在化しない**。普通の
プログラム実行では heap が広いので mark-sweep が走らずバグが眠る。
`gc_stress = true` で **毎 alloc に collect**、すれば最小再現に
帰着する。

### Phase 1 で flag を仕込んでおくメリット

- Phase 5 でこの flag を `true` に切り替えるだけで stress test が
  走る (build option で外から切り替えられるようにする予定)
- **「Phase 5 が来たときに `arena.zig` を編集する必要が最小」** —
  ROADMAP P2 (final shape on day 1) と A2 (新機能は新ファイル) を
  一段階先取りしている

### 演習 4.3: arena.zig 全体を書き起こす (L3 — 完全再構成)

ファイル名と公開 API のみ:

- File: `src/runtime/gc/arena.zig`
- 公開 API:
  - `pub const Stats = struct { bytes_allocated: usize = 0, alloc_count: u64 = 0 };`
  - `pub const gc_stress = false;`
  - `pub const ArenaGc = struct { ... };`
    - `pub fn init(backing: std.mem.Allocator) ArenaGc`
    - `pub fn deinit(self: *ArenaGc) void`
    - `pub fn allocator(self: *ArenaGc) std.mem.Allocator`
    - `pub fn reset(self: *ArenaGc) void`
    - `pub fn suppressCollection(self: *ArenaGc) void`
    - `pub fn unsuppressCollection(self: *ArenaGc) void`
    - `pub fn isSuppressed(self: *const ArenaGc) bool`

<details>
<summary>答え骨子</summary>

```zig
//! Arena GC for Phase 1.

const std = @import("std");

pub const gc_stress = false;

pub const Stats = struct {
    bytes_allocated: usize = 0,
    alloc_count: u64 = 0,
};

pub const ArenaGc = struct {
    arena: std.heap.ArenaAllocator,
    suppress_count: u32 = 0,
    stats: Stats = .{},

    pub fn init(backing: std.mem.Allocator) ArenaGc {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *ArenaGc) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *ArenaGc) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn suppressCollection(self: *ArenaGc) void {
        self.suppress_count += 1;
    }

    pub fn unsuppressCollection(self: *ArenaGc) void {
        std.debug.assert(self.suppress_count > 0);
        self.suppress_count -= 1;
    }

    pub fn isSuppressed(self: *const ArenaGc) bool {
        return self.suppress_count > 0;
    }

    pub fn reset(self: *ArenaGc) void {
        _ = self.arena.reset(.free_all);
        self.stats = .{};
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = arenaAlloc,
        .resize = arenaResize,
        .remap = arenaRemap,
        .free = arenaFree,
    };

    fn arenaAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ArenaGc = @ptrCast(@alignCast(ctx));
        const result = self.arena.allocator().rawAlloc(len, alignment, ret_addr);
        if (result != null) {
            self.stats.bytes_allocated += len;
            self.stats.alloc_count += 1;
        }
        return result;
    }
    // ... resize / remap / free も同様 ...
};
```

検証: `bash test/run_all.sh` が緑、特に `ArenaGc tracks allocations
via stats` / `ArenaGc suppression nests` / `gc_stress flag is
accessible` のテストが通ること。

</details>

---

## 5. なぜ Phase 1 は single-thread 限定なのか

`arena.zig` 冒頭のコメントが明示している:

```
//! Thread-safety: the allocator vtable is **not** thread-safe. Phase 1
//! is single-threaded so this is fine. `std.Thread.Mutex` is gone in
//! Zig 0.16, and `std.Io.Mutex.lock` requires an `Io` argument that
//! `std.mem.Allocator.VTable` callbacks cannot accept (their signatures
//! are fixed). A different lock strategy must land before Phase 15.
```

要点:

- **`std.Thread.Mutex` は Zig 0.16 で消えた**（`zig_tips.md` 参照）。
- **`std.Io.Mutex.lock(io)` に変わった**が、これには `io: std.Io` の
  引数が必要。
- **`std.mem.Allocator.VTable` の callback は signature 固定**で、
  `io` を渡す経路がない。
- Phase 1 は single-thread 確定 → ロック不要 → 問題なし。

Phase 15 (concurrency) で対応する選択肢:

1. **per-thread arena**: スレッドごとに独立した arena を持たせる
2. **lock-free bump pointer**: `std.atomic` で next pointer を CAS

どちらも一手間あり、Phase 1 で先取りする価値はない（**P10: Honour
Zig 0.16 idioms**）。

---

## 6. 設計判断と却下した代替

| 案 | 採否 | 理由 |
|----|------|------|
| **arena + suppress_count + gc_stress flag** | ✓ | Phase 1 の lifetime に最適、Phase 5 の mark-sweep に向けた seam を完備 |
| `GeneralPurposeAllocator` 直接利用 | ✗ | 個別 free は Phase 1 で不要、cache locality が劣る |
| Phase 1 から mark-sweep 実装 | ✗ | Phase 1 タスクがない (短文 eval が完結する)、Phase 1 を肥大化 |
| `bool` で suppress | ✗ | 入れ子マクロで状態が壊れる、`u32` は数 byte で済む |
| `gc_stress` を Phase 5 で追加 | ✗ | Phase 5 で API 変更を増やす — Day 1 の comptime flag で済む |
| allocator vtable に mutex 内蔵 | ✗ | callback signature に `io` を渡せず Zig 0.16 idiom に違反 |

ROADMAP §4.7 / §4.8 / §A4 (GC は隔離 subsystem) と整合。

---

## 7. 確認 (Try it)

```sh
git -C ~/Documents/MyProducts/ClojureWasmFromScratch checkout c22f900
zig build test
# arena.zig の test 群が緑（5 ケース、最後の "gc_stress flag is
# accessible" を含む）

# stats が機能していることを確認
cat <<'EOF' > /tmp/stats_demo.zig
const std = @import("std");
const arena_mod = @import("src/runtime/gc/arena.zig");

pub fn main() !void {
    var gc = arena_mod.ArenaGc.init(std.heap.page_allocator);
    defer gc.deinit();
    const alloc = gc.allocator();

    _ = try alloc.alloc(u8, 1024);
    _ = try alloc.alloc(u64, 16);

    std.debug.print("alloc_count = {d}\n", .{gc.stats.alloc_count});
    std.debug.print("bytes       = {d}\n", .{gc.stats.bytes_allocated});
    // → alloc_count = 2, bytes >= 1024 + 128
}
EOF

git checkout cw-from-scratch
```

---

## 8. 教科書との対比

| 軸 | v1 (`~/Documents/MyProducts/ClojureWasm`) | v1_ref | Clojure JVM | 本リポ |
|----|------|------|------|------|
| Phase 1 alloc | `GeneralPurposeAllocator` | `ArenaGc` | n/a (`new` + GC) | `ArenaGc` |
| GC のレイヤ分け | 単一ファイル `gc.zig` 1957 行 | `gc/arena.zig` | `Object` ヒープ | `gc/{arena,mark_sweep,roots}.zig` (§4.7) |
| suppress | Phase 後半で追加 | Day 1 | n/a (JVM GC) | Day 1 |
| 統計取得 | 手動 print | `Stats` 構造体 | JMX | `Stats` 構造体 |
| stress test | none | `gc_stress` comptime const | `-XX:+UseSerialGC` 等 | `gc_stress` comptime const |

引っ張られず本リポの理念で整理した点：

- v1 の `gc.zig` は **1957 行の巨大ファイル**で、§A6 (≤ 1000 LOC) の
  raison d'être の 1 つ。本リポは Phase 1 から `gc/arena.zig` (200 行)
  と `gc/mark_sweep.zig` (Phase 5) と `gc/roots.zig` (Phase 5) に
  **物理分割**。
- v1 の suppress は後付け、本リポは Day 1 — マクロ展開を実装する
  Phase 3+ で `suppressCollection()` の呼び出し site を埋めるだけで
  動く。

---

## 9. Feynman 課題

1. なぜ Phase 1 は arena だけで足りるのか？ 1 行で。
2. `suppress_count` を **`u32`** にして **`bool` にしない**理由は？ 1 行で。
3. `gc_stress = false` を Day 1 から定義しておくと、Phase 5 で何が
   楽になるのか？ 1 行で。

---

## 10. チェックリスト

- [ ] 演習 4.1: alloc_count / bytes_allocated を予測できる
- [ ] 演習 4.2: `suppressCollection` / `unsuppressCollection` を
      シグネチャだけから書ける
- [ ] 演習 4.3: `arena.zig` 全体をファイル名と API リストだけから
      書き起こせる
- [ ] Feynman 3 問を 1 行ずつで答えられる
- [ ] ROADMAP §4.7 / §4.8 / §A6 を即座に指せる

---

## 次へ

第 5 章: [PersistentList と Murmur3 hash](./0005-persistent-list-and-hash.md)

— Clojure の `(cons x xs)` がどう ヒープ上に cons cell として現れるか、
`count` を **O(1) で持つこと** の意味、そして Clojure JVM と互換な
Murmur3 hash を Zig で wrap-around 算術 (`*%` / `+%`) を使って 1:1
再現する流儀を見ます。
