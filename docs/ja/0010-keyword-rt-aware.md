---
chapter: 10
commits:
  - 07d5c34
related-tasks:
  - §9.4 / 2.2
related-chapters:
  - 0009
  - 0011
date: 2026-04-27
---

# 0010 — Keyword interning を rt-aware に昇格

> 対応 task: §9.4 / 2.2 / 所要時間: 30〜45 分

Phase 1 で「single-thread だから」と素朴に書いた `KeywordInterner
.intern(self, ns, name)` を、Runtime ハンドル導入の直後（Phase 2.2）
に **rt-aware** な `intern(rt, ns, name)` へリファクタリングします。
**cell layout は 1 byte も触らず、API 表面だけを書き換えます**。

短い章ですが、本リポジトリの方針 **「workaround を Phase をまたいで
残さない」** を端的に体現するコミットです。

---

## この章で学ぶこと

- Phase 1 → Phase 2.2 で **何が変わって、何が変わらなかったか**
- 旧 `intern` を `internUnlocked` に rename した命名意図
- 新 top-level `intern(rt, ...)` で `rt.keywords.mutex.lockUncancelable
  (rt.io)` を取る作法
- Phase 2 が **まだ single-thread** なのに mutex を入れる理由
  (Phase 15 への伏線)
- Phase 2.1 と 2.2 を分けた diff 可読性の話

---

## 1. Phase 1 → Phase 2.2 の差分

### Phase 1 (`b60924b`) — 単純な `*KeywordInterner` メソッド

```zig
//! Keyword interning — Phase-1 single-threaded stub.

pub const KeywordInterner = struct {
    alloc: std.mem.Allocator,
    table: std.StringArrayHashMapUnmanaged(*Keyword) = .empty,

    pub fn intern(self: *KeywordInterner,
                  ns: ?[]const u8,
                  name: []const u8) !Value {
        // ... 直接 self.table を触る ...
    }

    pub fn find(self: *KeywordInterner, ...) ?Value { ... }
};
```

ここには **mutex がありません**。Phase 1 を single-thread と定めて
いるので必要なく、書いていません。ただし冒頭コメントには伏線が
張られています：

```
//! ### Phase-1 scope
//!
//! Phase 2.0 widens the public API to take a `*Runtime` and
//! wraps the table with `std.Io.Mutex.lockUncancelable(rt.io)`.
//! Pinning the *struct shape* now (header + ns + name + hash_cache)
//! means Phase 2.0 only changes call sites, not memory layout.
```

「**cell の形（header / ns / name / hash）は今この時点で固定する**。
Phase 2 で変わるのは API 表面だけ」と、Phase 1 の段階で宣言して
いるわけです。

### Phase 2.2 (`07d5c34`) — rt-aware への refactor

```zig
//! Keyword interning — Phase-2 rt-aware.

pub const KeywordInterner = struct {
    alloc: std.mem.Allocator,
    table: std.StringArrayHashMapUnmanaged(*Keyword) = .empty,
    mutex: std.Io.Mutex = .init,                 // ← 追加

    /// Low-level intern — does **not** lock.
    pub fn internUnlocked(self: *KeywordInterner, ...) !Value {
        // 中身は Phase 1 とほぼ同じ
    }
    pub fn findUnlocked(self: *KeywordInterner, ...) ?Value { ... }
};

/// Intern (ns, name) against rt.keywords, locking via rt.io.
pub fn intern(rt: *Runtime, ns: ?[]const u8, name_: []const u8) !Value {
    rt.keywords.mutex.lockUncancelable(rt.io);
    defer rt.keywords.mutex.unlock(rt.io);
    return rt.keywords.internUnlocked(ns, name_);
}

pub fn find(rt: *Runtime, ns: ?[]const u8, name_: []const u8) ?Value {
    rt.keywords.mutex.lockUncancelable(rt.io);
    defer rt.keywords.mutex.unlock(rt.io);
    return rt.keywords.findUnlocked(ns, name_);
}
```

変更を 4 つに分解できます：

