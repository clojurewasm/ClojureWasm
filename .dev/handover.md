# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (`cw-from-scratch`). Gate green 251/0 Mac + 250/0 Linux
  x86_64 (serial-e2e). debt = `.dev/debt.yaml`. Active plan = **ADR-0089 (A→B→C)**.
- **First commit on resume MUST be**: a non-gated Phase B unit (pick one). The
  **#4a' GC-ROOTING is COMPLETE** — in-txn maps self+worker (opaque `ThreadGcContext.
  tx_slot` + `mark_sweep` mark-pass + `lock_tx.markRoots`, TDD red→green) + the
  audit-proven-safe fabrication windows (`private/notes/phaseB-4a-rooting-audit.md`)
  + `gc_self_guard` Q1-partials. The ONLY remaining #4a' step is the **auto-collect-
  ON flip** — GATED (Forbidden below): it needs a full runtime-wide root re-audit +
  USER-AWARENESS (it can destabilize the whole runtime). So next non-gated work:
  agent watches/validator (ADR-0093 Alt 2 IRef extraction) / error-handler /
  `await-for` / `shutdown-agents`, OR with-local-vars (D-237). (arrays F-004 + full
  `*out*` D-238 are OWNER-GATED — do NOT cold-seize.) Phase B concurrency PRIMITIVES
  are complete + dual-arch-verified + code-reviewed. rework-OK + test guards (F-002);
  src commits gate `--serial-e2e`. Cold-start: `private/notes/phaseB-4a-self-tx-
  rooting.md` + `phaseB-4a-rooting-audit.md`.
- **Forbidden this session**: turning auto-collect ON (collect stays explicit/
  test-triggered). The safepoint + per-thread root publication + the in-txn-map
  rooting (self+worker) + the fabrication-window audit are now ALL done — so any
  EXPLICIT collect is safe — but the auto-collect-ON flip is the remaining highest-
  risk step (a full runtime-wide root re-audit + user-awareness first; it can
  destabilize the whole runtime); editing `.claude/rules/*` (permission
  classifier blocks it as self-mod — surface to user, see memory); "fixing" an
  AD-001..013 accepted divergence (AD-013 = STM no-barge, landed); re-opening
  landed work (git log = SSOT); perf without a Release `scripts/perf.sh` number;
  trusting `~/Documents/OSS/zig` for 0.16 API (post-0.16 master — wrong tree; use
  pinned nix-store std / cw v0).

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

## Recently landed (git log = SSOT)

**Phase B concurrency PRIMITIVES complete** (ADR-0090/91/92/93), all clj-verified
+ a ReleaseSafe `phase16_concurrency_stress.sh` step (loops each invariant ×20,
catching the rare lost-update class). (1) **GC STW handshake** + thread-major
`thread_roots` walk + `safepoint.zig`. (2) **Real-thread `future`/`promise`/
`delay`**. (3) **STM** (`lock_tx.zig`) — `dosync`/`ref-set`/`alter`/`commute`/
`ensure`, multi-ref, deadlock-free; AD-013. (4) **`locking`** (ADR-0092,
`object_monitor.zig`) — header `lock_state` spinlock + threadlocal reentrancy +
safepoint-poll; Option C blocking inflation = D-245. (5) **`agent` first slice**
(ADR-0093, `agent.zig`) — serial single-drainer handoff, leaf-lock gpa queue,
latch `await`. **Two real memory-ordering races found + fixed (ReleaseSafe-only,
Debug masks them)**: the STM `doGet` stale read (now reads under the Ref lock) and
the atom being non-atomic (`swap!`→CAS-retry, `current`/`compare-and-set!` atomic,
`swap-vals!`/`reset-vals!` CAS-retry; volatile/ref reads synchronized). D-246 =
remaining low-freq metadata visibility (atom watches/validator, var root).

## Open carry-overs (actionable)

- **3 rules** carry a stale `src/runtime/host/**` glob (ADR-0029); the cleanup Edit
  is permission-blocked as self-mod (memory `claude-rules-edit-permission-block`).
- **D-243** = 8 re-opened deferrals: D-048/105/106 (Phase C) · D-104 · D-054/056/057 · D-049 (user-owned F-NNN).
- **D-244** = the **#4a' hardening** (the capstone, high-risk): `gc_self_guard`
  setters at the fabrication sites + GC-root publication for the in-txn maps /
  future result / agent action-fabrication window + per-thread registration audit
  (the `locking` safepoint-poll + agent drainer share it) + turning auto-collect
  ON — all dormant while nothing fires a collect. **D-245** = `locking` Option C
  blocking-monitor inflation. **D-246** = low-freq concurrency-metadata visibility.

## Process discipline (SSOT = memory + rules; do NOT re-expand here)

- Gate (Phase B/C source work only): `timeout 1800 bash test/run_all.sh
  --serial-e2e` (~5min; -P8 over-runs under load). Doc-only = no gate.
- Never poll a bg gate. `clj -M -e` → `timeout 20` + bound infinite seqs. Speed
  ONLY via `scripts/perf.sh`. Edit/Write TRANSCODES literal non-ASCII (keep source
  ASCII; splice non-ASCII doc edits via python). Default backend = VM (F-012).
- Swept fake GC test Cells use a finaliser-free tag (`.vector`), NOT `.string`
  (its finaliser reads a data ptr a 16-byte fake Cell lacks → crash).

## Cold-start reading order (tracked-only)

handover → `private/notes/phaseB-6-agent.md` (latest; agent + next-task cluster) +
`phaseB-6-agent-survey.md` → **`.dev/decisions/0093_agent_serial_executor.md`**
(agent + DA) + **`0092_heap_value_monitor_locking.md`** (locking) +
**`0090_phase_b_concurrency_redesign.md`** (§3 STM + Alt B spine) →
**`.dev/debt.yaml` D-244** (#4a' capstone) + D-242 → ROADMAP §9.2.R/§7 → CLAUDE.md
(§ Project spirit + Autonomous Workflow + The only stop) → `.dev/project_facts.md`
(F-002/004/005/006/009/011/012) → `.dev/principle.md`.
