# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` is the SSOT; ≈ 9e802816+). All work on `main`;
  commit + `git push origin main` is the atomic Step 6 (`--force*` deny-listed)
  — EXCEPT the component experiment below, which is push-suppressed by user
  directive. Full gate green 334/0 (2026-06-13). Build config is UNIFIED
  (ADR-0133 Rev 1+2): every e2e/bench/perf builder + manual probe uses
  `zig build -Dwasm -Doptimize=ReleaseSafe` (bare `zig build` = hand
  experiments only; it Debug-overwrites zig-out). Bench re-baselined under the
  unified config (bench/cross-lang-latest.yaml, 39 benches; D-411 discharged).

- **zwasm CM-API COMPLETED 2026-06-13** (marker:
  `private/20260613_handover_from_zwasm/handover.md`, COMPLETED). All 6 cw
  requests landed at zwasm pin `5795c3d0` (branch zwasm-from-scratch): REQ-1
  unified `comp.open`→`Opened`, REQ-2 enum/variant/flags VALUE labels, REQ-3
  public `resolveFuncSig`/`WitType` (replaces the hand-rolled TypeCtx), REQ-4
  budget threading, REQ-5 `dropResource` (caveat: guest destructor traps,
  zwasm D-325, doesn't block), REQ-6 typed-invoke diagnostics.

- **Component EXPERIMENT checkpoint (push-suppressed, in a git stash)**: the
  one-shot CM-API adoption WORKS (`(wasm/component-invoke …)` — greet,
  typed_payload record/list/result roundtrip, resource constructor; hand-rolled
  TypeCtx/Opened deleted, full ADR-0135 value mapping via REQ-2 labels). The
  NEXT step (instance caching → require-a-component) is BLOCKED on **zwasm
  REQ-7**: storing `comp.open`'s `Opened` in a host heap box breaks
  `resolveFuncSig` (Opened not relocatable). Finding relayed (user → zwasm):
  `private/20260613_handover_from_zwasm/cw_finding_REQ7_opened_heap_stability.md`.
  The whole experiment (relative-path build.zig.zon + engine/surface/component.zig)
  is in `git stash@{0}` ("wasm-component-experiment"); HEAD tree is CLEAN
  (tag-pin zon, builds green). **Do NOT pop the stash for normal dev** — it
  flips zon to relative-path (push-forbidden).

- **WATCH on resume**: check `private/20260613_handover_from_zwasm/` for a
  zwasm REQ-7 response (a new file / updated handover answering the
  Opened-heap-stability ask). If present → pop the stash, flip zon relative,
  re-land instance-caching per `private/notes/p14-wasm-component-experiment.md`
  (§ instance caching). If absent → continue normal dev below.

- **First task on resume MUST be** (REQ-7 absent = the default): library
  conformance track-1 — the Maven-layout deps fix (`345b1947`) unblocked old
  `src/main/clojure` contrib libs, so RE-PROBE candidates (next surfaced gap:
  `(Object.)` sentinel D-416 for data.finger-tree). OR the host_interface S1
  yaml/zig consolidation (D-415, focused small ADR, doc/gate only). instaparse
  blocked (D-414 LispReader frontier); cuerdas (D-410).

  SAFETY: every `clj` oracle batch needs `-J-Xmx2g` + bounded seqs (memory
  `clj_oracle_heap_cap`); register every new e2e in run_all.sh same-commit;
  new lib = verified_projects/<lib>/deps.edn + `lib_conformance.sh <lib>
  --oracle exprs.txt` then `--all` to regen COVERAGE.md.

  **State**: Phase 14 (v0.1.0 milestone) ~95% done. §9.16: 14.12 (component
  build) gated on zwasm REQ-7 (one-shot proven; caching blocked); 14.14
  (exit-smoke + tag) user-deferred. Conformance: 17 corpora 100% golden.

  **Paused (not abandoned)**: the §9.2.S perf campaign — resume ONLY on
  explicit user direction (state in `.dev/perf_v0_baseline.md` +
  `.dev/perf_campaign_essence.md`; edn_roundtrip ~23→~31ms drift 06-11→06-13
  in both configs is a lead to trace when it resumes).

- **Forbidden this session**: pushing the component-experiment artifacts or a
  relative-path build.zig.zon (user-directed: experiment locally first);
  re-opening the §9.2.S perf campaign as the resume DEFAULT; editing zwasm
  except via the F-001 finding-handling policy; `git push --force*`; bare
  `zig build` for any scripted/probe path (ADR-0133 Rev).

## Just landed (2026-06-13, on `main`)

re-matcher/Matcher (`379c0e9e`) + ADR-0035 D9 refer-precedence; regex `(?x)`
+ `\<non-alnum>` escape + deps absolute-`:paths` (`c7845f53`); flatland.ordered
17/17 + deftype-set contains? (`35159f41`); Maven-layout git-dep resolution +
data.generators 20/20 (`345b1947`); bare `Counted` supertype (`6865b3c0`).
D-415 host_interface finished-form right-sized to S1 (per-section attribution
proven correct); D-414 instaparse/D-416 `(Object.)` frontiers filed.

## Cold-start reading order (resume)

handover → check `private/20260613_handover_from_zwasm/` (WATCH: REQ-7
response?) → if normal dev: `private/notes/p14-flatland-ordered-contains.md` +
`private/notes/host_interface_finished_form_analysis.md` (D-415) →
`.dev/debt.yaml` (D-414/D-415/D-416). If REQ-7 landed:
`private/notes/p14-wasm-component-experiment.md` (§ instance caching) +
`.dev/decisions/0135_*.md`. zwasm repo =
`~/Documents/MyProducts/zwasm_from_scratch/` (read-only; HEAD ≥ pin 5795c3d0).
clj oracle = `~/Documents/OSS/clojure/` + `clj -J-Xmx2g -M` (`timeout 60`).

## Stopped — user requested

User instruction (2026-06-13): 「こっちはこっちで、クリアセッションから
continue で継続していけるよう、配線と参照チェーンを監査して準備して
ください。zwasm_from_scratch の方に handover は伝えました」。Wiring audited:
Resume contract above; component experiment stashed (HEAD tree clean, builds
green); zwasm REQ-7 finding relayed by the user; the next `/continue` resumes
normal dev (or the experiment if a REQ-7 response appears in the channel).
This section is history — the next session deletes it per handover_framing.md.