| # | 変更                                                                | 影響                                                          |
|---|---------------------------------------------------------------------|---------------------------------------------------------------|
| 1 | `KeywordInterner` に `mutex: std.Io.Mutex = .init` フィールド追加   | 構造体サイズ +1 ワード強。Phase 2 では未競合なのでコスト ≈ 0 |
| 2 | 旧 `intern` / `find` を `internUnlocked` / `findUnlocked` に rename | 「lock を取らない」ことを名前で明示                           |
| 3 | top-level `intern(rt, ...)` / `find(rt, ...)` を新設                | rt 経由で mutex を取る。これが新しい主流 API                  |
| 4 | tests に rt-aware シリーズ追加。既存の low-level test も残す        | 並列対応の段階性を test で示す                                |

**cell layout (`Keyword` struct)** は 1 byte も触っていません：

```zig
pub const Keyword = struct {
    header: HeapHeader,
    _pad: [6]u8 = undefined,
    ns: ?[]const u8,
    name: []const u8,
    hash_cache: u32,
};
```

Phase 1 と完全に同じです。**メモリレイアウトを Phase 1 で凍結し、
Phase 2 ではその上に API を被せただけ** ということです。

### 演習 10.1: 何が変わって何が変わらなかったか (L1)

以下の項目について、**Phase 1 → Phase 2.2 で変わった (○) /
変わらなかった (×)** のどちらか。

```
(a) Keyword struct のフィールド順
(b) Murmur3 hash 関数 (computeHash)
(c) intern API のシグネチャ
(d) find が返す Value の bit 表現
(e) 内部の StringArrayHashMap の使い方
(f) test の組み立て方法 (TestFixture の有無)
```

<details>
<summary>答え</summary>

| 項目                     | 変化 | 補足                                                                  |
|--------------------------|------|-----------------------------------------------------------------------|
| (a) Keyword フィールド順 | ×   | Phase 1 で凍結済み                                                    |
| (b) computeHash          | ×   | 純関数なので無関係                                                    |
| (c) intern API           | ○   | `(self, ns, name)` → `(rt, ns, name)`                                |
| (d) Value の bit 表現    | ×   | `Value.encodeHeapPtr(.keyword, kw)` で同じ                            |
| (e) HashMap 使い方       | ×   | 中身は `internUnlocked` に同じコードが残った                          |
| (f) test 組み立て        | ○   | rt-aware test では `TestFixture` (`std.Io.Threaded` + Runtime) が必要 |

要するに **API 表面だけが変わりました**。内部のセル / hash / map
操作はすべて Phase 1 から継承しています。

</details>

---

## 2. なぜ「Unlocked」の suffix なのか

旧 `intern` を消さずに `internUnlocked` という名前で残したのは、
**`async`-not-aware な慣習** を Zig コミュニティから引いてきた選択
です。

```zig
/// Low-level intern — does **not** lock. Most callers should use
/// the top-level `intern(rt, ns, name)` instead, which acquires
/// `mutex` first. This entry is preserved for callers that
/// already hold the lock or are running in a known-single-threaded
/// path (tests, fixed-input bootstrap).
pub fn internUnlocked(self: *KeywordInterner, ...) !Value { ... }
```

3 つの利点：

1. **lock を取らない事実が名前から読める**: ぼんやり `intern` を
   呼んだコードが「あれ、これ lock してないの？」と気付ける。
2. **テストが楽**: `std.Io.Threaded` を立てない単純な test では
   `internUnlocked` を呼べばよい。実際 Phase 2.2 後も Phase 1 から
   引き継いだ low-level test 群がそのまま動いています。
3. **bootstrap で使える**: 起動時に固定インプット (例: `nil` /
   `true` / `false` のシンボル登録) を入れるとき、まだ Runtime
   完成前なので Unlocked が必要。

### Convention from Zig stdlib

`std.heap.GeneralPurposeAllocator` も `noLockReuse` のような
unlocked variant を持つことがあります。**Zig は「lock 状態を関数名
で区別する」文化** です。Java や C# のような annotation での区別は
採らず、名前（suffix）で表現します。

### 演習 10.2: 旧 API を rt-aware に書き換える (L2)

