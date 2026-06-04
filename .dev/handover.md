# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (`cw-from-scratch`). Gate green 246/0 (Mac, serial-e2e).
  debt ledger = `.dev/debt.yaml`. Active plan = **ADR-0089 re-cut (A→B→C)**.
- **First commit on resume MUST be**: continue **Phase A (consolidation)** per
  ADR-0089 — finish the doc/guard drift sweep, then run the **exhaustive
  comment-drift sweep** (audit §E2.7, widened) via fan-out read-only subagents
  (one per `src/` module subtree, each fresh-context) to catalog finished-form
  drift → promote (b)/(c) findings to `debt.yaml` / Phase B inputs. Phase A is
  doc/scaffold-only → **no per-item test gate** (batch-resolve; user-directed).
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

## Phase A work items (in progress)

- DONE this turn: ROADMAP §7.2 STM-lie / §7.1 stale-Zig-0.16-API / §9.2.R / §9.2.S
  / 14.13.5 over-claim corrected (all ref ADR-0089); audit §E2.7 widened + run
  (70 candidates, surfaces the single-threaded-assumption surface); principle.md
  spike note; D-242 Phase-B anchor minted; this handover.
- NEXT: exhaustive comment-drift fan-out (the judgment-heavy half of §E2.7) →
  catalog → debt promotion. Then: dead-ref removal (`known_issues.md` /
  `status/vars.yaml` / `compat_tiers.md` references), ROADMAP closed-phase table
  archive-extract (2607→smaller), debt discharged-in-active sweep (102→smaller),
  guard pass (31 rules / 40 scripts / 89 ADRs — dead/redundant only, conservative).

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
