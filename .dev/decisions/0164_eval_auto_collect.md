# ADR-0164 — Threshold-driven auto-collect during eval (BOTH alloc-boundary + VM back-edge), within mark-sweep

- **Status**: Proposed → Accepted → **IMPLEMENTED + GO-PASSED** (2026-06-24; D-450 gc_alloc_rate root cause; DA-fork folded verbatim below). The BOTH-sites auto-collect landed at 4MB default + the `CLJW_GC_THRESHOLD_MB` knob; the load-robust OFF-vs-ON A/B (interleaved hyperfine, 20 runs) passed decisively — see **§ GO result** below. The DA's predicted "partial win" was too conservative: ON is FASTER than OFF on all 8 measured benches (1.12–1.65×), the `string_ops` canary INCLUDED (1.28× faster, not slower).
- **Driven by**: D-450's surviving fastest-script gap `gc_alloc_rate` (cljw 45.3ms / bb 39.9ms = 1.14×). Root-caused load-independently via the new `CLJW_GC_STATS=1` counter (committed 07176327): a tight allocating loop shows **reuse=0%, collects=0** — cljw runs **NO threshold-driven auto-collect during eval**, so it mallocs unboundedly (1.28GB for 4M short-lived vectors) and never reuses the free pool, while Babashka wins via JVM TLAB-bump + young-gen collect-and-reuse. This is BOTH the gap AND a latent **memory bug** (default `heap_ceiling=null` → no cap + no auto-collect → a real allocating loop OS-OOMs).
- **Relates to**: F-006 (GC = mark-sweep + 3-layer allocator; a moving/generational/nursery GC is a SEPARATE deferred unit — D-518 / the moving-GC unit), F-004 (NaN-box absolute pointers — non-moving collect), F-011 (GC timing not observable), F-002 (finished-form wins). ADR-0028 (mark-sweep + free-pool + adaptive threshold), ADR-0090 (STW safe-points), D-352/D-361 (the `heap_ceiling`/`checkInfraCap` alloc-boundary memory check this complements), the `CLJW_GC_TORTURE_ALLOC` validation path (the proven template).

## Context

`gc_heap.zig::alloc` already carries, at the alloc boundary (roots quiescent — the new object does not exist yet): a worker safe-point park, the `CLJW_GC_TORTURE_ALLOC` collect path (gated on a torture period), the `heap_ceiling` REFUSE check (D-352/D-361 — placed here precisely because a Zig primitive can allocate megabytes without crossing a VM back-edge), and `bytes_since_last_gc += size`. The adaptive threshold (`threshold_bytes = max(1MB, last_live*2)`, reset to 0 by each collect, mark_sweep.zig:171-175) exists but **nothing checks `bytes_since_last_gc > threshold_bytes` during normal eval** — only an explicit collect, torture, or a peer worker's STW request runs the GC. The VM back-edge poll (`vm.zig:305`, run once per bytecode instruction via `stepOnce`) checks only `safepoint.gc_requested` (a peer's request), not the heap threshold.

## Decision