シグネチャだけ与えるので本体を書いてください。

```zig
// Old (Phase 1):
//   pub fn intern(self: *KeywordInterner, ns: ?[]const u8, name: []const u8) !Value;

// New (Phase 2.2):
pub fn intern(rt: *Runtime, ns: ?[]const u8, name_: []const u8) !Value {
    // ここから書く
}
```

ヒント:

- `rt.keywords` で `KeywordInterner` を取れる
- mutex は `rt.keywords.mutex`
- lock 取得は `lockUncancelable(rt.io)`
- 解放は `unlock(rt.io)` を `defer` で

<details>
<summary>答え</summary>

```zig
pub fn intern(rt: *Runtime, ns: ?[]const u8, name_: []const u8) !Value {
    rt.keywords.mutex.lockUncancelable(rt.io);
    defer rt.keywords.mutex.unlock(rt.io);
    return rt.keywords.internUnlocked(ns, name_);
}
```

ポイント:

- **`lockUncancelable`**: cancel-aware ではなく無条件にロックを取り
  ます。Phase 2 では cancellation token がないので Uncancelable で
  問題ありません。
- **`defer unlock`**: errdefer ではなく defer です。`internUnlocked`
  が失敗しても unlock を必ず走らせます。
- **委譲**: 自分で table を触らず `internUnlocked` に委ねます。
  これで「ロックを取った版」の薄いラッパが完成します。

</details>

---

## 3. なぜ Phase 2 の単一スレッド時代に mutex を入れるのか

Phase 2 はまだ single-thread です。`std.Io.Threaded` を使っていても、
1 スレッドしか動いていません。それでも mutex を入れます：

```
//! ### Why a mutex when Phase 2 is still single-threaded?
//!
//! Wiring `std.Io.Mutex` through the call site now means the
//! Phase-15 concurrency rollout doesn't need to touch this file —
//! the lock just starts blocking. Cost in Phase 2 is one
//! uncontended `lockUncancelable` per intern, which is on the order
//! of a load + store.
```

理由は **「Phase 15 でこのファイルをもう触らずに済ませるため」**
です。

### Phase 15 で何が起きるか

ROADMAP §7 (Concurrency design):

```
Phase 15: future / promise / agent / atom / volatile! が入る。
スレッドが複数走り始める。
```

そのとき `keyword.intern` が **未保護で複数スレッドから呼ばれる** と
race condition で table が壊れます。Phase 15 を迎える前に lock を
入れる必要がある。

選択肢：

| 戦略                                                     | コスト                                                            |
|----------------------------------------------------------|-------------------------------------------------------------------|
| Phase 15 で keyword.zig を書き直す                       | 1 ファイル touch、テストの大幅追加、API 変更が他に伝播            |
| **Phase 2.2 で mutex を入れて、Phase 15 では何もしない** | Phase 2 で uncontended lock 1 命令分のオーバーヘッド (= 計測誤差) |

後者を選んだ。理由：

1. **API 変更を Phase をまたぐ箇所が減る**: Phase 2.2 の時点で
   `intern(rt, ...)` シグネチャは Phase 15 と同じ。Phase 15 で
   `intern` の引数や戻り値が変わらないので、その時の集中力を
   並行性そのもの (atom / future / agent) に使える。
2. **Phase 1 の `mutex 入れない` 妥協を Phase 2 で正しく解消**:
   strategic note (`private/2026-04-24_runtime_design/REPORT.md`)
   の「workaround を残さない」原則。
3. **uncontended lock のコストはほぼゼロ**: x86_64 の `LOCK CMPXCHG`
   は競合がなければ load + store と同じくらい (~5-10 ns)。
   benchmark で測れる差ではない。

### `std.Io.Mutex` を選んだ理由

Zig 0.16 では `std.Thread.Mutex` が **削除されました**。代わりに：

- `std.Io.Mutex` — 完全な blocking mutex。`lock` / `unlock` が `io`
  を引数に取る。caller が io を持つことを要求。
- `std.atomic.Mutex` — lock-free `tryLock` / `unlock` のみ
  (blocking lock なし)。

