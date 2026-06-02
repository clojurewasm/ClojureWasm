# ADR-0074 — `#uuid` reads to a real UUID value type (not a string)

- Status: Accepted
- Date: 2026-06-02
- Supersedes: none
- Refs: D-200 cycle 3 (this decision's debt), ADR-0073 (the reader infra
  that dispatches `#uuid` to a data reader), F-002 / F-004 / F-009,
  `no_jvm_specific_assumption`. `#inst`/Date is SPLIT to its own later ADR.

## Context

ADR-0073 landed the tagged-literal reader infra: `#tag form` dispatches
through `*data-readers*`, raising on an unregistered tag. To make
clj's built-in `#uuid "…"` reader work, cljw must decide what VALUE it
produces. Today cljw represents UUIDs as **canonical 36-char strings**:
`clojure.core/random-uuid` + `parse-uuid` (`lang/primitive/uuid.zig`) and
`java.util.UUID/randomUUID` (`runtime/java/util/UUID.zig`) all return a
string; the neutral impl `runtime/uuid.zig` has `generateV4`/`format`/
`parse` (16-byte ⇄ canonical). No `uuid?` predicate exists.

The decision is **string-parity** (consistent with the shipped string
surface, but lossy) vs a **real UUID value type** (clj-faithful, but
migrates the three string-returning primitives). Full DA analysis below.

## Decision (DA Alt 2 — real `uuid` heap value type, `#uuid` only)

Introduce a dedicated UUID heap value and migrate every UUID entry point
to it, because **EDN round-trip is the defining property of a reader
literal** and string-parity permanently breaks it
(`(pr-str #uuid "…")` → `"…"`, not `#uuid "…"`).

1. **Value**: a `uuid` heap tag reusing the reserved NaN-box slot
   `reserved_b15 = 31` (renamed `uuid = 31`). This keeps F-004's
   **4×16 = 64-slot shape unchanged** — only a reserved slot is assigned
   (a memo, per the project-spirit reservation rule), NOT a layout
   amendment, so no F-004 user-amendment is needed. The carrier
   (`runtime/uuid/value.zig`, modelled on `runtime/regex/value.zig`) holds
   the 16 bytes **inline** (no `gc.infra` payload) + a `meta` slot.
2. **Surfaces** (clj-faithful, all over the neutral `runtime/uuid.zig`
   per F-009): print → `#uuid "<canonical>"` (round-trips); equal →
   128-bit compare; hash → hash the 16 bytes; `(class x)` → a `UUID`
   TypeDescriptor (cljw-native, per `no_jvm_specific_assumption`, not a
   real `java.lang.Class`); `(instance? java.util.UUID x)` +
   `class_name.zig` entry; `clojure.core/uuid?` predicate.
3. **`#uuid` reader**: register a `uuid` entry in the **root**
   `*data-readers*` table (so it works without a `binding`, unlike the
   user-supplied readers of ADR-0073) → parse via `runtime/uuid.zig` →
   the new value. A bad UUID string raises (clj throws on malformed
   `#uuid`).
4. **Migrate the three string-returning primitives** to return the new
   type — `random-uuid`, `parse-uuid` (nil on bad input, unchanged), and
   `java.util.UUID/randomUUID` — so cljw has ONE coherent UUID
   representation (`(= (random-uuid) #uuid "…")` is type-comparable, not a
   string-vs-type mismatch). `(str <uuid>)` still yields the canonical
   string (UUID toString).

**SemVer**: the `String → UUID` migration is an observable change, but
v0.1.0 has **not shipped** — paying it now is SemVer-free; deferring it
(string-parity now, promote later) would force a MAJOR break to undo and
is the Cycle-budget-defer smell the DA flagged.

### Out of scope (split to own later ADRs)
- **`#inst` / `java.util.Date`** — heavier (timezone, `clojure.instant`
  grammar, a separate `runtime/time/` impl, F-009-distinct concern
  boundary). Its own ADR.
- **Generic `tagged_literal` (slot 24) carrier as the unknown-tag
  FALLBACK** — clj's `tagged-literal`/`tagged-literal?` is the *fallback*
  for tags with no reader, NOT how `#uuid`/`#inst` are represented
  (`(class #uuid …)` is UUID, not TaggedLiteral). Changing ADR-0073's
  unknown-tag-raises contract to a non-throwing carrier is a separate
  decision; slot 24 stays reserved-unused until then.

## Consequences

- `#uuid "…"` round-trips through `pr-str`; `(uuid? #uuid "…")` → true;
  `(class #uuid "…")` → UUID; `(= #uuid "a…" #uuid "a…")` → true.
