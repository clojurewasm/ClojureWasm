# OrbStack x86_64 development gate

ROADMAP §11.5 (Cross-platform gate) requires `bash test/run_all.sh`
to pass on Linux x86_64 at every phase boundary marked 🔒. NaN
boxing, HAMT, GC, VM dispatch, and packed-struct alignment are all
arch-sensitive — Apple Silicon-only verification is not enough.

This file documents the **operational** side: how to set the VM up
once, how to iterate against it during development, and how the gate
is wired into the project's quality timeline.

## 1. One-time setup (Apple Silicon Mac)

```sh
brew install orbstack                          # if not present
orb create -a amd64 ubuntu my-ubuntu-amd64     # x86_64 VM via Rosetta
```

`orb create` lands in a few minutes. After that the VM exists
permanently across reboots; you do not re-create it.

Install Zig 0.16.0 inside the VM (the Mac-side Nix `zig` is
`aarch64-darwin` and cannot run inside the Linux x86_64 sandbox):

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
project tree at `/Users/<you>/Documents/.../ClojureWasmFromScratch/`
is visible from inside the VM at the **same path** without any
`-v` / sync configuration.

## 2. Iteration loop (verify on Linux during development)

The 🔒 gate is the *required* verification point, but you can run
the full test suite on the VM at any time as a quick sanity check
when touching arch-sensitive code (NaN boxing, alignment, packed
structs, etc.):

```sh
# Full run from the project root (cwd inherits to the VM via path mirror)
orb run -m my-ubuntu-amd64 bash -c 'bash test/run_all.sh'
```

For tighter loops:

```sh
# Just the Zig unit tests
orb run -m my-ubuntu-amd64 bash -c 'zig build test'

# A single test file (faster feedback)
orb run -m my-ubuntu-amd64 bash -c 'zig test src/runtime/value.zig'

# Build the binary on Linux and run a CLI smoke
orb run -m my-ubuntu-amd64 bash -c 'zig build && zig-out/bin/cljw -e "(+ 1 2)"'
```

Notes:

- `zig-cache/` and `zig-out/` are inside the mirrored project dir,
  so Mac-side and VM-side builds share neither cache nor output —
  good (incompatible binaries) and bad (re-compiles from scratch
  per side).  Avoid mixing: either work the loop on Mac or on
  Linux for a given session.
- The VM has no network restriction; Zig fetches packages from the
  shared `~/.cache/zig` mirror automatically.

## 3. Gate integration

### 3.1 When the gate is required

ROADMAP §11.5 / §9 phase table: phases marked 🔒 (currently 1, 4,
5, 8, 14, 15) require a fresh Linux x86_64 run at the **boundary
into** that phase. The agent's `continue` skill phase-boundary
review chain runs the gate as part of the audit step.

### 3.2 Who runs it

Both the human developer and the Claude Code agent can run it. The
agent invokes it through the Bash tool with a generous timeout
(≥ 600s for cold builds):

```sh
orb run -m my-ubuntu-amd64 bash -c 'bash test/run_all.sh'
```

If `orb list` shows the VM in `stopped` state, OrbStack auto-starts
it on the first `orb run`. If the VM does not exist (fresh machine
without §1 setup), the command fails with `error: machine not
found` — surface that to the user; do not attempt to create the
VM autonomously (uses Mac admin context).

### 3.3 Recording the result

After a green run at a 🔒 boundary, record one line in
`.dev/handover.md`:

```
🔒 OrbStack x86_64 gate — PASSED YYYY-MM-DD (Phase N → Phase N+1).
```

A red run blocks the phase open; do not flip the §9 phase tracker
until the gate is green.

### 3.4 What the gate does **not** check

- Wasm runtime behaviour (Phase 14+ adds a `wasmtime` gate).
- Performance regressions (`bench/` harness, ROADMAP §10).
- Long-running stability (no soak yet).
- Other arches (aarch64-linux, riscv64) — single x86_64 representative
  is the project's current floor.

## References

- ROADMAP §11.5 — gate policy (single source of truth).
- ROADMAP §11.6 — full gate timeline by phase.
- `.claude/skills/continue/SKILL.md` — phase-boundary review chain
  that calls into this gate.
- `test/run_all.sh` — the script being gated.
