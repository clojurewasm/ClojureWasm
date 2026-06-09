# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: ≈ `1764f6fa` (see `git log` for current). Mac **303/0** + ubuntunote
  **302/0** (1-step delta = Mac-only zlinter gate, ADR-0003) both green. Tree
  clean. The user's 3 CFP-demo goals are all delivered (clojure.java.io
  subsystem ADR-0126 + babashka-free playground D-355 + fly.io configs for both
  demos, the latter two in `$MY/playground-v2` + `$MY/serverless-v2`), and the
  D-361 cross-platform heap-cap bug is root-fixed + Linux-verified.
- **First commit on resume MUST be**: self-select a quality-loop unit — the
  demo arc + D-361 are closed. Candidates, highest-value first: (1) implement the
  now-UNBLOCKED **D-357** (getAbsolutePath/getCanonicalPath via
  `std.process.currentPathAlloc(rt.io, a)` + resolvePosix — research corrected
  the "no cwd path" premise) to finish the `java.io.File` surface; (2) **D-358**
  (stream leaf-name `instance?` closed-set in class_name.isKnown); (3) a
  simplify/audit pass on the large ADR-0126 io diff. (User greenlit completing
  the io/url half-done items — D-357 + D-359 as-url/URL — this session.)
  **D-356** (bookshelf single-binary via `cljw build`) stays user-deferred.
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
