# ADR-0134: IObj/IMeta activation — make every clj-IObj substrate metable (D-271)

- Status: Proposed → Accepted (2026-06-12)
- Governing facts: **F-011** (behavioural equivalence on VALUE), **F-002**
  (finished-form wins; cycle/LOC is not a constraint), **F-013** (closed-set
  recognition up-front). F-004 is UNTOUCHED (a `meta: Value` field on a HEAP
  extern-struct is not a NaN-box slot). F-003 does NOT govern: D-271 is a
  clj-parity quality-loop FLOOR item (`tech_debt_consolidation.md` — the post-M
  quality loop owns clj-parity floor items), so there is no future-Phase owner to
  defer the layout change to. Closes the ADR-0116 Decision D deferral.
- Supersedes: the D-271 "SCOPE CORRECTION" reading that treated this as
  F-003-deferrable.

## Context

`clojure.lang.IObj`/`IMeta` resolve to NEITHER a class value NOR `instance?`
membership in cljw (both name_error; contrast IFn/Object/Number, which ARE
landed via the analyzeSymbol interface-marker arm + an `interface_membership.zig`
table row). The membership sets are enumerated INACTIVE in
`interface_membership.zig` (ADR-0116 Decision D), gated on D-271 because clj
guarantees the invariant `(instance? clojure.lang.IObj x)` ⟹ `(with-meta x m)`
works, and cljw's `.range`/`.cons`/etc. substrates carry no meta slot — claiming
membership without with-meta support would be an internally inconsistent core
predicate.

This blocks two real things: (a) `(with-meta (range 3) m)` (the original D-271
bug); (b) **clojure.datafy** — its core guards `(instance? clojure.lang.IObj v)`,
which name_errors, so the whole ns cannot load clj-faithfully (the datafy P3
ns-backfill is otherwise unblocked: Throwable->map landed D-389, core.protocols
present).

clj-oracle-verified IObj membership (2026-06-12): **IObj** = vector, list,
hash_set, sorted_map, sorted_set, persistent_queue, cons, lazy_seq, range,
chunked_cons, array_map, hash_map, string_seq, array_seq, symbol, promise,
future, **and fns** (`(meta (with-meta (fn [] 1) {:a 1}))` → `{:a 1}`).
EXCLUDES delay, keyword, map_entry. **IMeta** = IObj ∪ {atom, agent, ref,
var_ref, ns}. Already-metable in cljw: vector, list, hash_set, array_map,
hash_map, lazy_seq, symbol, persistent_queue (+ var_ref/atom/record/reify).

## Decision

**Finished form** = every clj-IObj substrate metable + full IObj/IMeta membership
+ value-resolution matching clj's oracle-verified set (DA-fork Alt 2 "Full" — the
only shape where the clj invariant holds for every tag with zero exceptions, no AD
needed). This is the terminal target and does not change.

**Execution = VALUE-DRIVEN, not speculative-complete-now (amended 2026-06-12 after
a user finished-form reconsideration that caught a Progress-pressure /
scope-escalation smell in the original "do all 13 substrates now" framing).** The
original D-271 bug (`(with-meta (range 3) m)`) is NICHE, but the IObj/IMeta
VALUE-RESOLUTION + membership half now has **TWO real consumers** (found via P4
lib-load, 2026-06-12): **clojure.datafy** (its core guards
`(instance? clojure.lang.IObj v)`) and **instaparse** (instaparse.auto_flatten_seq
is a deftype EXTENDING `clojure.lang.IObj`/`IMeta` + `(instance? clojure.lang.IObj
obj)`; blocks at auto_flatten_seq.cljc:157). instaparse additionally needs the
clojure.lang.* deftype-supertype recognition/remap (D-280 family) for the
extend-type half. So the value-resolution + metable-tag-membership slice (the
first slice below) is now PULLED — no longer purely speculative; the remaining
cross-zone fn-meta (tree_walk closure ctors + multimethod + protocol, for the rare
`(with-meta a-fn m)`) is still high-effort / near-zero-value and stays last. So:

- A substrate is made metable + admitted to IObj/IMeta membership **when a real
  consumer pulls it** (or opportunistically when its module is already open), NOT
  speculatively to chase clj-completeness.
