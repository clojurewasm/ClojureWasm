# 0056 — AOT-bootstrap: build-time bytecode envelope for the embedded `.clj` bootstrap (edge per-instance cold-start)

**Status**: Accepted (Devil's-advocate fork landed 2026-05-30; adopted Alt-2 sharpened framing)
**Date**: 2026-05-30
**Author**: Shota Kudo (drafted with Claude autonomous loop)
**Tags**: aot-bootstrap, edge, startup, bytecode-envelope, cache_gen, F-002, F-004, F-006, F-009, F-010, ADR-0034-D4, ADR-0036, D-131, D-103, D-139

## Context

`src/lang/bootstrap.zig::loadCore` (`:127-165`) re-runs the full
read → analyze → macroexpand → eval pipeline over **12 `@embedFile`'d
`.clj` sources** (`:53-66`: core / string / set / walk / zip / edn /
data.json / data.csv / tools.cli / pprint / test / cljw.error) on
**every** process / Wasm-instance startup. `setupCore` (`:174-183`) is
shared by three call sites (F-009): the REPL/CLI runner,
`builder.buildFile` (build-time), and `builder.tryRunEmbedded`
(built-app startup, `builder.zig:148`). So even a `cljw build`-produced
binary — whose *user* payload is precompiled bytecode — still re-evals
the entire bootstrap at startup. ADR-0034 §A1-D3 + **D-131** record this
as a tracked deferred gap; ADR-0034 §D4 already planned a "bootstrap
cache (bytecode) … core lib build-time bytecode化, 12ms → 3-4ms" via a
`cache_gen.zig` build stage (cw v0 evidence). This ADR executes that
deferred block with the v1-fitted shape.

**Why now, and why it is an edge task, not a native-CLI task.** The
mission (ROADMAP §1) is "cold start ≤ 10 ms, Edge execution (Cloudflare
Workers / Fastly / Fermyon Spin / Wasm Component Model)". Native CLI
cold-start is **already met** — `bench/quick_baseline.txt`
`cold_start_us = 6560` (budget 12000) WITH `loadCore` running every time
— because a native `cljw -e` is dominated by OS process spawn + dyld +
page-cache warm of the ~6.8 MB binary; the bootstrap eval is a few ms on
top (D-140 notes the native self-exe re-read isn't worth optimizing).
**On the edge/Wasm target the calculus inverts**: a Wasm Component
instantiated per request has no OS spawn and no dyld — the runtime is
already resident — so the per-instance bootstrap eval (parse+analyze+eval
of 12 `.clj` files into a fresh env) is *pure repeated overhead*. At the
per-request instance churn the edge mission targets, eliminating that
eval is the whole game. This is an **edge-readiness** task; the user
directed it now (2026-05-30) ahead of the default coverage sequence.

**Two facts that shape the decision** (Step-0 survey
`private/notes/phaseA26-d-aot-bootstrap-survey.md`):

1. v1's `serialize.zig` **already serializes `fn_val` by contents**
   (ADR-0034 am2, `:252-289`): `slot_base` + per-method
   `arity`/`has_rest` + recursive `serializeChunk` of the method's
   bytecode. The on-disk form is **index/tag-based** (decoder-stable
   `ValueTag`, ADR-0034 D11), never raw NaN-box bits — so restore
   reconstructs Values via live constructors and **no pointer relocation
   is needed** (F-004 / F-006 are untouched). The `cljw build`
   user-payload path (`builder.buildEnvelope` + `serialize.serializeEnvelope`
   + `EnvelopeIterator`) is already shipped and differentially verified.
2. The one real constraint: `loadCore` runs under the comptime-routed
   **default backend = `tree_walk`** (`driver.zig:32-45`, `build.zig:35-37`,
   ADR-0036), so bootstrap fns become TreeWalk **AST closures**
   (`bytecode == null`) which the serializer cannot round-trip
   (`serialize.zig:281-288` needs `m.bytecode`). This is the v0
   `vmRecompileAll` problem (`cache.zig:119-183`) — bootstrap must be
   **VM-compiled** before it can be snapshotted.

## Decision

Implement **D2 (AOT bytecode bundle) composed with D3 (lazy bootstrap)**,
in the **Devil's-advocate Alt-2 sharpened framing**: route the eager
bootstrap, lazy-`require`, and `cljw build` through **one
`runEnvelope(rt, env, bytes)` primitive** over the single shipped
envelope format — no parallel "bootstrap cache" code path. F-009-cleanest
(the bytecode-def-interning impl lives once; `setupCore` and the
`require` resolver are callers). Reusing the shipped build path, not
porting v0's bespoke ~3000-line env-snapshot serializer.

**Two finished-form obligations absorbed now (not deferred), per the DA:**

- **VM-dispatch hybrid at the runner (the one real knot).** The
  production runner installs the `tree_walk` vtable (ADR-0036), but
  AOT-restored core fns are bytecode-only (`body == null`) and must
  dispatch on the VM. The clean answer is the **per-method
  `bytecode`/`body` invariant that already exists** on `FunctionMethod`
  (`tree_walk.zig:107-123`): a fn with `bytecode != null` runs on the VM
  dispatch path, one with only `body` runs TreeWalk — so a
  tree_walk-default runner can host AOT core fns *and* TreeWalk-eval
  fresh user REPL/file forms. Cycle 1 must wire this call path (and
  confirm the VM dispatch is available — not comptime-excluded — in a
  `tree_walk` build).
- **Discharge D-139 (param-name fidelity) in the cycle that ships AOT
  core.** Deserialized fns currently drop param-name strings; once core
  is AOT'd, that regresses the default REPL's stack-trace labels for
  core fns. Serialize param names so core error frames keep their labels.

1. **Build-time bootstrap compilation (`cache_gen` analog).** A build
   stage VM-compiles the embedded bootstrap `.clj` sources to a bytecode
   **envelope** (one `BytecodeChunk` per top-level form, exactly as
   `builder.buildEnvelope` does for user programs) and embeds the blob.
   The stage runs the compile under `-Dbackend=vm` so the produced
   `fn_val`s carry `bytecode` (the `vmRecompileAll` equivalent), even
   though the runtime's default backend stays `tree_walk` — sound because
   the two backends are contract-equivalent (ADR-0036) and the runtime
   already dispatches AOT bytecode fns regardless of its own default
   (the `cljw build` user-payload path proves this).
2. **Startup restore.** A `setupCore` variant deserializes + VM-runs the
   embedded envelope (each `op_def` interns its Var) **instead of**
   `loadCore`'s parse+analyze+eval. Zig-side macros
   (`macro_transforms.registerInto`) and primitives
   (`primitive.registerAll`) register exactly as today — they are not in
   the `.clj` files, so AOT'ing the `.clj` sources does not affect macro
   availability for runtime REPL/eval.
3. **Lazy split (D3).** Only `clojure.core` (+ whatever it transitively
   needs) is eager; the other libs deserialize + run on first `require`
   (the embedded resolver path), mirroring v0's hybrid (§1.4). This
   serves the edge small-handler case (don't pay for pprint/csv/json on a
   one-liner) and is orthogonal to / composable with D2.
4. **Versioning.** The embedded blob carries the `serialize.zig` wire
   version AND the peephole rule-set identity (D-103) so a stale cache is
   rejected, not mis-run.

`cljw build` artifacts gain the same benefit by construction: once the
runtime restores its bootstrap from the embedded bytecode, `tryRunEmbedded`
no longer needs the full `loadCore` (advancing D-131).

### Incremental implementation plan (each a TDD cycle, gate-green)

- **Cycle 0 — resolve the VM-dispatch knot (prerequisite).** Confirm
  whether a bytecode-only `Function` can run in a `tree_walk`-default
  build (is the VM dispatch comptime-excluded?). Wire the per-method
  `bytecode`/`body` hybrid so the production runner dispatches a fn with
  `bytecode != null` on the VM while TreeWalk-evaling user input. Smallest
  proof: hand-build a bytecode fn (via `vm_compiler.compile`) and call it
  from a tree_walk-default runner. Without this, AOT core cannot run.
- **Cycle 1 — mechanism proof on the biggest file + D-139.** AOT-compile
  *only* `core.clj` to an embedded envelope at build; add the
  `runEnvelope` primitive + a `setupCore` path that deserializes+VM-runs
  it instead of parsing core.clj; **serialize param names (discharge
  D-139)** so core error frames keep labels. Verify parity (every e2e +
  diff green) + measure the parse/analyze skip.
- **Cycle 2 — the `cache_gen` build stage + all eager files.** Generalize
  to the eager `FILES` subset; wire the 2-stage build (`build.zig`).
- **Cycle 3 — D3 lazy deferral** for the rare/heavy namespaces.
- **Cycle 4 — `tryRunEmbedded` uses the cache** (discharge D-131's
  bootstrap-cache block) + edge/Wasm-instance cold-start measurement.

Each cycle keeps `loadCore` as the fallback until its successor is
proven, per F-002 skeleton-then-rewrite (no silent semantic drop).

## Alternatives considered

Devil's-advocate fork (`private/notes/phaseA26-d-aot-bootstrap-da.md`,
fresh context, F-NNN envelope). **Leading finding: no F-NNN amendment is
required by any alternative** — the index/tag wire format (F-004) already
decouples on-disk from NaN-box; the only F-006 stressor (D4) is already
rejected. The DA also verified two facts that *strengthen* the decision:
(1) AOT'ing core does NOT break macros — `core.clj` has **zero**
`defmacro` (all of `let`/`when`/`->` are Zig-side `macro_transforms`); the
only bootstrap `defmacro` is `cljw.error/with-context` (+2 in test.clj),
and a `defmacro` lowers to `op_def` + `DEF_FLAG_MACRO` (`compiler.zig:569`)
stamped at run time (`vm.zig:172`), AOT-agnostic. (2) The build path
already runs dual-mode (`tryRunEmbedded` installs the VM vtable + runs
`setupCore` and deserialized chunks together).

