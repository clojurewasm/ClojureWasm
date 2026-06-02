# clj differential sweep (F-011 quality mode)

Auto-loaded when editing `src/lang/clj/**` or the sweep harness. Codifies
how the post-M quality loop checks `cljw` against the `clj` oracle, and the
two disciplines that keep that work honest.

## The harness — don't hand-roll the loop

`scripts/clj_diff_sweep.sh` is the SSOT for "run these exprs through both
runtimes and show me the diffs". Do NOT write ad-hoc
`for e in …; cljw vs clj` shell loops — they are unreviewable, throw away
the result, and repeatedly re-derive the same methodology.

```sh
bash scripts/clj_diff_sweep.sh exprs.txt              # one bare value-expr per line
printf '%s\n' '(map inc [1])' | bash scripts/clj_diff_sweep.sh -
bash scripts/clj_diff_sweep.sh exprs.txt --corpus seqfns   # append OKs to a corpus
```

Methodology baked into the script (header has the detail): clj runs ONCE
over a batch (one `(prn EXPR)` per line); cljw runs one expr at a time;
both are `timeout`-wrapped; bound every seq producer with `(take N …)`.

## Discipline 1 — corpus-backed discharge (anti D-177)

A debt row whose discharge text **lists functions/behaviours as "landed"**
MUST add those exact expressions to a corpus under
`test/diff/clj_corpus/<area>.txt` (via `--corpus`), so the claim is
mechanically re-checkable. The 2026-06-02 audit found **D-177 discharged
with `take-while`/`take-nth`/`partition-by` listed as done when they were
not** — a false-positive-discharge lie. The fix for that lie class is:
*never list coverage you did not probe*, and leave the probe behind as a
corpus line. `scripts/check_corpus_regression.sh` re-runs every corpus and
fails on any DIFF, so a regression (or an over-claim) surfaces.

## Discipline 2 — big-bang, don't drip-feed

Coverage sweeps are done **exhaustively-then-closed**, not one function per
cycle forever (the Micro-coverage-grind smell). The drip-feed mode quietly
displaces the project's real differentiator (Phase 15-20 Wasm/edge-native)
and never converges. When opening a sweep area, enumerate the *whole*
surface (e.g. all of `clojure.string`, all transducer arities, all the
numeric tower), drive it to zero DIFFs in one focused push, write the
corpus, and close the area. A half-swept area is worse than an unswept one
because the debt ledger reads "covered".

## When a DIFF is NOT a bug

- **Set / non-sorted-map print order** differs from clj's hash order — not
  a bug (don't "fix" `#{2 3}` vs `#{3 2}`).
- **`()` vs `nil` for an empty realized seq** is the tracked D-164
  structural deviation (cljw collapses empty→nil), uniform across every
  seq fn — a single big-bang fix, not a per-function patch.
- **F-NNN-intentional divergences** (`+`/`*` overflow auto-promote per
  F-005, etc.) — check `project_facts.md` before treating a DIFF as a gap.

## Related

- memory `clj_diff_sweep_methodology` — the original hand-method notes.
- `.claude/rules/orphan_prevention.md` — the `timeout` / bounded-seq rules
  the harness obeys.
- `.dev/debt.yaml` D-164 (empty-seq `()` vs nil overhaul) — the standing
  big-bang target this rule's Discipline 2 points at. (D-047 setString was
  discharged 2026-06-02 via the `big_int.parseBase10` consolidated fix.)