- Membership stays **consistent at every step**: `(instance? IObj x)` is activated
  for tag x ONLY once x is genuinely metable, so the invariant
  `instance? IObj ⟹ with-meta` never breaks. The set being NARROWER than clj
  (range/cons/fn report `(instance? IObj x)` → false until made metable) is an
  HONEST, TRACKED gap (D-271), NOT a lie and NOT an AD — it is ordinary
  incremental growth, and `(instance? IObj range)`→false is graceful (a ported
  `(if (instance? IObj x) (with-meta x m) x)` returns x unchanged, not an error).
  This is the DA's permitted sequencing variant (interim narrow membership +
  completion debt row), elevated to the execution path.
- **The terminal Full membership flip is reached by accretion, not a single
  speculative leap.** "Big-bang" (the original framing) is reinterpreted: never
  ship a narrow membership as PERMANENT (that would be the gap-as-AD lie), and
  never drip COVERAGE claims — but DO grow the metable set value-first.

The first value-driven slice (whenever taken): resolve `clojure.lang.IObj`/`IMeta`
as class values + activate membership for the CURRENTLY-metable tags (vector/list/
hash_set/array_map/hash_map/lazy_seq/symbol/persistent_queue/var_ref/atom/record/
reify) — this clears the `name_error` and is the part datafy's guard exercises.
Each later substrate (range/cons/sorted/promise/future/fn) joins when pulled.

