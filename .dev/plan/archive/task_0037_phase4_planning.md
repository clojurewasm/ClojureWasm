# Task T4.0: Phase 4 Planning + Document Update + Status Tracking Setup

## Goal

Update all active .md files to reflect current project state (post-Phase 3,
post-README rewrite). Introduce YAML-based progress tracking (.dev/status/).
Set up Phase 4 roadmap.

## Scope

### Existing file changes (5 files)

1. `.dev/plan/roadmap.md` — Add Phase 4 sections (4a-4f)
2. `.dev/plan/memo.md` — Update to Phase 4 / T4.0
3. `.dev/checklist.md` — Remove resolved items, add P6, add Phase refs
4. `.dev/notes/decisions.md` — Add D16 (Dir Structure), D17 (YAML Status)
5. `.claude/CLAUDE.md` — Add Status Tracking section, update workflow

### New file creation (5 files)

6. `.dev/status/vars.yaml` — Var implementation status (generated from clj)
7. `scripts/generate_vars_yaml.clj` — Var list generation script
8. `.dev/status/bench.yaml` — Benchmark results in YAML
9. `.dev/status/README.md` — Status management guide
10. `.claude/skills/status-check/SKILL.md` — Status query skill

## Plan

1. Create this task file
2. Create generate_vars_yaml.clj, run with clj -> vars.yaml
3. Update vars.yaml with implemented status (cross-ref registry/core.clj)
4. Create bench.yaml from T3.17 results
5. Create status/README.md
6. Update roadmap.md with Phase 4
7. Update memo.md
8. Update checklist.md
9. Add D16, D17 to decisions.md
10. Update CLAUDE.md
11. Create status-check skill
12. Single commit

## Log

- Task file created
- scripts/generate_vars_yaml.clj created and run (29 namespaces, 1242 lines)
- vars.yaml status updated: 95 done, 7 skip (cross-referenced with registry/core.clj/analyzer)
- bench.yaml created from T3.17 results
- status/README.md created (schema docs, yq examples)
- roadmap.md Phase 4 sections added (4a-4f, 16 tasks)
- memo.md updated to Phase 4 / T4.0
- checklist.md updated (removed resolved items, added P6, added Phase refs)
- decisions.md D16 (Directory Structure) and D17 (YAML Status) added
- CLAUDE.md updated (Status Tracking section, workflow integration)
- status-check skill created
