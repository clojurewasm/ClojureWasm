# 0015 — `io_interface.zig` as a Zone 0 vtable abstraction

- **Status**: Accepted
- **Date**: 2026-05-23
- **Author**: Shota Kudo (drafted with Claude)
- **Tags**: phase-4-entry, io, zone-0, vtable, std-io-drift

## Context

cw v0 disabled five features (F140-F144: HTTP server, HTTP client,
nREPL, line editor, `cljw build` self-bundle) when the Zig 0.15→0.16
migration reshaped `std.Io`. Recovery is open-ended because every
recovered feature must follow the moving `std.Io` shape. The same
class of regression will recur with Zig 0.17 / 0.18 unless the
runtime insulates itself.

## Decision

cw v1 introduces `src/runtime/io_interface.zig` at Zone 0 (the
lowest zone — no upward imports). It exposes a vtable-style abstraction
for `Reader`, `Writer`, `Net`, and `Process` so that the rest of the
runtime depends on the abstraction, not on `std.Io` directly.

```zig
// src/runtime/io_interface.zig
pub const Writer = struct {
    vtable: *const VTable,
    ctx: *anyopaque,
    pub const VTable = struct {
        write_all: *const fn (*anyopaque, []const u8) anyerror!void,
        flush:     *const fn (*anyopaque) anyerror!void,
        close:     *const fn (*anyopaque) anyerror!void,
    };
};

pub const Reader = struct { ... };
pub const Net    = struct { ... };
pub const Process = struct { ... };
```

A concrete `runtime/io_default.zig` (Zone 1) wires the abstraction
to whatever `std.Io` ships in the current Zig version. When `std.Io`
changes, only `io_default.zig` needs revision.

`main()` constructs the default and injects it into the runtime.

### Two-tier strategy (per amendment 1)

The vtable is split into **two tiers** so that consumer code never
imports `std.Io` directly:

- **Tier 1** (`runtime/io_interface.zig`, Zone 0): the vtable
  declarations only. No `std.Io` import. Public API is `Reader` /
  `Writer` / `Net` / `Process` structs that carry a `*const VTable`
  + `*anyopaque` context. Consumer code (analyzers, REPL,
  primitives) imports this file.
- **Tier 2** (`runtime/io_default.zig`, Zone 1): the actual `std.Io`
  attachment. Constructs concrete vtable instances from `std.Io.File`,
  `std.Io.Dir`, `std.Io.Writer` etc., and exposes
  `defaultReader()` / `defaultWriter()` etc. so `main()` (Zone 3)
  injects them.

When Zig stdlib reshapes `std.Io` (the F140-F144 failure mode in
cw v0), only Tier 2 changes. Tier 1 is invariant under stdlib
churn. Consumer code never recompiles for the API surface; it only
recompiles if its own logic changed.

### File layout

```
src/runtime/
  io_interface.zig    ← Tier 1, Zone 0, no `std.Io` import
  io_default.zig      ← Tier 2, Zone 1, the only file that
                        imports `std.Io` directly for I/O ops
                        (other zones get I/O via injection)
```

Each `Tier 1` struct has a doc-comment declaring its semantic
contract (what the caller expects: blocking semantics, ownership,
error set). The `Tier 2` implementation must honour that contract;
re-implementing for a future Zig version is a Tier-2-only change.

## Alternatives considered

### Alternative A — Use `std.Io` directly throughout

- **Sketch**: the cw v0 path.
- **Why rejected**: F140-F144 cautionary precedent.

### Alternative B — Per-feature abstraction (HTTP wrapper, line editor wrapper, etc.)

- **Sketch**: each feature carries its own abstraction.
- **Why rejected**: duplication. A central vtable in Zone 0 covers
  every consumer.

## Consequences

- **Positive**: a Zig stdlib reshape affects one file. The five
  disabled v0 features can be re-implemented above this abstraction.
- **Negative**: an indirection cost per I/O call (function pointer).
  Negligible vs. system call costs.
