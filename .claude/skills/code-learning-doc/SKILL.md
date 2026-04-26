---
name: code-learning-doc
description: Write a Japanese commit-snapshot learning document under docs/ja/ as the COMMIT THAT IMMEDIATELY FOLLOWS every source-bearing commit. Required by the pre-commit gate (scripts/check_learning_doc.sh). Trigger right after running `git commit` for a change that staged any of src/**/*.zig, build.zig, build.zig.zon, .dev/decisions/*.md.
---

# code-learning-doc

For every source-bearing commit, the **next commit** is a Japanese
learning document under `docs/ja/`. The two commits form a pair:

```
commit N      feat(scope): ...               (src/ etc., NO doc)
commit N+1    docs(ja): NNNN — ...           (docs/ja/NNNN-*.md only)
```

The doc records what changed in commit N, why, and a snapshot of the code
at that moment. Code gets overwritten over time; the doc preserves it for
later re-reading and for future technical-book / talk material.

## Why a separate commit (and not the same one)

Writing the doc AFTER the source commit means the source commit's SHA is
known when filling in the front-matter `commit:` field. No "TBD then patch
later" cycle. Cleaner history, cleaner doc.

## When to invoke

Right after `git commit` for a source change. Do not start any other work
until the doc commit lands; the gate blocks any subsequent commit until
the previous source commit is paired.

## Filename

`docs/ja/NNNN-<slug>.md`

- `NNNN` — next available 4-digit number, zero-padded
- `<slug>` — kebab-case, English-preferred (Japanese mix OK if natural)

```sh
ls docs/ja/ | grep -oE '^[0-9]{4}' | sort -n | tail -1
# increment by 1, zero-pad to 4 digits
```

## Required structure

Body in **Japanese** (per the project language policy: code and
infrastructure in English; learning docs in Japanese). Code blocks keep
their original English identifiers.

```markdown
---
commit: <SHA — get with `git log -1 --format=%h`>
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

`scripts/check_learning_doc.sh` (PreToolUse hook on Bash) examines every
`git commit` invocation. It enforces two rules:

- **Rule 1**: a commit that stages a `docs/ja/NNNN-*.md` MUST NOT also
  stage source-bearing files (`src/**/*.zig`, `build.zig`, `build.zig.zon`,
  `.dev/decisions/*.md`). Mixing defeats the SHA-pairing scheme.
- **Rule 2**: if HEAD added source-bearing files without a doc, the next
  commit MUST add the paired `docs/ja/NNNN-*.md`. Any other shape is
  blocked until the doc lands.

## Exempt commit shapes (gate is silent)

- Pure docs / README / LICENSE changes (under `docs/`, `README.md`, `LICENSE`)
- Pure `.dev/` changes excluding `.dev/decisions/`
- Pure config changes (`flake.nix`, `.gitignore`, `.envrc`, `.claude/`,
  `scripts/`)

These do not trigger the gate and do not require a paired learning doc.

## Workflow (concrete)

```sh
# 1) Source commit
git add src/eval/tree_walk.zig
git commit -m "feat(eval): add tree_walk evaluator"
SHA=$(git log -1 --format=%h)

# 2) Write the doc, then commit it
NEXT=$(ls docs/ja/ | grep -oE '^[0-9]{4}' | sort -n | tail -1)
NEXT=$(printf '%04d' $((10#$NEXT + 1)))
$EDITOR docs/ja/${NEXT}-tree-walk-evaluator.md
# fill in `commit: ${SHA}` in the front matter, then save

git add docs/ja/${NEXT}-*.md
git commit -m "docs(ja): ${NEXT} — tree_walk evaluator (#${SHA})"
```

## Why this exists

- **Code is overwritten** during refactors; the snapshot in the doc
  preserves the moment for future re-reading.
- **Background knowledge accumulates naturally** — the author absorbs Zig
  0.16 idioms and runtime-implementation theory as they write the docs.
- **Public artifact**: doubles as material for a Japanese technical book
  and conference talks.
- **Separating doc from source commit** means the SHA is known at write
  time; no "TBD" placeholder ever needs to be patched.
