# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log`. The 2026-06-07 sessions landed (newest last): D-304
  symbol metadata (ADR-0110) · var-metadata Slice 1 (synth :name/:ns/:macro/
  :dynamic/:private on read) · D-306 collection-base deftype supertypes
  (IPersistentCollection/Counted/Associative/Seqable) · defn/fn `:pre`/`:post`
  → **clojure.core.cache FULLY LOADS** · D-307 IDeref/IPending deref-able family
  · **deps.edn `:mvn`-skip (ADR-0101 am.1)** so libs whose only mvn dep is
  `org.clojure/clojure` (= cw itself) resolve via git coords · **`verified_projects/`
  mechanism** (committed real-lib proofs + regression sweep). Full gate 277/0.
- **First commit on resume MUST be: grow `verified_projects/` by one library.**
  (User-directed methodology — committed deps.edn-git-coord proofs replace corpus
  copies / `-cp`.) Pick the next candidate from `docs/works/ladder.md` (next:
  clojure.core.cache — loads end-to-end; clojure.data.generators; NOTE
  clojure.tools.cli/data.json/data.csv are BUNDLED in cw, skip), add
  `verified_projects/<lib>/{deps.edn,verify.clj}`, run
  `bash scripts/verify_projects.sh <lib>`, commit on green; reconcile the ladder.
  A failure IS a coverage gap → fix root-cause (definition-derived, F-013) OR
  improve the deps.edn system (within cljw's control — `:git`/`:local` resolution,
  NOT Maven JAR). Method + how-to-add: `verified_projects/README.md`. SSOT =
  `.dev/convergence_campaign.md` Stage 1.3.
- **deps.edn next extensions (user ideas, debt-tracked)**: D-309 run-mode
  `-M:alias` (`:main-opts`/`-m -main`) + `-X:alias` (`:exec-fn`) — cljw resolves a
  classpath only today; entry = `cljw <file>`/`-e`; v0 has the parse precedent.
- **Deferred — do NOT re-attempt the naive fix**: D-308 `(instance?
  clojure.lang.IDeref x)` needs a per-interface NATIVE-implementer membership
  table ∪ protocol satisfaction — NOT a `satisfies?` alias (the 2026-06-07 try
  was reverted: it broke `(instance? clojure.lang.IFn :kw)`→true). ADR-level,
  sibling of D-293. · reify protocol_remap (D-280 residual: expandReify lacks the
  rewriteProtocolRemap path) · D-288 deftype `^:volatile-mutable`+set! · D-305
  builtin var :arglists/:doc table (Slice 3). These block core.memoize's deeper
  load (cache loads; memoize advances :36→:67); NOT blocking verified_projects.
- **⚠ USER must act (time-sensitive, NOT AI-doable)**: see
  `private/clojure_conj_2026_cfp/DEFERRED_USER_ACTIONS.md` — (1) Sessionize submit
  by 6/13; (2) v0.1.0 tag/Release + make `cw-from-scratch` default branch;
  (3) edge-demo CRUD `git push` + `fly deploy`.
- **Forbidden**: the 3 USER actions above (credential/product — safety-blocked);
  editing `.claude/rules/*` (permission-blocked → surface as carry-over); the
  naive D-308 `satisfies?`-rewrite; pinning an in-progress zwasm v2 state/tag
  (F-001: v2 ONLY from `zwasm-from-scratch`); trusting `~/Documents/OSS/zig`.

## Stopped — user requested

User instruction (2026-06-07): "ちょっと今回のキリが良くなったところで止めてくだ
さい。Mac のディスク容量が逼迫してきていますので、わたしが整理します。" Clean
stop at a good boundary (HEAD `2ac8a405`, tree clean, all pushed). Resume per the
Resume contract above — first commit = grow `verified_projects/` by one lib
(next = clojure.core.cache; see `private/notes/stage13-deps-edn-verified-projects.md`
for the concrete next-experiment + the priority-map-dep blocker). Delete this
section on resume (the directive applied to that session only).

## Just landed (2026-06-07, git log = SSOT)

- **deps.edn unified as the lib-load methodology** (user direction). A
  `:mvn/version` dep is recorded + SKIPPED (ADR-0101 am.1), not rejected —
  satisfaction is decided at require-time by namespace availability (cw's bundled
  namespaces ∪ source-resolved `:paths`); `org.clojure/clojure` silently provided,
  other skipped coords warned; no coord→provided allowlist. Empty `:paths`→`src`.
  `verified_projects/<lib>/` (deps.edn `:git/url`+`:git/sha` + `verify.clj`
  asserting real outputs) are committed proofs; `scripts/verify_projects.sh` is
  the NETWORK regression sweep (Phase-boundary / on-demand, NOT per-commit — the
  hermetic deps.edn mechanism test stays in `test/e2e/phase14_deps_edn.sh`).
  Seeds (3/3 green): medley, data.priority-map, math.combinatorics.

## Process discipline (SSOT = memory + rules; do NOT re-expand here)

- Gate (source only): `timeout 1800 bash test/run_all.sh --serial-e2e` (~5min;
  -P8 over-runs under load). Doc-only / verified_projects-only = no gate. Never
  poll a bg gate.
- `verified_projects` sweep + clj-diff probes are NETWORK / many-`cljw` — never
  run concurrently with the gate (contends with perf-threshold steps).
- clj-diff harness = `scripts/clj_diff_sweep.sh`; per-expr classify. `clj -M -e`
  → `timeout 20` + bound infinite seqs. Speed ONLY via `scripts/perf.sh`.
  Edit/Write TRANSCODES non-ASCII (splice via python). Default backend = VM (F-012).

## Cold-start reading order (tracked-only)

handover → **`.dev/convergence_campaign.md`** (driving SSOT; Stage 1.3 =
verified_projects) → **`verified_projects/README.md`** (the lib-load method) →
`docs/works/ladder.md` (ranked candidates) + `.dev/debt.yaml` + `compat_tiers.yaml`
→ `.dev/decisions/0101_deps_git_fetch.md` (+ amendment 1) → `.dev/project_facts.md`
(F-013/F-010/F-002) → CLAUDE.md (§ Project spirit + The only stop) →
`.dev/principle.md`.
