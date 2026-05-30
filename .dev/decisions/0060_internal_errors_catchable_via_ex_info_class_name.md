# ADR-0060 — Internal runtime errors are catchable: synthesize a class-name-bearing ex_info at the try boundary

- **Status**: Accepted
- **Date**: 2026-05-31
- **Phase**: Phase 14 (post-v0.1.0 coverage) / cluster A26
- **Supersedes**: —
- **Superseded by**: —

## Context

`(try (/ 1 0) (catch Exception e :caught))` returned the uncaught
message "Divide by zero" instead of `:caught` (confirmed; real Clojure
via `clj` throws `ArithmeticException`, caught by `(catch Exception …)`).
`(catch ArithmeticException …)` / `(catch Throwable …)` also failed.
But `(try (throw (ex-info "x" {})) (catch Exception e :caught))` WORKS.
So cljw's **internal** runtime errors (everything raised via
`error_catalog.raise` — divide-by-zero, type errors, index-out-of-range,
arity, …) are NOT catchable by try/catch; only user-`throw`-ed ex_info
Values are. This breaks the most common Clojure error-handling idiom and
is a behavioural-equivalence defect (F-011).

Root cause (dual error channels):

- `error_catalog.raise` (`catalog.zig:1009`) returns a typed
  `ClojureWasmError` Zig error (e.g. `error.ArithmeticError`) and sets a
  threadlocal `Info{kind, message, origin=.catalog}` via `setErrorFmt`.
  It never sets `dispatch.last_thrown_exception` and never builds a
  throwable Value.
- `evalThrow` (`tree_walk.zig:794`) sets `last_thrown_exception = v` +
  returns `error.ThrownValue`. `evalTry` (`tree_walk.zig:804`) catches
  `error.ThrownValue`, reads the Value, runs `catchMatches` →
  `host_class.matches(thrown, class)` (walks the Throwable hierarchy).
  Its `else =>` arm (`tree_walk.zig:840`) runs `finally` + `return err` —
  internal errors propagate **uncaught**, never converted, never matched.
  The VM mirror (`vm.zig:99`) is structurally the same; both backends
  already converge on the single shared predicate `host_class.matches`
  (`vm.zig:673-674`).
- `host_class.zig::thrownClassName` (L166) hardcodes every `.ex_info`
  Value to class `"ExceptionInfo"`, so a synthesized throwable would
  need to carry its real class to match `(catch ArithmeticException …)`.

`Origin = enum { catalog, thrown }` (`info.zig:79`, ADR-0055) is a
deliberate two-origin model: an uncaught internal error renders with its
`[arithmetic_error]` Kind header (origin=.catalog); a `(throw v)` renders
as `:exception`. The fix must preserve this for the **uncaught** path.

cw v0 DID make these catchable (`createRuntimeException`,
`~/Documents/MyProducts/ClojureWasm/.../tree_walk.zig:1450`): it switched
on `info.kind` to pick a `:__ex_type` string, packed a synthetic
exception map, and matched it via the same hierarchy walk cljw now has in
`host_class.zig`. Per `no_copy_from_v1.md`, cljw re-derives this in a
cljw-appropriate shape (struct field, not a map key; direct `host_class`
import, not a pub-var injection).

## Decision

Make internal **user-domain** errors catchable by **synthesizing a
class-name-bearing ex_info at the try boundary** and falling into the
existing shared catch-matching loop. cljw's `.ex_info` tag is the
**single unified throwable representation**; a `class_name` field
discriminates "which exception class this Value represents". This is the
F-011 commonised + behaviourally-equivalent finished form.

1. **`ExInfo.class_name: ?[]const u8 = null`** (`ex_info.zig`). For a
   real `(ex-info …)` Value it stays `null` (≡ `ExceptionInfo`); for a
   synthesized internal error it carries the Kind-derived class
   (`"ArithmeticException"`, …) — a comptime-static catalog string, so
   no GC ownership / `mark` / `rawFree` change is needed.

