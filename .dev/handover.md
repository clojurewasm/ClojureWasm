# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; ≈ `368c9851`). Per-commit = smoke; commit
  **and** push (CLAUDE.md § atomic Step 6). `build.zig.zon` `.zwasm` = tag pin
  `v2.0.0-alpha.3`.
- **First commit on resume MUST be**: **RE-MEASURE the cross-lang benches on a QUIET Mac**
  (`bash bench/compare_langs.sh --yaml=bench/cross-lang-latest.yaml` + regen README) — the
  cold-start arc just cut the floor **9.4→4.3ms** (ADR-0162), which should sharply improve
  every cold bench, especially **sieve** (the floor-sensitive top gap) + the cheap benches.
  The D-450 gap list is now STALE; re-rank from the fresh numbers. The cold-start arc is
  DONE: D-140 footer-seek (74970240) + **D-516 lazy-namespace bytecode (0f159228, ADR-0163)** —
  eager = clj's no-`require` set (SSOT `bootstrap.EAGER_NS`), rest lazy via region replay =
  strict clj-parity; floor 9.4→4.3ms. **OPTIONAL next levers** after the re-measure: D-517
  zero-copy in-place deserialize (now LOWER value — lazy cut the bulk; the eager set's
  deserialize is only ~0.8ms; the region blob is already D-517-ready) · D-518 heap-snapshot
  (DEFERRED to the moving-GC unit) · the residual D-450 compute gaps (gc_alloc_rate/string_ops/
  etc. — re-confirm on the quiet re-measure). **GUARDRAIL**: never Zig-ify the .clj bootstrap
  (cljw-v0 rut). Plan: `private/notes/9.2.S-coldstart-architecture-20260624.md` +
  `private/notes/D516-lazy-ns-survey.md`; decisions ADR-0162 / ADR-0163 (DA folded). D-515
  binary-size axis (standing).
- **Forbidden this session**: bare `zig build test` WITHOUT `-Dwasm` (false fails —
  `zig_build_test_needs_dwasm`); bare `zig build` for a probe (ADR-0133 — ReleaseSafe).

## Last landed (git log = SSOT)

**Cold-start floor arc DONE — floor 9.4→4.3ms (ADR-0162 + ADR-0163).** Measure-first
attribution (env-gated profiler `CLJW_PROFILE_STARTUP=1`, 24a2d635) → **D-140 footer-seek
(74970240)** → **D-516 lazy-namespace bytecode (0f159228)**. The bootstrap blob is now a
multi-region position-independent blob (one envelope per ns); loadCoreAot runs ONLY the
EAGER set (SSOT `bootstrap.EAGER_NS` = JVM Clojure's measured no-`require` set: core +
string/walk/edn/java.io/core.protocols/uuid/instant/spec.alpha + cljw.wasm), the rest
replay on first `require` via `loadOrFindNs`→`loadRegionNamespace`. STRICT clj-parity:
what clj uses require-free, cljw does too; what clj require-gates, cljw does too. Bugs
fixed: the require 4-path `mappings.count()` short-circuit unified to `loadOrFindNs`
(+ inline-ns last-resort); cljw.wasm eager (analyze-time component desugar); corpus runner
auto-requires. Blast-radius (27 e2e + cw_ported.clj) = missing-require, zero real bugs.
D-518 heap-snapshot DEFERRED to the moving-GC unit (DA: ~1ms behind a ~3.4ms exec wall at
silent-heap-corruption risk). Guardrail held: no .clj→Zig rewrite.

## Standing units (tracked in .dev/debt.yaml)

- **D-511** — 2-arg `(BigDecimal. x mc)` ctor LANDED (8db6d82f); only the
  exact-binary `(BigDecimal. double)` footgun remains (OPEN-LOW, deferred).
- **D-513** — three linked clj-parity gaps, all foundational (NOT clean drop-ins):
  (1) `clojure.core.reducers` (needs reduce→CollReduce wiring OR a cljw-native
  reducers impl; transducers supersede it, moderate-low value); (2) `clojure.repl`
  (dir/apropos implementable, but doc/find-doc/source blocked by (3)); (3) var
  `:doc` metadata absent — `(:doc (meta #'reduce))` → nil; wiring docstrings
  through every bootstrap defn/def + primitive var registration is a large,
  separate unit and the real prerequisite for a useful `clojure.repl`.
- **gap-III perf campaign** (ROADMAP §9.2.S, D-450) — the fastest-script goal
  (ADR-0148): cljw FASTEST among cljw/Python/Ruby/Node/Babashka cold-start. The
  ACTIVE front (see Resume contract for the re-measured 2026-06-24 gaps + lever
  order). Then D-386 dispatch→superinstructions→JIT.

## North star (ACTIVE)

cljw's differentiator = **Wasm/edge-native (gap II) × VM-perf fusion→JIT (gap III)**.
The embedded **zwasm** JIT engine (ADR-0200) is the cljw DEFAULT (`.auto`); the
remaining north-star step is **components-through-the-JIT** (zwasm-side, D-500).
Live ledger: `.dev/zwasm_capabilities.md`.

## Cold-start reading order (resume)

handover → **ADR-0162** (cold-start architecture decision; DA red-team in Alternatives) →
`private/notes/9.2.S-coldstart-architecture-20260624.md` (measured attribution + D-516
lazy-ns Step-0 prep + D-140 record; gitignored, on local disk) → `.dev/debt.yaml`
**D-516/D-517/D-518** (the arc's steps) + **D-450** (the 9 other gaps, re-measure quiet) →
memories `perf_campaign_roadmap_9_2_s` / `perf_beat_python_every_bench` /
`verify_actual_pattern_not_proxy` / `verify_against_releasesafe_binary` /
`smoke_first_batch_full_gate`. Profiler: `CLJW_PROFILE_STARTUP=1 cljw -e 1` (stderr phase
deltas). The campaign fast-mode is injected by `scripts/perf_campaign_remind.sh`
(`.dev/.perf_campaign_active` set).
