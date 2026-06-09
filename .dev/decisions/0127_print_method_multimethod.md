# ADR-0127 — `print-method` is a real multimethod with a native default, consulted by the pr path via a dirty-flag fast path

- **Status**: Proposed → Accepted (2026-06-10)
- **Driven by**: D-370 — loading `flatland.ordered.set` fails at set.clj:153
  `(defmethod print-method OrderedSet [o w] (print-method (seq o) w))` →
  `Unable to resolve symbol: 'print-method'`. cljw has no `print-method` var;
  libraries routinely extend it to customise how their types print (F-010/F-013
  library-driven discovery; high leverage — unblocks many libs, not just ordered).
- **Relates to**: F-011 (behavioural equivalence vs `clj`, incl. nested
  per-element recursion; commonization over effort), F-009 (impl-neutral writer
  handle in `runtime/`, thin surfaces above — ADR-0029), F-002 (finished-form
  wins; cycle/diff size is not a constraint), F-013 (definition-derived: cover the
  whole print-method recursion contract, not just the direct-print case),
  F-004 (2026-06-05 revision: writers are `host_instance` B13, no new NaN-box
  slot), ADR-0059 / AD-003 (no-JVM: a "writer" is not a real `java.io.Writer`
  class; `(class w)` is a simple name), ADR-0088 (cached-Var pattern,
  `initPrintLimitVars`), D-238 (bindable `*out*` — the owning slice for a general
  Writer/`*out*` redirect), D-369 (transient dispatch — sibling off-critical-path
  follow-up).

## Context

`clj` routes ALL printing through `print-method`, a multimethod dispatching on
`(class x)`, with default methods per type. A user `(defmethod print-method T
[o w] …)` overrides T's printing, and the collection printers recurse by calling
`print-method` on every element — so an override fires even when its type appears
NESTED inside a native collection.

cljw prints natively: `pr`/`prn`/`pr-str`/`print` are native primitives
(`src/lang/primitive/core.zig`) driving `src/runtime/print.zig` with a Zig
`w: *std.Io.Writer` (NOT a Clojure Value). There is no `print-method` var and no
`java.io.Writer` Value surface. cljw's multimethod stack
(`src/runtime/multimethod.zig`) is complete and already dispatches on deftype
types; `(class x)` returns interned `.type_descriptor` Values. `writeStrValue`
already carries the "consult an override, else native" idiom twice (`Object/
toString` for typed_instance, `host_instance` via `rt.vtable.callFn`).

Two load-bearing choices: (A) how the writer `w` passed to a user method is
represented (the user threads it back via `(print-method child w)`); (B) whether
the native pr path consults `print-method` per nested element (clj parity) and
how, given the recursive `printValue` is a pure `(w, v)` walk with no `rt`/`env`.

## Decision

**`print-method` is a real `defmulti` in `core.clj`** dispatching on `(class x)`,
whose `:default` delegates to a native `__print-method-default` primitive (the
existing native printer) — NOT ~40 re-derived clj default methods. The native pr
entry points consult it.

**Choice A — writer representation = A2: a `host_instance` writer handle**
wrapping the active `*std.Io.Writer`. `state[0]` holds the writer pointer (a raw
`usize`, non-GC — no `host_trace` hook); its descriptor registers `write`/
`append`/`flush` methods that unwrap `state[0]` and call straight through. The
consult mints this handle around the CURRENT sink (`out_capture` if set, else
`rt.stdout`), so `with-out-str`/`*out*` redirection works automatically. `(class
w)` is a clean simple name (no `java.io.Writer` FQCN — AD-003). This is the
F-004-declared finished form (writers = `host_instance` B13). **Invariant**: the
handle is single-print-scoped — `state[0]` is nulled after the print completes so
a stale `(.write w)` after the pr returns raises rather than reads a dangling
stack pointer.

**Choice B — recursion gating = B2 with single-walk (b-ii)**: a dirty flag
`any_print_method_override` (set by `__add_method!` on the print-method MultiFn)
gates the consult. Flag false (99% + bootstrap) ⇒ pure native `printValue`, zero
clojure calls. Flag true ⇒ `printValue` carries a nullable `rt`/`env` (null on the
pure path) and the collection arms re-enter the per-element consult — ONE walk,
not two parallel collection-walk forms (F-011 commonization over the effort of
threading the signature). Matches clj's per-element recursion (a nested override
fires). **Recursion guard**: `__print-method-default` renders via `printValue`
directly, BYPASSING the consult on the SAME value; only child elements re-enter
the consult — terminating because each child lands on either an override or the
native default. The print-method Var is cached (ADR-0088 `initPrintLimitVars`
pattern), nullable-until-installed so early-bootstrap `pr` is safe.