2. **`kindToHostClass(kind) []const u8`** (in `host_class.zig`) — the
   Kind→class map (grounded against real `clj`):

   | Kind               | catch class                 |
   |--------------------|-----------------------------|
   | `arithmetic_error` | `ArithmeticException`       |
   | `type_error`       | `ClassCastException`        |
   | `index_error`      | `IndexOutOfBoundsException` |
   | `value_error`      | `IllegalArgumentException`  |
   | `arity_error`      | `ArityException`            |
   | `number_error`     | `NumberFormatException`     |
   | `name_error`       | `RuntimeException`          |
   | `syntax_error`     | `RuntimeException`          |
   | `string_error`     | `RuntimeException`          |
   | `io_error`         | `IOException`               |

   **Uncatchable** (return null → keep the current `return err` /
   `[kind]` render): `internal_error`, `out_of_memory` (descend from
   `Error`, matching JVM `(catch Exception …)` NOT catching them), and
   `not_implemented` (a `(catch Exception …)` silently swallowing
   "feature not yet built" is the Silent-default-shift smell; keep it a
   loud uncaught signal — DA-endorsed).

3. **`evalTry` `else =>` arm (TreeWalk) + the VM run-loop error path**:
   if the propagating `ClojureWasmError`'s Kind maps to a class
   (`kindToHostClass` non-null), read `info.peekLastError()`, build
   `ex_info.alloc(rt, info.message, nil_data, nil)` with `class_name`
   set, stash it in `last_thrown_exception`, clear the threadlocal Info,
   and fall into the existing catch-matching loop. Otherwise keep the
   current `return err` (uncatchable). Conversion is **local to the try
   boundary**, so an uncaught internal error keeps its `[arithmetic_error]`
   Kind header (origin stays `.catalog`).

4. **`thrownClassName` (`host_class.zig:166`)**: for an `.ex_info`
   carrying a non-null `class_name`, return it; else `"ExceptionInfo"`.
   `matches()`/`isSubclassOf` then resolve `ArithmeticException` (and
   `(instance? Throwable e)` etc.) via the existing hierarchy walk, with
   **zero** change to the predicate itself.

5. **`ex-data` / `ex-info?` gate on `class_name`** (`ex_info.zig` +
   `lang/primitive/error.zig`): a synthesized exception (non-null,
   non-`ExceptionInfo` class) reports `(ex-data e)` → `nil` and
   `(instance? clojure.lang.ExceptionInfo e)` → `false` (the latter free
   via `thrownClassName`), matching real Clojure where a bare
   `ArithmeticException` is not an `IExceptionInfo`. `(ex-message e)` /
   `(.getMessage e)` / `str` return the catalog message (already duped
   through `rt.gc.infra` by `ex_info.alloc`).

6. **Add `ArityException` (parent `IllegalArgumentException`)** to the
   `host_class` table + FQCN map — the one class the table lacks, so
   `(catch ArityException …)` parses.

7. **Differential test** (`diff_test.zig`) so TreeWalk↔VM agree:
   `(try (/ 1 0) (catch ArithmeticException e (ex-message e)))` +
   `(catch Exception …)` + a no-match re-raise.

**Why this over the DA's recommended Alt 2 (a first-class `.host_error`
Value tag).** The Devil's-advocate fork (below, verbatim) found the
naive Option A *masquerade* defect (instance?/ex-data wrong) and
recommended a dedicated `.host_error` tag as the "cleanest sibling
model". The main loop adopts the **correctness** of Alt 2 (gate
instance?/ex-data so a synthesized exception is observably NOT an
ExceptionInfo) **without** the new tag, because:

