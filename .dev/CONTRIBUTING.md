# Contributing to ClojureWasm

Thank you for your interest in ClojureWasm!

## Current Status

ClojureWasm is in pre-alpha and not yet in a position to accept Issues or
Pull Requests. The codebase is still undergoing significant changes. This
document is placed here for future use.

## How to Contribute

### Issues

Bug reports and feature requests are welcome via GitHub Issues.
Please include:

- Steps to reproduce (for bugs)
- Expected vs actual behavior
- ClojureWasm version (`cljw --version`)
- Platform (e.g., macOS Apple Silicon)

### Pull Requests

**Please open an issue first** to discuss your proposed change before
submitting a PR. This avoids duplicate work and ensures alignment with
the project direction.

## Development Setup

### Prerequisites

- [Zig 0.15.2](https://ziglang.org/download/) (exact version required)
- macOS Apple Silicon (primary development platform)

### Build & Test

```bash
zig build              # Build (Debug)
zig build test         # Run all tests
./zig-out/bin/cljw -e '(+ 1 2)'              # VM backend (default)
./zig-out/bin/cljw --tree-walk -e '(+ 1 2)'  # TreeWalk backend
./zig-out/bin/cljw path/to/file.clj           # File execution
```

### Code Style

- All code in English: identifiers, comments, docstrings, commit messages
- One logical change per commit
- Follow existing patterns in the codebase
- Both VM and TreeWalk backends must be verified for any execution changes

### Upstream Test Files

Files in `test/upstream/` are ported from upstream Clojure and SCI.
When modifying these files:

- Preserve upstream copyright notices
- Mark all changes with `;; CLJW: <reason>` markers
- Do not reduce assertion counts or change expected values

## License

By contributing, you agree that your contributions will be licensed under
the [Eclipse Public License 1.0](LICENSE).
