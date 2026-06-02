# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (clj-parity campaign wiring on `cw-from-scratch`).
  Gate green on `vm` (Mac 205; ADR-0070 / F-012). debt ledger =
  **`.dev/debt.yaml`**.
- **First commit on resume MUST be: clj-parity campaign C1 = D-164**
  (empty `()`/seq ≡ nil → distinct empty-seq Value). This is the LEAD unit
  of the **clj-parity root-cause campaign** (ROADMAP §9.2.P, ADR-0076,
  user-directed 2026-06-02): one representation fix clears `seq?`/`list?`/
  `=`/print on `()` across every seq fn — the highest-leverage trust win.
  あるべき論 = interned distinct empty value inside the existing `.list`/seq
  tags (DA-confirmed NO new NaN-box slot), threaded through cons/rest/seq/
  filter/map/print/=/list?/seq? in ONE big-bang; leave a corpus line pinning
  `(seq? '())`/`(pr-str '())`/`(= '() nil)`. Then C2 D-205 → C3 D-207 → C4
  D-209 → C6 D-200(no-slot Date) → C5 D-198(after D-048) → C7 D-165(heap-Long
  B2). Full unit table: D-210 anchor row + ROADMAP §9.2.P. All 7 units are
  loop-resolvable (ADR-0076 am1; no user-LAW amendment needed).
- **Forbidden**: "fixing" an AD-001..008 accepted divergence (set print-order,
  `(class)` simple name, error Kind, **AD-008 Long-overflow auto-promote** —
  see `.dev/accepted_divergences.yaml`); for C7 D-165, widening the NaN-box
  inline int or adding a `.date`/heap-Long slot (use **B2**: a flag on the
  heap-int, F-004 layout UNCHANGED); re-opening landed work (git log = SSOT);
  perf without a Release `scripts/perf.sh` number.

## Just landed (this session; git log = SSOT, full rows in `.dev/debt.yaml`)

- **D-206 DISCHARGED**: regex/collection String methods (`.replaceAll`/
  `.replaceFirst`/`.split`/`.toCharArray`) via a neutral `runtime/regex/
  replace.zig` leaf shared with clojure.string (F-009 option a); vector
  return-type. **D-208 DISCHARGED**: char readable-print clj-faithful (`\`+
  literal char for all non-named; corrected D-154's `\uXXXX` doc-lie).
  **D-209** recorded (map-entry?, → campaign C4).
- **clj-parity campaign + accepted-divergence framework WIRED (ADR-0076)**:
  B-half = SSOT `.dev/accepted_divergences.yaml` (AD-001..007) + rule
  `.claude/rules/accepted_divergences.md` + gate
  `scripts/check_accepted_divergences.sh` (in run_all). A-half = §9.2.P
  campaign + D-210 anchor + D-164/165 re-opened from structural-defer.

## clj-parity campaign units (the A-half; full rows in `.dev/debt.yaml`, D-210 anchor)

- **All loop-resolvable** (ADR-0076 am1, user-decided 2026-06-02): C1 D-164
  (empty≡nil, LEAD) · C2 D-205 (BigDecimal map-key) · C3 D-207 (Object
  `.toString`/`.equals`/`.hashCode`/`.getClass` fallback) · C4 D-209
  (`map-entry?` via reserved `.map_entry` slot) · C6 D-200 (no-slot
  typed_instance Date, β) · C5 D-198 (host-class exc ctors, after D-048) ·
  C7 D-165 (heap-boxed Long, B2 flag on heap-int — NO F-004 amendment; F-005
  surface already wants Long-to-i64; NaN-box i64-inline is impossible, cw v0
  also i48).
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
D-164(C1)/D-205/D-207/D-209/D-200/D-198/D-165) → CLAUDE.md (§ Project spirit +
Autonomous Workflow + The only stop) → `.dev/project_facts.md`
(F-002/004/005/009/010/011/012) → `.dev/principle.md`.

## Stopped — user requested

User instruction (2026-06-02): "まず、ねじこみで、それらを根本的に解決する調査と
取り組みをつぶし…A系は解消。Bは…妥当な差異なので、しっかり許容した、と記録…
ようにルール化や自動防御したい。次のクリアセッションからさっそく対処がねじ込まれる
よう、配線や参照チェーンを準備したあとに確認してください". DONE this session: the
B-half framework (accepted-divergence SSOT + rule + gate, AD-001..007) and the
A-half wiring (ADR-0076 + ROADMAP §9.2.P + D-210 anchor + D-164/165 re-opened,
C1..C7 ordered with the honest loop-vs-user split) landed + verified. This stop
does NOT carry across sessions — the next `/continue` resumes at the Resume
contract's C1 (D-164) task (CLAUDE.md § The only stop).
