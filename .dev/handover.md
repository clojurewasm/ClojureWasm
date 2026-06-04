# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (`cw-from-scratch`). Gate green 247/0 (Mac, serial-e2e).
  debt ledger = `.dev/debt.yaml`. Active plan = **ADR-0089 re-cut (A→B→C)**.
- **First commit on resume MUST be**: open **Phase B entry (D-242)** — Phase A
  consolidation is COMPLETE (see Phase A work items). Phase B = the project's
  hardest unit (real concurrency in Zig 0.16). Entry ceremony, in order:
  Step 0 survey (concurrency: cw v0 `future`/STM/`agent`, Clojure JVM
  `LockingTransaction`/Agent, Zig 0.16 `std.Io`/`std.atomic`, Babashka) →
  Step 0.6 re-lay → **§7-redesign ADR** (Supersedes the pre-0.16 §7.1 mapping)
  with mandatory **DA-fork** + **Structural-imagination** + a throwaway
  **Zig-0.16 concurrency spike** in `private/` (validate the primitive BEFORE
  the ADR shape, principle.md). North star = user-observable parity, internals
  free (F-011 §2 + no_jvm). Phase B source work takes the full `--serial-e2e`
  gate per commit (gate-cadence hook).
- **Forbidden this session**: cold-seizing **Phase B** (D-242, concurrency-led
  core) without its §7-redesign ADR + Structural-imagination + DA-fork at entry
  (spike the Zig-0.16 primitive first, principle.md). Also forbidden: minting a
  new F-NNN to restate F-011 (the F-013 idea was DROPPED — ADR-0089); adding a
  new rule/skill/audit-section where folding into an existing home works
  (compress-guards); "fixing" an AD-001..012 accepted divergence; re-opening
  landed work (git log = SSOT); perf without a Release `scripts/perf.sh` number.

## Active plan — ADR-0089 post-M re-cut (2026-06-04)

```
Phase A  Consolidation — doc/guard drift sweep + exhaustive comment-drift sweep.
Phase B  KNOWN-unimplemented CORE, concurrency-led (D-242): §7 redesign vs Zig
         0.16 FIRST, then STM-txn / agent / locking / real-threading / Thread +
         arrays (F-004) / *out*·in·err (D-238) / with-local-vars (D-237) /
         reflection. finished-form, rework-OK with test guards. North star =
         user-observable parity, internals free (F-011 §2 + no_jvm).
Phase C  Library-driven gap-hunt (was the quality loop) on the concurrency base;
         workaround remediation folds in here.
```

Restores §9.2.R's Phase-15-first intent (the session had drifted by running the
quality loop pre-Phase-15). The clean-bounded clj-parity frontier is drained.

## Phase A work items — COMPLETE (git log = SSOT)

- Comment-drift fan-out (12 subagents): 121 files comment-only re-cut to
  finished form (db3932e7). (b) inventory → D-242; (c) fixed.
- Discharged-section audit (fecdd248): 141 rows → **8 fired-but-unbuilt**
  re-opened under **D-243** (D-048/104/105/106 HARD = Phase C host-surface+bench;
  D-054/056/057 soft; D-049 user-owned F-NNN). No false-discharge lies.
- §9.7 Phase 5 expanded list flipped PENDING→DONE (05a8526e, stale checkbox).
- ROADMAP archive-extract: §9.3-9.15 (Phases 1-13) → `ROADMAP_archive_phases_1-13.md`,
  2651→1922 lines, anchor-preserving stubs (8e4eafdd).
- Guard pass: clean (0 dead rules / 0 orphaned-superseded ADRs); wired the dormant
  `check_e2e_dup.sh` guard (f5e4d5b5, gate 247/0).
- **Two carry-overs**: (1) 3 rules carry a stale `src/runtime/host/**` glob
  (→ `runtime/java/**` per ADR-0029) — cleanup edit **declined by the permission
  classifier as agent-config self-modification; awaits user authorization**
  (harmless — rules still load via other globs). (2) debt discharged-in-active
  compaction stays LOW/clutter-only (D-243 took the actionable rows; watch
  D-210 standing-floor false-positive).

## Landed before the re-cut (git log = SSOT; one summary)

Post-M quality stream: random-sample · partitionv · the print-control var cluster
(`*print-length*`/`*print-level*`/`*print-namespace-maps*`/`*print-readably*`/
`*print-meta*` all bindable, ADR-0088 + DA-fork; deepRealize meta-preserve fix;
infinite-seq×*print-length* termination D-222 b) · regex `\p{}` POSIX classes +
`\s` \x0B fix + scoped `(?i:)`/`(?s)`/`(?m)` flags · thread-binding machinery
(`with-bindings`/`bound-fn`, D-241) · debt quality_floor hygiene.

## Process discipline (SSOT = memory + rules; do NOT re-expand here)

- Gate (Phase B/C source work only): `timeout 1800 bash test/run_all.sh
  --serial-e2e` (~5min; -P8 over-runs under load). Phase A doc/scaffold = no gate.
- Never poll a bg gate. `clj -M -e` → `timeout 20` + bound infinite seqs. Speed
  ONLY via `scripts/perf.sh`. Edit/Write TRANSCODES literal non-ASCII (keep source
  ASCII; splice non-ASCII doc edits via python). Default backend = VM (F-012).
- comment-drift sweep + spike-mode are FOLDED into §E2.7 + principle.md (ADR-0089
  DA verdict) — NOT new mechanisms.

## Cold-start reading order (tracked-only)

handover → `.dev/decisions/0089_recut_concurrency_and_drift_methods.md` (the active
plan) → ROADMAP §9.2.R/§7 → `.dev/debt.yaml` (D-242 Phase-B anchor + D-238/D-239/
D-241) → CLAUDE.md (§ Project spirit + Autonomous Workflow + The only stop) →
`.dev/project_facts.md` (F-002/004/005/009/011/012) → `.dev/principle.md`.
