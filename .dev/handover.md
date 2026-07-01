# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; tip `ac1b883c`). Per-commit = smoke; commit
  **and** push (atomic Step 6). `build.zig.zon` `.zwasm` = tag pin `v2.0.0-alpha.3`.
- **ACTIVE CAMPAIGN (2026-07-01, user-directed): 1.0.0-rc.1 release readiness
  (ADR-0167).** Full-scope A+B, fully autonomous. Drive the finite Track-A gate
  below + the parallel Track-B (ADR-0166 D-522…D-529) quality drain. The final
  version bump + `git tag` is **USER-OWNED** (build.zig.zon SSOT; loop never tags).
- **rc.1 readiness gate (FINITE — the tag-cut SSOT):**
  - [~] **D-537** community-health files — SECURITY/CoC/ISSUE_TEMPLATE/PR_TEMPLATE/
    FUNDING + CONTRIBUTING reconcile *drafted this session; commit pending*.
  - [ ] **D-539 ★** CI wiring (.github absent = zero external verification) — ci.yml
    push/PR macOS+Ubuntu via `scripts/ci_gate.sh` SSOT; dependabot; gitleaks; Zig pin.
  - [ ] **D-536** debt-ledger code-truth reconcile (zwasm S0 pattern).
  - [ ] **D-538** personal-env decoupling (SSH host→env default; 2 src leaks;
    settings.local.json). *`.claude/**` edits may hit auto-mode block → surface.*
  - [ ] **D-540** CHANGELOG (`## [Unreleased]`) + THIRD_PARTY + .gitattributes/.editorconfig + ship NOTICE in .paths.
  - [ ] **D-542** release.yml (prepared-not-fired, static cljw binary).
  - [ ] **D-543** dep-pin coherence (zwasm alpha.3 vs rc.1; eager zlinter fetch).
  - [ ] **D-541** version staging convention (all rc.1 strings = staged text).
- **Track B (parallel, non-blocking for the tag):** the easiest-first `active:`
  drain continues — D-522 de-pointer / D-523 doc-audit / D-526 interop / D-527
  parity / D-528 real-deps.edn / D-529 / D-305 / D-470 / D-222 / D-460 / D-439 sqrt.
  A correctness / clj-parity floor still PREEMPTS.
- **Forbidden this session**: bare `zig build test` WITHOUT `-Dwasm`; bare `zig build`
  for a probe (use ReleaseSafe). **The FULL gate MUST run `--serial-e2e`** — the `-P8`
  parallel default flakes the **D-418/D-258 agent load-race** (`agent_conj` →
  `[#<promise> 2]`; green isolated/serial, NOT a regression). **Never run a concurrent
  build during a gate** (host contention → false timeout). `.claude/**` edits may hit
  the auto-mode self-modification block — surface those to the user.

## Last landed (git log = SSOT)

Easiest-first `active:` drain (2026-06-25): **D-472** `bytes?` (over-broad = `array?`
per AD-051, type-erasure-forced; DA-fork recommended always-false, overridden by a
probe). **D-480** `instance? Serializable` (last deferred marker; clj-oracle all tags,
`multi_fn` EXCLUDED — MultiFn is not AFunction). **D-439** BigDecimal `scaleByPowerOfTen`/
`ulp`/`divideAndRemainder`. **D-532** BigInteger `.add/.subtract/.multiply/.divide` (new
`allocDivTruncManaged` — trunc-toward-zero). **D-471** slurp/spit accept a `java.io.File`
arg (R4-clean coerceToPath). **D-511** exact `(BigDecimal. double)` ctor (reuses
`allocFromRatioParts`). **D-535** opened (user-directed): Java-interop import-gating
parity — the Java analogue of D-516/ADR-0163, deferred to the import-semantics owner
alongside D-461.

## Standing units (tracked in .dev/debt.yaml)

- **Perf campaign (§9.2.S) — PAUSED** (cheap levers exhausted; D-520 / D-386 / D-005/006).
- **D-439 sqrt(MathContext)** — the one BigDecimal remnant; a focused numeric cycle
  (correct rounding ×8 modes + JDK preferred output scale; base = the native Managed.sqrt).
- **D-513** — clojure.core.reducers / clojure.repl / var :doc (foundational).
- **D-418/D-258** — agent send/await + GC load-race (open, recall-trigger; re-gate serial).

## North star (ACTIVE, distal)

cljw's differentiator = **Wasm/edge-native (gap II) × VM-perf fusion→JIT (gap III)**.
zwasm JIT (ADR-0200) is the cljw default; remaining = components-through-the-JIT
(zwasm-side, D-500). Distal — needs a user nod; the §9.2.T public-ization sweep
(easiest-first debt drain) is the active near-term mode.

## Reading order (resume)

handover → **`private/notes/2026-06-25-debt-drain-order.md`** (easiest-first snapshot)
→ `yq` the live `active:` list → **ADR-0166** (public-ization sweep mode) → ROADMAP
§9.2.T. Memories: `verify_against_releasesafe_binary` / `smoke_first_batch_full_gate` /
`gate_parallel_e2e_timeout`.

## This session (2026-07-01) — rc.1 campaign kickoff

User directive: not the usual loop — plan + execute the 1.0.0-rc.1 publicization,
using the zwasm v2 S0…S7 release series as the template (studied its actual
diffs). Scope = full A+B, fully autonomous. Landed: **ADR-0167** (release
mechanics, DA-forked → Alt 2 finite readiness gate) + debt rows **D-536…D-543** +
ROADMAP §9.2.T amendment. D-537 health files (SECURITY/CoC/.github templates/
CONTRIBUTING reconcile) drafted. Next: commit the doc set, then D-539 CI (headline).
