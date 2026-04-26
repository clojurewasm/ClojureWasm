---
name: code-learning-doc
description: Write a Japanese commit-snapshot learning document under docs/ja/ for every code-touching commit. Required by the pre-commit gate (scripts/check_learning_doc.sh). Trigger when about to run `git commit` and any of src/**/*.zig, build.zig, build.zig.zon, or .dev/decisions/*.md is staged.
---

# code-learning-doc

This project produces a sequenced **Japanese learning document** in
`docs/ja/` for every commit that touches the source. The docs let the author
re-experience how the implementation grew, even after the code is overwritten
later. They double as material for a future technical book and conference
talks.

## When to invoke

Right after a TDD cycle (red → green → refactor) and **before** running
`git commit`. The pre-commit gate
(`scripts/check_learning_doc.sh`, wired as a `PreToolUse` hook in
`.claude/settings.json`) will block the commit if the doc is missing.

## Filename

`docs/ja/NNNN-<slug>.md`

- `NNNN` — next available 4-digit number (zero-padded)
- `<slug>` — kebab-case, English-preferred (mixing in Japanese OK if natural)

Find next number:

```sh
ls docs/ja/ | grep -oE '^[0-9]{4}' | sort -n | tail -1
```

Then increment by 1 and zero-pad to 4 digits.

## Required structure

Body in **Japanese** (per the project language policy: code and infrastructure
in English, learning docs in Japanese). Code blocks keep English identifiers.

```markdown
---
commit: <SHA, fill in after commit; can stay TBD then patched>
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

このコミットで扱うトピックの背景知識:

- **処理系理論の論点** (例: tagged union による AST 表現、Pratt parser、HAMT)
- **Zig 0.16 のイディオム** (例: std.Io.Writer の interface 化、packed struct)
- **Clojure 仕様の関連箇所** (例: var resolution の優先順、syntax-quote)

## やったこと (What)

このコミットで何を変更したか (短く):

- 新規: src/<file>.zig
- 編集: src/<other>.zig
- 削除: なし

## コード (Snapshot)

**この瞬間の状態**を残す (将来上書きされる前提で凍結):

\`\`\`zig
// src/<file>.zig (commit <SHA>)
...
\`\`\`

## なぜ (Why)

この設計判断の根拠:

- 代替案 A: ... 却下理由: ...
- 代替案 B: ... 却下理由: ...
- ROADMAP § N.M / 原則 P# への対応

## 確認 (Try it)

このコミット時点で動かして観察する:

\`\`\`sh
git checkout <SHA>
zig build run -- "..."
\`\`\`

期待出力:

\`\`\`
...
\`\`\`

## 学び (Takeaway)

将来の自分 (技術書執筆・発表) のために何を持ち帰るか:

- 処理系一般知識: ...
- Zig 0.16 知識: ...
- Clojure 知識: ...
```

## What triggers the gate

`scripts/check_learning_doc.sh` blocks `git commit` when **any** of these
patterns is staged AND no new `docs/ja/NNNN-*.md` is staged in the same
commit:

- `src/**/*.zig`
- `build.zig`
- `build.zig.zon`
- `.dev/decisions/*.md`

## Exempt commit shapes (gate is silent)

- Pure docs changes (only files under `docs/`, `README.md`, `LICENSE`)
- Pure `.dev/` changes (excluding `.dev/decisions/`)
- Pure config changes (`flake.nix`, `.gitignore`, `.editorconfig`, `.envrc`,
  `.claude/`, `scripts/`)
- Pure test fixture changes (`test/**` without any `src/**` change)

## Workflow

1. Finish the TDD cycle for one task. `bash test/run_all.sh` (or `zig build
   test`) is green.
2. Stage the source changes: `git add src/... build.zig ...`.
3. Determine the next index: `ls docs/ja/ | grep -oE '^[0-9]{4}' | sort -n | tail -1`.
4. Write `docs/ja/NNNN-<slug>.md` following the template above.
5. Stage the doc: `git add docs/ja/NNNN-<slug>.md`.
6. Commit. The gate verifies the pairing and lets the commit through.
7. After the commit, optionally patch the `commit:` SHA in the doc front matter.

## Why this exists

- **Code is overwritten** during refactors; the snapshot in the doc preserves
  the moment for future re-reading.
- **Background knowledge accumulates naturally** — the author absorbs Zig
  0.16 idioms and runtime-implementation theory as they write the docs.
- **Public artifact**: doubles as material for a Japanese technical book and
  conference talks.
