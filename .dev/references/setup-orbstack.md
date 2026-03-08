# OrbStack Ubuntu x86_64 VM Setup

One-time setup for local Ubuntu x86_64 testing via OrbStack on Apple Silicon.
Referenced from roadmap.md 🔒 x86_64 Gate tasks.

## VM Creation

```bash
orb create --arch amd64 ubuntu my-ubuntu-amd64
```

Note: VM name `my-ubuntu-amd64` is shared with zwasm project.

## Tool Installation

Run inside the VM (`orb run -m my-ubuntu-amd64 bash -lc "..."`):

```bash
# System packages
sudo apt update && sudo apt install -y build-essential xz-utils curl git

# Zig 0.15.2
curl -L -o /tmp/zig.tar.xz https://ziglang.org/builds/zig-x86_64-linux-0.15.2.tar.xz
sudo mkdir -p /opt/zig && sudo tar -xf /tmp/zig.tar.xz -C /opt/zig --strip-components=1
echo 'export PATH="/opt/zig:$PATH"' >> ~/.bashrc
```

## Running Tests

```bash
# Option 1: Direct (uses Mac filesystem — slower)
orb run -m my-ubuntu-amd64 bash -lc "cd /Users/shota.508/Documents/MyProducts/ClojureWasm-new && zig build test"

# Option 2: rsync to VM-local storage (faster for large builds)
orb run -m my-ubuntu-amd64 bash -lc "
  rsync -a --delete /Users/shota.508/Documents/MyProducts/ClojureWasm-new/ ~/ClojureWasm-new/ --exclude .zig-cache --exclude zig-out
  cd ~/ClojureWasm-new && zig build test
"
```

## Notes

- OrbStack uses Rosetta for x86_64 emulation on Apple Silicon
- Mac filesystem is accessible at original paths inside the VM
- Building from Mac FS is slow — rsync to VM-local storage for faster builds
- Zig cross-compilation (`-Dtarget=x86_64-linux`) is NOT a substitute for running tests on actual x86_64
