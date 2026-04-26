---
name: code-learning-doc
description: Write a Japanese learning document under docs/ja/ that covers one or more recent source-bearing commits. Each source commit's SHA goes into the doc's `commits:` front-matter list. Required by the pre-commit gate (scripts/check_learning_doc.sh). Trigger when about to consolidate a unit of work into a single readable narrative.
---

# code-learning-doc

A docs/ja/ entry is the **narrative unit of work**. One doc may cover one
or many source commits. The `commits:` front-matter list ties them
together. Code is overwritten over time; the doc preserves the moment
and explains why.

```
commit N      feat(scope): step 1            (source only)
commit N+1    refactor(scope): step 2        (source only)
commit N+2    fix(scope): step 3             (source only)
commit N+3    docs(ja): NNNN — title         (doc only, commits: [N, N+1, N+2])
```

## Why split source from doc

Writing the doc AFTER the source commits means every SHA the doc cites
is already known. No "TBD then patch later" cycle. The doc commit
itself is small and review-friendly.

## When to invoke

When a unit of work is complete and ready to be told as one story.
That may be:

- A single TDD task (1 source commit)
- A small feature spanning red / green / refactor (2–3 source commits)
- A larger feature whose intermediate states are worth keeping as
  separate commits but should be documented together (≥ 4 source commits)

The gate does **not** force you to write the doc immediately; it only
enforces that **when** you do write the doc, it covers every source
commit since the previous doc.

## Filename

`docs/ja/NNNN-<slug>.md`

- `NNNN` — next available 4-digit number, zero-padded
- `<slug>` — kebab-case, English-preferred (Japanese mix OK if natural)

```sh
ls docs/ja/ | grep -oE '^[0-9]{4}' | sort -n | tail -1
# add 1, zero-pad to 4 digits
```

## Required front-matter shape

```yaml
---
commits:
  - 116b874        # oldest unpaired source commit
  - ac2e2b9        # next
  - 83a4f1b        # newest source commit being documented here
date: YYYY-MM-DD
scope:
  - src/<path>.zig
  - build.zig
related:
  - ROADMAP §N.M
  - ADR NNNN (if applicable)
---
```

`commits:` may be inline (`commits: [a, b]`) or block form (above).
Short SHAs (7 chars) are matched against the gate's expectations.

## Required body sections

Body in **Japanese** (per the project language policy). Code blocks keep
their original English identifiers.

```markdown
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

\`\`\`zig
// src/<file>.zig (commits SHA1..SHA_last)
...
\`\`\`

## なぜ (Why)

設計判断の根拠:

- 代替案 A: ... 却下理由: ...
- 代替案 B: ... 却下理由: ...
- ROADMAP § N.M / 原則 P# への対応

## 確認 (Try it)

\`\`\`sh
git checkout <SHA_last>
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
`git commit` invocation. The "source-bearing" file set is:

- `src/**/*.zig`
- `build.zig`, `build.zig.zon`
- `.dev/decisions/NNNN-<slug>.md` (real ADRs only — `README.md` and
  `0000-template.md` under `.dev/decisions/` are excluded)

Two rules:

- **Rule 1**: a commit that stages a `docs/ja/NNNN-*.md` MUST NOT also
  stage source-bearing files. Mixing defeats the SHA-pairing scheme.
- **Rule 2**: a doc commit's `commits:` front-matter list MUST cover
  every source-bearing commit since the previous doc commit. The gate
  walks back from HEAD, collects unpaired source SHAs, and verifies
  they all appear in the doc. Extra SHAs in the doc are allowed
  (voluntary documentation of non-source commits).

Non-doc commits are unconditionally allowed; source can accumulate
unpaired indefinitely until you choose to write the doc.

## Workflow (concrete)

```sh
# 1) Source commits (any number; the gate does not block you)
git add src/eval/tokenizer.zig
git commit -m "feat(eval): tokenizer skeleton"
SHA1=$(git log -1 --format=%h)

git add src/eval/tokenizer.zig
git commit -m "refactor(eval): hoist token kind enum"
SHA2=$(git log -1 --format=%h)

# 2) Doc commit (covers SHA1 + SHA2)
NEXT=$(ls docs/ja/ | grep -oE '^[0-9]{4}' | sort -n | tail -1)
NEXT=$(printf '%04d' $((10#$NEXT + 1)))
$EDITOR docs/ja/${NEXT}-tokenizer.md
# fill in:
#   commits:
#     - $SHA1
#     - $SHA2
git add docs/ja/${NEXT}-*.md
git commit -m "docs(ja): ${NEXT} — tokenizer (#${SHA1}..${SHA2})"
```

## Why this exists

- **Code is overwritten** during refactors; the snapshot in the doc
  preserves the moment for future re-reading.
- **Background knowledge accumulates naturally** — the author absorbs
  Zig 0.16 idioms and runtime-implementation theory as they write.
- **Public artifact**: doubles as material for a Japanese technical book
  and conference talks.
- **Doc commits stay focused**: with the doc separate from source and
  capable of covering many small source commits, the developer can
  commit at the natural granularity of code changes (red, green,
  refactor) without inflating each commit to also include narrative.
