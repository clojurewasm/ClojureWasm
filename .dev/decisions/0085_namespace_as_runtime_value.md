# ADR-0085 — Namespace as a runtime value: `*ns*`/`current_ns` binding round-trip + runtime `in-ns`/`use`/`refer`

Status: Proposed → Accepted (2026-06-04)

## Context

The D-232 validation campaign cannot load ~20 upstream `clojure.test`
suites because they depend on `clojure.test-helper`, whose `temp-ns` /
`eval-in-temp-ns` use:

```clojure
(binding [*ns* *ns*]
  (in-ns (gensym))
  (apply clojure.core/use 'clojure.core uses)
  *ns*)
```

Two cljw gaps block this (both confirmed by probing the binary +
reading source):

1. **`(binding [*ns* *ns*] (in-ns 'tmp) …)` does not round-trip.** After
   the binding frame pops, `current_ns` is still `tmp` — the next
   top-level form runs in the wrong namespace (`println` unresolved).
   ROOT: `*ns*` the Var is fine — `Var.deref` (env.zig:98) already
   consults `findBinding` before the root, so `*ns*`'s *value* respects
   thread-bindings. But `env.current_ns` is a SEPARATE stored `?*Namespace`
   field (env.zig:266) read by ~40 resolution sites, and the generic
   `binding` push/pop machinery never touches it. `in-ns`→`setCurrentNs`
   writes the field + the Var root directly, bypassing the thread-binding,
   so on pop the field stays stale. The field and the Var desync exactly
   when a `binding [*ns* …]` frame is live.
2. **`in-ns`/`require` are analyzer special forms requiring a literal/
   quoted symbol; `refer`/`use`/`refer-clojure` do not exist at all.**
   `(in-ns (gensym))` / `(apply clojure.core/use …)` need a RUNTIME
   FUNCTION surface. cljw evaluates files one form at a time
   (read→analyze→eval→next, runner.zig / loader.zig), so a runtime
   `in-ns` that mutates the ns during eval of form N IS visible to the
   analysis of form N+1 — the special form was a compile-time
   convenience, not a necessity, for the top-level case.

This is a structural change to how the namespace is represented at
runtime + to the special-form set. Per CLAUDE.md it is handled inline
with a mandatory Devil's-advocate fork (below).

## Decision

Make `current_ns` a **derived view of `*ns*`** (single source of truth),
realised by **eager materialisation**: the `current_ns` field is refreshed
from `env.ns_var.deref()` at the small, generic set of binding boundaries
— `setCurrentNs` (ns switch), `binding`-frame push, `binding`-frame pop —
so it always equals `*ns*`'s effective (thread-binding-respecting) value.
Readers keep reading the field (free; no per-resolution deref). The
refresh is generic (push/pop re-derive unconditionally; they never inspect
*which* var changed), so the binding machinery carries no per-var special
case, and the field is no longer an authoritative second copy — it is a
materialised cache of the Var.

`in-ns` becomes `set!`-semantics on `*ns*`: mutate the innermost thread
binding if one holds `*ns*`, else the root (reusing the existing `set!`
helper), then re-derive `current_ns`. `in-ns`/`use`/`refer`/`refer-clojure`
gain a runtime-function surface (`clojure.core` Vars over one shared
`ns_ops` impl, reachable as `clojure.core/use` for the `apply` site); the
existing `in-ns`/`require`/`ns` special forms stay as literal-head fast
paths and fall through to the var on a non-literal arg. `in-ns` returns the
ns Value (ADR-0083), not nil.

This realises the Devil's-advocate's recommended **Option 2** (single
source of truth = `*ns*`) while avoiding its 40-site `field→currentNs()`
call-site churn and the `*Env`-mutability (const-ness) wrinkle a lazy
caching accessor would impose: eager materialisation keeps the field a
plain read, and the refresh sites are the same few the lazy-cache
generation-bump would touch.

### Commit decomposition

