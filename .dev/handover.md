# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; ≈ `368c9851`). Per-commit = smoke; commit
  **and** push (CLAUDE.md § atomic Step 6). `build.zig.zon` `.zwasm` = tag pin
  `v2.0.0-alpha.3`.
- **First commit on resume MUST be**: the **quiet-Mac absolute peer re-rank** (deferred from
  D-519's GO) — `bash bench/compare_langs.sh --skip-build --lang=cw,py,rb,js,bb --yaml=…` at
  load <~2 + regen README, to settle the campaign's true standing on the ADR-0148 9. A
  load-~4 cross-run peer measure this session was contamination-noisy (cljw appeared to lose
  benches it "won" at load ~9; bb swung uniformly) — the absolute "cljw vs bb" standing is
  UNCERTAIN until measured quiet. **THEN attack the next gap = `ratio_sum`** (ADR-0148: 3.15×,
  numeric-tower per-op BigInt+GCD alloc; compute-bound, untouched by the cold-start arc/GC —
  fused rational accumulator, mine JVM `clojure.lang.Ratio`/`BigInteger`). **GUARDRAIL**:
  never Zig-ify the .clj bootstrap. D-517 zero-copy = LOW value; D-518 heap-snapshot DEFERRED
  (moving-GC unit). D-515 binary-size axis (standing).
- **Forbidden this session**: bare `zig build test` WITHOUT `-Dwasm` (false fails —
  `zig_build_test_needs_dwasm`); bare `zig build` for a probe (ADR-0133 — ReleaseSafe).

## Last landed (git log = SSOT)

**D-519 eval auto-collect LANDED + GO-PASSED (ADR-0164).** Shared `GcHeap.maybeAutoCollect()`
(the torture-alloc collect verbatim, gated `bytes_since_last_gc>threshold_bytes`) at BOTH the
`alloc` boundary + the VM back-edge poll; default floor 1MB→4MB via new per-heap
`threshold_floor_bytes` + `CLJW_GC_THRESHOLD_MB` knob; torture kept in the gate. Root cause
(no eval auto-collect → unbounded malloc + latent OS-OOM) fixed decisively: `CLJW_GC_STATS`
mallocs 401K→27335 (4M-vector run FLAT at 27335 = memory bounded). The load-robust OFF-vs-ON
A/B refuted the DA's canary-regression fear — ON is FASTER on all 8 benches (gc_alloc_rate
1.39×, string_ops 1.28×, …) + ~10× lower variance (collect+reuse wins cache/page-fault
locality). Correctness: diff oracle green; 15/305 mid-eval collects yet sums exact. Prior arc
(cold-start floor 9.4→4.3ms, ADR-0162/0163) still holds. Guardrail held: no .clj→Zig rewrite.

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

## Reading order (resume)

handover → **ADR-0148** (the fastest-script 9-bench campaign + gaps) → **ADR-0164** (eval
auto-collect = D-519, LANDED + GO result table) → `.dev/debt.yaml` **D-450** (the 9 gaps;
the absolute peer standing needs a quiet-Mac re-measure) + **D-519** (discharged). Prior arc:
ADR-0162/0163 + `private/notes/9.2.S-coldstart-architecture-20260624.md`. Tools:
`CLJW_GC_STATS=1` (alloc/reuse%/collects) / `CLJW_GC_THRESHOLD_MB` (auto-collect floor knob,
also the OFF-vs-ON A/B lever) / `CLJW_PROFILE_STARTUP=1`. Measurement discipline: ms-margin
peer benches need a QUIET Mac (load <~2); the load-robust signal is the interleaved OFF-vs-ON
knob A/B. Memories: `verify_against_releasesafe_binary` / `smoke_first_batch_full_gate` /
`perf_campaign_roadmap_9_2_s`. Campaign fast-mode injected by `scripts/perf_campaign_remind.sh`.
