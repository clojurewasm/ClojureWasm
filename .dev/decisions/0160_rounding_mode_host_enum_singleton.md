# ADR-0160 — `java.math.RoundingMode` enum constants as host-enum object singletons (not int ordinals)

- **Status**: Proposed → Accepted (2026-06-24; clj-parity sweep; DA-fork incorporated)
- **Driven by**: the stdlib/contrib clj-parity differential sweep. cljw did not
  register `java.math.RoundingMode`, so `java.math.RoundingMode/HALF_UP` raised
  `No namespace: 'java.math.RoundingMode'` and the clj-modern rounding call
  `(.setScale (bigdec "3.14159") 2 java.math.RoundingMode/HALF_UP)` errored where
  clj returns `3.14M`.
- **Relates to**: ADR-0061 (`Class/FIELD` static-field read), ADR-0087 (heap-singleton
  static fields resolved at analyze time), ADR-0115 (Locale host-object singletons — the
  pattern this mirrors), ADR-0106 (`.host_instance` container). F-005 (numeric tower =
  JVM surface), F-011 (behavioural equivalence), F-013 (closed-set host SSOT), F-002
  (finished-form wins). AD-002 (opaque-ref `#<tag>` print).

## Context

In JVM Clojure the modern rounding API is the `java.math.RoundingMode` **enum**
(`RoundingMode/HALF_UP` etc.); the `BigDecimal.ROUND_*` **int** constants are the
deprecated legacy form. The enum's 8 ordinals match the `ROUND_*` ints exactly
(UP=0 … UNNECESSARY=7). cljw already carried the deprecated int constants
(`BigDecimal/ROUND_HALF_UP` → 4) and a `setScale(int,int)` that accepts an int mode
0-7, but had no `RoundingMode` class at all.

clj's observable surface for an enum constant:

