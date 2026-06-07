# Convergence Campaign — drive cw v1 to feature-convergence (autonomous)

> **Status**: opened 2026-06-06; **Stage 0 DONE 2026-06-06** (5 SSOTs rebuilt:
> `core_coverage_gaps.md` re-run, NEW `v0_v1_feature_parity.md` + D-273 umbrella,
> `compat_tiers.yaml` Java scope +31A/+3C reservations, debt de-staled −5,
> `docs/works/` ladder seeded). **Load-bearing Stage-0.4 discovery: Phase B
> (concurrency, ADR-0090) is ALREADY IMPLEMENTED at HEAD** — STM/agent/locking/
> real-OS-thread future all probe-green; landed 2026-06-05 (commits
> `7ac5fb1d`..`0a1fbb73`), i.e. it was already done when this campaign was
> written. So the handover's "open Phase B" target was stale on arrival;
> Stage 1.7 is re-scoped to **hardening** (D-242 residuals), not implementation.
>
> **This file is a DRIVING procedure, not a finished inventory.** Every Stage
> exit is a *mechanical predicate* (a script result or a count), so the
> autonomous loop self-advances with **no user touchpoint**. Where a design
> choice surfaces, the loop drafts+accepts an ADR inline (CLAUDE.md § ADR-level
> designs are handled inline); where a clj divergence surfaces, it is bug→fix
> OR `AD-NNN` (never floating). The ONLY user-owned items are F-NNN amendments
> and the 3 deferred CFP actions — both OUT of campaign scope.

## Goal (the convergence definition)

cw v1 is "converged" when all four hold, each mechanically checkable:

1. **No v0→v1 functional regression** — every v0 bundled namespace / CLI
   feature is either present in v1 or has a debt row with a live barrier
   (`.dev/v0_v1_feature_parity.md`, built in Stage 0.2, has zero un-rowed
   MISSING entries).
2. **The true-remaining inventory is complete and honest** — `debt.yaml` has
   no stale defer, no over-claim (anti-D-177), no dup; every gap the sweeps
   found has a row (Stage 0.4).
3. **Real-world pure-Clojure libraries load** — `docs/works/` (F-010) records
   a ranked ladder of actual libraries `require`'d on cljw with pass/fail +
   the blocking gap (Stage 0.5 seeds it; Stage 1.3 drives it up).
4. **Every SSOT reference chain is intact** — the Final Stage wiring audit
   passes (no orphan / dangling / contradictory cross-reference).

---

## Stage 0 — Inventory & SSOT rebuild (FIRST; all mechanical, all regenerable)

Do these before any feature work. Each produces or refreshes an SSOT.

