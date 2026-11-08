# .dev/

Project-level design and operational metadata. Tracked in git. English.

## Load-bearing

- [`ROADMAP.md`](./ROADMAP.md): the authoritative mission, principles,
  architecture, plan and quality-gate timeline. If anything elsewhere
  disagrees with it, it wins.
- [`project_facts.md`](./project_facts.md): the `F-NNN` invariants. Every
  other document is edited to align with them; they are never amended by the
  loop on its own.
- [`debt.yaml`](./debt.yaml): the row-level debt ledger, one testable barrier
  per row. The live SSOT for technical debt.
- [`accepted_divergences.yaml`](./accepted_divergences.yaml): the `AD-NNN`
  ledger of intentional divergences from JVM Clojure, each pinned by a test.
- [`optimizations.md`](./optimizations.md): the `O-NNN` performance ledger;
  `PERF:` markers in source anchor each row.

## Decisions

ADRs are cited by number (`ADR-NNNN`) in commit messages and in the ledgers
above. The record itself moved out of the tree on 2026-09-11 and lives in the
maintainer's knowledge base; numbers stay time-ordered and the newest wins on
conflict.

## Reference material

- `bench/`: the scaling probes behind `docs/works/collection_performance.md`.
- `gc_rooting.md`, `wasm_percall_findings.md`, `zwasm_capabilities.md`,
  `perf_v0_baseline.md`, `perf_campaign_essence.md`: measured findings that
  later work builds on.
- `mutation*`: the mutation-testing target list and equivalence records
  (`scripts/mutation/`).
- `ubuntunote_setup.md` and `scripts/run_remote_ubuntu.sh`: the native Linux
  gate over SSH. `orbstack_setup.md` is the retired predecessor, kept for
  history.
- `archive/`, `ROADMAP_archive_phases_1-13.md`, `v0_v1_feature_parity.md`:
  closed campaigns, historical only.
