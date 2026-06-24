# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; ≈ `368c9851`). Per-commit = smoke; commit
  **and** push (CLAUDE.md § atomic Step 6). `build.zig.zon` `.zwasm` = tag pin
  `v2.0.0-alpha.3`.
- **First commit on resume MUST be**: **RE-MEASURE the cross-lang benches on a QUIET Mac**
  (`bash bench/compare_langs.sh --yaml=bench/cross-lang-latest.yaml` + regen README) to make
  the new rankings authoritative — THEN attack the surviving gap. The cold-start arc
  (D-140 footer-seek 74970240 + **D-516 lazy-namespace bytecode 0f159228+4b4f20c9, ADR-0162/
  0163**) cut the floor **9.4→4.3ms** and a focused re-check (load ~9, RELATIVE valid) shows
  it CLOSED **7 of the 9 D-450 gaps** — cljw now FASTEST on sieve/nested_update/
  map_filter_reduce/gc_large_heap/string_ops/destructure/bigint_factorial; json_parse
  borderline (~1.07× py). **ONLY `gc_alloc_rate` remains a clear gap** (cljw 45.3 / bb 39.9 =
  1.14×, GC-bound not floor-bound). fastest-script ~19/30→~27/30. THEN attack the surviving
  gap = **D-519 auto-collect (ADR-0164, design ACCEPTED + DA-vetted)**: root-caused via
  `CLJW_GC_STATS=1` (07176327, reuse=0%/collects=0 = NO eval auto-collect → unbounded malloc +
  latent OS-OOM bug). ADR-0164 = BOTH sites (alloc-boundary + VM back-edge poll), threshold-gated
  on the proven CLJW_GC_TORTURE_ALLOC path, default 1MB→4MB + knob, keep torture. **QUIET-Mac-
  GATED**: correctness is load-independent, but KEEP/REVERT needs a wall-clock all-bench re-run
  (string_ops CANARY; count proxy INSUFFICIENT) — don't commit under load. Full detail +
  BOTH-sites code: ADR-0164 / D-519 / the note. D-517 zero-copy = LOW value now; D-518
  heap-snapshot DEFERRED (moving-GC unit). **GUARDRAIL**: never Zig-ify the .clj bootstrap.
  Decisions ADR-0162/0163/0164; plan `private/notes/9.2.S-coldstart-architecture-20260624.md`.
  D-515 binary-size axis (standing).
- **Forbidden this session**: bare `zig build test` WITHOUT `-Dwasm` (false fails —
  `zig_build_test_needs_dwasm`); bare `zig build` for a probe (ADR-0133 — ReleaseSafe).

## Last landed (git log = SSOT)

**Cold-start floor arc DONE — floor 9.4→4.3ms (ADR-0162 + ADR-0163).** Measure-first
attribution (env-gated profiler `CLJW_PROFILE_STARTUP=1`, 24a2d635) → **D-140 footer-seek
(74970240)** → **D-516 lazy-namespace bytecode (0f159228)**. The bootstrap blob is now a
multi-region position-independent blob (one envelope per ns); loadCoreAot runs ONLY the
EAGER set (SSOT `bootstrap.EAGER_NS` = JVM Clojure's measured no-`require` set: core +
string/walk/edn/java.io/core.protocols/uuid/instant/spec.alpha + cljw.wasm), the rest
replay on first `require` via `loadOrFindNs`→`loadRegionNamespace`. STRICT clj-parity:
what clj uses require-free, cljw does too; what clj require-gates, cljw does too. Bugs
fixed: the require 4-path `mappings.count()` short-circuit unified to `loadOrFindNs`
(+ inline-ns last-resort); cljw.wasm eager (analyze-time component desugar); corpus runner
auto-requires. Blast-radius (27 e2e + cw_ported.clj) = missing-require, zero real bugs.
D-518 heap-snapshot DEFERRED to the moving-GC unit (DA: ~1ms behind a ~3.4ms exec wall at
silent-heap-corruption risk). Guardrail held: no .clj→Zig rewrite.

