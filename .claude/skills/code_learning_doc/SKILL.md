---
name: code_learning_doc
description: Write Japanese learning material under docs/ja/ as a textbook. Two cadences — (a) per-task short notes during the per-task TDD loop, (b) per-concept full chapters at phase boundary or every 3-5 source commits. Required by the pre-commit gate (scripts/check_learning_doc.sh).
---

# code_learning_doc

`docs/ja/` is **a textbook**, not a project diary. The reader is a future
self (and a Conj 2026 audience) studying how a Clojure runtime gets built
from scratch in Zig 0.16. The goal is **conceptual mastery through
reading**, not a chronicle of commits.

Chapters are **pure exposition** — narrative explanation, code excerpts
with commentary, and design rationale. They do **not** include exercises,
predict-then-verify prompts, L1/L2/L3 scaffolds, Feynman questions, or
checklists. The reader is expected to read straight through; the text
must carry all of the teaching weight on its own.

There are two cadences, both required:

1. **Per-task short note** — written immediately after a TDD task lands,
   while the context is hot. Captures *what got stuck*, *what referenced
   v1 / Babashka / Clojure JVM*, *what the chapter should highlight when
   the long-form is written later*. **Lives outside `docs/ja/`** — by
   default in `private/notes/<task>.md` (gitignored), so it does not pin
   commit pairing.

2. **Per-concept chapter** (`docs/ja/learn_clojurewasm/NNNN_<slug>.md`) — written at a
   phase boundary, or every 3–5 source commits when the concept is
   coherent enough to teach in one sitting. **This is the publishable
   textbook unit**. It uses the chapter template — narrative concept
   sections, design alternatives table, "Try it" runnable snippet,
   textbook comparison table, link to the next chapter.

The pre-commit gate (`scripts/check_learning_doc.sh`) only enforces the
per-concept chapters (paired commits, `commits:` front-matter). Per-task
notes are *for you*; they have no gate.

```
commit N      feat(scope): step 1            (source)
commit N+1    refactor(scope): step 2        (source)
              ↘ private/notes/<task>.md      (note, not committed)
commit N+2    fix(scope): step 3             (source)
commit N+3    docs(ja): NNNN — title         (chapter, commits: [N, N+1, N+2])
```

## When to write a per-task note

After every TDD task that landed a source commit, before moving on to
the next task. Five minutes. Capture:

- Files touched, one-line summary
- The 1–3 *things you almost forgot* / decided non-obviously
- Pointers to v1 / v1_ref / Clojure JVM / Babashka / mattpocock_skills
  that informed the implementation
- "When the chapter is written, the must-explain points are: ..."

Use `.claude/skills/code_learning_doc/TEMPLATE_TASK_NOTE.md`. The note
is a **scratchpad for the future chapter**, not a permanent artifact.

## When to write a per-concept chapter

Land a chapter when one of:

- A coherent concept (NaN boxing, Reader, Analyzer, …) is fully
  implemented across 1 to 5 source commits.
- A phase closes: write the remaining chapters that the phase introduced
  and were not yet promoted from notes.

Filename: `docs/ja/learn_clojurewasm/NNNN_<slug>.md` — `NNNN` = next available 4-digit,
`<slug>` = snake_case (English-preferred).

```sh
ls docs/ja/ | grep -oE '^[0-9]{4}' | sort -n | tail -1
```

The chapter template lives in
[`TEMPLATE_PHASE_DOC.md`](./TEMPLATE_PHASE_DOC.md). Copy it. The body
sections are pure narrative — explain the concept thoroughly, embed
code excerpts as snapshots, and walk the reader through *why* each
piece is shaped the way it is. If a section feels empty, the concept
is not yet ready for a chapter; keep iterating in notes.

### Chapter shape (single source of truth)

