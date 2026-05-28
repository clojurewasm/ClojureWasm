# Ubuntu SSH (`ubuntunote`) Setup

> **Doc-state**: ACTIVE — load-bearing reference (ADR-0049 +
> Phase 14+ scope).

cw v1's Linux x86_64 verification host. **Native x86_64
hardware** replaces the OrbStack `my-ubuntu-amd64` Rosetta-
translated path retired per ADR-0049 (2026-05-28). Mirrors
zwasm v2's identical setup (`~/Documents/MyProducts/zwasm_from_scratch/.dev/ubuntunote_setup.md`)
so the same Linux host serves both projects' gates.

## Why a real x86_64 box

- **OrbStack/Rosetta orphan hazard** — `orb run -m my-ubuntu-amd64`
  child processes inherit `PID 1` when the parent Claude session
  dies; downstream pipeline parts (especially `grep` on a hung
  REPL stdin) spin at 100 % CPU until reaped. Native SSH leaves a
  remote process whose death is bound to the ssh-session
  lifetime via SIGHUP.
- **JIT signal fidelity (zwasm-side, but the host is shared)** —
  Rosetta-translated x86_64 SIGSEGV delivery is non-deterministic
  on long-running JIT workloads (D-134 in zwasm). cw v1 doesn't
  JIT yet but uses the same host.
- **Identical toolchain via Nix flake** — both cw and zwasm
  pin Zig 0.16.0 via `flake.nix`; running on real x86_64 hardware
  removes Rosetta dynamic translation from the test path.

OrbStack is retained as a dev convenience host (see
`.dev/orbstack_setup.md`); it is no longer in the per-commit
gate.

## Mac-side prerequisites

`~/.ssh/config` block:

```
Host ubuntunote
    HostName ubuntunote.local
    User shota
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
    TCPKeepAlive yes
```

Verification:

```bash
ssh ubuntunote 'echo ok && nix --version'
```

Expected: `ok` + `nix (Determinate Nix ...) ...`.

## Ubuntu-side setup (one-time)

The full bring-up procedure (hostname, mDNS, apt baseline, Nix
install) lives in
[`zwasm_from_scratch/.dev/ubuntunote_setup.md`](../../zwasm_from_scratch/.dev/ubuntunote_setup.md)
§§ 1-3 (Ubuntu hostname + mDNS + apt + Determinate Nix). cw v1
inherits that host unchanged; only the **clone step** differs.

### cw repository clone

```bash
ssh ubuntunote
cd ~/Documents/MyProducts
git clone -b cw-from-scratch https://github.com/clojurewasm/ClojureWasm.git ClojureWasmFromScratch
cd ClojureWasmFromScratch
nix develop --command zig version   # should print 0.16.0
```

**HTTPS clone is intentional** — cw's GitHub remote is public-
read; ubuntunote performs read-only `git fetch + reset --hard`,
never `git push`. Mirrors zwasm's pattern (their ubuntunote
clone is also https://).

The first `nix develop` fetches Zig 0.16.0 from the flake's
pinned inputs (~15 s with cached store entries from the zwasm
bring-up; ~5 min cold).

### Gate smoke from Mac

```bash
bash scripts/run_remote_ubuntu.sh                          # full gate on cw-from-scratch
bash scripts/run_remote_ubuntu.sh --branch develop/foo     # feature-branch verification
```

Expected end-of-output:

```
[run_remote_ubuntu] OK (HEAD=<sha>).
```

The wrapper performs `git fetch + reset --hard` to ensure the
remote tree exactly matches the locally-pushed HEAD, then runs
`nix develop --command bash test/run_all.sh`. Failure messages
are labelled `[run_remote_ubuntu] FAIL: <step>` so log scans
localise the breaking phase.

## Gate integration (per ADR-0049)

cw's per-commit gate is **Mac host only** as of 2026-05-28:

- **Mac aarch64**: `bash test/run_all.sh` (foreground, every
  commit).
- **Ubuntu x86_64 (ubuntunote)**: `bash scripts/run_remote_ubuntu.sh`
  (manual / Phase-boundary review / before v0.1.0 tag). Not in
  the per-commit critical path.
- **Future CI**: GitHub Actions `ubuntu-latest` runs the same
  gate on every push (D-120, opportunistic).

## Lifecycle / sleep behavior

`ubuntunote` ideally stays up 24/7 for cross-project gate
availability. Sleep / Wake-on-LAN handling is documented in
`zwasm_from_scratch/.dev/ubuntunote_setup.md` § Lifecycle (same
host, same procedure).

## Apt vs Nix decision

See `zwasm_from_scratch/.dev/ubuntunote_setup.md` § "What apt vs
Nix decision look like" for the full table. cw inherits the
same split: apt for pre-Nix bootstrap + SSH + mDNS; Nix flake
for Zig + zlinter + project-pinned dev tools.

## Decommissioning OrbStack (post ubuntunote bring-up)

Per ADR-0049:

- `.dev/orbstack_setup.md` — deprecated header added; body
  retained for historical reference + dev convenience use.
- `test/run_all.sh` top-of-file comment — updated to say
  "Linux gate via `bash scripts/run_remote_ubuntu.sh`, no longer
  per-commit".
- `CLAUDE.md` / `ROADMAP.md` / `ARCHITECTURE.md` — Linux gate
  wording amended to point here.

## References

- ADR-0049 (this retirement).
- `scripts/run_remote_ubuntu.sh` (the wrapper).
- `~/Documents/MyProducts/zwasm_from_scratch/.dev/ubuntunote_setup.md`
  (full Ubuntu bring-up procedure; cw inherits sections 1-3).
- `.dev/orbstack_setup.md` (deprecated dev-convenience host).
- D-120 (CI Linux gate activation; opportunistic).
