# `modules/` — external Clojure modules

Peer to `src/`, populated from Phase 9 onward per
[`.dev/structure_plan.md`](../.dev/structure_plan.md) line 108-112
+ [`.claude/rules/zone_deps.md`](../.claude/rules/zone_deps.md).

## What lives here

External-namespace Clojure modules that JVM Clojure ships as
**separate libraries** (not in `clojure.core`). Each module gets
its own subdirectory under `modules/`:

| Subdir          | Clojure namespace   | Phase landing     |
|-----------------|---------------------|-------------------|
| `modules/edn/`  | `clojure.edn`       | Phase 9 (row 9.2) |
| `modules/json/` | `clojure.data.json` | Phase 9 (row 9.3) |
| `modules/csv/`  | `clojure.data.csv`  | Phase 9 (row 9.4) |
| `modules/cli/`  | `clojure.tools.cli` | Phase 9 (row 9.5) |

Phase 10+ may add `modules/pprint/`, `modules/walk/`, etc.;
`clojure.string` / `clojure.set` / `clojure.walk` (already
in-source under `src/lang/clj/clojure/`) are **not** modules —
they live in `src/lang/` because they ship as part of the
ClojureWasm base distribution alongside `clojure.core`.

## Dependency rule (zone-checked)

Per `.claude/rules/zone_deps.md`:

```
modules/ MUST NOT import from lang/ or app/
modules/ CAN  import from runtime/ + eval/
```

Enforced by `scripts/zone_check.sh` (modules-specific arm landed
at Phase 9 row 9.1). A module file importing
`src/lang/primitive/string.zig` (for example) is a violation —
the module must reach the shared neutral impl directly via
`src/runtime/<feature>.zig` per F-009 (feature-implementation
neutrality).

## File layout (deferred per D-095)

`modules/` is a **reserved top-level directory** at row 9.1. The
intended shape per `.dev/structure_plan.md` is one subdirectory
per external Clojure module with both the `.clj` source and the
matching Layer-2 Zig primitive co-located:

```
modules/<area>/
├── _README.md            # one-line scope + JVM upstream link
├── <area>.clj            # the user-facing Clojure ns
└── <area>.zig            # Layer-2 primitives the .clj defns route through
```

Zig 0.16's `@import` + `@embedFile` reject cross-module-path
access, so until `build.zig` declares `modules/` as a separate
Zig module (with `addImport("cw_modules", modules_mod)`), the
actual module content rides the existing in-source convention:

- `.clj` source → `src/lang/clj/clojure/<area>.clj`
  (mirroring `clojure.string` / `clojure.set` precedent).
- Layer-2 Zig primitive → `src/lang/primitive/<area>.zig`
  (mirroring `string.zig` / `walk.zig`).

The `modules/` top-level remains in the tree as a structural
reservation so the future build.zig migration has a target. The
deferred migration is tracked at `.dev/debt.yaml` D-095.

Module registration into the cw runtime happens via the bootstrap
loader (cw v1's `(require '[clojure.data.json :as json])` discovery
mechanism uses the `Runtime.require_resolver` per ADR-0035 D5).
The bootstrap FILES table at `src/lang/bootstrap.zig` is the
single SSOT for which namespace `.clj` sources get embedded at
compile time.

## Why a peer to `src/`, not under `src/lang/`

cw v1 ships `clojure.core` + `clojure.string` + `clojure.set` +
`clojure.walk` + `clojure.zip` as part of the base distribution
(in-source under `src/lang/clj/`). External modules — `json` /
`csv` / `edn` / `cli` — are technically optional dependencies that
a downstream user `(require)`s on demand. Keeping them in a
top-level `modules/` directory:

1. Makes the optional-dependency boundary visible at the
   filesystem level (compare with JVM `deps.edn` adding
   `[org.clojure/data.json "2.5.0"]`).
2. Prevents accidental upward imports into the base distribution
   (`src/lang/clj/clojure/core.clj` cannot accidentally require
   `clojure.data.json` because `modules/` is outside `src/`).
3. Lays the groundwork for Phase 12+ `cljw build` to produce
   distinct artefacts (bare runtime vs runtime-plus-modules).

## Related

- D-034 (discharged Phase 9 row 9.1) — `modules/` structure choice.
- ADR-0035 D5 — `Runtime.require_resolver` namespace-loading hook.
- ROADMAP §9.11 — Phase 9 task list.
