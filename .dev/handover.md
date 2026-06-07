# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log`. The 2026-06-07 ladder session landed a large arc:
  Pattern/quote · `(extend-type nil …)` nil-punning · deftype method-lowering
  (qualified params + empty bodies) · **ADR-0108** third host-surface tree
  `runtime/clojure/lang/` + complete `clojure.lang.Util` (11/11) + `class_of.zig`
  (D-303) · **ADR-0109 host-class-VALUE resolver CORE**: opaque collapsed-numerics
  (Integer/BigInteger → numeric-tower :98/:127→:162) + `java.lang.Object` universal
  root (algo.generic core LOADS) + `java.lang.Number` marker (algo.generic.arithmetic
  LOADS) — all oracle bit-for-bit. D-293 PARTIAL.
- **First commit on resume MUST be: the D-293 marker REMAINDER — `clojure.lang.IFn`
  value-resolution**. `(instance? IFn x)` ALREADY works (class_name.matchInterface);
  the gap is (a) resolving IFn as a VALUE in analyzeSymbol (interface-shaped names
  are skipped today — class_name.zig:585 divergence) so core.contracts'
  `(defmethod funcify* clojure.lang.IFn …)` registers + LOADS, and (b) class-level
  `(isa? <class> IFn)`. (b) is BLOCKED on a callable-class NAMING gap (D-293 row):
  `(class fn)`=`fn_val`, `sorted_map`, `var_ref` are RAW @tagName (fqcnForTag lacks
  entries). PREREQUISITE clj-parity fix: add NATIVE_ENTRIES/fqcnForTag for
  sorted_map→PersistentTreeMap, sorted_set→PersistentTreeSet, var_ref→Var (clean,
  re-verify `(class x)` e2e); fn-family stays cljw-named. Then IFn isa? via clean
  names. Then Stage 1: 1.4 cider → 1.5 v0→v1 (D-273) → 1.6 clj-parity → 1.7 Phase B
  (D-242). SSOT = `.dev/convergence_campaign.md`.
- **Carry-over (permission-blocked, ADR-0108)**: extend
  `.claude/rules/feature_name_consistency.md` scan-set to `runtime/clojure/**` — the
  classifier blocks `.claude/rules/*` edits; the user lands it. zone_check.sh already
  gates the third tree; this is doc-accuracy only.
- **Scoped gaps the ladder probes surfaced** (drive when a target needs them):
  D-286b (bare names that ARE cljw Vars — IPersistentSet/IPersistentMap with
  clj-named methods — bypass protocol_remap; needs method-name disambiguation;
  completes ordered's supertypes) · D-287 (Java arrays: aset/aget/make-array —
  ordered's backing store; ADR-level repr choice) · D-288 (deftype mutable fields
  `^:unsynchronized-mutable` + set! — tools.reader; ADR-level) · the deftype
  FUNCTIONAL residuals: cross-type `(= deftype-map native-map)` (D-280d8) ·
  find/`-entry-at` · subseq/Sorted-nav · reduce-kv→IKVReduce wiring · reify
  protocol_remap (expandReify lacks the rewriteProtocolRemap path).
- **⚠ USER must act (time-sensitive, NOT AI-doable)**: see
  `private/clojure_conj_2026_cfp/DEFERRED_USER_ACTIONS.md` — (1) Sessionize submit
  by 6/13 (`SUBMIT_READY.md` copy-paste ready); (2) v0.1.0 tag/Release + make
  `cw-from-scratch` the default branch; (3) edge-demo CRUD `git push` + `fly deploy`.
- **Forbidden**: the 3 USER actions above (credential / product decisions — the
  safety layer blocks them); editing `.claude/rules/*` (permission-blocked →
  surface); pinning an in-progress zwasm v2 state / tag (F-001: v2 ONLY from
  `zwasm-from-scratch`); trusting `~/Documents/OSS/zig`.

## Just landed (2026-06-07, git log = SSOT)

- **F-013 + ADR-0102** institutionalised the user's directive: library-driven
  discovery surfaces gaps; the response is definition-derived comprehensive
  coverage (網羅) in canonical Zig-equivalent (non-JVM) form, NOT ad-hoc
  "make this lib pass". The 個別最適化 entry is closed structurally — a closed-set
  SSOT (`host_interfaces.yaml`) + a single read point + a G4 gate (set-bound +
  route-soundness), not vigilance.
- **D-275 → D-285** (+ D-279, ADR-0103): the whole deftype/reify host-interface
  stack — clojure.lang.* family (macro rewrite to bare cljw protocol sections +
  Object method-family + arity-overload + IFn-call-path + IObj-meta), java.util.*
  host_inert, clojure.core.protocols ns, clj-name dot-calls, MapEntry ctor,
  keys/vals seq-derivation — gate-green throughout. PROVEN end-to-end: real
  `clojure.data.priority-map` is **FULLY FUNCTIONAL** (peek/count/keys/vals/assoc).
  30 e2e cases (phase14_deftype_object).

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