`std.Io.Mutex` を選ぶのは **Runtime が `io` を既に持っているから**。
caller (= `intern(rt, ...)` の中身) が `rt.io` を取り出して `lock` /
`unlock` に流すだけで済みます。

ROADMAP §7 / `.claude/rules/zig_tips.md`:

> Mutex: `std.Thread.Mutex` is gone. Replacements: `std.Io.Mutex` —
> full blocking mutex; lock/unlock take an `io: Io` argument, so the
> call site must already be threading `Io` through.

### 演習 10.3: rt-aware keyword モジュールを書き起こす (L3)

ファイル名と公開 API のみ：

要求:
- File: `src/runtime/keyword.zig`
- Public:
  - `pub const Keyword = struct { ... }` (cell, Phase 1 と同じ)
  - `pub const KeywordInterner = struct { ... }` (`mutex: std.Io.Mutex`
    を含む)
  - `pub fn KeywordInterner.init(alloc) KeywordInterner`
  - `pub fn KeywordInterner.deinit(self) void`
  - `pub fn KeywordInterner.internUnlocked(self, ns, name) !Value`
  - `pub fn KeywordInterner.findUnlocked(self, ns, name) ?Value`
  - `pub fn intern(rt: *Runtime, ns, name) !Value` (top-level)
  - `pub fn find(rt: *Runtime, ns, name) ?Value` (top-level)
  - `pub fn asKeyword(val: Value) *const Keyword`

ヒント:
- top-level `intern` / `find` は `rt.keywords.mutex.lockUncancelable
  (rt.io)` で囲んで `internUnlocked` / `findUnlocked` を呼ぶ
- `asKeyword` は `val.decodePtr(*const Keyword)`。lock 不要 (純粋な
  ポインタ算術)

<details>
<summary>答え骨子</summary>

```zig
//! Keyword interning — Phase-2 rt-aware.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const HeapHeader = value.HeapHeader;
const HeapTag = value.HeapTag;
const hash = @import("hash.zig");
const Runtime = @import("runtime.zig").Runtime;

pub const Keyword = struct {
    header: HeapHeader,
    _pad: [6]u8 = undefined,
    ns: ?[]const u8,
    name: []const u8,
    hash_cache: u32,
};

pub const KeywordInterner = struct {
    alloc: std.mem.Allocator,
    table: std.StringArrayHashMapUnmanaged(*Keyword) = .empty,
    mutex: std.Io.Mutex = .init,

    pub fn init(alloc: std.mem.Allocator) KeywordInterner {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *KeywordInterner) void {
        // ... free entries + table ...
    }

    pub fn internUnlocked(self: *KeywordInterner,
                          ns: ?[]const u8,
                          name_: []const u8) !Value {
        // 旧 Phase 1 の intern 中身そのまま
    }

    pub fn findUnlocked(self: *KeywordInterner,
                        ns: ?[]const u8,
                        name_: []const u8) ?Value {
        // 旧 Phase 1 の find 中身そのまま
    }
};

pub fn intern(rt: *Runtime, ns: ?[]const u8, name_: []const u8) !Value {
    rt.keywords.mutex.lockUncancelable(rt.io);
    defer rt.keywords.mutex.unlock(rt.io);
    return rt.keywords.internUnlocked(ns, name_);
}

pub fn find(rt: *Runtime, ns: ?[]const u8, name_: []const u8) ?Value {
    rt.keywords.mutex.lockUncancelable(rt.io);
    defer rt.keywords.mutex.unlock(rt.io);
    return rt.keywords.findUnlocked(ns, name_);
}

pub fn asKeyword(val: Value) *const Keyword {
    std.debug.assert(val.tag() == .keyword);
    return val.decodePtr(*const Keyword);
}
```

検証: `bash test/run_all.sh` が緑になる。Phase 1 から引き継いだ
low-level test 群と新 rt-aware test 群が両方通る。

</details>

---

## 4. なぜ Phase 2.1 と 2.2 を別 commit にしたのか

