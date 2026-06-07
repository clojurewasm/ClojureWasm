# ADR-0111 — deps.edn run modes `-M` / `-X` (in-process clojure.main grammar)

- **Status**: Proposed → Accepted
- **Date**: 2026-06-07
- **Discharges**: D-309 (deps.edn run-mode, user idea)
- **Opens**: D-310 (`*command-line-args*` binding — deferred sibling)
- **Cross-refs**: ADR-0101 (+ amendment 1, deps.edn git-fetch / `:mvn`-skip),
  F-002 (finished-form), F-009 (feature-impl neutrality — thin Zig surface over
  the one bootstrap+eval chain), F-013 (definition-derived capability);
  `private/notes/stage14-deps-run-mode-survey.md`

## Context

cljw resolved a deps.edn **classpath** only (Stage 1.2 / ADR-0101): `-A:aliases`
merged `:extra-paths`/`:extra-deps`, but `:main-opts` / `:exec-fn` / `:exec-args`
were parsed-skipped and the entry points were `cljw <file>` / `cljw -e`. A real
user runs an app with `clj -M:alias -m my.ns` or a tool with `clj -X:build
fn`. The user directed cljw to implement these run modes (and to align the
`verified_projects/` convention onto them so future proofs are deps.edn-idiomatic
`-M:verify` rather than a bare `verify.clj` script).

The survey (`stage14-deps-run-mode-survey.md`) mapped the two nesting grammars
(the launcher `-A`/`-M`/`-X` and the `clojure.main` `-i`/`-e`/`-m`/`file`
mini-grammar) and found three concrete cw v0 gaps to NOT repeat:

1. v0's `-M` called `(ns/-main)` with **no args** and did not append the user's
   trailing args to the alias `:main-opts`.
2. v0 never bound `*command-line-args*` for `-M`/`-X`.
3. v0's `-X` emitted every value as a **quoted string** (`:n 5` → `{:n "5"}`),
   losing EDN types.

## Decision

1. **In-process combined grammar.** cljw is JVM-less and single-process, so the
   launcher + `clojure.main` grammar run in one process (no `exec java
   clojure.main` hand-off — the cw v0 shape, kept). New `src/app/deps/run_mode.zig`
   owns it; `cli.zig` detects `-M`/`-X`/bare-`-m`, drains the remaining argv as
   verbatim run-args, resolves the classpath (+ parsed `cfg`), and dispatches.

2. **`-M[:aliases] [main-opts…]`** — effective opts = the last selected alias's
   `:main-opts` with the user's trailing args **APPENDED** (clj append, fixing
   v0 gap 1/3). First-token dispatch:
   - `-m ns [args]` → synthesize `(let [m (requiring-resolve 'ns/-main)] (if m (m
     "arg"…) (throw (ex-info "Namespace ns has no -main fn" {}))))` — args reach
     `-main` as strings; a missing `-main` is a clean message (survey edge 2).
   - `-e expr` → eval + print non-nil (the standalone `cljw -e` contract).
   - bare `file.clj` → load the script (no result print).
   - `-h` → the `-M` usage.

3. **`-X[:aliases] [ns/fn] [:k v…]`** — `:exec-fn` = a trailing CLI symbol
   (overrides) else the alias's; `:exec-args` = the alias map merged under CLI
   `:key value` pairs (CLI wins). Synthesize `(let [f (requiring-resolve 'ns/fn)]
   (if f (f (merge (quote ALIAS) (quote {CLI}))) (throw …)))`. **Both maps are
   `quote`d**: `-X` args are EDN *data*, never evaluated — so a numeric/boolean
   value keeps its type (fixing v0 gap 3) and a bare-symbol value stays a literal
   instead of being resolved. The result is **not printed** (clj `-X` contract).

4. **`print_results` on `runner.runSource`.** `-M -m` / file / `-X` pass `false`
   (`clojure.main` never prints a `-main`/`:exec-fn` value); `-e` and the plain
   `cljw -e`/file paths pass `true`. One bool gates the per-form `printResult`;
   the GC pin stays unconditional (forcing the value can still re-enter the VM).

5. **Bare top-level `-m`** (`cljw -m my.ns a b`, no `-M`) routes through the same
   main grammar — clj's launcher resolves it via `-M`, but in-process cljw accepts
   it directly (the `-m` token leads the run-args).

6. **`verified_projects/<lib>/` convention flips to `-M:verify`.** Each project's
   `deps.edn` gains `:paths ["."]` + `:aliases {:verify {:main-opts ["-m"
   "verify"]}}`, and `verify.clj` becomes `(ns verify (:require …))` + `(defn
   -main [& _] …asserts… (println "OK <lib>"))`. `scripts/verify_projects.sh`
   runs `cljw -M:verify`, so the sweep exercises the real deps.edn run-mode path a
   user invokes, not a bespoke entry.

### Divergences from clojure.main (cljw is JVM-less)

- **No second-process hand-off** — the whole grammar is in `cli.zig` +
  `run_mode.zig`; the only contract preserved is the alias-`:main-opts`-then-user
  -args APPEND.
