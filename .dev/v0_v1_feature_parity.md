# v0 → v1 feature parity

Convergence Campaign Stage 0.2 deliverable. Enumerates every v0 (ClojureWasm
v0.5.0, the read-only reference clone) bundled namespace + app feature and maps
each to its v1 (`main`) status, with the owning debt row (or
`NEEDS-ROW` where none exists yet). Generated 2026-06-06.

Method: v0 namespaces read from `src/lang/lib/*.zig` `namespace_def.name` (31
libs registered in `defs.zig` + `clojure.core`); v1 status probed by
`(require 'NS)` against a freshly built `./zig-out/bin/cljw` plus a
representative-var call. `present` = require succeeds AND a representative var
works; `MISSING` = `require` raises `name_error … could not locate … on the
require resolver`. v1-only additions (data.csv, data.json, tools.cli) are out of
scope. Debt-row column cites the existing owner; `NEEDS-ROW` means no dedicated
row exists (the main loop creates it — this file does not edit `debt.yaml`).

## Bundled namespaces

| v0 source                    | namespace / feature        | v1 status | debt row  | note                                                                                                                                                                                                       |
|------------------------------|----------------------------|-----------|-----------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| clojure_data.zig             | clojure.data               | present   | —        | `diff` verified: `(diff {:a 1} {:a 2})` → `({:a 1} {:a 2} nil)`.                                                                                                                                          |
| clojure_edn.zig              | clojure.edn                | present   | —        | `read-string` verified.                                                                                                                                                                                    |
| clojure_math.zig             | clojure.math               | present   | —        | drained to JVM parity per D-232 math.clj log; `sqrt` verified.                                                                                                                                             |
| clojure_pprint.zig           | clojure.pprint             | present   | —        | `pprint` verified via `with-out-str`.                                                                                                                                                                      |
| clojure_set.zig              | clojure.set                | present   | —        | `union` verified.                                                                                                                                                                                          |
| clojure_string.zig           | clojure.string             | present   | —        | `upper-case` verified.                                                                                                                                                                                     |
| clojure_test.zig             | clojure.test               | present   | D-227     | real `clojure.test` landed (D-227 DISCHARGED); `deftest`/`is` verified. `use-fixtures` cluster still thin.                                                                                                 |
| clojure_walk.zig             | clojure.walk               | present   | —        | `postwalk` verified.                                                                                                                                                                                       |
| clojure_zip.zig              | clojure.zip                | present   | —        | `vector-zip` verified.                                                                                                                                                                                     |
| clojure_repl.zig             | clojure.repl               | MISSING   | D-232     | listed in D-232 FRONTIER ("whole missing namespaces"); `doc`/`source`/`dir`/`apropos` absent. Cross-ref D-237/D-247 (REPL introspection, ADR-level).                                                       |
| clojure_repl_deps.zig        | clojure.repl.deps          | MISSING   | NEEDS-ROW | `add-lib`/`add-libs`/`sync-deps` (gated on deps.edn resolution).                                                                                                                                           |
| clojure_java_io.zig          | clojure.java.io            | present   | —        | backfilled by 2026-06-10; `(file "x")` verified 2026-06-12. The broader Java-tier `clojure.java.{shell,process,browse}` stay separate MISSING rows.                                                        |
| clojure_java_shell.zig       | clojure.java.shell         | MISSING   | NEEDS-ROW | gated on Stage-0.3 Java-tier decision.                                                                                                                                                                     |
| clojure_java_process.zig     | clojure.java.process       | MISSING   | NEEDS-ROW | gated on Stage-0.3 Java-tier decision.                                                                                                                                                                     |
| clojure_java_browse.zig      | clojure.java.browse        | MISSING   | NEEDS-ROW | `browse-url`.                                                                                                                                                                                              |
| clojure_core_protocols.zig   | clojure.core.protocols     | present   | —        | backfilled by 2026-06-10; `require` verified 2026-06-12 (`CollReduce`/`IKVReduce` substrate landed; unblocks D-282 priority-map kv-reduce).                                                                |
| clojure_core_reducers.zig    | clojure.core.reducers      | MISSING   | D-232     | listed in D-232 FRONTIER; fork/join fold family.                                                                                                                                                           |
| clojure_core_server.zig      | clojure.core.server        | MISSING   | NEEDS-ROW | `start-server`/`repl` socket server.                                                                                                                                                                       |
| clojure_core_specs_alpha.zig | clojure.core.specs.alpha   | MISSING   | NEEDS-ROW | depends on clojure.spec.alpha; arg-list specs for core macros.                                                                                                                                             |
| clojure_datafy.zig           | clojure.datafy             | MISSING   | D-232     | listed in D-232 FRONTIER; `datafy`/`nav`.                                                                                                                                                                  |
| clojure_instant.zig          | clojure.instant            | present   | —        | backfilled by 2026-06-10 (be52b4f9, alongside java.sql.Timestamp); `(read-instant-date "2024-01-01")` verified 2026-06-12.                                                                                 |
| clojure_main.zig             | clojure.main               | MISSING   | D-241     | D-241 owns the missing clojure.main baseline thread-binding frame; the full namespace (repl loop, `-main`, `with-bindings` defaults) is otherwise unbuilt.                                                 |
| clojure_spec_alpha.zig       | clojure.spec.alpha         | MISSING   | NEEDS-ROW | large; spec conformance errors are accepted-divergent today (AD-007). spec.alpha clone exists at `~/Documents/OSS/spec.alpha`.                                                                             |
| clojure_spec_gen_alpha.zig   | clojure.spec.gen.alpha     | MISSING   | NEEDS-ROW | depends on spec.alpha + a generator/test.check substrate.                                                                                                                                                  |
| clojure_stacktrace.zig       | clojure.stacktrace         | present   | —        | backfilled 2026-06-10 (24a9385e, over the ex-info exception model); `(root-cause (ex-info …))` verified 2026-06-12.                                                                                       |
| clojure_template.zig         | clojure.template           | present   | —        | backfilled by 2026-06-10 (variant-① upstream copy); `(apply-template …)` + `(clojure.test/are …)` consumer verified 2026-06-12.                                                                         |
| clojure_test_tap.zig         | clojure.test.tap           | present   | —        | backfilled 2026-06-10 (75a8fa80, TAP reporter over clojure.test); `require` verified 2026-06-12.                                                                                                           |
| clojure_uuid.zig             | clojure.uuid               | present   | —        | backfilled 2026-06-10 (e65e6a86, ns form; the `#uuid "…"` reader literal already worked in core); `require` + `uuid?` verified 2026-06-12.                                                                |
| clojure_xml.zig              | clojure.xml                | MISSING   | NEEDS-ROW | `parse`/`emit`; depends on a SAX/XML substrate.                                                                                                                                                            |
| cljw_http.zig                | cljw.http                  | partial   | D-258     | v0 is a flat `cljw.http`; v1 split into `cljw.http.server` (present, minimal first cut per ADR-0098/D-258) + `cljw.http.client` (stub, raises `feature_not_supported`). Flat `cljw.http` alias absent.     |
| cljw_wasm.zig                | cljw.wasm                  | MISSING   | NEEDS-ROW | wasm engine exists internally (`src/runtime/cljw/wasm/{engine,marshal,surface,wasm_handle}.zig`, referenced by `_host_api`) but the requirable `cljw.wasm` namespace / `Engine` surface is not registered. |
| cljw_wasm_builtins.zig       | (cljw.wasm support module) | MISSING   | NEEDS-ROW | builtins backing cljw.wasm; moves with the cljw.wasm row.                                                                                                                                                  |

