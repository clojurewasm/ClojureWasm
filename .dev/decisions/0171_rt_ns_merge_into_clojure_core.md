# ADR-0171: Merge the `rt` kernel namespace into `clojure.core`; internals move to `cljw.internal`

- **Status**: Accepted (2026-07-15)
- **Driver**: CIDER completion-parity campaign (user-directed 2026-07-15);
  survey `private/notes/gapT-completion-parity-survey.md`; oracle baseline
  5/18 probes matching (`scripts/completion_oracle.py --diff`).

## Context

Zig-implemented builtin vars intern into an internal `rt` namespace and are
referred (Var-sharing) into `user` / every entered ns; bootstrap Zig macros
home there too. The home ns stays `rt`, which leaks into every observable
introspection surface, diverging from mainline Clojure (F-011 violation):

- `(pr-str (resolve '+))` → `#'rt/+` (mainline: `#'clojure.core/+`); same
  for `doc`/`meta` `:ns`, eldoc/lookup/completion `ns` fields, callable
  printing, and error messages.
- nREPL completion candidates annotate `(rt)` where mainline shows
  `(clojure.core)` — the user-visible trigger for this campaign.
- `(ns-publics 'clojure.core)` is missing every Zig builtin (they are
  refers, not mappings).
- `(find-ns 'rt)` / `(all-ns)` expose an undocumented ns; `(in-ns 'rt)`
  can enter and clobber the kernel.
- Structural scar tissue exists only because of the split:
  `Namespace.resolveQualified`'s hard-coded clojure.core refers-exception
  (env.zig), `referAllOverriding`, the per-ns rt refer in both backends,
  and the per-site display hack `syntax_quote.zig` carries (rt →
  clojure.core rename during syntax-quote resolution).

## Decision

**Full merge** (the Devil's-advocate fork's Alt 2 — chosen over the
lighter "re-home publics but keep `rt` alive" shape):

1. Public Zig builtins and bootstrap Zig macros intern with **home ns =
   `clojure.core`** at registration.
2. `__`-prefixed (and `-`-prefixed) internal vars move to a new, documented
   **`cljw.internal`** namespace (consistent with the owned `cljw.*`
   surface; its presence in `(all-ns)` is a recorded, documented fact
   rather than an undocumented leak).
3. The `rt` namespace is **deleted**: `Env.init` no longer creates it, the
   boot referAll and the per-ns rt refer in both backends go away, and the
   `resolveQualified` clojure.core exception + `referAllOverriding`'s
   rt-collision purpose dissolve.
4. The bundled `.clj` `rt/…` qualified references (~48 code sites) migrate
   to `cljw.internal/…` (internals) or bare/`clojure.core/…` (publics);
   the 12 Zig-side `rt/`-qualified symbol emissions (macro hygiene,
   `@deref` lowering, analyzer fallback) emit `clojure.core/…` — exactly
   what mainline's expansions emit.
5. Rebind-recursion hazards (a core.clj wrapper that redefines a name
   while calling the rt builtin qualified, e.g. `re-find`) are enumerated
   mechanically (rt mappings ∩ core.clj re-defs) and those builtins are
   renamed to `cljw.internal/__<name>` so the wrapper calls the internal,
   not itself.
6. The embedded AOT bootstrap cache regenerates at build (self-consistent).
   Externally persisted `cljw build` archives from before this change bake
   `"rt"` into var_ref constants and cannot resolve it once `rt` is gone:
   the serializer format version is bumped so old archives fail with the
   explicit version message, not a resolution error.

## Consequences

- `#'clojure.core/+`, `(:ns (meta #'+))`, `ns-publics`, completion/lookup/
  eldoc ns fields, callable printing all match mainline **at the data
  layer** — no per-surface normalization, no whack-a-mole (F-013).
- syntax_quote's per-site rt→clojure.core rename is deleted.
- Future introspection surfaces (`cljw --list-vars`, new nREPL ops) are
  correct by construction.
