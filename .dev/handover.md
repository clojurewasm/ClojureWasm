# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; may lag). **NORMAL PUSH MODE**: after each
  unit's smoke-green commit, `git push origin main` immediately (Step 6).
  `build.zig.zon` `.zwasm` is SHA-PINNED (`#412966f7…`, `lazy`). Per-commit = smoke;
  full gate batches at ceiling / boundary / pre-tag.

- **First commit on resume MUST be**: **close the java.time temporal-arithmetic area
  (D-462)** — Instant + Duration + LocalTime `plus*`/`minus*` by time units (the
  remaining types; LocalDate + LocalDateTime arithmetic are DONE). Discipline 2
  (close, don't half-sweep): the typed_instance pattern is fully established, so
  each is a clj-grounded e2e → fork the mechanical impl (the value file's descriptor
  gains the methods) → verify vs clj → smoke → commit. Notes: LocalTime arithmetic
  WRAPS mod 24h (`@mod` nano_of_day, no day field); Instant uses [epoch_ms, nanos]
  carry; Duration adds+renormalizes. THEN the remaining java.time bits are on-demand
  (D-462): `getDayOfWeek`/`DayOfWeek` enum type, LDT/LocalDate `plusMonths`/`plusYears`
  (civil clamp, reuse local_date_value addMonths), Instant `plus(Duration)`,
  `compareTo`-as-method (AD-043 magnitude). After java.time, self-select the next
  high-value clj-parity unit (single-expr sweep SATURATED; structural debt
  D-460/D-461/D-446 blocked/deferred — weigh a fresh surface).

- **Forbidden this session**: JIT integration (D-133 — user-fenced 2026-06-16; plan
  in `private/notes/9.2.S-d133-jit-survey.md § INTEGRATION`). `git push --force*`.
  Bare `zig build test` WITHOUT `-Dwasm` (false fails — memory
  `zig_build_test_needs_dwasm`). Bare `zig build` for scripted/probe (ADR-0133 —
  ReleaseSafe). A reader-macro NS-qualification MUST use `rt/` (the only core ns
  resolvable in the core.clj-less diff fixture), NOT `clojure.core/` (AD-038 lesson).

## Last landed (git log = SSOT; all pushed)

**clj-parity + java.time campaign** (this session): D-463 clojure.test report-format
fidelity (`*test-out*`, `FAIL in (test-name)`, `(not (= 1 2))` actual, context line,
`Testing <ns>`; AD-041 source-line/stacktrace). Then a comprehensive **D-462 java.time
campaign** — all five local types wired as `.typed_instance` values (timestamp.zig
model; NO new NaN-box tag): **Instant, Duration, LocalDateTime, LocalDate, LocalTime**
— statics (of/now/parse/ofEpoch*) + readers + `(str)` ISO-grounded + value-`=`, all
verified vs clj (negatives / pre-1970 / 1900-non-leap / ns-precision edges). Plus:
print via a `temporal_print` enum; shared civil + ISO format/parse helpers in
instant.zig; `(compare …)`/`(sort …)` work (compare.zig temporal arm, AD-043 sign-vs-
magnitude); comparison predicates (isBefore/isAfter/isEqual + Duration isZero/
isNegative/negated/abs); LocalDate full date-math (plus/minus days/weeks/months/years
with civil clamp + isLeapYear/lengthOfMonth); LocalDateTime time-unit arithmetic
(plus/minus days/weeks/hours/minutes/seconds/nanos with midnight carry). AD-042
(bare-toString vs `#object[…]`). `*_value.zig` in the `wrap:` slot (G3). Gate-hygiene
fix (impl_extras→wrap; stale phase14_format `%d`). ZonedDateTime DEFERRED (tz-DB).

**Open residuals** (`.dev/debt.yaml`): D-462 remaining = Instant/Duration/LocalTime
arithmetic + getDayOfWeek/DayOfWeek + LDT/LD plusMonths/plusYears + Instant.plus(Dur)
+ compareTo-as-method (all on-demand) + ZonedDateTime (tz-DB); D-463 per-var lifecycle
events; D-460 (sorted coll as map key); D-461 (require semantics — F-003 owner);
D-446 (multidim arrays).

## Perf campaign (PAUSED behind the active flag; not the current task)

`.dev/.perf_campaign_active` is SET but the loop is in the quality sweep, not perf.
If the user re-opens perf: the only remaining accessible lever is D-386(a) (inline
`stepOnce` SP-marshalling, a risky UAF-class cycle — fresh focus + the
`CLJW_GC_TORTURE_ALLOC` safety net); JIT D-133 is user-fenced. Full perf state:
ADR-0148 + `private/notes/9.2.S-perf-remeasure-2026-06-17.md`.

## Cold-start reading order (resume)

handover → `.dev/project_facts.md` (F-002 / F-010 / F-011) →
`.claude/rules/clj_diff_sweep.md` + `accepted_divergences.md` (the sweep + AD
discipline) → `.dev/accepted_divergences.yaml` (AD-001…039) → `.dev/debt.yaml`
D-446 / D-460. memory `clj_diff_sweep_methodology` + `direct-explore-fork-mechanical`.

