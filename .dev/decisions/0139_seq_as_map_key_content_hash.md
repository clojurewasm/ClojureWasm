# ADR-0139 — seq / lazy / Sequential-instance as a map/set KEY hashes by content

- Status: Proposed → Accepted (2026-06-14)
- Deciders: autonomous loop (Track D D1, sweep_plan.md § Track D)
- Extends: ADR-0129 (ambient `dispatch.current_env` for the rt-free key
  path) — broadens its arming + its rt-aware hash/eq to sequential keys
- Relates: ADR-0056 (`runEnvelope` AOT driver — gains the same arming),
  D-427 (Sequential deftype `=` element-wise), D-092 (rt-free key
  hash/eq), F-011 (behavioural equivalence), F-002 (finished-form wins),
  F-004/F-006 (NaN-box / GC — the deferred Alt-2 owner)
- Discharges: D-432, D-408
- Opens: D-437 (nested seq/lazy key + rt-free memoized seq-key hash —
  the deferred finished form)

## Context

A content-equal `lazy_seq` / `cons`-over-lazy / `range` / Sequential-
declaring `deftype`/`reify` used as a **map/set KEY** hashed by IDENTITY,
not by element content. So `(get {(map inc [0 1 2]) :x} '(1 2 3))` → cljw
`nil` where clj returns `:x`, even though `(= '(1 2 3) (map inc [0 1 2]))`
is already `true` (D-427). The `=` side is rt-threaded (`Cursor` forces
thunks); the KEY side (`valueHash` → `seqHash` over the rt-free
`SeqKeyCursor`, + `keyEqValue`) had no Runtime, so a lazy/instance key
could not be realized and `SeqKeyCursor` documented it as an identity
residual (truncation fallback). A content-equal key thus landed in a
different HAMT bucket and was never found — a silent miss (the worst
F-011 failure class), not an accepted divergence (clj supports it).

ADR-0129 (D-377) had ALREADY broken the "key path is rt-free" premise: it
added `hashConsult`/`eqConsult`, which read the ambient
`dispatch.current_env` threadlocal to dispatch a deftype's custom
`hasheq`/`equiv` on the key path. The lazy/range/instance arms simply were
never added to that ambient path — so temporising D-432 further (low
frequency, "rt-threading is broad") was the Reservation-as-bias the
2026-06-14 audit flagged as the #1 finished-form win.

## Decision

**Option A**: make the key hash/eq path rt-aware via the EXISTING ADR-0129
ambient `current_env` — no public signature change.