- **`*command-line-args*` binding (D-310 part-1, landed same session).** A
  `(def ^:dynamic *command-line-args* nil)` in core.clj; `run_mode.zig` prepends
  `(alter-var-root (var clojure.core/*command-line-args*) (constantly (list …)))`
  to every `-M`/`-X` run — a **root-set, not a `binding`**, because cljw evals
  form-by-form and a `binding` cannot span a multi-form script. Covers -m /
  file-script / -X uniformly (the trailing args; nil for none). Migrates cleanly
  to the Alt-3 Clojure grammar (it would set the same root).
- **`-i` / `-r` / `--report` main-opts and `@resource` script paths are
  deferred** (D-310) — the survey ranks them medium-value; `-m`/`-e`/file/`-X`
  cover the real usage. An unrecognised `-M` main-opt is a clean error, not a
  silent script-path fallthrough.

## Alternatives considered (Devil's-advocate, fresh-context subagent, verbatim)

> **Verdict up front:** the source-string-synthesis crux is a genuine
> smallest-diff convenience, not the finished-form-clean marshalling. F-009 (one
> eval chain) does *not* mandate source-string assembly — it mandates one
> *bootstrap+eval setup*. Resolving the var and applying it via the existing Zig
> apply surface (`invokeCallable` / `vtable.callFn`) inside that same `rt`/`env`
> is equally F-009-compliant and removes a re-parse + a hand-rolled
> escaping/quoting layer that is the ADR's own stated "correctness crux." None of
> the three alternatives below violates an F-NNN.
>
> **Alt 1 — Smallest-diff: keep synthesis, extract a shared quoting helper.**
> Move `writeStringLiteral` + the `quote`-EDN-splice into a reusable
> `synth_quote.zig` + a round-trip test (argv → literal → reader → equal bytes) +
> a "value with `}`/newline/unicode" corpus. Better: closes the draft's biggest
> latent risk — the splice is `writeAll(kvs[i+1])` *verbatim*, so an argv value of
> `{:a 1` or an unbalanced-paren string is injected raw; only string *literal*
> args are escaped, EDN values are not validated. A reader round-trip test catches
> malformed-EDN injection before it becomes a confusing eval error. Breaks:
> nothing structural — but it entrenches the re-parse (argv read once, serialized
> to text, re-read by the Clojure reader), the very thing F-002's finished form
> would not keep. Not recommended (cycle-minimizing).
>
> **Alt 2 — Finished-form-clean (RECOMMENDED): resolve + apply in Zig, no
> re-parse.** Add `runner.runEntryFn(… ns_sym, fn_name, arg_values: []const Value,
> print)` sharing `runSource`'s exact setup (refactor it into a `prepare()`
> returning the bootstrapped `rt`+`env` — F-009's one chain becomes literally one
> function). `run_mode.zig` then: `-M -m` → `requiring-resolve` the `ns/-main` var
> as a Value, build args as `[]const Value` of cljw string Values (no escaping —
> they are Values), `invokeCallable`. `-X` → parse CLI `:k v` with the existing
> reader into Values, `merge` onto the alias `exec-args` (already a `Form` in
> `cfg`!), apply. No `quote`, no string assembly. Better: (a) argv EDN read once;
> (b) deletes the entire escaping/quoting surface the ADR flags as the
> "correctness crux"; (c) the `exec-args` alias map is already parsed — re-
> serializing via `formatPrStr` only to re-read is pure waste removed; (d) errors
> point at the real fn/args, not a `<-X>` synthetic label; (e) the `-main`-missing
> guard moves into Zig `error_catalog.raise` (the SSOT per `error_catalog_only.md`;
> the draft's synthesized `ex-info` bypasses it). Breaks: factor `runSource` setup
> into `prepare()` (low ripple); needs `requiring-resolve` Zig-callable (it is, a
> clojure.core var); larger diff than Alt 1 — recommended anyway per F-002.
>
> **Alt 3 — Wildcard: a real `*command-line-args*` + a `clojure.main`-shaped
> Clojure entry.** Bind `*command-line-args*` now (the ADR defers it to D-310) and
> express the whole `-M` grammar as a small `clojure.main`-shaped fn in
> `clojure.core` (or `cljw.run`), invoked from Zig with the argv vector as Values.
> The Zig side shrinks to "resolve `cljw.run/main` + apply argv"; the grammar
> (`-m`/`-e`/`-h`/file) lives in Clojure, reader-checkable + `.clj`-unit-testable.
> Better: the grammar becomes data-driven Clojure (definition-derived per F-013 —
> one general mechanism, not Zig per-flag branches); discharges D-310 in one
> stroke; matches how real clojure.main *is* Clojure — most finished-form-aligned
> with "cljw is a Clojure runtime." Breaks: bootstrap ordering — `cljw.run` must be
> loadable before classpath/user-ns resolution (a real sequencing question);
> biggest blast radius; risks pulling D-310 + a new ns into one cycle. A
> reasonable *next* step after Alt 2, not instead of it.
>
> **On the sub-questions.** `print_results` bool: minor smell, not Alt-level
> surgery; Alt 2 makes it a property of the entry (`runEntryFn` is inherently
> `print=false`) rather than a threaded param. `quote`d-map for `-X`: correct
> semantically, but exists *only because* the data was flattened to text and must
> be protected from re-evaluation — in Alt 2 the data never becomes text, so
> `quote` is unnecessary; the need for it is a symptom of the re-parse.
>
> **Recommendation: Alt 2.** Finished-form-clean within the full F-NNN envelope
> (F-009 one-chain preserved by `prepare()`, F-013 untouched, JVM-less untouched,
> error_catalog SSOT restored). Deletes the self-identified correctness crux rather
> than testing around it. Larger diff is not a reason to downgrade (F-002). Alt 3
> is the further-horizon ideal but couples in D-310 + bootstrap-ordering risk;
> sequence it after Alt 2.

**Main-loop disposition (not bound by the DA recommendation within the F-NNN
envelope).** The loop keeps the **source-synthesis** approach and declines Alt 2,
on a *substantive* (not cycle-budget) ground: **`clojure.main` is itself Clojure
code** — `-m` is `(apply (ns-resolve (doto (symbol ns) require) '-main) args)`,
`-X` is `(the-fn merged-map)`, both *evaluated as Clojure*. For a from-scratch
Clojure runtime, the finished form keeps that orchestration **in Clojure-eval**,
with a thin Zig wrapper handing a Clojure form to the one chain — which is exactly
**F-009** (surfaces are thin wrappers; the semantics live in the neutral/Clojure
layer). Alt 2 pulls the resolve/apply/merge orchestration *into Zig*, thickening
the surface against F-009. The DA itself ranks **Alt 3 (grammar in Clojure)** as
"most finished-form-aligned with 'cljw is a Clojure runtime'" — confirming the
true finished form is Clojure-level, not Zig-Value-marshalling. Alt 3 is
bootstrap-ordering-gated (the grammar ns must load before user libs) and is
**scoped to D-310** (which also owns `*command-line-args*`); the current synthesis
is the bootstrap-safe intermediate that lands the capability now and migrates
cleanly to Alt 3 later (the synthesized form *is* the Clojure body Alt 3 would
host). This is **not** a smaller-diff-for-its-own-sake pick — it is the F-009-thin
surface, and Alt 3 (not Alt 2) is the agreed end state.

Two DA critiques are folded without adopting Alt 2: (1) **malformed-EDN `-X`
value** — a verbatim-spliced bad token (`{:a`) yields a reader error against the
`<-X>` label; this matches clojure's own "`-X` value is EDN-read, malformed →
error" behaviour, so it is acceptable (a parse error, not a silent
mis-eval), recorded here rather than guarded. (2) the synthesized `ex-info`
"has no -main fn" is a **user-level Clojure throw** (mirroring clojure.main's own
missing-`-main` error), not a Zig `setErrorFmt` bypass — so `error_catalog_only.md`
(which governs Zig-raised runtime messages) is not violated; when Alt 3 lands, the
guard moves into the Clojure grammar fn.