`print-dup` is DEFERRED (off the flatland.ordered critical path; `*print-dup*`
moot per D-222). The general bindable-`*out*`/Writer-protocol shape is D-238's
slice — the A2 handle is the down-payment value type that future `*out*` binds
to (so A2 shrinks, not enlarges, that rewrite; F-003 defer-to-owner).

## Consequences

- A `print-method` multimethod + `__print-method-default` primitive land; pr/prn/
  print/pr-str consult it behind the dirty flag.
- A writer `host_instance` type + descriptor (`write`/`append`/`flush`) lands in
  `runtime/` (neutral); `(.write w s)` / `(.append w s)` work in a user method.
- `printValue` gains nullable `rt`/`env` params (the single-walk B2(b-ii) cost) —
  every printer signature is touched; the pure fast path passes null.
- Lifetime invariant: the writer handle is single-print-scoped (nulled after);
  documented + defended.
- Bootstrap: the print-method Var is cached nullable; pr before it installs takes
  the native path.
- Perf: zero overhead when no override is registered (dirty flag); when set, one
  cached identity-probe `getMethodNonDefault` per element (acceptable, deferred
  per `optimization_deferred_until_15_libs`).
- e2e + corpus: a user `(defmethod print-method T …)` overrides direct + nested
  printing, matching clj; `with-out-str` over an override.

## Alternatives considered (Devil's-advocate fork, verbatim)

> Fresh-context `general-purpose` DA-fork (agent abba199f8b683d98c), briefed with
> the F-NNN envelope. Reflected verbatim.

Grounding facts shaping every ruling: `(class x)` on a `host_instance` returns its
descriptor's interned `.type_descriptor` — a `host_instance` writer is
dispatchable and `(class)`es as a simple name (`Writer`/`StringWriter`), NOT a
`java.io.Writer` FQCN (AD-003). `host_instance` is the proven home for a Value
wrapping a non-Value handle (File holds a path; the GC-ROOT §H raw-u64 pattern
exists). `writeStrValue` already has the consult-else-native idiom twice;
`with-out-str` is a threadlocal `out_capture` sink, not a Value. The native
printer splits cleanly: `printResult`/`writeStrValue` carry `rt`+`env`; the
recursive `printValue` switch is pure `(w, v)`. F-004's 2026-06-05 revision
already designates writers as `host_instance` B13 (no new slot).

**CHOICE A — writer-value `w`:**
- **A1 — a `java.io.Writer` host-surface Value** (`runtime/java/io/Writer.zig`).
  Better: matches the `^java.io.Writer` hint; reuses host_instance dispatch;
  discoverable under ADR-0029. Breaks: exposing `java.io.Writer` as a CLASS is
  AD-003-dishonest (cljw has no java.io; `(class w)` is a simple name anyway), and
  the user almost never inspects `w`'s class — they thread it back / `.write` —
  so the java naming is surface theater wrapping nothing cljw-original (F-009 has
  no neutral impl to wrap).
- **A2 — a dedicated `host_instance` writer handle wrapping the active
  `*std.Io.Writer`** (recommended). Better: the honest finished form; `state[0]`
  = the writer pointer (raw usize, no GC trace), descriptor `write`/`append`/
  `flush` unwrap + call through (File.zig METHODS pattern 1:1); the consult mints
  the handle around the current sink so `with-out-str`/`*out*` work; `(class w)`
  is a clean simple name. Sits in F-004 (B13 host_instance), F-009 (neutral impl),
  ADR-0059 (no fake class). Cost: LIFETIME — the `*Writer` is stack-scoped; a
  user stashing `w` and reading after the pr reads a dangling pointer. Mitigation:
  single-print-scoped handle; null `state[0]` after the print so a stale write
  raises. Minor: a host_instance alloc per top-level pr (gated by the dirty flag).
- **A3 — `w` is the `*out*` sink / a cljw-native Writer protocol** (wildcard).
  Better: most Clojure-spirit; user could pass their own Writer; subsumes
  `with-out-str`. Breaks: over-reach (excessive-skeleton smell) — D-370's driver
  is "let ordered customise set printing"; a bindable-`*out*`-as-writer-Var is
  D-238's deferred slice; introduces a protocol nobody on the critical path
  implements; pre-empts a structural decision F-003 assigns to its owner.
