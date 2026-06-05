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

## Part 1 — Intentional divergences

These are by-design. The "why" in each row is the short form; the full
rationale lives in the linked ledger entry.

### Printing and representation

| Behaviour                                     | Clojure (JVM)                                 | ClojureWasm                                                 | Why                                                                                      |
|-----------------------------------------------|-----------------------------------------------|-------------------------------------------------------------|------------------------------------------------------------------------------------------|
| Set / non-sorted-map print order              | hash-order (version-dependent)                | deterministic insert-derived order                          | Order is not part of unordered-collection value semantics; the values are `=`. (AD-001)  |
| Opaque references (atom / fn / volatile / …) | `#object[clojure.lang.Atom 0x… {…}]`        | `#<atom>`                                                   | The JVM form embeds a non-reproducible identity hash + FQCN. (AD-002)                    |
| A namespace value                             | `#object[clojure.lang.Namespace 0x… "user"]` | `#object[Namespace "user"]`                                 | No JVM class FQN, no identity-hash address. `(str *ns*)` still yields `"user"`. (AD-010) |
| A `PersistentQueue`                           | opaque `#object[…]` (no `print-method`)      | readable `#queue (1 2 3)` + a matching `#queue` data-reader | cljw's form round-trips as EDN; clj's does not. (AD-012)                                 |

### Numeric tower

| Behaviour                           | Clojure (JVM)                                                        | ClojureWasm                           | Why                                                                               |
|-------------------------------------|----------------------------------------------------------------------|---------------------------------------|-----------------------------------------------------------------------------------|
| `Long` arithmetic overflow past i64 | `+` / `*` **throw** `ArithmeticException` (only `+'` / `*'` promote) | auto-promotes to BigInt               | F-005 chose silent auto-promotion as the numeric-tower surface. (AD-008)          |
| `(float x)`                         | yields an f32                                                        | yields an f64 (no f32 representation) | F-005 fixes a single internal double. (AD-004)                                    |
| Subnormal double shortest-render    | `4.9E-324`                                                           | `5.0E-324` (same f64 bit pattern)     | Cosmetic shortest-round-trip rendering only; the value is bit-identical. (AD-005) |
| `Double/parseDouble` rare grammar   | accepts hex-float `0x1p4`, lower-case `inf`/`nan`, trailing `d`/`f`  | rejects those rare forms              | Rare-edge grammar out of scope; common decimal path is at parity. (AD-006)        |

### No JVM class hierarchy

cljw has no `java.lang.Class` hierarchy — it carries a `TypeDescriptor`
instead (ADR-0059). Consequences:

| Behaviour                                     | Clojure (JVM)                                  | ClojureWasm                                                                                    | Why                                                                                                                                                 |
|-----------------------------------------------|------------------------------------------------|------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------|
| `(class x)` / `(type x)`                      | `java.lang.Long` (FQCN)                        | `Long` (simple name)                                                                           | No JVM Class; the simple name is the cljw surface. (AD-003)                                                                                         |
| Error rendering                               | `ArithmeticException …` (JVM exception class) | `[arithmetic_error] …` (catalog Kind)                                                         | No JVM exception hierarchy. **Both runtimes reject the same inputs** — only the message format differs. (AD-007)                                   |
| `hash` / `.hashCode` values                   | JVM/Murmur3 values                             | cljw-native values (intra-cljw consistent)                                                     | Hash values are explicitly impl-specific in Clojure; equal values still hash equal. Integers happen to match clj. (AD-009)                          |
| `ns-interns` / `ns-publics` of `clojure.core` | includes `reduce`, `+`, …                     | omits the `rt`-referred primitives (they live in the `rt` ns and are *referred*, not interned) | ADR-0033 core-surface split. Only differs when introspecting `clojure.core` itself; user namespaces are exact, and `ns-map` includes them. (AD-011) |

### Concurrency

| Behaviour                                                                       | Clojure (JVM)                                                | ClojureWasm                                                    | Why                                                                                                                                                                         |
|---------------------------------------------------------------------------------|--------------------------------------------------------------|----------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| STM conflict resolution                                                         | `barge` (an older txn can preempt a younger conflicting one) | retry-only (a conflicting txn re-runs with a fresh read-point) | The **committed result is identical** (serializable, no lost updates); only contention scheduling differs, which is not observable in the final state. (AD-013)             |
| `(locking x …)` on an immutable immediate (small int, nil, bool, bare keyword) | locks the boxed value's monitor and runs the body            | **errors** (`locking requires an object with identity`)        | An immediate is NaN-boxed with no header to lock; the JVM behaviour is a value-dependent foot-gun. Locking a real mutable object (atom / deftype / …) works fine. (AD-014) |

## Part 2 — Not yet implemented

These are gaps relative to Clojure, tracked as work items (not silent
no-ops — a missing Tier A/B/C form raises an explicit error rather than
quietly mis-behaving).

### Concurrency tail

The concurrency *primitives* are complete (`future` / `promise` / `delay`,
full STM `dosync` / `alter` / `commute` / `ensure` / `ref-set`, `atom` with
CAS, `agent` with error modes, `locking`, `volatile`, real threads,
`Thread/sleep`). The lower-frequency tail is deferred:

- agent **watches** and **validators**
- `await-for`, `shutdown-agents`
- `with-local-vars` (thread-local dynamic var bindings)

### Host / IO

- General `*out*` / `*err*` writer redirection is partial. `with-out-str`
  works (via a thread-local capture sink); full first-class writer values
  are deferred.
- **Arrays** (`int-array` / `object-array` / `aset` / `aget` mutation) are
  reserved but not yet implemented; the typed-array design is owner-gated.

### JVM-only surface (deferred or permanently out of scope)

Because cljw is no-JVM, the following Clojure forms that exist only to
bridge to the JVM are not part of the runtime (Tier C/D):

- `gen-class`, `gen-interface`, `compile` (AOT to `.class` files)
- deep `proxy` (subclassing arbitrary Java classes), `bean`
- reflection over, and `import` of, arbitrary Java classes

cljw provides its own host-class surface (a curated set, see
[`compat_tiers.yaml`](../compat_tiers.yaml)) rather than open JVM interop.

## How to read this page

A divergence listed in **Part 1** is *designed*: it derives from a project
invariant and is pinned by a regression test, so it reads as a deliberate
choice rather than a defect. A gap listed in **Part 2** is *scheduled*: it
is on the roadmap (or, for the JVM-only corners, intentionally excluded).
Anything not on this page that still differs from Clojure is a bug —
please report it.

For the authoritative, machine-readable form of Part 1, see
[`.dev/accepted_divergences.yaml`](../.dev/accepted_divergences.yaml); each
`AD-NNN` there carries its `derives_from` invariant and its `pin` test.