## Consequences

- **Positive**: cljw runs real apps (`-M -m`) and tools (`-X` build fns); the
  `verified_projects/` proofs become deps.edn-idiomatic and exercise the run-mode
  path. The three v0 gaps are fixed (args to `-main`, append semantics, EDN-typed
  `-X` values). All synthesis reuses `runner.runSource` (F-009 one-chain
  bootstrap) — no second eval engine.
- **Negative**: the `-M` mini-grammar is a first-token subset (no mixed
  `-e`-init-before-`-m`, no `-i`/`-r`/`--report`/`@resource`) — tracked as D-310.
  `*command-line-args*` is unbound, so library code reading it sees nil until
  D-310. Run-mode synthesis is source-string assembly (not a structured arg
  vector); the quoting discipline (`-X` data via `quote`, `-m` args via string
  literals) is the correctness crux.

## Affected files

- `src/app/deps/parse.zig` — `Alias` gains `main_opts` / `exec_fn` / `exec_args`;
  `parseAliases` captures them; `symbolName` helper.
- `src/app/deps/run_mode.zig` — **new**; `-M`/`-X` synthesis + dispatch.
- `src/app/cli.zig` — `-M`/`-X`/bare-`-m` detection + run-arg drain; `loadDepsEdn`
  returns `{load_paths, cfg}`; run-mode branch; `-h` text.
- `src/app/runner.zig` — `runSource` gains `print_results`.
- `src/main.zig` — test aggregator entry for `run_mode.zig`.
- `test/e2e/phase14_deps_run_mode.sh` — **new**; 7-case smoke. `test/run_all.sh`
  wires it.
- `verified_projects/*/` — deps.edn `:verify` alias + `(ns verify)` `-main`;
  `scripts/verify_projects.sh` runs `cljw -M:verify`; `verified_projects/README.md`.
