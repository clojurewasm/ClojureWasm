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

- **First task on resume**: **D-441 — `agent` ctor options `:meta`/`:validator`
  (Track R R1, next sub-unit; do-now, NOT Phase-deferred).** R1 slice 1 landed
  (concurrency clj-parity corpus `test/diff/clj_corpus/concurrency.txt`, 11/11 — ref/
  STM/future/promise/delay/agent-basic/pmap), and it SURFACED this gap: `(agent 0
  :validator number?)` → "Not implemented". Fix per D-441 (full text in debt.yaml):
  add `validator`+`meta` to the Agent extern struct (`runtime/agent.zig:88`) + GC-trace
  (l.435) + setters; `agentFn` (`lang/primitive/agent.zig:31`) parses kwargs + validates
  the initial value (mirror atom D-223); `runAction` (l.339) validates newstate before
  `@atomicStore` (reject → return error → drainer fails the agent); then re-add the
  held-out corpus line. **finished-form: add the struct fields properly, don't
  entry-patch.** Full plan + the extended-challenge 3-item bridge in
  `private/notes/p14-r1-concurrency-parity.md`.
  - **Then the rest of Track R** (the USER-DIRECTED completion-grade reorganization,
    F-015 / ADR-0141 / D-440): R1 cont. (un-defer D-242 hardening / D-244 GC-safety /
    D-245 locking-parking; load/stress) → R2 accurate-position survey → R3 ROADMAP §9
    rewrite (Phases 15-20: future → gap-areas-to-completion-grade) → R4 debt整理 (~19
    Phase-gated rows) → R5 AI-instruction 大整理. The blind Phase-deferral model is
    RETIRED; concurrency is BUILT, so harden/parity/load NOW.
  - **Reads: `.dev/project_facts.md` F-015 + ADR-0141 + D-440/D-441 + `.dev/sweep_plan.md
    § Track R`.** (Earlier-queued W1-remaining / Track S micro-units are fill-in BELOW
    Track R, not the lead.)

- **This session landed (git log = SSOT)** — Track D (the user-directed
  divergence-burden queue) DRAINED + 2 more units + W1 first slice:
  - **D1 / ADR-0139**: seq/lazy/range/Sequential-instance as a map/set KEY now
    content-hashes (rt-aware `hashDispatch`/`eqConsult` via ADR-0129 `current_env`
    + `runEnvelope` arming). D-432/D-408 discharged; nested+memoized residual → D-437.
  - **D2 / ADR-0140**: `(stack-trace e)` → cljw-shaped `{:ns :fn :file :line :column}`
    frame maps; `clojure.stacktrace` prints frames; `Throwable->map` `:trace`/`:at`
    filled. AD-029 amended, AD-033 added, D-389 discharged, D-438 (fixed the dangling
    D-232 cross-ref). **Track D D3 = Phase-15-gated (do not start).**
  - **D-223**: `(atom x & {:keys [meta validator]})` ctor kwargs (+ catalog code
    `ref_options_odd`).
  - **`clojure.core/intern`** (programmatic Var creation) — was the W1 blocker.
  - **W1 `:as` + `:refer`**: `cljw.wasm/require-component` (export = a Clojure Var);
    full WIT↔EDN marshalling table fixture-blocked → D-404.
  - **BigDecimal interop**: `.setScale` 2-arg + `.scale/.signum/.unscaledValue/
    .precision/.negate/.abs/.toBigInteger/.stripTrailingZeros` (D-223 atom kwargs too);
    movePointLeft/Right remain → D-439.
  - **yaml/yq hygiene** (user-directed): yaml_ssot_yq.md Golden-rule #4 (yq `+=` writes
    UNQUOTED ids → next-id undercount), audit recipes; fixed a stray `D-396` dup + the
    unquoted D-437/438/439 ids.
  - **F-015 / ADR-0141 / D-440 (USER-DIRECTED completion-grade reframe)** + R1 slice 1
    (concurrency parity corpus, 11/11) → see "First task on resume" above.

  SAFETY: every `clj` oracle batch needs `-J-Xmx2g` + bounded seqs (memory
  `clj_oracle_heap_cap`); register every new e2e in run_all.sh same-commit.

  **State**: Phase 14 (v0.1.0) ~95% BUT see F-015 — the phase model itself is being
  reorganized (D-440); "near-complete, strengthen gaps". Conformance: 21 corpora golden.

- **Forbidden this session**: pushing (LOCAL accumulation mode) — incl. the
  relative-path `build.zig.zon` + wasm experiment artifacts; `git push --force*`;
  bare `zig build` for any scripted/probe path (ADR-0133).

## Cold-start reading order (resume)

handover → **`.dev/project_facts.md` F-015** (the completion-grade posture — read
FIRST, it reframes everything) → **`.dev/decisions/0141_*.md`** (the reframe) →
**`.dev/debt.yaml` D-440** (reorganization epic) + **D-441** (the first sub-unit,
agent ctor options) → **`.dev/sweep_plan.md` § Track R** → `private/notes/
p14-r1-concurrency-parity.md` (D-441 plan + bridge). clj oracle =
`~/Documents/OSS/clojure/` + `clj -J-Xmx2g -M` (`timeout 60`). SAFETY: bounded seqs
+ `-J-Xmx2g`; register new e2e in run_all.sh same-commit; new debt rows via Edit
(quoted id), NOT `yq +=` (yaml_ssot_yq.md Golden-rule #4).

## Stopped — user requested

User instruction (2026-06-15): 「セッション長さで苦労しているみたいなので、現状が
すぐわかり、次のクリアセッションからcontinueで継続していけるよう、配線・参照チェーンを
監査して更新したら、止めてください」(+ 「常に finished form きれい、は心がけてね」=
F-002 reaffirmed). Wiring audited + updated: working tree clean, all SSOTs
well-formed (no dup/quote-drift), F-015/ADR-0141/D-440/D-441 + Track R + this
Resume contract all cross-resolve. **Resume = D-441 (agent ctor options), then the
rest of Track R.** This stop applies to THIS session only; the next `/continue`
resumes the loop normally (delete this section on resume per handover_framing).