- `hashDispatch` (the shared rt-aware hash core, used by both the HAMT
  key sites via `hashConsult` AND the `(hash x)` primitive) realizes a
  `lazy_seq` / `range` / `chunked_cons` / cons-over-lazy `.list` /
  Sequential-instance key to a native list, then hashes it with the
  existing rt-free `seqHash`. So `(hash (map inc [0 1 2]))` ==
  `(hash [1 2 3])` == `(hash '(1 2 3))` — the formula is unchanged; only
  the input is realized first (exactly what clj's `LazySeq.hashCode` does).
- `eqConsult` compares two sequential keys element-wise: the rt-free walk
  first, then — on a lazy tail that truncates it — realize both and retry
  via `seqKeyEq`. This is ahead of a custom `equiv`, mirroring
  `valueEqual` routing `isSequential` before `instanceEquiv` (D-427).
- A Sequential deftype/reify hashes **element-wise** (ignoring any custom
  `hasheq`), matching its element-wise `=` (D-427) — so the
  `=`-implies-equal-hash invariant holds by construction for these types.
- `realizeSeqToList` (new) walks the shared `lazy_seq.seq`/`first`/`rest`
  protocol, GC-rooting the accumulator + cursor; Sequential instances
  reuse the existing `realizeSequentialInstance`.
- `seqHashChecked` / `seqKeyEqChecked` (new) return null on a lazy-tail
  truncation so the rt-aware path can detect "needs realize" without a
  separate pre-walk; the old `seqHash`/`seqKeyEq` are thin
  `orelse identity` wrappers (the unarmed residual, now unreachable in
  real evaluation).

**Alt-1 (mandatory, part of the fix)**: arm `current_env` in
`driver.runEnvelope`. The DA fork (below) found `runEnvelope` — the second
top-level-form driver, used by `cljw build` AOT artifacts + the
AOT-bootstrap restore — calls `vm.eval` directly WITHOUT arming
`current_env` (only `evalForm` + `treeWalkCall` armed it). Without Alt-1,
an AOT-compiled top-level seq-keyed literal would hash its key by identity
at run and silently miss — and the existing ADR-0129 deftype-custom-hash
key feature had the SAME latent hole. Arming `runEnvelope` (save/set/
restore, mirroring `evalForm`) closes both. e2e `aot_top_level_seq_key`
guards it.

The unarmed fallback (identity) is now reachable only before the evaluator
is up (host-init / bootstrap), where no user `assoc` keys a map by a lazy
seq — acceptable.

## Alternatives considered (Devil's-advocate fork, fresh context)

The DA fork ran within the F-NNN envelope (F-002/F-009/F-011). Verbatim
summary:

- **Alt-1 (smallest-diff, ADOPTED alongside A)** — Option A + arm
  `runEnvelope`. Better: removes the AOT-envelope silent-miss that plain A
  leaves (A *asserts* the unarmed case unreachable; this makes it true).
  Breaks: nothing; also fixes ADR-0129's identical AOT hole. The DA
  proved the unarmed case **reachable**, not unreachable, via
  `runEnvelope` (driver.zig:48 → `vm.eval`, no arming; live for
  `bootstrap.loadCoreAot` + `app/builder` `cljw build`). Verified
  independently against the source.
- **Alt-2 (finished-form-clean, DEFERRED → D-437)** — give lazy/range/
  instance values a memoized realized-hash so the seq-key path becomes
  rt-free permanently, RETIRING the dual ambient mechanism + the nested-
  key residual. Better: completeness (no armed/unarmed duality, fixes the
  nested map-as-key case uniformly). Breaks: needs a memo slot on the
  value + a new GC root for the cached list (F-006 root surface) —
  per F-003/F-004/F-006 the rooting/layout decision is the owning
  surface's call, not a bug-fix cycle's. NOTE: the DA over-stated this as
  needing a "NaN-box layout owner Phase" — re-verified, Alt-2 needs only a
  heap-struct field + one `traceLazySeq` root, NOT a NaN-box change, so
  D-437 is a standalone quality-loop item, NOT Phase-gated.
- **Alt-3 (wildcard) — REJECTED** — thread `rt` explicitly through
  `keyHash`/`get`/`contains` (the survey's Option C). Re-litigates
  ADR-0129's settled threadlocal decision for a ~68-site ripple with no
  finished-form gain over Alt-2. Cycle-budget is not the reason (F-002);
  it is dominated by Alt-2 on cleanliness.

DA recommendation: "land Option A + Alt-1 now; record Alt-2 as the
finished-form target (D-437)." The main loop adopted it.

## Consequences

- `(get/contains?)` + `(hash)` are clj-faithful for lazy/range/cons-over-
  lazy/Sequential-instance keys; the `=`-implies-equal-hash invariant
  (F-011) holds for them. Corpus `test/diff/clj_corpus/seq_key_hash.txt`
  (10 cases) + e2e `phase14_seq_key_hash.sh` (7, incl. the AOT path) lock it.
- A queue key now also content-compares in the armed path (it already
  content-HASHED via `valueHash`'s `.persistent_queue => seqHash` arm) —
  closes a pre-existing hash/eq inconsistency.
- Hot path preserved: scalar/keyword/vector keys are untouched (the
  rt-aware switch only engages for seq/instance tags); a plain list key
  takes one extra function indirection (`seqHashChecked`), same walk cost.
- Residual (→ D-437): a lazy/seq key NESTED inside a collection key
  (`{{(map inc xs) 1} :outer}`) still hashes the inner lazy element by
  identity — `valueHash`/`contentHash`/`seqHash`'s per-element recursion
  stays rt-free. Rare; the finished form (Alt-2, rt-free memoized hash)
  fixes it uniformly.

## Affected files

- `src/runtime/equal.zig` — `realizeSeqToList`, `seqHashChecked`/
  `seqKeyEqChecked`, `realizeKeyForCompare`, `isSeqKeyValue`; rewrote
  `hashDispatch` / `hashConsult` / `eqConsult`.
- `src/eval/driver.zig` — `runEnvelope` arms `current_env` (Alt-1).
- `test/e2e/phase14_seq_key_hash.sh` + `test/run_all.sh` registration.
- `test/diff/clj_corpus/seq_key_hash.txt`.