Phase 2.1（`91feef0`）は dispatch + Runtime + Env skeleton を
**+435 行 / 4 ファイル新設するコミット** です。Phase 2.2（`07d5c34`）
は keyword のリファクタで **+143 / -67 行 / 1 ファイル変更するコミット**
です。

**この 2 つを 1 コミットに押し込むこともできました**。技術的には次の
ような形が可能です：

- 2.1 で `keyword.zig` も同時にリファクタすれば、`Runtime.keywords`
  への参照は最初から rt-aware に揃います。
- 余分な Phase 2.2 が不要になります。

それでも分けた理由を以下に並べます。

### 理由 1: diff 可読性

2.1 だけでも 4 ファイル新設の **大きなコミット** です。これに
keyword リファクタ（`+143 / -67`）を加えると、`git show 91feef0` で
4 ファイル + 1 ファイルが流れ、各ファイルでの変更の意図が混ざって
しまいます。

**読み手（= 半年後の自分、Conj 2026 発表の聴衆）が追えなくなります**。

### 理由 2: テストの粒度

2.1 の test は「Runtime / Env / VTable が **コンパイルでき、構築でき
る**」ことだけを確認します。これだけでも十分な価値があります。

2.2 で keyword に rt-aware API を足すと、別の独立した test 群
（`intern(rt, ...)` の rt-aware な振る舞い）が確認対象になります。
**1 コミット = 1 つの観察可能変化** という TDD 原則と整合します。

### 理由 3: 失敗時の roll-back 単位

仮に Phase 2.2 で「`std.Io.Mutex` の使い方を間違えていて、lock を
取ってからの動作が遅すぎる」と判明したら、`07d5c34` だけ revert
すれば Phase 2.1 の構造はそのまま残せます。

逆に 1 コミットにまとめていた場合、Mutex 部分だけを部分 revert
するのは困難になります。

### 理由 4: 将来の章で参照しやすい

Phase 2.1 と 2.2 を別コミットにしておくと、教科書（この `docs/ja/`）
の章構成でも分けて書けます。

- 第 0009 章 = 91feef0 の話（Runtime ハンドル + 3 層）
- 第 0010 章 = 07d5c34 の話（rt-aware リファクタ）

**1 章 = 1 概念** という本リポジトリの教育原則（第 0001 章）に直接
寄与します。1 章に複数の話を混ぜると、内容が薄まってしまいます。

---

## 5. 設計判断と却下した代替

| 案                                                 | 採否 | 理由                                                              |
|----------------------------------------------------|------|-------------------------------------------------------------------|
| **`internUnlocked` + top-level `intern(rt, ...)`** | ✓   | API 表面で lock 状態を区別、test で両方使える、bootstrap でも便利 |
| 旧 `intern` を残し、新たに `internRtAware` を追加  | ✗   | 名前が冗長。「lock していない」事実を覆い隠す                     |
| 全ての test を rt-aware に書き換え                 | ✗   | low-level test の独立性が失われる。fixture コスト増               |
| `std.Thread.Mutex` を使う                          | ✗   | Zig 0.16 で削除済。ROADMAP §13 の reject patterns                |
| `std.atomic.Mutex` (lock-free)                     | ✗   | blocking `lock` が無いので `std.Io.Mutex` の方が素直              |
| Phase 15 まで mutex 無し (現状維持)                | ✗   | Phase 15 で keyword.zig を再度大改修するのは「workaround を残す」 |
| Phase 2.1 と 2.2 を 1 commit に                    | ✗   | diff 可読性、test 粒度、roll-back 単位、章の独立性すべて損なう    |
| cell layout (Keyword struct) も同時に変更          | ✗   | Phase 1 で凍結した約束を破る。layout 変更は別の ADR レベル        |

ROADMAP §7 (Concurrency design — Phase 15 への伏線), §A7
(Concurrency designed Day 1), 原則 P10 (0.16 idiom) と整合。

---

## 6. 確認 (Try it)

