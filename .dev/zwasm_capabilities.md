# zwasm capability ledger — cljw's view of the embedded Wasm runtime (F-001)

> **The record of what the zwasm we embed offers, and what cljw adopted.**
> cljw embeds **zwasm v2** (F-001, unavoidable). The dep is a **tag pin** —
> **v2.6.0** (see § Pin), pinned 2026-09-05 by user direction.
> Prior pins: v2.5.0 (2026-08-12) full WASI 0.3 coverage + the `libzwasm.a`
> C-API symbols, v2.4.1 (2026-08-04) the two cljw-found
> component/output fixes, v2.4.0 (2026-08-03) the external-consumer release,
> v2.3.0 (2026-07-17) the WASI-0.3.0-official inventory sweep, v2.2.1
> (2026-07-16) the binary-size campaign, v2.2.0 (`cf5d20d7`, 2026-07-09)
> the AOT-full-fidelity release (ADR-0203). cljw **adopted the JIT as its
> default** (`.auto`, D-488 discharged); the north-star step it never reached is
> components-through-the-JIT (zwasm-side, D-500).

## Status of this file: a pin record, not a watch list (re-opened 2026-09-05)

This ledger existed to answer "what does zwasm have now, and has cljw adopted
it?" for a **moving** dependency that this repo co-developed. That
relationship ended on 2026-08-12, when zwasm left the `clojurewasm` org for
its own, <https://github.com/zwasm/zwasm>, under **separate, joint
maintainership**. The file was FROZEN at the v2.5.0 pin on that basis; the
"v2.5.0 is final" framing was **retired by user direction on 2026-09-05**
(F-001 Revision history), when the pin moved to v2.6.0.

What this file is now:

- **The pin moves on this fork's schedule, by user direction**, not in
  lockstep with zwasm releases. Each bump appends a § History entry (date,
  tag, sha, the embedding-API delta, what was re-verified) and updates § Pin.
- **Not a watch list.** There is no per-unit refresh duty and no
  `dogfooding_handover` mailbox (the `from_cljw_NN` / `to_cljw_NN` channel was
  between two repos under one owner and ended with the transfer). A zwasm-side
  finding is an ordinary upstream report. Capability rows are accurate as of
  the dates they carry and are **not** kept current against zwasm's ongoing
  development; read zwasm's own repo for that.

The embedding surface cljw actually depends on is narrow (Engine / Module /
Instance / `runWasmCapturedFull` / `wasi.host.Host`). A bump is verified
against the eight `phase16_wasm_*` e2e plus the full gate; the bump recipe is
under § Pin.

## Pin

