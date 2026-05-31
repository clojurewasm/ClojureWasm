# ADR-0064 — Transient hash map handles > 8 entries via persistent-HAMT delegation (D-045 transient half)

**Status**: Proposed → Accepted (2026-05-31)

**Context owner**: autonomous loop (user-directed root-cause fix)

## Context

The §9.2.S perf campaign's O-003 work routed `into` / `vec` through
transients (`(persistent! (reduce conj! (transient to) from))`) for the
vector win (D-180, measured 50x). Routing `into {}` / `into #{}` through
transients surfaced a latent gap: cljw's **transient map caps at 8
entries**.

`src/runtime/collection/transient/transient_array_map.zig` was a flat
`[2*8]Value` buffer; `assoc!` / `conj!` past `ARRAY_MAP_THRESHOLD` (8)
raised `feature_not_supported` ("transient assoc! beyond ArrayMap
capacity (transient hash_map pending)"), and `(transient <hash_map>)`
raised `error.HashMapNotImplemented`. So `(into {} (map … (range 20)))`
ERRORED at the 9th entry — caught by `phase14_hamt_map` /
`phase14_ifn_callable` / `phase14_vector_keys` / `phase14_metadata`.

The **persistent** side is complete: `map.assoc` promotes `.array_map`
→ `.hash_map` (CHAMP HAMT) at > 8 and dedups correctly; `(reduce conj
{} pairs)` builds a correct large map. Only the transient half (D-045's
transient component) was missing. The user directed fixing this at the
root (rather than narrowing `-editable?` to vectors), with upstream /
ClojureScript / cw v0 / web research (survey:
`private/notes/phase9.2.S-D045-transient-hashmap-survey.md`).

## Decision

**Adopt Alt 1 — persistent-HAMT delegation past the threshold.** The
`TransientArrayMap` gains an `overflow: Value` field:

- **Flat mode** (`overflow == nil`, count ≤ 8): unchanged — flat
  `entries` buffer, `assoc!` replaces-in-place on a key hit / appends on
  a new key.
- **Hash mode** (`overflow` holds a persistent `.hash_map`): on the 9th
  *distinct* key, the 8 flat pairs + the new key are replayed through
  `map.assoc` into a persistent HAMT held in `overflow`; further
  `assoc!` / `dissoc!` delegate to persistent `map.assoc` / `map.dissoc`
  (which dedup + promote for free). `persistent!` returns `overflow`
  directly (re-applying `meta`). `(transient <hash_map>)` seeds hash
  mode by holding the source map directly (`map.assoc` is
  copy-on-write, so the source is never mutated).

This **reuses the one proven mechanism** (the persistent CHAMP HAMT), so
`persistent!` produces the *identical* map `(reduce conj {} …)` produces
— behavioural equivalence (F-011) is trivially guaranteed with zero new
hash structure and zero `extern struct` layout change. The transient
hash **set** (`transient_hash_set.zig`) wraps a `TransientArrayMap` as
its `inner_map`, so it is fixed transitively (`(into #{} big)` /
`(transient <big-set>)` now work).

**Hash-mode `assoc!` is persistent-path O(log32 n) copy-on-write, NOT an
in-place editable-CHAMP transient.** It is correct but delivers none of
the in-place allocation win a true transient gives. That speed gap is
tracked as **D-181** (the editable-CHAMP HAMT with a ClojureScript-style
edit token is the named finished-form candidate), deferred because maps
were never a measured §9.2.S bottleneck (the ROI there was vectors). The
delegation produces a correct HAMT — it is not a permanent-no-op / silent
lie; only the speed is provisional, and it is debt-tracked.

## Non-goals (explicit)

- **In-place editable-CHAMP transient** (Alt 3 — the JVM/cljs finished
  form). Deferred to D-181; would touch the `HamtMapNode` `extern`
  layout (F-004) for an unmeasured map win.
- **A parallel open-addressing side index + `map.fromSlice`** (Alt 2,
  the survey's pick). Rejected — see Alternatives; its `map.fromSlice`
  is not an O(n) bulk build (CHAMP slot placement is hash-driven, no
  pre-grouping), so it pays for a second hash mechanism (F-011 tension)
  to buy only a constant-factor allocation reduction.
- **HAMT → ArrayMap demotion** on `dissoc!` below 8 — the persistent
  side has none (D-156), so the transient matches: once in hash mode it
  stays hash.

## Consequences

- `(into {} big)` / `(into #{} big)` / `(transient <big-map-or-set>)` /
  `(persistent! (reduce conj! (transient {}) big))` now work (were
  errors). The 4 e2e tests pass; diff oracle vs `clj` green at scale
  (100-entry maps/sets, `=` vs `zipmap`/`set`, sorted maps/sets, meta
  carry-through, `into nil` → list).
- Map/set print order vs `clj` stays the pre-existing accepted HAMT
  iteration-order divergence (the transient path produces the *identical*
  cljw order as the persistent path — verified — so no new divergence).
- `dissoc` gains an `rt` parameter (the hash-mode delegation needs it);
  `transient_hash_set.disj` + the `dissoc!` / `disj!` primitives thread
  it through.
- `meta` is now carried through `persistent!` (the old flat `toPersistent`
  silently dropped it — a latent bug fixed here).
- Map-transient *speed* is unchanged (= persistent conj). D-181 owns the
  in-place finished form.

## Alternatives considered

Sourced from a fresh-context Devil's-advocate subagent (mandatory at
depth ≥ 2), briefed with the F-002 / F-004 / F-006 / F-011 envelope. Its
analysis is reproduced verbatim; the leading recommendation (Alt 1) is
the shape this ADR adopts.

> # Devil's-advocate analysis — Transient hash map (D-045 transient half)
>
> ## Grounding confirmed against actual source
>
> - `map.assoc` already does the full lifecycle: `assocArrayMap`
>   replaces-in-place on key hit, copy-appends below 8, and calls
>   `promoteArrayMap` on the 9th distinct key, producing a correct
>   `.hash_map`. **The persistent side is complete and correct.**
> - `promoteArrayMap` is itself an O(n) "replay flat pairs into a fresh
>   HAMT root via `hamtAssoc`" loop. A `map.fromSlice` bulk-builder would
>   be this exact loop generalised to n pairs — there is no smarter
>   bottom-up CHAMP build analogous to `vector.fromSlice` (vectors get a
>   dense left-packed trie; a CHAMP node's slot placement is
>   hash-bitmap-driven, so you cannot pre-group — you must `hamtAssoc`
>   entry by entry regardless). This is a critical asymmetry the survey's
>   "map twin of `vector.fromSlice`" framing **overstates**:
>   `vector.fromSlice` is genuinely O(n) with cheap `@memcpy`-of-32
>   grouping; a map "fromSlice" is N × `hamtAssoc` = O(n·log32 n) of
>   path-copying allocation, no cheaper than calling `map.assoc` N times.
>   The map has no O(n) bulk-build shortcut today.
> - The `transient` primitive routes `.hash_map` source →
>   `transient_array_map.fromMap` → `error.HashMapNotImplemented`. So
>   `(transient some-big-map)` errors today regardless of `into`.
> - `HamtMapNode` is `extern struct { header, _pad[2], data_map:u32,
>   node_map:u32, slots:[64]Value }` with `comptime` layout asserts and a
>   dedicated GC trace. Adding an `edit` field is a real F-004 layout
>   change touching the persistent node every map in the system allocates.
>
> ## Alt 1 — persistent-wrap past threshold
>
> - **Better:** Reuses the one proven, already-tested mechanism
>   (`map.assoc`'s array→HAMT promotion + dedup). Zero new subsystem, zero
>   layout change, zero F-004 exposure. Correctly dedups for free. The
>   transient's `assoc!`-past-8 mirrors *exactly* what `(reduce conj {}
>   pairs)` already does correctly. Smallest correctness surface to audit.
> - **Breaks / costs:** No speed win for maps. Per-`assoc!` past 8 is
>   O(log32 n) path-copy with allocation of a fresh node chain per call.
>   `into {}` of n keys = O(n·log32 n) time and allocations — same as the
>   persistent fallback. Needs a discriminator field on the transient.
> - **Big-O:** `assoc!` O(log32 n) amortised (post-threshold); `into {}
>   n` = O(n log n). `persistent!` O(1) (return `current`).
> - **F-NNN:** Fully compliant. No F-004 layout touch. F-011 **strongest
>   of the three** — one mechanism (the CHAMP HAMT), no parallel hash
>   structure, so the diff oracle contract is trivially met.
>
> ## Alt 2 — flat growable buffer + open-addressing side hash index + `map.fromSlice` (survey's pick)
>
> - **Better:** Genuinely O(1)-amortised `assoc!` (hash probe + append),
>   deferring HAMT construction to one `persistent!` pass. Matches the
>   transient_vector lifecycle shape superficially. No persistent-node
>   layout change.
> - **Breaks / costs:** Introduces a **novel open-addressing hash table
>   subsystem** that exists nowhere else in cljw — a second
>   hashing/collision-resolution mechanism living *parallel to the CHAMP
>   HAMT*. That is precisely the F-011 "one mechanism, not parallel
>   copies" tension. The side index needs its own collision handling,
>   resize policy, `valueHash`/`keyEqValue` integration, and its own
>   correctness audit against the String value-eq rule (D-151). And the
>   payoff is undercut: **`map.fromSlice` is NOT an O(n) bulk build** — it
>   is N × `hamtAssoc`, so `persistent!` is O(n·log32 n) with n allocs
>   anyway. Alt 2 moves the log-n cost from `assoc!` to `persistent!` but
>   does not eliminate it; it only removes intermediate copy-on-write
>   garbage (a constant-factor allocation win, not a complexity-class win).
> - **Big-O:** `assoc!` O(1) amortised; `into {} n` = O(n) index ops + O(n
>   log n) at persistent!. Honest total O(n log n) like Alt 1, fewer
>   intermediate allocations.
> - **F-NNN:** F-011 the weak point — a second hash mechanism parallel to
>   CHAMP.
>
> **Answer to (a) — is the survey's "vector consistency" argument sound?**
> **No, it is the weakest argument in the survey.** The vector's
> flat-buffer-then-`fromSlice` shape is finished-form *because vectors
> need no dedup* — the flat buffer maps 1:1 to trie leaves and
> `fromSlice` is a true O(n) `@memcpy` grouping. The map breaks both
> halves: (1) it needs dedup, forcing the novel side index the vector
> never had; (2) its `fromSlice` is not an O(n) bulk build. So "vector
> consistency" is *surface* consistency hiding *mechanism* divergence (a
> whole open-addressing subsystem + a fake-O(n) builder). A finished-form
> owner would not want a second hash structure parallel to the CHAMP.
>
> ## Alt 3 — editable CHAMP HAMT with cljs-style edit token
>
> - **Better:** The only alternative with genuinely O(1) `persistent!`
>   AND no per-`assoc!` full-path-copy garbage — true in-place mutation of
>   nodes minted during this session. What JVM and ClojureScript both
>   ship; cljs proves it needs no threads (edit token = a freshly-minted
>   sentinel compared by identity, fitting cljw's single-threaded,
>   no-`pub var` constraint). One hash mechanism — best F-011 story.
> - **Breaks / costs:** Touches the `HamtMapNode` `extern struct` layout
>   (add `edit: ?*anyopaque` + adjust `_pad`, re-verify `comptime`
>   asserts, extend GC trace) — a real F-004 change rippling to every
>   persistent map allocation (an extra word per node, forever, for a
>   transient-only feature). Requires a parallel editable-insert variant
>   of `hamtAssoc`/`insertDataEntry`/`pushDownDataToNode` with an
>   `ensureEditable(edit)` branch. Largest implementation surface. cljw
>   also has no HAMT→ArrayMap demotion and an unfinished collision bucket
>   (D-155) the editable HAMT inherits.
> - **Big-O:** `assoc!` O(log32 n) but in-place (no alloc when owned).
>   `into {} n` = O(n log n), near-zero intermediate allocation.
>   `persistent!` O(1).
> - **F-NNN:** F-004 — the one alternative that touches a load-bearing
>   layout. F-011 strongest (single mechanism).
>
> ## The crux — is Alt 1 finished-form-clean, or the permanent-no-op / smallest-diff smell?
>
> **Alt 1 is finished-form-clean for the correctness layer, and is NOT a
> permanent no-op. But it is NOT the finished form for transient-map
> *performance* — and that distinction must be made explicit and tracked,
> or it silently becomes the smallest-diff smell.**
>
> 1. **Permanent-no-op test:** Alt 1 lands in the "function body that runs
>    with intermediate semantics" row, NOT the forbidden "returns input
>    unchanged / masks missing feature" row. It produces a *fully correct*
>    `PersistentHashMap` — `(persistent! (into-via-transient {} big))`
>    equals `(reduce conj {} big)` byte-for-byte because it literally
>    calls the same `map.assoc`. The user does not see "success while
>    semantics are dropped". **Clears the permanent-no-op bar cleanly.**
> 2. **Is "a transient not faster than persistent" itself a smell?** If
>    shipped *and declared finished*, yes — "transient" would be hollow.
>    The honest framing: Alt 1 is the finished form of *correctness* and
>    an explicitly-provisional form of *performance*. With the speed gap
>    tracked as debt (Alt 3 named), it is a tracked bootstrap layer, not
>    Silent-default-shift.
> 3. **Deferring map-transient SPEED is finished-form-correct, not a
>    dodge:** the perf campaign's measured ROI was vectors, not maps. Maps
>    were never a measured bottleneck. Building Alt 2's subsystem or Alt
>    3's layout change *now*, for an unmeasured map-`into`, is
>    smell-adjacent speculative mechanism. The finished-form-clean
>    sequence: (a) unblock correctness with the one proven mechanism now
>    (Alt 1), (b) file a debt row naming Alt 3 as the leading candidate,
>    picked up when maps are measured to matter.
>
> **Answers:** (b) Alt 1 clears the permanent-no-op bar; finished-form for
> correctness, not for speed — mark it. (c) the perf campaign does NOT
> justify Alt 2/3 now; correctness (Alt 1) is the right scope.
>
> **(d) Alt 1 correctness traps (tested):**
> - Transition trigger = "new distinct key pushing count > 8", NOT "9th
>   `assoc!` call". A replace of an existing key while full stays flat.
> - On promotion, seed `current` by replaying the 8 flat pairs through
>   `map.assoc` then assoc the 9th.
> - `dissoc!` below 8 must NOT demote (persistent side has no
>   HAMT→ArrayMap demotion); stay hash, `persistent!` yields `.hash_map`.
> - `conj!` of a `[k v]` pair routes through `assoc!`.
> - `meta` carry-through on `persistent!`.
> - `transient` of a `.hash_map` source: seed `overflow` with the source
>   directly (removes the `HashMapNotImplemented` site).
>
> ## Recommendation
>
> **Recommend Alt 1 (persistent-wrap) for this cycle, with a mandatory
> debt row naming Alt 3 (editable CHAMP HAMT) as the finished-form speed
> target.** This is NOT a cycle-budget-defer downgrade: after grounding in
> the code, **Alt 2's central premise is unsound** — its `map.fromSlice`
> is not an O(n) bulk build, so it pays for a novel parallel
> open-addressing subsystem (F-011 liability) to buy only a constant-factor
> allocation reduction. Alt 2 is the worst trade. Between Alt 1 and Alt 3:
> Alt 3 is the true finished form, but maps are not a measured bottleneck,
> so paying an `HamtMapNode` layout change now is speculative. Unblock
> correctness with the single proven mechanism (Alt 1); let the editable
> HAMT be its own ROI unit (D-181). **Strongest single reason:** Alt 1
> makes `persistent!` produce the identical HAMT `(reduce conj {} …)`
> produces, so F-011 equivalence is trivially guaranteed with zero new
> hash mechanism and zero layout risk — while the speed gap is honestly
> tracked. If map-`into` performance *is* a near-term target, F-002 flips
> the recommendation to Alt 3 outright (skip Alt 2 — its parallel hash
> index is what a finished-form owner would unwind).

### Main-loop decision

Adopt **Alt 1**. The user's directive was a *root-cause correctness* fix
("根本的に直して") for the transient map's 8-entry cap — not a map-perf
optimization. Alt 1 fixes that root (large maps/sets work through
transients, producing correct HAMTs identical to the persistent path)
with the one proven mechanism and zero layout risk. The DA's debunking of
Alt 2 (no O(n) map bulk-build; a parallel hash subsystem is an F-011
liability) is decisive against the survey's pick. Alt 3 (the true
in-place finished form) is deferred to D-181 because maps were never a
measured §9.2.S bottleneck; building a per-node layout change now is
speculative. The speed gap is debt-tracked (D-181, Alt 3 named), so Alt 1
is a tracked bootstrap layer, not a Silent-default-shift smell.

## Affected files

- `src/runtime/collection/transient/transient_array_map.zig` (the
  `overflow` field + hash-mode `assoc`/`dissoc`/`toPersistent`/`fromMap`
  + meta carry-through + GC trace; `dissoc` gains `rt`).
- `src/runtime/collection/transient/transient_hash_set.zig` (`disj`
  gains `rt` — its `inner_map` is a `TransientArrayMap`, fixed
  transitively).
- `src/lang/primitive/transient.zig` (`dissoc!` / `disj!` thread `rt`;
  the `.hash_map`-source comment updated).
- Tests: new transient-map boundary tests (promotion, replace-in-place
  stays flat, dissoc-below-8 stays hash, `.hash_map`-source seeding, meta
  carry-through).
- Debt: D-181 (transient map in-place speed; Alt 3 = editable CHAMP).

## Cross-references

F-002 / F-004 / F-006 / F-011 · D-045 (HAMT body — this is the transient
half) · D-156 (no HAMT→ArrayMap demotion) · D-155 (collision bucket stub)
· D-181 (in-place editable-CHAMP speed, deferred) · ADR-0063 / O-003 /
D-180 (the §9.2.S into/vec transient routing that surfaced this) · survey
`private/notes/phase9.2.S-D045-transient-hashmap-survey.md`.
