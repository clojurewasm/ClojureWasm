# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: ≈ `3d8f9326` (Phase 14 rows 14.0-14.10 closed;
  ADR-0048 minted + nREPL chart filled; ADR-0015 a3 narrowed F142;
  D-098/D-099/D-014b Discharged this session; D-111..D-118 minted
  Active. See `git log` for exact HEAD).
- **First commit on resume MUST be**: a focused **row 14.11
  (D-100 cluster — Phase-12 substantive deliverables, multi-cycle)**
  sub-deliverable. The cluster has 5 sub-pieces (a-e); each is
  itself a single-cycle landing. Recommended starting point:
  (c) `cljw render-error` post-mortem decoder (~200 LOC standalone;
  no bytecode-cache dependency). Alternative starts: (a) full
  BytecodeChunk constants-pool serializer (~400 LOC; foundation
  for b+e), (d) cold-start bench < 12 ms verification (mostly
  measurement work), (e) `cljw-formats/0.1.0.edn` archive lock
  (needs (a) first). Pivot if next owner prefers: row 14.13
  polish bundle sub-piece (D-066 env var spec + man page ~120 LOC,
  or `cljw.error/with-context` macro ~80 LOC).
- **Forbidden this session**: pulling the v0.1.0 release tag (row
  14.14) forward without 14.11/14.12/14.13 substantively closed.
  Re-opening rows 14.5-14.10 — fully Discharged this session.

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow +
§ The only stop) → `.dev/project_facts.md` (F-001..F-009) →
`.dev/principle.md` → `.dev/ROADMAP.md` §9.16 (rows 14.0-14.10
[x], 14.11+ [ ]) → `.dev/debt.md` Phase-14 debts (refined
barriers: D-100 [cluster] / D-102 / D-104 / D-105 / D-106 / D-066
+ session-minted D-111..D-118).

## Current state

Phase 14 (v0.1.0 milestone) IN-PROGRESS on `cw-from-scratch`. Phase
13 closed DONE at `797cb1a`. Gate green at HEAD: Mac 82/82 +
OrbStack Ubuntu x86_64 81/81.

This session: rows 14.5 → 14.10 landed (6 substantive rows in one
session). ADRs touched: ADR-0048 minted (state machine domain;
REPL + nREPL charts filled), ADR-0015 a3 (F142 path table
narrowed). Debts minted this session (D-111..D-118):
- D-111: `&form`/`&env` injection follow-up (defmacro Phase 11+).
- D-112: `:rename` arm for ns / refer (opportunistic).
- D-113: promise undelivered blocking semantics (Phase 15.1).
- D-114: future `std.Thread.spawn` swap (Phase 15.1).
- D-115: future thunk-error Value channel (Phase 15.1).
- D-116: REPL line editor (arrow-key / multi-line; opportunistic).
- D-117: nREPL multi-session / interrupt / CIDER ops / auto-port
  (Phase 15+).
- D-118: nREPL stdout/stderr capture (needs `*out*` binding).

Rows landed:
- 14.5 D-014b catch-by-keyword (`:type` arm)
- 14.6 D-099 user `defmacro` (analyzer arm + user-fn fallback)
- 14.7 D-098 `(ns ...)` `:exclude/:only` + `:require` libspecs
- 14.8 future/promise/delay Tier A primitives
- 14.9 ADR-0048 + `cljw repl` (line-buffered)
- 14.10 `cljw nrepl` + bencode codec + ADR-0048 chart fill

## Active task — §9.16 row 14.11 (D-100 cluster start: `cljw render-error`)

D-100 is the Phase-12 substantive deliverables cluster: (a)
BytecodeChunk full coverage / (b) `cljw build` CLI / (c) `cljw
render-error` decoder / (d) cold-start bench < 12 ms / (e)
`cljw-formats/0.1.0.edn` archive lock. Each is multi-cycle.
Recommended next: (c) — standalone decoder + EDN error event
format (`runtime/error/event.zig` + `src/app/render_error.zig`
+ TTY-aware split). ~200 LOC. Independent of (a)/(b)/(d)/(e).

## Guardrail refresh history

This session (2026-05-28): rows 14.5-14.10 closed; ADR-0048 issued
+ REPL/nREPL charts filled; ADR-0015 a3 narrows F142 file layout;
D-111..D-118 minted (8 new follow-up rows for Phase 11+/15.1+
work); D-014b/D-098/D-099 Discharged (TreeWalk paths fully
landed; VM-DEFER for 14.5/14.7 per feature_deps yaml). Phase 13→14
boundary (earlier 2026-05-28): §9.16 expanded inline (15 rows);
D-082 / D-008 / D-017 / D-026 / D-030 / D-069 / D-070 Discharged.
Phase 13 landmarks: ADR-0010 a3 + ADR-0047 minted.
