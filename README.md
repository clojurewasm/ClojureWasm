# ClojureWasm

A Clojure runtime written in Zig 0.16.0.

> **Status (this branch)**: ground-up redesign in progress on
> `cw-from-scratch`. The previous stable release is on `main` (v0.5.0).

## Build & test

```sh
direnv allow         # one-time: load Zig 0.16.0 via Nix
zig build            # build
zig build test       # run tests
zig build run        # run the executable (`cljw`)
```

Without direnv:

```sh
nix develop
zig build
```

## Layout

```
src/        Zig source
.dev/       Design docs, decisions, handover, status
```

See [`.dev/ROADMAP.md`](./.dev/ROADMAP.md) for mission and phase plan.

## For developers

Install via [bbin](https://github.com/babashka/bbin):

```sh
# Markdown table formatter (provides `md-table-align`)
bbin install io.github.chaploud/babashka-utilities
```

### Enable the shared git hooks

Pre-commit gates live in [`.githooks/`](./.githooks/) so they can be
shared across machines. Activate them once per clone:

```sh
git config core.hooksPath .githooks
```

The hooks invoke [`scripts/check_learning_doc.sh`](./scripts/check_learning_doc.sh)
and [`scripts/check_md_tables.sh`](./scripts/check_md_tables.sh) — the
same scripts the Claude Code agent flow runs as PreToolUse hooks. With
`core.hooksPath` set, plain `git commit` from a terminal is gated too.

## License

Eclipse Public License 2.0 — see [LICENSE](LICENSE).

EPL-2.0 follows the Clojure ecosystem convention (Clojure / Babashka / SCI
use EPL-1.0; newer projects such as Malli use EPL-2.0, the Eclipse
Foundation's current recommendation).
