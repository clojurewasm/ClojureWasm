# ADR-0118 — v0-level error display: loc back-fill + frame trace + numbered-context renderer

- **Status**: Proposed → Accepted
- **Date**: 2026-06-08
- **Opens**: **D-323** (the multi-cycle implementation tracker) + folds the two
  clear telemetry bugs (EDN `:file "unknown"`, eval `:line 0 :column 0`).
- **Cross-refs**: ADR-0055 (one `Info` → text + EDN in lockstep — the renderer
  changes MUST land in both formats), ADR-0059 / AD-007 (no-JVM: error Kind is
  the surface, not a JVM class — this ADR keeps cljw-native labels, does NOT
  adopt clj's `Execution error (Class)`), `dual_backend_parity.md` (frame push
  must land in TreeWalk + VM with a differential test), F-002 (finished-form
  wins), F-011. Reference impl: cw v0 (`~/Documents/MyProducts/ClojureWasm/`,
  v0.5.0) — survey at `private/notes/v0-error-span-trace-survey.md`.

## Context

The v1 redesign regressed the error DISPLAY relative to v0. A runtime/eval
error in v1 renders:

```
<-e>:0:0: arithmetic_error [eval]
Divide by zero
```

— no source location (`0:0`), no caret, no surrounding-source window, no stack
trace. Only parse/analysis errors (which the reader/analyzer locate) get a
single source line + a lone `^`. v0, by contrast, located eval errors at
runtime and rendered a numbered context window, an inline `^--- message` caret,
and a `Trace:` of fn frames:

```
Arithmetic error at /tmp/nested.clj:1:17
  Divide by zero
Trace:
  user/f (/tmp/nested.clj:1)
  user/g (/tmp/nested.clj:2)

  1 | (defn f [x] (/ x 0))
                       ^--- Divide by zero
  2 | (defn g [y] (f y))
  3 | (g 10)
```

The user (2026-06-08) confirmed v0's display was materially better and wants
v1 to reach v0-level error display — **including eval-error location and stack
trace** — by the CFP submission. The error SYSTEM stays cljw-native (no JVM
class fiction, per AD-007); only the DISPLAY is being raised to v0 level.

**The carrier chain already exists in v1.** Reader Forms carry `.location`,
every Node carries `loc`, and `loc` is threaded through `callFn` into hundreds
of `raise(.code, n.loc, …)` sites. The gaps are narrow and well-identified
(survey Q5).

## Decision A — loc back-fill via the live frame stack (closes `0:0`) — **DA Alt 2**

Eval errors surface as `0:0` because deep raise sites pass an empty loc
(`raise(.code, .{}, …)` — e.g. VM ops `vm.zig:237,245,…`, and primitives that
raise with a default loc).

The draft's first shape (TreeWalk node back-fill + a **VM per-IP `lines`/
`columns` Chunk side table**) was rejected by the Devil's-advocate as the
weakest load-bearing choice: two divergent loc-recovery mechanisms = two test
matrices + a Chunk-size regression on **every** compiled unit. Adopted instead
(DA Alt 2 — strictly cleaner, finished-form):

- **TreeWalk**: back-fills from the node `n` in hand at each eval arm (free —
  no table) for sub-form precision. `evalCall` already threads `n.loc` into
  `callFn`, so the TreeWalk path largely works; audit any `raise(…, .{}, …)`.

- **VM** (Revision 1, 2026-06-08 — corrects the DA Alt 2 premise): the DA's
  "the frame stack carries the loc, no VM table needed" assumed the call-site
  `loc` is **already threaded into `callFn` in the VM**. It is NOT — `vm.zig:386`
  `op_call` calls `vt.callFn(rt, env, callee, args, .{})` with an **empty loc**,
  so the divide-by-zero primitive (which DOES take a `loc`, `math.zig:142`)
  receives `.{}` → `0:0`. The VM operand stack discards node identity, so the
  call-site loc must come from the **bytecode** (compile-time known: `CallNode`
  carries `loc`). The finished-form carrier, matching v1's established
  **sparse-side-table-on-`BytecodeChunk`** pattern (`call_sites` / `libspecs` /
  `ns_filters` / `ctor_sites` / `import_sites`, all indexed off an operand): a
  parallel **`locs: []SourceLocation`** array on the chunk, indexed by
  instruction index (IP). The compiler populates it from each node's `loc` at
  `emit`; the VM passes `chunk.locs[ip]` into `callFn` at `op_call` (and the
  direct-raising ops annotate from it). The frame push (Decision B) reads its
  loc from the same `locs[call_ip]`.

  This is v0's per-IP `lines`/`columns` approach re-derived onto v1's `Chunk`.
  The DA's bloat objection stands as a real cost (≈ one `SourceLocation` per
  instruction) but is **necessary** — there is no free loc in the VM to reuse;
  the cost is bounded by code size and lives only on compiled fns. A later O-NNN
  may sparsify it (only call/raise IPs) if it measures; per-IP is the simplest
  correct first form.

