# Testing ClojureWasm

Everything you need to run the suite, read a failure, and put a new test in the
right place. If you are here to send a patch, the short version is:

```sh
bash test/cljw-test              # the gate; must be green before a change lands
```

That takes roughly 20 minutes. While iterating, use the smoke tier instead
(tens of seconds) and run the gate once before you open the PR:

```sh
bash test/cljw-test --only smoke          # unit + diff oracle + lint + build
bash test/cljw-test --list                # every runnable unit, with its layer
bash test/cljw-test --layer 6             # everything in one layer
bash test/cljw-test --only golden,tier_a  # named units
bash test/cljw-test --step e2e_phase4_cli # one inner gate step
bash test/cljw-test --dry-run             # print the selection, run nothing
```

Anything after `--` is appended to the selected unit's command, so a unit takes
its own options without the CLI growing a flag for each:

```sh
bash test/cljw-test --only mutation -- --targets src/runtime/collection/vector.zig --budget 8
bash test/cljw-test --layer 7 -- -Dprop-seed=0xdecafbad -Dprop-iters=5000
```

You need Zig 0.16.0 plus three things the gate shells out to: **ripgrep**,
**yq** (mikefarah v4 — `check_compat_members` exits 1 without it, it does not
skip), and **bash 4 or newer** (macOS ships 3.2). The hosted CI images happen to
carry yq, which is why its absence only ever showed up locally.

## One entry point, and how that is enforced

`test/cljw-test` is the entry point. `test/units.list` is the inventory behind
it — one row per runnable unit, `id|layer|gated|tags|command` — and
`scripts/check_runner_reach.sh` fails when a runnable script has no row.

That check is the whole point. This document used to claim single-entry status
for `test/run_all.sh`; at the time of writing 15 of 38 check scripts were not
reachable from it, and nothing could tell you so. A claim about coverage that
no check can falsify decays into decoration.

A script that should not run in the suite gets a row with `gated=no` and a tag
saying which KIND of exclusion it is — `timing` for benches, `measurement` for
mutation, `network` for the verified-projects loop, `authoring` for checks that
inspect a commit being written, `hook` for a PreToolUse hook that reads a JSON
payload on stdin and so has nothing to inspect in a batch run, `on-demand` for a
script kept out by a recorded decision, `dormant` for one whose discipline an
ADR has suspended. An exclusion is declared, never an absence, and it names the
reason it is settled. `todo:` is the one tag that is not settled, and
`check_runner_reach.sh` fails on it: an exclusion carries a settled kind or the
script goes.

`check_runner_reach` runs inside the gate (`run_all.sh`, step `runner_reach`),
so an unregistered script fails a normal run rather than waiting for someone to
invoke the meta-check by hand.

The composites (`full`, `gate`, `smoke`, `ci`) delegate to `test/run_all.sh` and
`scripts/run_gate.sh`, which still own step dispatch, the resume ledger and the
parallel e2e pool. Those remain callable directly; the CLI is the front door,
not a replacement.

**CI enters through the CLI too.** `.github/workflows/ci.yml` runs
`scripts/ci_gate.sh`, which is two `cljw-test` calls — `--only fmt`, then
`--only full`. What `full` runs is the registry row, so the gate configuration
is defined in one place instead of being repeated per launcher.
`scripts/check_gate_parity.sh` resolves that row by running
`cljw-test --only full --dry-run` and comparing, so CI-vs-local agreement is
executed rather than asserted.

**The build lock is not a guarantee.** Every unit run through `cljw-test` takes
`.dev/.build.lock`, so two builds cannot overlap *through the CLI*. A `zig
build` you run by hand ignores it. Two concurrent builds are enough to make a
machine unusable, so if you are working alongside someone else in the same
checkout, go through the CLI or coordinate by hand.

## The eight layers

A test belongs to exactly one layer, and choosing the layer is the first
decision — not an afterthought. Layers 1-5 are ADR-0021; 6-8 are ADR-0186.

| # | Layer | Lives in | Run with | In the gate? |
|---|---|---|---|---|
| 1 | Unit | `src/**/*.zig`, inline `test "..."` blocks | `cljw-test --only unit_vm` | every commit |
| 2 | E2E (CLI) | `test/e2e/*.sh` | `cljw-test --step <name>` | every commit |
| 3 | Differential | `test/diff/` | `cljw-test --layer 3` (both backends) | every commit |
| 4 | Bench | `bench/` | `cljw-test --tag timing` | no — on demand |
| 5 | Conformance | `test/clj/` | `cljw-test --only tier_a` | every commit |
| 6 | Golden | `test/golden/cases/*.clj` + `.expected` | `cljw-test --layer 6` | every commit |
| 7 | Property | `src/testing/prop_*.zig` | `cljw-test --layer 7` | every commit |
| 8 | Mutation | `scripts/mutation/` | `cljw-test --only mutation` | **no** — a measurement |

