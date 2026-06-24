# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; ≈ `888d7573`). Per-commit = smoke; commit
  **and** push (CLAUDE.md § atomic Step 6). `build.zig.zon` `.zwasm` = tag pin
  `v2.0.0-alpha.3`.
- **First commit on resume MUST be**: resume the **gap-III perf campaign (D-450)
  — fastest-script goal** (ADR-0148: cljw FASTEST among cljw/Python/Ruby/Node/
  Babashka cold-start on the 9 top-gap benches). The active quick-wins are drained
  (D-510 ✓, D-511 2-arg ctor ✓; D-511 double-ctor + D-513 are deferred/foundational
  — see Standing units). **MEASURE-FIRST** (`bash bench/compare_langs.sh --cold`,
  ≥10 runs) to refresh the cljw÷fastest-script ratios, THEN take the highest-ROI
  lever. D-450 ROI order (2026-06-16): ratio_sum 3.15× (numeric-tower fused
  accumulators) · gc_alloc_rate 2.81× / gc_large_heap 2.22× (GC-arch theme —
  generational/nursery, F-006, OWN ADR+DA fork when designed) · destructure 1.72× ·
  json_parse 1.59× · bigint_factorial 1.49× · nested_update 1.37× · string_ops
  1.35× · sieve 1.23×. **ratio_sum is the contained highest-ROI start; the GC-arch
  pair is the bigger design unit.** Per perf_v0_baseline.md the campaign's highest-
  risk lever (exact-count frame rooting, the O-005 redo) needs a FOCUSED cycle, not
  a rushed one — verify under CLJW_GC_TORTURE. D-180 (into/vec vector.fromSlice) is
  DONE; do not re-open it.
- **Forbidden this session**: bare `zig build test` WITHOUT `-Dwasm` (false fails —
  `zig_build_test_needs_dwasm`); bare `zig build` for a probe (ADR-0133 — ReleaseSafe).

## Last landed (git log = SSOT)

**D-510 — general host-enum mechanism, ADR-0161, 2 cycles, smoke 5/5 green.** Unified
all four JVM host enums (RoundingMode/ChronoUnit/DayOfWeek/Month) onto ONE comptime
registry `runtime/host_enum.zig` + ONE flat `rt.host_enum_consts[43]` cache with a
single interning entry point (DA-fork Alt-3). Cycle 1 migrated Group A
(RoundingMode/ChronoUnit) behaviour-preserving + folded/deleted
rounding_mode.zig/chrono_unit.zig. Cycle 2 folded Group B (DayOfWeek/Month) from
`.typed_instance` getter-mint to `.host_instance` singletons (new surfaces
DayOfWeek.zig/Month.zig), removed the typed_instance equal/compare/print arms +
day_of_week_value.zig/month_value.zig. **Parity wins**: `DayOfWeek/MONDAY`..`Month/
DECEMBER` static fields now resolve; `(identical? (.getDayOfWeek monday)
DayOfWeek/MONDAY)` => true; all four enums JVM-Comparable (sign-based, AD-043
extended). `TypeDescriptor.host_enum_idx` drives unified pr-print + compare-by-ordinal.
MathContext stays a consumer (not a member). compat_tiers 4 entries → keyword
host_enum (G3 green).

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
- **gap-III perf campaign** (ROADMAP §9.2.S, D-180/D-450) — the fastest-script goal
  (ADR-0148): cljw FASTEST among cljw/Python/Ruby/Node/Babashka cold-start on the
  top-gap benches. Resume at D-180 (bulk `persistent!`/`vector.fromSlice`, the
  into/vec 121s bottleneck). Measure-first (`bench/compare_langs.sh`). The
  high-value standing directive once the active quick-wins drain.

## North star (ACTIVE)

cljw's differentiator = **Wasm/edge-native (gap II) × VM-perf fusion→JIT (gap III)**.
The embedded **zwasm** JIT engine (ADR-0200) is the cljw DEFAULT (`.auto`); the
remaining north-star step is **components-through-the-JIT** (zwasm-side, D-500).
Live ledger: `.dev/zwasm_capabilities.md`.

## Cold-start reading order (resume)

handover → `.dev/debt.yaml` D-511 (next unit) + D-513 (foundational) → memory
`clj_diff_sweep_methodology` + `.claude/rules/clj_diff_sweep.md` → for the perf
pivot: `.dev/perf_v0_baseline.md` + memories `perf_campaign_roadmap_9_2_s` /
`perf_beat_python_every_bench`. memories `char_literal_e2e_oracle`,
`verify_actual_pattern_not_proxy`, `smoke_first_batch_full_gate`,
`verify_against_releasesafe_binary`.