- `(str RoundingMode/HALF_UP)` → `"HALF_UP"` (the enum's toString = its name)
- `(class RoundingMode/HALF_UP)` → `java.math.RoundingMode`
- `(= RoundingMode/HALF_UP RoundingMode/HALF_UP)` → `true`; `(= RoundingMode/HALF_UP 4)` → **false** (enum ≠ Long)
- `(pr-str RoundingMode/HALF_UP)` → `#object[java.math.RoundingMode 0x… "HALF_UP"]` (non-reproducible address)
- `(.setScale bd n RoundingMode/HALF_UP)` → rescaled value

## Decision

Register `java.math.RoundingMode` as a host class whose 8 enum constants are
**host-enum object singletons** (the Locale `singleton` pattern, ADR-0115), NOT
plain int ordinals:

- Each constant is a per-Runtime cached `.host_instance` carrying its ordinal in
  `state[0]`, with a descriptor `fqcn = "java.math.RoundingMode"` and a `.toString`
  method returning the bare enum name. Caching (8 `rt.rounding_modes` slots) gives
  `=` / `identical?` parity.
- A new `StaticFieldValue.rounding_mode: u8` arm carries the ordinal; the analyzer's
  `staticFieldValue` resolves it to the cached singleton (same analyze-time lift as
  Locale's `singleton`).
- `BigDecimal.setScale`'s mode arg accepts **both** a `RoundingMode` host_instance
  (read `state[0]`) and the deprecated `ROUND_*` int — both JVM-faithful, both decode
  to 0-7.
- The canonical name↔ordinal mapping lives once in the neutral
  `runtime/rounding_mode.zig`; **both** the `RoundingMode/<name>` enum table AND
  BigDecimal's `ROUND_<name>` int table are comptime-generated from it (no dual
  source of the ordinal numbering).

This reaches clj parity on `str` / `class` / `=` / `setScale`. The only divergence is
the opaque print form `#<java.math.RoundingMode>` vs clj's `#object[… 0x… "HALF_UP"]`
— the non-reproducible identity-hash class **already covered by AD-002** (same as
Locale / atom / every host opaque ref). No new accepted-divergence entry is required.

## Alternatives considered

A `general-purpose` Devil's-advocate subagent (fresh context) was forked with the
active F-NNN constraints and produced the following (reflected verbatim):

> **No alternative requires violating an F-NNN.** All three sit inside the envelope
> (F-005, F-013, AD-003, F-009). The int-ordinal draft is itself F-NNN-compliant; the
> disagreement is which finished form a future maintainer respects.
>
> **The fact that reframes the decision.** clj's `with-precision` (core.clj L5153-5157)
> expands `:rounding HALF_UP` to `(. java.math.RoundingMode HALF_UP)` and passes the
> result to `(java.math.MathContext. precision rm)`. So the dominant consumer of
> `RoundingMode` constants is a **`MathContext` constructor argument**, not `setScale`.
> cljw has no `MathContext` host class yet. An int passed to a future `MathContext.`
> constructor would be ambiguous with the `(int precision)` first arg — a typed enum
> disambiguates where a bare int cannot.
>
> **Alt 1 — Smallest-diff: int-ordinal but on the SHARED neutral surface.** Keep the
> int representation but generate both tables from one `[8]{name,ord}` source (no
> duplicated literal). Better: eliminates dual-source ordinal drift. Breaks everything
> the draft breaks: `(class …)` → Long; prints `4`; future `MathContext.` int/precision
> ambiguity. Reject on F-002 — but **fold the commonization into whatever wins**.
>
> **Alt 2 — Finished-form-clean: host-enum singleton (Locale pattern), ordinal in
> state[0].** `(class …)` correct; future `MathContext.` typed arg; `(str …)` = "HALF_UP"
> (draft gives "4"). `(= RoundingMode/HALF_UP 4)` is **false** here and in clj — whereas
> the draft makes it **true**, a divergence clj does NOT have. **AD-051 as drafted would
> lock in a non-clj equality** — heavier than the draft's consequence section admits.
> Would a maintainer unwind "HALF_UP = int 4"? Yes, high-confidence: the moment
> `MathContext`/`with-precision :rounding` lands, the int/precision ambiguity + `(class)`
> = Long breakage force a conversion. The int draft is a skeleton that *enlarges* the
> eventual rewrite (ships an AD that must be un-accepted + a setScale that must learn a
> second arg shape) — the disqualifying signal per F-002.
>
> **Alt 3 — Wildcard: a general host-enum mechanism.** `RoundingMode` is one instance of
> a recurring need (`TimeUnit`, `DayOfWeek`/`Month` — already ad-hoc in `TemporalPrint`,
> `ChronoUnit`). Grow a first-class `StaticFieldValue.host_enum_const {fqcn,name,ordinal}`
> + interned singleton + uniform bare-name print, subsuming the bespoke temporal arms.
> Correct everywhere + reusable. Cost: largest diff (not an F-002 constraint), but it is a
> **structural-plan** change — per F-003 the loop imagines + records + defers to the owning
> unit, it does not seize it mid-sweep. Record as a debt row; land `RoundingMode` today in
> the shape the mechanism absorbs cleanly = Alt 2's singleton.
>
> **Recommendation: Land Alt 2 (host-enum singleton), with Alt 1's commonized constant
> source folded in, and open a debt row for Alt 3.** Reject the int-ordinal draft: it
> locks a non-clj equality and a Long class identity a maintainer will unwind the instant
> `MathContext` lands. Alt 2 reaches the correct finished form now, is the exact shape
> Alt 3 generalizes, and its only true divergence (opaque print address) is the
> already-accepted AD-002 class.

The main loop adopted the recommendation in full: **Alt 2 + Alt 1's commonized constant
source**, with **Alt 3 deferred to debt D-510**.

## Consequences

- `java.math.RoundingMode/<NAME>` resolves (FQCN always; bare `RoundingMode/<NAME>` after
  `(import java.math.RoundingMode)`, matching clj which also requires the import).
- `setScale` accepts the enum constant; the deprecated `ROUND_*` int path is unchanged.
- `str` / `class` / `=` match clj; `pr-str` diverges under the pre-existing AD-002 (no new AD).
- The ordinal numbering is single-sourced — a future ordinal audit reconciles one table.
- `divide` with a `(scale, RoundingMode)` overload and a `MathContext` host class remain
  gaps; both are the natural next consumers of this shape (and of D-510's mechanism).

## Affected files

- `src/runtime/rounding_mode.zig` (new — neutral: Mode/name/singleton/deinit)
- `src/runtime/java/math/RoundingMode.zig` (new — surface: descriptor + static fields + toString)
- `src/runtime/type_descriptor.zig` (`StaticFieldValue.rounding_mode` arm)
- `src/eval/analyzer/analyzer.zig` (`staticFieldValue` resolves the new arm)
- `src/runtime/runtime.zig` (`rounding_modes` slots + deinit call)
- `src/runtime/java/math/BigDecimal.zig` (setScale dual-accept; ROUND_* table commonized)
- `src/runtime/java/_host_api.zig` (register the surface)
- `compat_tiers.yaml` (java.math.RoundingMode entry, keyword `rounding_mode`)
- `test/e2e/phase14_bigdecimal_setscale.sh` (9 RoundingMode cases)
- `.dev/debt.yaml` (D-510 — general host-enum mechanism, deferred)
