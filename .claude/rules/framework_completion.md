---
paths:
  - ".claude/rules/**/*.md"
  - ".claude/skills/**/SKILL.md"
  - "scripts/check_*.sh"
  - ".claude/settings.json"
  - "data/feature_deps.yaml"
  - "data/placement.yaml"
  - "data/compat_tiers.yaml"
---

# Framework completion

Auto-loaded when editing any framework / scaffolding file (rule, skill,
hook script, SSOT yaml, settings). Codifies the discipline that
introducing a new discipline is **not enough** — the same cycle that
introduces it must also retrofit the existing codebase to the new
discipline. Otherwise the codebase carries an asymmetry (= new files
follow the rule, old files don't) that no one is responsible for
healing.

## The rule

A cycle that does any of:

- adds a new `.claude/rules/<name>.md` (especially with a `paths:`
  frontmatter that targets pre-existing source)
- introduces a new SSOT yaml (`data/feature_deps.yaml`,
  `data/placement.yaml`, ...)
- lands a new PreToolUse hook script (`scripts/check_*.sh`)
- amends an existing rule in a way that broadens its scope
- adds a new Bad Smell entry to `principle.md`
- introduces a new marker convention (`PROVISIONAL:`, `TODO:` ban,
  etc.)

...MUST, in the same cycle, do all three of:

1. **Define the discovery criterion** — a concrete grep / yq / parser
   recipe that enumerates existing sites the new rule would cover.
   Recipe lives in the rule body or in the new script.
2. **Run the sweep** — execute the recipe against the current
   codebase. Output goes to `private/notes/<phase>-<task>-sweep.md` or
   inline in the per-task note.
3. **Land the retrofit** — for each enumerated site, either: apply the
   rule (= edit file to comply); OR add an explicit exemption (= note
   in `.dev/watch_findings.md` with revisit trigger); OR document why
   the site is genuinely out of scope.

A cycle that introduces the rule without doing all three is
**framework-incomplete** — a new smell defined in
`.dev/principle.md`. The codebase ends up with a 2-tier population
(new sites compliant, old sites unmarked), and no row in `.dev/debt.yaml`
points at the gap.

## Why

The Wave-15 spike (provisional-marker framework, 2026-05-26) initially
landed the rule + SSOT + hook (commits 1fdc342 / 0fed954) before any
existing provisional behaviour was marker-retrofitted. The
silent-failure-hunter review caught 5 sites that the initial
retrofit missed (set/walk/string `.clj` heads + primitive.zig +
macro_transforms.zig), because the discovery criterion was implicit
("things I changed in the recent 6.16.b cycles") rather than
mechanical ("grep for `(in-ns 'foo)` heads + grep for
`referAll(rt_ns, ...)` calls").

The fix is to require the discovery criterion as a deliverable of the
framework-introducing cycle itself.

## How to apply

### A. Discovery criterion shape

A discovery criterion is a deterministic recipe. Examples:

| Rule landed                      | Discovery criterion                                                                                                |
|----------------------------------|--------------------------------------------------------------------------------------------------------------------|
| `provisional_marker.md`          | `rg --no-heading -nl '(stands in for\|for now\|until Phase \d+\|temporarily)' src/ test/e2e/`                      |
| `module_docstring.md` (Phase 5+) | `find src -name '*.zig' -newer <ref> \| xargs -I{} head -2 {} \| ...` (first 2 lines start `// SPDX:` + `//! ...`) |
| `feature_name_consistency.md` G3 | `yq '.host_classes[].keyword' data/compat_tiers.yaml \| xargs -I{} rg -l '{}' src/`                                |
| `error_catalog_only.md`          | `rg --no-heading -n 'setErrorFmt\(' src/ \| grep -v 'runtime/error/catalog.zig'`                                   |
| `handover_framing.md`            | grep recipe at L189-194 of the rule itself                                                                         |

The criterion may be opinionated (= false positives possible) but must
be reproducible.

### B. Sweep output

Land the sweep output as a per-task note (or per-cycle survey):

```
# Sweep: <rule name> introduction (<cycle>)

Discovery recipe: `<command>`

Hit count: <N>
Hits:
  - <file>:<line> — <classification: comply / exempt / out-of-scope>
  ...

Coverage check: <hit count> sites considered; <comply> applied;
<exempt> recorded in watch_findings.md as W-NNN; <out-of-scope> noted
inline.
```

### C. Retrofit commit shape

The retrofit edits land in the same cycle:

- One commit per concern (per-cluster grouping is fine: spike 2.1 +
  2.2 + 2.3 across 4 sub-commits is the cw v1 precedent).
- Each commit's `Smell-audited:` line acknowledges the framework-
  completion discipline.
- The per-task note's `## 暫定ログ` section records the introduced /
  discharged / surfaced markers.

### D. Exemption shape

A site that does not get the new marker / yaml entry / debt row must
have an explicit exemption row in `.dev/watch_findings.md`:

```
| W-NNN | <commit SHA> | <file>:<line> — <site>; not applied because <reason> | <reason category> | <when to revisit> | YYYY-MM-DD |
```

A site without either a comply-application or an exemption row is a
**bug in the cycle**.

## Counter-examples

❌ Land `provisional_marker.md` + 11-site retrofit; never grep for
`stands in for` / `referAll(rt_ns, ...)` patterns the rule covers.
Review catches 5 missed sites → Framework-incomplete smell fired in
review, not in the cycle.

❌ Introduce a new Bad Smell entry in `principle.md` without
mentioning where existing code might have triggered it. The smell
description references no concrete site, so the catalogue grows but
the codebase doesn't.

❌ Add a hook script with a `paths:` matcher and ship it without
running the script against the current tree. The first real commit
that hits the matcher fails the hook unexpectedly.

✅ Land the rule + scripts + sweep output + retrofit + exemption rows
all in one cycle. The next session reads the cycle history and finds
the discovery recipe + the exemption list together.

## Enforcement

This rule is **prose-aspirational** today (it auto-loads on rule /
skill / script / yaml edits via the `paths:` frontmatter, so the
agent reads it whenever introducing a new discipline). A future
`scripts/check_framework_completion.sh` could mechanise it by:

- Detecting cycles that add a new `.claude/rules/<name>.md` or
  `scripts/check_*.sh`
- Requiring the same cycle to add either a sweep output file or an
  `.dev/watch_findings.md` row that references the new rule

For now the discipline lives in the rule body + Step 0.6 main-agent
re-laying + audit_scaffolding E2.7 telltale sweep at Phase boundary.

## Cross-references

- `.dev/principle.md` Bad Smell catalogue — Framework-incomplete +
  Defer-to-amnesia entries (Wave-16 addition).
- `.dev/watch_findings.md` — the SSOT for exemption rows.
- `audit_scaffolding/CHECKS.md` E2.7 telltale sweep — the periodic
  catch-up sweep that compensates for missed introductions.
- `provisional_marker.md` — the canonical example of the framework
  this rule operationalises around.
