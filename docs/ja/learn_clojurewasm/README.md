# docs/ja/ — ClojureWasm を Zig 0.16 でゼロから作る教科書

ここは ClojureWasm という Clojure ランタイムが Zig 0.16 上にゼロから
組み上がっていく過程を、**概念単位の章** として追える日本語の教材
です。各章は実装が成立した時点のスナップショットを保存しつつ、
**読み流すだけで概念が掴める純粋な解説**として書かれています。

「開発の記録」ではなく「教科書」です。演習や章末問題は置きません。
読者が能動的に手を動かす負担をかけず、地の文と code 抜粋だけで
理解が成立するように本文の密度で勝負します。

## 章立て（連番）

`NNNN_<slug>.md` の形式で、4 桁連番で並びます。Phase の進行に
沿って章番号が増えますが、**章 = 概念** であり、**章 ≠ コミット**
です。1 章はおおむね 1〜5 個の source commit を背景に持ちます。

各章の冒頭には次のフロントマターがつきます：

- `chapter:` — 1 始まりの単調増加整数
- `commits:` — その章が扱う source commit SHA
- `related-tasks:` — ROADMAP §9.X.Y 番号
- `related-chapters:` — 前後の章番号

## 章の構造（テンプレ）

すべての章は同じ構造でできています（`.claude/skills/code_learning_doc
/TEMPLATE_PHASE_DOC.md` 参照）：

1. この章で学ぶこと（学習目標 3〜5 行）
2. 概念 A 本文（解説 + コード抜粋）
3. 概念 B 本文（解説 + コード抜粋）
4. 概念 C 本文（解説 + コード抜粋）
5. 設計判断と却下した代替（表）
6. 確認 (Try it) — `git checkout` で実コードを動かす最短手順
7. 教科書との対比（v1 / v1_ref / Clojure JVM / Babashka）
8. この章で学んだこと（1〜3 行 / 1〜3 個の箇条書きで凝縮）
9. 次の章へのリンク

各セクションは独立して読めるように書きます。1 セクション = 1 概念。
重要な数値や bit pattern は表で整理し、地の文では「なぜこの形か」を
語ります。

## ファイル命名

`NNNN_<slug>.md`（4 桁ゼロ埋め連番 + snake_case slug）

例:
```
0001_overview_and_methodology.md
0002_nan_boxing_value_type.md
0003_error_infrastructure.md
...
```

slug は基本英語で、違和感がなければ日本語混在も可。本文は日本語、
コードブロック内の識別子・関数名・型名は英語のまま。

## ゲート（コミットルール）

`scripts/check_learning_doc.sh` が pre-commit hook として走ります。

- **Rule 1**: 新規 `docs/ja/learn_clojurewasm/NNNN_*.md` を追加するコミットには src 系
  ファイルを混ぜない。
- **Rule 2**: 新規章の `commits:` フロントマターは、前章コミット
  以降の **未ペアの source SHA すべて** をカバーする。

詳しくは [`.claude/skills/code_learning_doc/SKILL.md`](../../.claude
/skills/code_learning_doc/SKILL.md)。

## 二段運用（重要）

`docs/ja/learn_clojurewasm/` には章だけを置きます。**章を書くための
素材**となる **per-task note** は `private/notes/`（gitignored）に
蓄積されます。
これにより：

- task 単位の「現場メモ」を記憶が熱いうちに書ける（5 分／task）
- 章は概念単位で 3〜5 個のメモを統合して書く（gated）
- `git log` を冷やしてから「Phase ごとの物語」を書く失敗モード
  を回避できる

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

この教材は将来的に：
- Conj 2026 発表資料の土台
- 日本語技術書の原稿候補
- ClojureWasm を学びたい後発者にとっての最短経路

を兼ねるものとして書かれます。そのため章は **後発者が読んで概念を
把握できる** 粒度で、しかも **著者本人が将来思い出せる** 密度で
書かれます。
