# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (Convergence Campaign **Stage 0 DONE** this session —
  5 SSOTs rebuilt; see § Just landed).
- **First commit on resume MUST be**: **Convergence Campaign Stage 1.1 —
  `resolve`-in-stdin regression** (`.dev/convergence_campaign.md` Stage 1).
  `(resolve 'map)` returns nil via `cljw -` (stdin) but `#'clojure.core/map`
  via `-e`; the stdin eval path's ns/resolution setup differs from `-e`. Small,
  unblocks reliable nREPL/cider eval. Then Stage 1 proceeds in order: deps.edn
  resolution (1.2) → real-lib ladder drive (1.3) → native cljw cider ops (1.4) →
  v0→v1 bundled-lib backfill (1.5, D-273) → clj-parity sizable (1.6) → **Phase B
  HARDENING (1.7, D-242 — concurrency is IMPLEMENTED, this is torture/perf
  residuals not construction)** → Final Stage wiring audit. The campaign is the SSOT.
- **⚠ USER must act (time-sensitive, NOT AI-doable)**: see
  `private/clojure_conj_2026_cfp/DEFERRED_USER_ACTIONS.md` — (1) Sessionize submit
  by 6/13 (`SUBMIT_READY.md` copy-paste ready); (2) v0.1.0 tag/Release + make
  `cw-from-scratch` the default branch; (3) edge-demo CRUD `git push` + `fly deploy`.
- **Forbidden**: the 3 USER actions above (credential / product decisions — the
  safety layer blocks them); editing `.claude/rules/*` (permission-blocked →
  surface); pinning an in-progress zwasm v2 state / tag (F-001: v2 ONLY from
  `zwasm-from-scratch`); trusting `~/Documents/OSS/zig`.

## Just landed — Convergence Campaign Stage 0 (2026-06-06, git log = SSOT)

Inventory & SSOT rebuild, 4 commits:

- **0.1** `core_coverage_gaps.md` recipe re-run (168 raw missing, unchanged
  shape; residue = known-deferred REPL-dynvar/array/proxy classes).
- **0.2** NEW `.dev/v0_v1_feature_parity.md` (v0's 32 bundled ns + app surface →
  v1: 12 present / 3 partial / 24 MISSING) + umbrella **D-273** so every MISSING
  carries a live debt row.
- **0.3** `compat_tiers.yaml` Java scope: +31 Tier-A / +3 Tier-C host-class
  **reservations** (smell-caught: draft proposed phantom `files:`; merged as
  one-liner reservations per the SSOT's own convention, G3-clean).
- **0.4** debt de-stale −5 active: **DISCOVERY — Phase B concurrency is
  IMPLEMENTED at HEAD** (landed 2026-06-05, before the campaign was written;
  real-OS-thread future + MVCC STM + agent/locking/atom-CAS all probe-green).
  Discharged D-009/010/012/013/211; flipped D-224/046 to actionable; D-242
  re-scoped "unimplemented core" → "concurrency hardening".
- **0.5** NEW `docs/works/` ladder (F-010) — 15 libs ranked by pure-Clojure
  degree; medley / math.combinatorics / tools.cli load green on cljw (`-cp`,
  ADR-0084); deps.edn (Stage 1.2) is the next unlock.

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
`.dev/v0_v1_feature_parity.md` (D-273 backfill list) + `.dev/debt.yaml` (133
active) + `compat_tiers.yaml` (Java tier scope) + `docs/works/ladder.md` →
ADR-0090/0089 (Phase B — IMPLEMENTED, Stage 1.7 = hardening) →
`.dev/project_facts.md` F-004/F-006 → CLAUDE.md (§ Project spirit + The only
stop) → `.dev/principle.md`.