- **0.1 clojure.core coverage** — re-run `.dev/core_coverage_gaps.md`'s regen
  recipe (bb `ns-publics` ~647 diffed against cljw's var set). Output: the
  refreshed missing-var list. Confirm each "missing" with a real `cljw -e`
  probe (the recipe's false-positive caveat).
- **0.2 v0→v1 feature parity** — NEW file `.dev/v0_v1_feature_parity.md`.
  Enumerate every `~/Documents/MyProducts/ClojureWasm/src/lang/lib/*.zig`
  bundled namespace + `src/app/*` feature, map to v1 status
  (present / partial / MISSING + debt-row id). **Seed (this scan's findings —
  verify + complete in Stage 0.2, do not trust blindly):** MISSING in v1 =
  `clojure.spec.alpha` + `clojure.spec.gen.alpha`, `clojure.core.reducers`,
  `clojure.core.protocols`, `clojure.datafy`, `clojure.instant`,
  `clojure.java.io` / `.shell` / `.process` / `.browse`, `clojure.main`,
  `clojure.repl` + `clojure.repl.deps` (`add-lib!`), `clojure.stacktrace`,
  `clojure.template`, `clojure.test.tap`, `clojure.uuid` (ns form),
  `clojure.xml`; **app**: `deps.edn` resolution (`deps.zig`), project
  scaffolding. v1-only additions (reverse direction) are OUT of scope.
- **0.3 Java-handling scope** — rebuild `compat_tiers.yaml` as the authoritative
  "how far we handle Java" SSOT. v1 currently has only 22 Tier-A rows; v0's
  compat_tiers + ADR-0013 carried the full A/B/C/D classification. Mine v0's
  compat_tiers + the `clojure.java.*` libs + the `java.*` classes real
  libraries touch; classify each Java class A/B/C/D with the cw-native
  alternative for C/D. This is the SSOT the lib-compat ladder (0.5/1.3) reads
  to decide "this lib needs `java.io.File` → Tier?".
- **0.4 Debt de-stale + defer re-eval** — run the `audit_scaffolding` 5-lens +
  the anti-D-177 over-claim check on EVERY `debt.yaml` row (131 active):
  re-evaluate each `blocked-by` / `Phase N target` / `deferred` predicate (flip
  if the barrier dissolved), DELETE any row whose discharge text is a lie
  (corpus/code does not back it), consolidate dups (e.g. this session's
  Unicode-case row that duplicated the re-opened D-057 — caught + folded).
  Output: an honest debt set + a count delta in the commit.
- **0.5 Real-world lib ladder** — create + populate `docs/works/` (F-010,
  currently empty). Rank candidate libraries by **pure-Clojure degree** (zero
  Java interop first), `require` each via the Stage-1.2 deps path (or `-cp`
  until then), record `{lib, version, status, blocking-gap-row}`. Seed the
  ladder head with small pure-Clojure libs (e.g. data/edn/string utilities);
  the FIRST real Java-interop blocker each lib hits becomes a debt row read
  against the Stage-0.3 Java tier SSOT.

**Stage 0 exit (mechanical):** all five SSOTs regenerated this campaign;
`.dev/v0_v1_feature_parity.md` exists with zero un-rowed MISSING; `debt.yaml`
passes `audit_scaffolding` with zero over-claim/dup finding; `docs/works/` is
non-empty. The unified, dependency-sorted work-list for Stage 1 is materialized
from this data (the loop derives the order; it is NOT hand-fixed here).

---

## Stage 1 — Blocker-free ordered execution (autonomous)

The order below is the **seed**; the loop re-derives the true topological order
from Stage 0's data so that **every item's prerequisites land before it** (no
item blocks on a later one). Each item runs the standard per-task TDD loop
(CLAUDE.md § Autonomous Workflow): corpus- or e2e-backed, gate-green, committed.
The loop self-selects the next item by the order — **no user touchpoint**.

1. **`resolve`-in-stdin regression** — `(resolve 'map)` returns nil via
   `cljw -` (stdin) but `#'clojure.core/map` via `-e`. Blocks reliable
   nREPL/cider eval. Fix first (small; the stdin eval path's ns/resolution
   setup differs from `-e`).
2. **deps.edn source resolution** — re-derive v0's `deps.zig` cljw-clean
   (`no_copy_from_v1`): `:paths` / `:deps` (`:local/root`, `:git/url`+`:git/sha`)
   / `:aliases` / `-A:alias`. NO Maven/Clojars JAR (source-only, matching v0).
   Unblocks the real-world lib ladder.
3. **Real-world lib ladder drive** — push `docs/works/` up the pure-Clojure
   ranking; each new lib's first blocker spawns a fix (folds into the relevant
   item below). This is the campaign's *coverage engine* — it surfaces the
   highest-value missing pieces empirically, not by guessing.
   **Committed-artifact form (2026-06-07): `verified_projects/<lib>/`** — each
   proven lib lands as a tracked `deps.edn` (`:git/url`+`:git/sha`) + `verify.clj`
   exercise instead of a throwaway `-cp` probe, so (a) the dir list shows
   at-a-glance which libs load, and (b) `scripts/verify_projects.sh` re-runs them
   as a real-world-lib **regression sweep** (network; Phase-boundary / on-demand,
   not per-commit). Method + how-to-add: `verified_projects/README.md`. Grow it
   one lib at a time; reconcile with `docs/works/ladder.md` (ladder = ranked
   candidates, verified_projects = committed proofs). deps.edn-system gaps found
   while doing this are fixed in-place (within cljw's control — `:git`/`:local`
   resolution, NOT Maven JAR fetch); ADR-0101 + amendments record the policy.

   **PRIORITY + STAY directive (user 2026-06-07).** The next two libs to land
   are **hiccup** and **honeysql** (in that order of tractability is fine). Once
   the existing **9** verified (`medley`, `math.combinatorics`,
   `data.priority-map`, `core.cache`, `potpuri`, `data.zip`, `qbits.ex`,
   `core.unify`, `integrant`) **plus hiccup + honeysql** all verify (→ 11), this
   library-incorporation campaign goes to **STAY** (paused, not abandoned). After
   the STAY, the autonomous loop **self-selects the remaining work** (per CLAUDE.md
   § The only stop's next-task rule + the F-010 quality-loop floor) — coverage
   has plateaued, so the precision-raise shifts to quality work (tests,
   robustness, error-path fidelity, the `quality-loop floor:` debt drain) and any
   user-flagged feature, NOT more lib-probing. The known blockers for the two
   priority libs (each definition-derived, F-013):
   - **hiccup** → `java.net.URI` (`extend-protocol ToString java.net.URI` +
     functional `to-uri`/`url-encode`). A java.net surface (runtime/java/net/URI.zig)
     OR — since it is a real, implementable Java class (NOT a `clojure.lang.*`
     internal, so ADR-0113 does NOT defer it) — a minimal URI value + the
     ToString/url-encode path. Probe `verified_projects/hiccup` for the exact chain.
   - **honeysql** → (a) **java.util.Locale** US/ROOT static fields + a Locale-arg
     `String.toUpperCase`/`toLowerCase` overload (D-315; a host_instance surface was
     designed+reverted 2026-06-07 — re-land with a GC-safe per-Runtime singleton:
     gc.infra-alloc like empty_queue, OR root the rt slots), AND (b) **regex
     lookahead `(?=…)`** — `honey.sql/dehyphen` uses `#"(\w)-(?=\w)"`; the regex
     engine (`src/runtime/regex/`) rejects it (`unsupported syntax in cycle 1`).
     Land (a)+(b) TOGETHER (anti-drip-feed) so honeysql verifies in one push.
     Cross-ref D-315, D-314 (extend-via-metadata, separate/optional).
4. **Native `cljw.nrepl` cider ops** — prerequisite: **populate built-in var
   metadata** (`:doc` / `:arglists` on core vars; `(meta (var map))` is nil
   today — generate from `compat_tiers.yaml` / JVM source). Then implement
   `info` / `complete` (uses `ns-publics`, already works) / `eldoc` /
   `load-file` as native ops against cljw's own var tables (more tractable than
   JVM cider-nrepl, which is `clojure.reflect` / `tools.namespace`-coupled).
   Also close nREPL `*out*`/`*err*` per-session capture (D-118).
5. **v0→v1 bundled-lib backfill** — the Stage-0.2 MISSING list, in
   pure-Clojure-degree order: `clojure.repl` (+`repl.deps` `add-lib!`) /
   `clojure.template` / `clojure.stacktrace` / `clojure.uuid` ns /
   `clojure.instant` / `clojure.spec.alpha`(+gen) / `clojure.core.reducers` /
   `clojure.datafy` / `clojure.java.io`+`.shell` (gated on the Stage-0.3 Java
   tier decision) / `clojure.xml` / `clojure.test.tap` / `clojure.main`.
6. **clj-parity sizable remainder** — D-057 Unicode case-fold (table or AD),
   D-270 Java primitive arrays, D-086 record `__extmap` (F-003 structural),
   re-matcher/re-groups, D-266 lazy-seq perf, D-267 `%c`, D-271 with-meta range.
7. **Phase B — concurrency HARDENING (ADR-0090)** — ~~implement~~ **already
   IMPLEMENTED at HEAD** (Stage-0.4 discovery): real-OS-thread `future`
   (`std.Thread.spawn`), MVCC STM (`stm/ref.zig` + `concurrency/lock_tx.zig`),
   `agent`/`send`/`await`/`agent-error`, `locking` monitor, atom CAS, the
   ThreadGcContext root-publication GC handshake — all probe-green. This item is
   now **hardening, not construction** (D-242 anchor): close the concurrency
   torture/race edges (D-244 #4 family, D-250..D-253, D-258 dormant flake), wire
   `pmap`/`pcalls` to the work-pool for genuine parallelism (D-224, result already
   correct), pick the LazySeq.force mutex disposition (D-046). `future`/`promise`
   are already async. NOTE: `delay` once-lock + STW-rendezvous fixes are still
   trickling (git log), so this is real, not closed.

---

## Final Stage — Wiring & reference-chain audit (LAST; mechanical)

Run after Stage 1 converges. A graph audit that every SSOT cross-reference and
every code dependency edge is intact:

- **`@import` zone graph** — `scripts/zone_check.sh --gate` (no upward imports;
  baseline 0).
- **SSOT cross-reference integrity** — every `D-NNN` / `AD-NNN` / `O-NNN` /
  `ADR-NNNN` / `F-NNN` / corpus-name / `compat_tiers` fqcn referenced in code
  comments, debt, ADRs, rules RESOLVES to a defined node (`check_debt_id_refs`
  extended to all ledger ID classes; add a cross-ref check if absent).
- **marker ↔ ledger sync** — `PROVISIONAL:` ↔ `feature_deps.yaml` + debt
  (`check_provisional_sync`); `PERF:` ↔ `optimizations.md`; `GC-ROOT:` ↔
  `gc_rooting.md`; every marker has a live ledger row and vice-versa.
- **aspirational-rule check** — every `.claude/rules/*.md` that declares an
  enforcement has a backing script (the zwasm `audit_table_sync` pattern); a
  rule promising a gate with no script is a finding.
- **dangling/contradiction sweep** — a fact stated once (a tier, an F-NNN
  invariant, a divergence) is referenced consistently everywhere; no node is
  orphaned (defined, never referenced) or contradicted (two SSOTs disagree).

**Final exit:** all of the above are scripts in `test/run_all.sh` (or run
clean on demand), and the audit produces zero finding. The reference chain is
then self-verifying for every future session.

---

## Autonomy contract (the "no user intervention" guarantee)

- Every Stage/item exit is a **mechanical predicate** (script exit, count,
  corpus-green) — never a judgment call that pauses for input.
- A surfaced **design choice** → inline ADR (draft+accept, DA fork at depth ≥ 2).
  A surfaced **clj divergence** → bug-fix OR `AD-NNN`. A surfaced **structural
  plan** → deferred to its owning item with a debt row (F-003).
- The loop **self-selects** the next item from the Stage-0-derived order. The
  phrases "ask the user / awaiting / which should I do next" are forbidden
  (CLAUDE.md § The only stop — Direction-ask smell).
- User-owned exceptions (do NOT attempt; surface only): F-NNN amendments; the
  3 deferred CFP actions (`DEFERRED_USER_ACTIONS.md`); `.claude/rules/*` edits
  (permission-blocked).
