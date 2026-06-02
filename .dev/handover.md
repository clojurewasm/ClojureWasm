# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (D-203 extend-type-over-native-class + ADR-0072
  Accepted on `cw-from-scratch`). Gate green on `vm` (Mac 203; ADR-0070 /
  F-012). debt ledger is **`.dev/debt.yaml`** (structured YAML).
- **First commit on resume MUST be: implement D-200 — EDN `#uuid`/`#inst`
  tagged literals + data readers.** Land the reusable reader infra FIRST
  (tokenizer `#<tag> <form>` arm sibling to `#'`/`#()`, a `readTaggedLiteral`
  dispatch, a default data-reader table, `read-string` / `clojure.edn/read-string`
  routing + the 2-arity `[opts s]` form honouring `:readers`/`:default`).
  Then a SEPARATE ADR for the `#uuid`/`#inst` value-type decision: cljw's
  `java.util.UUID/randomUUID` returns the canonical 36-char STRING (F-009, no
  distinct UUID type), so `#uuid "s"` → `(UUID/fromString s)` gives `str`/`=`
  parity but `uuid?`/`pr-str`/`class` all diverge — partial-string-parity vs a
  real UUID type is ADR-level (same shape for `#inst`/Date). Full context +
  the reverted-spike finding in the D-200 row. **Verify via e2e** (top-level
  forms) — `clj_diff_sweep` can NOT batch-verify define-heavy reader/poly forms
  (wraps each line in `(prn …)` → `<clj-missing>`).
  Other follow-ups: (a) **D-204** — name↔Tag SSOT consolidation (spun out of
  D-203; broadens `instance?`/`class`/`extend-type` to BigInt/Ratio/BigDecimal,
  its own cycle); (b) v0.1.0-tag closeout (Phase 14.14).
- **Forbidden**: re-sweeping COVERAGE.md § Swept areas wholesale; seizing the
  F-003 structural-deferred rows (D-164 empty≡nil, D-165 i48→i64, D-086/088/
  178/179) incrementally — big-bang, user-gated; re-opening landed work
  (git log = SSOT); perf without a Release `scripts/perf.sh` number.

## Just landed (git log = SSOT; full rows in `.dev/debt.yaml`)

- **D-203 / ADR-0072 (Accepted)** — `extend-type`/`extend-protocol` over a
  native/java class. `class_name.nativeTagFor(name) ?Tag` (accessor over the
  EXISTING `NATIVE_ENTRIES`+`FQCN_MAP`, no new table) + an `analyzeSymbol`
  `symbol_unresolved` fallback arm resolve a bare native-class symbol
  (`Long`/`String`/`java.lang.Long`) to `nativeDescriptor(tag)` — the SAME
  descriptor a primitive receiver dispatches through, so the impl lands where
  dispatch finds it. AFTER Var resolution → `(def String …)` shadows. Bare
  class symbol is now a value (= `(class 5)`; coherence). Interface names
  (Number/IFn) stay unresolved (no single tag). 8 e2e (`--compare` dual) +
  2 unit tests. Discharges D-202 gap (2) (its `resolveJavaSurface` plan was
  wrong — would land on a `rt.types` surface descriptor, the wrong object).

## Remaining (pointers — full text in `.dev/debt.yaml` + COVERAGE.md)

- **Moderate features**: D-200 (next — see Resume contract), D-204 (name↔Tag
  SSOT consolidation, opportunistic).
- **Structural-deferred (F-003, big-bang, user-gated)**: D-164 empty≡nil
  (highest-leverage single fix), D-165 i48→i64, D-086/088/178/179, D-105.
- **v0.1.0 closeout**: Phase 14.14 — exit-smoke + `phase_at_least_14` flip +
  tag (D-047 unblocks ≥2^64 on Linux).
- **Perf §9.2.S CLOSED**: Release startup is ms; re-open ONLY with a Release
  `scripts/perf.sh` regression number. D-140 startup = moot.

## Process discipline (SSOT = memory + rules; do NOT re-expand here)

- Gate: `timeout 1800 bash test/run_all.sh --serial-e2e` (the -P8 pool times
  out under load — memory `gate-parallel-e2e-timeout`). Never poll a bg gate.
  `clj -M -e` → `timeout 20`-wrap + bound infinite seqs. Speed ONLY via
  `scripts/perf.sh` (Release) — `.claude/rules/perf_measure_release.md`.

## Cold-start reading order (tracked-only)

handover → `test/diff/clj_corpus/COVERAGE.md` (sweep state) +
`.claude/rules/clj_diff_sweep.md` → `.dev/debt.yaml` (open rows: D-200/D-204)
→ CLAUDE.md (§ Project spirit + Autonomous Workflow + The only stop) →
`.dev/project_facts.md` (F-002/010/011/012) → `.dev/principle.md` (Bad Smell).
