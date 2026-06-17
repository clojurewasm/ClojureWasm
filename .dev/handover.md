# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Stopped — user requested

User instruction (2026-06-17): 「クリアセッションから継続できる状態か、配線・参照
チェーンを監査して停止して」(audit clean-session resumability + the wiring/reference
chain, then stop). AUDIT RESULT = CLEAN-RESUME-READY: every handover-cited file/ADR/
debt-row resolves; handover 88 lines (≤100); `.dev/.gate_pass` MATCHES the current
src/test hash (a fresh resume sees a verified-green gate — this session's edits were
debt.yaml/rules-only, not in the fingerprint); working tree clean; all pushed
(HEAD 7378db07). Resume at the quality-loop floor drain (D-446) per the Resume
contract. (Next `/continue` deletes this section.)

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; may lag). **NORMAL PUSH MODE**: after each
  unit's smoke-green commit, `git push origin main` immediately (Step 6).
  `build.zig.zon` `.zwasm` is SHA-PINNED (`#412966f7…`, `lazy`). Per-commit = smoke;
  full gate batches at ceiling / boundary / pre-tag.

- **First commit on resume MUST be**: **quality-loop floor drain — D-446 (fn
  arity envelopes vs clj, complete the MID/UNDER/over-arity sweep + arity-boundary
  corpus)**. RATIONALE: the D-386 row (SSOT) says the accessible perf dispatch axis
  is EXHAUSTED — (a) inline-stepOnce-SP-marshalling is a risky UAF-class cycle "not
  to be rushed / fresh focus", (b) batch-polls DEAD (don't re-run), (c) JIT fenced
  (D-133); perf goal (fastest-script 19/30) already MET → pivot to quality sweep.
  Candidates after D-446: D-449 (regex dfa.zig dead-code decision), D-239
  (alter-meta! on ns/ref — agent landed via D-441 per the 2026-06-17 audit). D-386(a) stays open for a FRESH-FOCUS session with
  the CLJW_GC_TORTURE_ALLOC safety net (do not rush at the tail of a long context).
  Below = the prior perf-campaign detail (kept for when D-386(a) is taken fresh):
  RE-MEASURED + DIAGNOSED 2026-06-17 (fresh, ReleaseSafe,
  10-run, canonical `compare_langs.sh` — full detail in
  `private/notes/9.2.S-perf-remeasure-2026-06-17.md`). The 2026-06-16 baseline was
  STALE (pre-O-037..O-042). Current truth: **ratio_sum + nested_update are now WON
  (0.95× / 0.84×)**; the other 7 sit at 1.10–1.29× — gc_alloc_rate 1.29× ·
  json_parse 1.28× · string_ops 1.25× · bigint 1.20× · gc_large_heap 1.18× ·
  sieve 1.15× · destructure 1.10×. Localized construction levers (O-040/041/042)
  are MINED. **The GC/alloc-throughput hypothesis is REFUTED by measurement**: the
  D-244 #4b fix unblocked + I built ADR-0028 alloc-driven auto-collect (env, default
  OFF) and measured it — ZERO change on gc_alloc_rate / gc_large_heap (corroborates
  O-040: gc_alloc_rate is construction-bound, 0.5% malloc leaf). Auto-collect
  experiment REVERTED — plus TWO more cheap levers REFUTED (do NOT re-try):
  chunk-buffer `undefined` slots (~3% at noise floor + drops a safety margin) and
  the free-pool `pop()` empty fast-path (flat). **`-Dprofile` LANDED** (keep
  symbols on an optimised build for `sample`); the trustworthy profile shows the
  1.1–1.3× gaps are DIFFUSELY bound (per-alloc bookkeeping + VM dispatch +
  jsonToCw recursion, no single dominant cost). **So the ONLY remaining
  accessible lever is the structural D-386 (a)**: inline `stepOnce`'s per-op
  `var sp = sp_ptr.*` / `sp_ptr.* = sp` marshalling into eval-loop locals — its
  row flags it "a risky UAF-class cycle not to be rushed"; do it with FRESH FOCUS
  + the (now #4b-clean) `CLJW_GC_TORTURE_ALLOC` suite as the safety net (the
  flattened locals must stay GC-published at every alloc). JIT (c)=D-133 is
  user-fenced; a generational GC would NOT move these (not GC-time-bound).
  **Alternative high-value front while perf is structurally blocked**: §9.0 gap
  area II (Wasm-edge-native, the stated differentiator) — pivoting is reasonable
  (clj_diff_sweep Discipline 2: don't let perf-grind displace the differentiator);
  the user owns the `.dev/.perf_campaign_active` flag (currently SET). Regenerate
  stale `cross-lang-latest.yaml`. DEFERRED: D-446 arity residual; D-458 cl-format
  V/# runtime params (cl-dir gap, small, low-priority clj-parity).

- **Forbidden this session**: JIT integration (D-133 — user-fenced 2026-06-16;
  the ARM64 codegen substrate is DONE + execution-verified, but the coupled
  recognizer+codegen+trigger+marshalling+oracle build is GATED behind an
  explicit user greenlight; plan in `private/notes/9.2.S-d133-jit-survey.md
  § INTEGRATION`). `git push --force*`. Bare `zig build test` WITHOUT `-Dwasm`
  (false fails — memory `zig_build_test_needs_dwasm`). Bare `zig build` for
  scripted/probe (ADR-0133 — ReleaseSafe). Measure perf only ReleaseSafe.

## Last landed (git log = SSOT; all pushed)

**cl-format COMPLETE** (D-455 DISCHARGED): the whole Common-Lisp-format surface now
lands on cljw's minimal `cl-run` (no upstream arg-navigator/column-writer port — the
prior "ADR-level" assessment was wrong). chunk2 ~P/~*/~T (index arg-navigator),
chunk3 ~$/~E/~G (full CLtL Steele float, reusing `(str f)` shortest-round-trip),
chunk4 ~[~;~] conditional (nesting-aware) + ~<~;~> justification. e2e 82 cases +
`clj_corpus/cl_format_float.txt` 13 pins; all clj-oracle byte-matched. Documented
divergences that RAISE cleanly: the `V`/`#` runtime-valued directive params (D-458,
a cl-dir gap) + the ~<…~:;…~> pretty-print column mode (needs a column-tracking
writer). Also fixed a stale phase7 case3 (D-456 defprotocol→symbol parity follow-up).

Then (user-directed) **reconciled the debt ledger to code** (6 verify-forks): 8 misfiled
DISCHARGED rows moved active→discharged (74→66), 3 stale-partials corrected (D-042/033/239),
1 dangling-ref typo fixed — so Step 0.5 statuses are now code-trustworthy. Fixed the yq
SSOT tips too (3-section structure, mixed discharged schema, the `comma | select` precedence
footgun). Ledger: active=66/standing=31/discharged=362, all gates green.

## Cold-start reading order (resume)

handover → `.dev/project_facts.md` (F-002/F-006/F-015) → ADR-0148 (perf campaign
goal + landed O-037..O-040 + the 9-target table + conversion-group next-front) →
`.dev/perf_campaign_essence.md` (exploration modes + experiment-revert) → D-450
row in `.dev/debt.yaml` → `bench/README.md` (measured scoreboard). Perf measured
ReleaseFast/ReleaseSafe only (memory `perf-measure-release` /
`verify-against-releasesafe-binary`); each optimization gets its own ADR + DA
fork. memory `direct-explore-fork-mechanical` + `perf-beat-python-every-bench`.
