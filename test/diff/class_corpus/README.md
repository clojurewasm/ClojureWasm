# Per-class Java-completeness corpus (F-014 / ADR-0137)

Each `<Class>.txt` here is the **commonly-used surface** of one in-scope Java
class, captured as `expr` / `;;=> <output>` golden pairs that cljw reproduces
*and* the `clj` oracle agrees with. This operationalises **F-014 clause 2**
(per-class completeness when touched) as a real gate, per **ADR-0137 Axis-2**
(DA Alt 2 — oracle-derived per-class corpus).

## Why this exists (vs. a hand-maintained `methods:` list)

A hand-list of "methods we wired" only catches *drift*, never *under-scoping* —
it cannot tell you about the method you forgot to wire. The `clj` oracle knows
the whole JVM surface, so a corpus enumerated from the **frequency-filtered**
common surface (see below) fails the gate when clj answers a method and cljw
does not. That catches the partial-class trap F-014 forbids ("a partial class is
a worse trap than an absent one").

## How a corpus is built

1. Enumerate the class's common surface from the JVM public-instance methods,
   **filtered by real-world frequency** —
   `private/clojure_frequent_java_interop/00a_frequency_overview.md`
   (§2 class frequency, §5 instance-method frequency, derived from the
   `~/Documents/OSS/clojure-corpus` 228-repo scan).
2. Write one value-expr per method (with realistic args + a few edge cases) to
   a scratch file.
3. `bash scripts/clj_diff_sweep.sh <file> --class-corpus <Class>` — runs every
   expr through both cljw and clj, and appends only the **matching** pairs here.
   Any DIFF is a completeness gap: fix cljw (the common case) or, if the method
   is an intentional divergence, record an `AD-NNN` and leave it OUT of the
   corpus (the AD pin locks it instead).

## How it is gated

`scripts/check_corpus_regression.sh` scans both `clj_corpus/` (general
behaviour) and `class_corpus/` (this), re-running each `expr` through cljw only
and failing on any drift. It is part of the per-commit **smoke** gate
(`corpus_regression` step in `test/run_all.sh`), so a regression or a newly
under-scoped class surfaces immediately.

## What is deliberately NOT in a corpus

A method whose cljw behaviour intentionally diverges from clj (an accepted
divergence) is locked by its `AD-NNN` pin in `.dev/accepted_divergences.yaml`,
not by a corpus line. Examples on the String/Object surface: `.hashCode`
(AD-009, cljw value-hash ≠ JVM polynomial), `.getClass` (AD-003, simple name),
and nil-receiver method calls (error-format differs per F-011).

## Status

Landed: `String` (44), `Object` (15, universal `.toString`/`.equals`),
`Throwable` (15, the exception family's `.getMessage`/`.getLocalizedMessage`/
`.getCause`/`.getData` on the shared `.ex_info` descriptor). The remaining
in-scope bare classes are tracked by **D-431**.