Conformance against real libraries (`scripts/verify_projects.sh`, 21 libraries
including malli) is `cljw-test --only verify_projects`. It is outside the gate:
it clones over the network, and it stops at the FIRST blocking site with a
`file:line` so each fix reveals exactly one more. That one-answer-per-run
property is why it is tagged `failfast` rather than aggregated with the rest.

### Which layer does my test go in?

Ask in order and stop at the first yes:

1. **One deterministic function call, no I/O?** → Layer 1. Write it inline, next
   to the function, in a `test "..."` block. This is the default and most tests
   belong here.
2. **`cljw -e '...'`, a script file, exit codes, an error message?** → Layer 2.
3. **TreeWalk and VM must agree on the same source?** → Layer 3.
4. **A performance number?** → Layer 4, and run it on a quiet machine. Do not
   put a timing assertion in Layer 1 — see "Wall-clock" below.
5. **A port of an upstream Clojure test?** → Layer 5.
6. **Everything the program printed must stay the same?** → Layer 6.
7. **A law that must hold for every input, not just chosen ones?** → Layer 7.

Layer 8 is not a place to put a test. It tells you which lines the layers above
are failing to constrain.

## Layer 6 — golden snapshots

A case is a whole program. Its snapshot is stdout, stderr and the exit code in
one file, so it fails for *any* change in what the user sees — a reworded error,
a dropped newline, a value that starts printing its metadata.

```sh
bash test/golden/run.sh                  # verify
bash test/golden/run.sh --only printer   # substring-filter case names
bash test/golden/run.sh --update         # re-record every changed snapshot
CLJW_SKIP_BUILD=1 bash test/golden/run.sh          # skip the rebuild
CLJW_BIN=/path/to/cljw bash test/golden/run.sh     # test some other binary
```

**Adding a case**: drop `test/golden/cases/<name>.clj` in, run `--update`, then
**read the generated `.expected`** and commit both.

**When one fails**: the runner prints a unified diff. Decide which side is
right. If your change was meant to alter that output, run `--update`, read the
diff, and include it in the PR. A snapshot regenerated without being read is
worse than no snapshot — it records a bug as readily as a behaviour.

Determinism comes from explicit normalisation, not from luck: the repo path, hex
addresses, pids, durations and the version string are rewritten to fixed tokens
before comparison. If your case is still non-deterministic after that, it does
not belong in this layer.

## Layer 7 — properties

A property states a law over *generated* input and, when it fails, shrinks the
counterexample and prints the seed that produced it.

```sh
zig build test -Dwasm -Doptimize=ReleaseSafe        # gate defaults: fixed seed, 60 iterations
zig build test -Dwasm -Dprop-seed=0xdecafbad -Dprop-iters=5000   # a deeper sweep
zig test src/testing/prop.zig                        # the engine's own tests, in seconds
```

The seed is **fixed by default** on purpose: a gate whose input set changes per
run reports something different each time it is asked, and a failure nobody can
reproduce is a failure nobody fixes. When a sweep does find one, pin that seed
into the default in `build.zig` as part of the fix, so the gate keeps looking
where the bug was.

A failure looks like this, and the last line is copy-pasteable:

```
property FAILED on iteration 12 with TestExpectedEqual
  smallest failing input: [3, 0]
  reproduce: zig build test -Dprop-seed=0x10be15eed -Dprop-iters=60
```

**Writing one** needs an oracle that shares no implementation with the code
under test. Three that work here:

- **A law** — `pop` undoes `conj`; `dissoc` undoes `assoc`; insertion order does
  not change the result.
- **A model** — a plain Zig array doing the obviously-correct thing, fed the
  same operations as the persistent structure.
- **A second implementation** — TreeWalk against VM (that is Layer 3).

**Cross the representation boundaries deliberately.** `map` promotes from
ArrayMap to a HAMT past 16 entries, `set` past 8, and `vector` spills its tail
into a trie that grows a level at 1057 elements. Discussion #12 was a bug that
existed only above one of those lines while every fixture sat below it.

The properties live in `src/testing/`, not `test/prop/`, because `zig build
test` compiles one module rooted at `src/main.zig` and Zig rejects an `@import`
that leaves the module directory. `test/prop/README.md` says so and points at
the real location.

