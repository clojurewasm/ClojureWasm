# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` is the SSOT). **PHASE MODE = LOCAL ACCUMULATION
  (NO push), wasm = RELATIVE-path zon** — user override 2026-06-14. Commit each
  unit locally; do NOT `git push` (ignore the push reminders this phase); keep
  `build.zig.zon` `.zwasm = .{ .path = "../zwasm_from_scratch" }` (push-forbidden;
  the local zwasm HEAD has REQ-7). SSOT: memory `local-accumulation-sweep-phase`
  + `.dev/sweep_plan.md` § Phase mode. Per-commit = smoke (default build is
  zwasm-lazy-safe); wasm work also runs `-Dwasm`.

- **First task on resume MUST be**: **Track C — the `*out*`/`*in*` cljw-native
  writer/reader value** (user chose recommended Option C, 2026-06-14). Full order
  in **`.dev/sweep_plan.md`** (the phase SSOT — READ IT). C = ADR + DA fork for one
  cljw writer value + one reader value (NOT a java.io hierarchy clone); bind
  `*out*`/`*err*`/`*in*`; route `.write`/`.append`/`.flush` + `read`/`read-char`/…
  on it; `with-out-str` = rebind to a string-backed writer (kills the `out_capture`
  threadlocal cross-zone hack + the D-434 `out_writer_method` sentinel special-case).
  Discharges D-436(b); folds the D-414 reader shims. Then Track S (debt sweep,
  per sweep_plan.md) + Track W (wasm enrich, W1).

- **D-434 DONE** (this session, superseded by Track C): `*out*` sentinel
  `.write`/`.append`/`.flush` routed through `clojure.core/print` via the shared
  `out_writer_method` fallback (both backends). Track C replaces this with the
  writer-value model. Filed D-435 (diff-oracle full-runtime gap) + D-436 (大整理
  epic) per the user's finished-form directive.

- **Track W (wasm north-star, F-014.4) — W0 RE-LANDED this session**: the
  instance-caching component work is un-stashed (relative zon, local-only):
  `(wasm/load-component p)` + `(wasm/component-call h …)` + component-exports/invoke;
  `-Dwasm` builds green against the REQ-7 zwasm. Next = W1 enrich (require-as-
  namespace: one Var per export; dropResource GC-finaliser D-325). [D-404/ADR-0135;
  zwasm handover `private/20260613_handover_from_zwasm/handover_v2.md` COMPLETED]

- **D-431 per-class completeness CLOSED** (the prior directed task — DONE this
  session): mechanism wired + **18 built+deterministic+touched classes** corpus'd
  (String/Object/Throwable/Pattern/Matcher/Math/ArrayList/HashMap/StringBuilder/
  Long/Integer/Double/Boolean/Character/UUID/Random/URI/Date), gaps fixed same-cycle.
  Remaining is NOT more of this sweep: the over-claimed unbuilt surfaces (java.time
  D-105/D-243, BigDecimal, Arrays) are feature-builds; the ADR-0137 sharpenings
  (generated `methods:` index + mechanical lib stop-chasing) are the residual. See
  `test/diff/class_corpus/README.md` for the full map + the over-claim finding.
- **Resume PRIORITY SEQUENCE** (finished-form-first): (1) D-431 completeness gate
  — **per-class coverage CLOSED** (18 classes); residual = the ADR-0137 sharpenings
  (generated `methods:` index + mechanical lib stop-chasing) + feature-builds for
  the over-claimed classes. (2) pure-lib verification (F-014 clause 3) — **all
  LOCALLY-available org.clojure pure libs now verified** (data.json + data.csv
  added; sweep 19/19); the rest need network fetches or feature-builds (D-105 time,
  D-434 *out*, BreakIterator for cuerdas). (3) quality-floor drain — common surface
  confirmed clj-parity this session (host classes + clojure.string + set/walk/edn,
  modulo AD-001 set-order); the deep campaigns remain (D-242-245 concurrency/GC,
  D-232 validation). DEFERRED-DEEP, NOT until a consumer/window: D-430 (instaparse
  GLL parse divergence — NOT regex), D-424 (class-resolution seam), D-432 (seq-key
  hash residual), D-433 (exception str/pr one-liner).

- **Prior-session landings (git log is the SSOT)**: reify/instance-seq asymmetry
  class (D-422/423/426/427), Java surface D-425, the `*in*`/LispReader$StringReader
  reader subsystem (D-414) + D-428/429. This session: D-431 (above) + D-433/D-434
  filed. Discharged: D-414/421-429; open: D-418/424/430/432/433/434.

  SAFETY: every `clj` oracle batch needs `-J-Xmx2g` + bounded seqs (memory
  `clj_oracle_heap_cap`); register every new e2e in run_all.sh same-commit.

  **State**: Phase 14 (v0.1.0 milestone) ~95%. Conformance: 17 corpora golden.

- **Forbidden this session**: pushing the component-experiment artifacts or a
  relative-path `build.zig.zon` (experiment is local-only); `git push --force*`;
  bare `zig build` for any scripted/probe path (ADR-0133).

## Just landed (2026-06-14, on `main`) — cleanup + reader subsystem + instaparse chain

reify/instance-seq class CLOSED (D-422 count Counted-vs-walk + self-seq print;
D-423 reify qualified-remap; D-426 reify equiv ctor + keys/vals map-gate; D-427
element-wise `=` for Sequential deftypes, GC-rooted realize). `*in*` reader
subsystem (D-414): `*in*`+read-line+with-in-str, runtime/string_escape factor,
clojure.lang.LispReader$StringReader shim + java.util.LinkedList. Qualified
user-deftype resolution (D-428); String.subSequence (D-429). instaparse advanced
4 blockers → D-430 (deep GLL parse divergence, documented). 5 libs verified.
AD-031/032. Filed D-424/430 (open); D-414/421-429 discharged.

## Cold-start reading order (resume)

handover → **`.dev/project_facts.md` F-014** (scope goal line, user-owned) +
**ADR-0137** (its operationalisation; 0136 = sibling host-frontier ADR) → `.dev/debt.yaml` (next: D-431 completeness
gate; open: D-418/424/430/432; discharged this session: D-414/421-429) →
for the experiment: `private/notes/p14-wasm-component-experiment.md` +
`private/20260613_handover_from_zwasm/handover_v2.md`. zwasm repo =
`~/Documents/MyProducts/zwasm_from_scratch/` (read-only; HEAD ≥ `33e0100c`).
clj oracle = `~/Documents/OSS/clojure/` + `clj -J-Xmx2g -M` (`timeout 60`).
