# ADR-0137 — Scope goal line: Java surface boundary, per-class completeness, pure-leaning library re-selection, cljw.* differentiator surface

**Status**: Proposed → Accepted (2026-06-14). User-directed (chat 2026-06-14);
operationalises the new **F-014** (project_facts). Complements F-013 (how to
respond to a discovered gap: comprehensive + canonical) by fixing **where the
boundary is**.

> **Renumbered 0136 → 0137 (2026-06-14)**: this ADR was issued the day after
> ADR-0136 (host-frontier boundary, 2026-06-13) but collided on the same number.
> Per the time-ordered max+1 rule (CLAUDE.md), the earlier host-frontier ADR
> keeps 0136 and this scope ADR becomes 0137. The two are siblings: 0136 is the
> per-method admit/deny decision procedure; 0137 (this) is the per-class
> completeness + library + cljw.* goal line built on top of it.

## Context

cljw is a Clojure runtime in Zig, **not a JVM/Java reimplementation** (ADR-0059).
Library-driven discovery (F-013) keeps surfacing Java/`clojure.lang` surface to
add. Without an explicit boundary the loop drifts two ways: (a) chasing one
library's deep internals (instaparse GLL, D-430) past the point of general value,
and (b) leaving **partial classes** — a class with some methods wired and a
sibling method missing, which is a worse trap than an absent class (the user hits
a missing method on a class they thought worked). The user asked to "draw the
goal line" across three axes and to make touched classes complete.

## Decision

### Axis 1 — Java surface: "linguistically general" in, JVM-platform artifacts out

A Java class is **in scope** iff it is *linguistically general* — it models a
concept any language runtime needs, or that idiomatic Clojure code uses
pervasively — NOT a JVM-platform artifact. **Made decidable (DA sharpening c)**:
"linguistically general" is anchored to the same `clojure-corpus` frequency data
(`00a_frequency_overview.md`) Axis 2 uses — a class is in-scope iff it clears a
usage-frequency threshold in real Clojure AND is not a D-425 R1 (Java-artifact) /
R4 (impl-leak) disposition. Axis-1 in/out becomes a data lookup, not a per-class
debate, sharing one source with Axis-2's method corpora. The D-425 six-model tree
stays; the goal line per disposition:

- **IN — full surface (host_instance / native-collapse / stateless wrapper)**:
  String, the numeric tower (Long/Integer/Short/Byte/Double/Float/Boolean/
  Character/BigInteger/BigDecimal/Ratio — F-005), Math, System, StringBuilder,
  Object; `java.util` containers as host_instance (ArrayList, HashMap, LinkedList
  =ArrayList alias, HashSet); regex Pattern/Matcher; `java.time` common set
  (Instant/Duration/LocalDate(Time)/ZonedDateTime) + Date (#inst); Random (exact
  LCG); UUID; MessageDigest; **string/byte IO** (StringReader/PushbackReader/
  StringWriter/ByteArray streams + the `*in*` reader subsystem, D-414); the common
  Throwable hierarchy (catch vocabulary); Thread (currentThread/sleep/getName) +
  the atomics Clojure actually uses.
- **OPAQUE — recognition only (libs load, no instances)**: boxed-numeric
  supertypes, `java.sql.*`, `TimeUnit`, `*-TYPE` markers, `java.nio.ByteBuffer`
  (deferred), the `java.util.{Map,List,Set}` interfaces for `instance?`.
- **OUT — Tier D (explicit per-form error)**: gen-class / gen-interface /
  proxy(deep) / compile / bean(deep), deep reflection, JDBC (`java.sql` impl),
  Jackson, AWT/Swing, `java.nio` channels, `javax.xml` StAX impl, real OS threads
  as a Java API.

### Axis 2 — Per-class completeness (the user's central invariant → F-014)

> **Any Java class that exposes ANY surface method MUST be complete for its
> *commonly-used surface* — no intentional partial omission within an in-scope
> class.** Partial classes are forbidden: finish the class's common surface in
> the same campaign that touches it.

- "Commonly-used surface" = the methods idiomatic Clojure / real libraries call,
  NOT every JVM overload. Sibling methods ship together (e.g. `.subSequence`
  rides with `.substring`; never deferred to "a real consumer").
- This sharpens F-013's 網羅 from "the whole capability class" to "the whole
  *touched class's* common surface."

