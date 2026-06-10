# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (see `git log`). **The branch model changed 2026-06-10**:
  the cw-from-scratch redesign was merged into `main` (`-s ours`, superseding
  v0.5.0 main + its libc hotfix; v0.5.0 tag preserved at `184c873f`). **All
  work now happens on `main`**; commit + `git push origin main` is the atomic
  Step 6. The old `cw-from-scratch` branch == `main` (historical alias, do not
  commit to it). Gate cadence (ADR-0107): per-commit **smoke** (background,
  don't block); batch the full gate ALONE with `timeout 900 bash test/run_all.sh
  --serial-e2e` at the ≤5 ceiling / boundary. Probes on a ReleaseSafe binary.
- **First on resume MUST be: interactive outward-facing-doc improvement (a
  USER-COLLABORATIVE pass, NOT the autonomous TDD loop).** Order:
  1. **`README.md` + outward-facing materials** — improve interactively with
     the user (tone, accuracy, the story; the numbers are now ~3.4 MB default /
     ~3.8 MB `-Dwasm` / ~5 ms cold-start / 24 bundled `clojure.*` ns / 130 ADRs —
     see `bench/RELEASE_METRICS.md`).
  2. **CFP text + materials** (`private/clojure_conj_2026_cfp/`) — interactive
     refinement of SUBMISSION / REVIEWER_INFO / MY_CFP (numbers already refreshed
     2026-06-10 to "約4MB(最小1.6MB)/ 約5ms"; remaining = human-gated video /
     photo / final name).
  This is collaborative doc work; ask the user for direction on wording, do not
  autonomously rewrite their outward-facing claims.
- **Forbidden**: `git push --force*` (settings deny-list). Pushing to `main` is
  now NORMAL (no longer forbidden). The fly demos (D-362) are DONE + live.

## Just landed — 2026-06-10 mega-session (all pushed to `main`)

- **main merge**: redesign superseded v0.5.0 main; CLAUDE.md / continue skill /
  run_remote_ubuntu.sh / this handover rewired from `cw-from-scratch` → `main`.
- **D-377 facet 2 / ADR-0129**: deftype hasheq+equiv as HAMT key (flatland.ordered
  fully works) + collHash lazy-seq fix. **D-380 DC1+DC2**: all-28-AD differences
  doc + lossless debt-ledger hygiene (active 240→114). **D-273 backfills**:
  clojure.stacktrace / uuid / instant / test.tap (+ clj-compat clojure.test
  surface). **D-382 Stage 1**: neutral nanosecond java.sql.Timestamp +
  read-instant-timestamp (clj-exact). **CFP**: metrics re-measured + docs refreshed.

## Follow-ups tracked (autonomous-loop backlog, AFTER the interactive doc pass)

D-382 Stage 2 (field-rich Calendar — large) · D-381 (lazy hasheq cache, perf) ·
D-383 (regex literal in bootstrap .clj) · D-273 remaining (clojure.xml / shell /
spec — large) · quality_floor rows = standing drain. Per-task notes:
`private/notes/D37{3,5,7}-*.md` + `D377-facet2-*.md` + `D273-*` + `D382-*`.

## Cold-start reading order

handover → `README.md` (the doc to improve first) → `bench/RELEASE_METRICS.md`
(current numbers) → `private/clojure_conj_2026_cfp/SUBMISSION.md` + `MEASUREMENTS_2026-06-10.md`
(CFP, the 2nd interactive task) → CLAUDE.md § Identity (the `main` branch model).
