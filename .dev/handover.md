# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log`. Newest pushed = **6d36acc4** feat(error): v0-form
  renderer (ADR-0118 cycle 2). STREAM 1 (CLI align) + STREAM 2 (bench table) +
  ADR-0118 cycle 1 (loc back-fill) + cycle 2 (renderer) are all DONE + pushed.
  Working tree is clean of source (only this file's edit + gitignored
  `private/notes/`).
- **First commit on resume MUST be: ADR-0118 cycle 2.5 — arg-precise carets.**
  User directive (2026-06-08): the caret must land on the culprit — `(/ 2 0)`
  on the `0`, not the `(`; nested `(+ 1 (/ 2 0))` on the innermost; UNIFORM
  discipline, not per-primitive. The full plan + the verbatim Devil's-advocate
  output + the decision (Alt 1, NOT the DA-recommended Alt 2, with the rebuttal)
  + the exact edit sites (file:line) live in
  **`private/notes/phase14-error-cycle2.5-caret-precision-plan.md`** — read it
  FIRST; it is turn-key. Steps: (a) write ADR-0118 **Revision 2** (promote
  arg-precise carets from Decision A's "deferred until a sweep" to required;
  paste the DA output verbatim into "Alternatives considered"; doc commit
  first). (b) impl Alt 1 — threadlocal `arg_sources` in `info.zig:171-189`,
  record in `tree_walk.zig:1019` + the VM `op_call` (`vm.zig:377`), primitives
  name the culprit index (`math.zig` `slash`/`ensureNumeric` first). (c)
  dual-backend parity diff case (`(/ 2 0)` caret col equal vm == tree_walk). (d)
  tighten `phase14_error_format.sh` Case 8/9 to assert the divisor column. (e)
  gate + commit + push.
- **Forbidden**: trusting a bg-gate notification's exit code — it lies (false
  exit-0 over a real GATE_EXIT=124 timeout AND over a real exit-1 fail this
  session); verify ONLY via `SENTINEL-EXIT` / Summary `failed: 0` + `.dev/.gate_pass`
  == `bash scripts/gate_state_hash.sh`. The DA's Alt 2 eval-loc stack (it
  mis-attributes non-last-arg culprits under v1's eager-arg model). A separate
  `BytecodeChunk.locs[]` table (per-instruction `line/column` already rides every
  `Instruction`). A span/underline upgrade this cycle (deferred — single caret
  meets the directive; follow-on O-NNN under D-323). Running a CPU-heavy
  `zig build` / subagent CONCURRENT with a gate (contends perf-threshold steps +
  muddies which binary is on disk). Editing `.claude/rules/*` (permission-blocked
  → carry-over). Pinning a zwasm v2 tag (F-001).

## Cycle status (ADR-0118 error display, D-323)

- Cycle 1 (loc back-fill; VM per-instruction loc → real SourceLocation; E.1+E.2):
  DONE, pushed.
- Cycle 2 (v0-form renderer: natural-kind header + numbered ±2 window + `^--- msg`
  caret + EDN lockstep; render_error.zig reuses `print.zig::writeNaturalKind`):
  DONE, pushed (6d36acc4). 16 e2e migrated to the natural-kind text surface.
- Cycle 2.5 (arg-precise carets, Alt 1): NEXT — ADR Rev 2 + impl + parity test.
- Cycle 3 (frame `Trace:`, Decision B): pop-on-both + snapshot-at-raise at the
  shared `callFn`/`callMethodImpl` choke point; EDN `:trace` lockstep.

## Process discipline (SSOT = memory + rules; do NOT re-expand here)

- Gate (source only): `timeout 1800 bash test/run_all.sh --serial-e2e` (NOT the
  -P8 default — it 300s-timeouts mid-e2e under host load). Verify via Summary
  `failed: 0` + `.gate_pass` == `gate_state_hash.sh`, never the notification.
- The gate's e2e cljw binary is **ReleaseSafe** (`run_all.sh:306-307`,
  ~2.9MB) — NOT Debug; only `zig build test` (unit) is Debug. The bench
  `REGRESSION` rows are ReleaseSafe-vs-old-baseline, informational `[pass]`.
- Docs (`.dev/`, ADRs, this file) do NOT change the gate fingerprint. cljw -e of
  `(prn X)` echoes X then nil — e2e use BARE exprs. Edit/Write TRANSCODES
  non-ASCII (splice via python). Backend default = vm (F-012). Measure speed ONLY
  via bench harness / scripts/perf.sh (Release).

## Cold-start reading order (tracked-only)

handover → **`private/notes/phase14-error-cycle2.5-caret-precision-plan.md`**
(turn-key cycle 2.5 plan + DA output + Alt-1 decision + edit sites) →
`.dev/decisions/0118_error_display_v0_level.md` (+ Rev 1; Rev 2 to write) →
`.dev/debt.yaml` D-323 → `src/runtime/error/print.zig` (renderer) +
`src/runtime/error/info.zig:171-262` (threadlocal error state + BuiltinFn) +
`src/eval/backend/tree_walk.zig:1014` (evalCall) → CLAUDE.md → `.dev/principle.md`.

## Stopped — user requested

User instruction (2026-06-08): "rate limit の件があるので、これ [ADR-0118
cycle 2] の完遂をもってキリが良いところで、次のクリアセッションから続きから
continue できるように配線・参照チェーンを確認して止めて". Cycle 2 is committed +
pushed (6d36acc4); the reference chain is verified. Resume at ADR-0118 cycle 2.5
(the "First commit MUST be" above). This section applies to the previous session
only — the next `/continue` deletes it and resumes the loop unchanged.
