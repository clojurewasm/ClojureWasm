# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT; tip `ac1b883c`). Per-commit = smoke; commit
  **and** push (atomic Step 6). `build.zig.zon` `.zwasm` = tag pin `v2.0.0-alpha.3`.
- **First commit on resume MUST be**: continue the **EASIEST-FIRST `active:` drain**
  (CLAUDE.md § next-task rule). Read `private/notes/2026-06-25-debt-drain-order.md`
  + `yq -r '.active[]|.category+" "+.id' .dev/debt.yaml|sort`. This session cleared
  the easy interop tail — **D-472/D-480/D-532/D-511 discharged**; **D-439** re-narrowed
  to *only sqrt(MathContext) remains*; **D-471** to *File-arg done; URL/URI/Reader/stream
  remain*. Next contained candidates: **D-305** (Zig-builtin var :arglists/:doc) /
  **D-470** (`format` %t/%T date-time, ~40 sub-conv) / **D-222** (*flush-on-newline*) /
  **D-460** (sorted-coll-as-key, rt-free wrinkle). Deferred-by-tractability (bigger,
  NOT abandoned): **D-439 sqrt** (correct-rounding + JDK preferred scale; base =
  Managed.sqrt), **D-526 Arrays/Collections** (new surface), **D-446 multidim aget/aset**
  (perf-vs-F-009-layering DA-fork). A correctness / clj-parity floor still PREEMPTS.
- **Forbidden this session**: bare `zig build test` WITHOUT `-Dwasm`; bare `zig build`
  for a probe (use ReleaseSafe). **The FULL gate MUST run `--serial-e2e`** — the `-P8`
  parallel default flakes the **D-418/D-258 agent load-race** (`agent_conj` →
  `[#<promise> 2]`; green isolated/serial, NOT a regression). **Never run a concurrent
  build during a gate** (host contention → false timeout). `.claude/**` edits may hit
  the auto-mode self-modification block — surface those to the user.

## Last landed (git log = SSOT)

Easiest-first `active:` drain (2026-06-25): **D-472** `bytes?` (over-broad = `array?`
per AD-051, type-erasure-forced; DA-fork recommended always-false, overridden by a
probe). **D-480** `instance? Serializable` (last deferred marker; clj-oracle all tags,
`multi_fn` EXCLUDED — MultiFn is not AFunction). **D-439** BigDecimal `scaleByPowerOfTen`/
`ulp`/`divideAndRemainder`. **D-532** BigInteger `.add/.subtract/.multiply/.divide` (new
`allocDivTruncManaged` — trunc-toward-zero). **D-471** slurp/spit accept a `java.io.File`
arg (R4-clean coerceToPath). **D-511** exact `(BigDecimal. double)` ctor (reuses
`allocFromRatioParts`). **D-535** opened (user-directed): Java-interop import-gating
parity — the Java analogue of D-516/ADR-0163, deferred to the import-semantics owner
alongside D-461.

## Standing units (tracked in .dev/debt.yaml)

- **Perf campaign (§9.2.S) — PAUSED** (cheap levers exhausted; D-520 / D-386 / D-005/006).
- **D-439 sqrt(MathContext)** — the one BigDecimal remnant; a focused numeric cycle
  (correct rounding ×8 modes + JDK preferred output scale; base = the native Managed.sqrt).
- **D-513** — clojure.core.reducers / clojure.repl / var :doc (foundational).
- **D-418/D-258** — agent send/await + GC load-race (open, recall-trigger; re-gate serial).

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

## Stopped — user requested

User instruction (2026-06-25, verbatim): 「では、きりがよくなったら、配線・参照
チェーンをクリアセッションからcontinueだけで続けられるよう監査し、停止してください。」
DONE: (1) D-511 landed (the break-point); (2) wiring / reference-chain audit —
debt.yaml well-formed, active=84 / standing=34 / discharged=404, NO dup ids, NO
misfiled DISCHARGED-in-active rows, the 4 session-discharged rows all in
`discharged:`, D-535 in `active:`, `check_debt_id_refs` ok (no phantom), commit
chain fully pushed (tip `ac1b883c`); (3) the resume contract above re-pointed at the
new easiest-first frontier. Resume = `/continue` drains `active:` easiest-first. The
3-item extended-challenge (alt / next experiment / blocker) is in
`private/notes/9.2.T-D511-bigdecimal-double-ctor.md`.