- **F-011 (commonization) favours one unified throwable representation.**
  `.ex_info` becoming "the throwable Value, with an optional class_name
  saying which exception class it is" is the *shared mechanism*; a
  parallel `.host_error` tag is a second representation of the same
  concept (Cycle-budget defer's inverse — proliferation, not reuse).
- **F-011 (internals/representation may diverge; behaviour must match).**
  Alt 2's "ArithmeticException is its own class, not ex_info wearing a
  hat" is a JVM-faithfulness argument about *internal representation*.
  F-011 explicitly frees internals: cljw may use one `.ex_info` rep
  internally as long as `(instance? ExceptionInfo e)` / `(ex-data e)` /
  `(catch …)` observably match — which the class_name gate achieves.
- **F-004 (the 64-slot NaN-box layout is a fixed user invariant).** Alt
  2 consumes a reserved slot + adds the tag to every switch
  (`mark_sweep`, `rawFree`, `print`, ex-* builtins) — ~11 sites vs the
  ~4 gate sites here. This is **not** a cycle-budget/diff-size rejection
  (the DA's named smell) — it is an F-004 slot-economy + F-011
  commonization decision. The observable behaviour is identical to Alt 2.

If a future need arises where a synthesized exception must carry
genuinely different *internal* structure from an ex_info (not just a
class name), the `.host_error` tag is the escalation; today the
class_name field on the unified `.ex_info` rep is the F-011 finished
form.

## Alternatives considered

The following is the Devil's-advocate subagent's verbatim output (fresh
context, briefed with the survey + the F-NNN envelope + verified
file:line). Its recommendation (Alt 2, a `.host_error` tag) is recorded
in full; the main loop adopts Alt 2's *correctness* via the unified
ex_info + class_name gate per F-011/F-004 as narrated above.

> # Devil's-advocate: ADR-0060 (internal runtime errors catchable by try/catch)
>
> Verified against working tree. The draft's `catalog.zig:1009` (`raise`), `tree_walk.zig:804` (`evalTry`), `host_class.zig:166` (`thrownClassName`) line cites are all accurate. Two facts the draft under-weights, both load-bearing below:
>
> - **Both backends already converge on one predicate.** `vm.zig:673-674` literally comments "both backends share the predicate" and calls `host_class.matches(thrown, class_name)`; `tree_walk.catchMatches` (tree_walk.zig:855) does the same. The synthesis-then-match design therefore has a *single* match entry point already. This shrinks the dual-backend cost the draft assigns to Option B and changes the parity calculus across the board.
> - **`ExInfo` is an `extern struct`** (ex_info.zig:46) with a fixed C-ABI layout `{header, _pad, message_ptr, message_len, data, cause}` and a `mark`/`rawFree`/`asExInfo` trio that all assume that layout. The draft's "NEW field `class_name`" is not a free addition — it touches the GC trace fn, the rawFree path, and any code that hardcodes the struct's size. That is fine (it is language-core, F-009-exempt), but it makes the draft *more* invasive than the prose implies, which weakens "smallest-diff" as the draft's selling point and strengthens the finished-form alternative below.
>
> A third fact constrains every alternative: **`Origin = enum { catalog, thrown }`** (info.zig:79) is ADR-0055's deliberate two-origin model, kept precisely so a `(throw v)` has no fake `Kind`. Any alternative that synthesizes a `Kind`-bearing ex_info for caught internal errors must not collapse this distinction for the *uncaught* path. All three alternatives below preserve it.
>
> ---
>
> ## Alternative 1 — Smallest-diff: data-map key `:cljw.error/class`, no struct field
>
> **Shape.** Identical to the draft's Option A *except* sub-decision 2: instead of a new `ExInfo.class_name` field, the synthesized ex_info carries the class name as an entry in its `data` map under a reserved namespaced keyword `:cljw.error/class`. `thrownClassName` (host_class.zig:166) gains a branch that, for an `.ex_info`, reads `data`, looks up `:cljw.error/class`, and returns the string if present, else `"ExceptionInfo"`. Everything else — conversion at the try boundary, the Kind→class map, the uncatchable triad, the `ArityException` table addition — is unchanged from the draft.
>
> **What it does better than the draft.**
> - **Zero `extern struct` surgery.** `ExInfo`'s C-ABI layout, `mark` (ex_info.zig:94 walks `data`+`cause`), `rawFree`, and `asExInfo` are untouched. The class name rides inside the `data` Value, which `mark` already traces — so GC correctness is free, where the draft's new field needs a conscious "is `class_name` owned? does it need freeing?" decision (it is a `?[]const u8` of catalog-static bytes, so no — but that is one more invariant to get right and document).
> - **Survives a future serialization boundary.** If ex_info is ever printed/EDN-encoded/sent across a Wasm component boundary, the class lives in ordinary map data that the existing printer handles; a side-channel struct field would need bespoke plumbing at each such boundary.
>
> **What it breaks / risks.**
> - **Collision + leakage, exactly the draft's stated objection.** `(ex-data e)` on a caught `(/ 1 0)` now returns `{:cljw.error/class "ArithmeticException"}` instead of `{}` (or `nil`). Real Clojure's `(ex-data (try (/ 1 0) (catch Throwable e e)))` is `nil` (an `ArithmeticException` is not an `IExceptionInfo`). So this **leaks a synthetic key into user-visible `ex-data`** — a fidelity regression the draft explicitly flagged as "collision-prone." A user doing `(keys (ex-data e))` sees a key Clojure never puts there.
> - **Reserved-namespace is a weak guarantee.** Nothing prevents user data from already carrying `:cljw.error/class`; the synthesis would have to decide overwrite-vs-merge. For internal errors the `data` map is empty so it is moot *today*, but it is a latent footgun the field-based design does not have.
>
> **Explicit answers.**
> - (a) `(catch Exception e ...)` catches `(/ 1 0)`? **Yes** — synthesized ex_info maps via `isSubclassOf("ArithmeticException","Exception")` (host_class.zig:149 walk: ArithmeticException→RuntimeException→Exception).
> - (b) `(catch ArithmeticException e ...)` catches it specifically? **Yes** — `thrownClassName` returns "ArithmeticException" from the data key; `isSubclassOf("ArithmeticException","ArithmeticException")` is true (self, host_class.zig:235).
> - (c) Uncaught `(/ 1 0)` still renders `[arithmetic_error]`? **Yes** — synthesis happens only inside the try arm. With no enclosing try, the Zig error-union propagates to the CLI/REPL render path which reads the threadlocal `Info{kind=.arithmetic_error, origin=.catalog}`. Origin stays `.catalog`, Kind header intact. ADR-0055 preserved.
> - (d) Dual-backend parity cost? **Low.** Both backends already route through `host_class.matches` (vm.zig:674). The new conversion logic lives in two error-arms (tree_walk.zig:840 `else =>`, vm.zig:99 `return err`), but the *match* path is shared. One differential case covers both. Required per ADR-0036.
> - (e) `(ex-message e)`/`(ex-data e)` work? `ex-message` **yes** (real message from `info.message`). `ex-data` **yes but wrong** — returns `{:cljw.error/class ...}` where Clojure returns `nil`. **Fidelity regression.**
> - (f) Reusable-precedent quality? **Mediocre.** The next "internal error → catchable" need inherits a data-map-pollution pattern; each new synthetic field is another reserved key leaking into `ex-data`. The pattern does not scale cleanly.
>
> ---
>
> ## Alternative 2 — Finished-form-clean: a first-class `host_error` Value tag (not an ex_info masquerade)
>
> **Shape.** Stop pretending an internal error *is* an ExceptionInfo. Introduce a dedicated throwable Value variant — call it `.host_error` — that carries `{kind: Kind, message: []const u8, data: Value = nil}` and represents "a runtime-synthesized JVM-style exception" as its own thing, parallel to `.ex_info`. At the try boundary (tree_walk.zig:840 `else =>` and vm.zig:99), a user-domain `ClojureWasmError` is wrapped into a `.host_error` Value, stashed in `last_thrown_exception`, and matching falls into the existing shared loop. `thrownClassName` (host_class.zig:166) gains a `.host_error => kindToHostClass(v.kind)` arm — mapping is computed from the carried `Kind`, no string is stored redundantly. `ex-message`/`ex-data`/`ex-info?` are taught about `.host_error`: `ex-message` returns the message, `ex-data` returns `nil` (matching JVM: a bare `ArithmeticException` is not `IExceptionInfo`), `(instance? clojure.lang.ExceptionInfo e)` returns **false** for it (correct — `ArithmeticException` is not an `ExceptionInfo`), while `(instance? Throwable e)` / `(instance? Exception e)` / `(instance? ArithmeticException e)` return **true** via the hierarchy walk.
>
> This is what real Clojure's object model *is*: `ArithmeticException` and `ExceptionInfo` are siblings under `RuntimeException`, not one wearing the other's clothes. The draft's Option A makes every caught internal error an `ExceptionInfo` instance wearing a `class_name` hat — which means `(instance? clojure.lang.ExceptionInfo (try (/ 1 0) (catch Throwable e e)))` would wrongly return **true** under the draft, where real Clojure returns **false**. The draft did not list this defect; it is the strongest argument for Alt 2.
>
> **What it does better than the draft.**
> - **`(instance? ExceptionInfo e)` is correct.** The draft's masquerade makes a divide-by-zero look like an ExceptionInfo to `instance?` and to any `ex-data`-gated logic. Alt 2 gets the type identity right, which is the whole point of catch-by-class.
> - **No `extern struct` surgery, no data-map pollution.** `ExInfo` (ex_info.zig:46) is left exactly as designed for genuine `(ex-info …)` values; the new concern lives in its own tag. Clean separation: `.ex_info` = "user attached structured data", `.host_error` = "runtime raised a typed condition".
> - **`kind` is the single source; class name is derived, never stored.** No redundant string to keep in sync with the `Kind`. The Kind⇄class map is one comptime function consulted at match time — mirrors how `host_class.matches` already derives everything from the class-name string rather than caching identity.
> - **Cleanest precedent (f).** The next "internal error → catchable" need is *already handled*: it is just another `Kind` in the map. No new field, no new reserved key, no new struct variant per error family.
>
> **What it breaks / risks.**
> - **Largest diff of the three** — a new `Value.Tag` variant touches: the tag enum, `mark_sweep` trace, `rawFree`, the printer (`print` must render a `.host_error`), `ex-message`/`ex-data`/`ex-info?`/`instance?` builtins, the analyzer/VM where ex-* primitives dispatch on tag, plus the two try-arms and `thrownClassName`. **Per F-002, diff size is explicitly NOT a constraint, so this does not count against it.** It does mean more surface for a bug in the introducing cycle.
> - **New tag = new differential-parity obligation** (ADR-0036): every backend path that can produce or observe a `.host_error` needs a diff case. Mitigated by the shared `matches` predicate, but the *production* side (try-arm synthesis) exists in two places and both need coverage.
> - **`(throw (ArithmeticException.))`-style user construction** is not addressed (cljw has no Class constructors yet) — but neither is it in the draft; out of scope either way.
>
> **Explicit answers.**
> - (a) `(catch Exception e ...)` catches `(/ 1 0)`? **Yes** — `.host_error` with kind `arithmetic_error` → "ArithmeticException" → `isSubclassOf(...,"Exception")` true.
> - (b) `(catch ArithmeticException e ...)`? **Yes** — derived class equals target, self-subclass true.
> - (c) Uncaught still renders `[arithmetic_error]`? **Yes** — same reasoning as Alt 1: synthesis is local to the try arm; with no try, the threadlocal `Info{origin=.catalog, kind=.arithmetic_error}` drives the CLI render. ADR-0055 origin model untouched (and *reinforced*: the catalog origin is the uncaught path, the new `.host_error` Value is the caught path — clean duality).
> - (d) Dual-backend parity cost? **Moderate.** Match path shared (vm.zig:674). Production path duplicated across two try-arms + a new tag observed by ex-* builtins → more diff cases than Alt 1, but each is mechanical. Highest of the three on raw case count; lowest on *conceptual* risk because the model is correct.
> - (e) `(ex-message e)`/`(ex-data e)`? `ex-message` **yes** (carried message). `ex-data` **`nil`** — *correct*, matches JVM where a bare `ArithmeticException` carries no ex-data. This is the only alternative that gets `ex-data` right.
> - (f) Reusable-precedent quality? **Best.** Adding the next catchable internal-error family is one map row + (if a new class) one host_class table row. No struct/field/key growth. Models Clojure's actual sibling-class reality.
>
> ---
>
> ## Alternative 3 — Wildcard: lazy match, synthesize the bound Value only on catch (draft's "Option B", re-evaluated)
>
> **Shape.** Do not synthesize *anything* at the throw boundary. When a user-domain `ClojureWasmError` reaches the try arm, do not build an ex_info and do not set `last_thrown_exception`. Instead, stash the raw `(Kind, message)` in a lightweight threadlocal "pending host condition" slot (the `Info` is *already* there — peek it). Widen the match predicate so `catchMatches`/the VM mirror can answer "does class `C` match a pending host condition of `Kind K`?" directly from `kindToHostClass(K)` + `isSubclassOf`, **without** a Value. Only when a clause *matches* do we materialize the bound Value (an Alt-2 `.host_error` or an Alt-1 ex_info — the wildcard is agnostic) and bind it to the catch local. On no match, nothing was allocated; the Zig error re-propagates with the threadlocal Info still intact.
>
> **What it does better than the draft.**
> - **Zero allocation on the non-matching / re-throw path.** The draft (and Alt 1/2) allocate a heap Value at the throw boundary even when no clause matches and the error re-propagates to the CLI. Alt 3 allocates only on a successful catch. For deeply-nested try/catch where inner clauses do not match (common in `cond`-style error handling), this is strictly less GC pressure.
> - **Uncaught path is provably untouched.** Because nothing is synthesized until a match, the uncaught render path *cannot* be perturbed.
>
> **What it breaks / risks.**
> - **Two match entry points** — a genuine second predicate `matchesKind(kind, class_name)` both backends must call (≤5-line shims over `isSubclassOf`, but real).
> - **Late materialization complicates the catch-binding code.** `catchMatches` stops being a pure `bool`; the VM handler-unwind protocol (vm.zig:84-97) expects the Value already staged in `last_thrown_exception`, so Alt 3 is a more intrusive VM change than Alt 1/2.
> - **Keyword-target catch (`(catch :my/type e …)`, tree_walk.zig:860) still needs a real Value** (it inspects ex-data `:type`), forcing a materialization carve-out — the laziness does not generalize.
>
> **Explicit answers.**
> - (a)/(b) Yes / Yes. (c) Yes, most robustly. (d) Highest parity cost (two predicates × two backends + VM unwind protocol change). (e) Works once materialized; should pair with Alt 2's Value shape for correct `ex-data`. (f) Good for allocation-discipline, poor for simplicity.
>
> ---
>
> ## Non-binding ranked recommendation
>
> 1. **Alternative 2 (first-class `.host_error` Value tag) — recommended.** It is the only option that gets `(instance? clojure.lang.ExceptionInfo e)` and `(ex-data e)` *correct* — the draft's Option A silently makes every caught internal error masquerade as an ExceptionInfo (`instance? ExceptionInfo` → wrongly `true`, `ex-data` → wrongly non-nil), a fidelity defect the draft did not enumerate. Alt 2 models Clojure's actual sibling-class reality, derives the class name from the single `Kind` source with no redundant stored string, leaves the `extern struct ExInfo` untouched, and gives the best reusable precedent. It is the **largest diff** — but **per F-002 / F-009, diff size is not a project constraint, and the finished-form-clean shape wins.** Picking the draft's Option A *over* Alt 2 on "Option A is a smaller diff / Alt 2 touches the Value tag enum" grounds would be the **Cycle-budget defer smell** — re-pick Alt 2.
>
> 2. **Draft Option A (ExInfo `class_name` field) — acceptable fallback, with one correction.** If Alt 2's new-tag surface is judged too risky to land in one cycle, Option A works for catch-by-class. But it **must** additionally fix `instance?`/`ex-data` so a class-name-bearing ex_info reports `false` for `(instance? ExceptionInfo …)` and `nil` for `ex-data` consistent with the carried class — otherwise it ships the masquerade defect. With that correction Option A converges toward Alt 2 anyway, which is itself evidence Alt 2 is the finished form.
>
> 3. **Alternative 1 (`:cljw.error/class` data key) — not recommended.** Smallest diff, but leaks a synthetic key into user-visible `(ex-data e)` and still has the `instance? ExceptionInfo` masquerade.
>
> 4. **Alternative 3 (lazy match) — not recommended for this ADR.** Allocation-discipline win is real but premature; highest parity cost + perturbs the VM unwind protocol + the `:type_keyword` carve-out breaks laziness. Worth recording as a **future optimization** once a benchmark shows throw-boundary allocation matters.
>
> **Sub-decisions, resolved:** conversion at try-boundary (not raise-site) is **correct** — keeps the uncaught `[arithmetic_error]` header (ADR-0055 origin model). `not_implemented` stays **uncatchable** (Silent-default-shift smell otherwise). Uncaught Kind-header preservation **holds** for try-boundary conversion across all alternatives.

The main loop adopts the DA's **correctness findings** (gate
instance?/ex-data; conversion at try boundary; not_implemented
uncatchable; add ArityException) but realises them on the **unified
`.ex_info` representation + `class_name` field** rather than a new
`.host_error` tag, per F-011 (commonization + internals-free) and F-004
(slot economy) as narrated in § Decision. The override is F-NNN-grounded,
not a cycle-budget defer.

## Consequences

- **Positive**: `(try (/ 1 0) (catch Exception e …))` works; the most
  common Clojure error idiom matches real Clojure (verified via `clj`).
  `(catch ArithmeticException …)` / `(catch Throwable …)` resolve via
  the existing hierarchy walk. `(instance? ExceptionInfo e)` → false and
  `(ex-data e)` → nil for a synthesized exception (behavioural
  equivalence). One unified throwable representation (`.ex_info` +
  `class_name`); no new NaN-box slot; the next catchable-internal-error
  family is one `kindToHostClass` row.
- **DIVERGENCE from JVM**: cljw matches by class-name STRING + a comptime
  hierarchy table, not Class-object identity (no-JVM rule). The Kind→class
  map is coarser than JVM's per-call class (cljw's one `type_error` Kind
  maps to `ClassCastException`, where JVM might throw
  `IllegalArgumentException` for some type errors) — `(catch Exception …)`
  always catches; the precise subclass is approximate per Kind.
- **Uncatchable by design**: `internal_error`, `out_of_memory`,
  `not_implemented` keep the `return err` path + `[kind]` header.
- **`phase14_float_div.sh`** asserts `(/ 1 0)` prints uncaught "Divide by
  zero" — re-pointed: the bare form still renders the Kind header; a new
  case covers the caught form.

## Affected files

- `src/runtime/collection/ex_info.zig` — `class_name` field + accessor;
  `ex-data` gate.
- `src/runtime/error/host_class.zig` — `kindToHostClass` map;
  `thrownClassName` reads `class_name`; `ArityException` table + FQCN.
- `src/eval/backend/tree_walk.zig` — `evalTry` `else =>` synthesises.
- `src/eval/backend/vm.zig` — run-loop error path synthesises (parity).
- `src/lang/primitive/error.zig` — `ex-data`/`ex-info?` gate.
- `src/lang/diff_test.zig` — differential cases.
- `test/e2e/` — catch-internal-error cases; `phase14_float_div.sh`
  re-point.
- `.dev/debt.md` — D-048 host_instance arm note (related).
