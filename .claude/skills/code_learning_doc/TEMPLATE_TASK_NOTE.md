<!-- Per-task short note. Lives in private/notes/<phase>-<task>.md (gitignored).
     Five minutes to fill in. The future chapter writer reads this; you
     do not. -->

---
task: §9.X.Y
commits:
  - <SHA>            # the source commit(s) this note covers
date: YYYY-MM-DD
files:
  - src/<path>.zig
---

## 一行サマリ

<task で何が動くようになったか、1 行>

## 詰まったポイント

1. <非自明な点 1>
2. <非自明な点 2>
3. <非自明な点 3>

## 教科書との対比

- **cw v0** (git tag `v0.5.0`, via `git worktree add ../cw-v0 v0.5.0`):
  <cw v0 はどうしているか、ファイル名 + 1 行>
- **v1_ref** (`~/Documents/MyProducts/ClojureWasmFromScratch_v1_ref/...`):
  <前回はどうしていたか>
- **Clojure JVM / Babashka / Zig stdlib**:
  <該当する場合のみ>

## 設計判断（却下した案）

- 案 A: ... 却下理由: ...
- 案 B: ... 却下理由: ...

## 暫定ログ (this cycle)

<!-- Mandatory section. See .claude/rules/provisional_marker.md. List
     every PROVISIONAL marker this cycle introduced / discharged /
     newly surfaced. Empty list (= 0 net delta, none surfaced) is a
     valid entry; write "なし" explicitly so audit_scaffolding can
     tell "thought about it" from "forgot to record". -->

- 導入: <file>:<line> ref [refs: D-NNN, feature_deps.yaml#<key>]
  理由 1 行: ...
- 消化: <file>:<line> の marker 削除 (D-NNN close, feature_deps
  entry status: provisional → landed)
- 想定外: <file>:<line> で新規暫定発見 → D-NNN row 起票

## 章を書くときに必ず触れるべき点

- <演習 1 候補>
- <演習 2 候補>
- <Feynman 課題候補>
- <次章への伏線>

## TODO（直後の task に持ち越す事項）

- <あれば>
