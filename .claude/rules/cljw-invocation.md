---
paths:
  - "test/e2e/**/*.sh"
  - "bench/**/*.sh"
  - "scripts/**/*.sh"
  - "src/main.zig"
---

# Invoking `cljw` safely (Phase 3.1+)

Auto-loaded when editing scripts that drive the `cljw` binary. Use
this rule whenever you write a smoke / e2e / bench script, or when
debugging interactively.

## Three entry points

`cljw` accepts code in three shapes (all available from §9.5 task
3.1 onward):

| Shape           | Invocation              | Use when                                |
|-----------------|-------------------------|------------------------------------------|
| Inline string   | `cljw -e '<expr>'`      | One-liner with no shell-special chars.  |
| File           | `cljw path/to/file.clj` | Multi-line code, fixtures, real scripts. |
| Stdin          | `cljw -` (`-` literal)  | Heredoc, pipe from another command.      |

Until 3.1 lands, only `-e` works.

## Why `-e` is fragile in zsh

zsh expands history references (`!`), parameter substitutions (`$x`,
`${x}`), command substitution (`` `cmd` ``, `$(cmd)`), and globs
inside double-quoted strings. Several Clojure idioms collide:

| Clojure surface | Zsh interpretation                    | Failure mode                          |
|-----------------|---------------------------------------|---------------------------------------|
| `name!`         | `!name` history reference             | `zsh: event not found: ...`           |
| `(deref @atom)` | nothing — but `\\@atom` may be eaten  | Edge case in deeply-nested quotes.    |
| `$ARGS`         | shell variable expansion              | `cljw -e "(+ $x 1)"` → `(+  1)` if `$x` unset. |
| `` `name` ``    | command substitution                  | shell tries to run a program.        |
| `*foo*` (earmuff dynamic var) | glob expansion       | filename match in cwd substitutes the symbol. |

Single-quoting (`-e '...'`) defeats most of these, **but**:
- History expansion (`!`) still happens inside single quotes in
  interactive zsh by default. Disable with `set +H` or just use a file.
- You cannot embed a literal single-quote inside `'...'` without
  closing+reopening (`'...'\''...'`), which is unreadable for
  Clojure code with `'symbol` quote forms.

So **`-e` is fine for tests where you control the input**, but
**fragile for anything user-typed or anything containing earmuffs /
quote forms / non-trivial strings**.

## Preferred patterns

### A. File for fixtures / e2e / benches

Put the Clojure source in a real file under `test/e2e/fixtures/` or
`bench/fixtures/`. Invoke with `cljw fixtures/foo.clj`. This is the
canonical pattern for `test/e2e/*.sh` and `bench/*.sh`.

```bash
# test/e2e/phase3_macros.sh
got=$("$BIN" test/e2e/fixtures/defn_basic.clj)
[[ "$got" == "3" ]] || fail
```

### B. Heredoc via stdin for inline-but-tricky code

When the code stays inline (so the script is self-contained) but
contains shell-specials, pipe via heredoc:

```bash
# Single-quoted heredoc — NO shell expansion happens inside.
got=$("$BIN" - <<'EOF'
(defn name! [x] (str "hi, " x))
(name! "world")
EOF
)
[[ "$got" == '"hi, world"' ]] || fail
```

Note the **single-quoted `'EOF'`** delimiter — that's what suppresses
expansion. Without quotes around `EOF` the heredoc would still
expand `$x`, `` `cmd` `` etc. The `eval-nrepl` skill uses the same
pattern; mirror it here.

### C. `-e` for trivial inputs only

`-e` is fine when:

- The expression has no `!`, `$`, `` ` ``, `*` outside of math `*`,
  or earmuff `*foo*`.
- The expression fits cleanly on one line.
- The script writer can audit every character.

```bash
"$BIN" -e '(+ 1 2)'                 # safe
"$BIN" -e '(let* [x 1] (+ x 2))'    # safe
"$BIN" -e '(println *out*)'         # NOT safe (zsh globs *out*)
```

## When in doubt

Default to **B (heredoc)** for scripts you write. It always works,
costs one extra line, and the intent ("run this exact code") is
visible.

For interactive debugging at the prompt, `cljw <file>` is usually
fastest — keep a `scratch.clj` around.
