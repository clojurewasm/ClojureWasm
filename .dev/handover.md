# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT). Per-commit = smoke; commit
  **and** push (atomic Step 6). `build.zig.zon` `.zwasm` = tag pin
  `v2.2.1` (binary-size release). Latest release: **v1.4.0** (2026-07-16; the binary-size
  campaign release — 6,974,584 B; tap bumped + brew-verified). CHANGELOG is the release-history SSOT.
- **First task on resume MUST be**: self-select from the live
  `.dev/debt.yaml` `active:` list, easiest-first. Fresh well-scoped
  rows: **D-563** (a2: Clojure 1.12
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
- **Binary-size campaign COMPLETE** (2026-07-16, user-directed):
  **9,469,816 → 6,974,584 B (−26.3%, sub-7MB)**. ADR-0172 (budget +
  levers + `size_claims`/ceiling gate + `.claude/rules/binary_size.md`),
  ADR-0173 envelope v7 (WireInstr zero-copy, constant pool, flate lazy
  regions + .clj sources — D-517 DISCHARGED), zwasm v2.2.1 re-pin
  (thunk collapse −1.08MB, CODEV same-day round-trip), O-052/O-053.
  Full cross-language bench re-recorded (bench/cross-lang-latest.yaml
  2026-07-16) + RELEASE_METRICS refreshed (6.97MB / ~6ms).
- Debug tooling: `scripts/nrepl_send.py` (nREPL client),
  `scripts/clj_diff_sweep.sh` + corpora (now incl. `character.txt`,
  `hash_compare.txt`, `records_method_values.txt`),
  `scripts/binary_size_report.sh` (size report + claims check).
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