- One UUID representation across reader literal + `random-uuid` +
  `parse-uuid` + `java.util.UUID/randomUUID`.
- Existing tests/corpus asserting a STRING from `random-uuid`/`parse-uuid`
  are updated in the migration commit (the change is intended).
- One reserved NaN-box slot (`reserved_b15`→`uuid`) is now assigned;
  F-004's 64-slot shape is unchanged.

## Affected files

- `src/runtime/value/value.zig` (`reserved_b15` → `uuid` tag).
- `src/runtime/uuid/value.zig` (new — the heap carrier) + `runtime/uuid.zig`
  (neutral impl already present; add any value-wrap helper).
- GC: `runtime/gc/tag_ops.zig` + mark-sweep registration (trace `meta`).
- `src/runtime/print.zig` (print arm), `src/runtime/equal.zig` (equal +
  hash arms), `src/runtime/class_name.zig` (UUID class entry + `instance?`).
- `src/lang/primitive/uuid.zig` (migrate `random-uuid`/`parse-uuid`, add
  `uuid?`), `src/runtime/java/util/UUID.zig` (migrate `randomUUID`).
- Default `*data-readers*` registration (`lang/bootstrap.zig` or the uuid
  primitive) for the `uuid` reader.
- Tests: `test/e2e/phase14_uuid_literal.sh` + diff_test + unit tests.

## Alternatives considered

