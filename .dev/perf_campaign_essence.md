# Perf-campaign essence (the relentless-lookahead injection SSOT)

> Machine-injected at every wait-point by `scripts/perf_campaign_remind.sh`
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
- **Mine v0** (`~/Documents/MyProducts/ClojureWasm/`) for the next lever's proven
  shape — re-derive cljw-clean (F-004), never copy. v0 beat Python 17/20; catalogue
  `.dev/perf_v0_baseline.md`: 24A.4 arith fast-path, 37.2-3 superinstructions +
  compare-branch fusion, 37.4 ARM64 hot-loop JIT (the full target map is in
  `private/notes/9.2.S-flat-frame-survey.md § CAMPAIGN ROADMAP`).
- **Survey the next Python-target** (the losing benches) + draft its attack.
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

1. cljw beats Python on EVERY `bench/` workload (cold µs), THEN
2. cljw closes on cw v0's numbers (fib 16 ms, arith_loop 4-5 ms, …) using v0's
   proven levers (superinstructions → JIT), THEN
3. the user explicitly says stop (CLAUDE.md § The only stop).

Current front: **D-386 per-instruction dispatch** (kill stepOnce's per-op
sp/ip copy+writeback v0-style; batch the polls; superinstructions; then JIT).
Live state: `.dev/handover.md` + `private/notes/9.2.S-flat-frame-survey.md`.

## Guard level

This is a *don't-drift* injection, not a blocking gate. But treat it with the
same non-negotiable force you give the commit guards (smell-audit, gate cadence):
when it fires, you ACT on it — pick a lookahead task and do it — you do not
acknowledge-and-idle.
