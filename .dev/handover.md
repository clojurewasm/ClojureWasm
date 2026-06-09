# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: ≈ `ffd7ecd2` (see `git log` for current). Mac gate baseline
  **303/0** `--serial-e2e`. Tree clean. The user's 3 CFP-demo goals are all
  delivered (io subsystem + babashka-free playground D-355 + fly.io configs for
  both demos — the latter two in the `$MY/playground-v2` + `$MY/serverless-v2`
  repos, not this one).
- **First commit on resume MUST be**: **D-361** — make the Linux-only
  `e2e_phase16_eval_budget` heap case diagnosable, then fix. The runner cap-lift
  did NOT resolve it (Linux `$out` is empty + non-zero → process killed without
  rendering). Concrete step: add an exit-code echo to the heap case in
  `test/e2e/phase16_eval_budget.sh` (124=timeout vs 137=OOM disambiguates
  cause), `bash scripts/run_remote_ubuntu.sh`, then fix (loosen the timeout, or
  make `heap_ceiling` cover the bulk-alloc path it currently misses). Mac cannot
  reproduce. If you'd rather defer D-361 (Linux-env-bound), self-select per
  CLAUDE.md § The only stop — D-356 (bookshelf single-binary via `cljw build`)
  or a quality-loop floor.
- **Forbidden**: pushing to `main`; pinning a zwasm tag (F-001 relative-path
  co-dev). Two gates at once (share `/tmp/codev_gate.lock` — `mkdir` acquire,
  `rmdir` release).

## Just landed — clojure.java.io subsystem (ADR-0126, 9 commits)

Full cljw-native io, `bca4eb9d..8a9460fd`: `java.io.File` host type (Cycle 1) ·
`clojure.java.io` file family + reader/writer/input-stream/output-stream + copy
+ as-url/resource stubs (Cycles 2,4,5,6) · `clojure.core/line-seq` · generic
buffer-backed `host_stream` (Cycle 3, `runtime/io/host_stream.zig`) ·
`cljw.json` (encode/decode-keywordized) + `cljw.fs` (babashka.fs-style) (Cycle
7) · D-361 Linux heap-render fix. cljw-style (no-JVM, F-009 neutral impl, FS-jail
reused, cond dispatch). Deferrals tracked: D-357 (getAbsolutePath, no cwd path),
D-358 (stream leaf-name instance?), D-359 (URL/resource), D-360 (read-str
:key-fn), D-051 (byte-array Value, Phase 16).

## Process discipline (SSOT)

- **Gate cadence**: additive (pure-insertion .clj/new file) commits ride on
  per-feature smoke (`zig build` + `cljw -e` probes + the new e2e) up to 5
  before a full gate; **shared-code (existing-line edit / build.zig\*) needs a
  fresh full gate**. `bash test/run_all.sh --serial-e2e`; verify Summary
  `failed: 0` + `.dev/.gate_pass` == `scripts/gate_state_hash.sh`.
- **Linux gate is independent** (ubuntunote, remote): launch in background
  against a pushed HEAD as look-ahead; it does not contend with local smoke.
  `timeout 1800 bash scripts/run_remote_ubuntu.sh`.
- Demo binary is `cljw-wasm` (separate from the gate's `cljw`); rebuild before
  any playground run.

## Cold-start reading order

handover → `.dev/decisions/0126_clojure_java_io.md` (the io subsystem ADR +
DA Alt 2) → `.dev/debt.yaml` (D-355 playground, D-357..361 io deferrals) →
`~/Documents/MyProducts/RESUME_cfp_demos.md` (demo background) → CLAUDE.md.
