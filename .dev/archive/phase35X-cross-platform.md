# Phase 35X: Cross-Platform Build & Verification

## Context

Phase 35.5 complete. ClojureWasm is macOS aarch64-only. Phase 35X enables Linux
support and lays CI foundation. Pre-alpha stage — users clone and build locally.

**Key findings (updated after Phase 35W):**
- zware fully removed in Phase 35W (D84). `.always_tail` blocker eliminated.
  Custom Wasm runtime uses switch-based dispatch — cross-compile friendly.
- `zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe` should now work
  without LLVM backend issues. Needs verification.
- Binary trailer (CLJW magic) is platform-generic — works on ELF/Mach-O.
- Docker (OrbStack) available on host for Linux verification.
- WASI uses `std.posix` APIs — should work on Linux without changes.

**Obsolete (from original plan):**
- ~~35.1: Make zware optional~~ — zware fully removed in Phase 35W.
  No stub types needed, no conditional imports.

## Scope

**In scope:**
1. Linux x86_64 cross-compile + Docker verification
2. Linux aarch64 cross-compile + Docker verification (QEMU)
3. macOS x86_64 cross-compile + Rosetta verification
4. `cljw build` output verification on Linux (binary trailer on ELF)
5. LICENSE file (EPL-1.0)
6. GitHub Actions CI (build + test matrix)

**Explicitly out of scope:**
- Windows (all of it — compilation, runtime, REPL, signals)
- Release binary distribution / packaging
- macOS code signing / notarization

## Tasks

### 35X.1: Linux x86_64 cross-compile + Docker verification

Steps:
1. Cross-compile: `zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe`
2. Fix any compile errors (should be minimal — zware removed)
3. Verify in Docker (debian:bookworm-slim):

```
cljw -e '(+ 1 2)'                                    # basic eval
cljw -e '(println (System/getProperty "os.name"))'   # platform detection
cljw file.clj                                         # file execution
cljw build app.clj -o app && ./app                    # single binary
```

4. HTTP server + curl test inside Docker
5. E2E Wasm tests: verify `(wasm/load ...)` works on Linux
6. Fix any issues found

### 35X.2: Linux aarch64 cross-compile + Docker verification

Cross-compile: `zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe`
Verify via Docker with `--platform linux/arm64` (OrbStack supports QEMU).
Basic eval + file execution.

### 35X.3: macOS x86_64 cross-compile + Rosetta verification

Cross-compile: `zig build -Dtarget=x86_64-macos -Doptimize=ReleaseSafe`
Verify via Rosetta 2 (should just work on Apple Silicon).
Basic eval + file execution.

### 35X.4: LICENSE file

Add `LICENSE` file with EPL-1.0 full text (matching Clojure upstream).

### 35X.5: GitHub Actions CI

**Cost:** Free for public repos. Private repos: 2,000 min/month free.
No API keys needed — just commit `.github/workflows/ci.yml`.

Workflow: `.github/workflows/ci.yml`
- Trigger: push to main, pull request
- Jobs:
  - `test-macos` (macOS aarch64): `zig build test` (native)
  - `test-linux` (ubuntu-latest): install zig, `zig build test`
  - `cross-compile`: build for x86_64-linux, aarch64-linux, x86_64-macos
  - `e2e`: run `bash test/e2e/run_e2e.sh` on native
- Zig installation: use `mlugg/setup-zig@v2` action (Zig 0.15.2)

## Verification

1. `zig build test` passes (no regression)
2. Linux x86_64 binary runs in Docker (eval, file, build, http, wasm)
3. Linux aarch64 binary runs in Docker (basic eval)
4. macOS x86_64 binary runs via Rosetta (basic eval)
5. `cljw build` output runs on Linux (trailer format works on ELF)
6. CI workflow passes on push

## File Change Summary

| File                       | Change                                |
|----------------------------|---------------------------------------|
| `LICENSE`                  | EPL-1.0 text (new)                    |
| `.github/workflows/ci.yml` | CI workflow (new)                     |
| Platform-specific fixes    | TBD — discovered during cross-compile |

## References

| Item                      | Location                                          |
|---------------------------|---------------------------------------------------|
| Checklist entry           | `.dev/checklist.md` F117                          |
| Roadmap section           | `.dev/roadmap.md` Phase 35X                       |
| Phase 35W (zware removed) | `.dev/archive/phase35-custom-wasm.md`             |
| Decision D84              | `.dev/decisions.md`                               |
| Original plan (obsolete)  | `~/.claude/plans/phase35-cross-platform-saved.md` |
