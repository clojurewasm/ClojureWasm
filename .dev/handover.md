# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (D-200 UUID value type + D-204 name↔Tag SSOT on
  `cw-from-scratch`). Gate green on `vm` (Mac 205; ADR-0070 / F-012). debt
  ledger is **`.dev/debt.yaml`** (structured YAML).
- **First commit on resume MUST be: D-200's last piece — the `#inst` /
  `java.util.Date` value-type ADR + impl.** This is a GREENFIELD (unlike
  `#uuid`, there is NO Date value type, NO `clojure.instant.clj` peer, NO
  ISO-8601 parser today — `runtime/time/instant.zig` + `java.util.Date` /
  `java.time.Instant` surfaces exist but no reader-literal value). Do a Step 0
  survey of `clojure.instant`'s grammar (`~/Documents/OSS/clojure/src/clj/
  clojure/instant.clj` L100-274) + the existing `runtime/time/` impl, then an
  ADR + mandatory Devil's-advocate fork deciding the Date representation
  (mirror ADR-0074's real-type decision: a `.inst`/Date heap value vs
  string/long). Register `#inst` in the root `*data-readers*` (sibling to the
  `uuid` reader landed this session) + add `inst?` / `inst-ms`. **Verify via
  e2e** (top-level forms) — `clj_diff_sweep` can NOT batch reader/define forms.
- **Lighter alternative if Date is deferred**: the generic `tagged_literal`
  (NaN-box slot 24, reserved-unused) carrier as the unknown-tag FALLBACK —
  changes ADR-0073's raise contract to a non-throwing carrier + adds
  `tagged-literal` / `tagged-literal?`. Its own decision; clj-grounded.
- **Forbidden**: re-sweeping COVERAGE.md § Swept areas wholesale; seizing the
  F-003 structural-deferred rows (D-164 empty≡nil, D-165 i48→i64, D-086/088/
  178/179) incrementally — big-bang, user-gated; re-opening landed work
  (git log = SSOT); perf without a Release `scripts/perf.sh` number.

## Just landed (git log = SSOT; full rows in `.dev/debt.yaml`)

- **D-203 / ADR-0072** extend-type/extend-protocol over native/java classes
  (analyzer native-class symbol resolution → `nativeDescriptor(tag)` identity).
- **D-200 / ADR-0073** EDN tagged-literal reader infra: `#tag form` →
  `FormData.tagged` → `formToValue` data-reader dispatch over `*data-readers*`
  / `*default-data-reader-fn*` (`^:dynamic` Vars, BindingFrame-honoured) +
  `reader_tag_unknown` clj-parity raise; `clojure.edn/read-string` 2-arity
  `[opts s]` (`:readers`/`:default`/`:eof`).
- **D-200 cycle 3 / ADR-0074** `#uuid` reads to a REAL `.uuid` heap value
  (slot 31), round-trips via `pr-str`, `uuid?`/`class`/`=`; `random-uuid` /
  `parse-uuid` / `java.util.UUID/randomUUID` migrated to it.
- **D-204** name↔Tag SSOT consolidation (`class_name.fqcnForTag`); fixed
  `(class #"x")`→`Pattern` + `(instance? clojure.lang.BigInt 1N)` etc.

## Remaining (pointers — full text in `.dev/debt.yaml` + COVERAGE.md)

- **D-200 (still open)**: `#inst`/Date value-type (next) + the generic
  `tagged_literal` fallback carrier.
- **Structural-deferred (F-003, big-bang, user-gated)**: D-164 empty≡nil
  (highest-leverage single fix), D-165 i48→i64, D-086/088/178/179, D-105.
- **v0.1.0 closeout**: Phase 14.14 — exit-smoke + `phase_at_least_14` flip +
  tag (D-047 unblocks ≥2^64 on Linux).
- **Perf §9.2.S CLOSED**: re-open ONLY with a Release `scripts/perf.sh` number.

## Process discipline (SSOT = memory + rules; do NOT re-expand here)

- Gate: `timeout 1800 bash test/run_all.sh --serial-e2e` (the -P8 pool times
  out under load — memory `gate-parallel-e2e-timeout`). Never poll a bg gate.
  `clj -M -e` → `timeout 20`-wrap + bound infinite seqs. Speed ONLY via
  `scripts/perf.sh` (Release). Tool channel corrupts under host load — verify
  greps via Read / `bash grep` (memory `tool_channel_corrupts_under_load`).

## Cold-start reading order (tracked-only)

handover → `test/diff/clj_corpus/COVERAGE.md` (sweep state) +
`.claude/rules/clj_diff_sweep.md` → `.dev/debt.yaml` (open: D-200) →
CLAUDE.md (§ Project spirit + Autonomous Workflow + The only stop) →
`.dev/project_facts.md` (F-002/004/009/010/011/012) → `.dev/principle.md`.
