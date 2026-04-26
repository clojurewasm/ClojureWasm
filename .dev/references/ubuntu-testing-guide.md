# Ubuntu x86_64 Testing Guide (OrbStack)

How to run ClojureWasm tests on the local OrbStack Ubuntu x86_64 VM.

## Connection

```bash
# Interactive shell
orb shell my-ubuntu-amd64

# One-shot command (used by Claude Code)
orb run -m my-ubuntu-amd64 bash -lc "COMMAND"
```

Claude Code uses stateless one-shot execution — each `orb run` starts a fresh shell.
Always use `bash -lc` to load `.bashrc` (PATH for zig, wasmtime, etc.).

## Sync Project

Rsync from Mac filesystem to VM-local storage for build performance:

```bash
orb run -m my-ubuntu-amd64 bash -lc "
  rsync -a --delete \
    --exclude='.zig-cache' --exclude='zig-out' \
    '/Users/shota.508/ClojureWasm/' ~/ClojureWasm/
"
```

Run sync before each test session to pick up latest changes.

## Test Commands

All commands run inside the VM at `~/ClojureWasm/`:

```bash
# Unit tests (IMPORTANT: --seed 0 required on Rosetta)
orb run -m my-ubuntu-amd64 bash -lc "cd ~/ClojureWasm && zig build test --seed 0"

# Full test suite
orb run -m my-ubuntu-amd64 bash -lc "cd ~/ClojureWasm && zig build test --seed 0 && \
  zig build -Doptimize=ReleaseSafe && \
  ./zig-out/bin/cljw test"

# E2E tests
orb run -m my-ubuntu-amd64 bash -lc "cd ~/ClojureWasm && bash test/e2e/run_e2e.sh"

# Benchmarks
orb run -m my-ubuntu-amd64 bash -lc "cd ~/ClojureWasm && bash bench/run_bench.sh --quick"
```

## Critical: --seed 0 Workaround

**`zig build test` crashes without `--seed 0` on Rosetta x86_64 emulation.**

Root cause: Zig's build runner's `shuffleWithIndex` produces an index out of bounds
under Rosetta's Random implementation. Originally seen on Zig 0.15.2; needs
re-verification on Zig 0.16.0 — line numbers in std/Random.zig may have shifted.
The `--seed 0` flag disables test shuffling, avoiding the crash entirely.

This is 100% reproducible without the flag and 100% fixed with it.

## Known Platform Differences

3 float-format tests fail on x86_64 due to platform-specific formatting differences
(e.g., `-0.0` vs `0.0`, exponential notation). These are cosmetic, not bugs:

- `test.core-print: print double -0.0`
- `test.core-print: print MIN_VALUE`
- `test.core-print: print MAX_VALUE`

These are tracked and accepted — not regressions.

## Expected Results

| Suite      | Expectation                          |
| ---------- | ------------------------------------ |
| Unit tests | 1338+ pass (3 known float failures)  |
| cljw test  | 83 namespaces, no crashes            |
| E2E        | all pass                             |
| Benchmarks | no regression vs Mac baseline        |
