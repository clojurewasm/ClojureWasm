# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; ≈ `0c26349e`). Per-commit = smoke; commit
  **and** push (CLAUDE.md § atomic Step 6). `build.zig.zon` `.zwasm` = tag pin
  `v2.0.0-alpha.3`.
- **First commit on resume MUST be**: continue the **stdlib/contrib clj-parity
  differential sweep** (user's overnight directive + memory
  `clj_stdlib_contrib_sweep_campaign`) into the **less-common namespaces not yet
  swept** — clojure.test (fixtures/reporting), clojure.pprint (dispatch/`*print-*`),
  clojure.spec.alpha (advanced: `s/fdef`/`s/multi-spec`/regex-op edges),
  clojure.core.reducers, clojure.string/set deep arities. Method: probe vs the clj
  oracle (FILE/heredoc, not `-e "$big"` — `char_literal_e2e_oracle`); a DIFF is
  bug→fix+e2e OR AD-NNN. The **common surface is mature** (extensively probed: core/
  string/set/data/walk/math/format/zip/edn/contrib/number/interop/transducers/
  destructuring/protocols/state/reader all clean).
- **Forbidden this session**: bare `zig build test` WITHOUT `-Dwasm` (false fails —
  memory `zig_build_test_needs_dwasm`); bare `zig build` for a probe (ADR-0133 —
  ReleaseSafe). Reader-macro / syntax-quote NS-qualification stays `rt/` (AD-038/049).

## Last landed (git log = SSOT)

**BigDecimal / java.time clj-parity arc, 2026-06-24 — full gate GREEN (392/0).**
Complete BigDecimal numeric surface: `java.math.RoundingMode` enum (ADR-0160,
host-enum singleton) + compareTo/max/min/equals(scale-sensitive)/pow/intValue/
longValue/doubleValue/divide-with-mode/remainder/divideToIntegralValue +
`java.math.MathContext` (ctor + getPrecision/getRoundingMode/.round(mc)/.divide(mc)
+ DECIMAL32/64/128/UNLIMITED) + `(BigDecimal. str|int)` ctor. `java.time`:
`ChronoUnit` enum + `.until(d2, unit)` complete across LocalDate/LocalDateTime/
Instant (D-510/D-511/D-512). `ns-unalias`. Cache cleanup: ~39G local + 126G
ubuntunote `.zig-cache` freed (user-requested). New host-singleton pattern
(`.rounding_mode`/`.chrono_unit`/`.math_context` StaticFieldValue arms).

## Standing structural unit (available, not yet started)

**D-510 — general host-singleton/enum unification.** Four parallel consumers now
exist (RoundingMode/ChronoUnit/MathContext-DECIMAL* on `.host_instance`; DayOfWeek/
Month on `.typed_instance`+TemporalPrint). The unification reconciles the two
representations into one mechanism — a focused depth-2 refactor (ADR + DA), best
with fresh context. Tracked in `.dev/debt.yaml` D-510 with the scope finding.

## North star (ACTIVE)

cljw's differentiator = **Wasm/edge-native (gap II) × VM-perf fusion→JIT (gap III)**.
The embedded **zwasm** JIT engine (ADR-0200) is the cljw DEFAULT (`.auto`). The
remaining north-star step is **components-through-the-JIT** — zwasm-side (D-500).
Live ledger: `.dev/zwasm_capabilities.md`.

## Cold-start reading order (resume)

handover → memory `clj_stdlib_contrib_sweep_campaign` (the overnight directive) +
`docs/works/ladder.md` → `.claude/rules/clj_diff_sweep.md` + `scripts/clj_diff_sweep.sh`
(sweep harness + corpus-lock) → `private/notes/sweep-*.md` (this arc's findings).
memories `char_literal_e2e_oracle`, `verify_actual_pattern_not_proxy`,
`smoke_first_batch_full_gate`.
