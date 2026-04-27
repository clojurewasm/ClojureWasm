# docs/ja/ — ClojureWasm を Zig 0.16 でゼロから作る教科書

ここは ClojureWasm という Clojure ランタイムが、Zig 0.16 上にゼロから
組み上がっていく過程を **概念単位の章** で追える日本語の教材です。
各章は実装が成立した時点のスナップショットを保存しつつ、読者が
**手で再構成して定着させる** ための演習・予測検証・Feynman 課題・
チェックリストを備えています。

「事件の記録」ではなく「教科書」です。

## 章立て（連番）

`NNNN-<slug>.md` の形で 4 桁連番で並びます。Phase の進行に沿って
章番号が増えますが、**章 = 概念**であり、**章 ≠ コミット**です。
1 章は 1〜5 個の source commit を背景に持ちます。

各章の冒頭には：

- `chapter:` — 1 始まりの単調増加整数
- `commits:` — その章が描く source commit SHA
- `related-tasks:` — ROADMAP §9.X.Y 番号
- `related-chapters:` — 前後の章番号

がフロントマターで書かれます。

## 章の構造（テンプレ）

すべての章は同じ構造でできています（`.claude/skills/code-learning-doc
/TEMPLATE_PHASE_DOC.md` 参照）：

1. この章で学ぶこと（学習目標 3〜5 行）
2. 概念 A 本文 → 演習 N.1（L1: 穴埋め / 予測検証）
3. 概念 B 本文 → 演習 N.2（L2: 部分再構成）
4. 概念 C 本文 → 演習 N.3（L3: 完全再構成）
5. 設計判断と却下した代替（表）
6. 確認 (Try it) — `git checkout` で実コードを動かす手順
7. 教科書との対比（v1 / v1_ref / Clojure JVM / Babashka）
8. Feynman 課題（3 問）
9. チェックリスト（5 項目）
10. 次の章へのリンク

演習の答えは `<details>` で折りたためられます。**答えを見る前に
手を動かすこと**を強く推奨。これが学習効率を 2〜3 倍に押し上げる
testing effect の活用です。

## 学習方法論

姉妹リポジトリ `~/Documents/MyProducts/learn-clojurewasm-from-scratch/
code_learning/00_methodology.md` の方法論を継承しています。要点：

1. **再構成法 (Reconstruct from Memory)** — 章を閉じてから白紙に書き
   出す。最強の定着法。
2. **予測 → 検証ループ (Predict-Then-Verify)** — コード出力を紙に
   書いてから `zig build test` で確かめる。
3. **段階的写経 (L1/L2/L3)** — 穴埋め → シグネチャだけ → ファイル
   名だけ、と段階的に難易度を上げる。
4. **Feynman Technique** — 6 歳の子に説明できるか。
5. **マイクロカタ** — 1 概念あたり 5〜15 分の小演習。

## ファイル命名

`NNNN-<slug>.md`（4 桁ゼロ埋め連番 + kebab-case slug）

例:
```
0001-overview-and-methodology.md
0002-build-and-flake-bootstrap.md
0003-nan-boxing-value-type.md
...
```

slug は基本英語、自然なら日本語混在も可。本文は日本語、コードブロック
内の識別子・関数名・型名は英語のまま。

## ゲート（コミットルール）

`scripts/check_learning_doc.sh` が pre-commit hook として走ります。

- **Rule 1**: 新規 `docs/ja/NNNN-*.md` を追加するコミットには src 系
  ファイルを混ぜない。
- **Rule 2**: 新規章の `commits:` フロントマターは、前章コミット
  以降の **未対応 source SHA すべて** をカバーする。

詳しくは [`.claude/skills/code-learning-doc/SKILL.md`](../../.claude
/skills/code-learning-doc/SKILL.md)。

## 二段運用（重要）

新形式では章だけが `docs/ja/` に置かれます。**章を書く素材**となる
**per-task note** は `private/notes/` (gitignored) に貯まります。
これにより：

- task 単位の「事件メモ」を熱いうちに書ける（5 分／task）
- 章は概念単位で 3〜5 個のメモを統合して書く（gated）
- `git log` を冷やしてから `Phase ごとの物語` を書く失敗モードを回避

## 実行環境

```bash
# 本リポジトリのテストすべて
cd ~/Documents/MyProducts/ClojureWasmFromScratch
bash test/run_all.sh

# 章末の "確認 (Try it)" の実行
zig build run -- "..."
```

Zig 0.16.0 を前提。Nix flake (`flake.nix`) でピン止めされています。

## 教材としての位置付け

将来的に：
- Conj 2026 発表資料の地力
- 日本語技術書の原稿候補
- ClojureWasm を学びたい後発者の最短経路

を兼ねます。だから章は **後発者が読んで再現できる** 粒度で、しかも
**著者本人が将来思い出せる** 密度で書かれます。
