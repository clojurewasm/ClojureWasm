# docs/ja/ — 日本語教材のしおり

ここは ClojureWasm 関連の日本語教材を集めた場所です。

## 現状：章執筆は休眠中 (Phase 4 critical-path close 時点)

ADR-0029 に基づき、 Phase 1-3 期に書かれた既存章 (learn_clojurewasm
全 20 章 + learn_zig 副読本) は [`archive/`](./archive/) に一括移動
されています。 章カデンス (新章の追加義務) は **休眠** していますが、
per-task notes (`private/notes/`) は引き続き書かれ、 将来の章再生成の
入力として温存されます。

| ステータス        | 場所                                                                                   | 説明                                                                                                 |
|-------------------|----------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------|
| **休眠中** (本編) | (空)                                                                                   | 次の再開 ADR が出るまで新章は追加されません。 過去章は archive 参照。                                |
| **アーカイブ**    | [`archive/learn_clojurewasm_v1_phase1to3/`](./archive/learn_clojurewasm_v1_phase1to3/) | Phase 1-3 (cw-from-scratch redesign 期) の本編 20 章 + README。 設計過渡期の遺物として読み取り専用。 |
| **アーカイブ**    | [`archive/learn_zig_v1/`](./archive/learn_zig_v1/)                                     | Zig 0.16.0 文法副読本 (Phase 1-3 期向け 30 章)。 同上。                                              |

### なぜ休眠なのか

Phase 4 が dual backend (TreeWalk + VM) を導入し、 Phase 1-3 期の
複数の設計面を書き換えました (`Function.bytecode`、 vtable
`evalChunk` フック、 `callFunction` のルーティング 等)。 Phase 1-3
の章を継続として 0021 から書き続けると、 読者に「2 つの設計を順に
追体験」 を強いる結果になります。 ADR-0029 はこれを避け、 archive
+ regenerate (大規模刷新後の一括再生成) を選びました。

### 再開はいつか

再開条件は ADR-0029 §3 参照。 候補は Phase 4 closure
(4.13-4.26.f 完了) または Phase 5 entry (mark-sweep GC +
TypeDescriptor activation) です。 再開時は新章サイクルが `0001`
から再スタートします。

## 言語ポリシー

本文は日本語、 コードブロック内の識別子・関数名・型名・コメントは
英語です (`.claude/output_styles/japanese.md` 参照)。

## 関連

- ADR-0029 — Big-bang chapter regeneration boundary at Phase-4
  critical-path close (`.dev/decisions/0029_chapter_archive_boundary.md`)
- code_learning_doc skill (`.claude/skills/code_learning_doc/SKILL.md`) —
  cadence 規定 (現在は dormancy)
