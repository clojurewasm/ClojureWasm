# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `b132baf6` (`cw-from-scratch`; see `git log` for drift). Tree clean,
  **0 unpushed**. Mac gate green (179).
- **First commit on resume MUST be**: the next clj-differential-sweep unit =
  **Integer/Long bit static methods** (`Integer/bitCount`,
  `Long/numberOfLeadingZeros`, `numberOfTrailingZeros`, `highestOneBit`,
  `reverse`). Verified gaps (clj `(Integer/bitCount 7)`→3, `(Long/numberOf
  LeadingZeros 1)`→63; cljw errors "No namespace"). Add to the EXISTING
  `runtime/java/lang/{Integer,Long}.zig` method_table (`@popCount`/`@clz`/
  `@ctz`); same `___HOST_EXTENSION` pattern, no new infra. Step 0 may be
  skipped (clear continuation of the landed statics; survey note already
  covers Integer/Long).
- **Operating mode** = clj differential sweep (F-011): probe a category through
  BOTH `clj` and `cljw`, diff, fix every divergence at the finished form;
  commonise rather than per-op patch. Deep/unresolvable → master ledger entry +
  `.dev/debt.md` D-NNN. Fully autonomous; loop self-selects per F-002 (may
  weigh the higher-value structural items in Open debts over bit-method
  coverage).
- **Forbidden**: re-opening anything landed (git log = SSOT). JIT/superinstruction
  (perf deferred, D-163). Touching `tree_walk.zig`/`vm.zig` for statics/fields
  (they resolve to `.constant` Node / shared builtins — backend-agnostic; the
  diff oracle verifies parity).

## Process discipline (load incident 2026-05-31 — full detail in memory + rules)

- **Never poll a background gate** (`sleep N; cmd` is harness-blocked): launch
  `run_in_background`, yield, act on the completion notification, read once.
- **`clj -M -e` MUST be `timeout 20`-wrapped** (infinite-seq orphan → ~160% CPU).
- **Never pass `\a`-style char literals through `cljw -e`** (shell eats `\`); use
  `(char N)`.
- **Under load, capture probe output to `/tmp/*.txt` and Read it**; bare reads can
  be garbled. One Claude session per repo — 2026-05-31 confirmed only this
  session on cljw (others were zwasm/myskill).
- **Defender exclusions** (`mdatp exclusion`): verify post-reboot via
  `mdatp exclusion list`, re-add any dropped (zig + project `.zig-cache`/`zig-out`
  + `~/.cache/zig`).

## Current state

java.lang scalar-class **static cluster COMPLETE** (cluster A26, cycles A-G,
`678b78ba..b132baf6`): Integer / Long / Double / Character / Boolean static
methods + fields, Math PI/E/floorDiv/floorMod. Landed the static-field
resolution mechanism (**ADR-0061** + amendment: `TypeDescriptor.static_fields`,
`.bool` variant) and a shared `runtime/numeric/parse.zig` leaf. Invariants:
**F-011** (commonisation/behavioural-equivalence; clj oracle wired) + F-010.

## Master divergence ledger (compaction-survival)

[`private/notes/phaseA26-clj-differential-oracle.md`](../private/notes/phaseA26-clj-differential-oracle.md)
holds every clj diff (fixed + unresolved + acceptable), the oracle recipe, the
swept categories, the next-sweep candidates (bit methods / Math `*Exact`), and
the remaining Java-interop gap list. **Read it first on resume.** Per-task
notes: `private/notes/phaseA26-*.md`.

## Open debts (full rows in `.dev/debt.md`)

- **D-166** float printer never uses scientific notation (clj/Java switch at
  |x|≥1e7 or <1e-3); affects ALL extreme doubles. Higher-value correctness item
  the loop may pick over bit-method coverage (Java Double.toString thresholds +
  shortest round-trip in print.zig). open.
- **D-164** empty-seq≡nil: cljw collapses `()` to nil. The biggest structural
  parity gap (own cycle). open.
- **D-165** i48→i64 long range prints as BigInt `N` (value exact; F-004 NaN-box).
  open, numeric-tower owner.
- **D-163** perf ~100µs/element (F-010 post-M perf phase, NOT premature JIT).
- **D-167 DISCHARGED** (3a79ce6d): `<`/`>`/`neg?`/`pos?` now correct for
  BigInt/Ratio/BigDecimal.
- **Acceptable divergences**: `(class 5)`→`Long` not `java.lang.Long` (ADR-0059);
  `(float 1/3)` f64 not f32; set print order; `(rest "abc")` substring.

## Cold-start reading order

handover → master ledger (above) → CLAUDE.md (§ Project spirit + Autonomous
Workflow + The only stop) → `.dev/project_facts.md` (F-011 + F-010) →
`.dev/principle.md` (Bad Smell) → `.dev/reference_clones.md` (clj oracle).

## Stopped — user requested

User instruction (2026-05-31): "では、もとの作業をきりのよいところまで進めて、
クリアセッションからのcontinueのために、配線・参照チェーンを確認して修正したら、
止めておいてください". cluster A26 Java statics advanced to a clean point (cluster
complete, gate 179, all pushed); wiring/reference chain verified. Resume per the
Resume-contract First-commit line — Integer/Long bit static methods.
