# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (`cw-from-scratch`). Gate green 247/0 (Mac, serial-e2e).
  debt ledger = `.dev/debt.yaml`. Active plan = **ADR-0089 re-cut (A→B→C)**.
- **First commit on resume MUST be**: continue **Phase B IMPLEMENTATION (D-242)**.
  The entire Phase B *design* is decided + DA-fork-validated (ADR-0090 + its
  "D-244 decision" section = **Alt B**). GC-handshake build order: ✅(1)
  `runtime/concurrency/io_default.zig` (a68398b7) · ✅(2) GC global-heap `Io.Mutex`
  via the singleton (3200181b) · ✅(3a) `ThreadGcContext` registry IN `root_set.zig`
  + root-walker UNION over registered worker contexts for the dynamic-binding +
  macro sources, folded into the cursors not an 11th `RootSource` (cc6881b5 +
  6ca347ae + stress test eeeb142e; runtime-inert today, empty registry == current
  behaviour) · **➡(3b) NEXT = the operand-stack half + the safepoint**: each
  `vm.eval` registers its `{&stack,&sp,locals}` frame on the thread's chain
  (per-call push/defer-pop) so collect walks live operand Values; + the
  alloc-boundary SAFEPOINT (a `gc_requested` flag: a thread parks at its own
  `alloc` entry; the collector waits for all to park, walks the union, broadcasts)
  + a liveness-only back-edge poll in `vm.eval`'s `while(true)` + the
  collecting-thread self-guard for its in-flight alloc partial. **#3b is atomic
  with #4** (only worker threads make it live; full design = D-244 barrier "#3b" +
  ADR-0090 "D-244 decision"). Then (4) force-VM `future`/`promise`/`delay` workers
  (`evalChunkErased`) + binding-conveyor → (5) STM engine `lock_tx.zig` → (6)
  `agent`/`locking`. rework-OK + test guards (F-002); src commits gate
  `--serial-e2e` (additive batch ≤5). Spike: `private/spike_concurrency_0.16.zig`.
- **Forbidden this session**: minting a new F-NNN to restate F-011 (the F-013 idea
  was DROPPED — ADR-0089); minting **AD-013 in the ledger before its pin test
  exists** (`check_accepted_divergences.sh` enforces pin-existence — AD-013 lands
  WITH the Phase B STM concurrent test); adding a new rule/skill/audit-section
  where folding works (compress-guards); editing `.claude/rules/*` (permission
  classifier blocks it as self-mod — surface to user, see memory); "fixing" an
  AD-001..012 accepted divergence; re-opening landed work (git log = SSOT); perf
  without a Release `scripts/perf.sh` number; trusting `~/Documents/OSS/zig` for
  0.16 API (post-0.16 master — wrong tree; use pinned nix-store std / cw v0).

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

Phase A consolidation: comment-drift sweep (121 files, db3932e7), discharged-audit
→ **D-243** (8 fired-trigger deferrals re-opened), §9.7 stale-checkbox fix, ROADMAP
archive-extract (→ `ROADMAP_archive_phases_1-13.md`, 2651→1922), guard pass +
`check_e2e_dup`. Phase B: ADR-0090 (§7 redesign + D-244 GC-safety decision, two
DA-forks) + impl #1 io_default + #2 GC alloc-lock + #3a registry/root-walker union.

## Open carry-overs (actionable)

- **3 rules** carry a stale `src/runtime/host/**` glob (→ `runtime/java/**`, ADR-0029);
  the cleanup Edit was **declined by the permission classifier as agent-config
  self-mod — awaits user authorization** (harmless; rules still load via other
  globs). Memory `claude-rules-edit-permission-block`.
- **D-243** = 8 re-opened deferrals: host-surface impls D-048/105/106 (Phase C) ·
  bench D-104 · regex/string D-054/056/057 · D-049 (user-owned F-NNN).
- debt discharged-in-active compaction: LOW/clutter (watch D-210 standing-floor).

## Process discipline (SSOT = memory + rules; do NOT re-expand here)

- Gate (Phase B/C source work only): `timeout 1800 bash test/run_all.sh
  --serial-e2e` (~5min; -P8 over-runs under load). Phase A doc/scaffold = no gate.
- Never poll a bg gate. `clj -M -e` → `timeout 20` + bound infinite seqs. Speed
  ONLY via `scripts/perf.sh`. Edit/Write TRANSCODES literal non-ASCII (keep source
  ASCII; splice non-ASCII doc edits via python). Default backend = VM (F-012).
- comment-drift sweep + spike-mode are FOLDED into §E2.7 + principle.md (ADR-0089
  DA verdict) — NOT new mechanisms.

## Cold-start reading order (tracked-only)

handover → **`.dev/decisions/0090_phase_b_concurrency_redesign.md`** (the §7
redesign + its "D-244 decision" section = the active **#3b** design) →
**`.dev/debt.yaml` D-244** (the #3 implementation checklist) + D-242 (Phase-B
anchor) + D-238/D-241 → `.dev/decisions/0089_recut_concurrency_and_drift_methods.md`
(the A→B→C re-cut) → ROADMAP §9.2.R/§7 → CLAUDE.md (§ Project spirit + Autonomous
Workflow + The only stop) → `.dev/project_facts.md`
(F-002/004/005/006/009/011/012) → `.dev/principle.md`.

## Stopped — user requested

User instruction (2026-06-05): 「起きていますが、クリアセッションから当初予定を
遂行できるように配線・参照チェーンを監査したら止めてください」. The resume wiring
was audited at this stop and two gaps fixed: (a) the Resume contract said "implement
#3a first" but #3a is DONE — corrected to point at **#3b**; (b) the cold-start order
omitted ADR-0090 + D-244 (the active #3b design) — now led by them. A clear session
resumes at Phase B **#3b** (operand-stack publication + safepoint, atomic with #4)
via the Resume contract + cold-start order above. Per-task note:
`private/notes/phaseB-3a-gc-handshake.md`.
