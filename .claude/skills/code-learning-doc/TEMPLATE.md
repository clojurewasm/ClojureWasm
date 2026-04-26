<!-- Template for docs/ja/NNNN-<slug>.md
     Copy this file to docs/ja/NNNN-<slug>.md, fill in placeholders.
     Body is Japanese; code blocks keep their original English identifiers. -->

---
commits:
  - <SHA1>        # oldest unpaired source commit since the previous doc
  - <SHA2>        # newest source commit covered here
date: YYYY-MM-DD
scope:
  - src/<path>.zig
  - build.zig
related:
  - ROADMAP §N.M
  - ADR NNNN (if applicable)
---

# NNNN — <タイトル>

## 背景 (Background)

このドキュメントが扱うトピックの背景知識:

- **処理系理論の論点** (例: tagged union による AST 表現、Pratt parser、HAMT)
- **Zig 0.16 のイディオム** (例: std.Io.Writer の interface 化、packed struct)
- **Clojure 仕様の関連箇所** (例: var resolution の優先順、syntax-quote)

## やったこと (What)

各 commit が何を変更したか (commit ごとに 1 ブロック):

### <SHA1> — <subject>

- 新規: src/<file>.zig
- 編集: src/<other>.zig

### <SHA2> — <subject>

- ...

## コード (Snapshot)

**この瞬間の状態**を残す (将来上書きされる前提で凍結):

```zig
// src/<file>.zig (commits SHA1..SHA_last)
...
```

## なぜ (Why)

設計判断の根拠:

- 代替案 A: ... 却下理由: ...
- 代替案 B: ... 却下理由: ...
- ROADMAP § N.M / 原則 P# への対応

## 確認 (Try it)

```sh
git checkout <SHA_last>
zig build run -- "..."
```

期待出力:

```
...
```

## 学び (Takeaway)

将来の自分 (技術書執筆・発表) のために何を持ち帰るか:

- 処理系一般知識: ...
- Zig 0.16 知識: ...
- Clojure 知識: ...
