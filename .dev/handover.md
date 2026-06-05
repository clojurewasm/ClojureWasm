# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: pushed `81af5cd3` (zwasm v2 embedding spike, D-037 / F-001). Active
  plan = ADR-0089 (A->B->C), Phase B. DONE: add-watch-IRef (atom/agent/ref/var)
  + set!-parity (ADR-0096) + the zwasm v2 relative-path import spike (consumable,
  no issues — full FFI stays Phase 16 / D-036).
- **First commit on resume MUST be**: the next Phase B unit — **D-237
  `with-local-vars`** (now-status; needs anonymous-Var creation + the heap
  binding-frame primitive, which the ADR-0096 baseline-frame work just exercised;
  var-get/var-set already landed). Step 0 survey clojure.core/with-local-vars +
  vars.clj, then TDD. Owner-gated concurrency (real-threading / auto-collect ON /
  D-244 #4) stays OUT.
- **Forbidden this session**: **pinning an in-progress zwasm v2 state / using a
  zwasm tag or v1** (F-001 guardrail — v2 ONLY from the `zwasm-from-scratch`
  branch; wasm findings split per the finding-handling policy: zwasm-side =
  feedback note no-code, cljw-side = real fix); turning auto-collect ON (user-
  owned #4a'); editing .claude/rules/* (permission-blocked -- surface to user);
  re-opening landed work (git log = SSOT); trusting ~/Documents/OSS/zig for 0.16.

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

**zwasm v2 embedding spike** (D-037 / F-001, 81af5cd3). cljw consumes zwasm v2's
Zig API via a `build.zig.zon` relative-path LAZY dep behind `-Dzwasm-spike`
(default gate zwasm-free, verified). `zig build zwasm-spike -Dzwasm-spike` ->
Engine.init(cljw alloc) -> compile -> instantiate -> typedFunc add(2,40)==42,
leak-clean. zwasm v2 ONLY from the `zwasm-from-scratch` branch (tags=v1, unused).
No issues found. D-038 surface verified in-repo. Full FFI = Phase 16 (D-036).
Prior: add-watch IRef (atom/agent/ref/var via shared `iref.notifyWatches`) +
**ADR-0096 / D-254** set! JVM-`Var.set` parity (runtime thread-bound gate in both
backends, never setRoot; removed the analyze-time check that raced the eval-time
flag) + a clojure.main-style baseline binding frame (8 std config/print vars;
partial D-241). Env.deinit nulls the threadlocal current_frame.

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

handover → **`.dev/gc_rooting.md`** (the GC-rooting SSOT) + **`.dev/debt.yaml`
D-253/252/251** (the torture-green campaign + closed classes) +
`private/notes/torture-full-sweep-gaps.txt` (the 38-gap inventory) →
**`.dev/decisions/0094_*`/`0095_*`** (the rooting ADRs) → **`.dev/project_facts.md`
F-004/F-006/F-011** → CLAUDE.md (§ Project spirit + The only stop) →
`.dev/principle.md`.