- **FORK-BRANCH PIN — BuddhiLW/zwasm `cljw` @ `544f9c12`, pinned 2026-09-14
  (user direction: "use our zwasm for now. And also pull their latest changes
  locally").** `build.zig.zon` `.zwasm` = `.url =
  "git+https://github.com/BuddhiLW/zwasm.git?ref=cljw#544f9c12…"` + `.hash =
  "zwasm-2.7.0-FT1Fv_ZInADJZP5qmVfBJwpwDOJBdw4smLQ3wP5AVDBe"`. The branch is
  upstream **v2.7.0** (`d09d9248`, 2026-09-14: cross-module composition on the
  default engine, five observability hooks, `Instance.engine()`, two appended
  trap kinds, `.auto` no longer retries the interpreter on a JIT validity
  verdict) plus two cherry-picks found from cljw that upstream does not carry:
  `f1b0dc97` every exported interface of a component resolves (was: the second
  interface invisible, ZWASM-INSTANCE-REEXPORT) and `544f9c12` the 0.2
  `metadata-hash` / `metadata-hash-at` rows made real plus the 0.2 error-code
  ordinals past `no-lock` corrected (was: any rust-std wasip2 guest that links
  `std::fs` failed to instantiate, CLJW-WASIP2-STD). Both sit on the fork as
  PR-ready branches (`fix/instance-reexport`, `fix/p2-metadata-hash-at`) for
  `zwasm/zwasm`; the pin returns to an upstream tag when a release carries
  them. Embedding-API delta for cljw: none required (the additions are
  additive; cljw's `.auto` path is unchanged in shape). Verified: see the
  Revision log entry of 2026-09-14.
- Prior: **TAG PIN — v2.6.0, pinned 2026-09-05 (user direction).** `build.zig.zon`
  `.zwasm` = `.url = "git+…/zwasm.git?ref=v2.6.0#3831e68b"` +
  `.hash = "zwasm-2.6.0-FT1Fv3i-…"`. One embedding-API delta: zwasm #257
  widened `runWasmCapturedFull`'s stdin from `?[]const u8` to a `StdinSource`
  union so a core module can inherit the host's stdin; `engine.zig` maps
  cljw's `:stdin` string to `.bytes` and its absence to `.none` (behaviour
  unchanged; `.inherit` deliberately not wired, a sandbox decision). It does
  NOT fix zwasm/D-584 / zwasm/D-585, the per-call JIT cost recorded in
  `.dev/wasm_percall_findings.md`. Verified: `zig build -Dwasm
  -Doptimize=ReleaseSafe` + all eight `phase16_wasm_*` e2e, then the full gate.
- Prior: **v2.5.0** (2026-08-12). `build.zig.zon`
  `.zwasm` = `.url = "git+…/zwasm.git?ref=v2.5.0#278587f6"` +
  `.hash = "zwasm-2.5.0-FT1Fv4KP…"`. Brought full **WASI 0.3** coverage (all
  six proposals, 45/45 on the official `wasm32-wasip3` corpus across
  macOS/Linux/Windows) and the 81 declared-but-unexported C-API symbols in
  `libzwasm.a` (zwasm #161). **Neither reaches cljw's embedding surface**:
  cljw drives Engine/Module/Instance through Zig on `.auto` (JIT-default,
  D-488), not the C API, and its WASI use is the component/`wasm/run` path
  the previous pins already served. So this is a hygiene follow that lands
  cljw's last release on zwasm's current stable rather than a behaviour
  change; no cljw-side delta is claimed. Verified: `zig build -Dwasm` +
  the five phase16 wasm e2e (ffi / component / component_multiexport /
  engine_select / require_component) green on the new pin, then the full
  gate. Prior: **v2.4.1** (2026-08-04), the two fixes found FROM cljw —
  component multi-export validation (#157) and the captured-run output
  bound (#158/#159). Prior: **v2.4.0** (2026-08-03), the external-consumer
  release: `-Dcompiler-rt`
  bundles Zig's compiler-rt into `libzwasm.a` for non-Zig linkers
  (zwasm #153/#154), and a DCE fix keeps the WasmGC cohort out of
  sub-3.0 builds (zwasm #150). **Neither reaches cljw, structurally**:
  cljw links zwasm through Zig (`b.lazyDependency`), which supplies its
  own compiler-rt, and it passes no `-Dwasm` override so it builds at
  zwasm's default `3.0` — where the DCE guard is `if (comptime false)`
  and the real helper bodies run unchanged. So this pin is hygiene, not
  a behaviour follow; no cljw-side size or output delta is claimed.
  Verified: `zig build -Dwasm` + phase16 wasm e2e (ffi / engine_select /
  run / component / require_component) all green on the new pin.
  Executed under the user's standing tag-watch directive, user-
  directed this session. Prior: **v2.3.0** (2026-07-17), the
  WASI-0.3.0-official inventory sweep (docs truth-sweep,
  `wasi:clocks/system-clock` + `get-resolution` component-host support,
  Homebrew packaging) — also a pure engine follow. Prior: **v2.2.1** (2026-07-16), the binary-size
  campaign (zwasm ADR-0204 / D-522 stage 1: JIT host-callback thunk
  collapse, `api.jit_host_bridge` 1,311 KB → 232 KB, zwasm CLI −21%;
  measured cljw effect: shipped binary 8,583,352 → **7,499,896 B
  (−1,083 KB)**). Prior:
  **v2.2.0** (`cf5d20d7`, 2026-07-09), described below. The AOT-full-fidelity release (zwasm ADR-0203 stages
  1-5): guard-page bounds-check elision (D-507/ADR-0202), committed
  differential-fuzz gate (D-510), JIT helper de-baking (D-516), full-fidelity
  `.cwasm` v0.5 AOT serialize/load (aot-diff 62/62), transparent on-disk
  compilation cache (`--cache`, D-508). cljw's embedding surface is unchanged
  (engine follow); the bump was executed under the user's standing 2026-07-09
  tag-watch directive (bump on a >v2.1.0 tag). Prior pins: **v2.1.0**
  (`d5d685ad`, 2026-07-06, table64-JIT) / **v2.0.0** (`0853f3c1`, 2026-07-01,
  the cljw 1.0.0 release engine).
- `lazy` dependency: resolved only under `-Dwasm`. So a churning dep never
  breaks the day-to-day gate when the flag is off — it
  only gates what `cljw.wasm/*` can do.
- Pin-bump (to a newer tag/SHA): `zig fetch "git+https://github.com/zwasm/zwasm.git?ref=<tag>#<SHA>"`
  prints the content hash; hand-edit `.url` + `.hash` + keep `.lazy` (`--save` mangles the
  entry). The `#<SHA>` must be the COMMIT the tag points at, not the annotated
  tag object: `git rev-parse 'vX.Y.Z^{}'` peels it (`zig fetch` rejects the
  tag object with `NotACommit`). Bumps are user-directed (F-001 Revision
  history); each one appends a § History entry and re-verifies the eight
  `phase16_wasm_*` e2e plus the full gate.

## Capability table (rows accurate as of the dates they carry)

| Capability                            | zwasm status (as of 2026-06-22)                                                                                                                            | in cljw's tree? | cljw adoption                                                                                                                   | ref          |
|---------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------|---------------------------------------------------------------------------------------------------------------------------------|--------------|
| Interp embedding (load/instantiate)   | ready                                                                                                                                                      | YES             | integrated behind `cljw.wasm/*` (-Dwasm)                                                                                        | F-001, D-036 |
| `invoke` (call exported fn)           | ready (interp + JIT)                                                                                                                                       | YES (rel-path)  | integrated; JIT `invoke` verified via unit test                                                                                 | D-036, D-488 |
| Embedder hardening / WASI sandbox     | landed (security pass `…→6b08fe70`, 3-host green)                                                                                                        | mostly          | consumed (old security mailbox)                                                                                                 | CODEV        |
| **Multi-arg JIT invoke (≤5/7 GPR)**  | **ready** (embedder-stable, to_cljw_02 matrix)                                                                                                             | YES (rel-path)  | exercised by the dual-engine unit test                                                                                          | to_cljw_02   |
| **SIMD (v128) body on JIT**           | **ready** (JIT-only by design; interp has no v128 dispatch)                                                                                                | YES (rel-path)  | verified (lane0→42 on .jit); interp traps catchably                                                                            | D-488        |
| `exportFuncSig` on JIT instance       | **ready** (JIT arm shipped @5b6449779, to_cljw_03)                                                                                                         | YES (rel-path)  | adopted — explicit `:jit` `wasm/call` works end-to-end (e2e)                                                                   | D-488        |
| FP-bank scalar JIT invoke (f32/f64)   | **ready** (1/2-arg matrix COMPLETE @3cf40a573 — veneer→generic-buffer fall-through; 3-arg via buffer)                                                    | YES (rel-path)  | adopted — `:jit` covers all 1/2-arg scalar (incl. mixed) + 3-arg; e2e-locked                                                   | D-488        |
| **JIT-backed engine (`.auto`)**       | **ON (JIT-first + interp fallback)** — re-landed v2.0.0-alpha.3 (D-478); x86_64 LSRA miscompile D-489/D-494 fixed, 3-host green                           | YES (tag-pin)   | **ADOPTED — cljw default flipped `.interp`→`.auto` (D-488 discharged 2026-06-22); no-opts load rides JIT**                    | D-488        |
| Components on JIT                     | interp-pinned (D-500, zwasm CM-API core); Win64 string-arg wrapper-thunk gap                                                                               | YES (tag-pin)   | unaffected — `.auto` default leaves components on interp (zwasm-side pin)                                                      | D-500, D-404 |
| WIT component marshalling             | future                                                                                                                                                     | NO              | NOT adopted                                                                                                                     | D-404        |
| no-max table `table.grow` (JIT)       | tier-1 FIXED in v2.0.0 (D-501) — grows to a synth cap `max(min*2, 1024)`; unbounded no-max grow still interp-only                                         | YES (pin)       | unaffected (no `table.grow` / table decl in cljw host or FFI fixtures); available if a guest needs it                           | D-501        |
| table64 (i64-indexed tables) on JIT   | NEW in v2.1.0 (D-475) — table64 ops / `call_indirect` / elem segments compile natively (u64 index width, wrap-safe bounds); i32 tables keep the fast path | YES (pin)       | unaffected (cljw declares no tables); a table64 guest now rides the JIT instead of the interp fallback                          | zwasm D-475  |
| guard-page bounds-check elision (JIT) | NEW in v2.2.0 (D-507/ADR-0202) — reservation-backed linear memory + fault→trap PC-redirect; bounds checks elided by default, diff-fuzz-gated (D-510)     | YES (pin)       | transparent — cljw's `.auto` guests get the faster JIT bodies; no embedding-API change                                         | zwasm D-507  |
| .cwasm AOT + on-disk compile cache    | NEW in v2.2.0 (ADR-0203) — full-fidelity `.cwasm` v0.5 serialize/load (aot-diff 62/62) + transparent `--cache` (D-508); JIT helpers de-baked (D-516)      | YES (pin)       | NOT adopted — zwasm-CLI-side surface today; candidate for cljw cold-start (evaluate when an embedding API for the cache lands) | zwasm D-508  |
| In-process compiled WASI command (`cli.run_prepared.PreparedWasi`) | fork branch `feat/captured-wasi-run`: validate + JIT-compile once, then per-call store/WASI host/instance with captured stdio, stdin bytes, argv, env, preopens, fuel, memory, output cap, timeout; same exit/trap mapping as `runWasmCapturedFull` | YES (sha pin)   | **ADOPTED**: `wasm/run` caches prepared modules (LRU 8, keyed by jail-resolved path + inode + size + mtime); `:cache false` opts out, `wasm/clear-cache!` drops them (D-350 amendment 2026-10-07) | D-350        |

## The JIT adoption unit (gap area II × III) — CLOSED, partially reached

The north-star capability was **running Wasm components through zwasm's JIT
engine** from cljw. Scalar/SIMD function invocation got there; components did
not (they stayed interp-pinned on the zwasm side, D-500). The record:

1. **Trigger (DONE)**: zwasm shipped the embedder-stable JIT engine (`to_cljw_02`);
   cljw switched the dep to relative-path (user-directed experiment, no-push).
2. **cljw action (DONE this cycle)**: threaded `:engine :jit/:interp/:auto` through the
   finished-form `(wasm/load path opts)` surface; interp kept as the default; landed a
   dual-engine diff oracle (unit + e2e) per the F-012 discipline. Explicit `:jit`
   `wasm/call` works end-to-end (zwasm shipped the exportFuncSig JIT arm @5b6449779).
3. **Default flip (DONE 2026-06-22, D-488 DISCHARGED)**: zwasm cut **v2.0.0-alpha.3**
   (pin `fc7ff0b3b`, 3-host green) which re-lands `.auto`→JIT (its D-478) AND fixes the
   gating x86_64 LSRA dual-spill miscompile (D-489/D-494) — to_cljw_09. cljw flipped its
   `LoadOpts.engine` default `.interp`→`.auto`, so a no-opts `(wasm/load path)` now rides
   zwasm's JIT-first engine (transparent interp fallback). The e2e proves it: the no-opts
   default executes a SIMD body that ONLY the JIT can run (interp would trap). **Did NOT**
   build any cljw-side shim for the JIT gaps — requested each upstream (from_cljw_02-04,
   CODEV / F-002). Components stay interp-pinned on the zwasm side (D-500), so the north-star
   "components through the JIT" awaits zwasm's component-on-JIT (Win64 wrapper-thunk gap).

D-036 is the remaining JIT-coordination master row; D-350's embedding-API shape is
DISCHARGED by ADR-0124's explicit command/handle lifecycle split; D-488
(DISCHARGED) was the `.auto`-default flip. This ledger tracks adoption status per
capability.

## Known zwasm blockers on cljw features (read before promising a capability)

| zwasm gap                                                                                                                                                                                                                                | Blocks                                                                                                                                    | cljw row                    | Found                                        |
|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------|----------------------------------------------|
| **A component with 2+ exports fails validation (`InvalidSort`)** — `component_funcs` does not count the index-space entries component-level `export`s create (`feature/component/types.zig`, the `.@"export"` arm handles only `.type`) | **`(:require ["x.wasm" :as x])` — the headline feature.** Only single-export components load today; every real component exports several | **D-567** / zwasm **D-527** | 2026-08-04, by the typed fixture's first use |

That row is the reason this section exists. cljw's two component fixtures both
exported exactly one function, so "component as a namespace" had never been
tried with a namespace-shaped component. A capability ledger that tracks what
zwasm *has* and not what it *rejects* will keep missing this class — the pin
bump to v2.4.0 the day before was reviewed for behaviour-follow and could not
have surfaced it.

## Revision log

- **2026-06-20** — ledger created (user-directed convention). Pin = pre-JIT
  `412966f7`. zwasm JIT (zwasm ADR-0200 / zwasm#477) recorded as BUILDING, not yet adoptable.
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
- **2026-06-22** — **JIT DEFAULT LANDED (D-488 DISCHARGED)**. zwasm cut **v2.0.0-alpha.3**
  (pin `fc7ff0b3b`, annotated tag-only, 3-host green: Mac aarch64 + ubuntu x86_64 + Win64)
  which RE-LANDS `.auto`→JIT (its D-478) AND fixes the gating x86_64 LSRA dual-spill
  miscompile (D-489/D-494) — `to_cljw_09`. cljw exited the relative-path no-push experiment
  and pinned the tag (`build.zig.zon` `.zwasm` = tag URL + hash, `.lazy = true`), then flipped
  `engine.LoadOpts.engine` default `.interp`→`.auto` (removed the PROVISIONAL marker + emptied
  feature_deps#runtime/cljw/wasm/engine_default, same commit): a no-opts `(wasm/load path)` now
  rides zwasm's JIT-first engine. e2e `phase16_wasm_engine_select.sh` extended — the no-opts
  default executes a SIMD body only the JIT can run (`default-simd: 42`), proving the flip.
  Components stay interp-pinned on the zwasm side (D-500), so the component path is unaffected
  and the F-012 diff oracle (explicit `.interp`/`.jit`) is untouched. `to_cljw_09` CONSUMED.
- **2026-07-01** — **PIN BUMP v2.0.0-alpha.3 → STABLE v2.0.0 (`0853f3c1`)** for the cljw
  1.0.0 release. zwasm cut + published a stable `v2.0.0` GitHub Release (after one failed
  release build + a tag re-cut); it picks up zwasm D-501 tier-1 (no-max table `table.grow`
  under JIT grows to `max(min*2, 1024)`; PR #115) + a test-infra guest-stdout fd guard.
  cljw is behaviorally unaffected (no `table.grow` usage); the full `--serial-e2e` gate
  confirmed the embedding API (`Engine.init` / `runWasmCapturedFull` / `wasi.host.Host` /
  `Module.InstantiateOpts`) is signature-stable. Resolves the D-543 "1.0.0 embeds a
  pre-1.0 zwasm" incoherent-pin story — cljw 1.0.0 now ships on a coherent stable zwasm v2.0.0.
- **2026-07-06** — **PIN BUMP STABLE v2.0.0 → v2.1.0 (`d5d685ad`)**. zwasm cut a
  `v2.1.0` release (table64-JIT): D-475 lands native JIT compilation of table64
  (i64-indexed tables — the memory64 proposal's table extension), so table64 ops /
  `call_indirect` / active elem segments no longer fall back to the interpreter, plus
  instantiate-time 64-bit bounds hardening + an AOT loud-reject for oversized table64
  minimums. cljw declares no tables in its host or FFI fixtures, so it is behaviorally
  unaffected — a clean engine follow, not a required fix. Bumped to keep the embedded
  engine current toward the gap-II×III north star; `build.zig.zon` `.zwasm` re-pinned
  (tag URL + hash), smoke green.
- **2026-07-16** — **Sent `from_cljw_05.md`** (binary-size campaign, cljw ADR-0172 L5):
  measured zwasm at ~2.99 MB of cljw's `__text` (44% of all code;
  `engine.codegen.arm64.emit.compile` alone 691 KB — the biggest single symbol in the
  product; `api.*` ~1.37 MB / 5,624 symbols). Requests, size-neutral only: (1)
  table-driven arm64 emitter (+ design the coming x86_64 emitter table-driven from day
  one), (2) comptime-gate unused component-model api surfaces for embedders, (3)
  optional compute-only module split for safety-tier flexibility. No urgency coupling —
  rides the normal user-gated pin cadence. The mailbox dir had been cleaned; recreated.
  cljw-side budget contract: zwasm (engine+api) = 4.0 MB line in ADR-0172 §2.
- **2026-07-16 (same day)** — **to_cljw_05 + to_cljw_06 CONSUMED; pin bumped
  v2.2.0 → v2.2.1.** zwasm accepted the campaign (their ADR-0204), landed the
  thunk collapse same-day (D-522 stage 1, PR #145) and released v2.2.1; cljw
  re-pinned and measured **−1,083 KB** (8,583,352 → 7,499,896 B). Two
  corrections adopted from the reply: (1) the x86_64 JIT emitter ALREADY
  exists (target-comptime-gated — 0 B on arm64; my from_cljw_05 called it
  "planned"); (2) **the table-driven-emitter request is REFUTED by their
  reversible experiment** — `emit.compile`'s 707 KB is the aggregation of
  once-called inlined handlers (out-lining is size-neutral, +28.8 KB even);
  symbol-size attribution overstates recoverable size when code has ONE call
  site — the predictive question is instantiation count (the thunks WERE
  ×64-duplicated, hence the real win). ADR-0172's zwasm budget line re-set
  to 2.5 MB (was 4.0) per the same reply's suggestion.

- **2026-08-04** — pin v2.4.0 (unchanged). Added the **Known zwasm blockers**
  section above after building the typed component fixture ClojureWit had
  already written (`echo.wat`, hand-written WAT, no Rust toolchain) and finding
  on its first run that zwasm rejects any component with two or more exports.
  Root-caused into zwasm's component index-space accounting and filed as zwasm
  D-527 with a two-line reproduction; pinned cljw-side as D-567 +
  `phase16_wasm_component_multiexport.sh`, which asserts the failure is a clean
  catchable error rather than hiding it. Discharges half of D-404's "BLOCKED on
  a typed component FIXTURE" — the fixture now exists and is checked in; what
  remains is the engine accepting it.

- **2026-08-12** — **PIN BUMP v2.4.1 → v2.5.0 (`278587f6`), the FINAL pin.**
  User-directed, to land cljw's last release on zwasm's current stable. zwasm
  2.5.0 is full WASI 0.3 coverage + the `libzwasm.a` C-API export fix; neither
  touches cljw's Zig embedding surface, so this is hygiene rather than a
  behaviour follow (five phase16 wasm e2e + the full gate green on it). This
  ledger's per-unit watch duty ends here: zwasm continues under separate
  maintainership, so this fork follows its releases deliberately rather than
  tracking them.

- **2026-08-12 (same day)** — **zwasm transferred out of the `clojurewasm` org**
  to its own org, <https://github.com/zwasm/zwasm>, to be maintained jointly by
  its author and an outside contributor. cljw's dep URL now names that org
  directly rather than riding GitHub's transfer redirect (a redirect is only an
  alias until something else claims the old name — the RepoJacking shape). The
  `.hash` is content-addressed and did not change, verified by `zig fetch`
  against both URLs. This file was FROZEN as of this entry; the co-development
  protocol it used to carry (per-unit refresh, `dogfooding_handover` mailbox)
  is retired with the transfer, since the two repos no longer share an owner.

- **2026-09-05** — **PIN BUMP v2.5.0 → v2.6.0 (`3831e68b`); the "final pin"
  framing is retired.** User direction: unpin from v2.5.0 and track the latest
  release (F-001 Revision history, same date). The FROZEN status above is
  replaced by § Status: the ledger records each pin and its embedding-API
  delta, with no watch duty. Delta at this bump: zwasm #257's `StdinSource`
  union on `runWasmCapturedFull` (mapped in `engine.zig`, behaviour
  unchanged). Not brought: a fix for zwasm/D-584 (`computeStackLimit` per JIT
  invocation, the 48x per-call cost on Linux) or zwasm/D-585 (export re-resolved
  per call); `computeStackLimit` is still called per invocation on upstream main.
  zwasm's ledger ids are always written `zwasm/D-NNN`: bare `D-NNN` is a cljw
  row (`check_debt_id_refs.sh`), and the two ledgers collide on D-585.
  Gotcha recorded under § Pin: `zig fetch` wants the peeled commit, not the
  annotated tag object. Verified: ReleaseSafe `-Dwasm` build, all eight
  `phase16_wasm_*` e2e, the full gate.
- **2026-09-14** — **FORK-BRANCH PIN** (user-directed: "use our zwasm for now.
  And also pull their latest changes locally"). Pin moved v2.6.0 ->
  BuddhiLW/zwasm `cljw` @ `544f9c12` = upstream v2.7.0 (`d09d9248`) + two
  cherry-picks found from cljw that upstream lacks: `f1b0dc97` every exported
  interface of a component resolves (ZWASM-INSTANCE-REEXPORT) and `544f9c12`
  the 0.2 `metadata-hash` / `metadata-hash-at` rows made real + the 0.2
  error-code ordinals past `no-lock` corrected (CLJW-WASIP2-STD). Both sit on
  the fork as PR-ready branches for `zwasm/zwasm` (the account has READ there;
  a push to the fork must go over SSH, the `gh` OAuth token lacks the
  `workflow` scope). v2.6.0 -> v2.7.0 embedding delta: additive (five engine
  hooks, `Instance.engine()`, two appended trap kinds); one behaviour change,
  `.auto` refuses a module the JIT judges invalid instead of rerunning it on
  the interpreter, which no e2e exercises. Verified: ReleaseSafe `-Dwasm`
  build, all nine `phase16_wasm_*` e2e (the budget step is new since
  v1.14.6), and the wasip2 `std` guest hive-addon-wasm text-tools lists its
  seven exports across both interfaces where 2.6.0 failed to link. Measured
  cljw effect on the release PR's macOS leg: shipped binary 7,549,512 ->
  **8,141,512 B (+592 KB)**, within the 8,800,000 B ceiling; the size claims
  were updated to 8.14 MB in the same batch. The full gate ran on that PR's
  CI. The pin returns to a `zwasm/zwasm` tag when a release carries both
  fixes.
