# ADR-0071 — VM cleanup handlers vs catch handlers (error-context parity)

- Status: Proposed → Accepted
- Date: 2026-06-02
- Supersedes: none
- Refs: D-196 (VM-default flip blocker 4), ADR-0070 (F-012 VM-default
  intent), ADR-0060 (catalog→exception conversion), ADR-0055 am2 /
  D-144 (dynamic error-context), ADR-0036 (dual-backend parity).

## Context

D-196 blocker (4): the VM backend loses the dynamic
`cljw.error/*error-context*` (and collapses the catalog Kind) when an
error propagates out of a `binding` (`with-context`) form. With
`CLJW_ERROR_FORMAT=edn`:

- `(with-context {:request-id "abc"} (/ 1 0))` → VM renders
  `:kind :exception` (should be `:arithmetic_error`) and drops
  `:request-id`. tree_walk renders `:kind :arithmetic_error
  :request-id "abc"`.
- `(with-context {:request-id "abc"} (throw (ex-info "boom" {})))` →
  VM renders `:kind :exception :message "boom"` but drops
  `:request-id`.

### Root cause

`compileBinding` (`vm/compiler.zig`) lowers `binding`'s
cleanup-on-unwind with `op_push_handler` (a **catch** handler) +
`op_pop_binding_frame; op_throw`. When the body raises, the VM outer
loop (`vm.zig`) treats it as catchable:

1. **Catalog path** — converts the catalog error (`arithmetic_error`)
   into a synthetic exception via `allocException(rt, info.message,
   class)`, reading only `info.message` and `clearLastError()`-ing →
   drops `info.context` AND collapses the Kind to `:exception`.
2. **Throw path** — nulls `last_thrown_context`, and the cleanup
   re-throw `op_throw` runs AFTER `op_pop_binding_frame`, so its
   context re-snapshot reads the now-restored empty `{}`.

tree_walk's `evalBinding` uses `defer popFrame`: cleanup unwinds
**without catching**, so an uncaught catalog error keeps its `Info`
(Kind + context, captured at `setErrorFmt` time) and a user throw's
context snapshot (taken at the original throw, frame still live)
survive intact.

The VM overloads ONE mechanism (`op_push_handler` + `op_throw`) for
two semantics — `catch` (intercept + convert + match) and `defer`
(unwind + re-raise unchanged). That overload is the bug.

## Decision

Distinguish **cleanup** handlers from **catch** handlers in the VM, so
a `binding`/bare-`try` cleanup behaves as the `defer` it semantically
is — no conversion, no context clear, no re-snapshot.

1. `Handler` gains `kind: enum { catch_clause, cleanup }` (`vm.zig`).
2. New opcode `op_push_cleanup` — identical to `op_push_handler` but
   tags the handler `.cleanup`.
3. New opcode `op_reraise` — re-fires the in-flight error WITHOUT
   conversion or context mutation, via a
   `dispatch.vm_pending_reraise: ?anyerror` threadlocal the cleanup
   branch stashes immediately before jumping to the cleanup tail.
4. VM outer loop: **check the nearest handler's kind first**. If
   `.cleanup`, do NOT convert catalog→exception, do NOT clear
   `last_thrown_context`; stash the original Zig error, restore `sp`,
   jump to the cleanup ip. The cleanup bytecode runs (e.g.
   `op_pop_binding_frame`) then `op_reraise` returns the stashed error
   so the ORIGINAL error (catalog `Info` intact, or thrown value +
   context snapshot intact) propagates unchanged.
   Idempotency: because the cleanup branch is tested *before* the
   conversion branch and stashes immediately before each jump, a
   re-raised catalog error meeting an OUTER cleanup handler is stashed
   again (never re-converted); meeting an outer CATCH handler converts
   exactly once (correct — the catch needs a class to match).
5. compiler: `compileBinding` uses `op_push_cleanup` + `op_reraise`.
   `compileTry` with **zero** catch clauses (bare `try` /
   finally-only) uses `op_push_cleanup` + `op_reraise`. `compileTry`
   WITH catch clauses keeps `op_push_handler` + `op_throw` (the catch
   path needs the catalog→exception conversion so `op_match_class`
   can match a class name).

### Scope / out-of-scope

In scope (D-196 blocker 4): `binding`, bare `try`, finally-only `try`.
Out of scope (separate, no e2e, tracked as a D-196 follow-up note):
the `try`-WITH-catch no-match re-raise edge still converts + can lose
context when an unmatched catalog error escapes a catch inside a
`with-context`. That edge needs the same "re-raise the original, not
the converted, error" treatment but interacts with the
duplicated-finally lowering; deferred to keep this cycle focused on
the binding blocker per the user's one-blocker-at-a-time directive.

## Consequences

- VM error-context parity with tree_walk for `binding`/bare-`try`
  cleanup edges; D-196 blocker (4) discharged (phase14_with_context +
  phase14_user_throw green on `-Dbackend=vm`).
- Two new opcodes (exhaustive `Opcode` switch enforces dispatch arms).
- `compileTry`'s no-catch unit test updates to the new shape
  (`op_push_cleanup` / `op_reraise`).
- The cleanup edge now NAMES its `defer` semantics, so a future reader
  does not re-derive this analysis (the silence that hid this bug).

## Alternatives considered

