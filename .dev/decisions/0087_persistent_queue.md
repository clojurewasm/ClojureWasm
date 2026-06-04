# ADR-0087 — PersistentQueue (FIFO persistent collection, slot 45)

Status: Proposed → Accepted (2026-06-04)

## Context

`clojure.lang.PersistentQueue` (the immutable FIFO queue) is a real
Clojure collection that user code uses directly via
`clojure.lang.PersistentQueue/EMPTY` + `conj`/`peek`/`pop`/`seq`. cljw
reserved the NaN-box tag `persistent_queue = 45` (F-004 enumerated
types) but never implemented it: no collection module, no constructor,
no dispatch. The recurring real-world-library drain (medley, aero) and
the interface-membership sweep this session (which already wired
`persistent_queue` into every `instance? clojure.lang.X` arm,
`sequential?`, `coll?`, `seq?`) leave the actual value type as the only
missing piece.

Survey: `private/notes/phase15-persistent-queue-survey.md`.

### JVM semantics (verified)

Okasaki batched queue: `cnt` + front `ISeq f` + rear `PersistentVector r`
(+ meta). `conj`/`cons`: the first element seeds `f`; subsequent
elements append to `r`. `peek`: `(first f)`. `pop`: `(rest f)`; when `f`
empties, `r` becomes the new front (via `seq`) and `r` resets — **pop of
empty returns the empty queue, no throw**. `seq`: front ++ rear-seq, or
`nil` when empty. `count` = `cnt`. `empty` = `EMPTY` with this queue's
meta. `=`/hash are ordered-sequential. `EMPTY` is a static singleton.

**Print (verified on host clj):** JVM has NO `print-method` for queues —
it prints the opaque `#object[clojure.lang.PersistentQueue 0xADDR
"…@hash"]`, embedding an identity hash cljw cannot and should not
reproduce. The `<-(…)-<` form is ClojureScript, not JVM.

## Decision

Implement PersistentQueue as a real collection on the reserved tag 45,
mirroring the JVM batched-queue representation with cljw's existing
collections, and resolving the EMPTY-static + print questions cljw's way:

1. **Representation** (`src/runtime/collection/persistent_queue.zig`, an
   `extern struct` like `map_entry.zig`): `count: i64`, `front: Value`
   (a cljw seq/list, or nil), `rear: Value` (a cljw vector, or nil),
   `meta: Value`. `conj` seeds `front` on the first element then conjes
   to `rear`; `peek` = first of `front`; `pop` = rest of `front`,
   migrating `rear`→`front` (via `seq`) when `front` empties (pop of
   empty returns EMPTY); `seq` = front ++ (seq rear) or nil; `count`
   returns the field; `empty` = EMPTY (meta-preserving). **`=`/hash: a
   queue is `Sequential`, so it routes through the SHARED
   Sequential-equality + ordered-hash paths** (add `.persistent_queue`
   to `isSeqLike` in equal.zig + the seq-hash dispatch — no bespoke
   queue equality). **A queue is `=` to ANY other Sequential (vector /
   list / seq / lazy-seq) with equal elements in order**
   (oracle-verified: `(= (conj EMPTY 1 2 3) [1 2 3])` → **true**,
   `(= EMPTY [])` → true), and **NOT** `=` to a set or `nil`
   (`(= EMPTY #{})` / `(= EMPTY nil)` → false); hash = the ordered hash
   of the equal vector/list. GC trace marks front/rear/meta (mirror
   `atom.zig` traceGc).

2. **EMPTY singleton**: a per-Runtime `rt.empty_queue`, allocated once on
   the GC `infra` arena and never swept (the `rt.empty_list` pattern from
   ADR-0076 / D-164), freed in `Runtime.deinit`.

3. **`clojure.lang.PersistentQueue/EMPTY` resolution**: the ADR-0061
   bare-static-field path uses a scalar-only `StaticFieldValue` union —
   extend it with a **`singleton: enum { empty_queue }`** variant
   (NOT a raw `value: Value` — the analyzer may run before/independently
   of the runtime that owns `rt.empty_queue`; the enum defers the pointer
   to resolution time, and future `…/EMPTY` fields reuse the seam). The
   resolver maps `.empty_queue` → `rt.empty_queue`. Register
   `PersistentQueue` in **both** `class_name.NATIVE_ENTRIES`/FQCN_MAP
   (so `(class q)` → `PersistentQueue`, AD-003) **and** `rt.types` (so
   `PersistentQueue/EMPTY` resolves via the Java-surface path) — the two
   use different tables (survey §4).

