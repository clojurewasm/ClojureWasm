# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (`cw-from-scratch`). Gate green 252/0 Mac (serial-e2e).
  debt = `.dev/debt.yaml`. Active plan = **ADR-0089 (A->B->C)**.
- **First commit on resume MUST be**: **`add-watch`/`remove-watch` generalization
  to all IRefs** (agent first, then ref, then var). cljw's add-watch/remove-watch
  reject everything but atoms; JVM accepts any IRef. Per-type firing: AGENT fires
  after each action `[old new]` (drainer state-store, agent.zig:250); REF fires
  ONCE post-commit with the net `[pre-tx post-tx]`; VAR fires on alter-var-root.
  Add a `watches` field to Agent/Ref (extern structs) + Var (gpa struct).
  Var watches need a NEW root-walk site: Var is `var_ref`-filtered from GC, so the
  `ns_vars` enumeration must also walk `Var.watches`. Generalize
  `watchesOf`/`setWatches` + `requireAtom`->`requireIRef`. Repro (currently errors
  "add-watch: expected atom, got agent"): `(let [log (atom []) a (agent 0)]
  (add-watch a :k (fn [k r o n] (swap! log conj n))) (send a inc) (await a) @log)`.
- **Forbidden this session**: turning auto-collect ON (collect stays explicit/
  test-triggered) -- the WORKER-INITIATED multi-thread collect + wrapping every
  worker blocking-site in a safepoint (only `delay.force` is wrapped today, the
  sole eval-under-lock site) is the user-owned #4a' audit, needs a full
  runtime-wide root re-audit + user awareness; editing `.claude/rules/*`
  (permission classifier blocks it -- surface to user); "fixing" an AD-001..013
  accepted divergence; re-opening landed work (git log = SSOT); perf without a
  Release `scripts/perf.sh` number; trusting `~/Documents/OSS/zig` for 0.16 API
  (post-0.16 master -- use pinned nix-store std / cw v0).

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

**GC-torture MULTI-THREAD hardening** (git log = SSOT; D-244 #4 / D-253). Three
hang root causes fixed, no workarounds: (1) torture scoped to the MAIN thread
(`root_set.is_registered_worker`); (2) STW rendezvous TOCTOU -- `stopWorld`
recomputes its park target each wake from a lock-free `registered_count` + a
leaving worker calls `noteWorkerLeft` (closes the tiny-action-drainer hang);
(3) delay-once BLOCKING-safepoint -- `safepoint.enterBlocked`/`exitBlocked` via
`lockMutexAtSafepoint` at `delay.force`'s once-lock (the only eval-under-lock
site), closing the concurrent-deref deadlock. Main-driven multi-thread torture
(future/agent/pmap/delay/promise) is torture-CLEAN: phase16_gc_torture.sh +
phase16_agent.sh + phase14_future_promise_delay all green under torture. The
full-suite N=1 sweep is SLOWNESS-bound on large-N realises (interleave_large =
100000 elems -> O(n^2) per-poll collect), NOT a hang. SSOT `.dev/gc_rooting.md`
E4/E6 updated. D-250 tier-2 = multi-thread-clean.

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
