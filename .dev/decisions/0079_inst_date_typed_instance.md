# ADR-0079 — `#inst` / java.util.Date as a no-slot typed_instance value

**Status**: Proposed → Accepted (2026-06-03, clj-parity campaign C6 / D-200)

## Context

ADR-0076 §9.2.P clj-parity campaign unit **C6 (D-200)**: `#inst "2024-01-01"`
→ cljw `reader_tag_unknown` (the `inst` data-reader is not registered); clj →
a `java.util.Date` printing `#inst "2024-01-01T00:00:00.000-00:00"`, with
`(inst? …)`→true, `(class …)`→java.util.Date, `(= …)` by epoch-ms,
`(inst-ms …)`→ms-since-epoch.

The tagged-literal reader infra is COMPLETE (D-200's reader cycles + ADR-0074
`#uuid` + ADR-0075 generic `tagged_literal`): `#tag form` → tokenizer `.tagged`
→ reader → `*data-readers*` dispatch. So C6 is "add an `inst` data-reader + a
Date value type", not "build reader infra".

**Representation is user-settled (F-004 LAW): β = a no-slot value.** All 64
NaN-box slots are named (the `heap_tag.zig` "reserved" comment is stale —
D11–D15 are hamt/tail/map-node/tval). A dedicated `.date` slot would need a
user F-004 reshuffle; the user chose **β = a `.typed_instance` Date**. The
slot-vs-typed_instance axis is therefore NOT re-litigated here.

## Decision

Implement Date as a `.typed_instance` carrying ONE epoch-ms `Value` field +
the canonical Date `TypeDescriptor`. The Devil's-advocate fork (mandatory at
depth ≥2) corrected the survey's "1-line" framing and surfaced four latent gaps
the chosen shape (DA Alt 2 hybrid) closes:

1. **Storage**: `allocInstance(rt, date_descriptor, &.{Value.initInteger(epoch_ms)})`
   — a single epoch-ms field. i48 inline integer holds ms to year ~6429 (max
   ±1.4e14), so no BigInt; keeps the typed_instance layout honest (a real
   field array, not a pointer that lies about its shape).
2. **One canonical descriptor**: reuse the EXISTING `runtime/java/util/Date.zig`
   surface descriptor (do NOT mint a second ad-hoc one — two descriptors would
   break the print/`instance?`/`class` pointer identity). Its pointer is cached
   on `Runtime` at `installAll`; the reader + `inst-ms` build/read instances
   against it. `fqcn` set so `(class …)`→"Date" (AD-003 simple name); a
   `class_name` FQCN_MAP row maps "java.util.Date"→"Date" so
   `(instance? java.util.Date d)` resolves through the existing `matchUserType`.
3. **Print** via a new `TypeDescriptor.print_tag: ?[]const u8 = null`:
   `printTypedInstance` (which has NO `rt`) emits `#<print_tag> "<iso>"` when
   non-null, formatting the epoch-ms field. Date sets `print_tag = "inst"`.
   Chosen over a `print.zig` descriptor-pointer compare because
   `printTypedInstance` has no `rt` to reach a cached pointer — the descriptor
   carrying its own print tag is the rt-free, data-driven shape, and it
   generalises to any future reader-tag native value.
