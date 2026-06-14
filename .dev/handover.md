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

- **First task on resume MUST be**: continue the **Java-class completion campaign
  (D-425)** — user-directed proactive finished-form push ("よく使うJava Classは
  先回りで完備 + どういう設計で取り扱うか毎回しっかり決める"). D-425 carries the
  6-model decision-tree + the prioritized order; next unit is (a) System/setProperty
  (property store) or (b) Thread/currentThread + Runtime/getRuntime (singleton
  host_instance). Drain D-425's order highest-value-first; pick the design model
  per class and cite it in the commit. Survey: private/notes/survey-java-class-coverage.md.
  (The component experiment below remains the user's other active track; D-418/D-419
  status changed — D-419 discharged, D-418 still barrier-blocked.)

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

## Just landed (2026-06-14, on `main`) — finished-form cleanup period + Java campaign start

User-directed cleanup of asymmetries the library work surfaced (3 parallel
surveys), then the Java campaign opened. Commits: D-421 `(resolve 'Class)` +
D-420 numeric-tower close; D-419 deftype inheritance-flatten (method under a
foreign interface header); reify remap-awareness (silent-failure fix) + getFn
3-arity-default unification; host_interface yaml==zig gate (D-415 S1 closed);
System exit/lineSeparator/arraycopy (D-425 campaign unit 1). Filed D-422
(finger-tree conjl segfault), D-423 (qualified protocol name in reify), D-424
(latent class-resolution seam), D-425 (Java-completion campaign anchor).

## Cold-start reading order (resume)

handover → `.dev/debt.yaml` (D-418 / D-419 open; D-416 / D-417 / D-420 / D-421
discharged) →
for the experiment: `private/notes/p14-wasm-component-experiment.md` +
`private/20260613_handover_from_zwasm/handover_v2.md`. zwasm repo =
`~/Documents/MyProducts/zwasm_from_scratch/` (read-only; HEAD ≥ `33e0100c`).
clj oracle = `~/Documents/OSS/clojure/` + `clj -J-Xmx2g -M` (`timeout 60`).