- **Ruling A → A2.** Already the F-004-declared finished form. A1's java-class
  naming is AD-003 theater buying nothing on the thread-back/`.write` call
  pattern; F-009 has no neutral impl for it to wrap. A3 is the right GENERAL
  `*out*` shape but out of scope + collides with deferred D-238 (excessive
  skeleton). Cycle size is NOT why A1 loses (F-002) — A1 loses on honesty +
  wrapper-around-nothing. The lifetime invariant is a Consequence, not a downgrade
  reason. Follow-on (debt, F-003): when D-238's bindable-`*out*` lands, the A2
  handle is exactly the value type `*out*` binds to — A2 is the down-payment on
  A3, shrinking that rewrite.

**CHOICE B — per-element recursion gating** (clj fact: clj's collection printers
call `print-method` on EVERY element, so an override on a nested element DOES fire
— the common case for a collection-like custom type):
- **B1 — consult only for typed_instance; natives always native.** Better:
  cheapest; zero native consult. Breaks: parity hole that matters — a user can
  override a NATIVE type's print, and even a custom-type override fails to fire
  when nested inside a native collection (the pure `printValue` has no consult).
  Fails the flatland.ordered nested-in-larger-structure case. Ad-hoc-pass smell /
  F-013 violation (direct probe passes, definitional recursion uncovered).
- **B2 — consult every value when ANY override registered (dirty flag), else pure
  native** (recommended). Better: matches clj's per-element recursion exactly when
  an override exists, zero cost otherwise (flag gates it). One consult mechanism,
  uniform, parity-correct (F-011). Cost/tension: `printValue` is pure `(w, v)` but
  the consult needs `rt`/`env`. Two ways: (b-i) an rt/env-carrying collection-
  printer variant on the flag-true path only (duplicates the collection walk —
  F-011 frowns); (b-ii) `printValue` itself carries nullable `rt`/`env`, null on
  the pure path (ONE walk, F-011-clean, touches every printer signature). F-011
  outranks effort ⇒ (b-ii). Perf when flag true: one cached identity probe per
  element (bounded). 
- **B3 — pr IS print-method always; native default per type** (wildcard). Better:
  purest, closest to clj's model. Breaks: bootstrap (the MultiFn must exist before
  the first load-time pr — the nullable cached var is removed), perf (every value
  pays a multimethod resolve + clojure-fn call, no fast path — the shape the
  survey rejects), infinite recursion (the default re-enters print-method on the
  same value while consulting children — a fragile invariant the dirty-flag design
  sidesteps because flag-false is purely native).
- **Ruling B → B2 (b-ii single-walk).** B1 fails the driver (nested override) +
  is the Ad-hoc-pass smell. B3 is model-pure but reintroduces the bootstrap
  hazard, kills print-path perf, makes the recursion invariant fragile. B2 is the
  only option matching clj per-element recursion AND keeping zero overhead + safe
  bootstrap via the dirty flag. Within B2, pick ONE walk ((b-ii) nullable rt/env),
  NOT two ((b-i)) — cycle/diff size is not a valid reason for the duplicated form
  (Cycle-budget-defer smell). Recursion guard (ADR invariant): the native default
  renders via `printValue` DIRECTLY, bypassing the consult on the same value; only
  children re-enter.

**Leading entry — F-NNN:** No amendment required. A2 + B2 sit inside the envelope
and are in two places the DECLARED finished form: A2 is F-004-declared
(host_instance B13); A2 + B2 honor AD-003 (no java.io.Writer class), F-009
(neutral impl), F-011 (one commonized per-element consult, parity-verified). The
one finding surfaced (not a halt): A1's `java.io.Writer`-as-class would lean
AGAINST AD-003 — a reason to reject A1 (done), not to amend AD-003. A future
`(instance? java.io.Writer w)` truth is a separate host-supertype-marker decision
(`host_interfaces.yaml`, ADR-0102) attachable to the A2 handle's descriptor
without changing A2.

**Net:** A2 (host_instance writer handle) + B2(b-ii) (dirty-flag per-element
consult, single walk), native default bypasses the consult on the same value, the
writer handle single-print-scoped with a defended stale-write invariant.