- `cljw.internal` is user-visible in `(all-ns)`; completion hides its
  `__` vars (the campaign's hidden-filter); an AD row records the
  divergence "mainline has no cljw.internal".
- One-time migration cost: ~60 sites + 7 test files + serializer version
  bump. Accepted per F-002 (finished-form wins; diff size is not a
  constraint).

## Alternatives considered (Devil's-advocate fork output, verbatim)

### Alternative 1 — smallest-diff: shared display normalization

One `introspect.publicVarNs(v)` (rt→"clojure.core") consulted by
completion/eldoc/lookup (introspect.zig:68; ops.zig:347,363), `printVarRef`
(print.zig:1318), the callable printer (print.zig:609/1039 via
`indexBuiltinNames`, primitive.zig:175), and syntax-quote (deleting the
syntax_quote.zig:95 per-site hack); plus a `__`-prefix filter in
`emitVarMap`.

- Better than the full merge: zero bootstrap-order risk; zero `.clj`
  churn; no AOT interaction; no rebind hazards; lands in one cycle.
- Breaks / fails to fix: it is display-layer lying — the data still says
  `rt`. `(ns-name (:ns (meta (resolve '+))))` → `rt` unless var-meta is
  faked too (another site); `(ns-publics 'clojure.core)` still missing
  builtins; `(find-ns 'rt)`, `(all-ns)`, `(ns-resolve 'rt '+)`,
  `(in-ns 'rt)` clobber hazard all remain. Every future introspection
  surface must remember to call the normalizer — the exact per-site
  whack-a-mole F-013 forbids, and it does not reach the same finished
  form, so F-002's smallest-diff tiebreaker does not apply. Rejected as
  terminal shape.

### Alternative 2 — finished-form-clean: FULL MERGE, `rt` eliminated (ADOPTED)

Intern public Zig builtins + bootstrap macros with home = `clojure.core`
at registration (primitive.zig:71-111 target swap; macro_transforms.zig:48);
move `__`/`-`-prefixed internals to a real, documented `cljw.internal` ns.
Delete `rt` entirely: Env.init (env.zig:390), the boot referAll
(primitive.zig:169), the per-ns rt refer in both backends (vm.zig:1217,1247;
tree_walk.zig:578), and the `resolveQualified` clojure.core exception
(env.zig:222-228) — it dissolves, as does `referAllOverriding`'s
rt-collision raison d'être and `cacheArithIntrinsics`' rt fallback
(bootstrap.zig:445-451). Migrate the ~48 `.clj` sites and 12 Zig emission
sites (`rt/or` → `clojure.core/or`, `rt/deref` → `clojure.core/deref` —
exactly what clj's own expansions emit).

- Better than keep-rt-alive (b): (b) keeps `(find-ns 'rt)`, `(all-ns)`,
  `(ns-resolve 'rt '+)`, `(in-ns 'rt)` as observable divergences — the
  F-011 violation is only ~90% closed, and the env.zig:222 special case
  must stay. Full merge closes the class, matches clj's actual shape,
  fixes `ns-publics` of clojure.core as a free side effect, and deletes
  ~4 pieces of structural scar tissue instead of preserving them.
- Breaks (concrete): (i) rebind-recursion hazard — core.clj wrappers that
  redefine a name while calling the rt builtin qualified (`re-find`,
  core.clj:2145) would rebind the same Var and recurse; enumerate
  mechanically (diff rt mappings vs post-bootstrap clojure.core mappings)
  and rename those to `cljw.internal/__…`. (ii) Tests: env.zig:919-968,
  primitive.zig:183-200, protocol.zig:957, core.zig:2033, math.zig:1391,
  macro_transforms.zig:4116, root_set.zig:891 — mechanical updates.
  (iii) Bootstrap order unchanged (registerAll already receives
  `clojure_core_ns`; clojure.core exists from Env.init). (iv) AOT:
  serialize.zig:295-300 bakes `var_ptr.ns.name` into var_ref constants;
  the embedded cache regenerates at build; external pre-change archives
  need a format-version bump (currently 3, serialize.zig:10). (v)
  placement.yaml Pattern B2 already interns private leaves directly into
  clojure.core — the merge generalizes the existing pattern. Diff is
  large (~60 sites + ledger/docs) — per F-002 not a counter-argument.

### Alternative 3 — wildcard: Env-level double-key ns aliasing

Register `"rt"` as a second `env.namespaces` key pointing at the same
`*Namespace` as `"clojure.core"`, and swap the registration target.

- Better: cheapest route to home-ns = "clojure.core" everywhere; all
  48+12 qualified refs keep resolving.
- Breaks: `Namespace.deinit` double-frees under two owning keys (needs an
  alias-aware ownership flag); `(find-ns 'rt)` returns clojure.core (a
  new divergence); `__` internals become clojure.core-homed → pollute
  `(ns-publics 'clojure.core)` and completion worse than today; the
  `re-find` recursion hazard fires immediately. A trap dressed as a
  shortcut — also the reason (b)'s "alias ns" sub-option is distrusted.

## Affected files (planned)

`src/runtime/env.zig`, `src/lang/primitive.zig`,
`src/lang/macro_transforms.zig`, `src/lang/bootstrap.zig`,
`src/eval/backend/vm.zig`, `src/eval/backend/tree_walk.zig`,
`src/eval/analyzer/{analyzer,syntax_quote}.zig`, `src/eval/reader.zig`,
`src/app/builder/serialize.zig` (version bump),
`src/lang/clj/clojure/core.clj` + `java/io.clj` + `instant.clj`
(rt/ → cljw.internal/ migration), affected unit tests,
`data/placement.yaml` (Pattern B wording), `.dev/accepted_divergences.yaml`
(cljw.internal AD row).

## Revision history

- 2026-07-15: Accepted (DA fork output embedded above).
