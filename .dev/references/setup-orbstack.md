# OrbStack Ubuntu x86_64 VM Setup

One-time setup for local Ubuntu x86_64 testing via OrbStack on Apple Silicon.
This VM is shared with zwasm — if already created, skip to verification.

## VM Creation

```bash
orb create --arch amd64 ubuntu my-ubuntu-amd64
```

## Tool Installation

See `zwasm/.dev/references/setup-orbstack.md` for full installation commands.
The same VM and tools are used for both projects:

| Tool       | Version  | Path                     |
| ---------- | -------- | ------------------------ |
| Zig        | 0.16.0   | /opt/zig/zig             |
| wasmtime   | 42.0.1   | ~/.wasmtime/bin/wasmtime |
| wasm-tools | 1.245.1  | /usr/local/bin/wasm-tools|
| WASI SDK   | 25       | /opt/wasi-sdk            |
| Rust       | stable   | ~/.cargo/bin/rustc       |
| hyperfine  | system   | /usr/bin/hyperfine       |

## Verification

```bash
orb run -m my-ubuntu-amd64 bash -lc "zig version && wasmtime --version"
# Expected: 0.16.0, wasmtime-cli 42.0.1
```

## Notes

- VM name: `my-ubuntu-amd64` (shared between zwasm and ClojureWasm)
- Mac filesystem accessible inside VM at original paths (e.g., `/Users/shota.508/...`)
  but building directly from Mac FS is slow — rsync to VM-local storage instead
- OrbStack uses Rosetta for x86_64 emulation on Apple Silicon
