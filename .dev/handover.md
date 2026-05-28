# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: ≈ ADR-0049 commit (Phase 14 rows 14.0-14.10 closed +
  row 14.11 partial: D-100(c)+(d) Discharged + D-066 Discharged
  + ADR-0048 + ADR-0049 minted; D-014b/D-098/D-099 Discharged
  this session; D-111..D-120 minted Active. See `git log` for
  exact HEAD).
- **First commit on resume MUST be**: a focused **row 14.11
  D-100 cluster** sub-deliverable from the still-outstanding set
  **(a)/(b)/(e)** (sub-deliverables (c) + (d) closed this
  session and are NOT to be re-opened). Recommended starting
  point: (a) full `BytecodeChunk` constants-pool serializer with
  NaN-box Value round-trip (~400 LOC; foundation for (b) + (e)).
  Alternative starts: (b) `cljw build app.clj -o app` CLI
  (~300 LOC; depends on (a) being at least partially landed for
  binary trailer write); (e) `cljw-formats/0.1.0.edn` archive
  initial commit (~80 LOC + JSON-ish opcode table; depends on
  (a) being settled). Pivot if next owner prefers: row 14.13
  remainder (compat_tiers Tier A/B review or
  `cljw.error/with-context` macro). See `.dev/debt.md` D-100
  for the multi-cycle splits + current status text.
- **Forbidden this session**: pulling the v0.1.0 release tag
  (row 14.14) forward without 14.11 fully + 14.12 + 14.13
  substantively closed. Re-opening any of rows 14.5-14.10 or
  the (c)/(d) D-100 sub-deliverables — all Discharged this
  session.

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow +
§ The only stop) → `.dev/project_facts.md` (F-001..F-009) →
`.dev/principle.md` → ADR-0049 (gate migration) →
`.dev/ROADMAP.md` §9.16 (rows 14.0-14.10 [x], 14.11 partial,
14.12+ [ ]) → `.dev/debt.md` Phase-14 debts (D-100 [partial] /
D-102 / D-104 / D-105 / D-106 / session-minted D-111..D-120).

## Current state

Phase 14 (v0.1.0 milestone) IN-PROGRESS on `cw-from-scratch`.
Phase 13 closed DONE at `797cb1a`. Mac gate green at HEAD: 85/85.
ubuntunote gate verified green at row 14.11 close: 84/84 (zlinter
diff per ADR-0003). Linux per-commit gate retired per ADR-0049;
manual via `bash scripts/run_remote_ubuntu.sh`.

This session landed (8 substantive rows + 2 ADRs + 3 partial
closures):
- 14.5 D-014b catch-by-keyword (`:type` arm)
- 14.6 D-099 user `defmacro` (analyzer arm + user-fn fallback)
- 14.7 D-098 `(ns ...)` `:exclude/:only` + `:require` libspecs
- 14.8 future/promise/delay Tier A primitives
- 14.9 ADR-0048 + `cljw repl` (line-buffered)
- 14.10 `cljw nrepl` + bencode codec + ADR-0048 chart fill
- 14.11 partial: D-100(c) `cljw render-error` + D-100(d) cold-
  start < 12 ms threshold
- 14.13 partial: D-066 (CLJW_ERROR_FORMAT + CLJW_ERROR_LOG +
  spec doc) Discharged
- ADR-0049 OrbStack retire + ubuntunote bring-up + verified

## Active task — §9.16 row 14.11 D-100 (a)/(b)/(e)

D-100 cluster remaining work:
- (a) full BytecodeChunk coverage — constants-pool serializer
  with NaN-box Value round-trip + call_sites + libspecs side-
  tables. Foundation for (b) + (e). ~400 LOC, dedicated cycle.
- (b) `cljw build app.clj -o app` CLI — Deno-style binary
  trailer + bootstrap cache build.zig integration. Depends on
  (a). ~300 LOC.
- (e) `cljw-formats/0.1.0.edn` archive v0.1.0 lock — opcode
  table snapshot for cross-version cljw render-error decoding.
  Depends on (a) opcode set being settled. ~80 LOC + the
  archive doc itself.

After D-100 closes, row 14.12 (`cljw component build`, zwasm v2
gated) + row 14.13 polish bundle remainder + row 14.14 release
tag complete Phase 14.

## Stopped — user requested

User instruction (2026-05-28, paraphrased): "render-error を
commit + push してから停止 (autonomous loop 再開は次 session)".
Resume at §9.16 row 14.11 D-100(a) when `/continue` next fires.
The OrbStack → ubuntunote migration (ADR-0049) landed in the
same final commit cycle as a user-directed sideline; per-commit
gate is now Mac-only with manual `bash scripts/run_remote_ubuntu.sh`
at boundaries.

## Guardrail refresh history

This session (2026-05-28): rows 14.5-14.10 closed + row 14.11
(c)+(d) closed + row 14.13 D-066 Discharged; ADR-0048 issued
+ REPL/nREPL charts filled; ADR-0015 a3 narrowed F142;
**ADR-0049 OrbStack retire + ubuntunote migration verified**;
D-111..D-120 minted (10 follow-up rows incl. CI Linux gate
D-120, REPL line editor D-116, nREPL polish D-117, *out*/
*err* capture D-118, mdoc man page D-119); D-014b/D-098/
D-099/D-066 Discharged.
