# ADR-0049 — Retire `orb run -m my-ubuntu-amd64` per-commit Linux gate; migrate to `ubuntunote` SSH host

- **Status**: Proposed → Accepted (issued 2026-05-28, implementation
  verified same day)
- **Affected**: `test/run_all.sh` (header comment); `CLAUDE.md`
  § Working agreement + § Build & test; `.dev/ROADMAP.md` Phase
  tracker + 🔒 OrbStack annotations; `.dev/orbstack_setup.md`
  (deprecated header); `ARCHITECTURE.md` cross-arch test row;
  new `scripts/run_remote_ubuntu.sh` + `.dev/ubuntunote_setup.md`.
- **Supersedes**: per-commit `orb run -m my-ubuntu-amd64` gate
  language across CLAUDE.md / ROADMAP / ARCHITECTURE / orbstack_setup;
  all retired in this commit.

## Context

`bash test/run_all.sh` has run twice per commit since Phase 1.12:
once on Mac (host, `aarch64-darwin`) and once on Linux x86_64 via
`orb run -m my-ubuntu-amd64 bash -c 'bash test/run_all.sh'`. The
OrbStack-driven Linux run validates cross-arch + cross-OS
portability of the cw v1 codebase.

Two operational pains accumulated and prompted the migration:

1. **Orphan-process hazard on session interruption.** cw's per-task
   loop has invoked the Linux gate from `run_in_background:true`
   bash agents to overlap with Mac measurement. When the parent
   Claude session terminates abnormally (compaction crash / harness
   kill / user interrupt), the `orb run` child inherits `PID 1`,
   the OrbStack VM (`my-ubuntu-amd64`) holds the connection open,
   and downstream pipeline parts (e.g. `grep` on a hung REPL
   stdin) spin at 100 % CPU. A 2026-05-28 incident ran ~1h50m on
   the user's Mac (fan + Helper CPU pinned) before a sibling
   session reaped it.
2. **VM hang propagation.** When the OrbStack VM enters its own
   hung state, subsequent `orb run` invocations queue rather than
   error out, masking the issue and exhausting CPU budget on the
   OrbStack Helper process.

zwasm v2 (sibling project on the same host) retired the same
gate earlier under their ADR-0067; cw v1 mirrors the migration
here with the same `ubuntunote` SSH host already provisioned for
zwasm.

## Decision

Remove `orb run -m my-ubuntu-amd64` from the per-commit gate.
`bash test/run_all.sh` runs **only on the Mac host** for the loop's
TDD cycles. Cross-arch / cross-OS portability validation moves to:

1. **Manual via `scripts/run_remote_ubuntu.sh`** — invoked by the
   reviewer at Phase-boundary review chains, before the v0.1.0
   release tag, and on demand during a feature branch's late
   stages. Drives the `ubuntunote` SSH host (native x86_64 Linux,
   physical hardware) via `git fetch + reset --hard
   origin/cw-from-scratch` + `nix develop --command bash test/run_all.sh`.
   Setup procedure at `.dev/ubuntunote_setup.md`.
2. **Future CI integration** — a GitHub Actions / equivalent
   workflow that runs the gate on `ubuntu-latest` for every push
   closes the gap for every commit. Filed as new debt D-120
   (opportunistic — first GitHub Actions push).

Until CI lands, **cw v1 single-OS Mac coverage is the per-commit
contract**; cross-arch regressions surface at the next
`run_remote_ubuntu.sh` invocation + at CI activation.

## Implementation verified (2026-05-28)

The migration was implemented + verified within the same cycle:

1. **`ubuntunote` SSH reachability** confirmed: `ssh ubuntunote
   'echo ok && nix --version'` returns `ok` + `Determinate Nix
   3.20.0`.
2. **cw repository clone** landed on ubuntunote:
   `~/Documents/MyProducts/ClojureWasmFromScratch` via
   `git clone -b cw-from-scratch
   https://github.com/clojurewasm/ClojureWasm.git` (HTTPS is
   sufficient for the read-only fetch flow; mirrors zwasm's
   clone pattern).
3. **`nix develop --command zig version`** returns `0.16.0` from
   the project's `flake.nix` pinned input. First invocation
   bootstrap took 15 s (with cached store entries shared with
   the zwasm bring-up on the same host).
4. **Full gate** `nix develop --command bash test/run_all.sh`
   on ubuntunote: **84/84 PASS** at HEAD `a9045b10` (the +1
   diff vs Mac 85/85 is the zlinter step, Mac-only per
   ADR-0003).
5. **Wrapper** `scripts/run_remote_ubuntu.sh` lands in this
   commit (mirrors zwasm v2's `scripts/run_remote_ubuntu.sh`
   shape: preflight + sync + gate with labelled failure
   attribution).

## Alternatives considered

(Devil's-advocate fork not run — the decision is operational
governance, not a structural design choice. The three
alternatives below were enumerated inline by the issuing chat.)

