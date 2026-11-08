# ClojureWasm

A Clojure runtime written in Zig 0.16.0. Binary and package name: `cljw`.

> Loaded on every turn, so it holds only what is true on every turn:
> invariants, identity, the priority chain, and ids. Procedure lives in
> hive memory and is fetched when the step actually runs.
> `mcp__hive__memory get :id <id>`

## Priority chain (top-down; higher wins, lower is edited to align)

1. `.dev/project_facts.md` F-NNN, user-declared, treated as project law.
   The loop **never** amends an F-NNN on its own.
2. `.dev/ROADMAP.md` engineering plan.
3. Implementation decisions, all in memory now (ADRs tagged `adr-NNNN`, the rule
   corpus tagged `cljw-rule`; both indexed below). Amendable by the loop
   autonomously (depth 2-4) by editing the ENTRY, never by re-creating a file.
4. The smell sensors and depth selection, in memory: the catalogue is
   `memory query :tags ["bad-smell"]` (24 entries, open set); the premises and the
   three finished-form questions are `20260911004145-29ffd52a`; depth 1-4 plus the
   mandatory devil's-advocate fork at depth >= 2 are `20260901165122-24182b0a`
   and `20260901164941-6357af6c`; structural imagination and its F-003 / F-015
   scope boundary are `20260911004146-720ff81e`.
5. AI judgement fills in the rest.

Treating an F-NNN as "informational" / "tie-breaker" / "recommendation" is the
Smallest-diff bias smell and is forbidden.

**Project spirit: the finished form's cleanliness wins.** Shipping fast and
avoiding rework are second-tier. Big surgery is welcome; reservations (ADR
numbers, NaN-box slots, debt rows) are memos, not contracts; progress pressure
does not override the smell sensor. Mechanism: the smell corpus in memory, layer
4 above.

## Identity (verified 2026-09-10)

- **Repo**: `~/PP/ClojureWasm`.
- **origin** = `git@github.com:BuddhiLW/ClojureWasm.git`. **This fork is the
  maintained one.** The `clojurewasm` remote is deliberately hobbled
  (`no_push`, `--no-tags`) because `v1.10.1` names TWO commits. Never fetch
  upstream tags.
- **Branches**: work lands on `staging`; `main` is reached by PR
  (`staging` -> `main`), which is what cuts a release. Commit **and** push in
  the same step; local commits never accumulate.
- **Shipped through v1.14.5.** Release mechanics: memory
  `20260911001201-09a51b5b`. Commit and gate hygiene (the smell-audit trailer
  needs `<digit>: <summary>`, CI is ONE configuration): `20260911001202-2ee19e2f`.
  What is unfinished: `.dev/debt.yaml` + the kanban board.
- **Read-only references**: cw v0 through git only (`git show v0.5.0:<path>`,
  or `git worktree add ../cw-v0 v0.5.0`). zwasm clone at
  `~/PP/zwasm` (origin `BuddhiLW/zwasm`, the fork `build.zig.zon` pins).
  The `~/Documents/OSS/{clojure,babashka,zig}` and
  `~/Documents/MyProducts/ClojureWasm` paths in older text are the
  **upstream author's machine layout**, inherited by the fork and never valid
  here. A survey that needs JVM Clojure, Babashka or the Zig stdlib must be
  pointed at a tree that exists, or clone one first.

## Language and writing style