```
---
chapter: NN                     # 1-based, monotone with NNNN
commits:
  - <SHA1>                      # oldest unpaired source commit since prev chapter
  - ...
related-tasks: [§9.X.Y, ...]    # ROADMAP task numbers
related-chapters: [NN-1, NN+1]  # for cross-linking
date: YYYY-MM-DD
---

# NN — <タイトル>

## この章で学ぶこと   (3-5 行)
## 1. <概念 A>          ← 解説本文 + コード抜粋
## 2. <概念 B>          ← 解説本文 + コード抜粋
## 3. <概念 C>          ← 解説本文 + コード抜粋
## (必要に応じて概念を追加)
## N. 設計判断と却下した代替   (表)
## N+1. 確認 (Try it)         (実行可能スニペット)
## N+2. 教科書との対比         (v1 / v1_ref / Clojure JVM / Babashka)
## この章で学んだこと          (1〜3 行 / 1〜3 個の箇条書きで凝縮)
## 次へ → NN+1
```

「この章で学んだこと」は章末の **総括** で、章頭の「この章で学ぶこと」
とは別物。**読み終えた読者が口頭で 30 秒で再現できる結論文**を 1〜3
個に絞る。概念名の羅列ではなく「結局のところこの章は X だ」と言い切る
形で書く。同じ事実を角度を変えて並べない — 最も鋭いものだけを残す。

数だけでなく **粒度** も同じ。1 概念は 1 セクションで完結させ、
読者がそのセクションだけ読んでも意味が通るように書く。

## The two gate rules (canonical definition)

`scripts/check_learning_doc.sh` runs as a Claude Code PreToolUse hook on
Bash and is invoked on every `git commit`.

**Source-bearing file set**:
- `src/**/*.zig`
- `build.zig`, `build.zig.zon`
- `.dev/decisions/NNNN_<slug>.md` (real ADRs only — `README.md` and
  `0000_template.md` are excluded)

**Rule 1**: a commit that ADDS a `docs/ja/learn_clojurewasm/NNNN_*.md` MUST NOT also stage
source-bearing files. (Modifying an existing chapter does not count as
"adding"; mixing edits with source is fine.)

**Rule 2**: a commit that adds a new `docs/ja/learn_clojurewasm/NNNN_*.md` MUST list, in
its `commits:` front-matter, every unpaired source-bearing SHA since the
previous chapter commit. Extras allowed.

Per-task notes (`private/notes/<task>.md`) are **outside** this gate.
They are gitignored.

## Multi-chapter commits

If a phase boundary lands several chapters at once (e.g. 0007–0011 for
Phase 1), they can ride in a single commit *or* in one commit per
chapter. The gate only inspects the **first** new chapter file alphabetically
for `commits:`. **Recommendation**: include the same `commits:` list in
every chapter's front-matter so each can be read standalone, even when
the gate only enforces one. The first chapter is enough to satisfy the
gate; the rest are voluntary.

## Why this exists

- **Code is overwritten** during refactors; the chapter preserves the
  conceptual snapshot.
- **Phase chronicles drift into "what I did" reports**, which lose value
  to anyone who is not the author. Per-concept chapters organised
  around *the concept* retain instructional value to a wider audience.
- **Per-task notes prevent the "summarise five tasks at the end of the
  phase from cold context" failure mode** — the long-form chapter is
  written from hot notes, not from `git log`.

## Anti-patterns

- ❌ Writing `## やったこと` followed by 11 commit subsections. That is a
  diary. Use the chapter template instead.
- ❌ One chapter per commit. Concepts span commits; chapters span
  concepts.
- ❌ Inserting exercises, predict-then-verify prompts, L1/L2/L3
  scaffolds, Feynman questions, or end-of-chapter checklists. Chapters
  are pure exposition — the reader reads, they do not drill. If a
  point is important, explain it in prose; do not hide it behind a
  `<details>` answer block.
- ❌ Writing the chapter at the *end* of the phase from `git log` only.
  By that point the why-not's are forgotten. Use per-task notes as
  the source.
