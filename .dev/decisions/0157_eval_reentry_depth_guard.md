# ADR-0157: Stack-overflow robustness — catchable Kind + self-calibrating native-stack guard

- **Status**: Accepted (2026-06-21) — Devil's-advocate reflected; decision revised from
  the proposed eval-entry COUNTER to a catchable Kind (2b) + self-calibrating
  stack-pointer guard (2a). **2b LANDED** (commit aaf391e3: `stack_overflow` own
  catchable Kind → StackOverflowError; re-entry + nested-eval overflows now catch).
  **2a PENDING** (the self-calibrating native-stack guard that converts the
  validator/reducer SIGSEGV to a graceful error; also fixes the same-eval
  direct-recursion-at-FRAMES_MAX catch edge) — the remaining D-485 work.
- **Deciders**: autonomous loop (differential bug-sweep finding)
- **Supersedes / relates**: D-485 (the tracking row + full mechanism trace),
  the watch-nesting partial fix (commit b69d97a9, `iref.enterWatchNotify` cap 256
  — this ADR's general fix subsumes it), ADR-0131 (the flattened in-VM call
  frame / `vm_arena`), ADR-0059 (no-JVM error model), AD-007 (cljw error Kind).

## Context

A higher-order primitive that re-enters the evaluator through a user callback
overflows the **native** Zig stack → SIGSEGV (exit 134), where JVM Clojure
raises a catchable `StackOverflowError`. Confirmed repros (all were SIGSEGV):

- `(let [a (atom 0)] (add-watch a :w (fn [k r o n] (swap! r inc))) (swap! a inc))`
- `(let [a (atom 0)] (set-validator! a (fn [n] (swap! a inc) true)) (reset! a 5))`
- `(reduce (fn f [acc x] (reduce f acc [x])) 0 [1 2 3])`

A comparator that recurses on *itself* (`(sort (fn cmp [x y] (cmp x y)) …)`) is
already graceful — it is direct VM self-recursion bounded by `FRAMES_MAX=2048`.
So only **primitive→callFn re-entry** is unguarded, not VM self-recursion.

**Mechanism** (traced in D-485): `vm.eval` (vm.zig:194) saves
`frame_base = ar.frame_top` on entry and *continues* from it — the VM frame
budget is **already global** across re-entry, and `FRAMES_MAX` (vm.zig:227 +
`flattenPush`:149) checks the global depth. Plain VM recursion is safe at 2048
because `op_call` flattens in-VM (iterative — ~1 native frame per VM frame). But
each primitive→callFn re-entry (callBuiltin→notify/validate→`invokeCallable`→
`treeWalkCall`→`callMethodImpl`→`eval`) adds ~6-10 **native** frames per ~1-2
**VM** frames, so `frame_top` **under-counts native depth** and the native stack
overflows before `frame_top` reaches 2048.

F-011 forbids cljw crashing on an input clj merely throws on; this is a
robustness gap that must close.

## Decision

Adopt the Devil's-advocate's **Alternative 2** (finished-form-clean), staged:

- **2b (land first, independent)** — give `.stack_overflow` its **own catchable
  Kind** mapping to `"StackOverflowError"` in `kindToHostClass`, NOT the current
  `.resource_exhausted` (which maps to `null` → uncatchable, and is *deliberately*
  uncatchable for the eval-budget sandbox bound — the opposite requirement). clj's
  `StackOverflowError` is catchable (`Throwable`); cljw must match
  (`(try (deep-recursion) (catch StackOverflowError _ :ok))` → `:ok`). The existing
  plain-recursion path already raises `.stack_overflow` gracefully at 2048, so 2b
  is independently testable.
- **2a (the SIGSEGV fix, the remaining D-485 work)** — a **self-calibrating
  native-stack guard** instead of a fixed counter/cap: capture the thread's stack
  base (main thread at startup, workers at spawn), and at the `vm.eval` entry
  (± `invokeCallable`) compare a stack-local address against base − a generous
  safety margin (the SpiderMonkey `CheckRecursionLimit` / CPython
  `_Py_CheckRecursiveCall` / Go `morestack` pattern). It measures the actual
  resource (native bytes remaining), so it is immune to per-primitive frame
  variance, optimization level (Debug vs ReleaseSafe), and platform (arm64 vs
  x86_64) — the cross-host SIGSEGV risk that sinks a fixed cap. It matches clj's
  "error when the stack is actually nearly full" model and **subsumes the
  watch-256 partial** (removed when 2a lands).

The originally-proposed fixed-cap eval-entry counter (Alternative 1) is REJECTED:
a single constant cannot be both ≤ native-stack/worst-frame and ≥ deepest-legit-HOF,
and it drifts across optimization level / platform — a latent cross-host crash.
Alternative 3 (trampoline primitive callbacks through the VM frame stack so
`frame_top` becomes an accurate native bound) is the eventual finished form but a
depth-4 GC-rooting surgery across every HOF primitive — recorded as forward debt
(gap-area-III primitive-calling-convention rework), not opened now.

## Alternatives considered

The following is the fresh-context Devil's-advocate critique, reflected verbatim
(per CLAUDE.md § ADR-level designs). Its central code-level finding —
`.stack_overflow` is currently uncatchable (Kind `.resource_exhausted` →
`kindToHostClass` `null`) while clj's is catchable — is what revised the decision
from Alternative 1 to Alternative 2.

