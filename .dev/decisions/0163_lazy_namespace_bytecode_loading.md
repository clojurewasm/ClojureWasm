# ADR-0163 — Lazy-namespace bytecode loading: `loaded_libs`-keyed loader, eager set = JVM Clojure's no-`require` set (SSOT `bootstrap.EAGER_NS`), one position-independent blob

> The Decision below first set "eager = clojure.core only"; **Amendment 1 (bottom)
> revised it to the measured clj no-`require` set** after an F-011 regression. The
> live SSOT is `bootstrap.EAGER_NS` + `bootstrap.isEagerNs`. Read Amendment 1 first.

- **Status**: Proposed → Accepted (2026-06-24; D-516; ADR-0162 step 2 realization; DA-fork folded verbatim below)
- **Driven by**: ADR-0162 step 2 (lazy-namespace bytecode) + a Step-0 survey + Step-0.6
  + a DA red-team on the implementation design. The eager bootstrap replays
  clojure.core + ~28 non-core stdlib namespaces every startup (~5ms; non-core = 79% of
  891 chunks); a `cljw -e 1` one-liner uses ~only core. This ADR pins HOW the non-core
  set becomes lazy.
- **Relates to**: ADR-0162 (cold-start architecture — this is its step 2), ADR-0056
  (AOT bytecode envelope), ADR-0034 am4 (envelope manifest), D-516 (this unit), D-517
  (zero-copy in-place deserialize — step 3, which this format must serve). F-002
  (finished-form wins), F-011 (behavioural equivalence — clj requires explicit require),
  F-013 (single binary, no side artifacts). User-declared invariant: no .clj→Zig
  bootstrap rewrite (cljw-v0 rut) — this touches only the restore mechanism + eager set.

## Context

Today `buildBootstrapEnvelope` (builder.zig:204, the `for (files)` loop) compiles ALL
of `bootstrap.FILES` into ONE bytecode envelope eval'd in FILES order, replayed whole at
startup. The non-core 79% is replayed even when unused. Three facts from the survey +
Step 0.6 shape the design:

1. **Minimal eager need = clojure.core only.** core.clj `(require ...)`s no non-core ns;
   the default `-e`/REPL/print/error path touches only core. The one apparent exception —
   `error_context.register` needs the `cljw.error` ns — interns `*error-context*` from
   Zig via `findOrCreateNs` (it does NOT need cljw.error.clj loaded; the `with-context`
   macro is user-facing).
2. **The loader's existing-ns guard is already subtly wrong.** `loadOrFindNs`
   (loader.zig:110) short-circuits on `if (mappings.count() > 0) return existing`. A ns
   that has interned vars but whose `.clj` body has not run (exactly the cljw.error case
   after `register`, and the general `(intern 'foo 'x 1)` then `(require 'foo)` case)
   is wrongly treated as "loaded". `loadNamespace` already maintains the correct signal,
   `rt.loaded_libs` (loader.zig:38 contains / :70 put).