## App features

| v0 source                        | namespace / feature        | v1 status | debt row  | note                                                                                                                                                                                                           |
|----------------------------------|----------------------------|-----------|-----------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| app/cli.zig                      | CLI entry / option parsing | partial   | —        | v1 `cli.zig` present: `-e`/`-`/`<file>`/`-cp`/`--compare`/`-h`. v0 also has a `test` subcommand (see test_runner) — absent in v1.                                                                             |
| app/deps.zig                     | deps.edn resolution        | MISSING   | NEEDS-ROW | v0 parses `deps.edn` (`:paths`/`:deps`/`:aliases`/`:cljw/main`/`:cljw/test-paths`/`:cljw/wasm-deps`). v1 has no `DepsConfig`/deps.edn path; classpath is `-cp`/`$CLJW_PATH`/`.` only. Campaign Stage 0.3 item. |
| app/runner.zig                   | source file runner         | present   | —        | v1 `runner.zig` runs `<file.clj>` / stdin / `-e`.                                                                                                                                                              |
| app/test_runner.zig              | `cljw test` subcommand     | MISSING   | NEEDS-ROW | v0 `cljw test` discovers + runs `clojure.test` suites. No `cljw test` mode in v1's CLI.                                                                                                                        |
| app/repl/line_editor.zig         | interactive REPL line edit | present   | —        | v1 `repl.zig` present.                                                                                                                                                                                         |
| app/repl/nrepl.zig + bencode.zig | nREPL server               | present   | D-118     | v1 `nrepl.zig` present; `*out*`/`*err*` per-session capture still open (D-118).                                                                                                                                |
| app/wasm/ (testdata + harness)   | wasm conformance harness   | partial   | —        | v1 has the wasm engine internally; the requirable `cljw.wasm` surface + conformance suite parity move with the cljw.wasm row.                                                                                  |
| (project scaffolding)            | project scaffolding / init | MISSING   | NEEDS-ROW | new-project scaffolding (campaign seed) — no `cljw new`/init equivalent in v1.                                                                                                                                |