### A. Keep `orb run` per-commit + add `timeout 600` wrap

- **Sketch**: every Linux gate invocation wraps `orb run …` in
  `timeout 600 …` so a hung VM dies after 10 min instead of
  spinning forever.
- **Why rejected**: addresses the symptom (CPU spin duration)
  not the root (no orphan-reap when Claude session dies). 600 s
  spin × repeated crashes still drains fan / battery. The
  `timeout` wrap propagates SIGTERM to `orb run` but not into
  the VM-side child process, so the VM can stay hung after
  `orb run` exits.

### B. Retire `orb run` AND adopt a containerised runner inline (Docker / Podman)

- **Sketch**: replace `orb run` with `docker run --rm -v
  $(pwd):/repo -w /repo zig-0.16:latest bash test/run_all.sh`.
- **Why rejected**: Docker / Podman is not currently a cw v1
  dev-env dependency; introducing one for a single gate pushes
  the dev-env baseline. Defer to CI activation (D-120) where
  the runner image is managed by GitHub Actions infrastructure.

### C. (Adopted) Retire `orb run` + reuse the `ubuntunote` host already in zwasm

- See § Decision. The shared host is already provisioned for
  the sibling project; cw inherits the bring-up at no extra
  cost beyond a one-time `git clone`.

## Consequences

- **Positive**: per-commit gate loses one OS-coverage surface
  but gains stability; no orphan / fan / CPU regression risk;
  cw's TDD loop is single-OS-fast.
- **Positive**: OrbStack VM lifecycle is no longer in the cw
  per-commit critical path. `orb stop my-ubuntu-amd64` is
  acceptable at any time without affecting cw work.
- **Positive**: ubuntunote is real hardware → no Rosetta
  signal-delivery surprises (a JIT-era hazard cw v1 will hit
  at Phase 17).
- **Negative**: cross-arch / cross-OS regressions can sneak in
  between manual `run_remote_ubuntu.sh` invocations. Mitigation:
  D-120 GitHub Actions activation.
- **Neutral**: `~/Documents/MyProducts/ClojureWasm` v1 reference
  clone is unaffected — this ADR retires the **gate**, not the
  **reference clone**.

## Migration steps (landed in this commit)

1. `scripts/run_remote_ubuntu.sh` (new): wrapper invoking the
   ubuntunote gate via SSH + `nix develop`. Mirrors zwasm's
   pattern (labelled failure attribution; `--branch` flag for
   feature-branch verification).
2. `.dev/ubuntunote_setup.md` (new): cw-side setup notes; defers
   the full Ubuntu bring-up procedure to
   `~/Documents/MyProducts/zwasm_from_scratch/.dev/ubuntunote_setup.md`
   §§ 1-3 (shared host); documents the cw-specific clone +
   `flake.nix` chain.
3. `test/run_all.sh`: top-of-file comment block updated to point
   at `scripts/run_remote_ubuntu.sh` for the Linux gate (the
   script body did not invoke `orb run` itself).
4. `CLAUDE.md` § Working agreement + § Build & test: the
   "OrbStack Ubuntu x86_64 before every commit" sentence is
   removed; "Linux gate runs at Phase boundary + via
   `scripts/run_remote_ubuntu.sh`" replaces it.
5. `.dev/ROADMAP.md`: 🔒 OrbStack annotations become 🔒 Mac-host
   + a pointer to this ADR.
6. `.dev/orbstack_setup.md`: deprecation header added at the
   top; body retained as historical reference + dev convenience.
7. `ARCHITECTURE.md`: cross-arch test row text amended.
8. New `D-120` debt row: "CI Linux gate activation" — blocker =
   first GitHub Actions push enabling `ubuntu-latest` workflow.

## References

- ROADMAP §A1.12 (per-commit gate definition — amended).
- CLAUDE.md § Working agreement / § Build & test (amended).
- `.dev/ubuntunote_setup.md` (cw setup notes).
- `~/Documents/MyProducts/zwasm_from_scratch/.dev/ubuntunote_setup.md`
  (shared host's full bring-up).
- `~/Documents/MyProducts/zwasm_from_scratch/scripts/run_remote_ubuntu.sh`
  (reference shape for the wrapper).
- 2026-05-28 cross-session incident report (user chat): cw
  Claude session orphan-leaked a REPL pipeline with grep
  CPU-spinning ~1h50m; sibling zwasm session reaped it +
  introduced `~/.claude/hooks/cleanup_orphans.sh` globally.
- ADR-0003 (zlinter on Mac only — explains the +1 PASS-count
  diff between Mac and ubuntunote gates).

## Revision history

- 2026-05-28: Status: Proposed → Accepted (initial landing with
  same-day verification — `ssh ubuntunote` + clone + `nix
  develop` + full gate 84/84 PASS at HEAD `a9045b10` confirmed
  before this ADR text was finalised).
