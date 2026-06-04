# ADR-0086 — Implicit `&form` / `&env` arguments for `defmacro`

Status: Proposed → Accepted (2026-06-04)

## Context

cljw's `defmacro` does not thread the implicit `&form` / `&env`
arguments that every JVM Clojure macro receives. `analyzeDefmacro`
(special_forms.zig) lowers `(defmacro m [a] body)` to `(fn* [a] body)`
and `expandIfMacro` (macro_dispatch.zig) calls that fn with only the
user args. The original D-099 landing recorded this as a deliberate
omission ("Tier-A test corpora do not introspect them; threading both
is D-099-followup") — at the time no consumer needed them.

The post-M real-world-library drain (F-010/F-011) changes that. `&env`
appears in **104 corpus files**, and two concrete consumers fail to
load today:

- **slingshot** (`slingshot/support.clj:198`): `(contains? &env sym)`
  — needs `&env` to be a real map whose KEYS are the in-scope local
  symbols.
- **meander** (`meander/epsilon.clj`): `(meta &form)` — needs `&form`
  to carry the call form's reader `:line`/`:column` metadata.

Survey: `private/notes/phase15-form-env-survey.md`.

### JVM semantics (the convention to match)

`Compiler.java` macroexpand1 calls the macro fn as
`(form, LOCAL_ENV, ...user-args)`, so the lowered fn is
`[&form &env & user-args]`:

- **`&form`** = the whole call form (head symbol included), a seq that
  is `IObj` and carries the reader's `{:line :column}` meta. `(meta
  &form)` → that map.
- **`&env`** = a `PersistentHashMap` keyed by the in-scope local
  **Symbol**, valued by an opaque `LocalBinding`. **No `:ns` key** (the
  `:ns`/`:locals` shape is ClojureScript, not JVM). `{}` (never nil) at
  the top level.
- Reported user arity is `method-arity − 2`.

## Decision

Thread `&form` and `&env` through `defmacro`, matching the JVM
calling convention, with three cljw-specific representation choices
forced by cljw's design (no JVM classes, metadata-less symbols):

1. **Lowering** (`analyzeDefmacro`): prepend `&form &env` to every
   arity's param vector, so the macro fn is `(fn* [&form &env & params]
   …)` (single- and multi-arity). This mirrors clj core.clj's
   `add-implicit-args`.

2. **Dispatch** (`expandIfMacro` + its analyzer call site): the
   analyzer — which owns the lexical `Scope` and the call `Form` —
   builds two Values and the dispatcher prepends them before the user
   args:
   - **`&form`**: the call form `(head a b …)` rebuilt as a list
     Value, with `{:line :column}` metadata synthesized from
     `Form.location` and attached via `list.withMeta`. (cljw Forms are
     metadata-less as *symbols* per ADR-0037, but list Values carry
     meta, so `(meta &form)` works.)
   - **`&env`**: a map Value whose keys are the in-scope local symbols
     (walked up the `Scope.parent` chain). Because cljw has no
     `LocalBinding` class (ADR-0009 / no-JVM ADR-0059), the **value**
     for each key is the local symbol itself (a stable, metadata-free
     placeholder). **No `:ns` key** (mirror JVM, not cljs). Empty map
     `{}` at the top level, never nil.

3. **Arity**: user-visible arity errors subtract the 2 implicit params
   (the macro author wrote `[a b]`, not `[&form &env a b]`).

Lowering and dispatch **land in the same commit** — either alone yields
arity mismatches.

### cljw divergences from JVM (recorded as accepted)

- **`&env` values are the local symbol, not a `LocalBinding`.** No JVM
  class exists; macros use `&env` KEYS (`contains?`, `keys`), not the
  opaque values, so a symbol placeholder is behaviour-preserving for
  the real consumer set. (AD candidate, derives_from ADR-0059/ADR-0009.)
- **No `:ns` key in `&env`.** Matches JVM; cljw is not ClojureScript.
- **`&form` metadata is synthesized from `Form.location`** at expansion
  time rather than carried on a metadata-bearing reader Value.

## Consequences

- `defmacro` macros can introspect their call form (`&form`, incl.
  `(meta &form)` for source location) and the lexical environment
  (`&env`, incl. `(contains? &env 'x)`).
- slingshot + meander advance past their `&env`/`&form` walls.
- The macro calling convention changes: any code that defined a macro
  and relied on the old no-implicit-args lowering would break — but
  that lowering was non-conforming, so this is a fix, not a break.
- Closes D-099-followup.

## Affected files

- `src/eval/analyzer/special_forms.zig` — `analyzeDefmacro` lowering
  (prepend `&form &env` to each arity's params).
- `src/eval/macro_dispatch.zig` — `expandIfMacro` signature (+ the
  call form + the env map) + prepend before user args.
- `src/eval/analyzer/analyzer.zig` — call site builds the `&form`
  (with synthesized meta) + `&env` (from `scope`) Values.
- Tests: `test/e2e/phase14_defmacro_user.sh` (+`&form`/`&env` cases),
  `src/lang/diff_test.zig` (dual-backend), corpus where clj-expressible.

## Devil's-advocate resolution (the key finding, verified)

The DA fork's central objection was that cljw's `Scope` contains
destructuring **gensym temps** (`vec__N` / `map__N`) in addition to
user locals, so an `&env` built from all Scope keys would "leak" them
and diverge from JVM (which the survey claimed is user-locals-only).

**This premise is false — verified against the clj oracle:**

```clojure
(defmacro envkeys [] (prn (sort (map str (keys &env)))) nil)
(let [[a b] [1 2] {c :c} {:c 3} x 5] (envkeys))
;; clj → ("a" "b" "c" "map__142" "vec__139" "x")
```

JVM `&env` **includes the destructuring gensym temps**. So building
cljw's `&env` from the full `Scope` binding chain (user locals + temps)
is the F-011-**correct** behaviour, not a leak. The only divergence is
the temp *names* (cljw names its gensyms differently), which is an
accepted opaque divergence — gensym names are never stable or compared,
exactly like set/hash print order (AD-001). The DA's Alt-2 "key-set
fidelity" work (filter temps, thread user-only symbols) would actually
make cljw *diverge* from JVM, so it is rejected.

### `&env` value representation (refinement vs the DA's Alt 2)

The DA recommended `&env` values be a `{:name :tag}` map for forward
type-hint introspection. **Rejected as Reservation-as-bias**
(`.dev/principle.md`): cljw's `Scope` stores only `name → slot` (no
type hints), so `:tag` would be perpetually `nil` — speculative
structure for a feature (lexical type-hint capture) that does not
exist. The F-011-observable contract is `(contains? &env sym)` → true,
`(keys &env)` → the local symbols, `(get &env sym)` → truthy/opaque
(JVM returns an opaque `LocalBinding`; cljw has no such class per
ADR-0059). The **local symbol itself** satisfies all three (truthy,
opaque-enough) without speculative keys. **Upgrade path:** when cljw
gains lexical type-hint capture, the value becomes a binding-info map
at that point (when `:tag` is actually populable) — not before.

`nil`-as-value (DA Alt 1) is rejected: it breaks the legal
`(if-let [b (get &env sym)] …)` idiom (present local reads as absent).

The DA's two correct points are **adopted**: (1) `&form`'s synthesized
`{:line :column}` meta is meander-sufficient (kept as-is); (2) the
`&form`/`&env` Values are built on the **runtime GC heap** (like the
existing `value_args` in `expandIfMacro`), not the analyzer arena, so
the VM compile path (F-012) sees stable Values.

## Alternatives considered

(Devil's-advocate fork output, verbatim.)

**Alt 1 — smallest-diff: `&env` value = nil, keys = raw Scope names.**
Better: honest that cljw has no LocalBinding; `nil` cannot be mistaken
for a binding. Breaks: same temp-key behaviour; `(get &env sym)` → nil
indistinguishable from absent (breaks `if-let` idiom). Verdict: worse
on the `get` idiom, not recommended.

**Alt 2 — finished-form-clean: `{:name :tag}` value + key-set fidelity
(filter gensym temps).** Better (per DA): forward-compat `:tag`; "fixes"
the temp leak. Breaks: the temp-leak "fix" is wrong — JVM includes temps
(verified above), so filtering them *causes* a divergence; `:tag` is
speculative (no type hints in Scope). Verdict: rejected on the verified
oracle behaviour + Reservation-as-bias.

**Alt 3 — wildcard: `&env` always `{}`, `&form` real, defer keys.**
Better: eliminates any temp-key question; `&form` lands uncoupled.
Breaks: `(contains? &env sym)` always false → **silently drops
slingshot's locals** (the named consumer), a permanent-no-op /
silent-semantics-drop (forbidden). Verdict: only viable as a labelled
PROVISIONAL, never finished form.

**DA recommendation:** Alt 2. **Main-loop decision (within F-NNN):**
neither the DA nor the survey verified the JVM `&env` key-set; the
oracle shows JVM *includes* destructure temps, which inverts Alt 2's
core premise. The finished form is therefore: `&env` keys = the full
Scope local set (matches JVM incl. temps), `&env` value = the local
symbol (the type-hint map is the documented upgrade when hints land,
not a speculative reservation now), `&form` = the DA-endorsed
synthesized-meta list on the runtime heap. This is more finished-form
than Alt 2 because it matches the *actual* clj behaviour rather than an
unverified assumption about it.
