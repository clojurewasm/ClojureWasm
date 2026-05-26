# 0038 — `analyzeDef` pre-registers Var at analyze time

- **Status**: Accepted (Devil's-advocate fork landed 2026-05-26)
- **Date**: 2026-05-26
- **Author**: Shota Kudo (drafted with Claude autonomous loop)
- **Tags**: analyzer, def, var-binding, jvm-parity, F-002, F-009,
  D-084 (discharge)

## Context

`src/eval/analyzer/special_forms.zig::analyzeDef` historically built
a `DefNode` without interning the Var into the active namespace.
The actual `env.intern(ns, name, root, null)` call happens lazily at
`tree_walk.zig:466-475::evalDef` (and at VM runtime via the
`op_def` dispatch arm).

This "lazy intern" shape — Var resolution happens only after the
preceding `def` form has *evaluated* — produces two user-visible
breakages versus Clojure JVM Compiler semantics:

1. **Recursive `defn` fails at analyze time**:
   `(defn f [n] (if (= n 0) 0 (f (- n 1))))` raises
   `name_error [analysis]` on the inner `f` reference. The recursive
   body's `f` is analyzed before the outer `def`'s value has been
   reached at runtime; without an analyze-time pre-register, the
   symbol is unbound.
2. **Forward references inside top-level `(do ...)` fail**:
   `(do (def a 1) (def b a))` raises `name_error` on the second `a`.
   `analyzeDo` walks its forms sequentially through `analyze(...)`;
   the first sub-form's `DefNode` is built but no env binding has
   been installed by then.

Row 7.3 cycle 7 surfaced the issue through `defprotocol`'s macro
emission. The natural lowering of `(defprotocol P (m [x]))` is

```clojure
(do
  (def P (rt/__make-protocol! 'P ['m]))
  (def m (rt/__make-protocol-fn! P "m")))
```

which trips breakage #2. Cycle 7.1 (commit `99461f8`) shipped a
truncation workaround — emit only `(def P ...)` and defer the
per-method-Var binding to D-084 closure — and tracked the gap as
debt row D-084.

This ADR discharges D-084 by changing `analyzeDef`'s contract to
match Clojure JVM Compiler's: the Var lands in `env` at analyze
time, with placeholder `nil` root; runtime evaluators (TreeWalk's
`evalDef`, VM's `op_def`) re-intern with the actual evaluated value.
`env.intern` at `env.zig:353-357` is documented idempotent —
update-in-place when the name is already bound — which lets the
re-intern at runtime overwrite the placeholder cleanly.

## Decision

In `analyzeDef`, after the existing symbol-shape validation and
**before** the recursive `analyze(...)` call on the value form,
intern the Var with `nil` root:

```zig
const ns = env.current_ns orelse
    return error_catalog.raiseInternal(form.location, "def: no current namespace");
_ = try env.intern(ns, name_sym.name, .nil_val, null);
const value_node = if (items.len == 3)
    try analyzer_mod.analyze(arena, rt, env, scope, items[2], macro_table)
else
    try analyzer_mod.makeConstant(arena, .nil_val, items[1]);
// ... DefNode build as before ...
```

This unblocks all three cycle-7.1 dependents:

- Recursive `defn`: `(defn f [n] ...)` body now resolves `f` at
  analyze time because the placeholder Var was just interned.
- Forward refs inside `(do ...)`: `(do (def a 1) (def b a))` works
  because `a` is interned before `(def b a)` is analyzed.
- `defprotocol` per-method-Var binding: `(do (def P ...) (def m P
  ...))` reverts to the natural shape. Cycle 7.1's macro
  truncation rolls back in the same source commit (= cycle 8.1
  re-emits the full method-Var-binding shape).

### "Var exists but root is nil" window

A consequence of the chosen finished form is an observable window:
between `analyzeDef` and `evalDef`, the Var is resolvable in `env`
but its `root` is `.nil_val`. The window is:

- **Invisible today**: cw v1 evaluates analyze-then-eval back-to-back
  inside the same `cljw -e` / file invocation; no introspection path
  exists between the two passes.
- **JVM-parity**: Clojure JVM Compiler also interns the Var at parse
  time. A failed value-expression analysis there too leaves the Var
  interned at its previous root (or nil for a first-time def).
- **Documented for future**: live REPL streaming or lazy-compile
  paths (Phase 10+) would need to handle this window. The same is
  true on the JVM; cw v1 inherits the standard solution shape.

### Error semantics

If `analyze(value_expr)` raises after the pre-register, the
placeholder Var stays interned. On the next REPL form, the Var is
visible with root `.nil_val`. This matches JVM Clojure: a failed
`def` body leaves the namespace's Var binding at whatever value
the previous body set (or nil for a first-time def). cw v1 adopts
the same behaviour rather than introducing a rollback path.

## Alternatives considered

**Devil's-advocate fork (depth-2, fresh context) verbatim
embedding** — produced 3 alternatives within F-002 / F-009 +
ADR-0036 envelope (full text:
`private/notes/phase7-7.3-cycle8.1-devils-advocate.md`):

> **Alt 1 — smallest-diff (status quo + workaround macros)**
> **Shape**: `analyzeDef` stays unchanged. Recursive `defn` is
> handled by macro expansion — `defn` rewrites to a `(letfn [(f
> [...] ...)] (def f f))`-style shape, where `letfn` introduces
> the self-binding at analyze time via a local Scope rather than
> at the Var layer. `defprotocol` keeps the cycle-7.1 truncation
> indefinitely.
> **Verdict within F-NNN**: F-002 disfavours — smallest-diff bias
> smell. The finished form on JVM is "the Var is interned before
> the body is analyzed"; status quo refuses this and pushes the
> chicken-and-egg to a macro layer that has no clean general
> solution for the cross-`def` reference case. F-009 neutral.
>
> **Alt 2 — finished-form-clean (env.intern at analyze)**
> **Shape**: as described above. `analyzeDef` calls
> `env.intern(ns, name_sym.name, .nil_val, null)` after symbol
> validation, before recursing into the value form. Idempotence
> at `env.zig:353-357` covers the runtime re-intern.
> **Verdict within F-NNN**: F-002 strongly favours — matches JVM
> Clojure Compiler's `DefExpr.parse` exactly. "Var exists but root
> is nil" window is a known consequence of the chosen finished
> form (JVM has it too) — not a cw v1 defect. ADR-0036 obligation
> is tractable (≥1 diff case in the same commit). F-009 neutral-
> to-favouring (analyzer's role as Var-binding-lifecycle owner is
> strengthened).
>
> **Alt 3 — wildcard (declare special form)**
> **Shape**: Introduce explicit `(declare name)` special form.
> Recursive `defn` requires `(declare f) (defn f ...)`.
> `defprotocol` macro emits `(do (declare P) (declare m1) ...
> (def P ...) (def m1 ...))`.
> **Verdict within F-NNN**: F-002 disfavours — user-visible
> divergence from JVM Clojure (recursive `defn` requires `declare`
> two-step). If `defn` macro masks via implicit `(declare)`
> emission, the `defn` macro becomes the analyzer-impurity surface
> — worst of both worlds. F-009 neutral but adds a new analyzer
> Node variant (more ADR-0036 parity work).
>
> **No hard F-NNN violation surfaced** across any alternative;
> findings are F-002-leaning. Recommendation: Alt 2.

**Selected**: Alt 2. The Devil's-advocate's F-002 reading is the
load-bearing rationale: cw v1's lazy-intern is a smallest-diff
omission, not a design choice. The finished form (matching JVM
Compiler's `DefExpr.parse`) lands in this cycle.

Alt 1 rejected per the smallest-diff bias finding: it calcifies the
cycle-7.1 workaround into the steady state and produces a *larger*
overall surgery (`letfn` shim in every `defn`) than touching
`analyzeDef`. Alt 3 rejected per the F-002 visibility finding: it
forces user-visible divergence from JVM Clojure or hides it via a
`defn` side-effect.

## Consequences

- **D-084 discharges in the same source commit as this ADR
  amendment lands.** The cycle-7.1 `defprotocol` macro truncation
  rolls back; per-method-Var binding works.
- **`(defn f [n] (... (f ...)))` works.** Recursive functions
  become a first-class cw v1 surface — previously requiring
  `loop` / `recur` exclusively, now supporting the natural shape.
- **`(do (def a 1) (def b a))` works.** Forward references inside
  top-level `(do)` blocks unblock; the conformance porting path
  (Phase 11+) inherits the JVM-equivalent semantics.
- **New diff cases land in the same commit per ADR-0036.** Two
  cases minimum: `def_recursive_reference` and
  `def_forward_in_do` exercising the analyze-time pre-register.
- **No dual-backend asymmetry.** Both TreeWalk and VM observe the
  same runtime intern behaviour (analyzeDef's pre-register is
  analyze-only; runtime intern paths are unchanged in both
  backends).
- **No new Node variant, no new opcode.** ADR-0036 parity
  obligations are minimal.

## Affected files

- `src/eval/analyzer/special_forms.zig` — `analyzeDef` body.
- `src/lang/macro_transforms.zig` — `expandDefprotocol` reverts
  the cycle-7.1 truncation, emits full `(do (def P ...) (def m
  P ...))` shape.
- `src/lang/diff_test.zig` — new differential test cases.
- `.dev/debt.md` — D-084 row moves to `## Discharged` (or status
  flips to `landed`).
- `test/e2e/phase7_protocol.sh` — added cases exercising
  per-method-Var binding (`(defprotocol IPing (ping [this])) (ping
  ...)` — the call path still needs the `.protocol_fn` arm in
  `vtable.callFn`, landing in cycle 8.2; this ADR's e2e covers
  the macro-emission path only).

## References

- F-002 (`.dev/project_facts.md`) — finished-form cleanliness wins.
- F-009 (`.dev/project_facts.md`) — feature-implementation
  neutrality.
- ADR-0036 — dual-backend parity contract.
- ADR-0008 amendments 1-3 — protocol dispatch evolution (cycle 7.1
  surfaced this issue).
- `private/notes/phase7-7.3-cycle8.1-devils-advocate.md` — full
  Devil's-advocate output.
- D-084 (`.dev/debt.md`) — the debt row this ADR discharges.

## Revision history

- 2026-05-26: Status: Proposed -> Accepted (initial landing).
