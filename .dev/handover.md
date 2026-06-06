# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (Phase-C library gap-hunt exhausted this session — ~16
  clj-parity fixes landed + corpus-backed + audited; see § Phase C below).
- **First commit on resume MUST be**: **execute the Convergence Campaign
  Stage 0** (`.dev/convergence_campaign.md`) — inventory & SSOT rebuild:
  (0.1) refresh `core_coverage_gaps.md`; (0.2) NEW `v0_v1_feature_parity.md`
  (v0 bundled-lib / CLI feature → v1 status; seed list in the campaign);
  (0.3) rebuild `compat_tiers.yaml` Java tier scope; (0.4) de-stale + defer
  re-eval EVERY debt row (anti-D-177 over-claim + dup sweep); (0.5) populate
  `docs/works/` real-world pure-Clojure lib ladder. Then Stage 1 runs the
  blocker-free ordered execution autonomously (resolve-stdin fix → deps.edn →
  lib ladder → native cljw cider ops → v0-lib backfill → clj-parity sizable →
  **Phase B concurrency = Stage 1.7**), ending with the wiring/reference-chain
  audit (Final Stage). The campaign is the SSOT; Phase B is one ordered item in it.
- **⚠ USER must act (time-sensitive, NOT AI-doable)**: see
  `private/clojure_conj_2026_cfp/DEFERRED_USER_ACTIONS.md` — (1) Sessionize submit
  by 6/13 (`SUBMIT_READY.md` copy-paste ready); (2) v0.1.0 tag/Release + make
  `cw-from-scratch` the default branch; (3) edge-demo CRUD `git push` + `fly deploy`.
- **Forbidden**: the 3 USER actions above (credential / product decisions — the
  safety layer blocks them); editing `.claude/rules/*` (permission-blocked →
  surface); pinning an in-progress zwasm v2 state / tag (F-001: v2 ONLY from
  `zwasm-from-scratch`); trusting `~/Documents/OSS/zig`.

## Phase C — library gap-hunt exhausted (2026-06-06, git log = SSOT)

The clj-diff differential sweep ran across all practically-probeable surfaces
(~300 probes: reader / numeric-tower / comparison / collections / higher-order /
regex / var-ns / string / transducers — common AND deep). ~16 clj-parity fixes
landed, each corpus- or e2e-backed; corpus regression 2045/2045 reproduce:

- **reader**: radix `2r1010` (D-263); octal `017` + octal-char `\o377` cap;
  `\uXXXX` lone-surrogate reject.
- **numeric tower**: biginteger≡bigint + AD-016 (D-265); unchecked-* FULL family
  (D-268); ratio-collapses-to-whole → BigInt `2N` (D-272, F-005); compare across
  the whole tower EXACTLY + `(compare ##NaN x)`→0.
- **seq/string**: lazy distinct/dedupe (D-264); subs / subvec / .substring
  bounds-check (was silent clamp); symbol/keyword `"ns/name"` split; nthrest
  (n≤0 keeps coll) / take-last (empty→nil).
- **analyzer**: qualified `ns/name` own-interns-only (D-261). **edn**: read-string
  EOF throws, not silent nil (D-269).

Remaining gaps are TRACKED sizable features or AD (not quick-fix), recorded in
debt.yaml: **D-057** Unicode case-fold (ASCII-only; full table = Phase 11 OR AD);
**D-270** Java primitive arrays; **D-086** record `__extmap` (F-003 structural);
**D-266** non-chunked lazy-seq perf; **D-267** format `%c`; **D-271** with-meta on
a raw range; re-matcher/re-groups; **D-258** dormant agent torture flake (D-244 #4).

## Process discipline (SSOT = memory + rules; do NOT re-expand here)

- Gate (source only): `timeout 1800 bash test/run_all.sh --serial-e2e` (~5min;
  -P8 over-runs under load). Doc-only = no gate. Never poll a bg gate.
- A clj-diff probe runs many `cljw` processes — **never sweep concurrently with a
  running gate** (contends with the perf-threshold steps → false failures).
- clj-diff harness = `scripts/clj_diff_sweep.sh exprs --corpus <area>`; for
  classification, probe **per-expr** (cljw vs clj individually) — a batch desyncs
  when one expr is a clj READ error (e.g. `08`, `nan?`, a non-required
  `clojure.set/…`). `clj -M -e` → `timeout 20` + bound infinite seqs.
- Speed ONLY via `scripts/perf.sh` (never time Debug). Edit/Write TRANSCODES
  literal non-ASCII (keep source ASCII; splice non-ASCII via python). Default
  backend = VM (F-012).

## Cold-start reading order (tracked-only)

handover → **`.dev/convergence_campaign.md`** (the driving SSOT/procedure) →
`.dev/core_coverage_gaps.md` (D-158 var map) + `.dev/debt.yaml` (131 active) +
`compat_tiers.yaml` (Java tier scope) → ADR-0090 (Phase-B concurrency, = campaign
Stage 1.7) + ADR-0089 → `.dev/project_facts.md` F-004/F-006 → CLAUDE.md
(§ Project spirit + The only stop) → `.dev/principle.md`.
