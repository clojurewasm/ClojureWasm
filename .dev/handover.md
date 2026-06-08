# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: newest pushed ≈ the D-336 trace-across-boundary source commit
  (see `git log`). The error-display overhaul is comprehensively landed —
  caret / naming / trace / trace-discipline / cross-thread fidelity +
  trace-across-boundary all shipped. Working tree clean of source.
- **First commit on resume MUST be: D-327 — builtins print `#<clojure.core/name>`,
  not `#builtin`.** This is the last form of the callable-print surface (ADR-0121
  / AD-025 closed fn/multifn/protocol-fn and co-designed the envelope so D-327
  only fills the builtin name). Builtins are NaN-boxed immediate fn-pointers
  (value.zig) with no name slot, so `print.zig`'s `.builtin_fn` arm prints
  `#builtin`. Plan: build a reverse `ptr → ns/name` map at `primitive.registerAll`
  into an rt-owned `AutoHashMap(usize, FnIdentity)`, expose a Layer-0 accessor
  (same setter-injection shape as the `.fn_val` `fn_name_accessor` ADR-0121 added),
  and have the `.builtin_fn` arm format `#<ns/name>` via `printCallable`. Read
  FIRST: `.dev/debt.yaml` D-327 + `src/lang/primitive.zig` (registerAll) +
  `src/runtime/print.zig` (`.builtin_fn` arm + `printCallable` + `setFnNameAccessor`
  precedent) + `.dev/decisions/0121_callable_print_naming.md`. After D-327 the
  callable-print area is exhaustively closed; next self-select is a quality-loop
  floor row (D-210 clj-parity / D-273 bundled-lib / D-242 concurrency — drain
  highest-value-first per CLAUDE.md).
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
