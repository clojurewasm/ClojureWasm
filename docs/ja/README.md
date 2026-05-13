# docs/ja/ — 日本語教材のしおり

ここは ClojureWasm 関連の日本語教材を集めた場所です。2 系統あります：

- [`learn_clojurewasm/`](./learn_clojurewasm/)
  - **本編**: ClojureWasm という Clojure ランタイムが Zig 0.16 上にゼロから組み上がる過程を概念単位の章で追体験する教科書(章 0001〜)
- [`learn_zig/`](./learn_zig/)
  -  **副読本**: 本リポジトリのソースに登場する Zig 0.16.0 機能を教科書順に並べ直し、各章を解説・問題・解答の 3 段構成にまとめた単一ファイル教材

## どちらを読むべきか

- ClojureWasm 本編を **追体験する** → `learn_clojurewasm/README.md` から始める
- ClojureWasm のソースを読み始めて **Zig の文法でつまづいた** → `learn_zig/README.md` の該当章を引く

両者は独立しています。`learn_clojurewasm/` は実装ストーリーに沿って
進む設計 (章 = 概念、章 ≠ コミット)、`learn_zig/` はリポジトリで使用
されている Zig 機能の網羅的レファレンス兼演習集です。

## 言語ポリシー

本文は日本語、コードブロック内の識別子・関数名・型名・コメントは
英語です（`.claude/output_styles/japanese.md` 参照）。
