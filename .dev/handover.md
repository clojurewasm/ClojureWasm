# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).
> Updated at session end; reads in < 30 sec at cold start.

## Resume contract

- **HEAD**: see `git log` (v5 plan + wiring landed; HEAD line refreshes
  only on Active-task-identifier change).
- **First commit on resume MUST be**: issue **ADR-0033** (placement +
  naming + transducer + var-level order) per
  `private/notes/clj_vs_zig_split_proposal_v5.md` §19.1. Devil's-advocate
  fork mandatory (depth ≥ 2 per principle.md). Reflect Alt 1/2/3 verbatim
  into `Alternatives considered`, stamp `Status: Proposed → Accepted`,
  commit ADR alone. Then proceed: ADR-0034 (build pipeline) is **deferred
  until Phase 6.16.a-1 cycle terminus** (size budget measured). ADR-0035
  (require spec) is **deferred until Phase 6.16.b cycle terminus**
  (multi-file .clj migration starts). Source-side first cycle after
  ADR-0033 lands = **Phase 6.16.a-0** (env.intern API metadata expansion,
  small prerequisite cycle per v5 §4.1 + §24.5 U-6).
- **Forbidden this session**: (a) `__zig-` namespace prefix path (v5
  §3.1 rejected; `defn-` + `-name` + `^:private :zig-leaf` metadata is
  the confirmed scheme). (b) `clojure.X.impl/` sub-ns path (v5 §3 rejected
  for取り残しリスク + 分散コスト). (c) `cljw build --source` / `--debug`
  / `--aot` flag path (v5 §11.1 confirmed single mode, flag ゼロ). (d)
  mixing human + EDN in single stderr stream (v5 §13.1 confirmed
  stream-separated TTY=human / pipe=structured EDN). (e) ABI-level
  bytecode format commitment (v5 §12.4 confirmed self-contained binary,
  decoder-only永久互換性).

## Cold-start reading order

handover (this file) → CLAUDE.md (§ Project spirit + § Autonomous
Workflow + § The only stop) → `.dev/project_facts.md` (F-001..F-009) →
`.dev/principle.md` (Bad Smell + Devil's-advocate mandate) →
**`private/notes/clj_vs_zig_split_proposal_v5.md` (placement +
build + error 確定計画 SSOT)** →
`.dev/structure_plan.md` → `.dev/ROADMAP.md` §9.8.

## Current state

- **Phase**: **Phase 6 IN-PROGRESS** — §9.8 10/16 `[x]` + 6.10 `[~]
  (7/12)` + 6.11 `[~] (3/10)`. v5 plan + ADR-0033/0034/0035 起票計画
  + ROADMAP §9.8 phase 6.16.a-0..e cycle rows + D-062..D-069 debt rows
  landed. **Active task = ADR-0033 issuance** (see Resume contract).
- **Branch**: `cw-from-scratch`. ADR-0032 issued (multi-file loader +
  in-ns). v5 plan = `private/notes/clj_vs_zig_split_proposal_v5.md`
  (1593 lines, self-contained, SSOT for ADR-0033/0034/0035).
- **Gate**: Mac 25/25 + OrbStack Ubuntu x86_64 24/24 green (last
  green at commit 329cd35; v5 + wiring is doc-only, gate unchanged).
- **Chapter cadence**: dormant per ADR-0025 + F-007.

## Active task — ADR-0033 issuance

Issue ADR-0033 (placement decision rule + `defn-`+`-name` naming +
hybrid polymorphism + transducer 先取り + var-level dependency order
+ 10 cycle migration plan + JIT independence claim) per v5 §19.1.
Devil's-advocate fork required: brief the subagent with v5 §2-§9
content + F-001/F-004/F-009 constraints, request 3 alternatives
(Alt 1 smallest-diff = 現状維持 + ad-hoc migration / Alt 2
finished-form-clean = v5 proposal / Alt 3 wildcard = sub-ns impl/
[棄却見込み]). Reflect verbatim into ADR.

After ADR-0033 lands: open Phase 6.16.a-0 cycle (env.intern API
metadata expansion — `MetadataMap{ private, zig_leaf, unsupported,
doc, arglists }`) per v5 §4.1 + §24.5 U-6.

## Open questions / blockers

None testable from inside the loop. Step 0.5 debt sweep walks
debt.md including new rows D-062..D-069 (v5 §21.1). D-062 cluster
recall trigger anchored to placement.yaml — initial scaffold landed
at `placement.yaml`, populated incrementally as cycles close.

## Guardrail refresh history (condensed)

Waves 1-12: spirit + Bad Smell + F-NNN + stop-list + ADR-0029 F-009
+ ADR-0030 + 6.1 analyzer split + ADR-0031 Accepted (Alt 2) + 6.16
cluster + silent-test-skip surgery + clock API port. **Wave 13
(2026-05-25)**: ADR-0032 multi-file bootstrap loader + `(in-ns)`
analyzer special form. **Wave 14 (2026-05-25)**: v5 placement/build/
error plan landed (`private/notes/clj_vs_zig_split_proposal_v5.md`)
+ ROADMAP §9.8 cycle rows 6.16.a-0..e + ROADMAP §9.14/16/18/19
deliverable extensions + debt.md D-062..D-069 + placement.yaml stub
+ ADR-0033/0034/0035 起票計画 (ADR-0033 immediate, 0034/0035 cycle-
terminus deferred).
