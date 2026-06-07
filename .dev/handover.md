# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log`. 2026-06-07 landed (newest last): aliased-macro analyzer
  fix (`fa8628ea`, resolveMaybe alias-translate) · clojure.template / defprotocol
  options / `..` macro (`811d1f08`) · java.lang.Class methods + java.util.*
  interfaces (`ee1552d6`, D-311) · **ADR-0113 deferred `clojure.lang.*` host-refs +
  defmethod-empty-body + defmulti docstring/attr-map** (`bfa4c514`). `verified_projects/`
  → `-M:verify`, now **9** (medley, math.combinatorics, data.priority-map,
  core.cache, potpuri, data.zip, qbits.ex, core.unify, integrant). Gate 285/0.
- **First commit on resume MUST be: land hiccup, then honeysql** (user 2026-06-07
  priority — the 2 libs that take verified_projects to 11, then the campaign STAYs).
  `hiccup` blocks on **`java.net.URI`** (`extend-protocol ToString java.net.URI` +
  functional `to-uri`/`url-encode`; a real Java class → a `runtime/java/net/URI.zig`
  surface, NOT ADR-0113-deferrable). `honeysql` blocks on **java.util.Locale**
  (D-315: US/ROOT static fields + `String.toUpperCase`/`toLowerCase` Locale overload;
  a host_instance surface was designed+reverted — re-land GC-safe, gc.infra-singleton
  like empty_queue) **AND regex lookahead `(?=…)`** (`honey.sql/dehyphen`;
  `src/runtime/regex/` rejects it). Land Locale+lookahead TOGETHER (anti-drip-feed).
  Probe `verified_projects/<lib>` for the exact chain; add dir + `bash
  scripts/verify_projects.sh <lib>`, commit on green. SSOT = `.dev/convergence_campaign.md`
  Stage 1.3 item 3 (PRIORITY + STAY directive). A failure IS a coverage gap → fix
  root-cause (F-013) or improve deps.edn (`:git`/`:local`, NOT Maven JAR).
- **After hiccup + honeysql verify (→ 11): STAY the library-incorporation
  campaign** (paused, not abandoned). The loop then **self-selects the remaining
  work** (CLAUDE.md § The only stop next-task rule + the F-010 `quality-loop floor:`
  drain) — coverage has plateaued, so precision-raise = quality work (tests,
  robustness, error-path fidelity) + any user-flagged feature, NOT more lib-probing.
  Optimization stays DEFERRED per memory `optimization-deferred-until-15-libs`
  (binary size / startup / hot paths, measured via `scripts/perf.sh` Release only).
- **Parked libs (deeper blockers; not the priority)**: schema (`clojure.lang.Compiler/
  CHAR_MAP` value-position — ADR-0113 relieves the call-position class but CHAR_MAP is
  value-position + more), clip (`clojure.lang.Reflector`), data.avl (`clojure.lang.RT`/
  APersistentMap), bouncer/struct (clj-time / cuerdas Maven+regex). Re-probe after a
  campaign re-open; NOT now.
- **Deferred — do NOT re-attempt the naive fix**: D-308 `(instance?
  clojure.lang.IDeref x)` needs a per-interface NATIVE-implementer table ∪ protocol
  satisfaction — NOT a `satisfies?` alias (reverted). · reify protocol_remap (D-280
  residual) · D-288 deftype `^:volatile-mutable`+set! · D-305 builtin var
  :arglists/:doc table · D-316 def-target metadata-map VALUES unevaluated (affects
  defn+defmulti) · D-314 defprotocol `:extend-via-metadata` dispatch.
- **⚠ USER must act (time-sensitive, NOT AI-doable)**: see
  `private/clojure_conj_2026_cfp/archive/DEFERRED_USER_ACTIONS.md` — (1) Sessionize submit
  by 6/13; (2) v0.1.0 tag/Release + make `cw-from-scratch` default branch;
  (3) edge-demo CRUD `git push` + `fly deploy`.
- **Forbidden**: the 3 USER actions above (credential/product — safety-blocked;
  **user gives concrete instructions later — do NOT touch tag/Sessionize/edge-demo
  until then**); bench/optimization before the lib bar; editing `.claude/rules/*`
  (permission-blocked → surface as carry-over); the naive D-308 `satisfies?`-rewrite;
  pinning an in-progress zwasm v2 state/tag (F-001); trusting `~/Documents/OSS/zig`.

## Just landed (2026-06-07, git log = SSOT)

- **ADR-0113 deferred `clojure.lang.*` host-refs** (`bfa4c514`, integrant 9th). An
  unresolved `clojure.lang.*`/`clojure.asm.*` qualified ref (call-head OR value
  position) rewrites to a CALL-time `feature_not_supported` instead of failing the
  whole namespace at analysis — a lib whose CORE is pure but whose periphery names a
  JVM internal now LOADS (integrant's `clojure.lang.RT/baseLoader`). Strict prefix
  allowlist keeps typos loud; `java.*` stays loud (AD-022). Same cycle:
  enumeration-seq/iterator-seq stubs, empty-body defmethod (clj parity), defmulti
  docstring/attr-map (was mistaken for the dispatch fn — now skipped + attached to
  Var.meta). D-316 records a separate divergence (metadata-map values unevaluated).

## Process discipline (SSOT = memory + rules; do NOT re-expand here)

- Gate (source only): `timeout 1800 bash test/run_all.sh --serial-e2e` (~5min;
  -P8 over-runs under load). Doc-only / verified_projects-only = no gate. Never
  poll a bg gate.
- `verified_projects` sweep + clj-diff probes are NETWORK / many-`cljw` — never
  run concurrently with the gate. clj-diff harness = `scripts/clj_diff_sweep.sh`;
  `clj -M -e` → `timeout 20` + bound infinite seqs. Speed ONLY via `scripts/perf.sh`.
  Edit/Write TRANSCODES non-ASCII (splice via python). Default backend = VM (F-012).

## Cold-start reading order (tracked-only)

handover → **`.dev/convergence_campaign.md`** (driving SSOT; Stage 1.3 item 3 =
verified_projects + PRIORITY/STAY directive) → **`verified_projects/README.md`** (the
lib-load method) → `docs/works/ladder.md` (ranked candidates + NEEDS-ROW) +
`.dev/debt.yaml` (D-314/D-315/D-316) + `compat_tiers.yaml` → ADRs
`0101_deps_git_fetch.md` (+am.1) / `0111_deps_run_modes.md` / `0112_typed_instance_metadata.md`
/ **`0113_deferred_host_class_ref.md`** → `.dev/project_facts.md` (F-013/F-010/F-002)
→ CLAUDE.md (§ Project spirit + The only stop) → `.dev/principle.md`.

## Stopped — user requested

User instruction (2026-06-07): prioritize incorporating **hiccup + honeysql**; once
those + the existing 9 verify (→ 11), put the library-incorporation campaign on STAY
and have the loop self-select the remaining work; rewrite the plan accordingly;
audit the wiring + reference chains so a fresh `/continue` resumes autonomously; then
stop. Plan rewritten (convergence_campaign Stage 1.3 item 3 + this Resume contract);
wiring audited. Resume = the "First commit on resume MUST be" above (land hiccup,
then honeysql).
