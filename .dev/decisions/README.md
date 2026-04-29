# Architecture Decision Records

> Load-bearing decisions only. ADRs document *why* a decision was made so
> that future readers (including future Claude sessions) do not re-litigate
> it. Skip ADRs for ephemeral choices ("not worth it right now") or for
> facts that are obvious from the code.

## Filename convention

`NNNN_<snake_slug>.md`

- `NNNN` — 4-digit sequential index, zero-padded
- `<snake_slug>` — short English identifier in snake_case
- `0000_template.md` — template (do not delete or renumber)

## Required structure

Use [`0000_template.md`](./0000_template.md) as the starting point. Every
ADR has:

- **Status**: Proposed / Accepted / Superseded by NNNN / Deprecated
- **Context**: what motivated the decision (constraints, prior art)
- **Decision**: what was chosen
- **Alternatives considered**: what was rejected and why
- **Consequences**: positive, negative, neutral
- **References**: ROADMAP §, related ADRs, external docs

## Lifecycle

- **Add**: when a load-bearing decision is made. Number = max(existing) + 1.
- **Supersede**: do not edit a historical ADR. Add a new one and mark the
  old one `Status: Superseded by NNNN`.
- **Reject after debate**: also add an ADR with `Status: Proposed → Rejected`.
  Records why the path was not taken.

## Commit gate trigger

Adding `.dev/decisions/NNNN_<slug>.md` (real ADRs; not `README.md` and
not `0000_template.md`) makes the commit "source-bearing" per
`scripts/check_learning_doc.sh`. The next doc commit must include the
ADR's commit SHA in its `commits:` front-matter list — see skill
`code_learning_doc`.
