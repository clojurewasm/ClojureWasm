# Optimizations ledger (SSOT)

> **Purpose.** A discoverable index of every place where cljw's code is
> shaped for *speed* rather than for the simplest correct form. The
> user's directive (2026-05-31): *"将来の最適化のとき、「最適化してる
> んだよ」と分かりやすく — 理想は SSOT 的な箇所があること"*. This is that
> SSOT. Optimizations come in many kinds and not all fit one registry
> cleanly, so this is a **best-effort index**, paired with the
> grep-discoverable in-code `// PERF:` marker
> (see [`.claude/rules/perf_marker.md`](../.claude/rules/perf_marker.md)).
>
> An entry answers: *what is the naive correct form, what is the
> optimized form, why is it faster, and what verifies they agree?*
> The naive form is the behavioural contract; the optimization must be
> observably equivalent (F-011) — only the internal mechanics change.

## How to read / maintain

- Every optimization that trades simplicity for speed gets (a) a
  `// PERF: <what> [refs: O-NNN, …]` marker at the code site and
  (b) a row here. The `O-NNN` id is this ledger's; cross-ref the
  driving `D-NNN` debt row when one exists (perf debt lives in
  `.dev/debt.md`; this ledger is the *implemented* optimizations).
- A "fast path" that can be removed and replaced by the naive form
  with no behaviour change is the cleanest kind — note the naive
  fallback explicitly so a future reader can verify by deletion.
- When an optimization is reverted / superseded, mark the row
  `RETIRED <date>` rather than deleting it (history).

## Entries

| ID    | Site                                         | Naive form (the contract)                                                                                  | Optimized form                                                                                         | Why faster                                                                                                                                                  | Verified by                                       | Refs          |
|-------|----------------------------------------------|------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------|---------------|
| O-001 | `runtime/collection/range.zig` + call sites  | `(range a b s)` as a lazy cons-seq (one cons + lazy_seq per element)                                       | Compact `.range` value `{start,end,step,count}`: O(1) count/nth, tight-loop reduce, chunked-cons `seq` | No per-element alloc on count/nth/reduce; 1 alloc/32 on walk                                                                                                | `phase14_range_indexed.sh` + diff oracle vs `clj` | D-163 / D-168 |
| O-002 | `higher_order.zig::reduceFn` (`.vector` arm) | `reduce` over a vector via `seqFn` → `vectorToList` (N-element eager cons list), then walk via first/next | Index-walk: `vector.nth(coll, i)` in a tight `i` loop, honouring `reduced`                             | No N-element intermediate cons list; `(reduce f bigvec)` / `(into to bigvec)` went O(n) alloc → O(1). Measured `(reduce + (vec (range 1e6)))` 182s → fast | `phase14_*` reduce e2e + diff oracle vs `clj`     | D-163         |

## Out-of-scope future optimizations (tracked, not yet implemented)

- **Map/filter/take reduce-fusion** (cw v0 `fusedReduce`: collapse a
  `(reduce f (map g (filter p (range n))))` chain to a single 0-alloc
  pass over the base). The compact `.range` value (O-001) is the
  substrate this operates over. Deferred to the D-163 perf window as
  its own ADR. cw v0 measured 1336x on lazy_chain — see D-163's cw-v0
  blueprint note.
