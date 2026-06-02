# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (clj-parity campaign on `cw-from-scratch`).
  Gate green (Mac 206). debt ledger = **`.dev/debt.yaml`**.
- **First commit on resume MUST be: clj-parity campaign C7 = D-165**
  (the LAST campaign unit): Longs in (2^47, 2^63] print as BigInt `…N` where
  JVM keeps a primitive Long. あるべき論 = **heap-boxed Long, representation B2**
  (a `Long-origin/fits-i64` flag on the heap-integer struct — NO new NaN-box
  slot, F-004 layout UNCHANGED; F-005's surface already wants Long-to-i64;
  NaN-box i64-inline is impossible, cw v0 also i48). `(class)`→Long + print
  no-`N` for the (2^47, i64] window; promote to BigInt only PAST i64. The
  overflow-past-i64 behaviour (cljw promote vs clj throw) is the separate
  user-ratified **AD-008**, NOT this row. C1–C6 (D-164/205/207/209/200/198)
  all DONE. After C7, the clj-parity campaign C1..C7 is COMPLETE — D-210
  anchor becomes a standing `quality-loop floor` (drain new sweep DIFFs).
  Full unit table: D-210 anchor + ROADMAP §9.2.P.
- **Forbidden**: "fixing" an AD-001..008 accepted divergence (set print-order,
  `(class)` simple name, error Kind, **AD-008 Long-overflow auto-promote** —
  see `.dev/accepted_divergences.yaml`); for C7 D-165, widening the NaN-box
  inline int or adding a `.date`/heap-Long slot (use **B2**: a flag on the
  heap-int, F-004 layout UNCHANGED); re-opening landed work (git log = SSOT);
  perf without a Release `scripts/perf.sh` number.

## Just landed (this session; git log = SSOT, full rows in `.dev/debt.yaml`)

- **C1 D-164 DISCHARGED**: distinct empty list `()` (interned count-0 `.list`
  on `rt.empty_list`, no new NaN-box slot) threaded big-bang through rest/
  empty/take/print/analyzer/**serialize**/lazy_seq.seq/core.clj; `()` truthy,
  `(seq?/list? '())`→true, `(= '() nil)`→false. Corpus `empty_seq` (70).
- **C2 D-205** (ADR-0077): BigDecimal scale-independent map-key via a cached
  stripped projection; **C3 D-207**: universal Object methods (`.toString`/
  `.equals`/`.hashCode`/`.getClass`) via dispatch fallback → str/=/hash/class
  (AD-009, AD-003; surfaced D-212). See git log + debt rows.
- **C4 D-209** (ADR-0078): distinct MapEntry (reserved `.map_entry` slot,
  ~16 op arms, `map-entry?`/`class`, conj→plain-vector). Corpus `map_entry`.
- **C6 D-200** (ADR-0079): `#inst`/Date as a no-slot `typed_instance`
  (per-Runtime descriptor, `print_tag="inst"`, epoch-ms; civil↔ms in
  `runtime/time/instant.zig`); inst?/inst-ms, `=` by epoch-ms. Corpus `inst_date`.
- **C5 D-198 DISCHARGED**: Throwable-family CONSTRUCTORS `(Exception. msg)` etc
  via the `<init>` method_table hook (both backends) → an `.ex_info` tagged with
  the class name (no-JVM, ADR-0059/0060); throw/catch/getMessage/instance? ride
  the existing bridge. Corpus `host_exception_ctor` (14). Surfaced **D-213**
  (`(class e)`→"ex_info" not the specific class — pre-existing, all exceptions).

## clj-parity campaign units (the A-half; full rows in `.dev/debt.yaml`, D-210 anchor)

- **All loop-resolvable** (ADR-0076 am1): C1 D-164 / C2 D-205 / C3 D-207 /
  C4 D-209 / C6 D-200 / C5 D-198 DONE · **C7 D-165** (LAST: heap-boxed Long,
  B2 flag on heap-int — NO F-004 amendment; NaN-box i64-inline is impossible,
  cw v0 also i48). After C7 the campaign is complete.
- **Decided, NOT campaign units**: AD-008 (Long overflow past i64 auto-promotes
  per F-005; clj throws — accepted divergence, user-ratified) · D-211 (`+'`/`*'`
  promoting arithmetic deferred; F-005's `+'`-clause is clj-inverted).

## Process discipline (SSOT = memory + rules; do NOT re-expand here)

- Gate: `timeout 1800 bash test/run_all.sh --serial-e2e` (~5min actual; 1800 is
  headroom — the -P8 pool over-runs under load, memory `gate-parallel-e2e-timeout`).
  Never poll a bg gate. `clj -M -e` → `timeout 20` + bound infinite seqs. Speed
  ONLY via `scripts/perf.sh`. Tool channel corrupts under host load — verify
  greps via Read / `bash grep`; and it TRANSCODES literal non-ASCII in
  Edit/Write (build expected non-ASCII via `printf` in tests, keep files ASCII).

## Cold-start reading order (tracked-only)

handover → `.dev/decisions/0076_clj_parity_campaign_and_accepted_divergences.md`
+ ROADMAP §9.2.P → `.dev/accepted_divergences.yaml` +
`.claude/rules/accepted_divergences.md` → `test/diff/clj_corpus/COVERAGE.md` +
`.claude/rules/clj_diff_sweep.md` → `.dev/debt.yaml` (open: D-210 anchor /
D-165(C7) + D-212 + D-213) + `.dev/decisions/0077_*`/`0078_*`/`0079_*` (C2/C4/C6) → CLAUDE.md
(§ Project spirit + Autonomous Workflow + The only stop) →
`.dev/project_facts.md` (F-002/004/005/009/010/011/012) → `.dev/principle.md`.
