# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT). Per-commit = smoke; commit
  **and** push (atomic Step 6). `build.zig.zon` `.zwasm` = tag pin `v2.2.0` (AOT-full-fidelity; from v2.1.0).
- **1.2.0 RELEASED (2026-07-14 JST, tag v1.2.0, user-authorized).**
  Contents: **ADR-0170 nREPL re-architecture** (fa0917b5) — the CIDER
  field report (REPL RET dead / no completion / bare `NameError`)
  root-caused empirically to 6 defect classes and rebuilt as
  `src/app/nrepl/` (transport drain-all framing + >4KiB frames /
  distinct sessions + per-session `*1..*e`+ns / comptime op table with
  derived describe / completions+complete+lookup+info+eldoc) + shared
  `app/eval_session.zig` (CLI REPL gained `*1`/`*2`/`*3`/`*e` same
  cycle) + `runtime/introspect.zig` (line-editor TAB + nREPL share) +
  bencode readString arena-dupe. Verified vs the REAL nrepl/nrepl 1.3.1
  Java client. PLUS **D-369 discharged** (d1310fe9): the pre-tag
  conformance sweep caught flatland.ordered 17→8 + data.generators
  20→19 — both present in released 1.1.0 (NOT ADR-0170 regressions);
  fixed at the root: -editable? = instance? IEditableCollection,
  transient family dispatches .typed_instance to ITransient*, native
  transients answer interop method calls (TRANSIENT_METHOD_MAP), and
  the O-045 reduce-fusion gate no longer realizes the head to decide
  chunked-ness (double side-effect; data.generators seeded *rnd*).
  Pre-tag record: full gate 402/0 + conformance 17 libs 0 DRIFT +
  verify_projects 19/19 + CI green (29261004785). D-117/D-118
  re-narrowed by code-truth; D-560 unchanged.
- **1.1.0 RELEASED (2026-07-12).** cljw `v1.1.0` tagged + pushed (user-authorized);
  release.yml published macos-aarch64 + linux-x86_64 binaries + sha256. Pins **zwasm
  v2.2.0**. Contents = 56 commits past v1.0.1: clojure.repl bundle + :arglists/:doc meta
  + regex lookbehind + %t format + interop statics + the D-555…558/C10 GC-correctness
  batch. **Homebrew tap LIVE**: `clojurewasm/homebrew-tap` (own tap, holds many
  formulae), `brew install clojurewasm/tap/cljw` verified on Apple Silicon (unsigned,
  ad-hoc/linker sig, no quarantine xattr; eval+wasm-FFI+clojure.repl all work). Signing
  = unsigned + README xattr fallback note (user call). D-549 residual (Docker/ghcr +
  Developer-ID notarization) stays user-LOCKED.
- **CI is FULLY GREEN (2026-07-13, dispatch runs 29216662670 / 29219521822 /
  29223367467, both legs).** The week-long nightly red was 3 layers: (1)
  `check_surface_marker` `printf|grep -q` SIGPIPE/pipefail false positive
  (here-string fix, swept 3 scripts; memory `pipefail_grep_q_broken_pipe`);
  (2) `check_vm_parity` raw `timeout` → exit 127 on hosted macOS (no GNU
  timeout/gtimeout — ported to `run_bounded`, the last raw caller after
  264804b7); (3) the agent race below.
- **D-418 + D-559 agent/GC races DISCHARGED (2026-07-13).** D-418 = the
  send/await FABRICATION-WINDOW race (action vector / await promise unrooted
  across the enqueue) — EvalFrame-rooted in primitive/agent.zig; made
  deterministic via `tortureCollectInWindow` (collect injected into the exact
  window under CLJW_GC_TORTURE_ALLOC); the gc_torture agent block's ncpu>=4
  gate is REMOVED and green on the 3-vCPU macOS runner. D-559 = the peer-STW
  park firing INSIDE a fabrication bracket (worker builder nodes swept →
  `@memcpy arguments alias`) — **ADR-0150 amendment 1**: the alloc-prologue
  park honors `fabrication_depth` (JVM-GCLocker shape); park/enterBlocked
  asserts; `safepoint.max_stopworld_wait_ns`; guard `alloc-agent/nested_xagent`.
  Accepted cost = **D-560** (fold-chain rendezvous delay; publish-roots flip is
  its trigger-gated discharge shape — do NOT self-select).
- **First commit on resume MUST be: D-523's residual** — audit
  `docs/architecture.md` + `docs/examples/wasm/README.md` vs code-truth
  (recipe in `private/notes/2026-07-09-d460-sorted-as-key.md` § Extended
  challenge), then D-522 pointer-condensation / D-527/528 / D-430 var-alias
  (S-sized), per the easiest-first drain.
- **Forbidden this session**: bare `zig build test` WITHOUT `-Dwasm`; bare `zig build`
  for a probe (use ReleaseSafe). **The FULL gate MUST run `--serial-e2e`** — canonical
  mode; the residual D-548 (a) future/promise SIGABRT + (b) pmap wall-clock remain
  load-sensitive (the D-418 agent_conj arm is FIXED). **Never run a concurrent
  build during a gate** (host contention → false timeout). `.claude/**` edits may hit
  the auto-mode self-modification block — surface those to the user. **D-549
  distribution cluster (brew/Docker/signing) is user-LOCKED** — never self-select.
  **D-560 is trigger-gated** (measured pause-time harm or F-006 amendment) — not
  an ease-drain row.

## Last landed (git log = SSOT)

2026-07-13 session: CI 3-layer root-cause fix (surface_marker pipefail +
vm_parity portable timeout) + D-418 fabrication-window fix + D-559 / ADR-0150
am1 park-honors-fabrication + D-560 opened. All CI-verified on both legs.

## Standing units (tracked in .dev/debt.yaml)

- **Perf campaign (§9.2.S) — PAUSED** (cheap levers exhausted; D-520 / D-386 / D-005/006).
- **D-439 sqrt(MathContext)** — the one BigDecimal remnant; a focused numeric cycle
  (correct rounding ×8 modes + JDK preferred output scale; base = the native Managed.sqrt).
- **D-513** — clojure.core.reducers / clojure.repl / var :doc (foundational).
- **D-548** — residual low-core exposures (a) future/promise SIGABRT (b) pmap wall-clock;
  the (c) agent_conj arm is DISCHARGED via D-418. D-560 — trigger-gated (see above).
- **D-430** — instaparse frontier is now DETERMINISTIC (core.cljc:361 `#'gll/TRACE`
  family) after the GC arc; re-derivable without the corruption noise.

## North star (ACTIVE, distal)

cljw's differentiator = **Wasm/edge-native (gap II) × VM-perf fusion→JIT (gap III)**.
zwasm JIT (ADR-0200) is the cljw default; remaining = components-through-the-JIT
(zwasm-side, D-500). Distal — needs a user nod; the §9.2.T public-ization sweep
(easiest-first debt drain) is the active near-term mode.

## Reading order (resume)

handover → **`private/notes/2026-06-25-debt-drain-order.md`** (easiest-first snapshot)
→ `yq` the live `active:` list → **ADR-0166** (public-ization sweep mode) → ROADMAP
§9.2.T. Memories: `verify_against_releasesafe_binary` / `smoke_first_batch_full_gate` /
`gate_parallel_e2e_timeout`.

