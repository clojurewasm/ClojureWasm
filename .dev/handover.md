# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (see `git log`). All work happens on `main`; commit + `git
  push origin main` is the atomic Step 6 (`git push --force*` is deny-listed).
  Gate cadence (ADR-0107): per-commit **smoke** (background, don't block); batch
  the full gate ALONE (`timeout 900 bash test/run_all.sh --serial-e2e`) at the
  ≤5 ceiling / boundary. **Perf is measured ONLY on a Release binary via
  `scripts/perf.sh` / `bench/`, NEVER `time zig-out/bin/cljw` (Debug)** —
  `.claude/rules/perf_measure_release.md`.
- **First commit on resume MUST be: the performance-tuning campaign
  (ROADMAP §9.2.S), run continuously and autonomously — user-directed
  2026-06-11. Only an explicit user stop halts it (CLAUDE.md § The only stop);
  unit / boundary transitions roll straight into the next unit.** Three axes:
  **execution speed, startup speed, binary size.**
  1. **Build / confirm the experiment → measure → keep-or-revert loop first**:
     baseline with `scripts/perf.sh` (Release) + `bench/run_bench.sh` +
     `bench/compare_langs.sh`; make ONE change; re-measure; keep if faster, else
     `git` revert. **Measure the FOCUSED target only** — `bash bench/run_bench.sh
     --quick --bench=<name>` (3 runs / 1 warmup, low-noise); run the FULL suite
     (no `--bench`) only for regression once a real win lands, not every iteration.
     Each unit is its own commit (revert-friendly); log every
     speed-for-simplicity trade in [`.dev/optimizations.md`](./optimizations.md)
     (O-NNN SSOT) + a `// PERF:` marker; the naive form stays the F-011 contract
     (observably equivalent vs `clj`).
  2. **Then ROI-ordered units** (impact × frequency / effort · risk), bench-driven
     from the slowest / most-global spots. Resume at **D-163** (lazy-chain
     reduce-fusion, ADR-0065 ACTIVE) → **D-140** (startup bootstrap cache —
     highest dev-velocity ROI). Add a **binary-size** axis (ReleaseSafe / Small;
     what bloats the binary). O-001 / O-002 / O-003 (D-180) are already DONE.
  - **Do NOT touch zwasm** — it stays as a long-lived branch for the CFP.
    Optimize cljw's own Clojure processing only. Step-0 survey may reference cw v0
    (`~/Documents/MyProducts/ClojureWasm/`: `Meta.range` / `fusedReduce` /
    incremental-trie transients — re-derive cljw-appropriately per F-004, not
    copy), other reference clones, and web search.
  - This supersedes the §9.2.P clj-parity / Phase-A "resume here" markers for
    this session (user re-prioritization 2026-06-11).
- **Forbidden this session**: editing zwasm; `git push --force*`. Run
  continuously per CLAUDE.md § The only stop.

## Just landed — 2026-06-11 (pushed to `main`)

- **Bench overhaul**: run_bench.sh wasm suite rebuilt on the real FFI API
  (`wasm/load` + `wasm/call`) + hand-authored `.wat` fixtures (`bench/wasm/ffi/`);
  +7 benchmarks (numeric tower / STM / regex / sort / destructure / edn);
  cross-language **Go** column + cold/warm tables; `flake.nix` pins the
  comparison + wasm toolchains (clang/jdk/python/ruby/node/babashka/go/tinygo/
  wasmtime/wasm-tools). cold-start re-measured → **~5 ms** (RELEASE_METRICS +
  this file synced). D-384 = wasm_bench's WASI-import-FFI gap.
- **CFP** (`private/clojure_conj_2026_cfp/`, USER-OWNED, not an autonomous task):
  reviewer info finalized (1–8); recorded-talk outline + script DRAFT in
  SUBMISSION.md, to discuss with the user. Paused on the user.

## Cold-start reading order (perf campaign)

handover → ROADMAP §9.2.S (campaign + resume D-163) → `.dev/optimizations.md`
(O-NNN SSOT) → `scripts/perf.sh` + `.claude/rules/perf_measure_release.md` (how to
measure) → `bench/run_bench.sh` / `bench/compare_langs.sh` (ROI from the slow rows)
→ cw v0 `~/Documents/MyProducts/ClojureWasm/` (perf precedent).
