# ADR-0084 — `require` loads namespace source from the filesystem (D-158)

- **Status**: Proposed → Accepted (2026-06-03)
- **Debt**: D-158 (this). Capstone of the real-lib-compat stack (D-226
  syntax-quote, D-230 `*ns*`/ns-reflection, D-227 clojure.test all met).
- **Depends on**: ADR-0035 (require/in-ns scaffolding, `require_in_progress` +
  `circular_require` reservation), ADR-0036 (dual-backend parity), zone_deps
  (Layer 1 `eval/` vs Layer 2 `lang/`).

## Context

`require` resolves only bootstrap-EMBEDDED namespaces today. Both backends
already (a) check `env.findNs` for already-loaded, (b) call
`rt.require_resolver` for source bytes, (c) get the bytes — then raise
`feature_not_supported` instead of evaluating them (`tree_walk.zig:~464`,
`vm.zig` `op_require:~557` + `op_require_with_libspec:~584`). `:as`/`:refer`/
multi-`:require` in `(ns …)` already work (the `ns` macro expands to per-spec
single-libspec `require` calls); only the SOURCE-LOAD is missing. This ADR adds
filesystem loading so a real lib (a directory of `.clj` files) and its
`clojure.test` suite run on cljw.

## Decision

Adopt **Alt 2** (DA-recommended). Plain dirs of `.clj`/`.cljc` only — no JVM
classloader, no jar/zip resources (the prominent divergence).

1. **Classpath = `rt.load_paths: []const []const u8`**, populated in the CLI
   from `--classpath`/`-cp` (colon-separated) and the `CLJW_PATH` env, default
   `["."]`. Two roots (`src:test`) is the real-lib minimum; a colon-path list is
   exactly that. **deps.edn parsing deferred** (own ADR — it just populates the
   same `load_paths` later; correct layering, not a smallest-diff dodge).
2. **Resolver returns `?ResolvedSource { source, label }`** (signature change to
   the reserved `RequireResolverFn` slot — a reservation is a memo, not a
   contract). The `label` is the SourceContext key: a real filesystem path for
   disk libs (so errors render `src/foo/bar.clj:12`), the `<ns-name>` sentinel
   for embedded. This is what makes error rendering correct for both source
   kinds without the helper guessing.
3. **Resolver chaining = a 2-element `chainedResolver`, embedded-FIRST** then
   filesystem. Embedded-first is mandatory: `clojure.core`/`clojure.test` must
   never be shadowed by a stray on-disk file of the same name. A resolver LIST
   is premature (only two sources exist; the Phase-16 pod resolver is a
   reservation — build the list when a third consumer actually lands; YAGNI).
4. **Shared load helper in a NEW Layer-1 module `src/eval/loader.zig`** (NOT
   bootstrap.zig — that is Layer 2; `eval/backend/*` importing it would violate
   zone_deps). `loader.loadNamespace(rt, env, macro_table, arena, ns, source,
   label)`: `registerSource(label, source)` → if `require_in_progress.contains(ns)`
   → `circular_require` → `put(ns)` → save `env.current_ns` → Reader-loop
   {read → analyzeForm → evalForm} (the loaded file's own `(ns …)` switches
   current_ns) → `defer setCurrentNs(saved)` → `loaded_libs.put(ns)` →
   `require_in_progress.remove(ns)`. Both backends call this one body (parity).
5. **Idempotency = `findNs` + NEW `rt.loaded_libs`**. `findNs(mappings>0)` is
   necessary but NOT sufficient: during `a→b→a`, ns `a` exists with partial
   mappings before its body finishes, so a re-entrant require could skip and
   return a half-built ns. `require_in_progress` (in-flight → `circular_require`)
   + `loaded_libs` (completed → idempotent skip) is the robust pair (F-011
   `*loaded-libs*` parity). `:reload` deferred (orthogonal).
6. **New error Code `lib_load_failed`** — a file that exists but fails to
   open/read (permissions, I/O error). `lib_not_found` (null resolver) conflates
   "no such lib" with "found but unreadable"; clj distinguishes them. (No new
   F-004 slot — `load_paths`/`loaded_libs` are plain Runtime fields.)
7. **Install the chain in CLI run + REPL** (both embedded-first, so core stays
   deterministic). **Test Fixtures + the embedded bootstrap path stay
   embedded-only** so a stray `.clj` in a test's cwd can never perturb a unit /
   diff test.