Add threshold-driven auto-collect at **BOTH** sites (the DA's Alt 2 — finished-form), within F-006 mark-sweep (non-moving, no nursery):

1. **Alloc-boundary** (`gc_heap.zig::alloc`, beside the existing `heap_ceiling` check): when `bytes_since_last_gc > threshold_bytes` AND `fabrication_depth == 0` AND not a registered worker / in-torture AND a live `active_env`, run `collectStopTheWorld` — the `CLJW_GC_TORTURE_ALLOC` path VERBATIM, threshold-gated instead of period-gated. This is the **completeness floor**: it catches bulk-primitive allocation (`(vec (range 1e6))`) that never crosses a VM back-edge — the SAME rationale (and SAME boundary) as the `heap_ceiling`/`checkInfraCap` memory check it complements (its *collecting* twin).

2. **VM back-edge poll** (`vm.zig:305`, beside the existing `gc_requested` poll): the same threshold check. This is the **cheap tight-loop path**: a `recur` loop back-edges every iteration but allocs once, so the common case pays the threshold compare on the already-paid poll branch (cleaner safe-point: `sp`/`op_top` settled, `fabrication_depth==0` by construction). The shared `bytes_since_last_gc` reset (collect sets it to 0) keeps the two sites idempotent — no double-collect.

3. **Raise `default_gc_threshold_bytes` 1MB → 4MB** + add a `CLJW_GC_THRESHOLD_MB` env knob. For a churn workload `last_live≈0` so the adaptive `max(1MB, last_live*2)` arm is inert → the initial threshold IS the operative number; 4MB gives ~16 collects vs ~64 (same total sweep work, fewer STW fences) at negligible memory cost. The adaptive arm is unchanged (correct for growth workloads).

4. **Keep `CLJW_GC_TORTURE_ALLOC` in the gate.** Threshold-driven is a WEAKER completeness probe (the 1MB/4MB cadence can step over a 2-alloc-unrooted window for years; torture fires frequently enough to catch it). Threshold ships ALONGSIDE torture, never instead.

5. **Implementation + GO is a SEPARATE next unit needing a QUIET Mac.** The change alters WHEN the GC fires for EVERY allocating program. Correctness is load-independently validatable (diff oracle + `CLJW_GC_TORTURE` + `CLJW_GC_STATS`: collects>0 / reuse>0 / bytes bounded). But the KEEP/REVERT decision (experiment-and-revert) is **wall-clock-gated**: a now-firing mid-bench collect could REGRESS one of the 7 fastest-script benches the cold-start arc just won — **`string_ops` is the canary** (continuous string alloc → crosses the threshold → new STW cost). A count proxy (collects>0) is INSUFFICIENT (it hides the wall-cost). GO requires a before/after wall-clock re-run of all 7 won benches on a ReleaseSafe binary (a quiet Mac; the won/lost margin is ms); raise the threshold until every won bench holds. **Do not commit the implementation until that wall-clock GO passes.**

## Consequences

- Fixes the latent **unbounded-alloc memory bug** decisively (any allocating loop now collects at the threshold instead of growing until OS-OOM) — the more important half.
- **Partial** `gc_alloc_rate` perf win, NOT full closure. Honest framing (DA PT5): collect+reuse trades malloc-storm for pool-reuse + per-threshold mark+sweep; it narrows but likely does not fully close 1.14× — bb's edge is bump-allocation (no malloc, just pointer-increment), which is the DEFERRED nursery unit (Alt 3, out of F-006 scope). The last slice of the gap awaits that unit. **(Measured — see § GO result: the wall-clock win was LARGER than this prediction; the OFF-vs-ON A/B shows ON beat OFF 1.39× on gc_alloc_rate itself, 49→35ms, because collect+reuse also wins cache/page-fault locality. Whether cljw fully beats bb's bump-allocator still awaits a quiet-Mac peer re-rank + possibly the nursery.)**
- A global GC-timing change: re-validated by the wall-clock all-bench gate (§5) before it ships.
- `gc_large_heap` (already a cljw win) and any &gt;threshold-retention workload may shift; the wall-clock gate covers them.

## GO result (2026-06-24) — KEEP, decisively