## Layer 8 — mutation

Not a test. It changes one line of one source file, rebuilds, runs the unit
suite, and records whether anything failed. A mutant that survives names a line
whose behaviour **no test constrains**.

```sh
bash scripts/mutation/run.sh --targets src/runtime/collection/vector.zig --budget 8
bash scripts/mutation/run.sh --targets-from .dev/mutation_targets.txt --budget 20 --seed 7
bash scripts/mutation/run.sh --targets v.zig --ids 9474dd05b9cf     # re-run named mutants
```

It costs **one full rebuild per mutant**, so `--budget` is the number of
rebuilds you are buying. Reports land in `.dev/mutation/` (gitignored; commit a
report deliberately with `git add -f` when it is worth keeping).

Three things to know before running it:

- **It never touches your checkout.** It builds a detached git worktree at a
  revision, mutates there, and removes it. Never point a mutation tool at a tree
  with uncommitted work.
- **It refuses to run on a red baseline.** A suite that is already failing
  reports every mutant as killed — a perfect score for a broken suite.
- **It is not a gate.** A survivor is a missing test to schedule, not a commit
  to reject.
- **Named IDs survive relocation.** IDs derive from the enclosing function and
  mutation content, not file path or line number. `.dev/mutation_id_aliases.jsonl`
  keeps pre-2026-09-03 line-based IDs replayable after code moves and file splits.

**The loop that makes a survivor useful**: the sweep names a line → you write
the test that should have constrained it → you re-run *that* mutant with
`--ids` and watch it die. Without `--ids` you are re-sampling and hoping.

### Equivalent mutants

Some mutants cannot be killed, because they change the source without changing
the program. A survivor is only a missing test *after* you have ruled that out.

`.dev/mutation_equivalent.jsonl` is the register of the ones already ruled out.
Each row matches on `file` + `op` + `before` and carries a `reason`, which is a
**proof obligation**: state why no input can distinguish the mutant. Registered
mutants are dropped from the score instead of counted against it. An entry that
matches no enumerated candidate is reported as **STALE** and the run exits
non-zero — a line that moved has outrun its proof, so the mutant returns to the
survivor list rather than staying quietly excused.

Reach for the register only with an argument you could defend, and never to
quiet a survivor you have not understood. The two entries in it today are both
index arithmetic feeding a `>> SHIFT_BITS`, where the mutated constant lands in
the same 32-element leaf as the original.

### What the first sweep actually found

The first sweep (`.dev/mutation/report-ce5cb6c8-seed1.md`) scored 50%, and all
three of its survivors were in `popTail`'s deep-trie collapse — beyond the reach
of the vector property, whose generator stopped at 96 elements when the trie
only grows a level at 1057. Adding a deep-trie property killed one of them
(`bool_and_to_or` on the collapse condition) and proved the other two equivalent
by the argument above.

Both halves of that are the point. The property looked correct, *was* correct,
and never reached the branch it was aimed at — only the mutant showed it. And
two thirds of a survivor list turned out not to be work at all, which is why the
verdict is a starting point for an argument and not a score to optimise.

## Wall-clock assertions

Elapsed time is not deterministic, and CI runners are noisy.

- A **lower** bound is safe: load makes things slower, never faster.
- An **order-of-magnitude upper** bound is safe: it separates a hang from a busy
  machine.
- A **ratio** upper bound is a flake generator. It cannot distinguish a 20%
  regression from a 50% busy runner, so it eventually fails for the one reason
  it was not written to detect. Put the ratio in Layer 4 and record the numbers.

## Conventions

- Name a Layer 1 test for the behaviour, not the mechanism: `test "+ on two
  integers"`, not `test "primAdd inline call"`.
- A shell e2e exits non-zero on failure and prints the failing case name.
- Never use a bare `timeout` in anything the gate runs — the macOS runner has
  neither `timeout` nor `gtimeout`. Use the `run_bounded` helper;
  `scripts/check_portable_timeout.sh` enforces it.
- Never run a concurrent build during a gate.
- `zig build test` without `-Dwasm` builds a different configuration from the
  one that ships.

## What the loop's conventions do NOT ask of you

This repository is developed largely by an autonomous loop under written
guardrails, and that loop follows conventions that exist to keep *it* honest.
None of them apply to an outside contribution: no `Smell-audited:` line, no
`.dev/debt.yaml` row, no ADR, no ROADMAP amendment. Write a clear commit
message, keep the gate green, and that is enough. See
[`.github/CONTRIBUTING.md`](../.github/CONTRIBUTING.md).
