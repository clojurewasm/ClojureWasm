# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: ≈ `38706fcd` (see `git log` for current). Mac **303/0** + ubuntunote
  **302/0** (1-step delta = Mac-only zlinter gate, ADR-0003). Tree clean. All
  three CFP-demo goals delivered + the io/url half-done items completed (D-357
  getAbsolutePath/getCanonicalPath; D-359 as-url→java.net.URI + reader/writer
  URI arms) + D-361 cross-platform heap-cap bug root-fixed + Linux-verified.
  Both demos (`$MY/playground-v2` + `$MY/serverless-v2`) are babashka-free,
  cljw-native, one-command local (`./run_local.sh`, env mirrors fly.toml) +
  fly-ready, and verified end-to-end (playground via curl + my-playwright:
  eval/runaway/static/wasm-FFI nth_prime=541; bookshelf via curl:
  static/config/books-from-SQLite-wasm).
- **First commit on resume MUST be**: **D-358** (stream leaf-name `instance?` —
  add a closed-set of host_stream's READER/WRITER/INPUT/OUTPUT_NAMES to
  `class_name.isKnown`, mirroring the host_interfaces.yaml pattern; the leaf
  names are already in each family descriptor's `protocol_impls`, so
  matchUserType will match once isKnown recognises them — avoid a
  class_name↔host_stream import cycle, define the name list in a leaf module or
  inline). **Then D-356** (bookshelf single-binary via `cljw build`: a
  build-entry .clj requiring bookshelf.server + `(-main 8080)`, classpath for the
  multi-file requires, runtime assets relative to cwd). After BOTH: see **D-362**
  — the Clojure Conj 2026 CFP runway (repo migration to clojurewasm org → fly
  deploy → zwasm v2.0.0-alpha.2 tag → build.zig.zon pin → README/CFP), which is
  user-collaborative.
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
reused, cond dispatch). DONE since: D-357 (getAbsolutePath via
currentPathAlloc), D-359 (as-url→URI + URI reader/writer arms), D-361 (heap-cap
infra-buffer fix). Still deferred: D-358 (stream leaf-name instance?), D-360
(read-str :key-fn), resource (no classpath), D-051 (byte-array Value, Phase 16).

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
DA Alt 2) → `.dev/debt.yaml` (D-358 + D-356 = next; D-362 = CFP runway) →
`.dev/lessons/io_isolation_findings.md` (budget-scope / heap-cap / cwd /
look-ahead-gate know-how) → `~/Documents/MyProducts/RESUME_cfp_demos.md` (demo
background) → CLAUDE.md.

## Stopped — user requested

User instruction (2026-06-09): "ここまでのノウハウや経緯を永続化しつつ、次の
クリアセッションから continue で D-358, D-356 に取り組めるよう配線、参照
チェーンを監査して止まって". Then (post-debt) the D-362 CFP runway: register
playground-v2 → `cw-playground` + serverless-v2 → `cw-serverless-demo` under the
clojurewasm org, delete the old `playground`/`edge-demo` repos, deploy to fly.io
collaboratively (fly CLI + dashboard, verify, micro-fix), tag zwasm
`v2.0.0-alpha.2`, repoint ClojureWasmFromScratch build.zig.zon to that tag, then
README/CFP polish for Clojure Conj 2026. Resume at **D-358** (then D-356, then
D-362). Know-how persisted in `.dev/lessons/io_isolation_findings.md` + the
per-task notes in `private/notes/`.