## Summary

> **Re-probed 2026-06-12** (polish-loop staleness sweep): the table was
> generated 2026-06-06 and went stale — **7 bundled namespaces backfilled by
> 2026-06-10 were still marked MISSING**: `clojure.java.io`,
> `clojure.core.protocols`, `clojure.instant`, `clojure.stacktrace`,
> `clojure.template`, `clojure.test.tap`, `clojure.uuid`. All flipped to
> `present` above (require + representative-var re-verified). Counts below are
> the corrected figures.

- **present**: 19 — 16 bundled namespaces (clojure.data, .edn, .math, .pprint,
  .set, .string, .test, .walk, .zip, .java.io, .core.protocols, .instant,
  .stacktrace, .template, .test.tap, .uuid) + 3 app features (CLI entry
  parsing, source runner, REPL/nREPL). (CLI parsing and the wasm harness are
  noted `partial` below; counted here as having a working v1 surface.)
- **partial**: 3 — `cljw.http` (server present / client stub), `app/cli.zig`
  (no `test` subcommand), `app/wasm` (engine internal, no requirable surface).
- **MISSING**: 17 — 14 bundled namespaces + 3 app features (deps.edn
  resolution, `cljw test` subcommand, project scaffolding).

### MISSING / partial with no dedicated debt row (NEEDS-ROW — main loop creates)

1. `clojure.repl.deps` (`add-lib!`/`add-libs`/`sync-deps`)
2. `clojure.java.shell`
3. `clojure.java.process`
4. `clojure.java.browse`
5. `clojure.core.server`
6. `clojure.core.specs.alpha`
7. `clojure.spec.alpha`
8. `clojure.spec.gen.alpha`
9. `clojure.xml`
10. `cljw.wasm` (+ its `cljw_wasm_builtins` support module)
11. app: `deps.edn` resolution (`app/deps.zig`)
12. app: `cljw test` subcommand (`app/test_runner.zig`)
13. app: project scaffolding / init

Now-present (were NEEDS-ROW, backfilled 2026-06-10, verified 2026-06-12):
`clojure.instant` / `clojure.stacktrace` / `clojure.template` /
`clojure.test.tap` / `clojure.uuid`.

Rows that already cover their feature (no NEEDS-ROW): clojure.repl /
clojure.core.reducers / clojure.datafy → **D-232** (FRONTIER "whole missing
namespaces"); clojure.main → **D-241** (baseline binding frame); cljw.http →
**D-258** (server first cut); clojure.test → **D-227** (DISCHARGED, present);
nREPL `*out*`/`*err*` → **D-118**. Now-present (were D-232 FRONTIER):
clojure.java.io / clojure.core.protocols.