Per-substrate work (template = `lazy_seq.zig`'s `meta: Value = nil` field):

1. Add a `meta: Value` field to the extern structs of the currently-unmetable
   IObj tags: **cons, range (LongRange), chunked_cons (ChunkedCons; ChunkBuffer
   is an internal node, no meta), string_seq, array_seq, sorted_map, sorted_set,
   promise, future**, and the **fn tags** (fn_val/builtin_fn/multi_fn/protocol_fn
   — a callable carrying meta; mind the closure/dispatch structs).
2. Mark the new `meta` field in each tag's GC-trace arm (`gc/tag_ops.zig`) — the
   one genuine hazard; a missed mark is a use-after-free.
3. Add `metaOf` + `withMeta` (shallow-copy sharing internals, new meta) per
   struct; wire the `metadata.zig` `metaFn`/`withMetaFn` switch arms.
4. Activate the IObj/IMeta rows in `interface_membership.zig` (flip INACTIVE →
   table rows pointing at the verified tag-set constants).
5. Resolve `clojure.lang.IObj`/`IMeta` as class values (analyzeSymbol
   interface-marker arm, mirroring IFn/Object).

**Execution sequencing (value-driven; amended 2026-06-12 per the Decision above).**
Steps 1-3 (adding a `meta` field + GC-trace + metaOf/withMeta to a substrate) are
an INDEPENDENT `(with-meta <substrate> m)` bug-fix per tag, done WHEN PULLED. Steps
4-5 (membership rows + value-resolution) activate PER TAG as that tag becomes
metable — `(instance? IObj x)` is switched on for x ONLY once x is genuinely
metable, so the one-directional invariant (`instance? IObj` ⟹ `with-meta`) holds at
every step. The membership set therefore GROWS toward clj's full set by accretion;
it is narrower than clj in the interim (an honest, D-271-tracked gap, NOT a
permanent AD). "Big-bang" is reinterpreted as the two PROHIBITIONS it really
protects: (1) never ship a narrow membership as PERMANENT (gap-as-AD lie), (2)
never drip COVERAGE claims — NOT a mandate to build all 13 substrates before any
membership activates. The cross-zone fn tags (`eval/backend/tree_walk.zig` closure
ctors + `multimethod.zig` + `protocol.zig`) are LAST and only if a consumer needs
fn-meta (rare). Each substrate's GC trace is torture-verified independently before
the next.

**Execution mandates (make Full safe):**
- **Per-tag with-meta round-trip corpus line under `CLJW_GC_TORTURE`** for each
  newly-metable struct (`(meta (with-meta <ctor> {:a 1}))` → `{:a 1}`). This is
  what converts F-012 (diff oracle) + torture coverage from theoretical to actual
  on the GC-trace risk — without a per-tag line that traverses the new field, the
  torture coverage is only nominal.
- Match clj's set EXACTLY (exclude delay/keyword/map_entry from IObj) so F-013's
  closed-set recognition stays honest; no over-claim.
- Big-bang per `clj_diff_sweep.md` Discipline 2 — all substrates in one focused
  push, NOT one-struct-per-commit (the drip-feed smell).

## Consequences

- `(with-meta (range 3) m)` / cons / sorted-map / fn / etc. all work; `(meta …)`
  round-trips; `(instance? clojure.lang.IObj x)` / `IMeta` match clj on every
  tag. clojure.datafy unblocks. D-271 discharges; no residual AD.
- Extern-struct sizes grow by 8 bytes (one Value) on ~13 substrate structs. The
  fn tags are the delicate part (meta on a callable — confirm it composes with
  dispatch/closure capture and does not perturb the call path).
- sorted_map/sorted_set carry comparator state; the meta field is orthogonal to
  ordering (verify withMeta preserves the comparator).
- GC-trace correctness is the load-bearing risk, covered by the per-tag torture
  corpus mandate above.

## Alternatives considered

(Verbatim from the mandatory Devil's-advocate fork — `general-purpose`, fresh
context, F-NNN envelope.)

**Leading finding:** No F-NNN is violated by any alternative. F-004 untouched
(heap field, not a NaN-box slot). F-003 does NOT forbid the loop doing the layout
change — D-271 is a clj-parity floor item the post-M quality loop OWNS; there is
no Phase owner to defer to. The choice is governed by F-011 + the clj invariant,
not an F-NNN block. Pivotal sub-ruling: value-resolution and membership are
SEPARABLE code points, and datafy is unblocked by partial-but-correct membership
(it only feeds maps/vectors to its own guard) — but a core predicate returning
**false-where-clj-true** is a SEMANTIC divergence (categorically worse than the
representational AD-001/AD-003), so a narrower-than-clj IObj is an acceptable
INTERIM but not a finished form.

- **Alt 1 — Narrow (smallest-diff):** resolve values + activate membership ONLY
  for currently-metable tags; AD for the clj-IObj-but-cljw-not-metable tags
  (cons/range/sorted/etc. report `(instance? IObj x)` → false where clj true).
  BETTER: unblocks datafy + literal/collection with-meta with zero substrate
  risk, internally consistent. BREAKS: ships a core predicate that LIES vs clj on
  ~9 tags — a semantic gap any IObj-guarding ported lib hits; sorted_map/set
  exclusion especially sharp. Finished-form-clean ONLY if cljw's IObj is
  permanently a subset, which contradicts F-011. Legitimate interim, NOT terminal.
- **Alt 2 — Full (finished-form-clean) — RECOMMENDED + CHOSEN:** add meta to all
  unmetable IObj substrates THEN activate full membership. BETTER: clj invariant
  holds for every tag, no AD, F-011 fully satisfied — the only option with no
  core predicate lying (F-002 terminal shape). BREAKS/RISK: multi-struct layout +
  per-struct GC-trace (the real hazard) — covered by F-012 + CLJW_GC_TORTURE
  PROVIDED each new field gets a torture-exercised with-meta round-trip corpus
  line (else torture coverage is theoretical).
- **Alt 3 — Wildcard (uniform side-table meta), REJECTED on correctness:** store
  meta in a pointer-keyed side-table, one GC-trace site. BETTER: one mechanism,
  no layout change. BREAKS: violates Clojure's meta-is-value-not-identity
  contract (with-meta returns a NEW object; pointer-identity keys conflate
  allocation with value, desync on copy/realize, leak without weak keys which a
  moving GC makes unstable — collides with F-006 + `gc_rooting.md`). A
  misuse-resistant-looking shortcut that is a correctness violation. The
  sequencing sub-variant (Alt 1 now → Alt 2 next, with a completion debt row) is
  the ONLY acceptable form of staging, never Alt 1 standing alone (drip-feed
  smell).

DA recommendation: **Alt 2 (Full)**, with the per-tag torture corpus mandate +
exact-clj-set matching. The main loop adopts this unchanged.
