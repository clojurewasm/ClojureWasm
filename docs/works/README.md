# docs/works — real-world Clojure library compatibility ladder

This directory tracks **which real-world, pure-Clojure libraries load and
run on cljw**. It is the concrete, externally-grounded half of the
convergence definition (F-010, Convergence Campaign Stage 0.5 / 1.3): cw v1
is not "converged" on the strength of its own test suite alone — it is
converged when libraries people actually use in the wild `require` cleanly.

`ladder.md` is the ranked table. This file explains how it is built and
maintained.

## Why a ladder (and not a flat checklist)

Libraries differ enormously in how much of the host platform they touch. A
data-structure utility that calls only `clojure.core` is a far easier — and
far earlier — target than one that reaches into `java.io`, threads, or
`deftype`-heavy machinery. Ranking by **pure-Clojure degree** turns "support
real libraries" into an ordered ladder the autonomous loop can climb one rung
at a time: each rung that fails surfaces exactly one next gap to close, and
clearing it tends to unblock several libraries at once.

## Ranking method — pure-Clojure degree

Each candidate is placed by how much non-`clojure.core` host surface it
needs, lowest (easiest) first:

| Degree | Meaning                                                                     |
|--------|-----------------------------------------------------------------------------|
| 1      | Zero Java/host interop. Only `clojure.core` + bundled `clojure.*` ns.       |
| 2      | Touches `java.lang.Math` / `java.util.regex` only (cljw largely covers).    |
| 3      | Touches `java.util.*` / `java.text.*` (locale, collections, BreakIterator). |
| 4      | Touches `java.io` / readers / writers / streams.                            |
| 5      | Threads, agents, `deftype`-heavy protocols, `java.time`, reflection.        |

Degree is judged from the library's `(:import ...)` / `java.` interop forms
plus its transitive `require` graph. A library that is degree-1 in its own
namespace but transitively pulls a degree-4 namespace is ranked at the
higher (harder) degree.

## How a library is loaded today (and the limitation)

cljw has **no `deps.edn` / Maven resolution yet** — that is Campaign
Stage 1.2 (`deps.zig`). Until then, libraries are loaded by putting their
`.clj` / `.cljc` source on the classpath manually:

```sh
# Lay out the source so the namespace path matches the file path:
#   medley.core           -> <root>/medley/core.cljc
#   clojure.tools.cli     -> <root>/clojure/tools/cli.cljc
# then point -cp at the root:
zig-out/bin/cljw -cp <root> -e '(require (quote medley.core)) (medley.core/find-first even? [1 3 4])'
```

`-cp` (alias `--classpath`) is colon-separated; cljw's `require` resolver
searches each root for `<ns-path>.clj` then `.cljc` (ADR-0084). `$CLJW_PATH`
is the fallback when `-cp` is absent.

**Limitation / blocker for the ladder as a whole:** every transitive
dependency must be fetched and laid out by hand, because there is no
dependency resolver. This makes deep dependency trees impractical to verify
until Stage 1.2 lands. Libraries that are blocked *only* by this (not by a
real cljw feature gap) are marked `blocked: no deps.edn yet` in the status
column — they are not cljw failures, they are not-yet-loadable.

`.cljc` reader conditionals resolve to the `:clj` branch on cljw (cljw is a
Clojure runtime, not ClojureScript), so `#?(:clj ... :cljs ...)` picks the
JVM-shaped branch — which is exactly where the Java interop blockers live.

## How to add a library

1. Fetch its source (raw GitHub is fine for a manual probe) and lay each
   namespace out under a classpath root matching its `ns` path.
2. `require` it on cljw with `-cp <root>` and exercise a representative
   function or two.
3. Judge its pure-Clojure degree (table above) from imports + transitive
   requires.
4. Add a row to `ladder.md` with `{rank, lib, version, pure-degree, status,
   first-blocking-gap}`. Run `md-table-align ladder.md`.
5. If the library hits a **real cljw feature gap** (not just the missing
   resolver), record it in the row as `NEEDS-ROW: <gap>`. Do **not** edit
   `.dev/debt.yaml` from here — the main loop reads the `NEEDS-ROW:` markers
   and creates the debt rows, cross-referenced against the Java-tier SSOT
   (`compat_tiers.yaml`, Campaign Stage 0.3).

## Status vocabulary

- **loads** — `require` succeeds and exercised functions return correct values.
- **partial** — loads but some functions hit a gap; the gap is named.
- **fails** — `require` itself fails on a real cljw gap (named).
- **blocked: no deps.edn yet** — not a cljw gap; blocked only on manual
  dependency layout / the absent resolver (Stage 1.2).
- **not-probed** — seeded by static source inspection only; not yet loaded.