Start at sub-form (node) precision; add arg-precise carets (v0's 8-slot
`arg_sources`) only if a sweep shows it matters.

## Decision B — frame-stack for `Trace:`, **pop-on-both + snapshot-at-raise** (DA correctness fix)

`info.zig:180-256` already defines `StackFrame` + a 64-frame `call_stack` +
`pushFrame`/`popFrame`/`getCallStack`/`clearCallStack` — **never called**. Revive
it, pushing an error-frame at the single shared `callMethodImpl`/`callFn` choke
point (better than v0's two separate TreeWalk+VM push sites; both backends get
it from one site).

**Pop on BOTH success and unwind — NOT pop-on-success-only.** The DA caught a
correctness trap: pop-on-success-only leaks frames on every *non-error* non-local
exit (`recur` is signalled not errored; a `try`-caught exception recovers; a
`reduced` early return) — stale frames then poison the *next* unrelated error's
trace. Instead, **snapshot the live frame stack into `Info` at `setErrorFmt`/
raise time** and pop on both paths via `defer` — this reuses v1's existing
dynamic-context discipline (`info.zig:212`: the binding frame is popped during
unwind, so its content is snapshotted into `Info.context` before the renderer
reads it). The renderer reads the per-`Info` trace snapshot, never the (by then
empty) live stack. A caught-and-recovered error's `Info` is discarded with its
snapshot, so no cross-error poisoning.

Do NOT fold the error-frame onto the `env_mod` binding-frame stack as a *shared*
stack, but DO mirror its snapshot-on-raise + pop-on-both lifecycle. Per
`dual_backend_parity.md`, the push lands in TreeWalk AND the VM call op in the
same change with a differential test asserting equal traces.

## Decision C — renderer upgrade, two formats in lockstep (ADR-0055)

Extend `formatErrorWithContext` (`runtime/error/print.zig`): a numbered ±2-line
window (`  N | <line>` gutter, `countDigits` width), the error line bright with
a `^--- <message>` caret tail (column-padded), surrounding lines dim, then a
`Trace:` walk (innermost first, `  <ns>/<fn> (<file>:<line>)`). The EDN emitter
(`error_render.zig`) gains a parallel `:trace [{:ns :fn :file :line} …]` vector
**in the same change** — the text and EDN formats never drift (ADR-0055). This
is v1's deliberate divergence from v0 (v0 had only a text renderer).

Optionally add a natural-name Kind label (`arithmetic_error` → `Arithmetic
error`) — but only via `info.kindLabel()` so text + EDN stay consistent; the
EDN keeps the `:kind :arithmetic_error` keyword (machine surface), the text
gets the natural label.

## Decision D — spans stay on Node/Chunk, never on Values

NaN-boxed 64-bit Values have no spare bits for a span and a Value↔span side-map
would be a GC-rooting liability. Source info lives on the compiled tree (Node
`loc`, already present) + the VM per-IP `Chunk` table (Decision A). Same choice
as v0 (off Values), different reason (v0: avoid bloating the tagged union; v1:
NaN-box has no room + GC-root hazard) — a `no_copy_from_v1.md` re-derivation.

## Decision E — fold the two clear telemetry bugs

- **EDN `:file "unknown"`**: the `-e` source label `<-e>` is present in the text
  path but the EDN emits `:file "unknown"` — the label is dropped. Thread the
  real source label into the EDN `:file`.
