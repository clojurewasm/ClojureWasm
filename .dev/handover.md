# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; may lag). **NORMAL PUSH MODE**: after each
  unit's smoke-green commit, `git push origin main` immediately (Step 6).
  `build.zig.zon` `.zwasm` is SHA-PINNED (`#412966f7…`, `lazy`). Per-commit = smoke;
  full gate batches at ceiling / boundary / pre-tag.

- **First commit on resume MUST be**: **ADR-0148 fastest-script perf campaign**
  (user-directed 2026-06-16) — make cljw the FASTEST script interpreter (among
  `{cljw, Python, Ruby, Node.js, Babashka}` cold-start) on the **9 top-gap benches**,
  highest-ROI first: **ratio_sum 3.15× · gc_alloc_rate 2.81× · gc_large_heap 2.22× ·
  destructure 1.72× · json_parse 1.59× · bigint_factorial 1.49× · nested_update 1.37× ·
  string_ops 1.35× · sieve 1.23×** (ratios = cljw ÷ fastest-script, `bench/cross-lang-
  latest.yaml` 2026-06-16). nqueens/regex_count (1.04×) EXCLUDED = cold-start/noise.
  **Method (v0 mostly exhausted)**: other-language internal-impl study (JVM Ratio/
  HashMap/BigInteger, GraalVM/Babashka GC, CPython C-json) + web search + cljw deep-
  dive + measurement-driven experiments + recombining DEFERRED levers. **Experiment
  aggressively, revert freely — a reverted experiment's commit MAY stay in the log**
  (tests are the backstop; never leave `main` red); no regressions (diff oracle + corpus
  3157 stay green); short benches carry noise (≥10 runs, cold-vs-compute). Themes/ROI +
  per-target opt directions: **ADR-0148**. After the 9 (or provably cold-start-floor +
  D-140 cache landed) → resume the original front (VM-perf **D-386** dispatch→
  superinstructions→JIT; §9.0 gap areas). `.dev/.perf_campaign_active` is SET.
  - **GC architecture** (gc_alloc_rate/gc_large_heap, F-006) is now on the critical path
    — its design choice gets its own ADR + DA fork. **D-140 startup cache** lifts every
    cold-start-floor target (sieve, partly nested_update) at once.
  - regex arc DONE (ADR-0147: S1+S2 wired+winning, S3 DFA reserved/D-449, leftmost-first
    fixed, reluctant quantifiers landed); **D-448** nested-empty-quant capture deferred.
  - **bigint** = a target now (was deferred): the BigInt-reduce-accumulator lever, likely
    combined with the alloc work; `private/notes/9.2.S-bigint-factorial-lookahead.md`.
  - **JIT (D-133)** re-sequenced LAST (ADR-0145). **D-244 #4** capstone below.

- **Validation infra / D-244 #4 gap**: `CLJW_GC_TORTURE_ALLOC=N` validates MID-ALLOC
  rooting; the O-032/O-033 producers are SAFEPOINT-torture-validated (the primary
  hazard) but ALLOC-torture is BLOCKED on a pre-existing fabrication-rooting bug
  (op_vector_literal/set/map folds + the `vector` builtin build a partial collection
  in an unrooted Zig local → mid-alloc collect sweeps it). `fromSlice` does NOT
  sidestep it (tried+reverted). FIX = wire `gc_self_guard` (GcHeap.pin/unpin exist;
  per-site set/clear unwired) — an own-session GC-infra capstone;
  `private/notes/9.2.S-d244-4-alloc-torture-finding.md`. LESSON: diff oracle is
  necessary but NOT sufficient; clj corpus + torture + direct probe are the backstops.

- **Forbidden**: `git push --force*`; bare `zig build test` WITHOUT `-Dwasm` (false
  fails — memory `zig_build_test_needs_dwasm`); bare `zig build` for scripted/probe
  (ADR-0133 — ReleaseSafe). Measure perf only ReleaseSafe.

## Stopped — user requested

User instruction (2026-06-15): "次のクリアセッションから腰を据えて…zigライブラリを
直接使うのではなくこのシステムにうまく馴染ませるために拝借して高速性を（…工夫を
しっかり入れ込むのをゴールにする）、再度、情報伝達、配線、参照チェーン監査をして
止めて". Done: the regex perf APPROACH is elevated + made durable as **ADR-0147**
(borrow-and-adapt the prefilter + lazy-DFA into cljw's Pike-NFA, staged,
equivalence-locked; goal = incorporate the optimizations properly). `ezi-gex` cloned
as the Zig blueprint; **D-447** = regex parity gaps. **Resume = ADR-0147 Stage 1→3**
(read refs directly + measure-first, no survey/DA fork). Earlier this session the
regex fork was stopped + REVERTED (had only S1, 45→41.5ms) — tree clean, all pushed.
Re-audit verdict (info-transfer / wiring / reference-chain): RESOLVES — the durable
load-bearing direction now lives in TRACKED git (ADR-0147 + the 48-golden corpus +
D-447 + reference_clones.md ezi-gex entry), not only the gitignored audit note. A
fresh `/continue` reaches the regex approach via handover → ADR-0147 → the refs (a
fresh clone re-clones ezi-gex per reference_clones.md).

## Last landed (git log = SSOT; HEAD `fd2c9ca1`+, all pushed)

Perf: **O-030** mod/rem/quot intrinsic · **O-031** not= intrinsic + bootstrap
re-cache + not= 0-arg clj-divergence fix → **sieve CLOSED** (0.96×) · **O-032**
in-Zig chunk-map/filter producer → **map/filter 2.16-2.5×** (closure-floor
touchpoint) · **O-033** in-Zig update-in → **nested_update CLOSED** (1.18×). All
diff-oracle + clj-corpus + CLJW_GC_TORTURE=1. ADR-0146 filter-chain NO-GO (sieve is
fn-call-bound). SAFETY: `clj` needs `-J-Xmx2g` + bounded seqs; new debt rows via Edit
(quoted id) in the **active:** list. State: near-complete (F-015); §9 gap-area model.

## Cold-start reading order (resume)

handover → **`.dev/project_facts.md` F-015** → **ADR-0142** (§9 gap-area) → **ROADMAP
§9.0** → the regex unit: **ADR-0147** + ADR-0031 + the audit note + the 48-golden
corpus + `ezi-gex`. memory `perf-beat-python-every-bench` + `perf-campaign-roadmap-9-2-s`
+ `direct-explore-fork-mechanical`. clj oracle = `clojure -J-Xmx2g -M -e` (timeout 60).
