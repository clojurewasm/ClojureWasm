# Perf-campaign essence (the relentless-lookahead injection SSOT)

> Machine-injected at every wait-point by `scripts/perf_campaign_remind.sh`
> **only while `.dev/.perf_campaign_active` exists** (the campaign-pause
> switch, 2026-06-13 — while the campaign is paused the hook is silent;
> `touch` the flag when the user re-opens §9.2.S).
> (PostToolUse:Bash on a gate / bench / background launch) and at SessionStart.
> Kept SHORT so it can be force-injected often without diluting; the existing
> `gate_continue_remind.sh` / `post_commit_remind.sh` are the model. The campaign
> runs under ROADMAP §9.2.S; the smell-audit + gate-cadence hooks are the
> *blocking* guards, this is the *don't-drift* guard.

## The one rule

**A wait is never idle. While ANY background work runs (a gate, a bench, a
ScheduleWakeup), do LOOKAHEAD SURVEY + PREP — never end a turn on a bare
"awaiting X".** Rework from a survey that a later fix invalidates is cheap (AI
speed); an idle wait is the only real waste.

## What to do during a wait — go CONCRETE (no build / no bench during the wait)

Plans alone are SHALLOW (user, 2026-06-11). During a wait, write the ACTUAL next
change as code — only `build` / `bench` / `run` are deferred (they contend with
the wait's perf-threshold steps). `private/` is gitignored scratch; and you may
write directly into `src/` UNCOMMITTED (the working tree is fine to hold the next
change — just don't build/bench until the wait clears; a later fix that reworks it
is cheap at AI speed). On wait-clear: build + bench + commit.

- **Write the next change's real code** (in `src/`, uncommitted, OR a `private/`
  draft) so the instant the wait clears it is build+bench away — not a plan to
  start typing.
- **Beyond v0 (v0 is mostly mined; ADR-0148)** — source the next lever from:
  (a) the WINNER's internal impl — read JVM `clojure.lang.{Ratio,PersistentHashMap,
  BigInteger}`, GraalVM/Babashka native-image GC, CPython `Objects/` + C-json, V8;
  (b) web search for the published technique (generational GC, rational fast-paths,
  bignum limb reuse); (c) cljw v1 deep-dive + a measurement-driven hypothesis;
  (d) recombining DEFERRED `debt.yaml` levers (one alone may be inert, combined pays).
  Re-derive cljw-clean (F-004), never copy. (v0 catalogue still at
  `.dev/perf_v0_baseline.md` for residual ideas.)
- **Survey the next ADR-0148 target** (ratio_sum / the GC pair / …) + draft its attack.
- **Experiment-and-revert**: try a lever, MEASURE; if it doesn't pay, revert the code —
  a reverted experiment's commit MAY stay in the log (the test suite is the backstop;
  never leave `main` red). No regressions (diff oracle + corpus stay green). Short
  benches carry noise (≥10 runs, cold-vs-compute) — don't optimize noise.
- **Re-profile / re-read** the hot path; update the survey note's plan.

## Campaign fast-mode — the gating rules are OURS; relax them for velocity

The gate is OUR rule (user, 2026-06-11: "結局自分達で決めたルールでしかない"). During
the campaign, REVISE the mechanization autonomously for speed — do not be paralysed
by a slow / timing-out gate:

- **Per-commit = the correctness CORE, fast**: `zig build test` (×2 backends = the
  full F-012 diff oracle, ~67 s — this IS the correctness proof) + targeted
  `CLJW_GC_TORTURE` (only for GC/frame changes) + a focused `bench/run_bench.sh
  --quick`. Commit on that. A pure-perf change that produces identical Values needs
  no more than the diff oracle.
- **The heavy 297-step e2e suite does NOT run per-commit** during the campaign — it
  is the D-385 bottleneck (it can exceed the 40-min timeout). BATCH it, and **always
  with `--resume`** (`bash test/run_all.sh --serial-e2e --resume`): a re-run after a
  timeout CONTINUES from where it stopped (content-fingerprint ledger), never redoes
  passed steps. Run it at a milestone (a real win solidifies) or on `ubuntunote`
  (remote, no local contention). Re-deriving "redo from scratch on timeout" is the
  stupidity this exists to kill.
- **Disable, don't suffer**: if a self-imposed gate/check is the bottleneck and the
  correctness it adds is already covered (diff oracle = F-012), skip it for the
  campaign and note the deferral — it is ours to relax. Re-tighten at the campaign's
  milestone / before a release tag.

## The campaign does not stop until

1. cljw is the **FASTEST SCRIPT INTERPRETER** (among `{cljw, Python, Ruby, Node.js,
   Babashka}` cold µs) on the **ADR-0148 9 top-gap benches** (ratio_sum · gc_alloc_rate
   · gc_large_heap · destructure · json_parse · bigint_factorial · nested_update ·
   string_ops · sieve), THEN
2. cljw closes on cw v0's numbers (fib 16 ms, arith_loop 4-5 ms, …) — VM-perf D-386
   dispatch → superinstructions → JIT, THEN
3. the user explicitly says stop (CLAUDE.md § The only stop).

(The earlier "beat Python on every bench" goal is MET/superseded — cljw is fastest-
script in 19/30; the bar rose to fastest-script on the 9 not-yet-won, above-noise
benches. nqueens/regex_count 1.04× are EXCLUDED as cold-start/noise.)

Current front: **ADR-0148 fastest-script campaign** — highest-ROI first (ratio_sum
3.15× → the GC-arch pair → conversion/alloc → the cold-start-floor pair via D-140).
Then **D-386** dispatch. Live state: `.dev/handover.md` + ADR-0148 +
`private/notes/9.2.S-flat-frame-survey.md`.

## Guard level

This is a *don't-drift* injection, not a blocking gate. But treat it with the
same non-negotiable force you give the commit guards (smell-audit, gate cadence):
when it fires, you ACT on it — pick a lookahead task and do it — you do not
acknowledge-and-idle.