- **Commit 1 (prerequisite, representation fix):** `current_ns` becomes
  an eagerly-materialised view of `*ns*` — refresh helper called at
  setCurrentNs + binding push + binding pop; `in-ns` set!-semantics. Test:
  `(binding [*ns* *ns*] (in-ns 'tmp.x)) (println "ok")` resolves in the
  restored outer ns. Dual-backend diff case (ADR-0036) — VM has its own
  binding + in_ns arms.
- **Commit 2 (surface, runtime fns):** `in-ns`/`use`/`refer` builtins +
  `refer-clojure` macro over a shared `ns_ops` impl; special-form
  non-literal fall-through. Test: the `temp-ns` / `eval-in-temp-ns` shapes.
- **Commit 3 (optional):** turn on the ~20 test-helper-dependent suites.

Commit 1 must precede Commit 2: without the round-trip fix, a runtime
`in-ns` inside `(binding [*ns* *ns*] …)` leaves `current_ns` at the temp
ns after pop, masking whether the fns work.

## Consequences

- The `binding [*ns* …]` round-trip works → `temp-ns` / `eval-in-temp-ns`
  → the test-helper cluster (~20 suites) becomes loadable.
- `current_ns` is no longer an authoritative second copy of the namespace;
  it is a materialised view of `*ns*`. Any FUTURE binding entry point (a
  Phase-16 thread that inherits bindings, a `with-bindings` primitive) must
  call the single refresh helper — this residual is contained to one helper
  invoked at the enumerable binding boundaries, not a per-var special case.
- Both backends change identically (both refresh via the same helper),
  preserving TreeWalk↔VM parity (F-012); the ADR-0036 dual-backend gate
  rides Commit 1.
- `in-ns`/`use`/`refer` reach clj's "these are functions" finished form
  (F-002); the special forms are reframed as literal-head fast paths over
  the canonical Vars (F-011 single mechanism).

### Divergences from clj (intentional)

- `in-ns` returns the ns Value (ADR-0083), matching clj.
- `(do (require …) (aliased/sym))` within a SINGLE form: the alias is
  installed at require-eval, after the whole `do` was analysed, so the
  in-form aliased symbol does not resolve. clj has the same top-level-
  sequential constraint; only multi-form files are affected, which cljw
  handles via per-form eval. Unchanged by this ADR.
- `:rename` / `:as-alias` on a runtime libspec stay an explicit
  unsupported raise (separate deferred feature).

## Alternatives considered

The mandatory Devil's-advocate subagent (fresh context, briefed with the
F-002/F-009/F-011/F-012 envelope) produced the following, reflected
verbatim:

