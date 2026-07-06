# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; tip ≈ `40ccdc77`). Per-commit = smoke; commit
  **and** push (atomic Step 6). `build.zig.zon` `.zwasm` = tag pin `v2.1.0` (table64-JIT; bumped from v2.0.0).
- **1.0.0 RELEASED (2026-07-01).** cljw `v1.0.0` tagged + pushed (commit a6db5dd6);
  release.yml published the GitHub Release (macos-aarch64 + linux-x86_64 binaries +
  sha256). Pins the coherent stable **zwasm v2.0.0** (D-543 resolved; the D-501 no-max
  table grow fix is in). The user authorized the one-time loop-tag override for this cut
  (release.yml/CLAUDE.md "loop never tags" is otherwise intact). Demo repos
  cw-serverless-demo + cw-playground redeployed to fly.io on v1.0.0 and live-verified
  (books+cover-colours / eval+wasm-FFI). ADR-0167 rc.1-readiness campaign CLOSED — 1.0.0 shipped.
- **First commit on resume MUST be: the easiest-first drain head** —
  D-555/556/557 all DISCHARGED 2026-07-07 (GC persist-roots root fix +
  conservative stack scan + evalRecur reentrancy + vm loc fidelity; the
  check_vm_parity tree_walk sweep is CLEAN and runs in ci_gate.sh's
  nightly FULL tier). Resume the drain: D-526 interop statics / D-527
  parity / D-528 real-deps / D-305 builtin :arglists/:doc / D-470 format
  %t / D-554 ns attr-map. A correctness floor still PREEMPTS.
- **Forbidden this session**: bare `zig build test` WITHOUT `-Dwasm`; bare `zig build`
  for a probe (use ReleaseSafe). **The FULL gate MUST run `--serial-e2e`** — the `-P8`
  parallel default flakes the **D-418/D-258 agent load-race** (`agent_conj` →
  `[#<promise> 2]`; green isolated/serial, NOT a regression). **Never run a concurrent
  build during a gate** (host contention → false timeout). `.claude/**` edits may hit
  the auto-mode self-modification block — surface those to the user. **D-549
  distribution cluster (brew/Docker/signing) is user-LOCKED** — never self-select.

## Last landed (git log = SSOT)

2026-07-02 session (user-directed comprehensive audit → immediate fixes): 4-way
audit (debt-vs-code / scaffolding / OSS refresh / unfiled ideas → 4 notes in
`private/notes/2026-07-02-*`), then the GC-safety arc it uncovered: **ADR-0028
am3** gray-worklist mark (deep-chain SIGSEGV); **ADR-0169** AnalysisFrame — 3
sibling unrooted classes closed (analysis/compile/deserialize constants;
formToValue accumulators; TypeDescriptor method-table trace = gc_rooting C8);
ns-reflection misuse now CATCHABLE (clj-parity, corpus `ns_reflection`).
instaparse is byte-deterministic; **D-531 discharged**. Ledger reconciliation
(5 discharges, 8 re-narrows, D-549…D-553 filed incl. user 2026-07-02
decisions) + scaffolding quick wins (2 orphan scripts deleted, hook
false-positive matchers fixed, phase-era wording swept, 5 historical docs
CLOSED-bannered). Full gate green (23:34).

## Standing units (tracked in .dev/debt.yaml)

- **Perf campaign (§9.2.S) — PAUSED** (cheap levers exhausted; D-520 / D-386 / D-005/006).
- **D-439 sqrt(MathContext)** — the one BigDecimal remnant; a focused numeric cycle
  (correct rounding ×8 modes + JDK preferred output scale; base = the native Managed.sqrt).
- **D-513** — clojure.core.reducers / clojure.repl / var :doc (foundational).
- **D-418/D-258** — agent send/await + GC load-race (open, recall-trigger; re-gate serial).
- **D-430** — instaparse frontier is now DETERMINISTIC (core.cljc:361 `#'gll/TRACE`
  family) after the GC arc; re-derivable without the corruption noise.

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

## This session (2026-07-01) — rc.1 publicization campaign

Not the usual loop — plan + execute the 1.0.0-rc.1 publicization (zwasm v2 S0…S7
as template). Full scope, fully autonomous. LANDED + PUSHED: **ADR-0167** +
debt **D-536…D-543** + ROADMAP §9.2.T; **D-537** health files; **D-539** CI
wiring + repo `zig fmt`-clean; **D-540** CHANGELOG/THIRD_PARTY/attrs; **D-541**
version staging; **D-542** release.yml; **D-543** dep-pin; **D-538** env
decoupling (loop part); **D-536** down-payment. Local full gate 398/0.

Publicization pass (user's 2nd directive) — ALL committed + pushed + CI GREEN:
- **README badges + subtle sponsor** (zwasm taste: CI/Zig/Clojure/EPL/Sponsors +
  bottom sponsor line). Issues/PRs **stay paused** (did NOT mirror zwasm's reopen).
- **CI reproducibility + efficiency (D-544, discharged)**: gate-script tool-gaps
  (rg/mapfile/GNU-timeout, a bare-runner reproducibility gap) fixed → mapfile→read,
  timeout→`run_bounded`, ripgrep install + flake ripgrep/coreutils; actions/cache
  of Zig deps + two-tier gate (push/PR=core, nightly/dispatch=full). Residual ~15-min
  warm CI = inherent 3× ReleaseSafe compile (cache saves deps, not compile).
- **大整理**: shipped host-names, 8 src `private/` de-pointered, 6 mixed-JP comments
  → English, provenance `~/Documents/OSS`→repo-relative, ladder.md. Inventory:
  `private/notes/2026-07-01-publicization-cleanup-inventory.md`.

## Stopped — user requested

User instruction (2026-07-02): 「そろそろきりがよいですか？であれば、このへんで
区切りたいです。」 Session closed at a clean boundary (full gate green 23:34, all
pushed). Resume at D-430's narrowed frontier: the `var` special form does not
resolve NS ALIASES (minimal repro + fix site in the D-430 row; S-sized).

**First task on resume:** continue **Track B** (easiest-first drain; note
2026-07-02 order changes: D-517 UNBLOCKED, D-473 folded into D-513):
**D-522** = the GRADUAL ~2962-line AI-narration/pointer de-pointering (worst-offender
`src/runtime/interface_membership.zig` — but note MUCH of it is genuine technical doc;
only date-stamps like `clj-oracle 2026-06-21` + ADR/D pointers are the noise — do NOT
blindly strip provenance; careful, code-truth, multi-agent-with-verify OK). Then
D-523 doc-audit / D-460 sorted-coll-as-key correctness / D-526/527/528.