3. **Several bundled libs call non-core vars WITHOUT declaring `:require`** (verified:
   clojure.data→clojure.set; clojure.test→clojure.string/clojure.walk; cljw.json→
   clojure.data.json/clojure.walk; cljw.fs→clojure.java.io; clojure.pprint→clojure.string).
   The eager monolith masks this via FILES load order (the dep is always eval'd earlier).
   Lazy loading exposes it as a runtime NameError when the lib is required without its dep.
   Upstream Clojure declares these requires; cljw dropped them under eager-all.

## Decision

Adopt the DA-recommended shape (Alt B loader on Alt C format), in THREE sequenced commits.

**1. Loader guard = `rt.loaded_libs`, not `mappings.count()`.** `loadOrFindNs`'s
existing-ns short-circuit keys off `rt.loaded_libs.contains(name)`. This fixes the latent
intern-then-require bug for ALL namespaces (not just the bootstrap instance), and makes
"ns exists (has Zig-interned vars) but .clj not yet replayed" an expressible state — so
**cljw.error becomes lazy too** and the **eager set shrinks to clojure.core ONLY**. The
bootstrap (setupCoreAot) must register clojure.core in `loaded_libs` so a user
`(require 'clojure.core)` is the correct no-op. The 4 `loadOrFindNs` callers
(namespace.zig require/use) are unchanged — only the guard inside flips.

**2. Registry format = ONE contiguous position-independent blob + tail offset manifest.**
`[eager core region][lib₁ region]…[lib₂₇ region][offset manifest: name→(byte_offset,len)]`.
Each lib region is a self-contained mini-envelope (`EnvelopeIterator.init(blob[off..off+len])`
works verbatim). The manifest is a flat name→offset table at the tail. NOT 27 separate
`serializeEnvelope` outputs (which would hand D-517 twenty-seven separately-framed regions
to skip) and NOT 27 `@embedFile` sites — one embed, one position-independent rodata span,
exactly what D-517 (zero-copy in-place deserialize, the next step) wants. The regions carry
no absolute pointers (`EnvelopeIterator.next` already returns slices INTO the bytes), so the
blob is relocation-free.

**3. Trigger = explicit `require` only** (NOT first-unqualified-var-reference auto-load).
The lazy path slots into `loadOrFindNs`: on a registry hit, `runEnvelope` the lib's region
+ `loaded_libs.put`; on miss, fall through to the source resolver (filesystem user libs).
This is a **clj-parity correction** — JVM Clojure requires explicit `require`; cljw's
eager-all was the divergence.

**4. Missing-`:require` fix lands FIRST (commit 1), independently.** Add the missing
`:require`s to the lib heads (from each lib's ACTUAL non-core usage, matching upstream's
declare-your-deps). Verified safe for the eager monolith TODAY (every dep loads earlier in
FILES order, so the added require is an idempotent no-op) and clj-oracle-provable. It must
precede the split so a post-split failure is not ambiguous (require-fix bug vs split bug),
and because a require can in principle reorder the build-time chunk stream.

**5. Isolated-replay build gate (the completeness proof).** cache_gen building each region
proves it replays clean against the FULL eager set (all files in FILES order) — which is
NOT what the lazy runtime does. So a hard build gate must, for EACH lazy ns, spin a fresh
runtime, replay the eager set (core only), `(require 'that-ns)`, and assert clean. This
catches a lib that builds (its dep was eval'd earlier at build time) but fails at lazy
runtime when required without its dep — i.e. it is the mechanical proof the missing-require
set is COMPLETE. Without it, an un-fixed missing-require regresses only for users who
require in the "wrong" order — the worst, hardest-to-catch failure class.

**Sequencing (three commits):**
1. Missing-`:require` fix alone — verified against eager monolith + clj oracle + corpus.
2. Loader guard rewrite (`loaded_libs`-keyed) + the isolated-replay build gate — still
   eager-all, a pure refactor verifiable against current behaviour.
3. The lazy split (format + trim eager set to core) + **blast-radius triage**: run the full
   corpus/e2e against a lazy build, enumerate every newly-failing bare-non-core-var case,
   and disposition each (test relied on the divergence → add the require; or genuine).

## Consequences

- **Eager set = clojure.core only** → the full non-core replay (~3.6ms) leaves the common
  cold path; floor → ~4.8ms (with D-140). Discharges the eager-vs-size standing tension.
- **A real loader bug is fixed** (intern-then-require), not just D-516's symptom — F-011 net
  positive beyond startup.
- **cljw moves TOWARD clj parity** (explicit require). The blast-radius triage (commit 3) is
  a one-time correction cost; each newly-failing case was relying on the eager-all divergence.
- **The blob is D-517-ready** — one position-independent rodata span, so step 3 (zero-copy)
  drops on without re-cutting the format.
- **A new hard build gate** (isolated per-lib replay) becomes the standing guarantee that the
  lazy set stays self-contained as libs evolve.
- **Risk owned**: the #1 subtle-regression vector is an incompletely-fixed missing-`:require`
  set masked by FILES order; the isolated-replay gate is its sole defense and is therefore
  mandatory, not optional.

## Alternatives considered

The DA red-team output (fresh-context subagent, grounded in `loader.zig` / `builder.zig` /
`serialize.zig` + the debt rows) is reproduced verbatim; its recommendation drove the
Decision (it inverted the proposed Option-C: eager-cljw.error → a smallest-diff dodge of a
real loader bug; 27-separate-envelopes → a cost pushed into D-517).

> **Alt A — smallest-diff: ONE envelope, per-ns chunk-range index (loader seeks).** Keep the
> single monolith; record per-ns `[start,end)` chunk ranges in a manifest; replay only
> core's range at startup; `loadOrFindNs` seeks the iterator to the ns's range. Better:
> smallest serialize change, one contiguous blob (D-517-friendly), staged migration possible.
> Breaks: `EnvelopeIterator.next` is sequential (skip is O(N), needs a `skip(n)`); a single
> envelope weakens isolation (a mis-ordered range still rides whatever ran); does NOT force
> the missing-`:require` fix (chunks for clojure.set still physically precede clojure.data, so
> range-replay MIGHT find it interned if the user required it first — load-order-dependent
> non-determinism). F-011 weaker (does not reliably expose the missing-require bug). F-002
> disfavours.
>
> **Alt B — finished-form-clean: N self-contained envelopes + explicit per-ns `loaded` flag
> (fixes the guard bug).** Option C's split PLUS replace `mappings.count()>0` with
> `rt.loaded_libs` membership (which `loadNamespace` already maintains). With a real
> loaded-flag, cljw.error can be lazy: `register` interns `*error-context*` (mappings>0) but
> does NOT add cljw.error to `loaded_libs`, so the flag correctly says "ns exists, .clj not
> replayed" → `with-context` loads on first require. Better: fixes a REAL loader bug (the
> guard is already wrong for intern-then-require), shrinks the eager set to pure clojure.core,
> deletes the 27-vs-28 special case. Risk: higher blast radius (every loadOrFindNs caller now
> keys off loaded_libs); must verify loadCore populates loaded_libs for core; confirm the
> Zig-interned cljw.error ns's initial flag is "not loaded". F-011 strongest; F-002 prefers it
> despite the larger diff (Cycle-budget-defer smell says diff size is not a reason to pick A).
>
> **Alt C — wildcard: single concatenated blob + offset manifest, designed for D-517 from day
> one.** One `@embedFile`'d blob `[core region][lib regions…][tail offset manifest
> name→(offset,len)]`; each region a self-contained mini-envelope; laid out
> position-independent (chunk-relative offsets, no absolute pointers — serialize already does
> this) so D-517's zero-copy reader drops on with no relocation. Better: co-designs the format
> with D-517 (which ADR-0162 sequences next and requires composing) instead of letting D-517
> re-cut 27 separately-framed regions; fewer @embedFile sites than Option C. Risk: new
> serialize format (`writeOffsetManifest`/`readOffsetManifest`) — the one thing Option C
> avoided; speculative if D-517 is descoped (Reservation-as-bias). F-013 cleaner (one embed);
> F-002 defensible as finished-form since D-517 IS committed.
>
> **Registry format pressure-test.** Option C (27 separate `serializeEnvelope` outputs) makes
> D-517 HARDER: D-517 wants one position-independent rodata span with no per-chunk alloc/copy,
> but 27 separately-serialized envelopes each carry their own component-table + manifest
> framing that D-517's zero-copy reader must locate and skip 27 times, plus a separate name
> index. Finished-form-clean = ONE contiguous blob + offset manifest (Alt C), or at minimum
> Alt A's single-envelope-with-ranges. Option C's "reuse serializeEnvelope verbatim 27 times"
> is a build-time convenience that pushes cost into the D-517 cycle — the
> smallest-diff-bias-against-finished-form pattern. **Recommendation: one blob (regions) +
> offset manifest, not 27 separate envelopes.**
>
> **The `mappings.count()>0` guard.** Keeping cljw.error eager is a smallest-diff DODGE of a
> real loader bug. The guard is already incorrect for "user interns a var then requires the
> ns" — no current test hits it, but lazy loading makes the guard load-bearing for
> correctness. The clean fix is the explicit flag, and `loadNamespace` ALREADY maintains
> `rt.loaded_libs` (contains-check + put). Keying `loadOrFindNs` off `loaded_libs` (i) lets
> cljw.error be lazy (eager set = pure clojure.core), (ii) fixes the latent intern-then-require
> bug, (iii) removes the 27-vs-28 special-case. "Not worth untangling for a 27-line file"
> inverts the cost: the untangle IS the cheap correct fix; the dodge leaves a bug behind.
>
> **Missing-`:require` fix — land FIRST, unambiguously.** It is the finished form (matches
> upstream; F-011 IS clj-parity which requires explicit require) AND a correctness change
> provable against the clj oracle independently of laziness. The load-bearing risk: adding a
> require CAN change load order in the eager monolith TODAY — a newly-added head `:require`
> triggers a nested require during build-time eval that pushes the dep's chunks earlier in the
> post-order chunk stream; idempotent if the dep was already eval'd, but a reorder if FILES had
> the user before the dep. So validate it BEFORE the lazy split confounds it. Commit 1 = add
> all missing requires, green against eager monolith + oracle + corpus; commit 2+ = the split.
> Bundling makes a post-split failure ambiguous.
>
> **Trigger = explicit require only — clj-parity-correct, yes.** JVM Clojure requires explicit
> require for every non-clojure.core ns; eager-all is the CURRENT cljw divergence. Blast radius
> (MUST quantify before shipping): every existing e2e/corpus/test using a non-core var without
> requiring it newly fails (suspects: bare clojure.string/set/walk/test). Mechanical sweep:
> grep e2e/corpus for non-core qualified vars + unqualified-via-eager-refer uses; run full
> corpus+e2e against a lazy build and COUNT failures; each is a test bug (add the require) or
> genuine. Acceptable as a parity correction ONLY with the failure list triaged, not a blind
> flip.
>
> **Build-time replay-clean gate — NOT redundant.** cache_gen building each envelope proves it
> replays clean against the FULL eager set (all files in FILES order). The lazy runtime replays
> against the TRIMMED eager set. A lib that builds because clojure.set was eval'd before
> clojure.data in FILES order FAILS at lazy runtime if clojure.data is required without
> clojure.set — and the build gate won't catch it (clojure.set WAS there at build). So the gate
> must replay each lazy lib IN ISOLATION (fresh runtime, eager-only, require the one lib, assert
> clean). It is the mechanical proof the require-fix is complete.
>
> **Recommended shape + sequencing.** Adopt Alt B's loader (`loaded_libs`-keyed guard, eager =
> clojure.core only, cljw.error lazy) on Alt C's format (one contiguous position-independent
> blob + tail offset manifest, D-517-ready). Reject Option C's 27-separate-envelopes +
> eager-cljw.error (both smallest-diff dodges). Commits: (1) missing-`:require` fix alone,
> oracle-verified; (2) loader guard rewrite + isolated-replay build gate, eager-all pure
> refactor; (3) lazy split + blast-radius triage.
>
> **The ONE thing most likely to ship a subtle regression:** an incompletely-fixed
> missing-`:require` set masked by FILES eval order — a lazy ns that builds clean (dep eager at
> build) but is required at runtime before its dep — works for the common order, fails for an
> uncommon one, invisible in build or a require-order-lucky test. Sole defense: the isolated
> per-lib replay gate for ALL 27 libs as a hard build gate.

Main-loop choice WITHIN the F-NNN envelope (the subagent's recommendation is not binding):
adopted in full — the DA's reasoning is F-002/F-011-aligned and the larger diff (guard
rewrite + new format) is the finished form, so the Cycle-budget-defer smell forbids picking
the smaller Option C.

## Amendment 1 (2026-06-24) — the eager set = JVM Clojure's no-`require` set (F-011)

The Decision above said "eager set = clojure.core ONLY". Implementation surfaced
an F-011 regression (user-flagged): JVM Clojure makes several non-core namespaces
usable WITHOUT an explicit `require`, and core-only-eager broke them
(`(clojure.string/upper-case "hi")` → Name error in cljw, "HI" in clj). The user
directive: *match clj — what clj bundles without require is by usage frequency, not
logic; align cljw to it*, and keep the eager/lazy split a **single SSOT**.

**Measured (2026-06-24, fresh `clj`, `(some? (find-ns 'X))` with no require):**

| auto-loaded in clj (TRUE) → cljw EAGER | NOT auto-loaded (FALSE) → cljw LAZY (require needed) |
|----------------------------------------|------------------------------------------------------|
| clojure.core, clojure.string, clojure.walk, clojure.edn, clojure.java.io, clojure.core.protocols, clojure.uuid, clojure.instant, clojure.spec.alpha | clojure.set, clojure.zip, clojure.data.json, clojure.data.csv, clojure.tools.cli, clojure.pprint, clojure.test, clojure.data, clojure.math, clojure.template, clojure.stacktrace, clojure.datafy, clojure.repl (+ cljw.* originals) |

**SSOT** = `bootstrap.EAGER_NS` (a `StaticStringMap`) + the single predicate
`bootstrap.isEagerNs`. `loadCoreAot` runs ONLY `isEagerNs` regions (in FILES order);
every other ns is a lazy region replayed on first `require`. spec.alpha's own deps
(spec.gen.alpha / core.specs.alpha) load transitively when its eager region runs.
This is STRICT clj-parity: clj's `clojure.set` is NOT auto-loaded either, so cljw
requiring it matches (verified: `set` no-require → Name error in BOTH).

**Cold-start cost of parity**: floor 8.6ms (all-29 eager) → 4.6ms (eager = the 9-ns
auto-set) vs 3.1ms (core-only, which violated parity). The +1.5ms over core-only
buys exact clj-parity — accepted per F-011/F-002 over a parity-violating 3.1ms.

**Unwind caution (user-flagged)**: eager-all was partly a D-452 optimization
(avoid re-parse). The lazy regions stay BYTECODE (no re-parse on lazy load either),
so that optimization is preserved; only the *eager replay* of unused libs is removed.
A second require path bug surfaced + was fixed in the same arc: `evalRequire`
(tree_walk) + `op_require` / `op_require_with_libspec` (vm) each carried an inline
copy of the load logic with the `mappings.count() > 0` short-circuit (which mis-fires
when `registerAll` pre-interned a ns's private leaves — clojure.string's `-upper-case`);
all three now route through the single `loader.loadOrFindNs`. And `loadOrFindNs` keeps
the `mappings.count() > 0` check as a LAST resort (after loaded_libs + region + source
all miss) so an INLINE-defined ns — `(ns mylib …)` then `(require '[mylib])`, no region
or file — is still found-as-is rather than raising lib_not_found (a real regression the
core-only flip introduced, caught by phase14_macro_shadow_builtin).