**The completeness MECHANISM (chosen = DA Alt 2 — oracle-derived per-class corpus).**
The DA fork found that the SSOT this ADR first pointed at does NOT exist:
`compat_tiers.yaml` carries `methods:` for only 28/82 host_classes and has NONE
for `java.lang.String` (42 methods wired in `String.zig`) or `Object`, and where
`methods:` exists it is a flat *wired* list with no intended/complete semantics —
so "wired ⊆ intended" had nothing to diff against (a vibe, not a gate). Per F-013
clause 3 (closed structurally, not by vigilance) + F-011 (clj equivalence), the
mechanism is therefore a **definition-derived per-class method corpus gated
against the `clj` oracle**:
  - For each in-scope class, build `test/diff/class_corpus/<Class>.txt` — one
    expr per common method (`(.substring "hello" 1 3)`, `(.subSequence "hello" 1 3)`,
    …), enumerated from the JVM class's public-instance surface **filtered by the
    `clojure-corpus` frequency data** (`00a_frequency_overview.md`) to the
    methods real Clojure actually calls.
  - Run through `scripts/clj_diff_sweep.sh`; `check_corpus_regression.sh` (already
    in the gate) re-runs them and fails on any DIFF. A method clj answers and
    cljw does not = a per-class completeness gap, caught **even when the author
    under-scoped** (the oracle knows the methods a hand-list would forget — the
    failure mode Alt 1's wired==declared check misses).
  - A method deliberately outside the common surface is an explicit
    OPAQUE/Tier-D line, never silent absence.
  - `compat_tiers.yaml` `methods:` becomes a generated index derived from the
    passing corpus, not a hand-maintained list.

**Mechanism LANDED (2026-06-14, D-431 first cut).** The infra is wired and the
two highest-frequency bare classes are closed:
  - `scripts/clj_diff_sweep.sh` gained `--class-corpus <Class>` (writes
    `test/diff/class_corpus/<Class>.txt`); `scripts/check_corpus_regression.sh`
    now scans `clj_corpus/` AND `class_corpus/`, so the per-class corpus is gated
    by the existing smoke step (`corpus_regression`) — no new gate wiring.
  - `String.txt` (44 goldens) + `Object.txt` (15 goldens, universal methods)
    landed. Building String's corpus surfaced real completeness gaps the JVM
    surface had and cljw lacked — `.indexOf`/`.lastIndexOf` fromIndex+codepoint
    overloads, `.stripLeading`/`.stripTrailing`, `.compareToIgnoreCase`,
    `.intern` — all fixed in the same cycle (the oracle-catches-under-scoping
    property in action). Accepted-divergence methods (`.hashCode` AD-009,
    `.getClass` AD-003, nil-receiver) are correctly OUT of the corpus (locked by
    their AD pins instead).
  - REMAINING (D-431 continues): the ~18 other in-scope bare classes
    (java.util containers / Pattern-Matcher / throwable family), the mechanical
    stop-chasing rule (sharpening b), the frequency-anchored Axis-1 list
    (sharpening c), and the generated `compat_tiers.yaml` `methods:` index.

### Axis 3 — Clojure libraries: pure-leaning re-selection

The verification engine is `verified_projects/` (committed `-M:verify` proofs).
Goal line for the candidate ladder (`docs/works/ladder.md`):

- **Target pure-degree ≤ 3.** Re-select TOWARD pure famous libs (data.* family,
  spec/malli, test.check, tools.* where pure, routing-core, utility cljc libs).
- **Re-select AWAY from Java-tight-coupled famous libs** — cheshire→Jackson,
  next.jdbc→JDBC, clj-time→joda, core.async→threads/executors. Keep them as
  boundary markers; do not chase.
- **Stop-chasing rule (made mechanical, DA sharpening b)**: a blocker is "general"
  iff its failing surface has a home in a SHARED class corpus (a `class_corpus/`
  line — advances all libs); it is "library-specific deep internal" iff the
  failing surface is a library-private construct with no class-corpus home
  (instaparse GLL, D-430). Corpus membership IS the general-vs-specific decision —
  computed, not re-litigated per library. Pursue the former; file + skip the latter.

### Axis 4 — cljw.* original surface = the differentiator, not JVM conveniences

`cljw.*` (ADR-0029) carries **what makes cljw worth using over the JVM**, never
re-implements JVM conveniences (those live under the java/clojure compat surface):
fast cold-start CLI, Wasm components, edge/serverless runtime, single-binary
build. Current: `cljw.wasm` / `cljw.http` / `cljw.eval`. Roadmap ideas (not
commitments): `cljw.wasm.*` (require-as-namespace + dropResource — the real
differentiator), `cljw.edge.*` (request/response edge runtime), `cljw.build`
(AOT single binary), `cljw.repl`/`cljw.nrepl` (dev surface), `cljw.os`/`cljw.proc`
(sandboxed process/env). A `cljw.*` addition must answer "why not just the JVM?".

## Alternatives considered

(Devil's-advocate fork, fresh context, 2026-06-14 — reflected faithfully.)

**Verification finding framing all three**: the draft's central completeness
claim ("compat_tiers.yaml lists each class's intended method set; a wired-but-
incomplete class is a finding") **does not hold** — 82 host_classes, only 28 carry
`methods:`; String (42 wired) and Object carry none; `methods:` is a flat *wired*
list with no intended/complete/partial semantics (grep = 0). So per-class
completeness was a vibe, not a gate; all alternatives must repair this or inherit
the lie (F-013 clause 3: "closed structurally, not by vigilance").

- **Alt 1 — smallest-diff**: redefine `methods:` as the intended set, backfill the
  ~54 bare classes, gate `wired == declared` (`check_class_completeness.sh`, reuses
  the G3 grep infra). *Better*: real PreToolUse gate in one cycle. *Risk*: still
  author-judged — catches later *drift* but not initial *under-scoping* (lists 3
  of String's 10 → green but partial); internal consistency, not completeness.
- **Alt 2 — finished-form (RECOMMENDED)**: definition-derived per-class method
  corpus enumerated from the JVM public-instance surface filtered by the
  `clojure-corpus` frequency data, gated against the `clj` oracle
  (`clj_diff_sweep.sh` + `check_corpus_regression.sh`, both already in the gate);
  `methods:` becomes a generated index. *Better*: the ONLY option where
  under-scoping is caught (the oracle knows the methods the author forgot);
  instantiates F-013 (definition-derived 網羅) + F-011 (clj equivalence) + the
  corpus-backed-discharge discipline (clj_diff_sweep.md Discipline 1 — same lie
  class). Stop-chasing + linguistically-general both get teeth from the shared
  corpus/frequency source. *Risk*: larger up-front corpus build (~20 classes); a
  global frequency threshold is a one-time judgment (vs per-class re-litigation).
- **Alt 3 — wildcard**: codegen dispatch + `methods:` + corpus skeleton from a
  single per-class spec; "partial relative to declaration" becomes a compile
  error. *Better*: eliminates wired-vs-declared drift at the representation level.
  *Risk*: largest surgery (codegen over all wired classes + build.zig); still
  doesn't decide the *common* surface (under-scoping hole relocated); risks the
  per-method error-message fidelity String.zig's hand-wired dispatch gives. Must
  be paired with Alt 2's oracle to actually close completeness.

**DA recommendation**: Alt 2, on F-002 (larger build is not a reason to downgrade)
+ F-013 clause 3 (structural, not vigilance, *requires* a definition-derived
check — only Alt 2 provides) + F-011 grounds. No alternative violates an F-NNN.

**Main-loop decision**: ADOPT Alt 2 as Axis-2's mechanism + all three sharpenings
(a corrected text above; b mechanical stop-chasing; c frequency-anchored Axis-1).
The corpus build is a follow-up campaign (this ADR sets the decision; it does not
require the ~20 corpora to land in this commit).

## Consequences

- The loop has an explicit in/out boundary; "should I add class X?" is answered by
  the linguistically-general test + the 6-model tree, not case-by-case drift.
- Per-class completeness becomes a *real* gate (not the draft's fiction): the
  per-class clj-oracle method corpus (Axis-2 mechanism) fails the commit on any
  missing common method — catching author under-scoping, not just drift. Follow-up
  campaign: build the ~20 in-scope class corpora + the frequency-anchored in/out
  list; until then, the rule is honoured by hand-discipline (sibling methods
  ship together) with the corpus as the converging structural backstop.
- Library work has a stop-chasing rule, protecting the perf/Wasm differentiator
  from breadth-grind (the Micro-coverage-grind smell, principle.md).
- `cljw.*` growth is purpose-gated.

## Affected files

- `.dev/project_facts.md` (F-014, the user-declared invariant).
- `compat_tiers.yaml` (per-class intended surface = the completeness SSOT).
- `docs/works/ladder.md` (re-curated per the pure-leaning criteria).
- `.claude/rules/feature_name_consistency.md` / D-425 taxonomy (the 6-model tree).
