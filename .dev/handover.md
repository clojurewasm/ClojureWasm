# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT). **NO-PUSH EXPERIMENT MODE** (user-directed
  2026-06-21): the JIT adoption experiment rides a **relative-path** zwasm dep
  (`build.zig.zon` `.zwasm` = `.path = "../zwasm_from_scratch"`, NOT a SHA pin), so
  others cannot reproduce it — commits **accumulate LOCAL, un-pushed** (10 so far:
  `18c71c22`…`59eed0d7`). Do NOT `git push` until the experiment settles + zwasm cuts a
  pinnable SHA (then revert `.zwasm` to the SHA-pin form preserved in build.zig.zon's
  comment + git history). Per-commit = smoke; commit, never push.

- **First commit on resume MUST be**: a self-selected **medium clj-parity/interop row** (the
  quick-win seam is drained — see § Stopped). Highest-value live candidates: **D-466**
  (host java.util collections not recognised as `instance?` of their supertypes Map/List/Set
  — `(instance? java.util.Map (java.util.HashMap.))` → false vs clj true; sync
  interface_membership/host_interfaces) and **D-468** (java.util collections print opaquely
  `#<cljw.java.util.ArrayList>` vs clj by-content `[1 2]`). The spec arc (**D-475** + its last
  blocker **D-476** macro-shadow precedence) is the big-value-but-multi-cycle target.
  **D-404 (wasm-component epic) is COMPLETE** (A–E landed 2026-06-21/22): require-string→
  component, source-relative `./`, WIT→`:arglists`, `cljw build` single-binary embed
  (ADR-0158), classpath resolution, resource ownership (own-handle wrapper + `wasm/resource-
  drop` + `with-resource`, ADR-0159). Only the `:cljw/wasm-deps` deps.edn coordinate + OCI/wkg
  registry arm remains — **user-deferred to the future (2026-06-22)**, not self-selected.
- **Background watch (NOT the active task)**: the JIT adoption experiment is CONVERGED
  (1/2-arg invoke matrix complete, e2e-locked); its only open item is **D-488's `.auto`
  default flip**, blocked by **zwasm D-489** (x86_64-only JIT miscompile, non-urgent,
  zwasm-internal). Check the dogfooding mailbox (`to_cljw_*.md` SENT) at unit boundaries;
  flip the default when zwasm signals D-489 fixed + `.auto` 3-host green.

## Stopped — user requested

User instruction (2026-06-22): defer the wasm-deps mechanism (`:cljw/wasm-deps`/registry)
to the future; do a sweep of **only quick wins toward a tag cut**, and "if there are none,
stopping is OK". The sweep found the quick-win seam **drained** (recent sessions cleared it):
the easiest-first active rows are all DISCHARGED-misfiled (10: D-487/486/485/458/465/467/469/
481/478/348), big (D-475 spec / D-476 / D-473 reducers / D-470 `%t`), medium (D-466/468/482/
471), blocked (D-474 immutable-Date / D-488 zwasm-gated), or impossible (D-472 bytes? per
AD-019). No clean small functional quick win remained → stopped per the authorization.
Resume: self-select D-466 or D-468 (named above). Pre-tag housekeeping the user may want
first: (a) move the 10 misfiled DISCHARGED rows active→discharged; (b) restore the zwasm
SHA-pin (the relative-path dep cannot be tagged). The next `/continue` resumes the loop
normally.

- **Forbidden this session**: `git push` (no-push experiment — relative-path dep).
  Flipping the cljw default to `.auto` before D-488 clears (x86_64 JIT miscompile, D-489).
  Bare `zig build test` WITHOUT `-Dwasm` (false fails — memory `zig_build_test_needs_dwasm`).
  Bare `zig build` for a probe (ADR-0133 — ReleaseSafe). A reader-macro / syntax-quote
  NS-qualification MUST stay `rt/`, not `clojure.core/` (AD-038/AD-049).

## Last landed (git log = SSOT; LOCAL, un-pushed — relative-path experiment)

**JIT adoption experiment (2026-06-21, user-directed): zwasm's JIT-backed embedding
API adopted via a relative-path dep; 10 local commits `18c71c22`…`59eed0d7`.**
- **Engine knob**: `(wasm/load p {:engine :jit/:interp/:auto})` threaded through
  engine.zig (`EngineKind` + `LoadOpts.engine`) + surface.zig. Default pinned `.interp`
  (PROVISIONAL triad + D-488).
- **Dual-engine oracle** (F-012 applied to engine choice): engine.zig unit test +
  surface e2e `phase16_wasm_engine_select.sh` — GPR `add`, multi-value `divmod` `[3 2]`,
  same-type-2-arg f64 `addf` 3.75, MIXED-2-arg `(i32,f64)→f64` 5.5 all jit==interp; SIMD
  `lane0`→42 + `simd_dot` (i32x4.mul)→70 JIT-only (interp traps).
- **Perf demo**: `bench/wasm_jit_vs_interp.sh` — sumto 1e8 loop ≈ **~44× jit vs interp**.
- **Co-dev (6 round-trips, from_cljw_02-04 / to_cljw_02-05)**: each precise report drove a
  zwasm fix within minutes — exportFuncSig JIT arm (@5b6449779), 2-arg×FP dispatch
  (@d7da97e04), mixed-2-arg general fall-through (@3cf40a573). **1/2-arg JIT invoke matrix
  now COMPLETE**.
- **D-488** (open): the `.interp`→`.auto` default flip, now blocked by **zwasm D-489** (an
  x86_64-only JIT realworld miscompile) + the x86_64 `.auto` 3-host verdict — zwasm-internal.

## North star (now ACTIVE, not distal)

cljw's differentiator = **Wasm/edge-native (gap II) × VM-perf fusion→JIT (gap III)**.
The embedded **zwasm** JIT-backed embedding API (ADR-0200) is now **adopted** (relative-
path experiment); the perf demo proves the ~44× win. Remaining: D-488's default flip
(zwasm-gated). Live ledger + the read-at-boundaries convention: `.dev/zwasm_capabilities.md`.

## Cold-start reading order (resume)

handover → `.dev/zwasm_capabilities.md` (the live JIT-adoption ledger + capability table +
the dogfooding mailbox convention) → `zwasm_from_scratch/private/dogfooding_handover/`
(to_cljw_*/from_cljw_* mailbox; check for a `to_cljw_06`+ signal that zwasm D-489 is
fixed / `.auto` is 3-host green) → `.dev/debt.yaml` D-488 (the default-flip blocker) →
`private/notes/9.0-jit-adoption-unit.md` (the full experiment log). memory
`verify_actual_pattern_not_proxy` + `local_accumulation_sweep_phase` (the no-push mode).
