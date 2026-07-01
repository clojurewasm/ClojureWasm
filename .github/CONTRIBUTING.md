# Contributing to ClojureWasm

Thanks for your interest. ClojureWasm is an early-stage runtime built by a very
small team, so **Issues and Pull Requests are currently paused**. The most useful
things you can do right now are to **read along, try it, and report behaviour that
differs from JVM Clojure** — please do that in
[GitHub Discussions](https://github.com/clojurewasm/ClojureWasm/discussions) and
mention `@chaploud`.

## Reporting a divergence from Clojure

ClojureWasm targets behavioural equivalence with JVM Clojure on the
user-observable surface. If you find an expression that behaves differently:

1. Check whether it is already a known, intentional difference in
   [`docs/clojure_vs_clojurewasm.md`](./docs/clojure_vs_clojurewasm.md).
2. If not, start a
   [Discussion](https://github.com/clojurewasm/ClojureWasm/discussions) with the
   expression, what `cljw` prints, and what a JVM Clojure REPL prints.

## Working on the code

```sh
direnv allow                              # one-time: load Zig 0.16.0 via Nix (or: nix develop)
zig build -Dwasm -Doptimize=ReleaseSafe   # build the Wasm-enabled `cljw` binary
bash test/run_all.sh                      # the full test suite must be green before a change lands
```

`test/run_all.sh` runs the full gate; if a run flakes on a concurrency test, the
serial mode (`bash test/run_all.sh --serial-e2e`) is authoritative.

The project follows a TDD loop (red → green → refactor) and keeps tests green on
every commit. The development workflow, design principles, and the amendment
process for the roadmap are documented in [`CLAUDE.md`](./CLAUDE.md) and
[`.dev/`](./.dev/) (ROADMAP, decision records, principles). Load-bearing
decisions are recorded as ADRs under [`.dev/decisions/`](./.dev/decisions/).

A note on provenance: much of this codebase is written by an autonomous
development loop under written guardrails and ADR discipline. Human review and
direction set the rails; contributions from people are very welcome and reviewed
the same way.

## Getting in touch

Questions and discussion are welcome in
[GitHub Discussions](https://github.com/clojurewasm/ClojureWasm/discussions);
the wider Clojure community also gathers on the
[Clojurians Slack](https://clojurians.slack.com).

Security problems should **not** be reported publicly — see
[`SECURITY.md`](./SECURITY.md).

## License

By contributing, you agree that your contributions are licensed under the
Eclipse Public License 2.0 (see [LICENSE](./LICENSE)).
