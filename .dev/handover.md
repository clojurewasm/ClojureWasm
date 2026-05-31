# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (a long clj-differential parity run landed 2026-05-31).
- **Direction (user, 2026-05-31 night)**: **resolve ALL clj input→output
  differences**, prioritising **structure / simplicity / beauty / DRY** (F-011).
  Use real Clojure (`clj -M -e`) as the oracle (`.dev/reference_clones.md` §
  Executable oracle). Operating mode = **clj differential sweep**: probe a
  category through BOTH `clj` and `cljw -e`, diff, fix every divergence at the
  finished form (F-002/F-011 — internals may diverge, observable output must
  match; commonise rather than per-op patch). Unresolvable / deep ones get a
  **detailed entry in the master ledger**
  [`private/notes/phaseA26-clj-differential-oracle.md`](../private/notes/phaseA26-clj-differential-oracle.md)
  + a `.dev/debt.md` D-NNN row. Fully autonomous all night; do NOT stop.
- **First commit on resume MUST be**: continue the **clj differential sweep**.
  The master ledger lists swept categories + remaining items; pick the next
  unswept category (host interop / Math / java.* statics / numeric edges /
  string fns / regex / map-set ops / metadata / atoms-refs / printing). Always
  diff vs `clj` (batch — clj startup ~1-2s). **Build-race**: chain
  `zig build && <probe>`. **Channel/load**: under load, tool output can be
  empty/duplicated/contradictory (memory `tool-channel-corrupts-under-load`) —
  write to SENTINEL /tmp files, poll the gate log for `SENTINEL-…-EXIT=`, run
  critical probes 3x; a premature task-completion notification can fire while a
  gate is still at the e2e step (wait for the EXIT line, not the notification).
- **Forbidden**: re-opening anything landed (git log is the SSOT). In particular
  the clj-parity fixes already done (see Current state) + all earlier Phase ≤14
  work. JIT/superinstruction (completeness first; perf deferred per D-163).

## Current state

Mac gate green (171). AOT-bootstrap LIVE. This session (git log = SSOT), in two
arcs:
1. **Structural-defect hunting**: satisfies?/extends? wrappers; class/type =
   interned `.type_descriptor` (ADR-0059); defrecord value-equality;
   keyword-on-record (`(:k rec)`≡`(get rec :k)` via shared `lookup.recordGet`);
   var_ref print `#'ns/name` + `resolve` + deref-on-var; kwargs destructuring
   (`& {:keys}` seq→map coerce); **internal errors catchable by try/catch**
   (ADR-0060: try-boundary synthesises a class_name-bearing ex_info; both
   backends; nth→index_error).
2. **clj differential parity** (user-directed, F-011): flatten/sort/sort-by/
   distinct/dedupe/reductions/map-indexed/keep-indexed return SEQS not vectors;
   interleave variadic+seq; format `%0` zero-pad; **string seq/first yield
   CHARACTERS not 1-char strings**; String `.length`/`.substring`/`.indexOf`.

New invariant **F-011** (commonisation/clean/behavioural-equivalence over
effort; clj oracle wired). New ADRs **0059** (class/type), **0060** (catch).

## Master divergence ledger (compaction-survival)

[`private/notes/phaseA26-clj-differential-oracle.md`](../private/notes/phaseA26-clj-differential-oracle.md)
holds every clj diff found this run (fixed + unresolved + acceptable), the
oracle recipe, and the swept categories. **Read it first on resume** — it is the
night-work state. Per-task notes: `private/notes/phaseA26-*.md`.

## Open debts (deep clj divergences deferred; full rows in `.dev/debt.md`)

- **D-164** empty-seq≡nil: cljw collapses `()` to nil (`(list? '())`/`(seq? '())`
  false, `(= () nil)` true, empty filter/map/rest/flatten print "nil" not "()").
  Structural empty-seq-representation cycle. The seq-vs-vector fixes inherit this
  (empty → nil). **The biggest remaining clj parity gap.**
- **D-163** perf: collection/lazy/higher-order ops ~100µs/element (large reduce/
  range timeout). Deferred to F-010 post-M perf phase (NOT premature JIT).
- Earlier: D-160 sequence/eduction, D-155/156 HAMT, D-150 VM ctor, D-133 JIT.
- **Acceptable divergences (recorded, not bugs)**: `(class 5)`→`Long` not
  `java.lang.Long` (no-JVM, ADR-0059); `(float 1/3)` f64 not f32 (no f32 type);
  set print order (unordered); `(rest "abc")` substring not char-seq (O(1) opt,
  transitively char-correct via `(seq (rest …))`).

## Remaining clj-parity work (next sweep targets)

Unswept categories to probe vs clj: host interop (Math/* static methods,
String/Integer/Long statics), regex edge (`re-find`/`re-matches` groups),
metadata (`meta`/`with-meta`/`vary-meta`), atoms/refs/volatile, ns-introspection
(`find-ns`/`ns-name`/`resolve`-class — needs `.namespace` value rep), printing
(`pr-str`/`prn` of nested/edge values), more seq fns (`mapv`/`partition`/
`tree-seq`/`iterate` edges). Record each find in the master ledger.

## Cold-start reading order

handover → master ledger (above) → CLAUDE.md (§ Project spirit + Autonomous
Workflow + The only stop) → `.dev/project_facts.md` (F-011 + F-010) →
`.dev/principle.md` (Bad Smell) → `.dev/reference_clones.md` (clj oracle) →
`.dev/lessons/structural_defect_hunting.md`.

## Stopped — user requested

User instruction (2026-05-31 night, close paraphrase): stop at a clean point
and wire up new-session continuity. Working tree clean, all pushed (HEAD
6db3b141). Resume per the First-commit line — continue the clj differential
sweep; the next queued unit is Java interop (Integer/Long/Double statics +
more String instance methods, per the master ledger's Java-interop section).

Problems surfaced this run (none blocking, all recorded): (1) **high host
load** (5-min avg peaked ~17) slowed gates and triggered channel garbling +
premature notifications; accrued orphan `run_all.sh` were killed — start the
morning on a clean machine. (2) **Premature gate-completion notifications**
fire while a gate is still at its e2e step (memory
`premature-gate-notification`) — verify `SENTINEL-…-EXIT=0` + `gate_state_hash`
== `.dev/.gate_pass` before committing, not the notification. (3) **D-164**
(empty-seq≡nil) is the biggest remaining clj-parity gap (structural; deferred).
(4) **D-163** perf (large reduce/range timeout; deferred to the perf phase).
