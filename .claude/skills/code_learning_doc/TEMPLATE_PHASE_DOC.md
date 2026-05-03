<!-- Per-concept chapter. docs/ja/learn_clojurewasm/NNNN_<slug>.md.
     Body is Japanese; code blocks keep their original English identifiers.
     A chapter is a teaching unit (pure exposition), not a project diary.
     Do NOT add exercises, predict-then-verify prompts, L1/L2/L3 scaffolds,
     Feynman questions, or end-of-chapter checklists. The reader reads;
     they do not drill. -->

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

<章の 2-3 行サマリ。何を扱い、なぜこの順で出てくるかを書く>

---

## この章で学ぶこと

- <学習目標 1>
- <学習目標 2>
- <学習目標 3>
- <学習目標 4>

---

## 1. <概念 A の見出し>

<本文。教科書として読みやすい連続的な文章。
要点は地の文で説明し、必要に応じて code block と図を挿入する。
読者は読み流すだけで理解できることを目指す。>

```zig
// 該当コードの抜粋（snapshot として将来の上書きに備える）
```

<コードのどこが本質か、なぜこの形なのかを地の文で続ける。
重要な数値や bit pattern は表で整理してもよい。>

---

## 2. <概念 B の見出し>

<本文>

```zig
// コード抜粋
```

<解説の続き>

---

## 3. <概念 C の見出し>

<本文>

<必要に応じて 4, 5, ... と概念を追加。1 章 = 1 概念群、
1 セクション = 1 概念。セクションだけ読んでも意味が通る粒度。>

---

## N. 設計判断と却下した代替

| 案           | 採否    | 理由   |
|--------------|---------|--------|
| 案 A: <略称> | ✓ / ✗ | <一行> |
| 案 B: <略称> | ✓ / ✗ | <一行> |
| 案 C: <略称> | ✓ / ✗ | <一行> |

ROADMAP § N.M / 原則 P# への対応：<どこを満たすか>

---

## N+1. 確認 (Try it)

```sh
git checkout <SHA_last>
zig build
./zig-out/bin/cljw -e "..."
# → 期待出力
bash test/run_all.sh    # 全 suite green
```

<手元で動かしたいときの最短手順だけを書く。
読者を試すための章末問題ではない。>

---

## N+2. 教科書との対比

| 軸       | v1 (`~/Documents/MyProducts/ClojureWasm`) | v1_ref | Clojure JVM | 本リポ               |
|----------|-------------------------------------------|--------|-------------|----------------------|
| <観点 1> | <一行>                                    | <一行> | <一行>      | <本リポはどう違うか> |
| <観点 2> | ...                                       | ...    | ...         | ...                  |

引っ張られず本リポの理念で整理した点：
- <一行>
- <一行>

---

## この章で学んだこと

<1〜3 行、または 1〜3 個の箇条書きで凝縮する。
読み終えた読者が口頭で 30 秒で再現できる結論文を選ぶ。
概念名の羅列ではなく「結局のところこの章は X だ」と言い切る形で。
同じ事実を角度を変えて並べない。最も鋭いものだけ。>

- <要点 1: 一撃で残したい核>
- <要点 2: あれば>
- <要点 3: あれば>

---

## 次へ

第 NN+1 章: [<次の概念>](./<next>.md)

<次章で扱う概念と、本章とのつながりを 1-2 行で予告する>
