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

`deps.edn` resolution **landed** (Campaign Stage 1.2): a `./deps.edn` with
`:paths` / `:deps {lib {:local/root "…"}}` / `:git/url`+`:git/sha` / `:aliases`
contributes its source roots to the front of the `require` classpath, so a
library is loaded by pointing a small consumer `deps.edn` at it:

```sh
# A consumer project whose deps.edn names the library by :local/root:
#   {:deps {org.clojure/data.priority-map {:local/root "/path/to/clone"}}}
cd consumer-proj && cljw -e '(require (quote clojure.data.priority-map))'
```

The older manual classpath still works: `-cp <root>` (alias `--classpath`,
colon-separated) makes `require` search each root for `<ns-path>.cljw`, then
`.clj`, then `.cljc` (ADR-0084, ADR-0189); `$CLJW_PATH` is the fallback when
`-cp` is absent. `.cljw` is cljw's own extension and is probed first, so a
`foo/bar.cljw` beside a `foo/bar.clj` is the file cljw loads — the same
precedence ClojureScript gives `.cljs` over `.cljc`. Roots are still searched
in order, so an earlier root's `.clj` beats a later root's `.cljw`.

**The residual limitation is Maven, not deps.edn:** a `:mvn/version` coord is
**skipped** (ADR-0101 am.1), not fetched — cljw has no artifact downloader — so
a transitive **Maven** dependency must still be cloned and supplied as an
explicit `:local/root` / `:git` coord by hand. A library blocked *only* by an
un-cloned transitive dep (not a real cljw feature gap) is marked
`blocked: no deps.edn yet` historically; the accurate phrasing is "blocked on an
un-fetched Maven/transitive dep" — they are not cljw failures, just
not-yet-loadable without laying the dep out.

`.cljc` reader conditionals resolve against the feature set
`{:cljw, :clj, :default}` (ADR-0188). cljw is a Clojure runtime, not
ClojureScript, so `#?(:clj ... :cljs ...)` picks the JVM-shaped branch — which
is exactly where the Java interop blockers live. `:cljw` names *this* runtime
for the cases where it diverges from the JVM; since branches are read
left-to-right, it only wins where an author put it ahead of `:clj`, so an
existing library reads exactly the branch it always did.

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
   (`data/compat_tiers.yaml`, Campaign Stage 0.3).

## Status vocabulary

- **loads** — `require` succeeds and exercised functions return correct values.
- **partial** — loads but some functions hit a gap; the gap is named.
- **fails** — `require` itself fails on a real cljw gap (named).
- **blocked: no deps.edn yet** (historical label) — not a cljw gap; blocked
  only on an un-fetched transitive **Maven** dep that must be cloned + supplied
  as a `:local/root` / `:git` coord by hand (the `:paths`/`:local/root`/`:git`
  resolver itself landed, Stage 1.2).
- **not-probed** — seeded by static source inspection only; not yet loaded.