Implemented as a shared `GcHeap.maybeAutoCollect()` (the torture-alloc collect verbatim,
gated on `bytes_since_last_gc > threshold_bytes`) called from BOTH sites: the `alloc`
boundary (after the torture block, before `lockMutex`) and the VM back-edge poll
(`vm.zig`, after the torture poll). Default floor 1MB→4MB via a new per-heap
`threshold_floor_bytes` field (so `CLJW_GC_THRESHOLD_MB` survives each collect's recompute);
torture kept in the gate.

**Load-independent validation (conclusive):**
- Diff oracle (`zig build test -Dwasm`, ReleaseSafe) green, no failures.
- `CLJW_GC_STATS`: 200K vectors → collects 0→**15**, reuse 0%→**93%**, mallocs 401K→**27,335**;
  4M vectors → collects **305**, reuse **99%**, mallocs **27,335 (FLAT)** = memory bounded
  regardless of loop size (was 1.28 GB unbounded — the latent OS-OOM bug, fixed decisively).
- Rooting: the 15/305 auto-collects fire MID-EVAL yet the sums are mathematically exact
  (`20000300000` / `8000006000000`); torture-alloc on the bench + `(+ 1 1)` clean.

**Wall-clock GO — the load-robust OFF-vs-ON knob A/B** (same ReleaseSafe binary,
`CLJW_GC_THRESHOLD_MB=1000000` = auto-collect off ≈ pre-D-519, vs default 4MB = on;
interleaved hyperfine 20 runs/5 warmup, so transient load hits both equally):

| bench               | OFF (no auto-collect) | ON (4MB)    | ON faster  |
|---------------------|-----------------------|-------------|------------|
| gc_alloc_rate       | 49.2 ± 4.3 ms        | 35.4 ± 0.6 | **1.39×** |
| string_ops (canary) | 27.3 ± 5.5           | 21.3 ± 0.3 | **1.28×** |
| sieve               | 21.9 ± 4.7           | 17.4 ± 0.6 | 1.26×     |
| map_filter_reduce   | 16.2 ± 6.6           | 9.8 ± 0.3  | 1.65×     |
| gc_large_heap       | 35.9 ± 1.2           | 31.9 ± 0.5 | 1.12×     |
| destructure         | 57.2 ± 7.1           | 50.5 ± 1.4 | 1.13×     |
| nested_update       | 14.7 ± 1.2           | 10.9 ± 0.2 | 1.35×     |
| bigint_factorial    | 21.9 ± 1.1           | 17.8 ± 0.4 | 1.23×     |

ON is faster on EVERY bench AND ~10× lower variance (σ 0.3–1.4 vs 4–7). The mechanism the
DA under-weighted (PT5): collect-and-reuse keeps the working set small → far fewer page
faults / malloc syscalls / cache misses, which OUTWEIGHS the mid-bench STW cost — so the
"the single most likely regression" (string_ops, PT2) instead IMPROVED. No threshold
tuning was needed; 4MB holds across the board. The separate **absolute peer re-rank** (does
cljw beat bb on the 9) is a campaign-standing question needing a genuinely quiet Mac (a
cross-run peer measure at load ~4 was contamination-noisy) — NOT a D-519 blocker, since the
A/B proves D-519 strictly improves cljw's own numbers.

## Alternatives considered

The DA red-team output (fresh-context subagent, grounded in `gc_heap.zig` / `vm.zig` / `mark_sweep.zig` / `vector.zig` / `root_set.zig`) is reproduced verbatim. Its verdict drove the Decision (BOTH sites over the proposed alloc-only; the wall-clock GO gate; the honest partial-win framing; keep-torture).

> **Code grounding.** `alloc` (gc_heap.zig:345-423): park → `torture:` block (the template) → gc_mutex → heap_ceiling check → free-pool pop / rawAlloc → record + `bytes_since_last_gc +=`. `fabrication_depth>0`, `is_registered_worker || in_alloc_torture`, `active_env orelse break` guards all already present. `vm.zig:297-324`: `while(true)` runs ONE `stepOnce` per iteration (line 326); the back-edge poll (`gc_requested`→park, line 305) + the torture safe-point collect (322-324) are at the loop TOP → once per bytecode op, including right after `op_recur_loop` jumps. `op_vector_literal` (1298-1311) → `fromSlice`, elements rooted on the operand stack (op_top), bracketed by `enterFabrication`/`exitFabrication` (18 fabrication sites). Adaptive threshold (mark_sweep.zig:171-175): `max(1MB, last_live*2)`, `bytes_since_last_gc=0`.
>
> **Alt 1 — smallest-diff: back-edge-poll-only.** Don't touch `alloc`; at vm.zig:305 add `if (bytes_since_last_gc > threshold_bytes) collectStopTheWorld(...)` beside the `gc_requested` poll. Better: maximally clean safe-point (sp/op_top settled, fabrication_depth 0 by construction); zero `alloc` hot-path change → no won-bench alloc regression; rides infra the torture campaign already validated at vm.zig:322. **Fatal gap**: a Zig-primitive bulk alloc that never crosses a back-edge (`(vec (range 1e6))` = one op, `fromSlice` does N×alloc internally) is never collected → re-opens the D-361 OS-OOM hole `checkInfraCap` exists to close; also does nothing for TreeWalk (no stepOnce loop). F-compliant but under-delivers the memory-bug half.
>
> **Alt 2 — finished-form: BOTH (alloc-boundary + back-edge).** The proposal PLUS Alt 1, clean division: alloc-boundary = the completeness floor for bulk primitives (same boundary + rationale as the existing heap_ceiling at gc_heap.zig:387-391); back-edge = the cheap tight-loop path (recur back-edges every iter, allocs once → triggers here first, cheaper). Shared `bytes_since_last_gc` reset → idempotent. Better: the ONLY shape closing BOTH halves — the tight-loop gap AND the bulk-primitive OOM — mirroring the existing heap_ceiling/checkInfraCap two-site pattern (finished-form-consistent); robust to backend (TreeWalk has no back-edge, alloc-boundary still fires). Risk: largest diff (two sites); double-collect risk mitigated by the shared reset (needs a test: one recur iter that both back-edges + allocs doesn't collect twice); the alloc-boundary mid-op state audit is the SAME the proposal needs, +no new surface (the back-edge site is strictly safer). F-002: do NOT pick the smaller diff (Alt 1) when the larger is the complete form — Cycle-budget-defer smell.
>
> **Alt 3 — wildcard: free-pool-prewarm + bump arena (attack reuse=0%, not collect cadence).** A size-segregated bump arena for the dominant small-vector size class, auto-collect only as a high-threshold backstop. Better: directly attacks the measured reuse=0% + is the structurally-faithful answer to "why is bb faster" (TLAB bump, not collect-frequency). **Borderline-VIOLATES F-006**: introduces a nursery/bump tier F-006 reserves for the separate deferred moving-GC unit; a bump arena that never individually frees needs moving compaction (F-004 violation) or a mark-sweep over the arena (square one). Leading would-violate-F-NNN finding: the genuinely-fastest path (bump allocation) needs the deferred GC work — OUT OF SCOPE for an in-mark-sweep fix; the loop should NOT take Alt 3 now.
>
> **PT1 — alloc vs back-edge vs BOTH.** The back-edge poll EXISTS in the hottest path (vm.zig:305, once per op) but checks only `gc_requested` → a threshold check there is 1 line. BOTH is forced by the existing heap_ceiling/checkInfraCap split: the codebase ALREADY decided memory-bounding lives at the alloc boundary because bulk primitives skip back-edges; auto-collect is its collecting twin → same boundary. But the tight-recur bench back-edges every iter → the back-edge poll catches it first + cheaper. Alloc-only (proposal) pays a per-alloc compare + fires mid-op; back-edge-only re-opens bulk-primitive OOM. **Verdict: proposal (alloc-only) is 2nd-best; Alt 2 (BOTH) is finished-form. Do not ship alloc-only citing diff budget.**
>
> **PT2 — global-effect risk + proving no regression.** `alloc` is NOT entered in a non-allocating loop (integers are NaN-box immediates) → zero cost there; the per-alloc branch (where alloc happens) is the same shape as the existing heap_ceiling null-check (negligible). The REAL risk is the now-firing COLLECTS: `string_ops` allocates strings continuously → crosses 1MB → auto-collect fires mid-bench → STW mark+sweep wall-time the won measurement never paid = **the single most likely regression**. `nested_update`/`map_filter_reduce` similar; `gc_large_heap` may improve (bounded) or regress (collect overhead). **A count proxy (collects>0) is NOT sufficient** — it shows GC fired, not the wall-cost; the margin is ms (45.3 vs 39.9). **Wall-clock re-run of all 7 benches via `bench/compare_langs.sh`, before/after, ReleaseSafe (the Debug cliff masks the signal), is MANDATORY.** Count is a secondary localizer (a bench newly showing collects>0 is the one to scrutinize). Acceptance: no won bench regresses past the loss line; if string_ops regresses, raise the threshold (PT4).
>
> **PT3 — correctness of mid-`alloc` collect at threshold cadence.** Threshold fires rarely (~1MB) vs torture's every-N → exercises FEWER distinct mid-op states but the SAME KIND (collect at the alloc boundary, before the new object exists) — a strict subset of what torture drives. The proposal's "structure is proven" is correct (same guard set: fabrication_depth, gc_self_guard, active_env, operand-stack/op_top root walk). Residual risk: a NEW Zig primitive that calls `gc.alloc` twice with an unrooted intermediate between, forgetting BOTH brackets — torture catches it (frequent), threshold MIGHT NOT (1MB cadence steps over the 2-alloc window for years). **So threshold is a WEAKER completeness probe → must NOT replace the torture gate; keep `CLJW_GC_TORTURE_ALLOC`.** The bench itself is SAFE (4 immediate-int elements, fromSlice brackets fabrication, rooted on operand stack).
>
> **PT4 — threshold tuning.** 1MB / 64MB-bench = ~64 collects, each O(allocs-since) sweep over the grown `gc.allocations` (~64K records/collect → ~4M sweep iters total) — real but bounded, replaces unbounded malloc. 4MB = 16 collects, same total sweep work, fewer mark-phase fixed costs + STW fences, +3MB peak (trivial) → strictly better on collect-overhead. The adaptive `last_live*2` is INERT for churn (last_live≈0 → stays 1MB); it only engages on growing-retention. **Raise the floor to 4MB (or a `CLJW_GC_THRESHOLD_MB` knob); leave the adaptive arm.**
>
> **PT5 — is auto-collect even the right lever? (honest verdict).** Post-collect, `alloc` pops the free pool (cheaper than malloc but not free; keyed on exact size class — holds for the 1-size-class bench). Net = trade N mallocs for N pool-pops + (N/threshold) collects; positive only if (malloc−poolpop)×N > collect×(N/threshold), tilted positive by a larger threshold. **Honest verdict: likely bounds memory + MODESTLY improves alloc rate, but will NOT reliably close the full 1.14× (need ~12% off).** bb's edge is bump-allocation (Alt 3 / deferred nursery). **Do not over-promise: frame as "bounds memory (the real bug) + partial perf win; full closure awaits the nursery."**
>
> **Recommended shape + sequencing.** (1) Ship Alt 2 (BOTH), not alloc-only, not back-edge-only. (2) Raise default threshold to 4MB + `CLJW_GC_THRESHOLD_MB` knob; keep adaptive arm. (3) Keep `CLJW_GC_TORTURE_ALLOC` in the gate. (4) Gate on wall-clock re-run of all 7 won benches (ReleaseSafe, before/after); `string_ops` is the canary; `CLJW_GC_STATS` reuse%/collects as secondary signals. (5) Frame the perf claim honestly (memory bug fixed + partial win; full closure = deferred nursery).
>
> **The ONE thing most likely to make this a mistake.** A won bench regresses on WALL-CLOCK because auto-collect now fires mid-bench and the STW mark+sweep exceeds the malloc savings — HIDDEN by a count proxy (collects=2-3 looks innocuous). `string_ops` is the danger. If validated by collect-count instead of wall-clock, this ships green and silently regresses a bench the cold-start arc just won. **Mitigation non-negotiable: wall-clock re-run, ReleaseSafe, raise the threshold until every won bench holds.** The secondary danger (a future 2-alloc primitive forgetting its fabrication bracket, stepped over by the 1MB cadence — PT3) is real but deferred-detectable; the bench regression is immediate + more probable.

Main-loop choice WITHIN the F-NNN envelope (the subagent's recommendation is not binding): adopted Alt 2 (BOTH) + the 4MB threshold + keep-torture + the honest framing + the mandatory wall-clock GO gate in full. Alt 3 (bump nursery) is recorded as the would-violate-F-006 finding and correctly deferred to the moving-GC unit. The implementation + the wall-clock GO is a separate unit requiring a quiet Mac (Decision §5) — NOT committed under host load on a count proxy (the DA's #1 mistake).