English everywhere: code, comments, commit messages, chat, README, ROADMAP,
ADRs, `.dev/`, `.claude/`, notes. `docs/ja/archive/` stays as it is
(chaploud's authored work, cadence dormant per ADR-0025).

No em-dashes, no `...` ellipsis, no LLM padding. A comma, a colon,
parentheses, or a full stop. State the fact and stop. Long rationale goes in
an ADR or hive memory, never inline in a README.

## The only stop

**One condition: the user explicitly asks the loop to stop.** Task, phase,
commit and cluster boundaries do not stop it. A smell trigger does not stop
it (it is an interrupt). A red gate does not stop it. Choosing the next unit
is never resolved by asking the user; that is the Direction-ask smell.

Full rule + next-unit self-selection + debt-drain order: `20260910001609-5b3ea4d7`

## Procedure (fetch when the step runs, not before)

| what | id |
|---|---|
| Per-task TDD loop, Step 0 to 7 | `20260910001609-609c3c20` |
| ADR-level design inline + the DA-fork brief | `20260910001609-6e4ca074` |
| The only stop + next-unit selection | `20260910001609-5b3ea4d7` |
| Data-source SSOTs, and what each answers | `20260910001610-1d4ad7e8` |
| Always-on context budget, measured | `20260909235631-5c19c78d` |

## Knowledge lives in hive memory, not in files

**`.claude/rules/*.md` is gone (2026-09-11).** All 32 were mirrored into memory
+ KG on 2026-09-09/10, no script ever read one, and the glob auto-loader was
re-sending ~18k tokens on every `.zig` edit (~47k for the corpus). The table
below is the whole tier: fetch a body when its subject is what you are doing.
**`G` = the entry carries a `guard-rule` block**, so it is enforced by
hive-spi.guard whether or not you read it; a refusal quoting an id IS that rule.

| rule | id | G |
|---|---|---|
| accepted_divergences | `20260909234822-74759eeb` | |
| binary_size | `20260909235202-2908e693` | G |
| bootstrap_essence | `20260909235202-58f77413` | |
| clj_attribution | `20260909234633-115f1e0c` | |
| clj_diff_sweep | `20260909234815-3490bbcd` | G |
| cljw_invocation | `20260909234845-35806ca2` | G |
| clojure_spec_citation | `20260909234644-6d1d690d` | |
| debt_dedup | `20260909234454-48f2e989` | G |
| dual_backend_parity | `20260909234759-18586426` | |
| error_catalog_only | `20260909234626-1bece9de` | G |
| exploration_vs_done | `20260909234838-2229ddfb` | |
| extended_challenge | `20260909234455-330545a2` | |
| feature_name_consistency | `20260909234605-3f9e2aa8` | |
| framework_completion | `20260909234612-6f9c927b` | |
| gate_cadence | `20260909234752-16ad5476` | G |
| markdown_format | `20260909234454-6705f6f7` | |
| module_docstring | `20260909235200-7c602907` | G |
| no_copy_from_v1 | `20260909235201-14470f53` | |
| no_jvm_specific_assumption | `20260909235201-44e1e6e9` | G |
| no_op_stub_forbidden | `20260909235201-72836234` | |
| orphan_prevention | `20260909234832-598b7c16` | G |
| perf_marker | `20260909234453-7ca5e578` | G |
| perf_measure_release | `20260909234455-390c5332` | G |
| plan_revision_thinking | `20260909234453-6cf9b052` | |
| provisional_marker | `20260909234453-094762cc` | G |
| test_taxonomy | `20260909234807-4b4c0db8` | |
| textbook_survey | `20260909234618-0095b147` | |
| tier_classification | `20260909234639-2efc4769` | |
| yaml_ssot_yq | `20260909234558-3c83a76a` | G |
| zig_tips | `20260909235200-1f86720b` | G |
| zone_deps | `20260909235201-1eab3b17` | G |

The 15 rows with no `G` are advice, not enforcement: fetch them on the subject,
and if one turns out to be mechanizable, write its `guard-rule` block into the
entry rather than restoring a file. The `check_*.sh` gates are unaffected; they
read the YAML SSOTs and the source, never a rule file, and the paths they print
in error messages are now memory ids.

ADRs are cited by commit messages. Search, do not read a directory:

```
mcp__hive__memory search :query "..."
mcp__hive__memory query  :tags ["adr" "adr-0107"]     # one ADR
mcp__hive__memory query  :tags ["cljw-rule"]          # the rule corpus
mcp__hive__memory kg traverse :start_node <id> :max_depth 2
```

Design canon distilled from reading the whole corpus at once:

| finding | id |
|---|---|
| A generated artifact with no gate is abandoned (decided 4x) | `20260909235631-6f763b58` |
| Registry for completeness; defer a seam for pluggability | `20260909235630-6096047d` |
| The dual-backend oracle cannot see a bug identical on both | `20260909235630-5ace59c5` |
| A proxy signal accepted for the fact it names | `20260910001213-63e219a4` |
| Overriding the DA fork: name the axis, not the size | `20260909235632-7a57b709` |
| Guard enforceability measured at 12 of 32 rules | `20260909235631-5ae3f445` |

## Build and test

```sh
bash test/run_all.sh --smoke <step>      # per-commit smoke (ADR-0107)
bash scripts/run_gate.sh                 # full gate, run ALONE
zig build -Dwasm -Doptimize=ReleaseSafe  # probe binary (= the gate config)
zig fmt src/
```

Never a bare `zig build test` without `-Dwasm`. Never a Debug binary for a
behaviour probe. Never a build during the full gate. Cadence SSOT: memory
`20260909234752-16ad5476` (gate_cadence).

## References

- `.dev/ROADMAP.md` authoritative mission and plan. **If this file conflicts
  with the roadmap, the roadmap wins.**
- Current state: `git log`, the CHANGELOG, and the kanban board. There is no
  handover file (retired 2026-09-11, `20260910235746-74389f7f`); the resume path
  is `project workflow catchup`, which drains the axioms and the live cards.
- **ADRs are memory entries, not files** (2026-09-11, `20260910235746-74389f7f`).
  All 199 were mirrored before deletion and the audit confirmed 199 of 199. Reach
  one by number: `memory query :tags ["adr" "adr-0107"]`. Numbers stay
  time-ordered and newest still wins on conflict; a new decision is an entry of
  type `decision` tagged `adr-NNNN`, cited by number in the commit message.
- `.dev/project_facts.md` the F-NNN invariants this chain starts from.