```sh
cd ~/Documents/MyProducts/ClojureWasmFromScratch

# Phase 2.2 時点に切り替え
git checkout 07d5c34

# rt-aware test が通ることを確認
zig build test 2>&1 | grep -E "intern|find" | head -20

# 旧 Phase 1 の low-level test と新 rt-aware test の両方を眺める
git diff b60924b 07d5c34 -- src/runtime/keyword.zig | head -80

# 戻る
git checkout cw-from-scratch
```

`b60924b` (Phase 1 の keyword 投入) と `07d5c34` (Phase 2.2 の rt-aware 化)
の間にある変更を読むと、「**cell layout が 1 byte も変わっていない**」
ことが diff で確認できます。

```sh
# Keyword struct の宣言は不変
git diff b60924b 07d5c34 -- src/runtime/keyword.zig | grep -A 10 "pub const Keyword = struct"
# ↑ 出力なし (= 差分なし) のはず
```

---

## 7. 教科書との対比

| 軸          | v1 (`ClojureWasm`)                   | v1_ref                        | Clojure JVM                                                   | 本リポ                                           |
|-------------|--------------------------------------|-------------------------------|---------------------------------------------------------------|--------------------------------------------------|
| 採用方式    | グローバル `var intern_mutex: Mutex` | rt-aware (試行)               | `clojure.lang.Keyword.intern(...)` static + ConcurrentHashMap | rt-aware (`*Runtime` 経由)                       |
| Mutex 種類  | `std.Thread.Mutex` (Zig 0.15 時代)   | `std.Io.Mutex` (試行)         | n/a (`ConcurrentHashMap`)                                     | `std.Io.Mutex`                                   |
| API 表面    | `intern(ns, name)` モジュール level  | `intern(rt, ns, name)` (試行) | `Keyword.intern(Symbol)` static                               | `intern(rt, ns, name)` top-level                 |
| Cell layout | header + ns + name + hash_cache      | 同左                          | `Keyword { Symbol sym, int hash }`                            | header + ns + name + hash_cache (Phase 1 で凍結) |
| 並列対応    | Phase ?? で後付け                    | Phase 2 で導入                | Day 1 (`ConcurrentHashMap`)                                   | Phase 2.2 で導入 (Phase 15 への伏線)             |

引っ張られずに本リポジトリの理念で整理した点：

- **Cell layout を Phase 1 で凍結**: v1 は keyword の field 構成も
  Phase をまたいで変えていましたが、本リポジトリは Phase 1 の段階で
  「header + ns + name + hash_cache」を確定させています。Phase 2 で
  動かすのは表面の API だけです。
- **`internUnlocked` という命名**: Java の `synchronized` annotation
  ではなく Zig の文化（suffix で状態を区別）に倣って命名しています。
- **Phase 2 で先回り mutex 導入**: 「single-thread だから不要」と
  Phase 15 まで遅延させません。**API シグネチャの最終形を早めに
  固定する** 方針です。

---

## 8. Feynman 課題

1. なぜ Phase 1 で書いた `intern(self, ns, name)` を、Phase 2.2 で
   `internUnlocked` にリネームしたのか。1 行で。
2. Phase 2 が single-thread なのに `std.Io.Mutex` を入れる理由は何か。
   1 行で。
3. なぜ Phase 2.1 と 2.2 を別コミットにしたのか。1 行で。

---

## 9. チェックリスト

- [ ] 演習 10.1 の 6 項目で「変わった/変わらなかった」を即答できる
- [ ] 演習 10.2 で rt-aware `intern` の本体をシグネチャだけから書ける
- [ ] 演習 10.3 で `keyword.zig` を公開 API リストだけから再構成できる
- [ ] Feynman 3 問を 1 行ずつで答えられた
- [ ] `git diff b60924b 07d5c34 -- src/runtime/keyword.zig` を読んで
      cell layout 不変を確認できた

---

## 次へ

第 0011 章: [Env を完成版に — Namespace, Var, threadlocal binding frames](./0011-env-namespace-var.md)

— Phase 2.1 で skeleton だった `Env` を、`Namespace` / `Var` /
`BindingFrame` で完成させます。Clojure dynamic var (`*ns*`, `*err*`,
`binding`) の意味論を threadlocal で実装する **正当性** を、v1
retrospective とともに掘り下げます。
