# Differences between Clojure (JVM) and ClojureWasm

ClojureWasm (`cljw`) is a from-scratch Clojure runtime written in Zig. Its
north star is **behavioural equivalence with JVM Clojure on the
user-observable surface** (F-011): the same input produces the same value,
including which inputs are accepted versus rejected. The internals are free
to be Zig-native rather than a JVM port.

This page is the single-sheet answer to *"how does cljw differ from
Clojure?"* — in the spirit of ClojureScript's "Differences from Clojure".
It has two parts:

- **[Part 1 — Intentional divergences](#part-1--intentional-divergences)**:
  behaviours that differ *by design* and will not be "fixed". Each is
  anchored to a project invariant (an `F-NNN` fact or an ADR) and is locked
  by a regression test so it cannot drift silently. These are the
  `AD-NNN` rows of the machine-readable ledger
  [`.dev/accepted_divergences.yaml`](../.dev/accepted_divergences.yaml).
- **[Part 2 — Not yet implemented](#part-2--not-yet-implemented)**: surface
  that Clojure has and cljw does not *yet* (or, for a few JVM-only corners,
  ever) carry. These are tracked work items, not silent gaps.

If a behaviour is **not** on this page and differs from Clojure, treat it as
a bug, not a feature.

The single root cause behind most of Part 1 is **no JVM**: cljw has no
`java.lang.Class` hierarchy (a `TypeDescriptor` instead, ADR-0059), no
reproducible identity-hash address, and a single Zig-native numeric model
(F-005). Wherever Clojure's observable surface leaks one of those JVM
facts — a class FQCN, a `0xADDR`, an `f32`, a JVM exception class — cljw
substitutes its own honest surface and records the divergence here.

## Part 1 — Intentional divergences

By-design; the "why" below is the short form, the full rationale is in the
linked ledger entry. Examples are `cljw => … / clj => …`, clj-verified.

### Printing and representation

Opaque / identity-bearing values cannot be reproduced because clj's
`#object[Class 0xADDR …]` form embeds a JVM class FQCN and a
non-reproducible identity hash. cljw prints a stable, honest form instead.

| Behaviour                                 | Clojure (JVM)                                 | ClojureWasm                                 | AD             |
|-------------------------------------------|-----------------------------------------------|---------------------------------------------|----------------|
| Set / non-sorted-map print order          | hash-order (version-dependent)                | deterministic insert-derived order          | AD-001         |
| Opaque references (atom / fn-less / …)   | `#object[clojure.lang.Atom 0x… {…}]`        | `#<atom>`                                   | AD-002         |
| A namespace value (`*ns*`, `:ns` meta)    | `#object[clojure.lang.Namespace 0x… "user"]` | `#object[Namespace "user"]`                 | AD-010, AD-021 |
| A `PersistentQueue`                       | opaque `#object[…]` (no `print-method`)      | readable `#queue (1 2 3)` + `#queue` reader | AD-012         |
| A host object (`java.util.Random` …)     | `#object[java.util.Random 0x… …]`           | `#<java.util.Random>`                       | AD-020         |
| A callable (`fn` / `defmulti` / proto-fn) | `#object[user$boom__N 0xHASH "…@…"]`        | `#<user/boom>` (`#<fn>` if unnamed)         | AD-025         |

`(str *ns*)` / `(ns-name …)` and every value's behaviour stay clj-faithful;
only the `pr`/`prn` identity rendering diverges. `str` and `pr` of a callable
render identically (matching clj).

### Numeric tower (F-005: a single Zig-native double + one arbitrary-precision integer)

| Behaviour                        | Clojure (JVM)                                                        | ClojureWasm                               | AD     |
|----------------------------------|----------------------------------------------------------------------|-------------------------------------------|--------|
| `Long` overflow past i64         | `+` / `*` **throw** `ArithmeticException` (only `+'` / `*'` promote) | auto-promotes to BigInt                   | AD-008 |
| `(float x)`                      | yields an f32                                                        | yields an f64 (no f32 representation)     | AD-004 |
| Subnormal double shortest-render | `4.9E-324`                                                           | `5.0E-324` (same f64 bit pattern)         | AD-005 |
| `(biginteger 5)`                 | `5` of class `java.math.BigInteger`                                  | `5N` of class `BigInt` (one big-int type) | AD-016 |

`(* Long/MAX_VALUE 2)` => `18446744073709551614N` (cljw) vs a throw (clj) is
the one accept/reject difference; the rest are cosmetic or rare-edge. cljw
collapses clj's `BigInt`/`BigInteger` into one `.big_int`, so every op on a
`biginteger` already returns `BigInt` in both runtimes (`(class (+ (biginteger
5) 1))` => `BigInt` both).

### No JVM class hierarchy & host interop (ADR-0059)

cljw carries a `TypeDescriptor`, not a `java.lang.Class`; its collections are
native types, not `java.util.*` implementors; and it has one value-hash, not
the JVM's `hashCode`/`hasheq` split.

| Behaviour                                                        | Clojure (JVM)                                    | ClojureWasm                                                       | AD     |
|------------------------------------------------------------------|--------------------------------------------------|-------------------------------------------------------------------|--------|
| `(class x)` / `(type x)`                                         | `java.lang.Long` (FQCN)                          | `Long` (simple name)                                              | AD-003 |
| Error rendering                                                  | `ArithmeticException …` (JVM exception class)   | `[arithmetic_error] …` (catalog Kind); same accept/reject        | AD-007 |
| Stack trace frames                                               | includes `clojure.core` machinery                | user frames only (stdlib + host elided uniformly)                 | AD-024 |
| `clojure.stacktrace` per-frame printing                          | `Class.method (file:line)` frames                | `[no stack trace available]` marker (cause-chain + message work)  | AD-029 |
| `hash` / `.hashCode` values                                      | JVM/Murmur3 values                               | cljw-native values (intra-cljw consistent)                        | AD-009 |
| `APersistentMap/mapHash` vs `/mapHasheq`                         | distinct (additive `hashCode` vs murmur)         | both = the single `(hash m)` content hash                         | AD-028 |
| `ns-interns`/`ns-publics` of `clojure.core`                      | includes `reduce`, `+`, …                       | omits the `rt`-referred primitives (`ns-map` includes them)       | AD-011 |
| `(class (object-array 0))` + typed arrays                        | `[Ljava.lang.Object;`, `aset` type-checks        | `array`; type-erased `[]Value`, `^"[B"` hints advisory            | AD-019 |
| Unresolved `clojure.lang.*` / `.asm.*` ref                       | resolves to the JVM class                        | namespace LOADS; the ref errors only if evaluated (call-time)     | AD-022 |
| `(extend-protocol P java.util.Map …)`                           | covers all clj maps (a map IS a `java.util.Map`) | LOAD-ONLY no-op; a map receiver falls to `Object`                 | AD-023 |
| `java.util.Map` methods under a `clojure.lang.*` deftype section | dispatch (the interfaces extend the java ones)   | accepted-and-dropped; a later `(.iterator x)` is method-not-found | AD-027 |

`(class 5)` => `Long`, `(quot 10 0)` rejects in both (only the message format
differs), and `(= (hash "abc") (.hashCode "abc"))` holds *within* cljw — the
HAMT key contract that actually matters. Integers happen to match clj's hash
value; strings/keywords differ. Java arrays, `clojure.lang.*` refs, and
`java.util.*` protocol targets all resolve to an **explicit error or a
declared no-op**, never a silent success.

### deftype mutable fields & type hints (F-004 uniform Value)

cljw stores every deftype field as one 8-byte NaN-boxed Value, so the JVM's
primitive-slot machinery has nothing to constrain.

| Behaviour                                        | Clojure (JVM)                               | ClojureWasm                                                      | AD     |
|--------------------------------------------------|---------------------------------------------|------------------------------------------------------------------|--------|
| `^long` / `^"[B"` on a mutable field             | primitive slot; `set!` of a non-prim throws | hint parsed-and-ignored (advisory)                               | AD-017 |
| `:volatile-mutable` vs `:unsynchronized-mutable` | differ in cross-thread visibility           | unified to one in-place write (single-thread; revisit Phase 15+) | AD-018 |

### Concurrency & vars

| Behaviour                                      | Clojure (JVM)                            | ClojureWasm                              | AD     |
|------------------------------------------------|------------------------------------------|------------------------------------------|--------|
| STM conflict resolution                        | `barge` (older txn preempts a younger)   | retry-only; identical committed result   | AD-013 |
| An ESCAPED `with-local-vars` var, deref'd late | `#object[clojure.lang.Var$Unbound 0x…]` | `nil` (no Unbound sentinel; memory-safe) | AD-015 |

STM's committed state is identical (4 threads × 100 `(dosync (alter c inc))`
=> 400 in both); only contention scheduling — unobservable in the result —
differs. Locking and `with-local-vars` are clj-faithful *inside* their normal
use; only the literal-as-lock and escaped-var anti-patterns diverge.

### Reader & security

| Behaviour                   | Clojure (JVM)                               | ClojureWasm                                      | AD     |
|-----------------------------|---------------------------------------------|--------------------------------------------------|--------|
| `(read-string "#=(+ 1 2)")` | `3` (`*read-eval*` true → the form is run) | error `No reader function for tag =` (eval-free) | AD-026 |

cljw's `read-string` is the same eval-free path as `clojure.edn/read-string`:
reading data never executes code (secure-by-default; the JVM read-eval footgun
is removed). Evaluation is reached only via an explicit `eval` on read data.

## Part 2 — Not yet implemented

Gaps relative to Clojure, tracked as work items — a missing Tier A/B/C form
raises an explicit error rather than quietly mis-behaving.

### Concurrency tail

The concurrency surface is complete (`future` / `promise` / `delay`, full STM
`dosync` / `alter` / `commute` / `ensure` / `ref-set`, `atom` with CAS, `agent`
with error modes — `agent-error` / `restart-agent` / `set-error-handler!` /
`agent-errors` / `clear-agent-errors` — reference **watches** — `add-watch` /
`remove-watch` fire uniformly across atoms, agents, refs and vars —
`await` / `await-for`, `shutdown-agents`, `locking`, `volatile`, real threads,
`Thread/sleep`). The lower-frequency tail:

- **validators** are wired on **atoms and agents** (`set-validator!` /
  `get-validator`, and the `(atom v :validator f)` / `(agent v :validator f)`
  ctor option); `ref` and `var` validators are not yet wired (`set-validator!`
  on a ref/var errors "expected atom or agent")
- the **`ref` constructor option map** — `(ref v :validator f)` /
  `:min-history` / `:max-history` — is not accepted (clj's `ref` does); pair it
  with the validator-on-refs gap above

### JVM-only surface (deferred or permanently out of scope)

Because cljw is no-JVM, the following Clojure forms that exist only to
bridge to the JVM are not part of the runtime (Tier C/D):

- `gen-class`, `gen-interface`, `compile` (AOT to `.class` files)
- deep `proxy` (subclassing arbitrary Java classes), `bean`
- reflection over, and `import` of, arbitrary Java classes

cljw provides its own host-class surface (a curated set, see
[`data/compat_tiers.yaml`](../data/compat_tiers.yaml)) rather than open JVM interop.
Note that Java *arrays* are implemented (type-erased — see AD-019), as is
`with-local-vars` (AD-015); they are no longer in this list.

## How to read this page

A divergence listed in **Part 1** is *designed*: it derives from a project
invariant and is pinned by a regression test, so it reads as a deliberate
choice rather than a defect. A gap listed in **Part 2** is *scheduled*: it
is on the roadmap (or, for the JVM-only corners, intentionally excluded).
Anything not on this page that still differs from Clojure is a bug —
please report it.

For the authoritative, machine-readable form of Part 1, see
[`.dev/accepted_divergences.yaml`](../.dev/accepted_divergences.yaml); each
`AD-NNN` there carries its `derives_from` invariant, its clj-verified
`example`, and its `pin` test.
