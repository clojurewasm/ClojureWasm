# OrbStack x86_64 setup

The project's testing baseline (CLAUDE.md "Working agreement") is
`bash test/run_all.sh` green on **both** Mac (host) **and** OrbStack
Ubuntu x86_64. NaN boxing, HAMT, GC, VM dispatch, and packed-struct
alignment are arch-sensitive — Apple-Silicon-only verification is
not enough.

This file documents the one-time VM setup. Day-to-day invocation
lives in `test/run_all.sh`'s header and the `continue` skill's
Step 5 (Test gate).

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
project tree at `/Users/<you>/.../ClojureWasmFromScratch/` is
visible from inside the VM at the **same path** with no `-v` /
sync configuration.

If `orb list` later shows the VM in `stopped` state, OrbStack
auto-starts it on the first `orb run`. If the VM does not exist
on a fresh machine, the command fails with `error: machine not
found`; re-run the steps above.
