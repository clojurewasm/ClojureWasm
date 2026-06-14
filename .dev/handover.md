# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` is the SSOT; ≈ `0c1a4e30`+). All work on `main`;
  commit + `git push origin main` is the atomic Step 6 (`--force*` deny-listed).
  Full-gate baseline 334 pass (2026-06-13); 1 known load-flaky (D-418, green
  standalone). Build config UNIFIED (ADR-0133): every e2e/bench/probe uses
  `zig build -Dwasm -Doptimize=ReleaseSafe` — bare `zig build` = Debug and
  Debug-overwrites zig-out, so it is for hand experiments only.

- **First task on resume MUST be**: self-select the next unit (the user-directed
  work is COMPLETE — see below). The clean/obvious feature work has run low, so
  per § The only stop raise precision via QUALITY work: the standing candidates
  are D-425's niche follow-ups ONLY on a real consumer (StandardCharsets value,
  char[] String ctor, Reader/`*in*` subsystem per D-414, Date setTime/toString,
  general-seqable ArrayList ctor), the quality-loop floor tail (D-086/088/173/
  183-189/232), D-422 (finger-tree conjl segfault — a real bug, needs a recursion
  trace), or a new conformance lib. None is high-value; pick finished-form-first.
  The component experiment (git stash@{0}) remains the user's other active track.

- **Directed work DONE (2026-06-14, comprehensively validated)**: (1) finished-form
  cleanup of library-surfaced asymmetries; (2) proactive completion of the
  commonly-used Java surface (D-425). Full gate 345/345, conformance 13/13, no
  regression. Java surface complete: System / exception-ctors / Thread / Runtime /
  StringBuilder / ArrayList / HashMap / Date / String⇄bytes.

- **Component experiment (push-suppressed, in `git stash@{0}`)**: zwasm REQ-7
  LANDED (pin `33e0100c`; channel `private/20260613_handover_from_zwasm/
  handover_v2.md` COMPLETED — root cause was input-buffer lifetime, not
  relocatability; the opened handle now owns its bytes). Instance caching is
  RE-LANDED + VALIDATED: `(wasm/load-component p)` + `(wasm/component-call h …)`
  — greet roundtrips across calls AND the resource chain works (ctor own-handle
  → method borrow: counter 5 → increment 6 → get 6). The D-404 / ADR-0135
  substrate is proven. Stashed to keep the tree clean (relative-path zon is
  push-forbidden). Next layer = require-as-namespace (one callable per export —
  needs a closure/Var-interning design) + dropResource GC-finaliser (D-325 also
  fixed at zwasm `65a760e2`). Re-land: pop the stash, flip zon relative, build
  `-Dwasm`. Notes: `private/notes/p14-wasm-component-experiment.md`.

  SAFETY: every `clj` oracle batch needs `-J-Xmx2g` + bounded seqs (memory
  `clj_oracle_heap_cap`); register every new e2e in run_all.sh same-commit.

  **State**: Phase 14 (v0.1.0 milestone) ~95%. Conformance: 17 corpora golden.

- **Forbidden this session**: pushing the component-experiment artifacts or a
  relative-path `build.zig.zon` (experiment is local-only); `git push --force*`;
  bare `zig build` for any scripted/probe path (ADR-0133).

## Just landed (2026-06-14, on `main`) — cleanup period + Java campaign (20 commits)

CLEANUP (3 parallel surveys → fixes): D-421 `(resolve 'Class)`→class value +
D-420 numeric-tower close; D-419 deftype inheritance-flatten; reify remap-
awareness (silent-failure) + getFn 3-arity-default unification; host_interface
yaml==zig gate (D-415 S1). JAVA (D-425, each w/ a recorded design model): System
(8 methods, +rt property store) / 8 exception ctors (comptime family) / Thread+
Runtime singletons / ArrayList + HashMap (host_instance, GC-traced, seq bridge,
ctor-from-coll) / Date ctor+getTime / String⇄bytes. AD-031 (ratio narrowing) +
AD-032 (host-coll seq entry). Filed D-422/423/424/425.

## Cold-start reading order (resume)

handover → `.dev/debt.yaml` (D-418 / D-419 open; D-416 / D-417 / D-420 / D-421
discharged) →
for the experiment: `private/notes/p14-wasm-component-experiment.md` +
`private/20260613_handover_from_zwasm/handover_v2.md`. zwasm repo =
`~/Documents/MyProducts/zwasm_from_scratch/` (read-only; HEAD ≥ `33e0100c`).
clj oracle = `~/Documents/OSS/clojure/` + `clj -J-Xmx2g -M` (`timeout 60`).
