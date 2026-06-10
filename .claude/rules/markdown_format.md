---
paths:
  - "**/*.md"
---

# Markdown formatting rules

Auto-loaded when editing any `.md` file. Two concerns: pipe-table
alignment, and a small set of conventions for Markdown bodies.

## Pipe tables — don't align by hand, run `md-table-align`

Manual width calculation is the wrong tool. We have a CLI that mirrors
Emacs `markdown-mode`'s `markdown-table-align` exactly. After you finish
editing any pipe table, run:

```sh
md-table-align <file>            # rewrite in place
md-table-align --check <file>    # verify (pre-commit hook does this)
```

A `PreToolUse` hook on `git commit` (`scripts/check_md_tables.sh`) checks
staged `.md` tables. **Since 2026-06-11 (user-directed) it is advisory only:**
it prints a `⚠ non-blocking` recommendation if a staged `.md` has unaligned
tables but does **not** auto-format, re-stage, or block — the earlier silent
in-place reformat drifted the gate fingerprint mid-commit. Run
`md-table-align <file>` yourself when you want tables tidied.

If the binary is missing, the hook simply skips (no block). Short form:

```sh
bbin install io.github.chaploud/babashka-utilities
```

## What the formatter enforces (informational)

The same rules `~/.claude/CLAUDE.md` describes — `md-table-align` is the
implementation:

- East Asian Wide / Fullwidth characters count as width 2. This covers
  kanji / hiragana / katakana (incl. the long-vowel mark `ー`), Hangul,
  and fullwidth ASCII / signs (`（）「」：`, `！？` etc.).
- Halfwidth ASCII counts as width 1.
- Each column's width is set to the longest cell in that column, plus
  one space of padding on each side.
- Alignment markers `:---`, `---:`, `:---:` in the delimiter row are
  honored.

Knowing the rule helps you sanity-check the formatter's output, but
your job is **never** to compute widths in your head.

## Language policy + Japanese narrative conventions

See [`.claude/output_styles/japanese.md`](../output_styles/japanese.md)
for the canonical rule. Summary:

- English by default for all Markdown — `README.md`, `.dev/`,
  `.claude/`, ADRs, `docs/` outside `docs/ja/`.
- Japanese for chat replies, `private/notes/<task>.md`, and
  `docs/ja/` body text (code blocks keep English identifiers).
- Do not mix: identifiers in code blocks are the only exception.
