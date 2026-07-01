# Clojure-namespace license attribution (EPL-2.0)

Auto-loaded when editing any `src/lang/clj/clojure/**/*.clj`. Codifies the
license-header convention so the judgement is made once (here) and never
re-litigated per file. The settled work order is
`private/20260609_license_research/PROMPT.md` § B (D-366); this rule is its
durable, machine-guaranteed form.

## The convention (judgement-less)

**Every `.clj` under `src/lang/clj/clojure/` MUST carry the line
`;; SPDX-License-Identifier: EPL-2.0` as part of its file header.** This
holds for any new namespace brought in from Clojure too. The classification
criterion is **namespace origin only** — a file lives under `clojure/`
because it implements a Clojure / Clojure-contrib API, so it is EPL-2.0.

`src/lang/clj/cljw/**` is **out of scope**: those namespaces are
ClojureWasm-original (no upstream lineage), so they carry no upstream
attribution. `.zig` is clean-room; tree-level attribution is
`legal/NOTICE`.

**Docstrings are not notices** — never edit a docstring for attribution
reasons, even when its text is copied from upstream (that is what variant ①
records explicitly).

## The two header variants

Which variant a file gets depends on **whether it reproduces upstream source
text**, not on the namespace:

### Variant ① — upstream source text reproduced (banner retained)

Only files that actually reproduce upstream text. As of D-366 exactly two:
`clojure/template.clj` (verbatim copy) and `clojure/core/protocols.clj`
(docstrings reproduced). These keep the upstream EPL banner so attribution
to Rich Hickey / the original author is preserved per EPL-1.0 §7:

```clojure
;; SPDX-License-Identifier: EPL-2.0
;;
;;   Copyright (c) Rich Hickey. All rights reserved.
;;   The use and distribution terms for this software are covered by the
;;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php).
;;   By using this software in any fashion, you are agreeing to be bound by the
;;   terms of this license. You must not remove this notice, or any other, from
;;   this software.
;;
;;   <file> — by <author>. Reproduced in ClojureWasm; redistributed
;;   under EPL-2.0 per EPL-1.0 §7. ClojureWasm changes (c) the ClojureWasm authors.
```

A new file gets variant ① **only if you literally paste upstream source
text** into it. The default for a fresh namespace is variant ②.

### Variant ② — independent reimplementation (the common case)

Every other `clojure/` namespace is an independent reimplementation (no
upstream source text reproduced). It carries the CW-copyright header citing
the upstream lineage as courtesy:

```clojure
;; SPDX-License-Identifier: EPL-2.0
;; Copyright (c) the ClojureWasm authors. Licensed under EPL-2.0.
;; Independently reimplements the <NS> API (originally <ORIG>; Clojure, EPL-1.0)
;; for ClojureWasm; no upstream source text is reproduced.
```

`<NS>` = the namespace (e.g. `clojure.set`); `<ORIG>` = the original
author(s) (e.g. `Rich Hickey`). The header is a **pure prepend** above the
file's existing comments — do not touch the body or docstrings.

## Discovery criterion (framework_completion.md mandate)

Enumerate header-less files (the sweep recipe — also used by the hook):

```sh
find src/lang/clj/clojure -name '*.clj' | xargs grep -L 'SPDX-License-Identifier: EPL-2.0'
```

> **Do NOT use `git ls-files 'src/lang/clj/clojure/**/*.clj'`** as the
> discovery recipe. Git pathspec `**` does not match a single path segment,
> so that glob silently skips the top-level `clojure/*.clj` files
> (`core.clj`, `set.clj`, `edn.clj`, `math.clj`, `string.clj`, …). `find`
> (or `git ls-files 'src/lang/clj/clojure/' | grep '\.clj$'`) is correct.

A clean run (empty output) means every file is attributed.

## Sweep + retrofit record (D-366)

The introducing cycle (2026-06-10) ran the recipe and retrofitted all 16
existing files in the same cycle (B-1 = the retrofit): 2 variant ① +
14 variant ② (`core`/`set`/`walk`/`zip`/`data`/`string`/`test`/`java.io`/
`math`/`pprint`/`edn`/`data.json`/`data.csv`/`tools.cli`). Sweep note:
`private/notes/D366-license-attribution.md`. No exemptions
(`.dev/watch_findings.md` carries none for this rule).

## Enforcement

`scripts/check_clj_attribution.sh` is a PreToolUse hook on `git commit`
(wired in `.claude/settings.json` alongside `check_smell_audit.sh` /
`check_gate_cadence.sh`, reusing `hook_lib.sh`). It scans the working tree
and **fail-closed blocks** any commit while a `clojure/**/*.clj` lacks the
SPDX line — so a header-less file can never be committed. Both variants
carry the SPDX line, so the single check guarantees both.

## Cross-references

- `private/20260609_license_research/PROMPT.md` § B — the settled work order
  (judgement; this rule is its durable form) + `REPORT.md` (rationale).
- `legal/NOTICE` — tree-level attribution (the import relationship +
  the two variant-① files).
- `LICENSE` (EPL-2.0) — the project license.
- `.claude/rules/framework_completion.md` — the discovery + sweep + retrofit
  discipline this rule + its hook satisfy in one cycle.
- `scripts/check_clj_attribution.sh` — the enforcement hook.
