# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `08e41d4d` (clean tree, all pushed). D-144 (user-throw EDN),
  D-134 (b) range 3-arg, D-145 (`fn` macro) all landed 2026-05-29 — see
  `git log`.
- **First commit on resume MUST be**: **D-146 — the `#()` reader macro**.
  `#(< % 3)` → `Invalid token '#'` today; the anonymous-function reader
  macro is unimplemented. Now that `fn`/`fn*` exist, the reader arm
  recognises `#(` → reads the inner form → collects `%`/`%1`/`%2`/…/`%&`
  usages (max N → arity; bare `%` == `%1`) → rewrites to
  `(fn* [%1 … %&] body)`. Pervasive in real corpus (terse predicates/
  mappers) — coverage-floor (§A26 ordering: fn → #() → interop). **Step 0
  survey**: the reader (`src/eval/reader.zig`) `#`-dispatch table (how
  `#{}`/`#"regex"`/`#_` are handled), JVM `#()` reader semantics, and the
  `%`-param collection + arity inference. Pick the rewrite target (`fn*`
  vs the new `fn` macro) deliberately.
- **Forbidden this session**: re-opening D-144 / range 3-arg / D-145 `fn`
  (DONE). Re-attempting "lazy-seq Layer-2 wiring" — closed (ADR-0054).
  Bundling `fn` self-name into `#()` — self-name is the SEPARATE D-147
  (a dual-backend `fn*` extension, its own ADR-0041-style cycle).
  Flipping `phase_at_least_14` / tagging v0.1.0 (release HELD). Treating
  §9.16 `[ ]` 14.12 (deferred) / 14.14 (held) as the next task.

## Current state

Phase 14 v0.1.0 substantive work DONE; release HELD. Mac gate **108/108**
green (`/tmp/gate_fn.log` @08e41d4d). cw v1 ≈ 60-70% of cw v0's surface
in ~half the LOC; error UX (structured user-throw EDN + `*error-context*`)
+ `--compare`/`render-error` exceed v0. Coverage floor advancing:
`(fn …)` + `(range start end step)` now work. The F-010-ordered gaps
(JIT / nREPL-richness / line-editor / Wasm-Component / deps-test) stay
deferred per §A26.

## Next milestone (F-010 M = Phase 15 完遂 + cw-v0-level JIT)

Per §A26 cross-cutting ordering, finish the **coverage floor**: D-146
(`#()` reader macro, next) → interop `.`/`new`/`set!` (D-130) → D-147
(`fn` self-name) → **Phase 15** (concurrency; unblocks D-117/D-118 nREPL
richness) → superinstruction/fusion → narrow ARM64 JIT (D-133) → **M** →
quality-elevation loop (`docs/works/`, G5/G7/G11).

## Open debts (named; full rows in `.dev/debt.md`)

- **D-146** `#()` reader macro (next task). **D-130** interop
  `.`/`new`/`set!`. **D-147** `fn*` self-name slot (dual-backend; from
  D-145). **D-134** clojure.core backlog — (b) lazy ALL done; only
  `partition` 4-arg pad + JVM step-0 nicety + comp/juxt multi-arity
  remain. **D-076** destructuring (`let`/`fn*`/`fn` params). **D-143**
  apply multi-arity spread. **D-142** Env-scope `*error-context*`
  (multi-Env nREPL). **D-141** bench multi-lock anchor. **D-105/D-106**
  time/net+crypto. **D-116** REPL line-editor. **D-117/D-118** nREPL
  richness (Phase-15-gated). **D-075** metadata. **D-133** JIT floor.

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow + § The
only stop) → `.dev/project_facts.md` (esp. F-010) → `.dev/principle.md`
→ `.dev/cw_v0_parity_and_gap_plan.md` §2 + ordering note → `.dev/debt.md`
D-146 → `src/eval/reader.zig` (`#`-dispatch) +
`~/Documents/OSS/clojure` reader (`#()`) → ROADMAP §9.17 (Phase 15).
