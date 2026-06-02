# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (`.matches` D-206 part 1 on `cw-from-scratch`). Gate
  green on `vm` (Mac 205; ADR-0070 / F-012). debt ledger is **`.dev/debt.yaml`**.
- **First commit on resume MUST be: D-206 — the regex/collection
  `java.lang.String` methods** (`.replaceAll` / `.replaceFirst` / `.split` /
  `.toCharArray`; `.matches` already landed). DECIDE the structural choice FIRST
  (recorded in the D-206 row): the regex-replace (`$1` backref `expandReplacement`)
  + split-by-regex impls live in `lang/primitive/string.zig` (Layer 2) but
  `runtime/java/lang/String.zig` is runtime/ (Layer 0, can't import lang/) — so
  either (a) relocate that impl to a NEUTRAL `runtime/regex/` leaf (F-009-clean,
  shared with clojure.string), or (b) register the String regex-methods from
  lang/ into the `.string` descriptor `method_table` (needs a merge past the
  idempotent guard). `.split`/`.toCharArray` also carry an array-vs-vector
  return-type call. clj: `(.replaceAll "abc" "(.)" "$1$1")`→`"aabbcc"`,
  `(vec (.split "a,b,c" ","))`→`["a" "b" "c"]`. **Verify via the
  `clj_diff_sweep` harness** (these are value-exprs). Then the other
  structural-deferred rows in any order.
- **Forbidden**: re-sweeping the COVERAGE.md § Swept areas wholesale (java.lang
  scalar+String-simple + set/walk/numeric-keys are DONE, corpus-backed); seizing
  the F-003 structural-deferred rows (D-164 empty≡nil, D-165, D-086/088/178/179)
  incrementally — big-bang, user-gated; re-opening landed work (git log = SSOT);
  forcing a to-be-unwound representation for #inst/D-205 (both structurally
  deferred — see below); perf without a Release `scripts/perf.sh` number.

## Just landed (this session; git log = SSOT, full rows in `.dev/debt.yaml`)

- **Reader-literal family**: ADR-0073 tagged-literal infra + edn 2-arity;
  ADR-0074 `#uuid` real value type; ADR-0075 `TaggedLiteral` (slot 24). D-200
  cycles 1-4. **D-203/ADR-0072** extend-type over native/java classes.
  **D-204** name↔Tag SSOT (`class_name.fqcnForTag`).
- **Key-equality bug fixes**: uuid/tagged-literal AND BigInt/Ratio as map keys /
  set elements (the rt-free `keyEqValue` lacked numeric + value-type arms; also
  fixed non-deterministic numeric `valueHash`). D-205 part 1.
- **java.lang surface sweep** (~20 methods, corpus-backed clj-parity):
  Character (isLetterOrDigit/isUpperCase/isLowerCase/getNumericValue/forDigit),
  Integer/Long (compare/max/min), Double (toString/valueOf/compare/max/min/sum) +
  Boolean (logicalAnd/Or/Xor), String simple (lastIndexOf/isBlank/strip/
  equalsIgnoreCase/codePointAt/compareTo + indexOf-int) + `.matches`.
- Scaffolding audit (0 block; W-009/W-010 tracked). doc-lie fixes.

## Structurally-deferred (focused-cycle items; full analysis in `.dev/debt.yaml`)

- **D-206** regex/collection String methods (next — see Resume contract).
- **#inst/Date** (D-200 last piece): NO free NaN-box slot (all 64 named) → a
  dedicated `.date` tag needs a USER F-004 decision OR D-048 host_instance;
  typed_instance fallback is contested. NOT a quick `#uuid` mirror.
- **D-205 BigDecimal keys**: rt-bound (numeric `=` needs rt-aware scale
  alignment; rt-free keyEqValue can't — like lazy/range keys).
- **D-207 Object methods** (`.toString`/`.equals`/`.hashCode`/`.getClass`): need
  a dispatch-level Object fallback; LOW priority (idiomatic clj uses str/=/etc.).

## Process discipline (SSOT = memory + rules; do NOT re-expand here)

- Gate: `timeout 1800 bash test/run_all.sh --serial-e2e` (~5min actual; 1800 is
  headroom — the -P8 pool over-runs under load, memory `gate-parallel-e2e-timeout`).
  Never poll a bg gate. `clj -M -e` → `timeout 20` + bound infinite seqs. Speed
  ONLY via `scripts/perf.sh`. Tool channel corrupts under host load — verify
  greps via Read / `bash grep` (memory `tool_channel_corrupts_under_load`).

## Cold-start reading order (tracked-only)

handover → `test/diff/clj_corpus/COVERAGE.md` + `.claude/rules/clj_diff_sweep.md`
→ `.dev/debt.yaml` (open: D-206/D-205/D-207/D-200/D-198) → CLAUDE.md (§ Project
spirit + Autonomous Workflow + The only stop) → `.dev/project_facts.md`
(F-002/004/009/010/011/012) → `.dev/principle.md`.

## Stopped — user requested

User instruction (2026-06-02): "OK、では、コンテキストウィンドウがおおきくなって
きたので、かえってきて対処が済んだら、最後にクリーンセッションから、continue
できるか配線や参照チェーンを監査して、止めてください". DONE: the in-flight `.matches`
work landed (gate green, pushed); resume wiring audited — cold-start files all
present, `check_debt_id_refs` resolves all cited IDs, scaffolding audit 0-block,
and the stale `#inst` next-task pointer was repointed to D-206 above. This stop
does NOT carry across sessions — the next `/continue` resumes the loop at the
Resume contract's D-206 task (CLAUDE.md § The only stop).
