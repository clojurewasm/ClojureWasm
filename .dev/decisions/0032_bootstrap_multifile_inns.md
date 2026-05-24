# 0032 — Bootstrap multi-file loader + `(in-ns 'foo.bar)` primitive

- **Status**: Accepted
- **Date**: 2026-05-25
- **Author**: Shota Kudo (drafted + accepted by the autonomous
  loop with Devil's-advocate fork)
- **Tags**: phase-6, bootstrap, namespace, in-ns, structural

## Context

ROADMAP §9.8 row 6.9 calls for `lang/clj/clojure/string.clj`
(Tier A, ~21 vars) — the first Clojure source file that lives
outside the `user` / `rt` default namespaces. The cw v1
bootstrap pipeline today (`src/lang/bootstrap.zig::loadCore`)
embeds a single `@embedFile("clj/clojure/core.clj")` and runs
the read-analyse-eval loop with `env.current_ns` left at
`user` (its default per `Env.init`).

To land `clojure.string/upper-case` etc., two structural pieces
are missing:

1. **The loader is single-file**. There is no way to embed +
   evaluate a second `.clj` file at boot.
2. **No namespace-switching mechanism exists**. `Env` carries
   `current_ns` + `findOrCreateNs`, but no `(in-ns 'foo.bar)`
   / `(ns ...)` / `(require ...)` primitive is registered. The
   analyser does not know how to interpret `(ns ...)` forms.

Both pieces also feed Phase 7's `require` landing and Phase 16's
WASM-component load (per F-001) — the shape chosen here propagates
forward.

## Decision

**Adopt Alternative 2 — `(in-ns 'foo.bar)` primitive +
flat file-iteration loader (Survey Option B, refined).**

Concretely:

1. **New primitive** `src/lang/primitive/ns.zig::inNs`, registered
   in `rt/` by `lang/primitive.zig::registerAll`. Semantics:
   `(in-ns 'sym)` mutates `env.current_ns` to the named namespace
   (creating it via `findOrCreateNs` if absent) and returns the
   namespace value (matches JVM `clojure.core/in-ns` contract).
   Single-arity; sym arg only. `(in-ns 'rt)` / `(in-ns 'user)`
   are valid (they target the auto-created namespaces).

2. **Loader rewrite** `src/lang/bootstrap.zig::loadCore`. The
   embed becomes a flat `[]const []const u8` table:

   ```zig
   pub const FILES: []const FileEntry = &.{
       .{ .label = "<bootstrap>",         .source = @embedFile("clj/clojure/core.clj") },
       .{ .label = "<clojure.string>",    .source = @embedFile("clj/clojure/string.clj") },
   };
   ```

   The loader iterates each entry's read/analyse/eval loop. The
   loader carries **no namespace knowledge** — each `.clj` file
   asserts its own namespace via a leading `(in-ns 'foo.bar)`
   form. After the last file, the loader resets `env.current_ns`
   to `user` so the REPL prompt starts in `user/`.

3. **Source convention**: every `.clj` file outside `core.clj`
   opens with `(in-ns 'name.space)`. `core.clj` does not need
   one (it inherits the loader's initial `user` current_ns).

4. **No analyser-cache invalidation work needed at Phase 6**:
   the analyser does not currently cache resolved Vars across
   forms, so `(in-ns)` mid-file just changes what `env.current_ns`
   points to for the next form's resolution. When the analyser
   adds resolution caching (Phase 7+), the `(in-ns)` primitive's
   call site is the natural invalidation hook.

This is the finished-form-clean choice per F-002: Phase 7's
`require` reuses `(in-ns)` verbatim, and the `.clj` files become
self-describing (a reader of `string.clj` sees `(in-ns
'clojure.string)` at the top and knows which namespace it
populates). Paying ~60 LOC for the primitive + ~30 LOC for the
loader rewrite now avoids a Phase 7 rewrite of the loader and
the bootstrap files. F-002 (finished-form wins) decides this
above the smallest-diff Alternative 1.

**Out of scope** (deferred):

- `(ns clojure.string (:refer-clojure :exclude [replace reverse]))`
  macro — requires `:require` / `:refer` / `:as` semantics and a
  namespace dependency graph. Phase 7+ when `require` lands.
- `Extension.init: ?*const fn () anyerror!void` signature widening
  (D-048) — the `(in-ns)` primitive lands via `primitive.registerAll`,
  not via the `Extension` host_api, so D-048 does not intersect this
  ADR. D-048 stays scheduled at its current Status (Phase 6 entry —
  already missed-boat but still actionable; carried as a separate
  landing).

## Alternatives considered

The following 3 alternatives were produced by the Devil's-advocate
subagent (forked with fresh context to counter the main loop's
goal-drift / instruction centrifugation, per CLAUDE.md § Smell
triggers are interrupts, not stops). Verbatim output below.

### Alternative 1 — Loader-side `current_ns` switch via `BootstrapFile` table (smallest-diff)

**Shape**: `bootstrap.zig` defines `pub const FILES: []const BootstrapFile = &.{ .{ ns_name: "user", source: @embedFile("clj/clojure/core.clj") }, .{ ns_name: "clojure.string", source: @embedFile("clj/clojure/string.clj") }, ... };`. `loadCore` saves `env.current_ns`, sets it from `file.ns_name` (via `findOrCreateNs`), runs the read/analyse/eval loop, and on the final file resets to `user`. No `(in-ns)` primitive lands; no `.clj` header. ~30 LOC diff to `bootstrap.zig`.

**What it does better than Option B**: Zero new analyser surface. No analyser-cache invalidation problem (D-048 stays untouched). The loader stays a single-purpose mechanism — no risk of an `(in-ns)` semantic drift between bootstrap-time and user-time.

**What it breaks vs Option B**: The `.clj` file is not self-describing — a reader of `string.clj` sees no `(ns clojure.string)` clue and must know the loader assigns it. Cannot be re-evaluated through `cljw -e "$(cat string.clj)"` (it would land in `user/`). Pushes the `(in-ns)` decision to Phase 7 instead of now.

**Phase 7 / Phase 16 horizon read**: Phase 7's `require` lands its own `(in-ns)` primitive — this alternative does **not** make that landing harder; it is orthogonal. Phase 16 WASM-component load (F-001) likely loads from a manifest with `(ns_name, source)` pairs anyway, so the `BootstrapFile` shape is actually closer to the WASM finished form than `(in-ns)` headers embedded in source.

### Alternative 2 — `(in-ns 'foo.bar)` primitive + flat file iteration (finished-form-clean)

**Shape**: New `lang/primitive/ns.zig::inNs` registered in `rt/`. `.clj` files start with `(in-ns 'clojure.string)`. `bootstrap.zig::FILES: []const []const u8` is a flat list; the loader has no namespace knowledge — the `(in-ns)` form mutates `env.current_ns` during evaluation. Loader resets `current_ns` to `user` after the last file.

**What it does better than Alt 1**: `.clj` files are self-describing. The `(in-ns)` primitive is a real Phase 7 building block for `require`. Files are testable through `cljw -e` (modulo loader order). Matches JVM/babashka idiom.

**What it breaks vs Alt 1**: New primitive surface lands now (small but real). Analyser caching across `(in-ns)` boundaries needs handling — mid-file ns-switch invalidates any per-ns cached resolutions (the survey notes this as Phase 6 scope). Couples D-048 (Extension.init signature) into this cycle.

**Phase 7 / Phase 16 horizon read**: Phase 7's `require` reuses `(in-ns)` verbatim, saving the rewrite Alt 1 doesn't actually impose (since Alt 1 is non-blocking). Phase 16 WASM-component load could embed `(in-ns)` headers in component sources — works but is less natural than a manifest table; the headers-in-source approach assumes "all loadable units are .clj text" which a WASM component is not.

### Alternative 3 — Wildcard: register Tier-A `clojure.string` as `rt/`-style primitive group, skip `.clj` entirely

**Shape**: `lang/primitive/clojure_string.zig` registers each var (`upper-case`, `blank?`, ...) directly into a `clojure.string` namespace via `env.intern(clojure_string_ns, "upper-case", ...)`, identical to how `math.zig` registers `+` into `rt`. No `.clj` file. No `(in-ns)` primitive. `loadCore` stays single-file (just `core.clj`).

**What it does better than Alts 1/2**: Maximum performance (no read/analyse/eval round-trip for 21 vars at boot). Vars carry direct Zig fn pointers, not closures. No bootstrap-loader extension needed at all. Aligns with how `rt/` already works — one consistent registration pattern for Tier-A namespaces.

**What it breaks vs Alts 1/2**: **Recreates cw v0's mistake** that the survey §2.2 explicitly identifies — strings.zig at 1824 lines violating ROADMAP A6. Forces Clojure-level helpers (e.g., `split-lines` calling `split` calling `re-find-from`) to be expressed in Zig with manual Value-wrapping instead of native `.clj`. Removes the natural surface for the developer reading `clojure.string` to learn the implementation. **Crucially, this contradicts the survey's DIVERGENCE D2 rationale (ADR-0029 §3.1 places `clojure.string` as Tier-A `.clj` source).**

**Phase 7 / Phase 16 horizon read**: Phase 7 `require` still needs `(in-ns)` (for user-loaded sources), so this alternative doesn't reduce Phase 7 work — it just delays it. Phase 16 unaffected. Tier-A clojure.* namespaces that arrive later (`clojure.set`, `clojure.walk`, `clojure.pprint`) would each have to choose between this Zig-primitive pattern and the `.clj` pattern, fragmenting the surface.

### F-NNN constraint-violation check

None of the three above violate F-001/F-002/F-003/F-009. No
`[VIOLATES F-NNN]` findings.

### Devil's-advocate recommendation

**Pick Alternative 2 (= survey's Option B)**, but with one
adjustment the survey under-emphasises: the loader iteration
should be a `[]const []const u8` flat list (refined to a `FileEntry
{label, source}` shape in this ADR), **not** a `(ns_name, source)`
tuple table. Letting `(in-ns)` carry the ns-switch — instead of
duplicating it in a Zig-side table — is what makes the `.clj` files
self-describing and re-evaluable, which is the whole point of
preferring B over A. F-002 (finished-form wins) decides between
Alt 1 and Alt 2: Phase 7 finished form ships `(in-ns)` regardless,
and the cost difference at Phase 6.9 is ~60 LOC + a cache-
invalidation hook — well below the threshold where F-002's
"shipping fast is second-tier" applies. Alt 3 is rejected on
DIVERGENCE D2 grounds (ADR-0029 §3.1 explicitly lists
`clojure.string` as a `.clj`-source namespace). Alt 1 stays a
viable fallback if D-048 resolution turns out to be more
disruptive than expected — but the survey already shows D-048 as
cleanly resolvable in the same cycle.

## Consequences

- **Phase 7+ `require` reuse**: the `(in-ns)` primitive lands its
  finished-form contract today. `require` then layers
  `:as` / `:refer` / dependency-graph computation on top of an
  existing namespace-switch mechanism.
- **Bootstrap order is explicit**: the `FILES` table makes load
  order grep-able in one place. New `.clj` modules add a row.
- **Single-file loader contract preserved for `core.clj`**: the
  first entry's source label remains `<bootstrap>` so the error
  renderer's existing test cases (per `error_print.SourceContext`)
  continue working.
- **`(in-ns)` is a real primitive, not a no-op**: per
  `no_op_stub_forbidden.md`, the body mutates `env.current_ns`
  and returns the namespace value. A stub that returned `nil` and
  did not switch would be a permanent no-op and is forbidden.
- **D-048 stays separate**: `Extension.init` widening is unrelated
  to this ADR and lands on its own schedule.
- **REPL prompt unchanged**: `current_ns` resets to `user` after
  bootstrap; the REPL (Phase 10+ landing) sees its expected
  starting namespace.

## Affected files

| File                                      | Change                                                                       |
|-------------------------------------------|------------------------------------------------------------------------------|
| `src/lang/primitive/ns.zig`               | NEW — `inNs` primitive (~60 LOC + tests)                                    |
| `src/lang/primitive.zig`                  | Add `ns` import + `ns.register(env, rt_ns)` call                             |
| `src/lang/bootstrap.zig`                  | Rewrite `loadCore` to iterate `FILES`; add `FILES` + `FileEntry` decls       |
| `src/lang/clj/clojure/string.clj`         | NEW — `(in-ns 'clojure.string)` header + cycle-1 vars                       |
| `src/main.zig`                            | If `bootstrap_ctx.text` / `file` reference assumes single-file source, adapt |
| `compat_tiers.yaml`                       | `clojure.string` entry (Tier A) + `in-ns` entry (Tier A, rt/ primitive)      |
| `test/e2e/phase6_clojure_string_basic.sh` | NEW — cycle-1 e2e smoke                                                     |

## Revision history

- 2026-05-25 issued and accepted. Devil's-advocate subagent
  consulted; output embedded verbatim above. Alternative 2 chosen
  with the FileEntry shape refinement. Cycle 1 of Phase 6.9 will
  land this ADR's surface; cycles 2-4 fill out the 21-var
  `clojure.string` surface per the Step-0 survey at
  `private/notes/phase6-6.9-survey.md`.