(Verbatim from the mandatory Devil's-advocate subagent, fresh context,
within the F-NNN envelope. The Decision adopts the DA's Alt 2.)

### Leading finding: F-004 is NOT a blocker — all options fit the live 64-slot shape

Verified against `value.zig`: the `Tag` enum is already the 64-slot second
generation. `tagged_literal = 24` exists today (Group B), and Group B has
`reserved_b15 = 31`. A dedicated UUID heap tag consumes one reserved slot;
a combined Date tag a second; activating `tagged_literal = 24` consumes
zero new slots. None requires amending F-004's 4×16=64 shape. F-004 is not
a hard block; the real decision is representation semantics, governed by
F-002 (finished-form) and F-009 (neutral impl).

### Alternative 1 (smallest-diff): String-parity — `#uuid`/`#inst` read to canonical String / ISO-string

`formToValue` registers `uuid` → canonical String (reusing
`runtime/uuid.zig`), `inst` → ISO-8601 String. No new heap tag, no
`uuid?`/`inst?` (or they heuristically test `string?` — ugly).

**Better:** Internal consistency with the already-shipped surface —
`random-uuid`, `parse-uuid`, `java.util.UUID/randomUUID` all return the
36-char String today, so string-parity means `(= (random-uuid) #uuid "…")`
works and cljw has exactly ONE UUID representation; a runtime where `#uuid`
produced a distinct type while `random-uuid` produced a String would be
internally incoherent. Smallest diff: one data-reader registration per tag,
reuses `runtime/uuid.zig` verbatim, no print/equal/hash/class/GC. `#inst`
trivial (ISO string round-trips).

**Breaks:** Diverges from clj on `(class #uuid "…")` (→ String descriptor);
`uuid?` cannot be `(instance? UUID x)` (no UUID type). **`pr-str` does not
round-trip** — clj prints `#uuid "a…"`, cljw prints `"a…"`; reading
`(pr-str x)` back gives a String, not the literal — breaks EDN round-trip,
the *entire point* of reader literals. A reader-literal feature whose
output does not re-read to itself is not implementing the reader literal;
it is "parse the string at read time and forget the tag." **SemVer trap**:
String-parity now → real type later is a `String→UUID` observable break =
MAJOR; F-002 forbids choosing it on cost grounds. **Smallest diff but
finished-form-dirty**: permanently sacrifices EDN round-trip.

### Alternative 2 (finished-form-clean, RECOMMENDED): Real `uuid` heap type + migrate the 3 String-returning primitives

Mint a dedicated UUID heap value (16-byte payload in `runtime/uuid/value.zig`
modelled on `runtime/regex/value.zig` — HeapHeader at offset 0, `gc.alloc`,
trivial finaliser since 16 bytes inline, trace only `meta`). Wire the five
touch-points regex shows: print (`#uuid "…"`), equal (128-bit), hash (16
bytes), `instance?`/`class` via TypeDescriptor, GC registration.
`formToValue`'s `uuid` reader produces it. Then migrate `random-uuid`,
`parse-uuid`, `java.util.UUID/randomUUID` to return it (else two UUID
representations).

**Better:** clj-faithful and EDN-round-tripping — `(class #uuid "…")` →
UUID, `(uuid? x)` → true, `(= … …)` → true by 128 bits, `(pr-str …)` →
`#uuid "…"`. Round-trip holds — the feature *is* the reader literal.
Coherent after migration: one representation, no `(= (random-uuid) #uuid …)`
surprise. No SemVer trap going forward — permanent shape. Fits F-004 (one
reserved slot).

**Breaks:** Changes already-shipped behaviour — `random-uuid`/`parse-uuid`
return String today (Tier A). Migrating to UUID is a `String→UUID` MAJOR
break — BUT no v0.1.0 has shipped, so doing it NOW is SemVer-free;
deferring is the trap. Largest diff (5 arms + 3 migrations + tests), but
F-002 says diff size is not a constraint. `#inst` deferral still open.
**The finished-form-clean alternative; the only "break" is SemVer-timing,
which resolves in its favour because the migration is pre-release.**

### Alternative 3 (wildcard): Generic `tagged_literal` (slot 24) carrier for ALL tags including `#uuid`/`#inst`

Activate `Tag.tagged_literal = 24` as a generic `{tag-symbol, payload}`
heap value (matching clj's `tagged-literal`/`tagged-literal?`,
core.clj L7961). `formToValue` wraps every `#tag form` into it;
`uuid?` becomes `(= (:tag x) 'uuid)`.

**Better:** One mechanism serves `#uuid`, `#inst`, user record-tags, AND
clj's `tagged-literal` API; activates a slot F-004 already reserved for
exactly this; EDN round-trip trivial (the carrier IS `{tag, form}`).

**Breaks — and why it is wrong for `#uuid`/`#inst`:** clj does NOT
represent `#uuid`/`#inst` as TaggedLiterals — `tagged-literal` is the
*fallback* for tags with no reader; `#uuid`/`#inst` have registered readers
producing real UUID/Date. So `(class #uuid "…")` in clj is `java.util.UUID`,
not `TaggedLiteral`. A generic carrier makes `(class #uuid …)` →
TaggedLiteral and `(uuid? x)` → false — diverges on the exact predicates
the feature exists to satisfy. It conflates the *reader fallback*
(TaggedLiteral, which cljw SHOULD build for unknown tags) with the
*registered-reader result* (real value). **Correct synthesis:** Alt 3 is
right for the FALLBACK path and wrong for `#uuid`/`#inst`. Finished form =
Alt 2's real types for built-in readers PLUS Alt 3's carrier as the
unknown-tag fallback (a separate, later decision — it changes ADR-0073's
unknown-tag-raises contract). The two are different layers, not competitors.

### Point-by-point

(a) **Consistency vs fidelity** — internal consistency is a real
finished-form virtue, but Alt 1 buys it by sacrificing EDN round-trip; Alt 2
buys BOTH consistency and fidelity by migrating the 3 primitives, and a
coherent runtime can be coherent around the *correct* representation just as
easily as the lossy one. Consistency favours Alt 2 + migration.
(b) **Generic carrier vs dedicated** — dedicated is finished-form for
`#uuid`/`#inst` (clj produces real UUID/Date, `class` must match); the
carrier is finished-form for the unknown-tag fallback. Coexist at different
layers.
(c) **`#inst` scope — SPLIT.** `#inst`→Date drags timezone parsing +
`clojure.instant` grammar (non-trivial, instant.clj L100-274) + a Date heap
type. `#uuid` is 16 bytes with a parser that ALREADY exists. Splitting on a
real concern boundary (different impl, `runtime/time/`, F-009-distinct) is
finished-form-clean, not Cycle-budget-defer (which is about diff size).
(d) **SemVer — decisive.** Alt 1 = ship String now, MAJOR break later
(trap). Alt 2 = pay `String→UUID` now, before v0.1.0, SemVer-free. The
pre-release window is exactly when the representation should be nailed down.

### Recommendation (DA)

**Alt 2 (real `uuid` heap type) + migrate the 3 String-returning primitives
in the same ADR, `#uuid` only, `#inst` split to its own later ADR.**
Finished-form-clean per F-002: clj fidelity (`class`/`uuid?`/`pr-str`
round-trip), restored coherence (one type across all four entry points),
fits the live F-004 64-slot envelope with no amendment (reserved slot), and
pays the only "break" (String→UUID) inside the SemVer-free pre-release
window. The regex carrier is the cost model (minus the gc.infra payload —
16 bytes sit inline). The generic `tagged_literal` carrier (Alt 3) is the
correct SEPARATE mechanism for the unknown-tag fallback, deferred. `#inst`
split on a real concern boundary. The instinct toward Alt 1 on "consistent +
tiny diff" is the Cycle-budget-defer smell — re-pick Alt 2.