> **Recommendation: Alternative 2** (self-calibrating stack guard + catchable
> `stack_overflow` with its own Kind). Removes the cap-calibration fragility,
> matches clj's stack-bound depth model far more closely than a frame-count proxy,
> and discharges the catchability F-011 divergence in the same unit rather than
> calcifying it.
>
> **Alt 1 (smallest-diff, counter at `vm.eval` entry, keep uncatchable)** — stops
> the segfault but (i) locks in the uncatchable divergence (clj programs that
> `(catch StackOverflowError _ :recovered)` would abort under cljw); (ii) counts at
> the wrong granularity (per VM activation, not per native re-entry — a
> high-variance proxy for native bytes); (iii) fixed-cap fragility: the safe value
> drifts with optimization level, platform, and any new deeper-native primitive — a
> cap calibrated on Mac ReleaseSafe can SIGSEGV on a Debug Linux gate.
>
> **Alt 2 (finished-form-clean, RECOMMENDED)** — (2a) self-calibrating stack guard:
> measure remaining native stack via a stack-local address vs the captured thread
> base, raise below a 64 KB-ish margin (the SpiderMonkey/CPython/Go pattern);
> self-calibrating, immune to frame-size/opt-level/platform variance, matches clj's
> depth model. (2b) make `stack_overflow` catchable with its OWN Kind →
> `StackOverflowError` (NOT reusing `.resource_exhausted`, which must stay
> uncatchable for the eval-budget sandbox — the two limits look alike but have
> opposite catchability requirements; the current conflation is a latent bug). Cost:
> per-thread stack-base capture (workers capture at spawn) + a portable
> remaining-stack read (`@frameAddress()`); the safety margin is one *one-sided
> over-estimable* number, far less fragile than a two-sided cap.
>
> **Alt 3 (wildcard, trampoline)** — re-express every HOF primitive's callback as
> "push a VM frame, yield to the iterative `eval` loop, resume with the result" so
> primitive re-entry costs ~1 native frame per VM frame and the existing
> `FRAMES_MAX=2048` becomes an accurate native bound (no new limit). Most
> finished-form-pure and likely a perf win (D-450), but a depth-4 CPS transform of
> the primitive layer touching the GC-rooting surface (the reduce accumulator moves
> from a native local to a collector-walked VM slot). Right *eventual* shape when
> the JIT/fusion work re-touches the calling convention; over-reach now.
>
> **(a) chokepoint**: `vm.eval` entry is a correct *counter* floor but wrong
> *granularity* (counts all activations equally); `invokeCallable` is the narrower
> primitive-re-entry-specific site. The stack-pointer guard dissolves the question —
> it measures the resource directly; site it at `vm.eval` entry for coverage ±
> `invokeCallable` for earlier detection.
> **(b) self-calibration**: a stack-remaining guard relocates the one constant from
> a two-sided tightrope cap to a one-sided over-estimable margin. (A guard page is
> the OS-level version but fragile across the GC's own signal use + the Wasm-edge
> target; the explicit SP check is the portable no-signal form.)
> **(c) catchability**: in-scope, non-optional. `.stack_overflow` Kind
> `.resource_exhausted` → `kindToHostClass` `null` → uncatchable; clj's is
> catchable. Must give stack-overflow its OWN Kind → `StackOverflowError`, distinct
> from the (correctly-uncatchable) eval-budget bound. Land 2b first (independently
> testable), then 2a.
> **(d) depth vs clj**: a frame *count* cap is a coarse proxy for clj's
> JVM-stack-bytes model and is pessimistic (counts non-primitive nested evals too);
> the stack-pointer guard errors "when the real stack is nearly full" = clj's model
> off only by the margin. Alt 3 matches exactly (same 2048 limit as plain
> recursion) at depth-4 cost.

## Consequences

- **Positive**: (2b) `stack_overflow` becomes catchable, matching clj — closes the
  F-011 catchability divergence the DA surfaced. (2a) no input crashes the process;
  all unbounded callback recursion errors gracefully, self-calibrated to the real
  native stack (no cross-host cap fragility); subsumes the watch-specific partial.
- **Negative**: (2a) per-thread stack-base capture is more plumbing than a
  threadlocal counter (workers capture at spawn); a portable remaining-stack read
  (`@frameAddress()`) + one over-estimable safety margin remain.
- **Follow-up**: Alternative 3 (trampoline primitive callbacks → `frame_top`
  accurate) recorded as forward debt for the gap-area-III primitive-calling-
  convention rework.

## Affected files

- **2b**: `src/runtime/error/catalog.zig` (stack_overflow → own catchable Kind) +
  `src/runtime/host_class.zig` (Kind → `"StackOverflowError"`) + an e2e asserting
  `(catch StackOverflowError …)` works.
- **2a**: `src/eval/backend/vm.zig` (capture stack base + remaining-stack check at
  `eval` entry ± `invokeCallable`) + `src/runtime/iref.zig` +
  `src/lang/primitive/atom.zig` (remove the subsumed watch-nesting partial) +
  `test/e2e/phase15_watch_recursion.sh` (extended: validator + reducer repros).
- `.dev/debt.yaml` — D-485 discharged when 2a lands; a new forward-debt row for
  Alternative 3.