4. **Print** (accepted divergence — JVM's opaque `#object[… 0xADDR
   "…@hash"]` embeds a non-reproducible identity hash; `(str q)` and
   `(pr-str q)` differ only in that wrapper, both non-reproducible):
   cljw prints a **reader-round-trippable** `#queue (e1 e2 …)` form
   **and ships a matching `queue` data-reader** (`#queue coll` →
   `(into EMPTY coll)`) so the form is honest EDN, not a false
   tagged-literal promise (the DA's key correction). `str` and `pr-str`
   of a queue are intentionally identical (clj's differ only in the
   non-reproducible wrapper). `(pr-str (conj EMPTY 1 2 3))` →
   `#queue (1 2 3)`; empty → `#queue ()`. Recorded as a new `AD-NNN`
   deriving from ADR-0059 (no-JVM identity hash).

5. **No new Node / VM opcode** (ADR-0036): a queue has no reader literal;
   it is reached purely via `conj`/EMPTY, so both backends produce it
   identically (same as `map_entry`). A differential case confirms parity.

## Consequences

- `(conj clojure.lang.PersistentQueue/EMPTY 1 2 3)` builds a queue;
  `peek`/`pop`/`seq`/`count`/`=`/`into`/`empty?` work; `(queue? x)` via
  `instance?` already works (this session).
- medley/aero advance past their PersistentQueue walls (they have other
  deep deps, so this is a standalone-collection win, not a full unblock).
- The queue print form diverges from JVM's opaque `#object` (AD-NNN) —
  intentionally readable.

## Affected files

- `src/runtime/collection/persistent_queue.zig` (new) — struct + conj /
  peek / pop / seq / count / empty / make / EMPTY / GC trace.
- `src/runtime/runtime.zig` — `empty_queue` singleton field + init/deinit.
- `src/main.zig` — `test { _ = @import("…persistent_queue.zig"); }` reach.
- `src/lang/primitive/collection.zig` — `conj` arm.
- `src/lang/primitive/sequence.zig` — seq / first / rest / next / count /
  empty arms.
- `src/lang/clj/clojure/core.clj` — `peek`/`pop` queue arms.
- `src/runtime/equal.zig`, `src/runtime/hash.zig` — queue equality/hash.
- `src/runtime/print.zig` — `#queue (…)` print.
- `src/eval/analyzer/analyzer.zig` + the StaticFieldValue union —
  `PersistentQueue/EMPTY` resolution.
- `src/runtime/class_name.zig` — `PersistentQueue` NATIVE_ENTRIES +
  FQCN_MAP (already in the instance? interface arms).
- `.dev/accepted_divergences.yaml` — AD-NNN (queue print form).
- Tests: `test/e2e/`, `src/lang/diff_test.zig`, corpus.

## Devil's-advocate resolution

The DA fork ran the clj oracle and surfaced three corrections, all
adopted into the Decision above:

1. **Equality (highest priority — the original draft was wrong).** The
   draft said "ordered-sequential" and the framing assumed a queue is
   NOT `=` to a vector. The oracle says the opposite:
   `(= (conj PQ/EMPTY 1 2) [1 2])` → **true**. A queue is `=` to any
   other `Sequential` with equal elements (vector / list / seq /
   lazy-seq), `≠` set/`nil`, and `(hash q) == (hash [1 2 3])`. The
   implementation reuses the shared Sequential-equality + ordered-hash
   paths. The corpus pins `(= q [1 2 3]) → true`, `(= EMPTY []) → true`,
   `(not= EMPTY nil)`.
2. **Print.** `#queue (…)` without a reader falsely implies EDN data.
   Adopted the DA's finished form: ship the `#queue (…)` print **plus** a
   `queue` data-reader so it round-trips in cljw (clj's own `#object`
   form does not round-trip either, so cljw is strictly better).
3. **EMPTY resolution.** A raw `value: Value` baked at analyze time is
   GC-unsafe (the singleton may not exist yet); use a `singleton: enum`
   variant resolved to `rt.empty_queue` at resolution time.

The representation (extern-struct list+rear-vector on reserved tag 45)
and the no-Node/no-opcode dual-backend conclusion were confirmed
finished-form and kept. Using slot 45 (not a `typed_instance` shim) is
correct — consuming the reservation like map_entry consumed slot 15; a
typed_instance would route every dispatch through user-protocol slow
paths.

## Alternatives considered

(Devil's-advocate fork output, verbatim.)

**Alt 1 — smallest-diff: ADR representation + cljs `<-(…)-<` print +
D2a name-keyed EMPTY.** Better: smallest EMPTY plumbing (no
StaticFieldValue surgery). Breaks: D2a adds a `"EMPTY"` string-compare
in the hot symbol-analysis path that the finished-form owner unwinds
when PersistentList/Vector/HashSet `…/EMPTY` land (re-litigated 3×) —
Reservation-as-bias-in-reverse. Rejected on F-002.

**Alt 2 — finished-form-clean (RECOMMENDED): ADR representation + D2b
generic singleton static-field + reuse seq-equality/hash + `#queue (…)`
*with* a matching data-reader (else `<-…-<`).** Better: D2b is the seam
every future `…/EMPTY` reuses (no hot-path string branch); equality is
correct + free + honestly documented; print either round-trips for real
or makes no false promise. Breaks/risks: D2b touches the
`StaticFieldValue` union (Zig exhaustive switch makes the fan-out
compiler-enforced — a feature); shipping the `queue` reader is a small
extra surface but the only way `#queue` is non-mendacious. The F-002
pick.

**Alt 3 — wildcard: single vector + head-index deque instead of
list+rear-vector.** Better: one GC child; O(log32) front random access;
no rear→front migration branch. Breaks: pop-without-compaction leaks
(drained elements pinned forever — unbounded growth under conj/pop);
adding compaction reintroduces complexity + breaks structural sharing;
diverges from JVM's amortized-O(1) Okasaki guarantee; throws away the
exact-mirror-of-JVM auditability. Rejected (better only on child count,
which is not a constraint; worse on correctness/finished-form).

**DA recommendation:** Alt 2. **Main-loop decision:** adopt Alt 2 with
the three corrections folded into the Decision. The representation, slot
choice, and dual-backend conclusion stand; the equality prose, print
form, and EMPTY-resolution shape are corrected per the oracle + the DA.