- **eval `:line 0 :column 0`**: "unknown position" rendered as a real `0`
  misleads telemetry consumers. Once Decision A back-fills most evals, a
  genuinely-unknown position should emit `:line nil`/omitted, not `0`.

These ride the relevant cycle (E.1 with the renderer/EDN work, E.2 with the
back-fill) per the user's "fix bugs the moment found" directive.

## Decision F — staging (3 + bugfix cycles, D-323)

Independent TDD cycles, highest-value first:

1. **Cycle 1 — loc back-fill (A) + eval position bug (E.2)**: closes the visible
   `0:0` regression. TreeWalk node back-fill, VM per-IP table + annotator.
2. **Cycle 2 — renderer window + caret tail (C, text) + EDN `:file` bug (E.1)**:
   the numbered context + `^--- msg` for the cases now located.
3. **Cycle 3 — frame trace (B) + `Trace:` render (C) + `:trace` EDN (C)**: the
   stack-trace capture + render, dual-backend parity test.

run-mode (`-M`/`-m`/`-X`) errors inherit all three uniformly (they flow through
the same eval/raise path; the synthetic `<-M>`/`<-X>` labels and the generic
`exception` Kind on `-X` throw are tracked as follow-on polish in D-323, not
blockers).

## Alternatives considered (Devil's-advocate, fresh-context fork)

**Alt 1 — Smallest-diff: loc back-fill only, no frame trace, text-only renderer.**
Ship choice A (close `0:0`) + a renderer that prints the context window + caret,
defer B (trace) and the EDN `:trace` to a later cycle. *Better:* zero new
threadlocal state on the hot call path; no pop-on-success-only correctness
surface; lands the highest-value UX win (eval location + caret) immediately.
*Breaks:* it is **smallest-diff bias dressed up** — the user explicitly named
"incl. eval location AND stack trace" as the v0-parity bar, so deferring B
misses the stated goal (F-002: the finished form is the whole v0 display, not
its cheaper half). It also tempts an ADR-0055 violation by touching only the
text emitter "for now" and back-filling `:trace` later, which is exactly the
drift ADR-0055 forbids. Reject on F-002 + ADR-0055 grounds.

**Alt 2 — Finished-form-clean: unify location and trace under one carrier, drop
the VM per-IP side table.** The draft's TreeWalk-node-vs-VM-IP-table **split is
the weakest load-bearing choice**. Two divergent loc-recovery mechanisms means
two test matrices and two drift surfaces forever. Cleaner: make the *frame push
itself* the single loc carrier. At the shared `callFn` choke point, the pushed
`StackFrame` already records `{fn_name, ns, file, line, column}` from the
call-site `loc` that is **already threaded into `callFn`** (confirmed: hundreds
of `raise(.code, n.loc, …)` sites + `BuiltinFn` takes `loc`). So the *innermost
live frame's* loc is the back-fill source for *both* backends — no per-IP Chunk
side table, no per-arm TreeWalk back-fill, no Chunk bloat across every compiled
unit. The VM's operand stack discarding node identity stops mattering because
the frame stack (not the IP) carries location. *Better:* one mechanism, one
test, no Chunk size regression, backend parity falls out for free instead of
needing a dedicated parity test. *Breaks:* a `raise` *between* calls (e.g. a bad
arg checked before any sub-call) has no fresher frame than the enclosing one, so
its loc is the call site, not the sub-expression — slightly coarser than
per-node back-fill. Mitigation: keep choice A's node back-fill *only* in
TreeWalk where the node is in hand for free (no table), and let the frame loc
cover the VM. This is strictly cleaner than a bespoke per-IP table and should be
the pick.

