# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; ≈ `368c9851`). Per-commit = smoke; commit
  **and** push (CLAUDE.md § atomic Step 6). `build.zig.zon` `.zwasm` = tag pin
  `v2.0.0-alpha.3`.
- **First commit on resume MUST be**: continue the **gap-III perf campaign (D-450)
  — fastest-script goal**. RE-MEASURED 2026-06-24 (`bench/cross-lang-latest.yaml` +
  README regenerated): still **19/30 fastest-script**; ratio_sum CLOSED (O-046 +
  O-050). The 9 LIVE GAPS (cljw÷fastest-script): **sieve 1.59×(bb)** · gc_alloc_rate
  1.43×(bb) · string_ops 1.40×(bb) · destructure 1.20× · json_parse 1.12× ·
  map_filter_reduce 1.11× · bigint_factorial 1.08× · gc_large_heap 1.07× ·
  nested_update 1.05×. **RECONSTRUCTED LEVER ORDER**: (1) **startup floor (D-140)**
  = highest cross-cutting — sieve (top gap) is floor-sensitive + the ~10-13ms cold
  floor is added to every bench; PROFILE `runner.zig setupCoreAot` (envelope
  deserialize + ~hundreds of op_def core-var interns + primitive.registerAll) — the
  measure-first next step; (2) GC-arch pair (own ADR+DA); (3) string_ops; (4)
  map_filter_reduce (NEW gap — check the O-045 fused-reduce gate). **CAVEAT**: this
  session's machine was under load (~+7-8ms all benches; floor proxy fib_loop 13.7ms
  vs 2026-06-16 5.1ms, but peers rose similarly → mostly load) — re-measure on a
  quiet Mac before treating bigint_factorial/destructure/gc_alloc_rate (prev O-047/
  O-048/O-040-closed) as genuine regressions. Full analysis:
  `private/notes/9.2.S-plan-reconstruction-20260624.md`. D-180 / D-510 / D-511(2-arg)
  are DONE; D-511 double-ctor + D-513 deferred/foundational (Standing units).
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

handover → `.dev/debt.yaml` **D-450** (the active perf front, re-measured) →
`private/notes/9.2.S-plan-reconstruction-20260624.md` (the full 2026-06-24 gap
analysis + lever order; gitignored but on local disk) → `.dev/perf_v0_baseline.md`
+ ADR-0148 + memories `perf_campaign_roadmap_9_2_s` / `perf_beat_python_every_bench`
/ `verify_actual_pattern_not_proxy` (the stale-data lesson this session re-confirmed)
/ `verify_against_releasesafe_binary` / `smoke_first_batch_full_gate`. The campaign
fast-mode (relax the gate to diff-oracle for pure-perf) is injected each session by
`scripts/perf_campaign_remind.sh` (`.dev/.perf_campaign_active` is set).

## Stopped — user requested

User instruction (2026-06-24): 「であれば、クリーンなセッションからやらせたいので、
continueだけで継続できるように配線・参照チェーンを監査して停止して。」(after the
cross-lang re-measure + plan reconstruction landed; the startup-floor lever is best
started with a clean session + a quiet Mac for reliable timing). Resume contract
above is audited: tree clean, HEAD `368c9851` pushed, src fingerprint == `.smoke_pass`
(HEAD green), D-450 + the plan note carry the reconstructed gaps + lever order.
**First action on `/continue`**: measure-first the startup floor (D-140) — profile
`runner.zig setupCoreAot` restore time on a QUIET Mac (the load caveat: do not chase
this session's inflated absolutes), confirm the floor is genuinely ~10ms+ at rest,
then tune the AOT restore. Per-task note: `private/notes/9.2.S-plan-reconstruction-20260624.md`.
