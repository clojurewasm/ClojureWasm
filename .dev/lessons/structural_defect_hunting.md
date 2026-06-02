# Lesson: structural-defect hunting (corpus-driven), fix per finished-form

- **Date**: 2026-05-30
- **Cluster**: E (Debugging and tooling) + cross-ref Cluster A

## Observation

The corpus-driven sweep (running common `clojure.core` ops on **large /
edge inputs** via `cljw -e`, not AI-guessed unit probes) surfaces a class
of bugs that self-probing misses: not "function X is absent" (an ad-hoc
gap), but **structural defects** — a design that is wired wrong, a
subsystem scaffolded-but-unconnected, a representation that diverges, or a
hidden super-linear cost. These are the high-value finds. When one is
structural, the response is **F-002**: fix the finished form (loop/recur,
proper wiring, rt plumbing), do the rework, do **not** ad-hoc patch the
symptom. (User directive 2026-05-30: "ad-hoc ではなく構造的欠陥を見つけ、
完成形がきれいの原則に従い手戻りを厭わず取り組む".)

This lesson is the resume contract for that mode — a fresh `continue`
session should treat structural-defect hunting as the operating mode, not
gap-filling.

## The structural-defect PATTERNS found this session (the reusable catalog)

1. **Eager non-TCO recursion class** (SEVERE — segfault). `(range 100000)`,
   `(sort (range 5000))`, `(interleave …)`, `(zipmap …)` all segfaulted:
   a `.clj` fn recursing fn-deep, or non-tail as `(into [x] (SELF (rest …)))`,
   over collection size → stack overflow. **Fix**: `loop`/`recur`
   (constant stack). **Detection**: large-input probe; grep
   `(into (conj` + a self-call not wrapped in `lazy-seq`. Safe siblings:
   lazy-seq-wrapped (map/filter/take-while/…) and log-depth (msort).
   Commits 1f6ca79e / fcd712fb / 485e9142 / d4acdb14.

2. **Designed-but-unconnected scaffolding**. The multimethod has a full
   isa?-walk in `getMethod` (`dominates`/prefer-table/cache-snapshot), but
   `makeMultiFn` sets `hierarchy_ref = nil`, `derefHierarchy` is a no-op,
   and `isaCheck` receives the ref (not `:ancestors`) — so `defmulti`
   never consults the hierarchy (`derive` doesn't affect dispatch). The
   feature "works" in isolation; its **integration path is a silent
   skeleton**. **Detection**: a feature works standalone but its
   cross-subsystem wire is a no-op/nil-default. = **D-161**.

3. **Missing eval-time reachability**. `eval` is blocked because
   `analyzeForm` needs the `macro_table`, which is a setup-time param NOT
   stored on `rt`/`env` — a runtime primitive can't reach it. The
   defect is architectural (a needed resource isn't threaded to the
   eval-time context), not a missing fn. **Detection**: a runtime
   primitive needs a resource that only exists at setup/analysis time.
   = **D-162**.

4. **Representation divergence**. cljw UUIDs are plain strings (no `.uuid`
   tag), so `uuid?` has nothing to check — the predicate is ambiguous
   because the representation collapsed the type. **Detection**: a
   `type?`-style predicate has no distinct tag/representation to test.

5. **Hidden O(n²)**. `dedupe` (`(last acc)` per step) and `distinct`
   (linear `some` per element) coll arities timed out at ~5000 — correct
   but unusable at scale. **Fix**: delegate to the O(n) transducer.
   **Detection**: large-input timeout (not a crash). Commit d4acdb14.

## The HUNTING METHOD (how to keep finding these)

0. **Use the real Clojure (`clj`) differential oracle** (F-011 +
   `.dev/reference_clones.md`). Instead of guessing the expected output,
   run the same form through `clj -M -e '<expr>'` and diff against
   `cljw -e '<expr>'` — **including error cases** (the message format
   differs, but the exception CLASS and the value must match; extract
   the class with `grep -oE '\(([A-Za-z]+Exception|[A-Za-z]+Error)\)'`).
   `clj` startup is ~1–2 s, so batch probes. A mismatch that is a
   recorded ADR divergence (e.g. `(class 5)` → `Long` not
   `java.lang.Long`) is not a defect; everything else is a candidate.
   Use the harness `scripts/clj_diff_sweep.sh` (rule
   `.claude/rules/clj_diff_sweep.md`); the tracked sweep state is
   `test/diff/clj_corpus/COVERAGE.md`. Gitignored scratch log (optional):
   `private/notes/phaseA26-clj-differential-oracle.md`.
1. Run **systematic large-input + edge `cljw -e` probes** over a category
   (every coll-fn, then string/regex/arith, then nil-punning/destructuring/
   threading, …). Tag each result OK / crash / timeout / name_error /
   **diverges-from-clj**.
2. A **crash or timeout** is almost always structural (recursion class,
   O(n²)) — fix the finished form (loop/recur, transducer delegation).
3. A **wrong-but-no-crash** result or a **feature that works standalone
   but no-ops in integration** is the subtler structural class (#2/#4) —
   trace the wiring; if a scaffold is unconnected, wire it per finished
   form (may need a Step-0 survey of the subsystem first).
4. A **name_error** is usually just an ad-hoc missing fn — fill it if
   clean (`.clj` composition / reuse), else record as a debt with the
   architectural blocker named (D-162-style).
5. When the fix requires **rework / rt plumbing / a subsystem rewrite**,
   that is the expected case — F-002 says cycle size is not a constraint.
   Do NOT defer on diff-size grounds (Cycle-budget defer smell). Defer
   ONLY when it needs a focused Step-0 survey to avoid breaking intricate
   scaffolding (e.g. D-161 touches the dispatch path) — record a precise
   debt row with the wiring plan so the focused session is ~30 min.

## Known structural-defect work-queue (for the resuming session)

- **D-162** — `eval`: store `macro_table` on `rt` at `setupCore`, then
  `eval` = valueToForm→analyzeForm(rt.macro_table)→evalForm. Architectural.
- **D-161** — `defmulti` dispatch: wire `hierarchy_ref` to the global
  `-global-hierarchy` atom; `derefHierarchy` deref it; `getMethod` pass
  `:ancestors`. Layer-0 dispatch path; survey the prefer/dominates/cache
  scaffolding first.
- **D-160** — `sequence`/`eduction`: need a push→pull transducer bridge
  (TransformerIterator-equivalent); cljw transducers are reduce-driven.
- **Representation**: UUID-as-string (no tag) — decide a UUID
  representation before `uuid?`; same question latent for `type`/`class`
  (no JVM Class → what does cljw return?).
- Continue the probe sweep on unswept surface (interop, dynamic vars,
  IO, deftype/defrecord field access, protocol edge) for more of the above.

## Lesson (what to do next time)

The gap-map's "fill missing fns" is the floor; the **ceiling is structural
defects**, and they hide behind functions that *appear* to work. Hunt them
with large-input/edge probes + wiring audits, and fix the finished form
even when it means undoing earlier shape. A crash/timeout on common input
is never acceptable to ship; an unconnected integration scaffold is a lie
(silent no-op) by the `permanent_noop_forbidden` standard.

## Related

- `.dev/principle.md` — Bad Smell catalogue (Smallest-diff bias,
  Cycle-budget defer, Silent default-shift) + four depths of revision +
  Structural imagination phase. This lesson is the *applied* form.
- F-002 (`project_facts.md`) — finished-form wins; cycle size not a
  constraint.
- `.dev/debt.yaml` D-160 / D-161 / D-162 — the named structural queue.
- `.dev/core_coverage_gaps.md` — CRASH FIXES + sweep sections (the
  per-defect detail).
- `phase_deferred_scaffolds.md` (Cluster A) — the sibling "scaffold loses
  its homing path" pattern (test-orphan / compile-error-orphan); #2 above
  (unconnected integration) is its dispatch-path cousin.
