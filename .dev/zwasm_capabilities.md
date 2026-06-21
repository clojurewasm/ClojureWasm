# zwasm capability ledger — cljw's view of the embedded Wasm runtime (F-001)

> **SSOT for "what does the zwasm we embed offer, and what has cljw adopted".**
> cljw embeds **zwasm v2** (F-001, unavoidable). The dep is normally a SHA pin, but
> is currently a **relative-path experiment** (`.path = "../zwasm_from_scratch"`,
> user-directed 2026-06-21, no-push — see § Pin). zwasm is itself under active
> co-development (`~/Documents/MyProducts/zwasm_from_scratch`, branch
> `zwasm-from-scratch`) and its embedding API is *growing* — notably a **JIT-backed
> engine** (the cljw north star, ROADMAP §9.0 gap area II × III), whose adoption is
> now IN PROGRESS. This file is the durable record so the loop never re-derives
> "is zwasm's JIT ready yet?" from scratch.

## The read-at-boundaries convention (why this file exists)

The cljw loop **cannot infer zwasm's status from its own tree** — the pin is frozen
at one commit while zwasm moves on. So, at every **gap-area-unit start** (CLAUDE.md
Step 1a) **and every Phase boundary**, the loop MUST:

1. Read THIS file (cljw's recorded view + adoption status).
2. Refresh it against zwasm's **live** status sources (below). If zwasm shipped a
   capability cljw's north star needs, update the table here + decide adoption.
3. Treat a capability as **adoptable only when zwasm marks it ready AND cljw bumps
   the pin** (`build.zig.zon`) — never adopt against an unpinned/moving API.

This is the cljw-side, git-tracked face of the **dogfooding handover protocol**
(simplified, no-loop, 2-state — `dogfooding_handover/PROTOCOL.md` below). **Also at
each unit boundary (after a commit, before the next Step 0), check the INBOX**
(`to_cljw_*.md` with `Status: SENT`); handle it, then flip to `CONSUMED`. When cljw
needs a not-yet-ready zwasm capability, the request goes out as a `from_cljw_NN.md`
(finished-form, request-don't-workaround; mark the dependent cljw task PENDING), never
a cljw-side shim.

## zwasm live status sources (read these to refresh the table)

| Source                                                                   | What it tells you                                              |
|--------------------------------------------------------------------------|----------------------------------------------------------------|
| `~/Documents/MyProducts/zwasm_from_scratch/private/dogfooding_handover/` | **the mailbox** — `PROTOCOL.md` + `from_cljw_NN`/`to_cljw_NN` |
| `~/Documents/MyProducts/zwasm_from_scratch/.dev/ROADMAP.md`              | zwasm phase plan (p17 = JIT)                                   |
| `~/Documents/MyProducts/zwasm_from_scratch/.dev/decisions/0200_*.md`     | ADR-0200 — JIT-DEFAULT engine + research-driven API           |
| `git -C ~/Documents/MyProducts/zwasm_from_scratch log --oneline -15`     | recent JIT work (zwasm#477 multi-arg invoke arm64/x86_64)      |

## Pin

- **RELATIVE-PATH EXPERIMENT mode (user-directed 2026-06-21).** `build.zig.zon`
  `.zwasm` is now `.path = "../zwasm_from_scratch"` (was the SHA pin
  `412966f7…`). The JIT readiness signal arrived (`to_cljw_02`, embedder-stable
  @ `9fcf9fb5b`+), so the JIT adoption unit is live; the user directed consuming
  zwasm's live tree by relative path to experiment with JIT/SIMD reproducibly
  **locally**. A `.path` dep is NOT reproducible for others, so cljw commits
  **accumulate un-pushed** until the experiment settles and zwasm cuts a
  pinnable SHA/tag — then this reverts to the SHA-pin form (the URL+hash live in
  git history / the `build.zig.zon` comment).
- `lazy` dependency: the default build + gate never resolve it; only `-Dwasm` /
  `-Dzwasm-spike` do. So a churning dep never breaks the day-to-day gate — it
  only gates what `cljw.wasm/*` can do. (Caveat in this mode: the wasm e2e steps
  now require the sibling `../zwasm_from_scratch` tree again, so they won't run on
  ubuntunote until the pin is restored — acceptable while un-pushed.)
- Pin-bump (back to SHA): zwasm `docs/consuming_prerelease_zwasm.md`. Re-pin is
  **user-gated** (a moving north-star API; the loop proposes, the user confirms).

## Capability table (refresh at each boundary)

| Capability                           | zwasm status (as of 2026-06-21)                                                                         | in cljw's tree? | cljw adoption                                                                 | ref          |
|--------------------------------------|---------------------------------------------------------------------------------------------------------|-----------------|-------------------------------------------------------------------------------|--------------|
| Interp embedding (load/instantiate)  | ready                                                                                                   | YES             | integrated behind `cljw.wasm/*` (-Dwasm)                                      | F-001, D-036 |
| `invoke` (call exported fn)          | ready (interp + JIT)                                                                                    | YES (rel-path)  | integrated; JIT `invoke` verified via unit test                               | D-036, D-488 |
| Embedder hardening / WASI sandbox    | landed (security pass `…→6b08fe70`, 3-host green)                                                     | mostly          | consumed (old security mailbox)                                               | CODEV        |
| **Multi-arg JIT invoke (≤5/7 GPR)** | **ready** (embedder-stable, to_cljw_02 matrix)                                                          | YES (rel-path)  | exercised by the dual-engine unit test                                        | to_cljw_02   |
| **SIMD (v128) body on JIT**          | **ready** (JIT-only by design; interp has no v128 dispatch)                                             | YES (rel-path)  | verified (lane0→42 on .jit); interp traps catchably                          | D-488        |
| `exportFuncSig` on JIT instance      | **ready** (JIT arm shipped @5b6449779, to_cljw_03)                                                      | YES (rel-path)  | adopted — explicit `:jit` `wasm/call` works end-to-end (e2e)                 | D-488        |
| FP-bank scalar JIT invoke (f32/f64)  | **ready** (1/2-arg matrix COMPLETE @3cf40a573 — veneer→generic-buffer fall-through; 3-arg via buffer) | YES (rel-path)  | adopted — `:jit` covers all 1/2-arg scalar (incl. mixed) + 3-arg; e2e-locked | D-488        |
| **JIT-backed engine (`.auto`)**      | **OFF (interp)** — blocked by zwasm D-489 (x86_64-only JIT realworld MISCOMPILE, tinygo_json)          | YES (rel-path)  | default pinned `.interp` (zwasm-endorsed); `:jit` explicit solid on arm64     | D-488        |
| WIT component marshalling            | future                                                                                                  | NO              | NOT adopted                                                                   | D-404        |

## Forward plan — the JIT adoption unit (gap area II × III) — ACTIVE

The north-star capability is **running Wasm components through zwasm's JIT engine**
from cljw. The trigger has FIRED (to_cljw_02, 2026-06-21) and adoption is in progress:

1. **Trigger (DONE)**: zwasm shipped the embedder-stable JIT engine (`to_cljw_02`);
   cljw switched the dep to relative-path (user-directed experiment, no-push).
2. **cljw action (DONE this cycle)**: threaded `:engine :jit/:interp/:auto` through the
   finished-form `(wasm/load path opts)` surface; interp kept as the default; landed a
   dual-engine diff oracle (unit + e2e) per the F-012 discipline. Explicit `:jit`
   `wasm/call` works end-to-end (zwasm shipped the exportFuncSig JIT arm @5b6449779).
3. **Remaining (D-488)**: flip the default to `.auto` when zwasm re-lands its
   `.auto`→JIT C-surface (their D-478). **Did NOT** build a cljw-side shim for the
   exportFuncSig gap — requested it upstream instead (from_cljw_02, CODEV / F-002).

D-036 is the master integration row; D-350 the embedding-API shape; D-488 the
remaining `.auto`-default flip; this ledger tracks adoption status per capability.

## Revision log

- **2026-06-20** — ledger created (user-directed convention). Pin = pre-JIT
  `412966f7`. zwasm JIT (ADR-0200 / zwasm#477) recorded as BUILDING, not yet adoptable.
- **2026-06-20** — handover protocol simplified (user-directed): no-loop, 2-state
  (`SENT`/`CONSUMED`), mailbox moved to `zwasm_from_scratch/private/dogfooding_handover/`.
  Sent `from_cljw_01.md` — JIT embedding-API consuming requirements (per-instance engine
  selection + interp stays, for cljw's dual-engine diff oracle) + a readiness-signal
  request (a future `to_cljw_NN` naming the pin SHA when embedder-stable).
- **2026-06-21** — JIT adoption unit OPENED (user-directed relative-path experiment, no-push).
  Consumed `to_cljw_02` (readiness signal): switched `build.zig.zon` `.zwasm` to
  `.path = "../zwasm_from_scratch"`; threaded `{:engine :jit/:interp/:auto}` through
  engine.zig + surface.zig; landed a dual-engine unit test (GPR jit==interp; SIMD-on-jit
  → 42). Found `exportFuncSig` returned null on JIT instances → blocked `wasm/call` on
  `:jit`; sent `from_cljw_02`. Same-session co-dev: zwasm shipped the exportFuncSig JIT
  arm @5b6449779 + REVERTED its `.auto`→JIT flip (@1e01e6797, C-surface incomplete) →
  `to_cljw_03`. Rebuilt on `5b6449779`: explicit `:jit` `wasm/call` now works end-to-end;
  landed the surface e2e `phase16_wasm_engine_select.sh`. cljw default stays `.interp`
  (zwasm-endorsed) until zwasm re-lands `.auto`→JIT (their D-478); tracked as cljw D-488.
  SIMD confirmed JIT-only by zwasm design (dual-engine oracle scoped to scalar bodies).
- **2026-06-21 (cont.)** — co-dev round-trips 3→4. `from_cljw_03` narrowed an FP-bank JIT
  trap to a precise **2-arg×FP-bank** trigger (arity×FP repro table); zwasm fixed the
  missing `dispatchScalar2` keys @`d7da97e04` (SAME-type 2-arg now works) → `to_cljw_03/04`.
  Verified on `@474922779`: `addf (f64,f64)→f64`=3.75, `(i32,i32)→f64`=7.0 on `.jit`; the
  cljw f64 test/e2e flipped to assert jit==interp. `from_cljw_04` reports the residual gap
  (MIXED `(i32,f64)`/`(f64,i32)→f64` still trap). zwasm re-reverted `.auto`→JIT again
  (more x86_64 dispatch gaps); cljw default stays `.interp` until the full shape matrix +
  `.auto` 3-host verdict land. Added bench `wasm_jit_vs_interp.sh` (~44× JIT speedup, 1e8 loop).
- **2026-06-21 (cont.)** — round-trips 5→6. `from_cljw_04` reported the residual MIXED
  2-arg trap; zwasm fixed it GENERALLY @`3cf40a573` (the per-combo veneer falls through to
  the generic buffer thunk for any uncovered 1/2-arg scalar shape) → the **1/2-arg JIT
  invoke matrix is COMPLETE**. cljw verified on `@f4848e680` (mixed `(i32,f64)→f64`=5.5
  jit==interp) + added a mixed-2-arg e2e assertion. NEW top `.auto` blocker = zwasm
  **D-489** (x86_64-only JIT realworld miscompile, tinygo_json) — `.auto` stays OFF, cljw
  default `.interp` firmly validated. Deferred (no cljw need): wide-arity / >2-result /
  v128-boundary (zwasm D-477). `to_cljw_05` consumed; no new finding (zwasm's fix is general).
