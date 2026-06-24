# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; ≈ `368c9851`). Per-commit = smoke; commit
  **and** push (CLAUDE.md § atomic Step 6). `build.zig.zon` `.zwasm` = tag pin
  `v2.0.0-alpha.3`.
- **First commit on resume MUST be**: **confirm the clean peer re-rank at load <2** + measure
  the 2 un-measured py-benches (json_parse, nested_update vs py) to complete it. CORRECTION
  THIS SESSION (note `9.2.S-clean-peer-rerank-20260624.md`): the handover's old "7/9 won,
  fastest-script ~27/30" was a **load-~9 artifact**. A load-robust **interleaved cljw-vs-bb
  A/B** (load 3, tight σ both) + the load-4 compare_langs BOTH show cljw **LOSING** all 6 bb-
  benches (gc_alloc_rate/gc_large_heap/destructure/string_ops/bigint_factorial/sieve) by
  1.02–1.16×. **The gap is REAL + load-independent**: cljw's User (CPU) time is **1.6–2.7×
  bb's** — bb (GraalVM AOT-native) out-COMPUTES cljw's bytecode interpreter; the cold-start arc
  maxed the STARTUP axis but not COMPUTE. EXCEPTION: **ratio_sum WON** (cljw 23.5 vs bb 33.4 =
  1.42× ahead; D-519+O-050+cold-start closed the old 3.15×). **Implication**: per-bench micro-
  tuning will NOT close a 1.6–2.7× interpreter-vs-AOT gap — the real lever is **COMPUTE =
  D-386 dispatch→superinstructions→JIT** (north-star = embedded zwasm JIT, ADR-0200). Confirm
  marginals (string_ops 1.03×, bigint_factorial 1.02×) at load <2 — they may flip; the
  compute-bound ones are real bb wins. **GUARDRAIL**: never Zig-ify the .clj bootstrap.
  D-517/D-518 DEFERRED; D-515 binary-size (standing).
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

## Stopped — user requested

User instruction (2026-06-24): 「よし、最適化キャンペーン全体について、きりの良いところで
停止して」(stop the whole optimization campaign at a clean point). Honored the designed
campaign-pause switch: **`.dev/.perf_campaign_active` removed** (gitignored), so the campaign
fast-mode injection is now silent — re-`touch` it to re-open §9.2.S. Clean state: tree clean,
HEAD pushed (`755a64c1`), smoke green (stamp `6e34be03`). This session: D-519 eval auto-collect
LANDED + GO-passed (1.1–1.65× faster, memory bug fixed) + the clean peer re-rank CORRECTION
(cljw LOSES the bb-benches on a real compute gap; ratio_sum the one win; lever = JIT, not
per-bench). If resumed: the campaign is PAUSED — do not auto-resume per-bench tuning; the
First-commit-on-resume above (confirm re-rank at load <2 + the JIT framing) applies only when
the user re-opens the campaign. Extended-challenge 3-items: `private/notes/
9.2.S-clean-peer-rerank-20260624.md`.