**Correctness trap the draft underweights (pop-on-success-only):**
pop-on-success-only **leaks frames on every non-local exit that is not an
error** — `recur` (signalled, not errored, in both `tree_walk.zig` and
`vm.zig`), `try`-caught exceptions, and early returns from `reduced`. The
draft's "survives the unwind" reasoning is correct *only* for the uncaught-error
path; a caught-and-recovered error leaves stale frames that poison the *next*
unrelated error's trace. The `binding`-stack analogy the draft rejects is
actually the right shape: frames must pop on **both** success and unwind, with
the trace **snapshotted into `Info.context` at `setErrorFmt` time** — which v1
already does for dynamic context (`info.zig:212`, the "binding frame is popped
during unwind, before the renderer reads this" comment). Reuse that exact
snapshot discipline for the trace and pop-on-both; do not invent
pop-on-success-only.

**Alt 3 — Wildcard: no threadlocal stack; reconstruct the trace from the GC
root-set / EvalFrame chain at raise time.** v1 already maintains rooted
`EvalFrame`s (per `gc_rooting.md`). Walk that live chain at `setErrorFmt` to
materialise the trace, instead of a parallel 64-slot threadlocal. *Better:* zero
hot-path push/pop cost, zero leak surface (the chain *is* the truth, nothing to
pop), no `max_call_depth` truncation lie. *Breaks:* couples error display to
GC-root internals (a moving-GC migration now must preserve frame fn-name/ns,
widening the `gc_rooting.md` contract); EvalFrame may not carry `fn_name`/`ns`
today, so it needs enrichment that touches the hottest struct. Higher risk than
Alt 2 for equal UX. Hold as the perf fallback if the threadlocal push/pop ever
measures on the call path.

**Recommendation (non-binding, F-002):** Alt 2. It removes the per-IP Chunk side
table (a real bloat-every-Chunk cost the draft accepts) and the dual-mechanism
test burden, and forces the pop-on-both + snapshot fix that the draft's
pop-on-success-only gets wrong. The 64-frame threadlocal cost is two pointer
writes per call — negligible versus the back-fill it replaces — and
`max_call_depth` truncation is already documented as best-effort. Keep choice C
and D as drafted (EDN `:trace` in lockstep per ADR-0055; spans never on
NaN-boxed Values).

**Main-loop disposition**: adopt **Alt 2's two correct contributions** — (1) the
revived frame stack with **pop-on-both + snapshot-at-raise** replacing the draft's
leaky pop-on-success-only (the DA's most valuable catch), and (2) TreeWalk node
back-fill where the node is free. **BUT Decision A Revision 1 reverses Alt 2's
"no VM per-IP table"**: implementation (2026-06-08) found the VM threads NO
call-site loc into `callFn` (`vm.zig:386` passes `.{}`), so the frame's loc has
no free source in the VM — a per-IP `locs` array on `BytecodeChunk` is necessary
(re-deriving v0's per-IP lines/columns onto v1's Chunk, matching v1's existing
sparse-side-table precedent). The DA's bloat objection is acknowledged as a real
(bounded, sparsifiable-later) cost, not a blocker. Alt 3 (GC-EvalFrame
reconstruction) is held as the perf fallback. Decisions C + D stand as drafted.

## Consequences

- Eval errors (incl. run-mode) gain location + numbered context + caret + trace
  — v0-level display, cljw-native (no JVM class).
- **VM `Chunk` grows a per-IP `locs: []SourceLocation` array** (Decision A
  Revision 1 — the DA's "no table" premise did not hold for the VM, which
  threads no call-site loc into `callFn`). Cost ≈ one `SourceLocation` per
  instruction, bounded by code size, on compiled fns only; a later O-NNN may
  sparsify to call/raise IPs. Plus the frame stack: a 64-frame threadlocal +
  two pointer writes per call (negligible; `max_call_depth` best-effort).
- The text + EDN renderers stay in lockstep (ADR-0055); both gain `:trace`.
- D-323 tracks the 3-cycle implementation + the run-mode label/Kind polish.

## Affected files (anticipated)

- `src/eval/backend/tree_walk.zig` (node loc back-fill + error-frame push at the
  shared `callFn`/`callMethodImpl` choke point).
- `src/eval/backend/vm.zig` (error-frame push at the VM call op — same frame
  API; NO per-IP Chunk table per Alt 2).
- `src/runtime/error/info.zig` (revive frame-stack use; snapshot trace into
  `Info` at raise; position nil when unknown).
- `src/runtime/error/print.zig` (numbered window + caret tail + trace).
- `src/app/error_render.zig` (EDN `:file` fix + `:trace` vector).
- `test/e2e/*`, `test/diff/*` (eval-loc + trace cases, dual-backend parity).
