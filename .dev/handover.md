# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; may lag). **NORMAL PUSH MODE**: after each
  unit's smoke-green commit, `git push origin main` immediately (Step 6).
  `build.zig.zon` `.zwasm` is SHA-PINNED (`#412966f7…`, `lazy`). Per-commit = smoke;
  full gate batches at ceiling / boundary / pre-tag.

- **First commit on resume MUST be**: drain a **deferred residual** (the clj-diff
  probe sweep is now ~16 surfaces deep and COMPREHENSIVELY SATURATED — the last ~8
  areas found only documented ADs: AD-001 set order / AD-003 class name / AD-016
  biginteger-N / AD-007 / AD-009). Pick highest-value-first: **D-472 uri?** (a small
  Zig primitive comparing a host_instance descriptor to the URI descriptor — NOTE the
  R4 zone rule: a primitive must NOT import runtime/java/**, so route via
  `rt.types.get(<URI fqcn>)` not a URI.zig import) + **bytes?** (AD-019 array
  type-erasure — decide AD vs over-broad); **D-470 format %t** (~40 date sub-convs);
  **D-471 spit/slurp File-arg Coercions**; the deep ones (D-446 multidim aget, D-410
  java.text grapheme) need data/infra. OR one more fresh probe (clojure.zip / pprint
  / reducers still untested) — fresh surfaces still occasionally yield real COMMON
  gaps (this session: iteration, spit-options, partitionv-all, the whole java.util
  family). Probe top-level for def-forms (harness `(prn …)`-wraps → false cascades;
  verify each DIFF INDIVIDUALLY — memory `clj_diff_sweep_methodology`). Classify every
  DIFF (bug→fix / accepted→AD / defer→debt); always grep F-NNN before "fixing" a
  numeric/semantic DIFF. Don't surrender-frame the thinning; drain residuals + probe.

- **Remaining clusters (all BARRIERED or niche — the high-value unblocked work is
  drained)**:
  - **Security (gap II, ~10 rows)**: ALL barriered — D-339 slowloris (Phase-15
    cancellable Io, F-003); D-347/349 wasm/run fuel+capture (zwasm-side, F-001);
    D-338 host-import allowlist (reservation); D-346/353 (no live threat / use case).
    Don't force (F-001/F-003).
  - **Perf (gap III, D-450, ADR-0148, PAUSED)**: only fenced levers — D-386(a)
    inline stepOnce (UAF-class), JIT D-133 user-fenced.
  - **clj-parity residuals (niche/deep)**: D-446 multidim aget (deep CHAIN —
    needs Long/TYPE + to-array-2d + multidim make-array + variadic aget; no-JVM
    design Qs), D-410 java.text grapheme (needs UCD GraphemeBreakProperty data-gen),
    D-470 format `%t` date directives (~40 sub-conversions, low-value), D-462
    ZonedDateTime (tz-DB, **user/ADR-owned — NOT autonomous**), D-463 per-var events,
    D-431 Throwable str/pr, D-468/D-433 (closed/low). java.time arithmetic COMPLETE.
  - **Concurrency (gap I)**: D-258 agent-race flake (deep multi-thread STW race,
    D-244 #4), D-239/245/255 PARTIAL.

- **Forbidden this session**: JIT integration (D-133 — user-fenced 2026-06-16; plan
  in `private/notes/9.2.S-d133-jit-survey.md § INTEGRATION`). `git push --force*`.
  Bare `zig build test` WITHOUT `-Dwasm` (false fails — memory
  `zig_build_test_needs_dwasm`). Bare `zig build` for scripted/probe (ADR-0133 —
  ReleaseSafe). A reader-macro NS-qualification MUST use `rt/` (the only core ns
  resolvable in the core.clj-less diff fixture), NOT `clojure.core/` (AD-038 lesson).

## Last landed (git log = SSOT; all pushed)

**This session (~13 units, all clj-oracle-verified, full gate 377/0 green throughout):**
- **D-348** (Wasm-edge differentiator): `(wasm/run … {:env {…}})` — barrier dissolved
  (forEachEntry now exists); string/keyword-keyed :env parsed into env_keys/env_vals.
  wasm/run option surface (args/stdin/dir/dirs/env) COMPLETE. (Step 0.5 barrier re-eval.)
- **spit `& options`**: `:append` (new file_io.appendAll) + content `(str)`-coercion;
  **iteration** (clojure 1.11, the one missing 1.11 fn); **partitionv-all** (1.12) +
  **splitv-at** fix ([vec, drop-SEQ] not [vec, vec]). D-471/D-472 filed (spit File-arg;
  uri?/bytes?).
- **D-466 + sub**: `(instance? java.util.Map/List/Set/Collection/SortedMap/Sorted/
  Navigable/Iterable host)` — NEW comptime-const `host_supertypes` TypeDescriptor
  field (mirrors `static_fields`, NOT freed by deinit — the protocol_impls overload
  crashed cache_gen) consulted by class_name.matchUserType; 4 Sorted/Navigable
  interfaces registered (FQCN_MAP + interface_membership empty-tag entries).
- **D-413**: diff_test `Fixture.init` returned BY VALUE after `Env.init(&f.rt)` →
  dangling `env.rt` (non-deterministic abort on unresolved-symbol host-class lookup).
  Fixed init-in-place (out-pointer); swept 3 sibling fixtures (vm/evaluator/regex).
- **D-468 + AD-047**: host java.util collections print BY CONTENT (`[1 2]`/`#{1 2}`/
  `{:a 1}`) via a `print_content` descriptor hook + print.zig deepRealize; str stays
  Clojure-form (AD-047, not JVM Object.toString). Closes the java.util family.
- **D-469**: extend-type/-protocol GROUPED multi-arity `(g ([x] b1) ([x y] b2))` via
  an expandGroupedArities normalize pre-pass reusing the D-279 multi-arity-fn* path.
- **D-462**: LocalDate.atStartOfDay/atTime (→ LocalDateTime) — a verify-sweep proved
  the rest of java.time arithmetic was already done (stale claim). **AD-048**: record
  str = content form. **D-470 filed**: format `%t` family (low-value, deferred).
- **~16 clj-diff probe areas** (numeric/seq/string, java.util, protocols/multimethods,
  reader/ns, transducers, math/bit/array, edn/walk/sorted, format, IO, var/binding,
  1.11/1.12, exception, string/destructuring, set/comprehension, bigint/bigdec) — real
  gaps clustered in java.util/extend/java.time/IO/1.11-1.12 (all fixed); rest clj-faithful.

## Perf campaign (PAUSED; not the current task)

`.dev/.perf_campaign_active` is SET but the loop is in the quality sweep. If the user
re-opens perf: only D-386(a) (inline `stepOnce` SP-marshalling, UAF-class — needs the
`CLJW_GC_TORTURE_ALLOC` net) is accessible; JIT D-133 is user-fenced. State: ADR-0148
+ `private/notes/9.2.S-perf-remeasure-2026-06-17.md`.

## Cold-start reading order (resume)

handover → `.dev/project_facts.md` (F-002 / F-010 / F-011) → ROADMAP §9.0 (gap
areas I/II/III) → `.dev/accepted_divergences.yaml` (AD-001…048) → `.dev/debt.yaml`
(clj-parity comprehensively saturated; remaining residuals deep/barriered per the
cluster list above). memory `clj_diff_sweep_methodology` (harness def-form trap +
verify-each-DIFF) + `verify_actual_pattern_not_proxy` (stale debt claims: D-462/D-216
were re-verified against the clj oracle, not trusted) + `direct-explore-fork-mechanical`.

