# ADR-0073 — Reader infrastructure for EDN tagged literals + data readers

- Status: Accepted
- Date: 2026-06-02
- Supersedes: none
- Refs: D-200 (this decision's debt entry), D-075 (reader-metadata
  `^:dynamic` — NOT a blocker here, see Decision), ADR-0036 (dual-backend
  parity), F-002 / F-009. A separate later ADR owns the `#uuid`/`#inst`
  VALUE-TYPE decision (out of scope here).

## Context

cljw's reader parses Clojure/EDN syntax but has **no tagged-literal
(`#tag form`) support**: `(read-string "#foo 5")` fails at the tokenizer
(`#`+letter → `.invalid`). `clojure.core/read-string` and
`clojure.edn/read-string` are the SAME 1-arity primitive
(`lang/primitive/edn.zig::readStringFn`) running `reader.readOne` →
`analyzer.formToValue`. The 2-arity `(read-string opts s)` with
`:readers`/`:default`/`:eof` is unimplemented. The data-lift SSOT is
`formToValue(rt, form)` (`analyzer.zig:798`), called from ~8 sites (quote,
meta, collection elements, read-string) with signature `(rt, form)`.

This ADR is for the **reusable reader infra only**. The `#uuid`/`#inst`
value-type decision (cljw has UUID-as-36-char-STRING, no distinct UUID
type; `Value.Tag.tagged_literal = 24` reserved-but-unused) is a separate
later ADR. The seam holds **provided the infra raises on an unknown tag**
(not a silent placeholder value) — confirmed correct below.

## Decision (DA Alt 2 — finished-form-clean over the existing dynamic-var stack)

