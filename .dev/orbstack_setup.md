# OrbStack x86_64 setup

> **DEPRECATED for the gate (2026-05-28, ADR-0049)**: OrbStack
> `my-ubuntu-amd64` is no longer in the per-commit Linux gate.
> The cross-arch verification host is the `ubuntunote` SSH box
> (native x86_64 hardware); see
> [`.dev/ubuntunote_setup.md`](ubuntunote_setup.md) and
> [`.dev/decisions/0049_orbstack_linux_gate_retired.md`](decisions/0049_orbstack_linux_gate_retired.md).
>
> This file is retained because OrbStack remains a useful
> dev-convenience host for interactive scratch (REPL probes,
> quick cross-arch sanity checks). The body below documents the
> one-time bring-up; treat any per-commit gate language as
> historical.

The project's gate baseline (CLAUDE.md "Working agreement") used
to be `bash test/run_all.sh` green on **both** Mac (host) **and**
OrbStack Ubuntu x86_64; ADR-0049 retired the OrbStack half.
NaN boxing, HAMT, GC, VM dispatch, and packed-struct alignment
are still arch-sensitive — the cross-arch validation moved to
`ubuntunote` (manual / Phase boundary) + future GitHub Actions
CI (D-120).

## One-time setup (Apple Silicon Mac)

```sh
brew install orbstack                          # if not present
orb create -a amd64 ubuntu my-ubuntu-amd64     # x86_64 VM via Rosetta
```

`orb create` lands in a few minutes. After that the VM persists
across reboots; you do not re-create it.

Install Zig 0.16.0 inside the VM (the Mac-side Nix `zig` is
`aarch64-darwin` and cannot run inside a Linux x86_64 sandbox):

```sh
orb run -m my-ubuntu-amd64 bash -c '
  cd /tmp &&
  curl -fsSL https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz \
    -o zig.tar.xz &&
  sudo tar -xJf zig.tar.xz -C /opt &&
  sudo mv /opt/zig-x86_64-linux-0.16.0 /opt/zig
'
echo 'export PATH=/opt/zig:$PATH' | \
  orb run -m my-ubuntu-amd64 sudo tee -a /etc/profile
```

Verify:

```sh
orb run -m my-ubuntu-amd64 bash -c 'zig version'   # → 0.16.0
```

OrbStack mirrors `/Users/<you>` into the VM transparently, so the
project tree at `/Users/<you>/.../ClojureWasm/` is
visible from inside the VM at the **same path** with no `-v` /
sync configuration.

If `orb list` later shows the VM in `stopped` state, OrbStack
auto-starts it on the first `orb run`. If the VM does not exist
on a fresh machine, the command fails with `error: machine not
found`; re-run the steps above.

## Multi-host pivot strategy

Currently: Mac host + OrbStack Ubuntu x86_64.

- Phase 4-5: status quo (OrbStack as gate).
- Phase 6+ (re-evaluate): OrbStack as scratch host, remote
  Linux x86_64 SSH host as gate. Rationale: long-running JIT
  cycles (Phase 17+ if go) encounter Rosetta translation races
  on OrbStack; native SSH host eliminates this class of flake.
- Phase 13+: Windows track is separate (per ROADMAP §3 scope).
