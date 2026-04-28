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

## License

Eclipse Public License 2.0 — see [LICENSE](LICENSE).

EPL-2.0 follows the Clojure ecosystem convention (Clojure / Babashka / SCI
use EPL-1.0; newer projects such as Malli use EPL-2.0, the Eclipse
Foundation's current recommendation).
