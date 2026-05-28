# ADR-0048 — State machine domain ADR for REPL / nREPL / build pipeline

- **Status**: Proposed → Accepted (issued inline at row 14.9, 2026-05-28)
- **Affected**: `src/app/repl.zig` (REPL state machine, this row);
  `src/app/nrepl.zig` (future, row 14.10); `src/app/builder.zig`
  (future, row 14.11). All three are user-visible interactive
  surfaces that benefit from an explicit state chart so error /
  recovery paths are reviewable as a graph rather than a callgraph.
- **Supersedes**: none. The §9.17 placeholder's reservation
  "ADR-0028 (state machine)" was discarded per F-002 Reservation-
  as-bias smell at row 14.0; this ADR's id 0048 follows the
  time-ordered allocation rule (`max(existing) + 1` at issue time).

## Context

Three Phase-14 surfaces — `cljw repl`, `cljw nrepl`, `cljw build` —
share a common pattern: an outer loop alternating between
read-from-input / process / produce-output, with per-iteration
recovery on transient errors. cw v1's principle.md flags
"untyped loops with implicit state" as a smell; documenting each
surface's state chart as a first-class diagram prevents the
implementation from accreting reachable-but-unaccounted-for
states (e.g. "we're in the middle of a multi-line read but the
prompt drew anyway").

The three surfaces also share **error-recovery discipline**: a
per-iteration error must not propagate out of the loop. This ADR
codifies the convention so future maintainers don't accidentally
`return err` in a place that should be `catch |e| renderAndContinue(e)`.

## Decision

Each of the three surfaces is described by an explicit state chart.
The Phase-14 landing only ships the REPL chart's implementation
(row 14.9); rows 14.10 (nREPL) and 14.11 (build) ship their charts'
implementations and reference this ADR. The chart is rendered as
ASCII in the implementation module's `//!` docstring; significant
refactors edit the chart in the same commit.

### REPL chart (row 14.9 — landed)

```
     ┌──────┐  prompt  ┌──────────┐  line received  ┌────────────┐
     │ idle │ ───────▶ │ reading  │ ───────────────▶ │ evaluating │
     └──────┘          └──────────┘                  └────────────┘
         ▲                  │                              │
         │ result printed   │ EOF on stdin                 │ value | error
         │                  ▼                              ▼
     ┌──────────┐         (exit)                     ┌──────────┐
     │ printing │ ◀────────────────────────────────  │  result  │
     └──────────┘                                    └──────────┘
```

States:
- `idle` — between prompts; no I/O in flight.
- `reading` — prompt drawn, waiting on stdin line.
- `evaluating` — parsing + analysing + evaluating one form.
- `result` — value (success) or error info (failure).
- `printing` — writing result + newline to stdout / stderr.

Transitions:
- `idle → reading`: drawn by `stdout.print("{ns}=> ")`.
- `reading → evaluating`: line received.
- `reading → exit`: stdin EOF.
- `evaluating → result`: parse + analyse + eval finish (success
  OR error).
- `result → printing`: format result Value via `print.printValue`
  or render error via `error_render.renderError`.
- `printing → idle`: returns control to the prompt loop.

**Recovery discipline**: every transition into `printing` is a
no-throw path. Any `error` in `evaluating` is caught by the loop
wrapper and converted to a `result(error)` transition.

### nREPL chart (row 14.10 — landed at 2026-05-28)

```
   ┌──────────┐  client connect   ┌───────────────┐  clone op   ┌─────────────┐
   │  accept  │ ────────────────▶ │ session_init  │ ──────────▶ │op_dispatch  │
   └──────────┘                   └───────────────┘             └─────────────┘
        ▲                                                              │
        │ session_close                                                 │ each op
        │                                                               ▼
   ┌──────────┐                                                  ┌─────────────┐
   │ closing  │ ◀── close op / disconnect ────────────────────── │ response    │
   └──────────┘                                                  │   _send     │
                                                                 └─────────────┘
```

States:
- `accept` — blocking accept on TCP socket; one client at a time
  per the Phase-14 single-thread runtime.
- `session_init` — session id minted on `clone`; the connection
  state machine begins.
- `op_dispatch` — read one bencode dict, look at `op` key, route
  to the per-op handler. Currently 4 ops: `clone` / `describe` /
  `eval` / `close`.
- `response_send` — encode the response dict(s) via bencode +
  write to the stream. `eval` sends one response per top-level
  form + a final `status: ["done"]`; other ops send one response.
- `closing` — `close` op received OR client disconnected; clean
  up session state; loop back to `accept`.

Recovery discipline: any per-op error renders as a
`status: ["error" "<reason>" "done"]` response and the session
continues (unknown-op, parse error, eval error all recover). Only
TCP-level errors (client RST / system EBADF) break out of the
session loop; the accept loop then accepts the next client.

Implementation deltas vs draft chart shape:
- `interrupt` op NOT yet supported — single-thread eval cannot
  interrupt itself (Phase 15+ thread spawn unlocks this; D-117).
- `complete` / `load-file` / `info` ops NOT yet supported —
  CIDER-specific extensions filed under D-117.
- stdout/stderr capture is empty (no `*out*` / `*err*` binding
  yet; D-118).

### Build pipeline chart (row 14.11 — implementation pending)

[To be filled at row 14.11 entry.] States expected: `parse_argv`,
`load_source` (loop over files), `analyse_all`, `emit_bytecode`,
`write_trailer`, `done`. Linear with explicit per-file recovery
on `analyse_all` failure (continue parsing other files; aggregate
errors).

## Alternatives considered

Devil's-advocate fork was NOT performed: ADR-0048's "decision" is
**ADR-existence-vs-prose**, not an implementation choice. The
implementation choice (REPL line-buffered vs PTY line editor) IS
deferred to D-116 polish. Both shapes fit the chart unchanged —
the chart is the abstract contract, not the byte-level loop body.

The alternative that WAS considered:
- (Alt A — recorded but rejected) **One state machine for all three
  surfaces**: would force an over-general "operation" enum carrying
  REPL prompts AND nREPL JSON-RPC frames AND build-pipeline file
  paths. The shared substructure is too thin (just "loop with
  per-iteration recovery"); merging the charts would add
  variant-dispatch noise without removing real duplication.

## Consequences

- Each surface's `//!` docstring carries its chart. PR reviews can
  diff the chart alongside the body.
- Future read-eval-loop additions (debugger? `:reload`?) update the
  chart visibly.
- The chart is documentation, not enforced syntax. A future
  hook could parse the docstring and lint added states without an
  ADR amendment, but that mechanisation is deferred until the
  charts have stabilised (Phase 15+).

## Cross-references

- ROADMAP §9.16 row 14.9 (this row); rows 14.10 + 14.11 (future).
- ADR-0015 amendment 2 (F140-F144 re-introduction table).
- `.dev/principle.md` Bad Smell catalogue — "untyped loop with
  implicit state".
- `src/app/repl.zig` (the REPL implementation embedding the chart).

## Revision history

- 2026-05-28: ADR landed alongside `cljw repl` (row 14.9). nREPL
  + build pipeline charts placeholder pending rows 14.10 / 14.11.
