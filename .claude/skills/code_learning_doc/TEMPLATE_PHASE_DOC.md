<!-- Per-concept chapter. docs/ja/NNNN_<slug>.md.
     Body is Japanese; code blocks keep their original English identifiers.
     A chapter is a teaching unit, not a project diary. -->

---
chapter: NN                     # 1-based monotone integer
commits:
  - <SHA1>                      # oldest unpaired source commit since prev chapter
  - <SHA2>
  - ...
related-tasks:
  - §9.X.Y
related-chapters:
  - <prev-NN>
  - <next-NN>
date: YYYY-MM-DD
---

# NN — <タイトル>

> 対応 task: §9.X.Y / 所要時間: ~XX 分

<章の 2-3 行サマリ>

---

## この章で学ぶこと

- <学習目標 1>
- <学習目標 2>
- <学習目標 3>
- <学習目標 4>

---

## 1. <概念 A の見出し>

<本文。教科書として読みやすい連続的な文章。code block と図を交える>

```zig
// 該当コードの抜粋（snapshot として将来の上書きに備える）
```

### 演習 N.1: <演習タイトル> (L1 — 穴埋め / predict)

```zig
pub fn foo(x: u64) u64 {
    return x ____ ____;   // ← Q: ここを埋めよ
}
```

Q1: …
Q2: …

<details>
<summary>答え</summary>

**Q1**: ...
**Q2**: ...

理由: ...

</details>

---

## 2. <概念 B の見出し>

<本文>

### 演習 N.2: <演習タイトル> (L2 — 部分再構成)

シグネチャだけを与え、本体を書かせる。

```zig
pub fn bar(rt: *Runtime, x: Value) !Value {
    // ここから書く
}
```

ヒント:
- ...
- ...

<details>
<summary>答え</summary>

```zig
pub fn bar(rt: *Runtime, x: Value) !Value {
    ...
}
```

ポイント:
- ...

</details>

---

## 3. <概念 C の見出し>

<本文>

### 演習 N.3: <演習タイトル> (L3 — 完全再構成)

ファイル名 + 公開 API のリストだけを与え、ゼロから書かせる。

要求:
- File: `src/<path>.zig`
- Public:
  - `pub fn <name>(...) ...`
  - `pub const <Type> = ...`

<details>
<summary>答え骨子</summary>

```zig
//! <module-doc>

const std = @import("std");

pub const Type = ...;

pub fn name(...) ... {
    ...
}

test "..." {
    ...
}
```

検証: `bash test/run_all.sh` が緑になる。

</details>

---

## 4. 設計判断と却下した代替

| 案           | 採否    | 理由   |
|--------------|---------|--------|
| 案 A: <略称> | ✓ / ✗ | <一行> |
| 案 B: <略称> | ✓ / ✗ | <一行> |
| 案 C: <略称> | ✓ / ✗ | <一行> |

ROADMAP § N.M / 原則 P# への対応：<どこを満たすか>

---

## 5. 確認 (Try it)

```sh
git checkout <SHA_last>
zig build
./zig-out/bin/cljw -e "..."
# → 期待出力
bash test/run_all.sh    # 全 suite green
```

---

## 6. 教科書との対比

| 軸       | v1 (`~/Documents/MyProducts/ClojureWasm`) | v1_ref | Clojure JVM | 本リポ               |
|----------|-------------------------------------------|--------|-------------|----------------------|
| <観点 1> | <一行>                                    | <一行> | <一行>      | <本リポはどう違うか> |
| <観点 2> | ...                                       | ...    | ...         | ...                  |

引っ張られず本リポの理念で整理した点：
- <一行>
- <一行>

---

## 7. Feynman 課題

6 歳の自分に説明するつもりで答える。書けなければ理解が不完全。

1. <一行で説明する設問 1>
2. <一行で説明する設問 2>
3. <一行で説明する設問 3>

---

## 8. チェックリスト

- [ ] 演習 N.1 の答えを書ける
- [ ] 演習 N.2 を試行錯誤なしで書ける
- [ ] 演習 N.3 をファイル名と API リストだけから書ける
- [ ] Feynman 3 問を 1 行ずつで答えられる
- [ ] ROADMAP の対応 § を即座に指せる

---

## 次へ

第 NN+1 章: [<次の概念>](./<next>.md)