## Standing units (tracked in .dev/debt.yaml)

- **D-511** — 2-arg `(BigDecimal. x mc)` ctor LANDED (8db6d82f); only the
  exact-binary `(BigDecimal. double)` footgun remains (OPEN-LOW, deferred).
- **D-513** — three linked clj-parity gaps, all foundational (NOT clean drop-ins):
  (1) `clojure.core.reducers` (needs reduce→CollReduce wiring OR a cljw-native
  reducers impl; transducers supersede it, moderate-low value); (2) `clojure.repl`
  (dir/apropos implementable, but doc/find-doc/source blocked by (3)); (3) var
  `:doc` metadata absent — `(:doc (meta #'reduce))` → nil; wiring docstrings
  through every bootstrap defn/def + primitive var registration is a large,
  separate unit and the real prerequisite for a useful `clojure.repl`.
- **gap-III perf campaign** (ROADMAP §9.2.S, D-450) — the fastest-script goal
  (ADR-0148): cljw FASTEST among cljw/Python/Ruby/Node/Babashka cold-start. The
  ACTIVE front (see Resume contract for the re-measured 2026-06-24 gaps + lever
  order). Then D-386 dispatch→superinstructions→JIT.

## North star (ACTIVE)

cljw's differentiator = **Wasm/edge-native (gap II) × VM-perf fusion→JIT (gap III)**.
The embedded **zwasm** JIT engine (ADR-0200) is the cljw DEFAULT (`.auto`); the
remaining north-star step is **components-through-the-JIT** (zwasm-side, D-500).
Live ledger: `.dev/zwasm_capabilities.md`.

## Cold-start reading order (resume)

handover → **ADR-0162/0163/0164** (cold-start arch / lazy-ns / eval auto-collect = D-519, the
next unit; DA folded in each) → `private/notes/9.2.S-coldstart-architecture-20260624.md` (the
full arc: measured attribution + payoff + gc_alloc_rate root-cause + BOTH-sites code) +
`D516-lazy-ns-survey.md` → `.dev/debt.yaml` **D-519** (next) / **D-450** (the 9 gaps,
re-measure quiet). Tools: `CLJW_PROFILE_STARTUP=1` (startup phases) / `CLJW_GC_STATS=1`
(alloc/reuse%/collects). Memories: `verify_against_releasesafe_binary` /
`smoke_first_batch_full_gate` / `perf_campaign_roadmap_9_2_s`. Campaign fast-mode injected by
`scripts/perf_campaign_remind.sh` (`.dev/.perf_campaign_active`).

## Stopped — user requested

User instruction (2026-06-24): 「すみません、コンテキストウィンドウがせまってきたので、
きりのよいところまで進め、クリアセッションからcontinueだけで自律できる配線・参照チェーン
を監査して止めてください。」(context window tightening — reach a clean point, audit the
wiring/reference chain so a fresh session resumes on `/continue` alone, then stop.)

Clean state: tree clean, HEAD pushed (≈ `51fb60af`), full gate green (394/0, stamp
`8adc3dcf` — the D-516 arc; the post-arc commits are docs + the env-gated GC_STATS counter,
diff-oracle-green). The cold-start arc (ADR-0162/0163) is DONE — floor 9.4→4.3ms, 7/9 D-450
gaps closed (cljw fastest-script ~27/30). The surviving gap gc_alloc_rate is root-caused +
its fix DESIGNED (ADR-0164, DA-vetted) but unimplemented = **D-519** (the First-task-on-resume
target above). **First action on `/continue`**: re-measure the cross-lang benches on a QUIET
Mac to confirm gc_alloc_rate is still the gap + the 7 wins hold, then implement D-519
auto-collect (ADR-0164 BOTH sites) — its KEEP/REVERT GO needs the quiet-Mac wall-clock
all-bench re-run (string_ops canary; not under load). Per-task note + precise BOTH-sites code:
`private/notes/9.2.S-coldstart-architecture-20260624.md`.
