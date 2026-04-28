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

A `PreToolUse` hook on `git commit` blocks the commit if any staged
`.md` file would change under `md-table-align --check`. So you cannot
forget; you can only get a noisier commit step. Run the tool yourself
once and the gate stays quiet.

If the binary is missing, the gate prints an install guide. Short form:

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

## Other Markdown conventions for this repo

- `docs/ja/NNNN-*.md` is Japanese narrative text. Body text is
  Japanese; code blocks keep English identifiers. See
  `.claude/output-styles/japanese.md` for the prose-polish checklist
  (`〜です/〜ます` over 体言止め, "本リポジトリ" not "本リポ", etc).
- All other Markdown — `README.md`, `.dev/`, `.claude/`, `docs/`
  outside `docs/ja/`, ADRs — is English.
- Don't mix Japanese into English docs, or English prose into Japanese
  ones (identifiers in code blocks are exempt and stay English).
