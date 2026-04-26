# docs/ja/ — コミット連動学習ドキュメント

このディレクトリには、ClojureWasm の **各コミット時点のスナップショットと
その背景知識** を日本語で連番で積み上げます。

コードはどんどん上書きされていきますが、ここのドキュメントは
**その瞬間の状態を凍結** します。あとから「あの時何をやっていたか」を
辿れる、技術書 / 発表に転用できる、という二重の目的です。

## ファイル命名

`NNNN-<slug>.md` (4 桁ゼロ埋め連番 + kebab-case slug)

例:
```
0001-project-bootstrap.md
0002-build-zig-zon-fingerprint.md
0003-nan-boxing-基礎.md
```

slug は基本英語、自然なら日本語混在も可。本文は日本語。

## ルール

1. **src/ や build.zig 系を変更するコミットは、対応する `docs/ja/NNNN-*.md` の追加が必須**
2. 連番は飛ばさない・遡らない
3. `git commit` 前に `scripts/check_learning_doc.sh` (Claude Code PreToolUse hook) が自動チェック
4. 詳しい雛形と運用は [`.claude/skills/code-learning-doc/SKILL.md`](../../.claude/skills/code-learning-doc/SKILL.md)

## 含むべき要素

- **背景知識**: 処理系理論 / Zig 0.16 イディオム / Clojure 仕様
- **やったこと**: 変更点の要約
- **コードスナップショット**: そのコミット時点のコード抜粋 (将来との差分のため)
- **なぜ**: 設計判断の根拠 (代替案、却下理由、ROADMAP § 対応)
- **確認方法**: そのコミットでどう動かして見られるか
- **学び**: 将来の自分が技術書 / 発表で再利用できる一般知識