The three within-envelope alternatives (DA verbatim findings condensed;
full text in the DA note):

- **Alt-1 — smallest-diff: D3-only lazy bootstrap, no AOT.** Split
  `FILES` eager (`core` + `cljw.error`) vs lazy; stop force-loading the
  lazy 10, let `require` pull them. *Better*: zero new serialization
  surface, no VM-dispatch knot, no cache versioning, no stale-artifact
  risk. *Breaks*: does NOT solve the stated problem — `clojure.core` (the
  largest file) still re-evals on **every** edge instance (survey §3.D3).
  Picking it for diff-size is "the Cycle-budget defer smell in its purest
  form". **Verdict: reject as standalone; keep as the D3 layer D2+D3
  already includes.**
- **Alt-2 — finished-form-clean: unify bootstrap + lazy-require +
  `cljw build` through one envelope-run primitive (this IS D2+D3,
  sharpened).** *Better*: removes the last special case — one
  `runEnvelope` helper, one place bytecode-defs intern (F-009-cleanest);
  forces the VM-dispatch knot to be solved cleanly at the runner; single
  artifact = single version field (D-103 solved once). *Breaks/cost*: the
  VM-dispatch-in-tree_walk-runner knot is real engineering (the per-method
  `bytecode`/`body` hybrid must be wired), and D-139 (param-name drop) now
  hits **core** error frames so must be discharged in the same cycle.
  **Verdict: the DA's pick — adopt D2+D3 in this framing.** (This ADR's
  Decision.)
