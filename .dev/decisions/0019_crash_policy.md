# 0019 — Crash policy: panic, internal error, and native crash

- **Status**: Accepted
- **Date**: 2026-05-23
- **Author**: Shota Kudo (drafted with Claude)
- **Tags**: phase-4-entry, error, crash, panic, internal-error, robustness

## Context

ADR-0018 specifies how user-input-driven errors are produced (catalog
`raise`). It does not cover what happens when:

- A cw runtime invariant is violated (a path the developer thought
  unreachable is reached).
- Zig itself traps at runtime (integer overflow in safe builds,
  index out of bounds, null pointer dereference, `unreachable`).
- The process receives a fatal signal (SIGSEGV, SIGBUS).

Without a policy, three failure modes appear and have appeared in
cw v0:

1. **`@panic("...")` sprinkled everywhere**. Some panics gate
   user-input paths (incorrect — they should be catalog raises);
   some gate genuine internal invariants (correct, but the message
   carries no `Code` and no `SourceLocation`).
2. **Silent `unreachable`**. A "this can never happen" assertion that
   later turns out to happen, leaving the user staring at a Zig
   trap with no context.
3. **`@panic` for "not yet implemented"**. Mixed with the catalog
   `feature_not_supported` Code, creating two parallel "not done"
   surfaces.

This ADR draws the line between the three layers and specifies the
top-level catch behaviour.

## Decision

cw v1 distinguishes three crash layers and applies a fixed policy to
each.

### Layer 1: User-input error (catalog, ADR-0018)

Any code path reachable by user input — parsing, analysis, macro
expansion, evaluation of user-supplied forms, primitive function
arguments, `cljw -e` input, file input, REPL input, nREPL input,
stdin input — raises through the catalog
(`error_catalog.raise(.code, loc, args)`). `@panic` is **forbidden**
in these paths.

If a path is "obviously" reachable only via user input but the
developer is unsure, default to catalog raise. Adding a catalog
`Code` is cheap.

### Layer 2: Runtime invariant violation

A "runtime invariant violation" is a state the developer believed
the cw runtime itself would never reach (e.g. "the dispatch vtable
field is non-null because installVTable runs in `main`"). Two
sub-cases:

- **The invariant is genuinely guaranteed by construction**
  (function only callable from one site that proves the
  precondition): use `std.debug.assert(...)` or
  `if (cond) unreachable;`. These cost nothing in release mode
  and trap in safe builds. Document the precondition in a `//`
  comment above the assertion.
- **The invariant is "should hold" but the developer cannot
  statically prove it**: raise the catalog `internal_error` Code
  with a `{detail}` slot describing the violation. The user sees
  a `[internal_error]` category and a hint to file a bug. The
  developer sees a `Code` in the failing test output and the
  source location.

`@panic("...")` with a bare string is **discouraged**. Replace with
either `std.debug.assert` (with a comment) or catalog
`internal_error` raise. Existing `@panic` call sites are audited
during task 4.26; each is converted to one of the two forms above
or annotated with a `// @panic: <reason>` comment justifying why it
must remain.

### Layer 3: Native crash

Some failure modes are below the Zig error mechanism:

- Integer overflow in release-fast builds (silent wrap; not a crash,
  but worse).
- Stack overflow with no recoverable trap.
- SIGSEGV / SIGBUS from a genuine memory bug.

Policy:

- **Build mode**: cw v1 default release mode is `ReleaseSafe`
  (overflow traps, OOB traps). `ReleaseFast` builds are produced only
  for benchmark / distribution and carry a clear opt-in flag.
- **Top-level catch in `main`**: the `pub fn main(init: std.process.Init)`
  body wraps the dispatch in a `catch |err|` that, when the error
  set includes `ClojureWasmError`, formats the catalog error and
  exits with a per-`Kind` exit code. Any other error (Zig native
  trap that surfaces as a `error.OutOfMemory` etc.) is rendered as
  an `[internal_error]` with the Zig error name as the `{detail}`.
- **Native signal handler** (Phase 14+, when REPL / nREPL is wired):
  install a SIGSEGV / SIGBUS handler that prints
  `"Internal error: ClojureWasm crashed unexpectedly."` to stderr
  with the cw build commit SHA and exits 70. Phase 4-13 ships
  without this handler; a SIGSEGV simply terminates the process
  (acceptable for non-interactive Phase 4 usage).

### Exit codes

| Exit code | Meaning                                                          |
|-----------|------------------------------------------------------------------|
| 0         | Success                                                          |
| 1         | User-facing catalog error (any `ClojureWasmError` variant)       |
| 70        | Internal error (cw bug; `internal_error` Code or signal handler) |
| 130       | SIGINT (Phase 14+ REPL)                                          |

The split between 1 and 70 lets `cljw -e ...` integrate into shell
pipelines that distinguish "the user's code was wrong" from "cw
itself broke".

## Alternatives considered

### Alternative A — `@panic` everywhere

- **Sketch**: any unexpected state panics with a string message.
- **Why rejected**: panics carry no `Code`, no `SourceLocation`, no
  `Kind`. Output is `thread N panic: ...` with no integration with
  the catalog or the user-facing format. User experience is bad
  for both end users and cw developers.

### Alternative B — All crashes are user-facing errors

- **Sketch**: catch every Zig trap and present it as a catalog
  error.
- **Why rejected**: some traps (memory corruption) leave the runtime
  in an unsafe state; continuing to execute is dangerous. The
  signal-handler path (Phase 14+) prints a brief message and
  exits, which is correct.

### Alternative C — Build-time elimination of `unreachable`

- **Sketch**: forbid `unreachable` and require all dispatch
  exhaustiveness checks to return `internal_error`.
- **Why rejected**: `unreachable` against a comptime-exhaustive
  enum switch is a Zig idiom (the compiler proves it cannot fire).
  Forbidding it loses static dispatch checking. The discipline is
  to use `unreachable` only when the compiler can prove the path
  unreachable; runtime "I think this won't happen" uses
  `internal_error`.

## Consequences

- **Positive**: every user-visible failure is one of two categories
  (catalog error or internal error), and the user can tell from the
  category label. cw developers can grep `@panic` and find a
  small justified set, not a sprawl. Exit codes carry meaning for
  shell integration.
- **Negative**: existing `@panic` and `unreachable` sites need an
  audit during task 4.26. Roughly 20-40 sites estimated from
  `grep -rn "@panic\|unreachable" src/`; each gets converted or
  annotated.
- **Neutral / follow-ups**:
  - `internal_error` Code template (`"Internal error: {detail}"`)
    is enough for now. When a public issue tracker URL is settled,
    a follow-up amends the template to include a "please report"
    suffix.
  - Phase 14+ signal handler is a separate task; this ADR records
    the intent only.
  - Stack overflow is platform-specific (the OS may not deliver a
    catchable signal). cw v1 sizes thread stacks at 16MB
    (per `JVM_TO_ZIG.md` §14 reasoning) which covers the deep
    recursion patterns observed in cw v0.

## References

- ADR-0018 (Error catalog SSOT — Layer 1 lives there)
- ADR-0009, ADR-0017 (`internal_error` raise sites referenced by
  lock and allocator implementations)
- ROADMAP §2 P6 (Error quality is non-negotiable)
- ROADMAP §9.6 task 4.26 (audit `@panic` and `unreachable` along
  with the `setErrorFmt` migration)

## Revision history

- 2026-05-23: Status: Proposed -> Accepted (initial landing).