- **Neutral / follow-ups**: clojure.java.io's `(reader x)` /
  `(writer x)` / `(input-stream x)` / `(output-stream x)` are
  implemented in `cljw.host.java.io` against the abstraction.

## Phase 14+ migration note (amendment 2)

The Phase 4 entry (task 4.13) lands `runtime/io_interface.zig` (Tier
1, Zone 0) + `runtime/io_default.zig` (Tier 2, Zone 1) skeleton plus
`defaultReader()` / `defaultWriter()` injection in `main()`. cw v0's
five disabled features (F140-F144) are **not** re-introduced at
Phase 4; they re-land at Phase 14 alongside REPL / nREPL.

Phase 14 entry activates each F-feature as a new file under the
appropriate zone, **and** rewrites a small number of Phase 4-13
src/ sites where today the dispatch row is a `feature_not_supported`
catalog raise:

| F    | Phase 14 landing path                                                           | Phase 4-13 placeholder rewritten                                 |
|------|---------------------------------------------------------------------------------|------------------------------------------------------------------|
| F140 | `src/host/io/http_server.zig` (new)                                             | `cljw.host.java.net` namespace dispatch row                      |
| F141 | `src/host/io/http_client.zig` (new)                                             | `cljw.host.java.net` namespace dispatch row                      |
| F142 | `src/app/nrepl.zig` (new; bencode under `src/runtime/bencode/` per amendment 3) | `src/app/main.zig` subcommand dispatch row for `nrepl`           |
| F143 | `src/app/repl/line_editor.zig` (new)                                            | `src/app/main.zig` subcommand dispatch row for `repl`            |
| F144 | `src/app/build/self_bundle.zig` (new)                                           | `src/app/main.zig` subcommand dispatch row for `component build` |

Tier 2 isolation (per amendment 1) means that if Zig 0.17 / 0.18
reshapes `std.Io` again before Phase 14, only `io_default.zig` is
rewritten — the F140-F144 landing files import from
`io_interface.zig` only.

The rewrite is expected per ROADMAP §A25; principle.md depth 2 for
each subcommand dispatch row swap, depth 3 if a `std.Io` reshape
coincides with the Phase 14 landing.

## References

- ROADMAP §9.6 task 4.13 (io_interface.zig Zone 0)
- ROADMAP §9.16 (Phase 14 entry — v0.1.0 milestone with REPL /
  nREPL re-introduction)
- ROADMAP §A1 (Zone discipline)
- ROADMAP §A25 (Existing code is mutable)
- cw v0 disabled features F140-F144

## Revision history

- 2026-05-23: Status: Proposed -> Accepted (initial landing).
- 2026-05-23 (amendment 1): Added "Two-tier strategy" section
  documenting the Tier 1 (Zone 0, no `std.Io` import) and Tier 2
  (Zone 1, the only `std.Io`-importing file) split. Source:
  zwasm v1 D135 + `private/research-2026-05-23/INSIGHTS_ZWASM_V1.md`
  observation that Tier 2 isolation makes Zig stdlib reshape a
  one-file change instead of a project-wide recovery.
- 2026-05-23 (amendment 2): Added "Phase 14+ migration note"
  section to narrate F140-F144 re-introduction landing paths and
  the corresponding Phase 4-13 placeholder dispatch rewrites (per
  ROADMAP §A25).
- 2026-05-28 (amendment 3): F142 row narrowed. Devil's-advocate
  for row 14.10 (cljw nrepl landing) recommended moving the
  bencode codec out of `src/app/nrepl/` into `src/runtime/bencode/`
  per F-009 strict (namespace-neutral wire codec; matches
  `runtime/regex/`, `runtime/io/` precedent). server / session /
  ops folded into a single `src/app/nrepl.zig` (~370 LOC; under
  the 1000-LOC §A6 cap so the 3-file split is reservation-as-bias
  until growth forces it). ADR-0015 a2's specific path table was
  a memo per CLAUDE.md spirit; the finished form amends in place.
  v0 disabled-feature F142 reactivation closed at commit XXXXXX
  (row 14.10).