1. **`FormData.tagged = struct { tag: SymbolRef, form: *const Form }`** —
   SymbolRef (not a bare string) so a qualified record-tag `#my.ns/Rec`
   reads cleanly later (DIVERGENCE from cljw-v0's bare-string tag).
2. **Tokenizer**: a `.tagged` marker token in `readDispatch`'s else-branch
   when `#` is followed by a symbol-start char; otherwise `.invalid`.
3. **Reader `readTagged`**: read the tag symbol token, then the next form;
   build `.tagged` (mirrors `readVarQuote`'s marker-then-follow shape).
4. **`formToValue`'s `.tagged` arm is the dispatch home** — NOT analyzer
   call-rewrite (cljw-v0), NOT dynamic-var-deref-mid-tokenize (JVM
   LispReader). `read-string` is pure data, and `formToValue` is the
   pure-data SSOT, so the data-reader application belongs there. The arm
   resolves the tag against the **`*data-readers*` dynamic Var**
   (`findBinding(var) orelse var.root`), the SAME threadlocal `BindingFrame`
   chain `(binding …)` already drives. Found → recursively lift the inner
   form to a Value, then `vtable.callFn` the reader fn with it. Not found →
   consult `*default-data-reader-fn*`; still nothing → raise
   `reader_tag_unknown` ("No reader function for tag {tag}") — clj parity,
   NOT a silent `tagged-literal` fallback.
5. **Table home = real `^:dynamic` Vars, not a Runtime mutable field.**
   `clojure.core/*data-readers*` (root `{}`) + `*default-data-reader-fn*`
   (root `nil`) are interned at bootstrap with `flags.dynamic = true`
   (mirroring `cljw.error/*error-context*`, `runtime/error/context.zig:54`);
   their `*Var` pointers are cached as two immutable-after-bootstrap `?*Var`
   fields on `Runtime` so the Layer-1 `formToValue` can reach them without
   an Env. `clojure.edn/read-string` 2-arity `[opts s]` installs
   `:readers`/`:default` by **pushing a `BindingFrame`** (`defer popFrame()`)
   over those Vars — exactly `(binding [*data-readers* …] …)`'s mechanism.

   This corrects the initial draft, which proposed a mutable
   `rt.data_readers` field + bespoke save/restore. That was the
   **Smallest-diff bias smell**: cljw already ships the full dynamic-var
   `BindingFrame` stack (`env.zig` `pushFrame`/`popFrame`/`findBinding`,
   `Var.deref` consulting the chain). The cited blocker (D-075,
   `^:dynamic` reader-metadata) is irrelevant — bootstrap interns dynamic
   Vars directly (`env.zig:560`). The field+save/restore is also a
   nested-read re-entrancy hazard (`#foo "#bar 5"`); a BindingFrame is
   re-entrancy-safe by construction and makes user
   `(binding [*data-readers* …] (read-string …))` work for free (clj
   parity the field would silently drop).

6. **Unknown tag raises during the infra cycle**: `#uuid`/`#inst` raise
   "No reader function for tag uuid/inst" until the value-type ADR lands.
   Honest transient state (a `reader_tag_unknown` raise is not a lie / not
   a no-op), tracked by the still-open D-200 row.

## Consequences

- `(read-string "#foo 5")` → `reader_tag_unknown` (clj parity).
- `(clojure.edn/read-string {:readers {'foo …}} "#foo 5")` applies the user
  reader; `:default` handles unmatched tags; `:eof` honoured.
- `(binding [*data-readers* {'foo …}] (read-string "#foo 5"))` works for
  free — same Var, same frame chain.
- `Value.Tag.tagged_literal = 24` stays reserved-unused; the later value-type
  ADR + `clojure.core/tagged-literal`/`tagged-literal?` activate it (the
  point at which `*default-data-reader-fn*` can default to `tagged-literal`,
  clj's richer behaviour). Reserving-without-using now is a forward pointer,
  not Reservation-as-bias (we do not consult it).
- DIVERGENCE (Guard 2): tag dispatch at `formToValue` time over a dynamic
  Var, vs cljw-v0's analyzer call-rewrite and JVM's mid-read deref.

## Affected files

- `src/eval/form.zig` (`FormData.tagged` + `typeName`/`format` arms).
- `src/eval/tokenizer.zig` (`.tagged` in `readDispatch` else-branch + `TokenKind`).
- `src/eval/reader.zig` (`readTagged` + `readForm` arm).
- `src/eval/analyzer/analyzer.zig` (`.tagged` arm in `formToValue` + the
  `valueToForm` inverse if present).
- `src/runtime/runtime.zig` (two `?*Var` cache fields).
- `src/runtime/error/catalog.zig` (`reader_tag_unknown` Code).
- bootstrap (intern `*data-readers*` + `*default-data-reader-fn*` dynamic Vars).
- `src/lang/primitive/edn.zig` (2-arity `[opts s]` + BindingFrame install).
- e2e `test/e2e/phase14_tagged_literal.sh` (new) + a diff_test case.

The `binding`/`findBinding`/`pushFrame` machinery is reused unchanged.

## Alternatives considered

(Verbatim from the mandatory Devil's-advocate subagent, fresh context,
within the F-NNN envelope. The Decision adopts the DA's Alt 2.)

**Leading finding (no F-NNN violation):** None of the three alternatives
requires violating an F-NNN. The finished-form-clean shape is fully
buildable today (Alt 2). The draft's central premise ("a Runtime field +
save/restore models clj's dynamic `*data-readers*` without needing
`^:dynamic` infra") is **factually wrong about the codebase**: cljw already
ships a complete threadlocal dynamic-var stack (`env.zig`
`BindingFrame`/`pushFrame`/`popFrame`/`findBinding`, `Var.flags.dynamic`,
`Var.deref` consulting the chain, plus the `binding` special form with
`binding_target_not_dynamic` enforcement). The draft proposes hand-rolling a
parallel, weaker save/restore for a problem the project already solved
generally — the **Smallest-diff bias smell** dressed as pragmatism.

### Alternative 1 — Smallest-diff: bare-string tag + explicit `formToValue` context param, no table threading

`FormData.tagged = struct { tag: []const u8, form: *const Form }` (bare
string). `formToValue` gains a `LiftCtx` param (`readers`/`default_fn`)
threaded through ~8 call sites + recursive helpers. edn 2-arity builds the
ctx; 1-arity passes `.{}`. No Runtime field, no save/restore, no dynamic var.

**Better:** No hidden re-entrancy hazard — an explicit context param is
re-entrancy-safe by construction (each frame owns its ctx), unlike the
draft's mutated shared field which a nested `read-string` (`#foo "#bar 5"`)
or an error long-jump can corrupt. Makes "lifting depends on a reader table"
visible in the signature.

**Breaks:** Ripple across ~8 call sites + every recursive helper
(`vector/map/set/listFormToValue`, `^meta` recursion, `analyzeQuote`
callback). F-002 says ripple size is not a reason to reject — but it is when
a cleaner shape exists, and cljw already has the dynamic-var mechanism that
makes the ripple unnecessary. Bare-string tag forecloses `#my.ns/Rec`
record-tag readiness. Threading an eval-ish table through `formToValue`
blurs the "pure data lift" character.

### Alternative 2 — Finished-form-clean (RECOMMENDED): SymbolRef tag + real `*data-readers*` / `*default-data-reader-fn*` dynamic Vars over the existing BindingFrame stack

(1) `FormData.tagged = struct { tag: SymbolRef, form: *const Form }`.
(2) Tokenizer `.tagged` + reader `readTagged` — same as draft (clean).
(3) `formToValue`'s `.tagged` arm looks the tag up by `env.findBinding` on
the `*data-readers*` Var (the same threadlocal chain `binding` drives),
falling back to the Var root. `*data-readers*`/`*default-data-reader-fn*`
are interned at bootstrap as `^:dynamic` Vars (root `{}` / `nil`, mirroring
core.clj). Found → lift inner form, `vtable.callFn` the reader fn; not found
→ `*default-data-reader-fn*`; nothing → raise `reader_tag_unknown`.
(4) edn 2-arity installs `:readers`/`:default` by pushing a `BindingFrame`
binding those Vars for the read's dynamic extent (`defer popFrame()`).

**Reaching `env` from `formToValue`:** `findBinding(v: *const Var)` is a free
function on the threadlocal `current_frame` (env.zig:202) — it needs the
*Var pointer*, not an Env. Cache the two Var pointers on the Runtime (two
`?*Var`, resolved once at bootstrap, immutable after) — a smaller,
immutable footprint than the draft's mutable map field. So `formToValue`
reads `findBinding(rt.data_readers_var.?) orelse rt.data_readers_var.?.root`.
No signature ripple, no mutable shared state.

**Better:** Re-entrancy-safe for free (nested reads push/pop their own
frames; error-unwind still pops via `defer`). It IS clj's model, not a model
"of" it — `binding` over a `^:dynamic` Var is already wired; D-075 is about
reader-metadata `^:dynamic` (attaching `:dynamic` via `^`), irrelevant here
since bootstrap interns these two Vars with `flags.dynamic = true` directly
(env.zig:560/605 precedent). `(binding [*data-readers* …] (read-string …))`
works at the surface with zero extra code — falls out of using the real Var;
the draft's field would silently ignore a user `binding`, a latent parity
bug. SymbolRef gives record-tag readiness.

**Breaks/costs:** Bootstrap interns two dynamic Vars + caches pointers (two
`?*Var` fields) — slightly more setup than one field, but immutable after
bootstrap vs mutated-per-read. `formToValue` (Layer 1) calling `findBinding`
(Layer 0 free fn on a Layer-0 Var) is clean (eval→runtime allowed; vtable
only needed for `callFn` on the reader fn, which the draft also needs). No
layering violation.

### Alternative 3 — Wildcard: defer the table; `.tagged` arm constructs a `tagged-literal` (Tag-24) Value, apply readers in a `clojure.core/read-string` layer

`formToValue`'s `.tagged` arm builds a `TaggedLiteral` Value (activating
reserved Tag-24) carrying `{tag-symbol, lifted-form-value}`, full stop.
Data-reader application moves up into a `clojure.core/read-string` peer that
walks the lifted structure applying `*data-readers*`. Unknown tag with no
reader → the `TaggedLiteral` survives as data (clj's `*default-data-reader-fn*`
= `tagged-literal` is literally this).

**Better:** Resolves the (c)/(d) tension — clj's default
`*default-data-reader-fn*` + `tagged-literal`/`tagged-literal?` (core.clj
L7961) mean the TaggedLiteral value is a first-class part of the reader
contract, so splitting "infra" from "Tag-24 value type" may be a false seam.
Keeps `formToValue` a pure lift (no fn-calling during lift).

**Breaks:** Diverges from clj on `read-string` unknown-tag (no opts, nil
default-fn) which *raises* — Alt 3 must replicate the raise in the apply
layer, so it doesn't escape `reader_tag_unknown`, only relocates it. Pulls
Tag-24 value-type design into scope (exactly what the seam defers);
activating a NaN-box slot is F-004-adjacent — doing it as a side effect of
reader infra is the **Reservation-as-bias inverse** (using the slot because
it's there). More layers (Zig reader → Clojure apply) for a feature whose
finished form (Alt 2) is a single dispatch arm.

### Recommendation (DA)

**Adopt Alternative 2.** Finished-form-clean *and* lands on infra the
project already built+tested (BindingFrame stack + `binding`), so the
"bigger diff" the draft feared is actually smaller and more correct than the
draft's bespoke save/restore. Per F-002, recommend it regardless of size;
here finished-form and diff size agree. Concretely: (1) drop the
`rt.data_readers` field + save/restore → two `^:dynamic` Vars + cached
`?*Var` pointers, edn installs via BindingFrame; (2) keep SymbolRef tag;
(3) keep `reader_tag_unknown` raise. On the seam (d): infra-ADR vs
value-type-ADR split is defensible **only if the infra ADR commits
unknown-tag = raise** (not a placeholder value) — which it does.
