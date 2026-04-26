---
name: code-learning-doc
description: Write a Japanese learning document under docs/ja/ that covers one or more recent source-bearing commits. Trigger when a unit of work is ready to be told as one narrative — typically after a series of source commits, before continuing to the next unit. Required by the pre-commit gate (scripts/check_learning_doc.sh).
---

# code-learning-doc

A `docs/ja/NNNN-<slug>.md` is the **narrative unit of work**. One doc
covers one or many source commits via a `commits:` list in its front
matter. Code is overwritten over time; the doc preserves the moment.

```
commit N      feat(scope): step 1            (source only)
commit N+1    refactor(scope): step 2        (source only)
commit N+2    fix(scope): step 3             (source only)
commit N+3    docs(ja): NNNN — title         (doc only, commits: [N, N+1, N+2])
```

## When to invoke

When the source commits since the last doc form a tellable story.
That may be 1 commit, or 5. The gate does not force you immediately;
it only enforces correctness when you do write the doc.

## Filename and template

`docs/ja/NNNN-<slug>.md` — `NNNN` = next available 4-digit, `<slug>` =
kebab-case (English-preferred, Japanese OK).

Find next index:
```sh
ls docs/ja/ | grep -oE '^[0-9]{4}' | sort -n | tail -1
```

The full template (front matter + body sections) lives in
[`TEMPLATE.md`](./TEMPLATE.md) next to this file. Copy it as the
starting point.

## The two gate rules (canonical definition)

`scripts/check_learning_doc.sh` runs as a Claude Code PreToolUse hook on
Bash and is invoked on every `git commit`. It defines the workflow.

**Source-bearing file set**:
- `src/**/*.zig`
- `build.zig`, `build.zig.zon`
- `.dev/decisions/NNNN-<slug>.md` (real ADRs only — `README.md` and
  `0000-template.md` under `.dev/decisions/` are excluded)

**Rule 1**: a commit that ADDS a `docs/ja/NNNN-*.md` MUST NOT also stage
source-bearing files. (Modifying an existing doc does not count as
"adding"; mixing modifications with source is fine.)

**Rule 2**: a commit that adds a new `docs/ja/NNNN-*.md` MUST list, in
its `commits:` front-matter, every unpaired source-bearing SHA since the
previous doc commit. Extras allowed (voluntary documentation of
non-source commits).

Non-doc commits are unconditionally allowed; source can accumulate
unpaired indefinitely until the doc lands.

## Workflow (concrete)

```sh
# Source commits — any number, the gate does not block
git add src/eval/tokenizer.zig
git commit -m "feat(eval): tokenizer skeleton"

git add src/eval/tokenizer.zig
git commit -m "refactor(eval): hoist token kind enum"

# Doc commit — covers both
SHAs="$(git log --format=%h <last-doc-commit>..HEAD)"
NEXT=$(printf '%04d' $(($(ls docs/ja/ | grep -oE '^[0-9]{4}' | sort -n | tail -1) + 1)))
cp .claude/skills/code-learning-doc/TEMPLATE.md docs/ja/${NEXT}-tokenizer.md
$EDITOR docs/ja/${NEXT}-tokenizer.md
# fill commits: list with $SHAs, fill body sections
git add docs/ja/${NEXT}-*.md
git commit -m "docs(ja): ${NEXT} — tokenizer (#$(echo $SHAs | tr ' ' .))"
```

## Why this exists

- **Code is overwritten** during refactors; the snapshot in the doc
  preserves the moment for future re-reading.
- **Background knowledge accumulates naturally** — the author absorbs
  Zig 0.16 idioms and runtime-implementation theory through writing.
- **Public artifact**: doubles as material for a Japanese technical book
  and conference talks.
- **Doc commits stay focused**: with the doc separate from source and
  capable of covering many small source commits, the developer can
  commit at the natural granularity of code changes (red, green,
  refactor) without inflating each commit to also include narrative.
