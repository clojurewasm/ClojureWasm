# ADR-0062 — Context-budget reduction: prune always-on injection, cap window at 200K, disable unused MCP, de-duplicate compaction hooks

- **Status**: Accepted
- **Date**: 2026-05-31
- **Phase**: Phase 14 (post-v0.1.0) — scaffolding maintenance (user-directed)
- **Supersedes**: —
- **Superseded by**: —

## Context

Auto-injected scaffolding had grown to dominate every turn's context.
Measured per-turn floor (approx, bytes/4):

| Region                                                     | tokens/turn |
|------------------------------------------------------------|-------------|
| project CLAUDE.md                                          | ~7,471      |
| global `~/.claude/CLAUDE.md`                               | ~2,288      |
| always-on rules (`paths: ["**"]`)                          | ~5,197      |
| handover.md + MEMORY.md (SessionStart)                     | ~2,004      |
| MCP server-instruction blocks (figma / datadog / slack …) | several K   |

A `.zig`-edit turn additionally fires ~18K of path-scoped rules
(`zig_tips` 6.8K, `provisional_marker` 2.8K, `feature_name_consistency`
2.1K, …), so a single source edit carried ~35K of scaffolding before any
file content. Three concrete defects amplified this:

1. **`gate_cadence.md` had no `paths:` frontmatter** → it loaded on
   *every* turn (~1.5K) instead of only on test-runner / settings edits.
2. **`orphan_prevention.md`** (always-on, `paths: ["**"]`) had grown to
   218 lines (~2.4K/turn) — mostly incident narratives + a one-time
   "0-hits sweep" + caveat expansions that are reference material, not
   per-turn instruction.
3. **Unused MCP servers** (datadog / figma / slack / Notion /
   chrome-devtools / playwright) — irrelevant to a Zig project — injected
   their server-instruction blocks + deferred tool lists on every turn.

Separately, the autonomous loop rides one session toward the 1M Opus
window; auto-compact fires at ~95% (~950K), so the session bloats and
becomes expensive before any compaction relief. The user chose to cap
the window at the 200K standard so compaction is early, cheap, and
frequent — relying on the handover.md + post-compaction re-injection
hook as the durable cross-compaction bridge.

**PostCompact-hook finding.** A prior belief held that Claude Code has
no `PostCompact` event and that the project's `PostCompact` block was
dead (= compaction resilience broken). Verified against the official
docs (code.claude.com/docs/en/hooks, 2026-05-31): **`PostCompact` and
`PreCompact` are both real events**, and `SessionStart` also fires after
compaction with `matcher: "compact"`. The block was *not* dead. The
actual defect was redundancy: `SessionStart` matched `"*"` (which
includes the `compact` source) **and** `PostCompact` matched `"*"`, so a
compaction re-injected the brief twice.

## Decision

A user-directed scaffolding diet. Concrete changes:

1. **Window → 200K.** Project `.claude/settings.json` sets
   `"model": "claude-opus-4-8"` (non-`[1m]`). Compaction becomes early /
   cheap / frequent; handover.md + the PostCompact hook carry state
   across.
2. **`gate_cadence.md`** gains a `paths:` frontmatter scoping it to the
   test runner / gate scripts / settings — off the always-on floor.
3. **`orphan_prevention.md`** trimmed 218 → ~58 lines: the two load-
   bearing rules (`timeout 600` for background long-runners;
   `timeout 20` + `(take N …)` for `clj -M -e` oracle probes), the
   `timeout`-non-propagation caveat, the gate launcher, and the counter-
   examples stay. Incident narratives move to their existing home,
   ADR-0049 § Context (a pointer remains).
4. **MCP disabled for this project only** (override, not global):
   `enabledPlugins` sets figma / slack / notion / chrome-devtools-mcp /
   playwright to `false`; `disabledMcpServers` lists `datadog-mcp` (a
   global `~/.claude.json` `mcpServers` http entry, not a plugin).
5. **Compaction hooks de-duplicated** with explicit matchers:
   `SessionStart` → `startup|resume|clear` (full handover inline),
   `PostCompact` → `auto|manual` (concise `print_handover_brief.sh`).
   No source overlaps, so compaction re-injects exactly once.
6. **CLAUDE.md** stale framing pruned: the "Phase 4 entry additions"
   header + the ADR-0004–0024 enumeration (archaeology — the project is
   past Phase 7 into the post-M / F-010 / F-011 quality loop); the
   Linux-gate bullet and the Cycle-budget-defer paragraph condensed
   against their canonical homes (ADR-0049, `principle.md`).
7. **`java_cljw_surface_layout.md` deleted** — a redundant pointer stub
   whose `paths` (`src/runtime/java/**`, `src/runtime/cljw/**`) are
   already subsumed by `feature_name_consistency.md`'s `src/runtime/**`,
   so a java/cljw-surface edit loaded both. The canonical content lives
   in `feature_name_consistency.md`.

## Consequences

- Always-on floor drops ~3.3K tokens/turn (gate_cadence frontmatter
  ~0.9K + orphan_prevention trim ~1.8K + CLAUDE.md condensations
  ~0.6K), plus the MCP server-instruction blocks (several K) once the
  settings reload / restart takes effect.
- 200K window forces the loop to lean on handover.md as the durable
  state — exactly the design the resume contract + `print_handover_brief.sh`
  already serve. Frequent auto-compact is now the expected operating
  mode, not an exception.
- **Verification required** (settings reload / restart): confirm the six
  MCP servers no longer load (their tool lists + instruction blocks
  vanish), and that `enabledPlugins: false` at project scope is honored
  (the key is undocumented in the settings reference but is the same key
  the global settings use; project overrides user). Fallback if not
  honored: the `/plugin` menu. `disabledMcpServers` as a plain-string
  array mirrors the per-project `~/.claude.json` practice; if ignored,
  datadog stays and needs the `/mcp` UI toggle instead.
- No load-bearing rule was cut: the smell-audit / gate-cadence /
  provisional-marker / dual-backend / orphan-`timeout` invariants and
  the F-NNN priority chain are intact.

## Alternatives considered

This is a **user-directed** change; the user supplied the external check
(approving the 200K cap and the orphan_prevention trim depth via an
in-chat decision, and directing the MCP disable + PostCompact
investigation), so the autonomous-loop Devil's-advocate fork (CLAUDE.md
§ ADR-level designs) does not apply.

- **Keep the 1M window** (rejected by the user): longer single sessions
  but late, expensive, rare compaction and unbounded bloat.
- **1M + run-time `/compact` discipline** (rejected): relies on the loop
  remembering to compact; the 200K cap makes it structural.
- **Trim orphan_prevention to ~25 lines / leave it untouched**
  (rejected both): the ~58-line core keeps both rules + caveat +
  counter-examples readable in one screen without re-deriving from
  ADR-0049, while still shedding the narrative bulk.
- **Disable MCP globally** (rejected by the user): would affect every
  other project; project-scoped override was required.

## Affected files

- `.claude/settings.json` — `model`, `enabledPlugins`,
  `disabledMcpServers`, `SessionStart` / `PostCompact` matchers.
- `.claude/rules/gate_cadence.md` — added `paths:` frontmatter.
- `.claude/rules/orphan_prevention.md` — trimmed to core.
- `.claude/rules/dual_backend_parity.md` — dropped the one-time
  `0cd92fa` sweep-result table.
- `.claude/rules/java_cljw_surface_layout.md` — deleted.
- `CLAUDE.md` — Data-sources header + ADR enumeration, Linux-gate
  bullet, Cycle-budget-defer paragraph condensed.
