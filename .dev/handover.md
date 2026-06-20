# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; may lag). **NORMAL PUSH MODE**: each unit's
  smoke-green commit is followed immediately by `git push origin main` (Step 6).
  `build.zig.zon` `.zwasm` is SHA-PINNED (`#412966f7…`, `lazy`, pre-JIT). Per-commit =
  smoke; full gate batches at ceiling / boundary / pre-tag.

- **First commit on resume MUST be**: continue the **stdlib/contrib sweep campaign**
  (user directive 2026-06-20, memory `clj_stdlib_contrib_sweep_campaign` + ADR-0156).
  Self-select the next unit (no user ask): either (a) **bundle the next official stdlib
  ns** eagerly (FILES in `bootstrap.zig` + `lookupEmbeddedFile` + EPL header per
  `clj_attribution.md`; AOT-rebuild — the `[AOT-FAIL] <file> form #N` builder.zig
  diagnostic locates traps; each bundle tends to surface a GENERIC cljw bug → fix +
  corpus it), or (b) **verify a contrib lib** under `~/Documents/OSS/` via a
  `verified_projects/<lib>/{deps.edn,verify.clj}` (`cljw -M:verify`). Candidate stdlib
  gaps: `clojure.datafy` (IObj/class/IRef markers), `clojure.repl` (doc/dir/apropos;
  `source` is hard), `clojure.core.reducers` (D-473 sequential surface), `clojure.xml`.
  Contrib clones already under `~/Documents/OSS/` (core.match, data.priority-map,
  test.check, core.memoize, …). Policy: **official stdlib → eager bundle; contrib →
  verify (require-on-demand)**.

- **Forbidden this session**: speculative JIT integration before zwasm's API stabilises
  (read `.dev/zwasm_capabilities.md` — JIT row BUILDING, not adoptable). `git push
  --force*`. Bare `zig build test` WITHOUT `-Dwasm` (false fails — memory
  `zig_build_test_needs_dwasm`). Bare `zig build` for a probe (ADR-0133 — ReleaseSafe).
  A reader-macro / syntax-quote NS-qualification MUST stay `rt/`, not `clojure.core/`
  (AD-038/AD-049).

## Last landed (git log = SSOT; all pushed)

**clojure.spec.alpha cluster COMPLETE + bundled (the campaign's first arc) + 4 GENERIC
cljw clj-parity fixes surfaced by it:**
- spec.alpha + spec.gen.alpha **eager-bundled** (ADR-0156, FILES[24/25]); loads no `-cp`;
  corpus `spec.txt` (20) + e2e `phase15_spec.sh` (19) + AD-049 (the one divergence: raw
  `s/form` shows `rt/int?`; explain/describe match clj exactly).
- `core.specs.alpha` bundled (FILES[26]); `math.combinatorics` verified (full clj parity).
- 4 generic fixes: `&`-destructure seq-walk · MapEntry-as-IFn · MultiFn read-surface
  (`.dispatchFn`/`.getMethod`) · `->`/`->>` threads any non-list step (set/map as IFn).
- `fn-sym` recovers a predicate name from its `#<ns/name>` print → spec explain/describe
  fully clj-identical. builder.zig gained an AOT-fail file+form+message diagnostic.

## North star (context, not the immediate task)

cljw's differentiator = **Wasm/edge-native (gap area II) × VM-perf fusion→JIT (gap area III)**.
The embedded **zwasm** runtime is growing a **JIT-backed embedding API** (ADR-0200) — the
cljw pin is still pre-JIT. Adoption is gated on zwasm marking it ready + a user-confirmed
pin bump. Tracker + trigger: `.dev/zwasm_capabilities.md`.

## Cold-start reading order (resume)

handover → memory `clj_stdlib_contrib_sweep_campaign` (the active campaign + policy) →
`.dev/project_facts.md` (F-002 finished-form / F-011 clj-parity) → ADR-0156 (stdlib-eager /
contrib-completeness) → `.dev/debt.yaml` D-477 (latent eager-load baseline-binding gap) →
`private/notes/spec-bundle-promotion.md` (the bundling method + next units). memory
`clj_diff_sweep_methodology` + `verify_actual_pattern_not_proxy`.
