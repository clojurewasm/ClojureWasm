# Contributing to ClojureWasm

Thanks for your interest. **Issues and Pull Requests are open.** This is a
small project, so replies can take a while — but the queue is real and it gets
read.

## The most useful thing you can do

**Report Clojure code that behaves differently here than on the JVM.**

ClojureWasm targets behavioural equivalence with JVM Clojure on the
user-observable surface. Every divergence you find is either a bug or a gap
that has not been written down yet — and finding them from the outside is worth
more than anything else, because a project cannot easily see its own blind
spots.

There is a [Clojure divergence issue template](https://github.com/BuddhiLW/ClojureWasm/issues/new?template=divergence.yml)
that asks for the three things that make such a report actionable: the
expression, what `cljw` prints, and what a JVM REPL prints.

Some differences are deliberate — check
[`docs/clojure_vs_clojurewasm.md`](../docs/clojure_vs_clojurewasm.md) first. If
one is listed there and you think the reasoning is wrong, that is a good
Discussion.

## Working on the code

```sh
direnv allow                              # one-time: load Zig 0.16.0 via Nix (or: nix develop)
zig build -Dwasm -Doptimize=ReleaseSafe   # build the Wasm-enabled `cljw` binary
bash test/run_all.sh --serial-e2e         # the full gate; must be green before a change lands
```

[`docs/testing.md`](../docs/testing.md) is the full guide — every layer, how to
run it, how to read its failures, and where a new test belongs. The short
version of the parts you are most likely to need:

Two of the newer layers have their own entry points (ADR-0186):

```sh
bash test/golden/run.sh              # Layer 6: whole-program output snapshots
bash test/golden/run.sh --update     # re-record them, then READ the diff
zig build test -Dprop-seed=0xdecafbad -Dprop-iters=5000   # Layer 7: a deeper property sweep
```

If your change alters what a program prints — a value's printed form, an
error message, an exit code — a golden snapshot will fail. That is the layer
working. Regenerate it, read the diff, and include it in the PR; a snapshot
regenerated without being read is worse than no snapshot.

For a quick loop while iterating, `bash test/run_all.sh --smoke <e2e-step>`
runs the unit tests, the dual-backend differential oracle, the linter, and the
one end-to-end step you touched — tens of seconds instead of ~20 minutes. Run
the full gate before you open the PR.

Branch from `staging` as `develop/<short-slug>` and open the PR against
`staging`; `main` only moves by a release PR from `staging`. CI runs the same
gate on macOS and Linux; a green CI is what merges.

### Tools the gate needs, and tools it does not

The gate needs Zig 0.16.0, `bb` (Babashka), `python3`, `yq` and `rg`. The Nix
dev shell (`flake.nix`) provides all of them; CI installs the same set.

Some files in the repo describe the maintainer's own tooling. You can skip it:

- **`clj` (the Clojure CLI).** The differential-oracle tools
  (`bb scripts/clj_diff_sweep.clj`, `scripts/lib_conformance.sh`) run real
  Clojure through it, resolved from `PATH`. The gate does not call it. Install
  it from <https://clojure.org/guides/install_clojure> only if you want to
  compare against the JVM yourself, which is also how you fill in the
  divergence issue template.
- **`md-table-align`.** A commit hook uses it to report unaligned Markdown
  tables. The hook is advisory and exits silently when the tool is absent.
- **Reference clones under `~/Documents/OSS`.** `.dev/reference_clones.md`
  lists upstream sources (JVM Clojure, Babashka and others) to read during a
  design survey, each with its `git clone` command. A fresh clone has none,
  the gate step that checks them skips, and the e2e steps that read one skip
  when it is absent. To let a Claude Code session read a clone outside the
  repo, add it to `permissions.additionalDirectories` in your own
  `.claude/settings.local.json` (gitignored).
- **`private/`.** Gitignored per-developer scratch. Older notes, ledgers and
  test headers cite `private/notes/*.md`; those files never ship, and nothing
  the gate runs reads them. Where one held something load-bearing, it was
  promoted into a tracked file (for example
  `test/diff/clj_corpus/COVERAGE.md`).
- **`.claude/`.** Settings and skills for the maintainer's Claude Code loop.
  Chat language is whatever your client uses; no hook forces one.

### What we do **not** ask of you

This repository is developed largely by an autonomous loop working under
written guardrails, and that loop follows conventions that exist to keep *it*
honest. **None of them apply to your contribution:**

- You do not need a `Smell-audited:` line in your commit message.
- You do not need to add a row to `.dev/debt.yaml`.
- You do not need to write an ADR, a per-task note, or a ROADMAP amendment.
- You do not need to match the commit-message style of the surrounding history.

Write a clear commit message, keep the gate green, and that is enough. If a
change turns out to need a design record, writing it is the maintainer's job,
not yours.

### What helps a PR land

- **One concern per PR.** A 30-line fix with a test merges; a 600-line
  refactor bundled with a fix stalls.
- **A test that fails before your change and passes after it.** The test
  taxonomy is in [`docs/testing.md`](../docs/testing.md); in short, unit
  tests live in `test "..."` blocks next to the code and CLI behaviour lives
  in `test/e2e/*.sh`.
- For a `clojure.core` behaviour change, **a line in the relevant corpus under
  `test/diff/clj_corpus/`**, so the behaviour stays checked against real `clj`
  from then on.

### When CI runs

CI (`.github/workflows/ci.yml`) triggers on `pull_request`, on a push to
`main`, and on manual dispatch. A push to `staging` gets no remote CI by
design: `staging` is the integration branch, and its machine-checked verdict
is the PR from `staging` to `main`, which runs the same full gate. Run
`scripts/ci_gate.sh` locally before pushing to `staging`; that is the only
gate those commits get until the PR.

Every push to a branch with an open PR fires `pull_request: synchronize` and
restarts that PR's CI from the beginning. Once a PR is green and you intend to
merge it, stop pushing to its branch.

A note on provenance: much of this codebase is machine-written under human
review and direction. Contributions from people are very welcome and are
reviewed the same way — on whether the code is right, not on who wrote it.

## Design context, if you want it

Load-bearing decisions are ADRs, cited by number (`ADR-NNNN`) in commit
messages; the plan and its principles live in
[`.dev/ROADMAP.md`](../.dev/ROADMAP.md), the invariants in
[`.dev/project_facts.md`](../.dev/project_facts.md), and the shape of the
runtime in [`docs/architecture.md`](../docs/architecture.md). None of this is
required reading to send a patch; it is there if you want to know why
something is the way it is.

## Getting in touch

Open-ended questions belong in
[GitHub Discussions](https://github.com/BuddhiLW/ClojureWasm/discussions);
the wider Clojure community also gathers on the
[Clojurians Slack](https://clojurians.slack.com).

Security problems should **not** be reported publicly — see
[`SECURITY.md`](./SECURITY.md).

## License

By contributing, you agree that your contributions are licensed under the
Eclipse Public License 2.0 (see [LICENSE](../LICENSE)).