(Devil's-advocate, fresh-context `general-purpose` fork — verbatim.)

**F-NNN envelope confirmed:** F-002 (finished-form cleanliness wins;
cycle/diff/LOC is *not* a constraint), F-012 (VM is production default,
tree_walk is the differential oracle, both backends MUST produce
identical observable behaviour). None of the three alternatives below
requires violating an F-NNN; the one design vector that *would* brush
against F-012's parity intent is flagged at the end.

**Shared root-cause framing.** The bug is two distinct loss points: (a)
the catalog→exception conversion at the handler-unwind drops
`info.context` and collapses the Kind; (b) the throw path nulls
`last_thrown_context` and the cleanup re-throw re-snapshots AFTER the
frame pop (empty). tree_walk avoids both via `defer popFrame` (no
handler interception). The draft's insight — "a binding/finally-only
try cleanup is `defer`, not `catch`" — is the load-bearing observation;
the alternatives differ in where it is encoded.

**Alt 1 — Smallest-diff: fix the two loss points in place, no new
opcodes.** Keep the existing lowering; (1) seed the synthetic exception
with `info.context` + preserve the original Kind (needs a new ex_info
field since `buildThrownInfo` hard-codes `origin = .thrown` →
`:exception`); (2) make `op_throw` keep the pre-pop snapshot if the
post-pop one is empty, and don't null context at the handler.
*Better:* no opcode growth, no `Handler.kind`, no threadlocal carrier.
*Breaks:* it patches symptoms at both leaks instead of separating the
semantics — the conversion still fires inside `binding`, forcing a new
ex_info field purely to undo a conversion that should never happen on a
cleanup edge (Smallest-diff-bias smell vs F-002). The
`op_throw orelse keep-old-snapshot` heuristic conflates "no context
bound" with "context popped" → a nested rebind-to-empty re-throw leaks
the outer context (silent wrong-context bug, and an *observable*
divergence the opposite direction from the fix = F-012 parity
regression risk). Two channels stay un-unified.

**Alt 2 — Finished-form-clean (RECOMMENDED): the draft's structure,
cleanup edge as a true pass-through.** Distinguish `.cleanup` from
`.catch_clause`; add `op_push_cleanup` + `op_reraise`. On the cleanup
edge: do NOT convert, do NOT `clearLastError()`, do NOT null context —
`last_error` (Info, context captured at `setErrorFmt`) stays put and
`op_reraise` returns the original Zig error (e.g. `error.ArithmeticError`,
not `error.ThrownValue`); the catalog Info then reaches `renderError`
exactly as in the uncaught tree_walk path → `:kind :arithmetic_error
:request-id "abc"`. For a thrown value, `last_thrown_exception` +
`last_thrown_context` are preserved verbatim (never nulled). Carry the
in-flight error in the threadlocal carrier; `compileBinding` and
`compileTry` with zero catch clauses switch to the cleanup ops; a `try`
WITH catches keeps `op_push_handler` (the catch needs the conversion to
match). *Critical subtlety:* the `try`-with-catch no-match-with-finally
edge must re-raise the original (not converted) error to fully match
tree_walk — the draft under-specifies this; pin it with a differential
case per edge. *Better than draft/Alt 1:* makes the cleanup edge
*semantically* a `defer` (F-012 parity by construction, not symptom
patching); the catalog error is never mutilated, so Alt 1's
Kind-preservation problem evaporates; `op_push_cleanup`/`op_reraise`
NAME the `defer` semantics the current code hid. *Risks:* largest diff
(two opcodes, `Handler.kind`, four compiler arms) — per F-002 not a
reason to downgrade; the try+catch+finally no-match edge is intricate
(mitigate with ~4 diff cases); `op_reraise` returning a *catalog* error
means the outer-loop unwind must be idempotent w.r.t. conversion when
an outer handler exists (assert via a nested-binding-inside-try case).

**Alt 3 — Wildcard: lower binding/finally cleanup as a dispatcher-level
scope guard, not bytecode.** Record env-frame depth at `eval()` entry;
on any error, a Zig `defer` restores `current_frame` to that depth
(mirrors tree_walk). The binding body compiles to just
`op_push_binding_frame` + body + `op_pop_binding_frame` with NO handler;
the error propagates raw with Info/context intact. *Better:* most
faithful to tree_walk, zero new opcodes, smallest `compileBinding`.
*Breaks:* a `finally` body has observable side effects that must run on
the operand stack BEFORE the error propagates — a dispatcher-level
`defer` cannot run arbitrary user cleanup code in order, so this handles
`binding` but NOT `try`/`finally`, splitting the two cases the draft
unifies (a smell). Restoring frame depth by count couples the VM unwind
to a global mutable invariant (`env_mod.current_frame` chain) ROADMAP
§13 is wary of. Does not address loss point (a) for the try-with-catch
case, so it must be COMBINED with part of Alt 1/2 → not actually
smaller net.

**Recommendation: Alt 2** — the only option that makes the VM cleanup
edge behave as the `defer` it semantically is, which is what F-012
parity demands. Per F-002 the larger diff is not a reason to prefer
Alt 1.

### Decision vs recommendation

Accept **Alt 2**, scoped to `binding` + zero-catch `try` (the D-196
blocker-4 surface). The DA's flagged try-with-catch no-match-with-finally
edge is acknowledged as out-of-scope here and recorded as a D-196
follow-up (no e2e/blocker today); the cleanup mechanism this ADR lands
is the reusable primitive that edge will adopt when it is taken up.
