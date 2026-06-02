# ADR-0082 — Syntax-quote: reader Form nodes + analyzer expansion (hybrid)

**Status**: Proposed → Accepted (2026-06-03, D-226). STAGE 1 (non-qualifying:
`~`/`~@`/`foo#`/templates + the `valueToForm` lazy-seq-forcing fix) LANDED
2026-06-03; STAGE 2 (symbol qualification + nested backtick) pending (D-226 open).

## Context

Syntax-quote (`` ` ``/`~`/`~@`/`foo#`) is unimplemented (D-226) — `` `(+ ~x 1) ``
→ "Unable to resolve symbol: '`'" (verified from a file). It is the single
highest-value clj-parity gap: every real-world Clojure library macro uses
backtick, so `(require some-lib)` fails on the lib's macros. It gates the
"run real Clojure libs" goal (D-158).

cljw's reader is namespace-UNAWARE by deliberate design (read = pure text→Form;
ns-resolution lives in the analyzer — `::name` auto-keywords set an
`auto_resolve` flag the analyzer resolves via `resolveAutoKeyword` against
`env.current_ns`). clj's reader, by contrast, resolves syntax-quote symbols at
READ time (its reader consults `*ns*`).

The three sub-problems split unevenly: `~`/`~@`/nesting/auto-gensym are pure
structural transforms (need no ns); **symbol qualification** (`` `foo `` →
`current-ns/foo`, `` `+ `` → `clojure.core/+`) is the only ns-dependent part and
the entire source of macro hygiene.

## Decision

**Alt 2 (DA-recommended): hybrid.** The reader adds Form nodes
`.syntax_quote`/`.unquote`/`.unquote_splicing` and does ZERO expansion (stays
pure). The **analyzer** owns expansion: on a `.syntax_quote` node it has
`env.current_ns` + the alias/refer table, so it builds the
`(seq (concat (list …) …))` tree — generalizing the `resolveAutoKeyword`
"reader marks / analyzer resolves" precedent instead of inventing a parallel
resolver, and keeping the reader's pure text→Form invariant.

**Staged (DA-endorsed bisectable path):**
1. **This commit — structural transform, PROVISIONAL (non-qualifying)**: tokenizer
   `` ` ``/`~`/`~@`; reader Form nodes; analyzer expander handling `~`/`~@`/
   nesting/`foo#` auto-gensym + list/vector/map/set, with symbols left BARE
   (`` `foo `` → `(quote foo)`). This makes single-ns + core-symbol macros work
   (the caller refers core / same ns), but **HARD-FAILS on a macro that backtick-
   references its own ns's private helper** (`` `helper `` → bare `helper`,
   unresolved at the call site) — so D-226 is **NOT discharged**; a `PROVISIONAL:`
   marker + feature_deps + debt row track the close-out.
2. **Next cycle — qualification**: the expander resolves each non-special, non-
   `~`, non-`foo#`, non-`.`-interop symbol to its ns-qualified form (var's ns if
   resolvable, else current ns) — the hygiene that makes real libs work. Also
   qualify the emitted `seq`/`concat`/`list`/`apply` as `clojure.core/…` so a
   caller shadow can't break the expansion. THEN discharge D-226 against a corpus
   of real-library-shaped macros (same-ns private helper + caller-shadowed core).

F-002 (finished form = Alt 2 with qualification; the provisional step is marked,
not a terminal shape). F-011 (a backtick macro must expand+run like clj).

## Alternatives considered

(Devil's-advocate fork, fresh context — verbatim summary.)

The design axis collapses to: **where does qualification live, and is it done at
all?** The structural transform (`~`/`~@`/gensym/nesting) is shared machinery.
Correction the DA flagged: clj resolves syntax-quote symbols to fully-qualified
`(quote ns/sym)` literals INSIDE the expansion, AND qualifies the emitted
`seq`/`concat`/`list` as `clojure.core/…` (a second hygiene surface).

- **Alt 1 — SMALLEST-DIFF: reader builds the full expansion, NON-qualifying.**
  Entirely in the reader (mirrors `readQuote`), bare symbols, reader-local
  gensym map. BREAKS F-011 and worse than "hygiene nicety": a macro that
  backtick-references its OWN ns private helper produces a bare symbol with NO
  call-site referent → hard failure, pervasive in real libs. Shipping it as a
  TERMINAL shape closing D-226 = a false-positive discharge (clj_diff_sweep
  Discipline 1). Acceptable ONLY as an explicitly-PROVISIONAL first commit.

- **Alt 2 — FINISHED-FORM: hybrid, reader `.syntax_quote` node + analyzer
  expansion with full ns.** F-011-correct (true qualification → hygiene → real
  libs work); resolution lives where `resolveAutoKeyword` already lives (no
  second resolver); reader stays pure; nesting-depth handled in ONE auditable
  analyzer fn; natural future home for `macroexpand-1`. One narrow divergence:
  `read-string` of a backtick form returns the `.syntax_quote` Form (clj returns
  the expanded data) — fixable by routing `read`/`read-string` through the same
  expander (debt row). Must also expand under `quote` (`` '`foo `` expands in clj).

- **Alt 3 — WILDCARD: thread current-ns INTO the reader (clj-faithful read-time).**
  Maximal fidelity incl. the `read-string` edge. REJECTED on cleanliness (not
  cost — F-002 forbids cost-downgrade): it REVERSES the deliberate pure-reader /
  ns-aware-analyzer split and duplicates resolution (reader for backtick,
  analyzer for `::`). clj does read-time resolution only because its reader and
  evaluator are fused with no separate analyzer; cljw has the split already, so
  the clean finished form puts all ns-resolution in the analyzer.

**DA recommendation (non-binding): Alt 2**, landing the structural transform
first (optionally as the marked-provisional non-qualifying intermediate of Alt
1's machinery), then the analyzer qualification pass — discharging D-226 only
when real-library-shaped macros run equivalently to clj. The main loop accepts
Alt 2 with this staging.

## Consequences

- This commit: `~`/`~@`/`foo#`/nesting work; single-ns + core-symbol macros run;
  D-226 stays open (qualification pending), PROVISIONAL-marked.
- Affected: `src/eval/tokenizer.zig` (3 tokens), `src/eval/form.zig` (3 Form
  nodes), `src/eval/reader.zig` (read the nodes), `src/eval/analyzer/` (the
  syntax-quote expander), corpus + e2e. Next cycle adds qualification +
  closes D-226 + the `read-string`-of-backtick debt.
