# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; ≈ `368c9851`). Per-commit = smoke; commit
  **and** push (CLAUDE.md § atomic Step 6). `build.zig.zon` `.zwasm` = tag pin
  `v2.0.0-alpha.3`.
- **First commit on resume MUST be**: **§9.2.S collection-perf L2 — chunked lazy-seq WALK path
  (sieve)** (**ADR-0165 Amendment 1** / **D-520**). L3 keyword-map-get LANDED as **O-051** (see
  Last landed). The 2026-06-24 implementation Step 0.6 re-laying CORRECTED ADR-0165's premises
  (Amendment 1): transients are NOT a stub (flat-buffer impl works; `into`/`vec` already use it),
  no losing bench is gated on transient build, so **L1 is demoted from "first"** — the lever order
  is now MEASURED-loss-led. Corrected peer standing (ReleaseSafe, hyperfine, load ~3): cljw LOSES
  gc_large_heap 1.19× / destructure 1.18× / sieve 1.14× / gc_alloc_rate 1.06×; **WINS nested_update
  1.39×** (was listed as a loss — stale) + bigint tie + pure-compute 2×. Remaining lever order:
  **L2 chunked-seq WALK (sieve)** → L4 right-size small-collection alloc (gc_alloc_rate/gc_large_heap
  TailNode `[32]Value` / ArrayMap `[16]Value` over-alloc) → L1 transients (only for `(into big few)`;
  not bench-moving) → L5/L6. Per lever: branch `develop/collection-<lever>`, experiment-and-revert /
  commit-no-push, **FULL diff oracle (global change, NOT smoke)** + clean old-vs-new-binary A/B
  (load-robust) ± interleaved cljw-vs-bb. **GUARDRAIL**: never Zig-ify the .clj bootstrap.
  D-517/D-518 DEFERRED; D-515 binary-size (standing).
- **Forbidden this session**: bare `zig build test` WITHOUT `-Dwasm` (false fails —
  `zig_build_test_needs_dwasm`); bare `zig build` for a probe (ADR-0133 — ReleaseSafe).

## Last landed (git log = SSOT)

**L3 keyword-map-get fast path LANDED as O-051 (ADR-0165 Amendment 1).** `array_map`
`get`/`contains` compare keyword keys by raw NaN-box payload bits (keywords are interned ⟹
`=` is bit-identity) via the new `arrayMapKeywordSlot` helper, skipping the per-entry
`keyEq`→`eqConsult`→`keyEqValue` error-union chain; non-keyword keys keep the general path;
the `>8`-entry hash_map path is unchanged. Clean old-vs-new ReleaseSafe binary A/B (hyperfine
-N, 30 runs): destructure −6.6%, gc_large_heap −4.5%, 300k-get −11.0%, map-destructure −6.3%.
diff oracle (`zig build test -Dwasm` ×2) green + new map.zig unit test (keyword hit/miss +
mixed keyword/int/string keys) + lint clean. Amendment 1 also corrected ADR-0165's two false
premises (transients-are-a-stub; L1-first) and the stale peer standing. Prior: D-519 eval
auto-collect (ADR-0164, memory bounded + faster) + the cold-start arc (ADR-0162/0163).

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
- **gap-III perf campaign** (ROADMAP §9.2.S) — fastest-script goal (ADR-0148). ACTIVE
  sub-strategy = **collection-perf (ADR-0165 / D-520)**: keep best-of-breed algorithms,
  win on Zig-native layout, transients-first (see Resume contract). Startup axis is won
  (cold-start arc); the SEPARATE compute frontier beyond bb = D-386 JIT.

## North star (ACTIVE)

cljw's differentiator = **Wasm/edge-native (gap II) × VM-perf fusion→JIT (gap III)**.
The embedded **zwasm** JIT engine (ADR-0200) is the cljw DEFAULT (`.auto`); the
remaining north-star step is **components-through-the-JIT** (zwasm-side, D-500).
Live ledger: `.dev/zwasm_capabilities.md`.

## Reading order (resume)

handover → **ADR-0165** (collection-perf strategy + ROI levers + experiment/regression protocol;
the NEXT direction) → **D-520** (the draining campaign row) → `private/notes/`
**collection-perf-proposal-20260624.md** (3-survey synthesis) + **9.2.S-clean-peer-rerank-20260624.md**
(measured standing) + **cljw_collection_codetruth.md** (where cljw is naive). Background:
**ADR-0148** (fastest-script campaign) → **ADR-0164** (D-519 auto-collect, LANDED). Tools:
`CLJW_GC_STATS=1` (alloc/reuse%/collects) / `CLJW_GC_THRESHOLD_MB` (auto-collect floor knob,
also the OFF-vs-ON A/B lever) / `CLJW_PROFILE_STARTUP=1`. Measurement discipline: ms-margin
peer benches need a QUIET Mac (load <~2); the load-robust signal is the interleaved OFF-vs-ON
knob A/B. Memories: `verify_against_releasesafe_binary` / `smoke_first_batch_full_gate` /
`perf_campaign_roadmap_9_2_s`. Campaign fast-mode injected by `scripts/perf_campaign_remind.sh`.
