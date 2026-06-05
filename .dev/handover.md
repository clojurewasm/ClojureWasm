# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (`cw-from-scratch`). Gate green 251/0 Mac + 250/0 Linux
  x86_64 (serial-e2e). debt = `.dev/debt.yaml`. Active plan = **ADR-0089 (A→B→C)**.
- **First commit on resume MUST be**: the **Clojure-vs-ClojureWasm differences doc**
  (D-249) — the user set **docs/release-prep ABOVE the low-value concurrency tail**
  (2026-06-05). A single-sheet `docs/` markdown synthesizing AD-001..014 + the
  F-NNN-intentional divergences + the deferred surface (ClojureScript-style). THEN
  (priority order): **GC torture mode** (D-250 — validate the #4a' rooting before
  the GATED auto-collect-ON flip) · **Group D wasm→tail reorg** (D-248 — a ready,
  NON-breaking ADR-0027 cleanup, no F-004 amendment) · then the low-value
  concurrency tail (agent watches/validator / `await-for` / `shutdown-agents` /
  with-local-vars D-237 — NOT skipped, after completeness). The **#4a' GC-ROOTING is
  COMPLETE** (in-txn maps self+worker, TDD-verified; only the GATED auto-collect-ON
  flip remains). Heap-tag layout stays **64 slots** (F-004 Rev 2026-06-05; 128 +
  region allocator = D-247, only IF slots run out). Phase C = library-gap-hunt →
  Wasm (zwasm before release). Phase B concurrency PRIMITIVES complete + dual-arch-
  verified + code-reviewed. src commits gate `--serial-e2e`. Cold-start:
  `private/notes/layout-gc-decisions-2026-06-05.md` + `phaseB-4a-self-tx-rooting.md`.
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

**Phase B concurrency PRIMITIVES + #4a' GC-rooting COMPLETE** (git log = SSOT;
ADR-0090/91/92/93). GC STW handshake + `future`/`promise`/`delay` (real threads) +
STM (full, deadlock-free) + `locking` + atomic atom/volatile/ref + agent (+ error
modes) + Thread/sleep + with-out-str + a ReleaseSafe stress step + the #4a' in-txn-
map rooting (self+worker, TDD). **Two real ReleaseSafe-only races found+fixed**: STM
`doGet` stale read + the atom being non-atomic (`swap!`→CAS-retry). Code-reviewed
(+2 GC-safety fixes); dual-arch (Mac + Linux x86_64) green.

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

handover → `private/notes/layout-gc-decisions-2026-06-05.md` (latest decisions) +
`phaseB-4a-self-tx-rooting.md` → **`.dev/debt.yaml` D-249/250/248/247** (next tasks) +
ROADMAP **§9.2.R** (priority refinement 2026-06-05) → **`.dev/project_facts.md` F-004**
(Rev 2026-06-05, 64-keep) + F-002/006/011 → CLAUDE.md (§ Project spirit + The only
stop) → `.dev/decisions/0090..0093` (concurrency/locking/agent) → `.dev/principle.md`.

## Stopped — user requested

User instruction (2026-06-05): "コンテキストウィンドウが広がってきたので、64維持とか
これまでの議論で確定したものを、クリアセッションから continue したときにちゃんと
取り組めるように、配線・参照チェーン確認して用意して止めてください。" Wiring done:
F-004 Rev (64-keep / 128-defer) + ROADMAP §9.2.R priority refinement + debt
D-247 (region-alloc→128) / D-248 (Group-D wasm→tail reorg) / D-249 (differences doc,
HIGH) / D-250 (GC torture) + note `layout-gc-decisions-2026-06-05.md`. Resume at the
differences doc (D-249) per the Resume-contract priority order.
