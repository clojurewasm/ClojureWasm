# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (`cw-from-scratch`). Gate green 248/0 (Mac, serial-e2e).
  debt ledger = `.dev/debt.yaml`. Active plan = **ADR-0089 re-cut (A→B→C)**.
- **First commit on resume MUST be**: **Phase B #6 — `locking`** (then `agent`),
  continuing the concurrency build. The Phase B CORE is LANDED + gated (see
  Recently landed): the GC stop-the-world handshake, real-OS-thread
  `future`/`promise`/`delay`, and the full STM (`dosync`/`ref`/`ref-set`/`alter`/
  `commute`, single + multi-ref, concurrent-serializable + deadlock-free) all
  work and are clj-verified. `locking`: `(locking obj body...)` acquires a
  heap-value monitor (ADR-0009 `lock_state` header bits — NOT a JVM monitor),
  runs the body, releases (a macro → an acquire/release primitive). `agent`:
  action queue + the thread pool (send fixed-pool / send-off unbounded) + error
  mode + `await`. Then the remaining STM refinements (`ensure` #5-v; the
  snapshot read-point ring walk for read-only multi-ref consistency) and the
  **#4a' hardening** (the in-txn/future GC-root publication + turning auto-collect
  ON — both dormant today since nothing fires a collect). rework-OK + test guards
  (F-002); each src commit gates `--serial-e2e`. Cold-start plan: the STM/
  real-threading per-task notes (`private/notes/phaseB-5-stm-*.md`,
  `phaseB-4b-*.md`) + the surveys (`phaseB-4-worker-wireup-survey.md`,
  `phaseB-5-stm-engine-survey.md`).
- **Forbidden this session**: turning auto-collect ON before the **#4a'**
  runtime-wide fabrication-window + in-txn-map GC-root audit (collect stays
  explicit/test-triggered; the safepoint + per-thread root publication are wired
  so any collect is safe, but the in-txn `vals`/`commutes` maps + a future's
  result are NOT yet a GC root source); editing `.claude/rules/*` (permission
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

**Phase B concurrency CORE COMPLETE** (ADR-0090 Alt B + ADR-0091), all
clj-verified: (1) **GC stop-the-world handshake** — io_default singleton, global
alloc-lock, `ThreadGcContext` registry + thread-major `thread_roots` union walk
(operand-stack `EvalFrame` chain + `gc_self_guard`), `concurrency/safepoint.zig`
(stopWorld/park/resumeWorld), alloc-prologue park + `collectStopTheWorld`,
`vm.eval` back-edge poll. (2) **Real OS-thread `future`/`promise`/`delay`** —
`std.Thread` workers, off-heap `Io.Mutex`/`Io.Condition` result cells
(`main` wires `io_default.set(init.io)`), blocking deref, thread-safe delay
memo. (3) **STM** (`concurrency/lock_tx.zig`) — `dosync`/`ref-set`/`alter`/
`commute`, single + multi-ref, retry + read-point conflict detection +
id-ordered deadlock-free atomic commit; AD-013 (no-barge). Concurrency exposed +
fixed a `Runtime.trackHeap` ArrayList race (now Io.Mutex-guarded).

## Open carry-overs (actionable)

- **3 rules** carry a stale `src/runtime/host/**` glob (→ `runtime/java/**`, ADR-0029);
  the cleanup Edit was declined by the permission classifier as agent-config
  self-mod — awaits user authorization (harmless; rules still load via other
  globs). Memory `claude-rules-edit-permission-block`.
- **D-243** = 8 re-opened deferrals: host-surface impls D-048/105/106 (Phase C) ·
  bench D-104 · regex/string D-054/056/057 · D-049 (user-owned F-NNN).
- **D-244** = the GC-handshake checklist; #4b-future/promise/delay landed.
  Remaining = the **#4a' hardening** (Q1 `gc_self_guard` setters at the
  fabrication sites + the in-txn-map/future GC-root publication + auto-collect
  ON) — all dormant while nothing fires a collect.

## Process discipline (SSOT = memory + rules; do NOT re-expand here)

- Gate (Phase B/C source work only): `timeout 1800 bash test/run_all.sh
  --serial-e2e` (~5min; -P8 over-runs under load). Doc-only = no gate.
- Never poll a bg gate. `clj -M -e` → `timeout 20` + bound infinite seqs. Speed
  ONLY via `scripts/perf.sh`. Edit/Write TRANSCODES literal non-ASCII (keep source
  ASCII; splice non-ASCII doc edits via python). Default backend = VM (F-012).
- Swept fake GC test Cells use a finaliser-free tag (`.vector`), NOT `.string`
  (its finaliser reads a data ptr a 16-byte fake Cell lacks → crash).

## Cold-start reading order (tracked-only)

handover → `private/notes/phaseB-5-stm-iv.md` (latest; STM done + next-task
cluster) + `phaseB-5-stm-engine-survey.md` (STM algorithm) →
**`.dev/decisions/0090_phase_b_concurrency_redesign.md`** (§3 STM + Alt B spine) +
**`0091_operand_stack_root_thread_union.md`** (thread_roots cursor) →
**`.dev/debt.yaml` D-244** (#4a' remains) + D-242 → ROADMAP §9.2.R/§7 → CLAUDE.md
(§ Project spirit + Autonomous Workflow + The only stop) → `.dev/project_facts.md`
(F-002/004/005/006/009/011/012) → `.dev/principle.md`.
