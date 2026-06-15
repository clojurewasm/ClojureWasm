# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` is the SSOT; HEAD ≈ `ec2ee67b`, may lag). **NORMAL
  PUSH MODE**: after each unit's smoke-green commit, `git push origin main`
  immediately (Step 6). `build.zig.zon` `.zwasm` is SHA-PINNED to a pushed
  clojurewasm/zwasm commit (`#412966f7…`, `lazy`) — not the local path.
  Per-commit = smoke; full gate batches at ceiling / boundary / pre-tag.

- **First commit on resume MUST be**: **fixnum `mod`/`rem`/`quot` intrinsic** (the
  sieve's real lever). GOAL (user-affirmed 2026-06-15): beat Python on EVERY bench
  via Zig-backed equivalent-semantics impls (memory `perf-beat-python-every-bench`).
  Current Python-losers (re-measured): **regex_count 1.75× / sieve 1.40× /
  nested_update 1.21× / bigint_factorial 1.19×** (fib FLIPPED to cljw-win via
  O-028/029). sieve is **fn-call-bound** (not depth-bound — filter-chain collapse
  was NO-GO, ADR-0146): user-`fn*` predicate `mod` ~230ns + `not=` ~260ns are NOT
  intrinsic. Fix = extend the O-029 `fastBinaryFixnum` family to `mod`/`rem`/`quot`
  (`@mod`/`@rem`/`@divTrunc`, div0 + i48min/-1 corner → null defer). FULL change
  list (MINIMUM 8 edits + the superinstruction variants) + the F-011 correctness
  table is in `private/notes/9.2.S-intrinsic-mod-survey.md`. Then re-measure `not=`
  (intrinsic as eq-then-negate?), then nested_update (update-in/assoc-in Zig
  builtins), then regex_count (after cross-lang equivalence audit). Validate each:
  diff oracle (TreeWalk≡VM) + new `diff_test.zig` case + `clj` corpus (F-011) + bench.
  - **JIT (D-133) re-sequenced LAST** (ADR-0145): re-open only when its ROI
    predicate fires. Do NOT open the executable-memory/codegen surface now.
  - **D-445** = fused-reduce 正しい姿 (reduce path, user interest) — open, separate
    from the sieve (which never reduces).

- **Validation infra**: alloc-driven GC torture (`CLJW_GC_TORTURE_ALLOC=N`,
  inert-by-default) forces a collect inside `gc.alloc` so MID-OP rooting gaps
  surface deterministically (caught the filter-chain vector-base gap this session).
  KEY LESSON: the diff oracle (TreeWalk≡VM) is necessary but NOT sufficient — a bug
  identical on both backends passes it; clj corpus + torture + direct probe are the
  backstops. (Intrinsic arith fast path is VM-only; TreeWalk uses the builtin, so
  parity is structural via the diff oracle.)

- **Forbidden this session**: `git push --force*`; bare `zig build test` WITHOUT
  `-Dwasm` (false fails — memory `zig_build_test_needs_dwasm`); bare `zig build`
  for scripted/probe (ADR-0133 — ReleaseSafe). Measure perf only ReleaseSafe.

## Last landed (git log = SSOT; HEAD `a5eb3fe9`, all pushed)

**ADR-0146 filter-chain collapse = NO-GO** (doc-only; the Zig producer was built,
measured, reverted). It collapses correctly (2.6× on deep cheap-pred nests) but
moves the sieve ~0 — the sieve is **fn-call-bound** (mod/not= non-intrinsic), not
depth-bound; v0's 1645ms depth pathology did not transfer (cljw starts at 27ms).
Redirect = the fixnum mod/rem/quot intrinsic (above). D-445 = fused-reduce proper
form (reduce path). Prior arc still in: O-028/029 (fib flipped to cljw-win) +
alloc-driven GC torture.

SAFETY: `clj` batches need `-J-Xmx2g` + bounded seqs; `zig build test` needs
`-Dwasm`; name changed e2e steps to `--smoke`; new debt rows via Edit (quoted id,
not `yq +=`). **State**: near-complete (F-015); §9 gap-area model; zwasm SHA-pinned.

## Cold-start reading order (resume)

handover → **`.dev/project_facts.md` F-015** (completion-grade posture) →
**`.dev/decisions/0142_*.md`** (§9 gap-area reframe) → **ROADMAP §9.0** → the
chosen perf unit's `.dev/debt.yaml` row (D-386 dispatch / D-133 JIT) +
`.dev/perf_v0_baseline.md` + memory `perf-campaign-roadmap-9-2-s`. clj oracle =
`~/Documents/OSS/clojure/` + `clj -J-Xmx2g -M` (`timeout 60`). The loop
self-selects the next perf unit (CLAUDE.md § "When the active work unit completes").
