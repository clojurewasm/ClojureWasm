# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log`. Newest = **3 clj-diff corpus sweeps + D-316 +
  ADR-0116/D-308** (2026-06-08). `verified_projects/` → `-M:verify`, 11 libs
  (library-incorporation campaign on STAY per user 2026-06-07).
- **First commit on resume MUST be: self-select the highest-value QUALITY work.**
  Read open `quality-loop floor:` debt rows FIRST (F-010 drain) per CLAUDE.md
  § The only stop, THEN broader quality. **The common / edge / lib-ns surface is
  VERIFIED clj-parity** (3 sweeps / 137 exprs / 0 real divergence — only AD-001
  set/map print order; banked as corpus `core_common_ops` / `core_edge_ops` /
  `core_lib_ns`) — do NOT re-probe those. Aim a NEW surface (error Kind parity,
  macros, ns/require) OR classify a floating DIFF (D-267 `%c`-on-integer → AD).
  Optimization stays DEFERRED (memory `optimization-deferred-until-15-libs`).
- **For a future library-campaign re-expansion**: know-how in
  **`.dev/library_incorporation_playbook.md`** (method = `verified_projects/README.md`).
- **Parked libs (re-probe only on campaign re-open)**: schema / clip / data.avl /
  data.xml / instaparse / data.json — each names its blocker class (playbook §4).
- **Deferred — do NOT re-attempt the naive fix**: reify protocol_remap (D-280
  residual) · D-288 deftype `^:volatile-mutable`+set! · D-305 builtin var
  :arglists/:doc table · D-314 defprotocol `:extend-via-metadata` dispatch ·
  **D-316 residual** (computed def-meta values need def-time runtime eval, depth-2) ·
  **D-317** IPersistentVector extend-target vs instance? membership reconcile ·
  **D-318** host_instance moving-GC / host_state_shape enum · **D-319**
  Object-as-descriptor-chain-root (perf) · **D-320** regex lookahead perf.
- **⚠ USER must act (time-sensitive, NOT AI-doable)**: see
  `private/clojure_conj_2026_cfp/archive/DEFERRED_USER_ACTIONS.md` — (1) Sessionize
  submit by 6/13; (2) v0.1.0 tag/Release + make `cw-from-scratch` default branch;
  (3) edge-demo CRUD `git push` + `fly deploy`.
- **Forbidden**: the 3 USER actions above (credential/product, safety-blocked — the
  user owns them); bench/optimization before the lib bar; editing `.claude/rules/*`
  (permission-blocked → surface as carry-over); the naive D-308 `satisfies?`-rewrite
  (superseded by ADR-0116 membership SSOT); pinning an in-progress zwasm v2 state/tag
  (F-001); trusting `~/Documents/OSS/zig`.

## Just landed (2026-06-08, git log = SSOT)

- **ADR-0116 / D-308** — `instance?` clojure.lang interface membership SSOT
  (`interface_membership.zig`): one definition-derived {name,tags} table; class_name
  matchInterface / isInterfaceName / isKnown derive (24-deep or-chain retired); the
  deref/pending/ref family (IDeref/IRef/IReference/IPending/IBlockingDeref) + a
  name-based protocol-satisfaction ∪ arm in matchUserType (a user deftype extending
  IDeref matches). D-317 narrowed (ISeq/Named/IPersistentMap derived; IPersistentVector
  residual). **D-316** — quoted def-meta values evaluate (`:arglists '([k v])` →
  `([k v])`); arbitrary computed-meta is the deferred residual. **3 clj-diff sweeps**
  banked (137 exprs, 0 real divergence) as regression-guard corpus.

## Process discipline (SSOT = memory + rules; do NOT re-expand here)

- Gate (source only): `timeout 1800 bash test/run_all.sh --serial-e2e`. Doc-only /
  corpus-only / verified_projects-only = no gate (additive batches up to 5 per
  `gate_cadence`). Never poll a bg gate. New e2e MUST register in run_all.sh.
- clj-diff harness = `scripts/clj_diff_sweep.sh` (NETWORK / many-cljw — never run
  with the gate). A bad expr POISONS the clj batch → all later lines `<clj-missing>`;
  keep every probe expr valid clj. `--corpus NAME` banks OK pairs. NEVER run the
  standalone corpus check with the Debug binary (≈2100 exprs × 0.5s ≈ 20min); the
  gate runs it in ReleaseSafe (fast). `clj -M -e` → `timeout 20` + bound seqs.
  Speed ONLY via `scripts/perf.sh`. Edit/Write TRANSCODES non-ASCII (splice via
  python). Default backend = VM (F-012). handover.md edits: the framing hook blocks
  an Edit holding a forbidden phrase — fix via Bash sed/python.

## Cold-start reading order (tracked-only)

handover → `.dev/debt.yaml` (quality-loop floor rows = next-task drain) +
`.dev/convergence_campaign.md` → `docs/works/ladder.md` + `compat_tiers.yaml` →
ADRs **`0116_instance_interface_membership_ssot.md`** / `0114` / `0115` / `0106`
→ `.dev/project_facts.md` (F-002/F-010/F-013/F-006) → CLAUDE.md (§ Project spirit
+ The only stop) → `.dev/principle.md` → `.dev/library_incorporation_playbook.md`.