4. **`=` by epoch-ms is NOT free** (the DA's load-bearing finding):
   `typedInstanceEqual` returns `false` for any `kind != .defrecord` (native =
   identity), so two distinct Date allocations would be `≠`. Add an epoch-ms
   equality arm gated on the Date descriptor / `print_tag != null`. Mandatory;
   pinned by a corpus case.
5. **Parse/format**: pure-Zig closed-form civil↔epoch-ms in `runtime/time/
   instant.zig` (F-009 neutral home) — parse the `#inst` grammar (year-only …
   full ISO + tz, offset subtracted to UTC), format epoch-ms → the canonical
   `#inst "YYYY-MM-DDTHH:MM:SS.mmm-00:00"`. The civil↔days conversion is new
   (instant.zig only had now→ms); use Hinnant's public-domain algorithms. Do
   NOT reuse v1's regex+callCore plumbing.
6. **`inst?`/`inst-ms`** core fns: Date-only (cljw has no `Instant` value type).
   Do NOT pre-build a forward-compatible Inst protocol (Reservation-as-bias);
   widen when an `Instant` value actually lands.

## Consequences

- `#inst "2024-01-01"` round-trips as `#inst "2024-01-01T00:00:00.000-00:00"`;
  `(inst? …)`→true, `(inst-ms #inst "1970-01-01T00:00:00.000-00:00")`→0,
  `(= #inst "2024-01-01" #inst "2024-01-01T00:00:00Z")`→true (epoch-ms),
  `(class …)`→"Date".
- A reusable `TypeDescriptor.print_tag` mechanism (one consumer today; the next
  reader-tag native value reuses it). Dispatch is backend-shared (typed_instance).
- Closes D-200's last piece (reader infra + `#uuid` already done). Next campaign
  unit: C5 = D-198 (after D-048).

## Affected files

- new: civil parse/format in `runtime/time/instant.zig`; `test/diff/clj_corpus/
  inst_date.txt`; e2e `test/e2e/phase14_inst_literal.sh`.
- edit: `runtime/type_descriptor.zig` (`print_tag` field), `runtime/java/util/
  Date.zig` (fqcn + print_tag + epoch field shape), `runtime/runtime.zig`
  (cache the Date descriptor pointer at installAll), `lang/bootstrap.zig`
  (register the `inst` data-reader), `lang/primitive/*` (`instReader` +
  `inst?`/`inst-ms` builtins), `runtime/print.zig` (print_tag branch in
  printTypedInstance), `runtime/equal.zig` (Date epoch-ms equality arm),
  `runtime/class_name.zig` (FQCN_MAP "java.util.Date"→"Date").

## Alternatives considered

(Devil's-advocate subagent, fresh context, depth-≥2 mandate. Within the β +
F-NNN envelope — slot-vs-typed_instance is user-settled, NOT re-litigated.)

### Alt 1 — Smallest-diff: single epoch-ms field + ad-hoc cached native descriptor

The survey's literal shape: `allocInstance` with one epoch-ms field; print via a
`print.zig` descriptor-pointer compare; a fresh `rt.date_descriptor` cache.

**Better:** minimal new types.

**Breaks/risks:** the **two-descriptor hazard** (an ad-hoc cache + the existing
`installAll` `cljw.java.util.Date` surface descriptor → print/`instance?`/`class`
key off whichever pointer the value carries); the print pointer-compare needs
`rt` in `printTypedInstance`, which has none (forces threading rt through the
print path); a `gc.infra` side-allocation for the 1-element field array; and it
STILL needs the equality arm + FQCN wiring it glosses as "confirm it works".
Rejected: it hides the load-bearing parts (equal arm, descriptor reconciliation).

### Alt 2 — Finished-form-clean (CHOSEN, hybrid): canonical descriptor + `print_tag` + epoch-ms equality arm

The decision above. Reuses the existing Date surface descriptor (one canonical),
adds the rt-free `print_tag` mechanism (no rt threading; reusable), the mandatory
epoch-ms equality arm, and the FQCN_MAP row. Storage stays a single epoch-ms
field-array (honest typed_instance layout) rather than a bespoke inline-i64
`DateValue` struct — the inline-i64 micro-opt's only payoff is one avoided small
allocation, not worth a `.typed_instance` that lies about its layout across
print/equal/dispatch.

**Better:** one canonical descriptor (no hazard); rt-free print; `=` correct;
`instance?`/`class` ride existing machinery; no layout footgun.

**Risks:** adds a `TypeDescriptor` field (`print_tag`, `= null` default → zero
call-site churn); the civil-date parse/format is genuinely new code (the
correctness-critical part). Mitigated by corpus pins on round-trip print +
epoch-`=`.

### Alt 3 — Wildcard: `#inst` as a `tagged_literal`, no Date value type

Read `#inst "…"` into a `.tagged_literal{tag=inst, form}`; implement
`inst?`/`inst-ms`/print over it.

**Better:** near-zero new machinery (tagged_literal already prints `#tag form`).

**Breaks/risks — disqualifying (F-011):** clj's `#inst` IS a java.util.Date, not
a tagged literal: `(class …)` wrong; round-trip print would echo the raw input
string, NOT the normalised `…T00:00:00.000-00:00`; `(= #inst "2024-01-01"
#inst "2024-01-01T00:00:00Z")` would be false (structural) instead of true
(epoch-ms); `inst-ms` would re-parse each call. Wrong value identity → would
need an unwanted accepted-divergence. Rejected.

## Revision history

- 2026-06-03 created (Accepted): clj-parity C6 / D-200. No-slot typed_instance
  Date (user β, F-004 unchanged). DA Alt 2 hybrid: canonical existing descriptor
  + `TypeDescriptor.print_tag` (rt-free print) + a mandatory epoch-ms equality
  arm (the DA's key finding — native typed_instances default to identity `=`) +
  pure-Zig civil parse/format in `runtime/time/`.
