# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT). Per-commit = smoke; commit
  **and** push (atomic Step 6). `build.zig.zon` `.zwasm` = tag pin
  `v2.2.0`. Latest release: **v1.3.1** (2026-07-16; tap bumped +
  brew-verified). CHANGELOG is the release-history SSOT.
- **First task on resume MUST be**: self-select from the live
  `.dev/debt.yaml` `active:` list, easiest-first. Fresh well-scoped
  rows from this session: **D-563** (a2: Clojure 1.12
  `Class/.instanceMethod` + `Class/new` method-value forms; (b) Var
  :line/:file source meta → clojure.test `(file:line)` suffix + AD-041
  dissolution; (c) default-data-readers / defstruct), **D-561**
  (Character getName/codePointOf name table vs gap II), D-522 comment
  de-pointering (next by density: diff_test.zig / vm.zig / print.zig).
- **Forbidden this session**: bare `zig build test` WITHOUT `-Dwasm`;
  bare `zig build` for a probe (use ReleaseSafe). **The FULL gate MUST
  run `--serial-e2e`, ALONE** (D-548 (a) future/promise SIGABRT + (b)
  pmap wall-clock stay load-sensitive; recurrence protocol in the row).
  **Never run a concurrent build during a gate.** `.claude/**` edits +
  cross-repo publishes may hit the auto-mode block — surface to the
  user. **D-549 distribution cluster (Docker/ghcr/notarization) is
  user-LOCKED**; **D-560 is trigger-gated** — neither self-selects.
  External-publish payloads need `test -s` + read-back guards (memory
  `external-publish-payload-guard`).

## Current state (2026-07-16; details = CHANGELOG + git log)

- **v1.3.0 + v1.3.1 released** — the arc the user named as the landing
  point: `java.lang.Character` complete (full-Unicode UCD tables, D-561
  = the one residual), **ADR-0171** (rt ns merged into clojure.core;
  `cljw.internal` for `__` helpers; serialize v6), CIDER completion
  parity (fixture-driven e2e `phase14_nrepl_completion`; oracle =
  `scripts/completion_oracle.py`; AD-054), the **D-562 AD full
  inventory** (all 50 rows classified — checklist
  `private/notes/D562-ad-inventory-checklist.md`; portable `(hash x)`
  values, compareTo magnitudes, locking immediates, exact parseDouble;
  AD-006/011/014/035/038/049 retired as parity, AD-009/043 narrowed),
  Clojure 1.12 **static method values**, and defrecord **ns-qualified
  identity** (print/reader-round-trip/hash parity; D-563(a) done).
- Debug tooling: `scripts/nrepl_send.py` (nREPL client),
  `scripts/clj_diff_sweep.sh` + corpora (now incl. `character.txt`,
  `hash_compare.txt`, `records_method_values.txt`).
- nREPL is single-connection (serial accept, D-117(a)): a second
  client waits while an editor is attached — probe via a fresh server,
  not the editor's port.

## Standing units (tracked in .dev/debt.yaml)

- **Perf campaign (§9.2.S) — PAUSED** (D-520 / D-386 / D-005/006).
- **D-513** — clojure.core.reducers / clojure.repl / var :doc.
- **D-548** — residual low-core exposures (a) future/promise SIGABRT
  (b) pmap wall-clock; recurrence protocol recorded in the row.
- CIDER upstream banner patch draft:
  `private/notes/cider-clojurewasm-banner-patch.md` (user-side PR).

## Stopped — user requested

User instruction (2026-07-16 朝): 「今の状況を教えて、取り組み始めて
いたようなものは完遂して、そこを停止点にしたい。パッチリリースだけ
ですか?」 → 進行中だった method values + record identity を完遂し
v1.3.1 を tag/release/tap まで届けて停止。Resume: the Resume
contract's "First task on resume" (D-563 residuals, easiest-first).

## North star (ACTIVE, distal)

cljw's differentiator = **Wasm/edge-native (gap II) × VM-perf
fusion→JIT (gap III)**. zwasm JIT (ADR-0200) is the cljw default;
remaining = components-through-the-JIT (zwasm-side, D-500). Distal —
needs a user nod; the §9.2.T public-ization sweep (easiest-first debt
drain) is the active near-term mode.

## Reading order (resume)

handover → `yq` the live `active:` list → ADR-0166 (public-ization
sweep mode) → ROADMAP §9.0. Memories:
`verify_against_releasesafe_binary` / `smoke_first_batch_full_gate` /
`external-publish-payload-guard`.
