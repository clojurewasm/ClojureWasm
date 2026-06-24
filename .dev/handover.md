# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT). Per-commit = smoke; commit **and** push
  (CLAUDE.md § atomic Step 6 — the perf-campaign no-push mode is LIFTED; push normally).
  `build.zig.zon` `.zwasm` = tag pin `v2.0.0-alpha.3`.
- **First commit on resume MUST be**: open **D-530** as a fresh focused unit (the
  top remaining code-tractable clj-parity gap; the contained correctness floor +
  the D-523 doc pass + the accessible D-528 library hunt are all drained). Its
  implementation SCOPE is already mapped (multi-point, NOT one-line): `expandDeftype`
  → `lowerDefType` + `wrapMethodBodyWithFields` BOTH assume a single-arity method
  (`impl[1]==.vector`), so overloaded same-name methods need merging into one
  multi-arity `fn*` at lowering + the runtime dispatch (`lookupMethod` name-only)
  invoking it — high blast radius (every deftype/reify), so **DA fork + full
  dual_backend_parity e2e set are mandatory**. Step 0 survey clj/v1 first. Lower
  fallbacks: **D-533** (ref/var validators + ref ctor option — moderate STM/Var-GC),
  **D-531** (partitions-M UAF — GC-poison instrument first), **D-532** (BigInteger
  construction DONE; only a fuzzy float round-trip + speculative arith remain), then
  pure-polish **D-522** (de-pointer — few BARE pointers; most refs anchor explanatory
  prose, keep those) · **D-524/525** (`.claude/`-blocked, surface to user) · **D-529**
  marker inventory. A correctness/clj-parity floor outranks pure polish.
- **Forbidden this session**: bare `zig build test` WITHOUT `-Dwasm` (false fails);
  bare `zig build` for a probe (ADR-0133 — use ReleaseSafe). Note: `.claude/**` edits
  (D-524/525) may hit the auto-mode self-modification block — surface those to the user.

## Last landed (git log = SSOT)

§9.2.T public-ization session. **Interop**: java.lang scalar statics (D-526) +
java.util.Objects + **java.util.UUID 2-long ctor** + **java.math.BigInteger surface**
(`<init>` String/byte[] + valueOf + `.toBigInteger`) + **BigDecimal(BigInteger,scale)
ctor** — all corpus-backed. **8 real bug fixes** (deftype-as-map `=` symmetry via
MapEquivalence, map?/sorted?/set? deftype recognition, a core lazy-`=` GC-rooting bug,
+ the UUID/BigInteger/BigDecimal interop chain). **D-528 library drain**: 6 real libs
exercised (priority-map/math.combinatorics/data.generators → fixes; core.unify/data.zip/
data.codec → clean) — the accessible self-contained-lib hunt is now exhausted (8
attempts; tools.reader/algo.monads/test.check load-blocked on JVM features/transitive
deps). **D-523 doc audit COMPLETE**: all 7 user-facing docs/ audited, 6 had real stale
claims (concurrency-tail/binary-size/:kind-counts/deps.edn-method/cadence-resume). Deep
work recorded with diagnostics: **D-530** (scope mapped), **D-531** (tooling-blocked),
**D-532**/**D-533** (new). All gates green.

## Standing units (tracked in .dev/debt.yaml)

- **Perf campaign (§9.2.S) — PAUSED.** Cheap levers exhausted (O-051 last clean
  one). Remaining in standing debt for a future deliberate decision: **D-520**
  collection-perf (L4 small-map = a GC-arch variable-length-object change, poor ROI
  for 1.05–1.16×) · **D-386** VM dispatch ((a) inline-stepOnce risky/UAF + D-244 #4
  prereq; (b) DEAD; (c) JIT user-fenced ADR-0151) · **D-005/006** broad JIT (future).
  `.dev/.perf_campaign_active` REMOVED (re-`touch` to re-open).
- **D-513** — three linked clj-parity gaps (clojure.core.reducers / clojure.repl /
  var `:doc` metadata) — foundational, not clean drop-ins; a D-527 sweep may reach them.
- **D-511** — only the exact-binary `(BigDecimal. double)` footgun remains (OPEN-LOW).

## North star (ACTIVE, distal)

cljw's differentiator = **Wasm/edge-native (gap II) × VM-perf fusion→JIT (gap III)**.
The embedded **zwasm** JIT engine (ADR-0200) is the cljw DEFAULT (`.auto`); the
remaining step is **components-through-the-JIT** (zwasm-side, D-500). Distal — needs
a user nod; the public-ization sweep (§9.2.T) is the active near-term mode.

## Reading order (resume)

handover → **ADR-0166** (public-ization polish-sweep mode — the active direction) →
the **D-522…D-529** rows in `.dev/debt.yaml` (the drain menu) → **ROADMAP §9.2.T**.
Background: **ADR-0165** + Amendment 1 (perf levers exhausted) → **D-520** (paused
perf). Bench: `bash bench/compare_langs.sh --skip-build --yaml=bench/cross-lang-latest.yaml`
then `yq -o=json … | python3 bench/gen_cross_table.py` → splice into `bench/README.md`.
Memories: `verify_against_releasesafe_binary` / `smoke_first_batch_full_gate`.

## Stopped — user requested

User instruction (2026-06-24, paraphrase): after this perf milestone, the standing
`/continue` mode is the **(b) sweep** — the finite quality work previously deferred
as low-ROI: java-interop missing statics (catalog first if not mechanically
knowable), "あと少し欠落" near-complete gaps, clj-parity alignment with upstream,
real-`deps.edn` library usage to surface bugs, doc audit against code-truth
(prune/simplify/archive), abolish the per-session `private/notes` dependence
(public artifact — anyone develops in their own env), skill/rules review, replace
ADR/debt **pointer** comments with self-contained explanation (ADR docs stay) +
condense verbose comments (huge, gradual), marker-comment inventory. The user asked
to lightly pre-investigate, record perf, push, then **wire + audit the reference
chain so a clear session's `/continue` fires these going forward**, and stop. Done:
**ADR-0166** + **§9.2.T** + **D-522…D-529** + this resume contract wire it; the perf
campaign is paused. Resume = self-select a §9.2.T category and drain it.