Deferred to their own debt rows: deps.edn (D-NNN), `:reload`/`:reload-all`,
the standalone-`require` multi-libspec wall (`special_forms.zig:480` — real
`(ns …)` forms don't hit it).

## Consequences

- A real pure-Clojure lib (dir of `.clj`) loads via `(require '[lib.core])` and
  its `clojure.test` suite runs on cljw — the D-158 goal + the payoff of the
  whole macro/ns/test stack.
- `RequireResolverFn` signature change ripples to the 3 raise sites + the
  resolver-direct tests (bootstrap.zig / runtime.zig) — mechanical.
- `loaded_libs` holds gpa-owned dup'd ns-name keys, freed in `Runtime.deinit`
  (mirroring `require_in_progress` teardown).
- Errors inside a loaded lib render with the lib's path:line (registerSource).

## Affected files

- `src/runtime/runtime.zig` — `load_paths`, `loaded_libs` fields + deinit;
  `RequireResolverFn` → `?ResolvedSource`.
- `src/eval/loader.zig` (NEW) — `loadNamespace` + `ResolvedSource`.
- `src/lang/require_resolver.zig` (NEW) — `filesystemResolver` (ns→path munge,
  search `load_paths`, read via `std.Io.File`) + `chainedResolver`.
- `src/lang/bootstrap.zig` — `embeddedResolver` returns `{source, label}`.
- `src/eval/backend/tree_walk.zig` + `vm.zig` — replace the 3 raises with
  `loader.loadNamespace`.
- `src/runtime/error/catalog.zig` — `lib_load_failed` Code.
- `src/app/cli.zig` + `repl.zig` — parse `-cp`/`CLJW_PATH` → `load_paths`,
  install `chainedResolver`.
- `test/e2e/phase15_require_fs.sh` (NEW) + a fixture lib under
  `test/e2e/fixtures/`.

## Alternatives considered

(Verbatim from the mandatory Devil's-advocate fork, fresh context, agent
`a006f0ffeb7733a02`. Recommendation Alt 2; the main loop concurs.)

> ## Alt 1 — SMALLEST-DIFF (cwd-relative, chained resolver, helper in
> bootstrap.zig)
> (a) cwd-relative only; munge + open `./<munged>.clj`/`.cljc`. No load_paths,
> no flag. (b) chainedResolver embedded-first in main. (c) helper in
> bootstrap.zig. (d) reuse findNs + activate require_in_progress, no loaded_libs.
> Better: minimal surface. **Breaks**: real libs are `src:test` (two roots) —
> D-158's own goal; cwd-only cannot find `test/foo_test.clj` from repo root.
> bootstrap.zig placement violates F-009 AND zone_deps (Layer-2 import from
> Layer-1 backends) — an independent disqualifier. A false economy: fails the
> goal and still pays the helper+cycle+dual-backend cost.
>
> ## Alt 2 — FINISHED-FORM-CLEAN (load_paths + new loader module, embedded-first
> chain) ⭐
> (a) `rt.load_paths` from `-cp`/`CLJW_PATH`, default `["."]`; two roots is the
> real-lib minimum; defer deps.edn (correct layering, sits on the same field
> later). (b) single slot + `chainedResolver` embedded-FIRST (core never
> shadowed); a resolver list is premature (two sources; pod is a reservation —
> YAGNI). (c) new `src/eval/loader.zig` (Layer 1 — bootstrap.zig is Layer 2 and
> must not be imported by eval/backend/*); loadNamespace = registerSource → cycle
> guard → save ns → Reader-loop analyze+eval → defer restore ns → loaded_libs →
> pop in-progress; macro_table threads in; resolver returns {source,label} so the
> label is the path (disk) or `<ns-name>` (embedded). (d) findNs is necessary but
> NOT sufficient (partial mid-load ns exists with mappings>0 before body
> finishes); need require_in_progress + loaded_libs both; :reload defer. Better:
> the only alt satisfying D-158's multi-root goal; clean zone placement; cycle +
> idempotency as finished form; chain immune to shadowing. Breaks/risks:
> RequireResolverFn signature change ripples to 3 sites + resolver-direct tests
> (mechanical); loaded_libs lifetime = gpa-dup'd keys freed in deinit. Larger
> diff — recommend anyway per F-002.
>
> ## Alt 3 — WILDCARD (resolver returns loader closures / NsProvider objects)
> load_paths modeled as `rt.providers: []NsProvider`, each a self-contained
> resolve(ns)→{source,label} with its own munge policy; slot becomes a
> provider-list iterator. Better: maximally extensible (Phase-16 pod + AOT-cache
> providers slot in with zero churn). Breaks/risks: introduces a vtable-ish
> provider abstraction BEFORE the second non-embedded consumer exists — textbook
> Reservation-as-bias + over-skeleton (enlarges the finished-form rewrite, dead
> weight until Phase 16; risks the pub-var/vtable patterns zone_deps warns
> against).
>
> ## Cross-cutting
> (f) Error rendering: registerSource(label, bytes) as the FIRST step, label =
> resolved path; embedded label = `<ns-name>` sentinel (matches `<clojure.set>`
> convention). The resolver returning {source,label} is what makes this correct
> for both kinds. (g) Standalone-require multi-libspec wall: DEFER — the ns macro
> expands per-spec, so real `(ns …)` never hits it; lifting it is a separate REPL
> parity item (own debt row), bundling = scope-creep. (h) Install: main/CLI +
> REPL get the chain (embedded-first preserves core determinism); test Fixtures +
> embedded bootstrap stay embedded-only (deterministic). New F-004 slot: none.
> New error Code: `lib_load_failed` (found-but-unreadable, distinct from
> lib_not_found); circular_require + lib_not_found already exist.
>
> ## Recommendation
> Alt 2: load_paths + `-cp`/`CLJW_PATH`, new `src/eval/loader.zig` shared by both
> backends, embedded-first 2-element chain (no provider list),
> require_in_progress + loaded_libs both activated, RequireResolverFn→{source,
> label}, deps.edn + :reload + multi-libspec wall deferred. The only alt that
> satisfies the multi-root goal; Alt 1 fails it + breaks zone_deps; Alt 3 builds
> Phase-16 machinery with no present consumer. Larger diff is not a downgrade
> reason (F-002).
