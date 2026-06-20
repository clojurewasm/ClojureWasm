# zwasm capability ledger — cljw's view of the embedded Wasm runtime (F-001)

> **SSOT for "what does the zwasm we embed offer, and what has cljw adopted".**
> cljw embeds **zwasm v2** (F-001, unavoidable) as a SHA-pinned dependency. zwasm
> is itself under active co-development (`~/Documents/MyProducts/zwasm_from_scratch`,
> branch `zwasm-from-scratch`) and its embedding API is *growing* — notably toward
> a **JIT-backed engine** (the cljw north star, ROADMAP §9.0 gap area II × III).
> This file is the durable record so the loop never re-derives "is zwasm's JIT
> ready yet?" from scratch.

## The read-at-boundaries convention (why this file exists)

The cljw loop **cannot infer zwasm's status from its own tree** — the pin is frozen
at one commit while zwasm moves on. So, at every **gap-area-unit start** (CLAUDE.md
Step 1a) **and every Phase boundary**, the loop MUST:

1. Read THIS file (cljw's recorded view + adoption status).
2. Refresh it against zwasm's **live** status sources (below). If zwasm shipped a
   capability cljw's north star needs, update the table here + decide adoption.
3. Treat a capability as **adoptable only when zwasm marks it ready AND cljw bumps
   the pin** (`build.zig.zon`) — never adopt against an unpinned/moving API.

This mirrors the existing **CODEV co-development protocol** (zwasm
`private/CODEV_PROTOCOL.md` + the `from_cljw_NN`/`to_cljw_NN` mailbox); this ledger
is its lightweight, always-on, git-tracked face on the cljw side. When cljw actually
*needs* a not-yet-ready zwasm capability, the request goes through the mailbox
(finished-form, request-don't-workaround), not a cljw-side shim.

## zwasm live status sources (read these to refresh the table)

| Source                                                               | What it tells you                                         |
|----------------------------------------------------------------------|-----------------------------------------------------------|
| `~/Documents/MyProducts/zwasm_from_scratch/private/CODEV_STATUS.md`  | live co-dev state + mailbox + verification snapshot       |
| `~/Documents/MyProducts/zwasm_from_scratch/.dev/ROADMAP.md`          | zwasm phase plan (p17 = JIT)                              |
| `~/Documents/MyProducts/zwasm_from_scratch/.dev/decisions/0200_*.md` | ADR-0200 — JIT-DEFAULT engine + research-driven API      |
| `git -C ~/Documents/MyProducts/zwasm_from_scratch log --oneline -15` | recent JIT work (zwasm#477 multi-arg invoke arm64/x86_64) |

## Pin

- **cljw pins zwasm @ `412966f79c6ca10a6fdf0c33c9e2c742b311a66e`** (`build.zig.zon`,
  hash `zwasm-0.0.0-pre-FT1Fv3wnfwBytPcvTE5ng09lCvi8qKtZfk17FTLiunhM`). This is a
  **pre-JIT** commit — the embedding API at this pin is **interp-only**.
- `lazy` dependency: the default build + gate never resolve it; only `-Dwasm` /
  `-Dzwasm-spike` do. So a stale pin never breaks the day-to-day gate — it only
  gates what `cljw.wasm/*` can do.
- Pin-bump procedure: zwasm `docs/consuming_prerelease_zwasm.md`. Bump is **user-
  gated** (a moving north-star API; the loop proposes, the user confirms the SHA).

## Capability table (refresh at each boundary)

| Capability                           | zwasm status (as of 2026-06-20)                       | in cljw's pin? | cljw adoption                            | ref             |
|--------------------------------------|-------------------------------------------------------|----------------|------------------------------------------|-----------------|
| Interp embedding (load/instantiate)  | ready                                                 | YES            | integrated behind `cljw.wasm/*` (-Dwasm) | F-001, D-036    |
| `invoke` (call exported fn)          | ready (interp)                                        | YES            | integrated                               | D-036           |
| Embedder hardening / WASI sandbox    | landed (security pass `…→6b08fe70`, 3-host green)   | mostly         | consumed `to_cljw_01`                    | CODEV           |
| **Multi-arg JIT invoke (≤5/7 GPR)** | **BUILDING** (zwasm#477, arm64 + x86_64 SysV thunks)  | NO (pre-JIT)   | NOT adopted                              | zwasm zwasm#477 |
| **JIT-backed engine (JIT-DEFAULT)**  | **BUILDING / DESIGN** (ADR-0200 reverses interp-only) | NO             | NOT adopted — **the north-star adopt**  | zwasm ADR-0200  |
| WIT component marshalling            | future                                                | NO             | NOT adopted                              | D-404           |

## Forward plan — the JIT adoption unit (gap area II × III)

The north-star capability is **running Wasm components through zwasm's JIT engine**
from cljw. The trigger + shape:

1. **Trigger**: zwasm cuts a commit/tag where ADR-0200's JIT engine + zwasm#477 invoke
   are *embedder-stable* (its CODEV_STATUS says so, or a `to_cljw_NN` announces it).
2. **cljw action**: bump the `build.zig.zon` pin (user-confirmed) → open a gap-area-II
   adoption unit: thread an `:engine :jit` (or auto) option through the finished-form
   `(wasm/load path opts)` surface (D-350), keep interp as the fallback/default until
   JIT is proven, add a diff-oracle/e2e that runs the SAME module both engines and
   asserts equal results (the F-012 discipline applied to engine choice).
3. **Do NOT** speculatively build a JIT facade in cljw before zwasm's API stabilises
   (the CODEV stance: request-don't-workaround; F-002 finished-form, not a shim).

D-036 is the master integration row; D-350 the embedding-API shape; this ledger is
the capability tracker that tells the loop *when* the JIT row flips from BUILDING to
adoptable.

## Revision log

- **2026-06-20** — ledger created (user-directed convention). Pin = pre-JIT
  `412966f7`. zwasm JIT (ADR-0200 / zwasm#477) recorded as BUILDING, not yet adoptable.
