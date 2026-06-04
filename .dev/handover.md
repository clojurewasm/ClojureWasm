# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (`cw-from-scratch`). Gate green 247/0 (Mac, serial-e2e).
  debt ledger = `.dev/debt.yaml`. Active plan = **ADR-0089 re-cut (A→B→C)**.
- **First commit on resume MUST be**: **Phase B #4b-future** — rewrite
  `src/runtime/future.zig` (today an eager-inline shell) into a REAL worker
  thread. The entire GC handshake + worker-park wiring is LANDED + gated (see
  Recently landed): a future worker is now safe under a concurrent collect (it
  parks at the alloc prologue or the `vm.eval` back-edge poll; its operand stack
  + bindings + macro slot + fabrication self-guard are published; the collector
  STW-walks the union). The surface stays `(future e)` → `(__future-call (fn* []
  e))` → `future_mod.alloc(rt, env, thunk, loc)` (stm.zig:78). `alloc` spawns a
  `std.Thread` running the thunk via `callFn` (the VM path on the VM-default
  build, F-012), `gc.pin`s the Future for the worker's lifetime, registers a
  `ThreadGcContext`, stores the result under an `Io.Mutex`+`Io.Condition` cell,
  signals; `deref` blocks on the cond. Detach the thread (cond synchronises
  deref; shutdown-orphan = debt). Full plan + cautions:
  `private/notes/phaseB-4b-poll.md` § next task. Then the Q1 `gc_self_guard`
  setters (op_vector/map/set_literal + callMethodImpl rest-list) → (5) STM
  `lock_tx.zig` → (6) `agent`/`locking`. rework-OK + test guards (F-002).
- **Forbidden this session**: turning auto-collect ON before the **#4a'**
  runtime-wide fabrication-window audit (collect stays explicit/test-triggered;
  the safepoint is wired so any collect is safe); minting **AD-013 before its pin
  test exists** (lands WITH the Phase B STM concurrent test); editing
  `.claude/rules/*` (permission classifier blocks it as self-mod — surface to
  user, see memory); "fixing" an AD-001..012 accepted divergence; re-opening
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

**Phase B GC handshake COMPLETE** (ADR-0090 Alt B + ADR-0091): #1 io_default ·
#2 GC global-heap alloc-lock · #3a `ThreadGcContext` registry + union root walk ·
**#3b-step1** operand-stack publication via a thread-major `thread_roots` cursor
(ADR-0091 — subsumes current_frame+macro, walks each thread's VM `EvalFrame`
chain) · **#3b-step2a** safepoint primitives (`concurrency/safepoint.zig`:
stopWorld / park / resumeWorld) · **#3b-step2b** `gc_self_guard` self-guard (4th
sub-walk) · **#4a-alloc** alloc-prologue park + `mark_sweep.collectStopTheWorld` ·
**#4b-poll** `vm.eval` back-edge poll. All runtime-inert (nothing arms
`gc_requested` / sets `gc_self_guard` until #4b's real worker); each landed with
real-`std.Thread` isolation tests.

## Open carry-overs (actionable)

- **3 rules** carry a stale `src/runtime/host/**` glob (→ `runtime/java/**`, ADR-0029);
  the cleanup Edit was declined by the permission classifier as agent-config
  self-mod — awaits user authorization (harmless; rules still load via other
  globs). Memory `claude-rules-edit-permission-block`.
- **D-243** = 8 re-opened deferrals: host-surface impls D-048/105/106 (Phase C) ·
  bench D-104 · regex/string D-054/056/057 · D-049 (user-owned F-NNN).
- **D-244** = the GC-handshake checklist; #4b-future + Q1 setters + #4a' remain.

## Process discipline (SSOT = memory + rules; do NOT re-expand here)

- Gate (Phase B/C source work only): `timeout 1800 bash test/run_all.sh
  --serial-e2e` (~5min; -P8 over-runs under load). Doc-only = no gate.
- Never poll a bg gate. `clj -M -e` → `timeout 20` + bound infinite seqs. Speed
  ONLY via `scripts/perf.sh`. Edit/Write TRANSCODES literal non-ASCII (keep source
  ASCII; splice non-ASCII doc edits via python). Default backend = VM (F-012).
- Swept fake GC test Cells use a finaliser-free tag (`.vector`), NOT `.string`
  (its finaliser reads a data ptr a 16-byte fake Cell lacks → crash).

## Cold-start reading order (tracked-only)

handover → `private/notes/phaseB-4b-poll.md` (the #4b-future plan + cautions) →
**`.dev/decisions/0090_phase_b_concurrency_redesign.md`** ("D-244 decision" = Alt
B spine) + **`0091_operand_stack_root_thread_union.md`** (thread_roots cursor) →
**`.dev/debt.yaml` D-244** (handshake checklist; #4b / Q1 / #4a' remain) + D-242 →
ROADMAP §9.2.R/§7 → CLAUDE.md (§ Project spirit + Autonomous Workflow + The only
stop) → `.dev/project_facts.md` (F-002/004/005/006/009/011/012) → `.dev/principle.md`.