> **Key correction:** `Var.deref` ALREADY consults `findBinding` for
> dynamic vars before root — so `*ns*` deref already respects
> thread-bindings. The bug is purely that `current_ns` (the FIELD read by
> ~40 resolution sites) is not kept in sync with the `*ns*` var's effective
> binding. Also: the `in_ns_node`/`require_node`/`ns_node` DO have VM arms
> (vm.zig:515-555) — the survey's "VM-free" claim is wrong; the
> dual-backend gate (ADR-0036) applies to Commit 1.
>
> **Option 1 — smallest-diff:** keep `current_ns` a field; make `binding`
> push/pop `*ns*`-aware (sync the field only when a pair binds `ns_var`);
> `in-ns` setBinding-if-frame-else-setRoot. Better: zero hot-path cost,
> smallest blast radius, reuses the existing `set!` pattern. Breaks/risks:
> the dual representation PERSISTS — every future binding entry point must
> remember to sync the field; a per-var special-case lives in the generic
> binding machinery forever; forgetting it silently re-arms the desync bug.
> This is the Smallest-diff bias smell. ~6 files.
>
> **Option 2 — finished-form-clean (RECOMMENDED):** `current_ns` becomes a
> derived view of `*ns*` (`currentNs() = ns_var.deref()` decoded), with a
> generation-counted cache (binding push/pop bump a generation; currentNs()
> recomputes only on generation change → one int-compare in the common
> case, same cost as today's field read). `in-ns` is set!-semantics on
> `*ns*` with no field to also update; the binding machinery needs NO
> `*ns*` special-case (the generic mechanism already makes the deref
> correct). Better: collapses the dual representation — exactly one answer
> to "what is the current ns", impossible to desync, every future binding
> path / backend / thread correct for free. Breaks/risks: the cache is
> load-bearing correctness (one generation-bump site to get right, vs
> Option 1's N field-sync sites — strictly fewer); touching `currentNs()`
> ripples to ~40 mechanical call-site renames (per F-002 NOT a reason to
> prefer Option 1 — that instinct is the Cycle-budget-defer smell); the
> bootstrap window (ns_var == null) needs a field fallback. ~15 files,
> mostly one-token edits. Largest diff; cleanest result. Does NOT violate
> any F-NNN.
>
> **Option 3 — wildcard:** eliminate the hot `current_ns` reads instead of
> caching them — bake alias/refer resolution fully into the Node at analyze
> time so backends never read ambient ns; `currentNs()` then an uncached
> deref read only by the (cold) analyzer + rare ns-mutating ops. Better: no
> cache AND no field. Breaks/risks: the premise (hot reads are eliminable)
> is UNVERIFIED — runtime reads survive at vm.zig def-target + macro_dispatch
> (warm); converting them is a deep change (def lowering, macro synthetic
> vars) of unbounded blast radius until an audit that is itself the risk;
> does not by itself fix the round-trip for sites that legitimately read
> ambient ns at runtime (`resolve`). Highest uncertainty. Revisit as a
> later optimisation on top of Option 2 if profiling demands.
>
> **Recommendation: Option 2, decomposed into Commit 1 (representation
> fix) + Commit 2 (runtime fns) + optional Commit 3 (turn on suites).**
> The "general binding machinery, no per-var special case" property is the
> decisive cleanliness win over Option 1; the larger call-site diff is not
> a valid reason to prefer Option 1 (Smallest-diff / Cycle-budget-defer
> smell). Option 1 is the fallback only if a call-site is found where the
> derived view is impossible (none found in the audit).

**Main-loop decision within the F-NNN envelope:** adopt Option 2's single
source of truth, but realise `currentNs()` by **eager materialisation of
the `current_ns` field** (refresh from `*ns*` deref at the setCurrentNs +
binding-push + binding-pop boundaries) rather than a lazy caching accessor.
This keeps Option 2's "current_ns is a view of `*ns*`, not an authoritative
copy" semantics and its "no per-var special case" property (push/pop
re-derive unconditionally), while avoiding (a) the 40-site `field →
currentNs()` churn and (b) the `*Env`-mutability requirement a self-caching
accessor imposes on ~40 read sites, several of which would need const→mut
signature changes. The residual — a generic refresh helper invoked at the
binding boundaries — is the same small surface Option 2's generation-bump
would occupy; it is NOT the per-var push/pop special-case that made Option 1
a smell (the refresh never inspects which var changed). Per F-002 this is
chosen on finished-form grounds (it is strictly cleaner than both
enumerated options for cljw's const-discipline), not on diff-size grounds.

## Cross-references

- D-232 (validation campaign) — the driver; the test-helper cluster is
  the unblock target.
- ADR-0083 (`*ns*` as `.ns` Value + `ns_var` cache + `setCurrentNs`
  contract) — this ADR makes `current_ns` a view of that Var.
- ADR-0036 (dual-backend diff gate) — Commit 1 rides it.
- F-002 (finished-form wins), F-011 (one shared mechanism + clj-oracle
  equivalence), F-012 (VM is production default — both backends change
  identically).
- private/notes/phase15-in-ns-runtime-fn-survey.md (Step-0 survey).
