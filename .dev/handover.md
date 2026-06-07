# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log`. 2026-06-07 landed (newest last): **D-309 deps.edn
  RUN-MODE `-M`/`-X` (ADR-0111)** · **D-310 part-1 `*command-line-args*`** (root-set
  across -m/file/-X) · **D-312/D-313 typed_instance + record-assoc metadata
  (ADR-0112)** · `verified_projects/` → `-M:verify` 規約, now **6** (medley,
  math.combinatorics, data.priority-map, core.cache, potpuri, data.zip). Gate 279/0.
- **Priority (user 2026-06-07, durable in memory `optimization-deferred-until-15-libs`)**:
  feature completeness > correctness > **divergence suppression** FIRST; bench /
  optimization DEFERRED until ~15 verified libs + bug pickup, THEN autonomous
  (binary size / startup / hot paths, measured via `scripts/perf.sh` Release only).
  Bench regressions acceptable meanwhile — do NOT chase.
- **First commit on resume MUST be: grow `verified_projects/` toward 15** via
  `-M:verify` (deps.edn `:paths ["."]` + `:aliases {:verify {:main-opts ["-m"
  "verify"]}}`; verify.clj = `(ns verify …)` + `-main`). Next candidates (broad-
  reprobe "loads", likely no new interop): **clojure.data.codec.base64**
  (`(b64/encode (.getBytes "hi"))`→"aGk="), **qbits.ex**, **bouncer.core**. Then
  the next interop vein is **D-311 `.isArray`** (java.lang.Class instance-method
  surface, D-293 family) → unblocks core.unify. Add dir, `bash
  scripts/verify_projects.sh <lib>`, commit on green; reconcile ladder. A failure IS
  a coverage gap → fix root-cause (F-013, definition-derived) OR improve deps.edn
  (`:git`/`:local`, NOT Maven JAR). How-to: `verified_projects/README.md`. SSOT =
  `.dev/convergence_campaign.md` Stage 1.3. data.generators deferred (maven layout);
  tools.cli/data.json/data.csv BUNDLED, skip.
- **deps.edn run-mode remainder = D-310** (part-2): `-i`/`-r`/`--report`/`@resource`/
  mixed-init-before-main + `-T` tool mode. FINISHED-FORM = a `clojure.main`-shaped
  Clojure grammar fn (ADR-0111 DA Alt 3), bootstrap-ordering-gated; current Zig
  source-synthesis migrates cleanly. Not blocking verified_projects.
- **Deferred — do NOT re-attempt the naive fix**: D-308 `(instance?
  clojure.lang.IDeref x)` needs a per-interface NATIVE-implementer membership
  table ∪ protocol satisfaction — NOT a `satisfies?` alias (the 2026-06-07 try
  was reverted: it broke `(instance? clojure.lang.IFn :kw)`→true). ADR-level,
  sibling of D-293. · reify protocol_remap (D-280 residual: expandReify lacks the
  rewriteProtocolRemap path) · D-288 deftype `^:volatile-mutable`+set! · D-305
  builtin var :arglists/:doc table (Slice 3). These block core.memoize's deeper
  load (cache loads; memoize advances :36→:67); NOT blocking verified_projects.
- **⚠ USER must act (time-sensitive, NOT AI-doable)**: see
  `private/clojure_conj_2026_cfp/archive/DEFERRED_USER_ACTIONS.md` — (1) Sessionize submit
  by 6/13; (2) v0.1.0 tag/Release + make `cw-from-scratch` default branch;
  (3) edge-demo CRUD `git push` + `fly deploy`.
- **Forbidden**: the 3 USER actions above (credential/product — safety-blocked;
  **user will give concrete instructions later — do NOT touch tag/Sessionize/
  edge-demo until then**); bench/optimization before the 15-lib bar (above);
  editing `.claude/rules/*` (permission-blocked → surface as carry-over); the
  naive D-308 `satisfies?`-rewrite; pinning an in-progress zwasm v2 state/tag
  (F-001: v2 ONLY from `zwasm-from-scratch`); trusting `~/Documents/OSS/zig`.

## Just landed (2026-06-07, git log = SSOT)

- **D-312/D-313 typed_instance metadata (ADR-0112)**. `with-meta`/`meta` on a
  defrecord (native `TypedInstance.meta`; `instWithMeta` COPIES the gc.infra field
  array — F-006 double-free guard). metadata.zig kind-gates the arms (user IObj
  wins; record→native; non-IObj deftype→error; reify dispatch-only). Record
  `assoc`/`update` thread `inst.meta` (collection.zig:618) so `(meta (assoc
  (with-meta r m) :k v))`→m — **D-313 closed in-cycle, NOT deferred** (DA flagged
  the assoc-meta-drop as a "ships a lie" smell; user's divergence-suppression
  priority). No membrane flip / no equality arm (records already field-structural).
  **clojure.data.zip** functionally verifies (6th proof). D-310 part-1
  (`*command-line-args*` root-set across -m/file/-X) also landed alongside.

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
→ `.dev/decisions/0101_deps_git_fetch.md` (+ am.1) + **`0111_deps_run_modes.md`**
+ **`0112_typed_instance_metadata.md`** → `.dev/project_facts.md`
(F-013/F-010/F-002) → CLAUDE.md (§ Project spirit + The only stop) →
`.dev/principle.md`.

## Stopped — user requested

User instruction (2026-06-07): 「このPCは一旦シャットダウン、Ubuntumini も再起動する
予定。今の実行結果を反映（バグってたら直して）、きれいな状態で止めて待って」。Same-day
priority directives are captured above (Priority line) + in memory
`optimization-deferred-until-15-libs` / `tool-channel-corrupts-under-load`.
Resume = the First-commit-MUST-be above (grow `verified_projects/` toward 15).
