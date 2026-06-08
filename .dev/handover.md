# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: newest pushed ≈ the D-336 trace-across-boundary source commit
  (see `git log`). The error-display overhaul is comprehensively landed —
  caret / naming / trace / trace-discipline / cross-thread fidelity +
  trace-across-boundary all shipped. Working tree clean of source.
- **First commit on resume MUST be: D-333 — the post-mortem `cljw render-error`
  decoder reads the EDN `:trace`.** Live text `Trace:` + EDN `:trace` are in
  lockstep, but `render_error.zig` (a hand-rolled flat-field scan;
  `renderOne` at :81) does NOT decode the nested `:trace [{:fn ".."  :ns ".."
  :file ".." :line N} …]` vector — the decoded-log view omits the trace. Add a
  nested-vector scan after the header/message in `renderOne` that walks each
  inner `{…}` map and prints `  <ns>/<fn> (<file>:<line>)`, matching the live
  text renderer (confirm the exact format from `runtime/error/print.zig`'s
  `Trace:` writer). Hand-rolled scan, NOT a full EDN parser (per the file's
  decoder-strategy docstring + v0.1.0 stability lock). Read FIRST:
  `.dev/debt.yaml` D-333 + `src/app/render_error.zig` + `runtime/error/print.zig`.
  After D-333: D-328 (`pr`/`str` of a fn shows its name) → D-325 (`(fn name …)`
  self-name).
- **Forbidden**: trusting a bg-gate notification's exit code (verify ONLY via
  Summary `failed: 0` + `.gate_pass` == `bash scripts/gate_state_hash.sh`).
  Skipping `zig build lint` (~2s) before the full gate when you delete/delegate
  a body or add a file — `no_unused` fires ONLY in the full gate (memory
  `zlinter_unused_only_full_gate`). Re-introducing a v0-style `defining_ns`
  current-ns restore (display-only, ADR-0119 §4). Editing `.claude/rules/*`
  (permission-blocked → carry-over). Pinning a zwasm v2 tag (F-001).

## Done this session (D-336 trace across the thread boundary)

- **Trace-on-ExInfo** (ADR-0120 §1, D-336): `ExInfo` gains `trace_ptr`/
  `trace_len`, deep-copied (frame array + each frame's `fn_name`/`ns`/`file`
  strings GC-owned, freed in `finaliseGc` — same ownership as `message`/
  `origin_file`). `allocExceptionLoc` gains a `trace` param; the 3 synth/marshal
  sites (vm.zig, tree_walk.zig, worker_error.zig) pass `info.trace`;
  `buildThrownInfo` reads `originTrace`. `@(future (boom))` renders
  `Trace: user/boom` across the OS-thread boundary; the in-thread
  `(throw (try (boom) …))` trace gap closes too. Discharges D-336 + D-330 + D-335
  (full cross-thread fidelity: kind/message/location/class/trace). Tests: 2 new
  e2e (error_future_trace_crosses + error_thrown_trace_inthread) + a deep-copy
  unit test (survives source-array mutation).

## Remaining tail (tracked)

- **D-333**: post-mortem `render-error` decoder reads EDN `:trace` (next; see
  resume contract).
- **D-328**: `pr`/`str` of a fn shows its name (couples to `(class fn)` format).
- **D-325**: `(fn name ..)` self-name (needs an analyzeFnStar self-name arm).

## Process discipline (SSOT = memory + rules)

- Full gate (shared-code): `timeout 1800 bash test/run_all.sh --serial-e2e`;
  verify Summary `failed: 0` + `.gate_pass` == `gate_state_hash.sh`. `zig build`
  (not `zig build test`) rebuilds `zig-out/bin/cljw`. Backend default = vm
  (F-012). Tool channel corrupts stdout under load — verify cljw output via
  per-cmd files + Read, not chained echoes.

## Cold-start reading order (tracked-only)

handover → `.dev/debt.yaml` D-333/328/325 → `src/app/render_error.zig` (the
decoder) + `src/runtime/error/print.zig` (the live `Trace:` text writer) →
`.dev/decisions/0120_cross_thread_error_fidelity.md` (the trace carrier) →
`.dev/decisions/0119_callable_naming_surface.md` (naming + trace discipline) →
`.dev/decisions/0118_error_display_v0_level.md` (caret/cycle base) → CLAUDE.md →
`.dev/principle.md`.
