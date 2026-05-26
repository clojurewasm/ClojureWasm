# 0037 — Symbol heap Value impl (F-004 Group A slot 1)

- **Status**: Accepted (Devil's-advocate fork landed 2026-05-26)
- **Date**: 2026-05-26
- **Author**: Shota Kudo (drafted with Claude autonomous loop)
- **Tags**: phase-7-entry, symbol, heap-value, F-004, interner

## Context

F-004 (in `.dev/project_facts.md`) reserved Group A slot 1 for
Symbol since the NaN-box second-generation landing (Phase 5,
ADR-0027). The slot has been declared at
`src/runtime/value/heap_tag.zig:56` day-1 (`symbol = 1`); the
module doc explicitly notes "behaviour-bearing call sites raise
`Code.feature_not_supported`" for declared-but-unwired tags.

cw v1 read Symbol Forms from day 1 (`SymbolRef` at
`src/eval/form.zig:14-17`, `FormData.symbol`), but
`formToValue` at `src/eval/analyzer/analyzer.zig:631` raised
`feature_not_supported "Quoted symbol as Value"` on `.symbol`
Forms, forcing 5+ Phase 7 rows into special-form workarounds:

- Phase 6.16.b-4 sub-cycle c.4 shipped `require` as an
  **analyzer special form** rather than a runtime fn,
  explicitly because `(require 'clojure.set)` would otherwise
  fail at `formToValue` on the quoted symbol (ADR-0035 D2
  Revision history first amendment).
- Phase 6.16.c Group E shipped `macroexpand-all` as a
  throw-stub for the same reason chain (Symbol Value gap →
  reader-metadata gap → declare-only path unreachable).
- Phase 7 rows 7.3 defprotocol / 7.4 defrecord / 7.5 reify /
  7.7 extend-type / 7.8 multi-arity `fn*` would each need a
  Symbol-Value workaround if T2 did not land.

T2 (this ADR) lands the impl behind the existing reserved slot.
No F-004 amendment is needed; the slot was reserved precisely
so the impl could land at this natural cycle.

T2 also unlocks the ADR-0035 D2 second amendment (`require`
migration from special form to runtime fn) — **out of T2 scope**
but tracked as a follow-up cycle. ADR-0036's dual-backend
parity contract (T1, just landed at HEAD `df79a38`) is satisfied
trivially: T2 adds no Node variant and no opcode; `analyzeQuote`
reaches `formToValue` identically on both TreeWalk and VM
backends.

Source survey: `private/notes/phase7-T2-survey.md` (~808 lines,
HEAD `df79a38`).

## Decision

### D1 — Pointer-eq interning mirroring Keyword

Symbol Values are interned by `(ns, name)` tuple in a registry
on `Runtime`. Two `'foo` literals from any source path produce
the same `*Symbol` pointer; equality via the existing
NaN-box-payload `u64` compare reduces to pointer-eq. This
matches Keyword's discipline (`src/runtime/keyword.zig`) and
gives every downstream caller (`identical?`, hash-map / set
key, multimethod dispatch cache, protocol satisfy cache) a
canonical-pointer fast path.

### D2 — New file `src/runtime/symbol.zig` parallel to keyword.zig

`Symbol` extern struct: `HeapHeader` + 6-byte pad + `ns:
?[]const u8` + `name: []const u8` + `hash_cache: u32`.
`SymbolInterner`: gpa-allocator + `std.array_hash_map.String(*Symbol)`
+ `std.Io.Mutex` (pre-wired for Phase 15 concurrency). Top-level
`intern(rt, ns, name)` + `find(rt, ns, name)` + `asSymbol(val)`
matching keyword's surface. No GC finaliser registration:
interner-owned + gpa-allocated; the `null` slot at
`tag_finaliser_table[symbol]` stays null (correct per keyword
precedent).

Layer 0 (`src/runtime/`) placement per F-009 (impl neutrality).
A future `runtime/java/lang/Symbol.zig` surface or any Wasm
host-side symbol carrier would re-use the same `runtime/symbol.zig`
impl.

### D3 — Runtime.symbols: SymbolInterner field

Parallel to `Runtime.keywords: KeywordInterner`. Init/deinit
sibling. No NaN-box tag amendment (slot was day-1 reserved).

### D4 — formToValue intern + printValue branch + nameFn extension

- `analyzer.zig:631` `.symbol` arm: replace the raise with
  `try symbol.intern(rt, sym.ns, sym.name)`.
- `print.zig` `printValue`: new `.symbol` arm between `.keyword`
  and `.string`, rendering `(ns/)?name` with NO leading colon
  (mirrors `form.zig:99-104` Form-side `pr-str`).
- `core.zig::nameFn`: add `.symbol` arm parallel to `.keyword`
  returning `(name 'ns/x)` → `"x"`. Drop the "blocked on
  F-004 symbol Value" docstring notes.

### D5 — clojure.core/symbol constructor + symbol? predicate

- `core.zig::symbolFn` (new): 1-arg
  (string / keyword / symbol idempotent) + 2-arg
  (string ns + string name). Mirror `keywordFn` shape exactly.
  Register in `ENTRIES` table.
- `core.zig::symbolQ` (existing): already tag-dispatches
  (`args[0].tag() == .symbol`), so no code change needed — it
  silently returned `.false_val` for every Value before T2;
  after T2 lights up automatically for interned symbols.

### D6 — Defer per-Value metadata to D-075

Per-Value metadata (`^:dynamic`, `^:private`, user `with-meta`)
is **NOT** added to Symbol in T2. The cw v1 envelope frames
metadata as a cross-cutting concern via D-075 (Phase 7+
metadata layer that lands meta on Symbol + Keyword + Var +
IObj-protocol Values uniformly), explicitly avoiding cw v0's
per-feature meta field which made the eventual migration
painful (`~/Documents/MyProducts/ClojureWasm/src/runtime/value.zig:295`
carried `meta: ?*const Value` on Symbol day 1).

Within the current F-NNN envelope (metadata-less Symbol +
metadata-less Keyword), pointer-eq IS the finished form —
every interned Symbol is the canonical wrapper, no per-Value
metadata exists, so `=` and `identical?` agree by construction.
**No PROVISIONAL marker** required because Symbol Value runs
in its **finished form** today (the PROVISIONAL marker
discipline is for intermediate semantics; D6 is a deliberate
deferral of an orthogonal future concern, not intermediate
semantics).

When D-075 lands, both Keyword and Symbol grow a
`meta_ptr: ?*Map` field in lockstep, plus the NaN-box decode
acquires a meta-flag bit (allocation TBD by D-075 itself). T2
deliberately does **not** prepare for this — adding a day-1
`meta_ptr: ?*Value = null` field is the Reservation-as-bias
smell (committing to D-075's eventual shape before D-075's own
Devil's-advocate has framed the decision; see Alt 2 refinement
rejection in Devil's-advocate output below).

## Alternatives considered

The Devil's-advocate fork (fresh context, briefed against
F-NNN envelope from `.dev/project_facts.md`) produced 3
alternatives. Embedded verbatim:

### Alt 1 — Smallest-diff: non-interned Symbol Value

Allocate a fresh heap `Symbol` on every `formToValue(.symbol)`; `(= 'foo 'foo)` falls through to string-compare on `(ns, name)`; no `SymbolInterner`, no mutex, no `Runtime.symbols` field.

- **Better than proposal**: ~80 LOC saving (no interner table + lock). Zero process-lifetime memory growth from repeated quote evaluation that the GC cannot reclaim (interner-owned Values pin until `Runtime.deinit`).
- **Breaks**:
  - Pointer-eq is the load-bearing semantic everywhere downstream — `identical?`, hash-map / hash-set key comparison fast path, multimethod dispatch key cache, protocol satisfy cache. Each of these grows an `if (tag == .symbol) strcmp...` branch on the hot path. That is the **Cascade smell** + **Smallest-diff bias smell** in one move per principle.md.
  - Diverges from Keyword's pointer-eq shape (`runtime/keyword.zig:101`), forcing every collection helper that today handles "interned identity Values uniformly" to split into a "keyword / symbol" two-case shape. F-002 finished-form lost.
  - The "~80 LOC saving" is illusory: the interner code is verbatim mirror of keyword.zig, so the marginal author cost is ~10 minutes; the cross-cutting strcmp drift never goes away.

**Reject** per F-002 (smallest-diff bias against a different finished form).

### Alt 2 — Finished-form-clean (canonical pick, with two refinements)

Pointer-eq interning mirror of Keyword exactly as the survey §3-§7 proposes. The refinements the brief asks about:

- **Day-1 `meta_ptr: ?*Value = null` field on Symbol?** **Reject**. This is the Reservation-as-bias smell (committing to D-075's eventual shape before D-075's own Devil's-advocate fork has happened). Adding `meta_ptr` now forces (a) Keyword struct lockstep widening, (b) a meta-flag bit allocation in NaN-box encoding that D-075 has not yet framed, (c) equality semantic migration to per-Value before the metadata layer exists to justify it. Per survey §7.2 + §10 the deferral IS the finished form within the current envelope.
- **Share keyword's hash function?** Yes — use `hash.hashString` exactly as `keyword.zig:151-159` does. Diverging the hash function for symbol vs keyword has no measurable upside and breaks the "interned identity Value" symmetry.
- **Re-entrant-safe lock?** Stay with `lockUncancelable(rt.io)` per keyword precedent. Phase 15 concurrency rollout converts this uniformly; symbol diverging from keyword would be Framework-incomplete.
- **`.symbol` arm ordering in `printValue`?** Place between `.keyword` and `.string` per survey §5.1 — matches the heap_tag.zig declared order (string=0, symbol=1, keyword=2) which Zig's switch jump-table generation already optimises for. No re-ordering justification.

The proposal-as-written matches finished form. The one mandatory addition beyond the brief: **open D-075 in the same commit** (or verify it exists; survey §10 + §12 step 10 already call this out). Without the row, the metadata deferral is the Defer-to-amnesia smell.

### Alt 3 — Wildcard: defer Symbol Value past Phase 7 entry

Push T2 to Phase 8 (transients), Phase 11 (self-hosting), or fold into D-075 (metadata layer, Phase 7+).

- **Better than proposal**: ~1 cycle saved now; lets Phase 7 entry resume directly to row 7.2 (multimethod).
- **Breaks**:
  - Forces 5 Phase 7 rows (7.3 defprotocol / 7.4 defrecord / 7.5 reify / 7.7 extend-type / 7.8 multi-arity fn*) plus the `require` runtime-fn migration into ADR-0035-D2-shaped analyzer-special-form workarounds. Each workaround needs its own ADR Revision history entry + its own un-do cycle when Symbol Value eventually lands. Cumulative cost is **substantially higher** than T2's ~150 LOC.
  - F-004 reserved Group A slot 1 specifically so Symbol Value could land at the natural cycle (per F-004 declaration + heap_tag.zig:56 day-1 reservation). Deferring is not an F-004 violation per se (the slot stays declared, behaviour-bearing call sites raise `feature_not_supported` per the heap_tag.zig L17-18 contract), but it IS the Reservation-as-bias smell inverted — treating "we can defer because the slot will still be there" as a license to defer indefinitely.
  - Folding into D-075 conflates two independent concerns: Symbol Value identity (a NaN-box / interner concern, scoped) and per-Value metadata (a cross-cutting equality-contract concern, large). D-075 becomes monolithic and harder to Devil's-advocate cleanly.

**Reject** per F-002 (Progress-pressure smell: "let me skip T2 to move faster" produces 5x downstream catch-up cost) + cumulative-workaround analysis in survey §6.

### Devil's-advocate recommendation

**Alt 2 as proposed in the survey, with the explicit decision to defer per-Value metadata to D-075 (do NOT add `meta_ptr` to Symbol on day 1) and to open the D-075 debt row in the same commit if it does not already exist.**

Rationale: F-002 picks Alt 2 over Alt 1 (smallest-diff bias against a different finished form) and over Alt 3 (Progress-pressure + Reservation-as-bias inverse). F-004's slot reservation is honored by implementing into the existing slot, not by inventing a new one (no Reservation-as-bias trigger). F-009 neutrality is preserved by landing impl in `src/runtime/symbol.zig` with `clojure.core/symbol` as a thin wrapper in `src/lang/primitive/core.zig`. ADR-0036 dual-backend parity contract is satisfied trivially (no Node variant, no opcode added; `analyzeQuote` reaches `formToValue` identically on both backends — survey §11.5).

## Selection rationale

Selected: Alt 2 as-is (verbatim Devil's-advocate recommendation).

- F-002: pointer-eq + interner + hash_cache + mutex pre-wired
  = finished form within the metadata-less envelope. Alt 1's
  cross-cutting strcmp drift breaks finished form; Alt 3's
  deferral compounds workaround cost.
- F-004: slot 1 already declared; T2 lands the impl behind
  the existing reservation (= honors the reservation, not
  biased by it).
- F-009: `runtime/symbol.zig` neutral; `clojure.core/symbol`
  wrapper lives in `lang/primitive/core.zig`. No cross-surface
  import.
- F-007: no chapter cadence touch.
- D-075 verified present in `.dev/debt.md` at HEAD `df79a38`
  (row name "Phase 7+ (value metadata system)") — the
  metadata deferral has its tracked debt row.

The "day-1 `meta_ptr` field" Alt 2 refinement is explicitly
rejected per D6 (Reservation-as-bias smell — committing to
D-075's shape pre-empts its own Devil's-advocate).

## Consequences

### Positive

- 5 Phase 7 rows (7.3 / 7.4 / 7.5 / 7.7 / 7.8) gain a working
  prerequisite — symbol parsing in defprotocol / defrecord /
  extend-type lands without ADR-0035-D2-shaped workarounds.
- ADR-0035 D2 second amendment (`require` runtime fn
  migration) becomes possible (out of T2 scope; tracked as
  follow-up).
- `(quote sym)` evaluates; `(= 'foo 'foo)` returns `true`
  via pointer-eq; `(name 'ns/x)` returns `"x"`;
  `(symbol "foo")` round-trips; `(symbol? 'foo)` returns
  `true` (auto-lit via tag-dispatch).
- `macroexpand-all` Pattern A path becomes possible alongside
  T3.
- `gensym` user-facing runtime fn becomes possible (returns
  a fresh Symbol Value rather than an arena `[]const u8`).
- `runtime/symbol.zig` becomes the neutral home a future
  `runtime/java/lang/Symbol.zig` host-surface or zwasm
  symbol carrier would re-use (F-009).

### Negative

- ~150 LOC new code (`runtime/symbol.zig` mirror + wiring +
  tests + ADR + ~100 LOC e2e+diff). Smell-audit depth 2 (new
  ADR + new file + multi-file wiring).
- Interner-owned Symbol Values pin until `Runtime.deinit`
  (process-lifetime). Acceptable per keyword precedent;
  identity-bearing Values are not GC candidates.
- ADR-0035 D2 first amendment's `require`-as-special-form
  remains active until the follow-up cycle migrates it.

### Neutral / follow-ups

- **Follow-up cycle A** (post-T3): `require` migration from
  analyzer special form to runtime fn per ADR-0035 D2 second
  amendment (now possible).
- **D-075 (Phase 7+)**: metadata layer lands `meta_ptr` on
  Symbol + Keyword + Var + IObj Values uniformly. Symbol
  struct widens in lockstep.
- **`(namespace 'ns/x)` primitive**: not in T2 scope; added
  in a separate minor cycle when the broader Symbol /
  Keyword surface lands.
- **Quoted vector / map / set Value lifting**: the other 3
  `formToValue` raise sites (D-080 clojure.zip block) — not
  blocking Phase 7 rows, separate concern.

## Affected files

- `.dev/decisions/0037_symbol_heap_value.md` — this ADR (new).
- `src/runtime/symbol.zig` — new file (~150 LOC; verbatim
  mirror of keyword.zig).
- `src/runtime/runtime.zig` — add `symbols: SymbolInterner`
  field + init/deinit sibling to `keywords`.
- `src/runtime/print.zig` — add `.symbol` arm in `printValue`
  (between `.keyword` and `.string` arms).
- `src/eval/analyzer/analyzer.zig` — replace `.symbol` raise
  arm in `formToValue` with `try symbol.intern(rt, sym.ns,
  sym.name)`.
- `src/lang/primitive/core.zig` — add `symbolFn` (1-arg +
  2-arg); extend `nameFn` with `.symbol` arm; register
  `symbol` in `ENTRIES`; drop "blocked on F-004 symbol Value"
  docstring notes.
- `src/main.zig` — add `_ = @import("runtime/symbol.zig");`
  to the `test {}` aggregator (per `zig_tips.md` test
  discovery trap).
- `test/e2e/phase7_symbol_value.sh` — new (smoke for
  `(quote sym)` / `(symbol "foo")` / `(= 'foo 'foo)` /
  `(name 'ns/x)` / `(symbol? 'foo)`).
- `src/lang/diff_test.zig` — new differential case
  exercising `(quote sym)` round-trip (ADR-0036 active
  exercise of parity contract; tree_walk + VM agree because
  both reach `formToValue` via `analyzeQuote`).

## References

- F-004 (`.dev/project_facts.md`) — Group A slot 1 = symbol.
- ADR-0027 — NaN-box second generation (declared the slot).
- ADR-0035 D2 first amendment — shipped `require` as special
  form because Symbol Value was missing. T2 unblocks the
  second amendment.
- ADR-0036 — dual-backend parity contract (T1, just landed).
  T2 satisfies trivially (no Node variant, no opcode).
- `.claude/rules/provisional_marker.md` — Skeleton vs
  PROVISIONAL discipline; T2's pointer-eq is **finished
  form** within current envelope, not PROVISIONAL.
- `.dev/debt.md` D-075 — Phase 7+ metadata layer (the
  deferred concern D6 names).
- `private/notes/phase7-T2-survey.md` — Step 0 survey (~808
  lines).
- `.dev/phase7_entry_prereq_triad.md` §T2 — operational
  driver for this cycle.
- `src/runtime/keyword.zig` — verbatim template (303 lines).

## Revision history

- 2026-05-26: Status: Proposed → Accepted (initial landing).
  Devil's-advocate fork (depth-2 mandatory) executed against
  F-NNN envelope (F-002 + F-004 + F-007 + F-009 + D-075
  deferral); Alt 2 selected as-is (refinement to add
  `meta_ptr` rejected per D6 Reservation-as-bias). T2 cycle
  lands this ADR alone in the doc-first commit (depth-2
  discipline); the source landing (`runtime/symbol.zig` +
  wiring + tests) follows in the next commit per CLAUDE.md
  Step 6.