- **Alt-3 — wildcard: per-form analyzed-AST memo cache (not bytecode).**
  Serialize the post-macroexpansion `Node` AST; restore + `evalForm` on
  TreeWalk, skipping Reader+Analyzer. *Better*: no backend mismatch
  (restored fns are TreeWalk closures, exactly what the default runner
  expects — the VM-dispatch knot vanishes); param names survive (no
  D-139). *Breaks*: the **wrong finished form** — needs a brand-new
  bespoke serializer for the arena-lifetime, pointer-rich `Node` graph
  (forks the serialization impl, violates F-009 + DIVERGENCE-1; harder to
  make index/tag-stable than the already-flat bytecode), and becomes dead
  weight the moment the VM is the hot-path backend (F-010's JIT). **Verdict:
  reject — a clever local optimum the finished-form owner unwinds.**

From the survey's design space (rejected before the DA pass):

- **D1 — full env-snapshot (v0 style).** Serialize the whole
  post-bootstrap env via a bespoke env-walker (mirrors v0
  `serializeEnvSnapshot`, ~3000 LOC) + deferred-var fixup lists +
  static-var-cache re-pointing. **Rejected**: duplicates capability v1
  already has (`buildEnvelope` compiles a program to a chunk envelope);
  porting v0's env serializer violates `no_copy_from_v1` and is a
  larger, less-reused surface than treating bootstrap as "just another
  program to AOT" (D2). Same `vmRecompileAll` prerequisite as D2 but more
  new code.
- **D4 — heap image / unexec (GraalVM native-image style).** Dump the raw
  GC heap at build, restore/mmap at startup. **Rejected**: the only
  option that hits F-004/F-006 — v1's 44-bit *shifted* pointer
  (`addr>>3`) is an absolute in-process address; a restored heap at a
  different base (ASLR; Wasm fresh linear memory per instance) needs
  every NaN-box payload + internal pointer relocated against a
  non-moving mark-sweep heap. Disproportionate when D2 removes the
  parse/analyze cost without touching the heap representation.

## Consequences

- **Edge/Wasm per-instance cold-start** drops to deserialize + VM-run
  defs (no Reader / Analyzer / macroexpander on the hot path) — the
  mission win. Native CLI is roughly unchanged (already OS-spawn-bound).
- **New build stage** (`cache_gen` analog) + a build-vs-runtime backend
  split (build compiles under `-Dbackend=vm`; runtime default stays
  `tree_walk`). The gate must build the cache stage.
- **`loadCore` remains** as the source-of-truth fallback during the
  incremental rollout and for the non-AOT dev path; the AOT path is the
  edge/release path.
- **D-139 fidelity gap** rides along: deserialized fns currently drop
  param-name strings (AOT error frames lose param labels) — a fidelity
  gap, not a semantics drop; tracked separately.
- **Cache invalidation** is a new failure surface — a bytecode blob
  compiled by a different `serialize.zig` version / peephole rule set
  (D-103) must be rejected at load, not mis-run.
- A `defmacro` *inside* a `.clj` file (if any exist) needs its macro
  registered at runtime for user code to expand it — Cycle 1 must audit
  the `.clj` files for `defmacro` and confirm the AOT path preserves
  runtime macro availability (expected: macros are Zig-side, so none —
  but verify, do not assume).

## Affected files

- `src/lang/bootstrap.zig` — `setupCore` variant (restore-from-envelope);
  eager/lazy `FILES` split.
- `build.zig` — `cache_gen` build stage (compile bootstrap under
  `-Dbackend=vm`, embed the blob).
- `src/app/builder.zig` — `buildEnvelope` reused for bootstrap;
  `tryRunEmbedded` uses the cache (Cycle 4).
- `src/eval/bytecode/serialize.zig` — version/peephole identity in the
  blob header (D-103); possibly an env-level envelope wrapper.
- `test/e2e/` — AOT-bootstrap parity + cold-start e2e.
- `.dev/debt.md` — advance/discharge D-131; note D-139.

## Revision history

- **2026-05-30 (initial issue + DA fork)**: Status Proposed → Accepted.
  Devil's-advocate fork (`private/notes/phaseA26-d-aot-bootstrap-da.md`)
  produced Alt-1 (D3-only, rejected — leaves core re-evaling),
  Alt-2 (unify via one `runEnvelope` primitive, **adopted as the
  sharpened framing**), Alt-3 (AST-memo cache, rejected — bespoke AST
  serializer forks the impl, F-009 + DIVERGENCE-1). DA verified the
  macro-availability worry is void (zero `defmacro` in core.clj) and that
  the dual-mode build path already exists. Two finished-form obligations
  pulled forward into the rollout (VM-dispatch hybrid → new Cycle 0;
  D-139 param-name discharge → Cycle 1) per F-002 (surgery over the
  smaller diff), not deferred.
