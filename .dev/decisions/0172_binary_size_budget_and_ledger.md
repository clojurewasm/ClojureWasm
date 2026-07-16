# ADR-0172 — Binary size: measured composition, per-component budget, lever ledger, and a size-claims gate (the binary-size SSOT)

- **Status**: Proposed → Accepted (2026-07-16; user-directed investigation; DA
  fork folded verbatim below)
- **Driven by**: user report (2026-07-16): the brew-installed cljw shows ~9.5-9.8
  MB while README still claimed "about 3.8 MB" — "バイナリサイズが小さい、と名乗れ
  なくなってきた". The user asked for a root-level investigation (build flags,
  Clojure/JVM/Zig angles), self-critiqued options, a concrete ADR, and a
  consolidation of every scattered binary-size mention (debt rows + ADR
  fragments) into one place.
- **Relates to**: D-515 (binary-size debt axis — re-narrowed to point here),
  D-277 (eager-comprehensiveness-vs-size standing tension), D-517 / ADR-0162 /
  ADR-0163 (envelope format + lazy-ns — the embedded-data lever folds into
  D-517), ADR-0158 (single-binary component embedding), ADR-0132 (ReleaseSafe =
  gated/shipped config), O-008 (release strip, `.dev/optimizations.md`),
  F-001 (zwasm unavoidable), F-002 (finished-form wins), F-011 (behavioural
  equivalence), F-013 clause 4 (comprehensiveness bounded by single-binary
  cost), F-014 (scope goal line).

## Context

### The incident, and why the old targets died

The shipped macOS arm64 binary (v1.3.1, ReleaseSafe, `-Dwasm`, stripped) is
**9,469,816 bytes (~9.5 MB decimal)**. Four tracked documents disagreed with
that reality and with each other:

| Location                         | Stale claim                             |
|----------------------------------|-----------------------------------------|
| `README.md` (Features)           | "about 3.8 MB"                          |
| `ROADMAP.md` §"No JVM" top-line | "target binary ≤ 5 MB"                 |
| `ROADMAP.md` §10.3 targets      | "< 3.5 MB target / < 2 MB stretch"      |
| `.dev/debt.yaml` D-515           | "8.8 MB (incl. a ~1.4 MB … blob)"      |
| `test/run_all.sh` comment        | "ReleaseSafe ≈ 3.5 MB … exceeds 8 MB" |

The pre-engine targets were not merely missed — they became **arithmetically
unreachable the day F-001's engine landed in the text segment**: the embedded
zwasm engine + component-model API alone is ~3.0 MB of code, i.e. F-001's
mandatory payload exceeds the old §10.3 target by itself. The binary grew
because the differentiator (Wasm FFI with an embedded JIT) and the
comprehensiveness laws (F-013/F-014: full-Unicode UCD tables, spec.alpha
bundled, CIDER-fidelity nREPL, TLS-capable http client) landed. The growth is
a consequence of the mission; the rot was that no mechanism compared any prose
claim against the measured artifact. Both problems are fixed here: honest
numbers derived from measurement, and a gate that keeps them honest.

### Measured composition (2026-07-16, macOS arm64, v1.3.1 config)

Total 9,469,816 B. Method: `scripts/binary_size_report.sh` (this ADR's tool)
+ symbol attribution on a `-Dprofile=true` build.

| Component                              | Size     | Notes                                                                            |
|----------------------------------------|----------|----------------------------------------------------------------------------------|
| `__text` (code)                        | 6.90 MB  | breakdown below                                                                  |
| — zwasm (engine/api/validate/ir/…)   | 2.99 MB  | 44% of code; `engine.codegen.arm64.emit.compile` alone 691 KB                    |
| — cljw proper (runtime/lang/eval/app) | 2.57 MB  | 38% of code                                                                      |
| — Zig std                             | 1.17 MB  | incl. std.crypto TLS 0.43 MB (https client), std.sort monomorphizations 0.22 MB  |
| `__const` + `__cstring` (data)         | 1.59 MB  | AOT bytecode blob 698 KB + raw `.clj` sources 451 KB + UCD tables ~207 KB + misc |
| `__eh_frame` + `__unwind_info`         | 0.75 MB  | unwind tables                                                                    |
| headers / `__LINKEDIT` / misc          | ~0.23 MB |                                                                                  |

Supporting facts: the whole binary gzips to 2.8 MB (the release tarball) —
high code redundancy, typical of monomorphized Zig; symbols are already
stripped (O-008); `zig build` release config already omits debug info.

### Optimize-mode measurements (same source, same flags otherwise)

| Config                              | Bytes     | Δ vs shipped | Trade                                       |
|-------------------------------------|-----------|---------------|---------------------------------------------|
| ReleaseSafe (shipped)               | 9,469,816 | —            | —                                          |
| ReleaseSafe + `unwind_tables=.none` | 8,731,096 | −739 KB       | see L1 (measured cost ≈ zero)              |
| ReleaseFast                         | 8,172,744 | −1.30 MB      | drops all safety checks                     |
| ReleaseSmall                        | 4,841,624 | −4.63 MB      | drops safety checks + speed (unbenchmarked) |

(`error_tracing=false` was measured a no-op: `strip=true` already disables
error-return tracing — the probe binary prints "stack tracing is disabled"
on panic with and without unwind tables.)

## Decision

### 1. This ADR is the binary-size SSOT

Composition, budget, and lever dispositions live **here**. D-515 is re-narrowed
to the drain anchor pointing at this ledger; the four stale claims above are
corrected in the same commit; `scripts/binary_size_report.sh` is the
measurement recipe (report mode) and the enforcement (check mode).
`bench/history.yaml`'s `binary_size_bytes` remains the bench-side time series;
the user-facing per-release record is CHANGELOG (each release entry states the
measured size per platform from this release on).

**Reference platform** for every number in this ledger: macOS arm64,
ReleaseSafe, `-Dwasm`, stripped (= the brew artifact). The Linux x86_64
`-Dcpu=baseline` deploy artifact is recorded at each release alongside it
(expected within ~±15%; the v1.3.1 Linux tarball implies ~10 MB uncompressed).

### 2. Per-component budget (derived ceiling, not a reverse-engineered line)

Size growth is feature-coupled (F-013/F-014 guarantee it), so the budget is
per-component with explicit headroom; the total ceiling **derives** from the
components, and a breach localizes itself via the report tool:

| Component              | Measured (2026-07-16) | Budget                             | Headroom rationale                                              |
|------------------------|-----------------------|------------------------------------|-----------------------------------------------------------------|
| zwasm (engine + api)   | 2.99 MB               | 4.0 MB                             | owns future x86_64 JIT emitter + component-model growth (CODEV) |
| cljw text              | 2.57 MB               | 3.5 MB                             | F-013/F-014 comprehensiveness growth                            |
| Zig std text           | 1.17 MB               | 1.5 MB                             |                                                                 |
| embedded data          | 1.59 MB               | 1.75 MB                            | re-set to **1.0 MB** when L2 lands                              |
| unwind + linkedit etc. | 0.23 MB               | 0.3 MB                             | L1 LANDED 2026-07-16 (O-052): tables dropped, budget re-set     |
| **Derived ceiling**    | **8.73 MB**           | **≈ 11 MB → ≈ 10.3 MB post-L2** |                                                                 |

A component crossing its budget line triggers: attribute (report tool) →
either a lever lands or the budget line is consciously amended **in this ADR**
(Revision history entry). Never silently.

### 3. Size-claims gate (the recurrence-prevention mechanism)

`test/run_all.sh` gains the `size_claims` step (full gate, after
`build_cljw`): `scripts/binary_size_report.sh --check` fails when README's
headline "<N> MB" claim drifts >10% from the freshly built binary. This is the
house pattern (check_clj_attribution / check_smell_audit): closed structurally,
not by vigilance (F-013 clause 3). A prose size claim can no longer rot 2.5×.

### 4. Lever ledger (each with a measured/estimated Δ and a disposition)

- **L1 — `unwind_tables = .none` on release builds: LANDED 2026-07-16 (O-052;
  shipped size 9,469,816 → 8,731,096 B).** Original disposition:
  Measured −739 KB. Measured cost ≈ zero: the stripped shipped binary
  *already* prints no native stack trace on a Zig-level panic (probe
  2026-07-16, "stack tracing is disabled" both ways); cljw renders Clojure
  errors from its own StackFrame stack (O-008). arm64-macOS keeps frame
  pointers, so an attached debugger can still walk frames post-mortem.
  Keep unwind tables on Debug (and under `-Dprofile`).
- **L2 — embedded-data shrink, folded into D-517's envelope-format redesign:
  ADOPT-with-D-517** (one format decision, not two). Shape: eager core region
  stays uncompressed for D-517 zero-copy in-place reads; **lazy lib regions +
  raw `.clj` sources are flate-compressed** (measured: blob 698→112 KB flate,
  `.clj` 451→125 KB; decompressing the *whole* blob costs 0.46 ms, and lazy
  regions decompress only on `require`). **Format compaction is evaluated in
  the same pass** (varint operands, cross-region constant-pool dedup) — it
  attacks the same bytes with no decompression copy and no RSS cost.
  Estimated −0.9 to −1.1 MB. Co-decide in D-517; do not build the format twice.
- **L3 — ship ReleaseSmall as the default artifact: REJECT.** Halves the
  binary (4.84 MB measured) but drops every Zig safety check from the shipped
  runtime; ADR-0132's shipped==gated ReleaseSafe identity stands. Recorded for
  perspective; a user who wants a minimal binary can build one.
- **L4 — hybrid: zwasm module compiled ReleaseSmall under a ReleaseSafe cljw:
  REJECT for the untrusted-input path; PENDING CODEV split otherwise.** The
  wasm parser/validator/JIT-emitter processes attacker-controlled `.wasm`
  bytes — exactly where ReleaseSafe's checks earn their keep; stripping them
  there is a safety regression, not a size win. If zwasm ever splits
  compute-only internals into a separate module, the hybrid can be re-scored
  for that module alone (bundle with the L5 CODEV request).
- **L5 — zwasm-side size campaign: FILE via CODEV** (co-developed, so
  tractable). Targets: the 691 KB monolithic `engine.codegen.arm64.emit.compile`
  (table-driven encoding), comptime-gating component-model surfaces cljw never
  calls. The zwasm budget line (4.0 MB) is the contract this campaign defends
  while x86_64 JIT lands.
- **L6 — monomorphization dedup (cljw-actionable): ADOPT opportunistically.**
  std.sort instantiations alone are 0.22 MB (many ~20-28 KB `sort.block`
  clones); type-erased comparator shims and `std.fmt` surface narrowing are
  classic Zig size work with no safety/startup trade. Driven by the report
  tool's symbol output; batch with L1's cycle or a quality-loop unit.
- **L7 — UCD table re-encoding: LOW.** Two-stage packed tables could halve the
  ~207 KB rodata (generator: `scripts/gen_unicode_case.py`). Take only when
  touching the generator anyway.
- **L8 — drop the raw `.clj` sources: REJECT.** They are load-bearing three
  ways: bootstrap-error `SourceContext` line rendering, `cljw build`'s
  re-envelope of user programs, and the non-AOT fallback path
  (`clojure.repl/source` notably does NOT read them — it throws honest
  not-available, D-513). Their fate is compression under L2.
- **L9 — feature-gate the TLS client: REJECT.** 0.43 MB buys an https-capable
  `slurp`/http client; a runtime whose http can't do https is a partial-class
  trap (F-014). Optional micro-probe: verify unused cipher-suite/cert-path
  code is actually dead-stripped.
- **L10 — UPX / binary packers: REJECT.** macOS AMFI kills modified/packed
  binaries (memory: `macos_cp_binary_breaks_codesign`); also opaque to the
  report tool and to users.

**Landing order**: L1 (single build.zig line, next cycle) → L2 inside the
D-517 unit → L6/L7 opportunistic. L5 filed via the CODEV channel
(`.dev/zwasm_capabilities.md` / `from_cljw`). Projected post-L1+L2 shipped
size: **~7.6-7.8 MB** on the reference platform.

### 5. Narrative posture (README)

README states the **measured** size (kept honest by the gate) and frames it
against verified peers: babashka 1.12.217's native binary is 70,933,648 B
(~71 MB, measured locally 2026-07-16) — cljw is ~7.5× smaller *with* an
embedded Wasm JIT engine. "Small" remains earned in the runtime's class;
the 3.8 MB era is not the claim anymore.

### 6. Ledger reconciliations in this commit

- **D-515**: re-narrowed — points here for composition/budget/levers; keeps
  the standing drain-anchor role; stale 8.8 MB / 1.4 MB figures corrected.
- **D-277**: status updated — the size half of the tension now has a
  mechanism (budget + gate); the startup half was discharged by ADR-0163
  lazy-ns. The tension itself remains standing (comprehensiveness keeps
  consuming the cljw-text/data budgets) but is observable, not vigilance-based.
- **D-517**: barrier gains the L2 fold-in (compression + compaction co-decided
  with zero-copy in ONE format redesign).
- **ROADMAP**: top-line "≤ 5 MB" and §10.3 "< 3.5 MB" amended per §17 (this
  ADR is the amendment record).
- **`test/run_all.sh`**: stale size-heuristic comment rewritten; `size_claims`
  step added.

## Alternatives considered (Devil's-advocate fork, 2026-07-16, verbatim)

> ## Leading entry: F-NNN violation check
>
> **No finished-form-clean alternative requires violating an F-NNN.** All
> three alternatives below are within the envelope. One important adjacent
> finding: the *old* size targets (ROADMAP line 73 "target binary ≤ 5 MB" and
> §10.3 "< 3.5 MB target / < 2 MB stretch") are **arithmetically unreachable
> while F-001 holds** — the zwasm engine+component-api alone is ~3.0MB, i.e.
> F-001's mandatory payload exceeds the §10.3 target by itself. Those targets
> predate the engine embedding and their retirement is a legitimate ROADMAP
> §17 amendment (ROADMAP-level, not an F-NNN), but the ADR must *say* this
> arithmetic out loud — "the old target died the day F-001's engine landed in
> the text segment" is the honest story, and it is a much stronger
> justification for a new budget than "we measured 9.5 and drew a line above
> it."
>
> ## Alternative 1 — smallest-diff: no new ADR; re-narrow D-515 + fix the
> stale numbers + land L1
>
> D-515 already exists as the standing binary-size axis row and already
> sketches most of the draft's levers. The smallest-diff shape: update
> D-515's stale "8.8MB" to the measured 9,469,816 + fold the measured
> composition and lever dispositions into its barrier text; fix README 3.8MB;
> amend both ROADMAP claims; land L1 as an O-NNN row; no ADR-0172 at all.
>
> - **Better than the draft**: honours debt_dedup ("many additions are
>   actually re-tagging an existing entry") — the draft creates a second SSOT
>   over an existing SSOT row and then has to re-point the row at the ADR, a
>   two-hop indirection for one axis. Zero governance machinery to maintain.
> - **Breaks**: the measured composition table (a genuinely valuable dataset
>   — the first real attribution of the 9.5MB) has no durable, formatted
>   home; debt-row prose is where tables go to die. The budget amendment
>   (retiring ≤5MB / <3.5MB) *is* an ADR-level decision under ROADMAP §17 —
>   quiet edits are forbidden — so this alternative still needs at least an
>   amendment ADR, at which point you have most of ADR-0172 anyway. And it
>   leaves governance at exactly the vigilance level that let 3.8MB rot for
>   months. Not recommended.
>
> ## Alternative 2 — finished-form-clean: budget-and-gate ADR, not
> posture-and-ledger memo (RECOMMENDED)
>
> Keep ADR-0172, but change what kind of document it is. The draft is a
> *posture* doc: measured facts + a lever list + a soft convention. The
> finished form is a *budget mechanism*: numbers derived from something,
> enforced by something.
>
> 1. **Retire the old targets with the F-001 arithmetic**, amending **both**
>    stale ROADMAP claims — the draft names only the line-73 top-line and
>    misses the §10.3 table row. An ADR whose stated purpose is killing
>    number-rot that itself leaves a stale number in §10.3 is self-refuting.
> 2. **Per-component budgets, not one total.** Size growth is feature-coupled
>    (F-013 網羅 / F-014 per-class completeness guarantee it grows), so a
>    flat byte ceiling structurally fights the comprehensiveness laws and
>    will be re-drawn every time it's hit — the same rot loop. Budget the
>    axes separately … A total ceiling then *derives* from the components
>    plus stated headroom, and a breach localizes itself.
> 3. **Mechanical enforcement, not convention.** This repo's own doctrine —
>    F-013 clause 3, verbatim: "closed structurally, not by vigilance" —
>    condemns the draft's governance. Extend the pre-tag/release path with a
>    small check: measure the binary, stamp binary_size_bytes + platform into
>    CHANGELOG mechanically, **fail** if README's stated size drifts >10%
>    from measured, warn on >5% inter-release growth. ~30 lines of script.
>    Note bench/history.yaml already records binary_size_bytes — reuse or
>    explicitly supersede it; a *third* uncoordinated size record is more rot
>    surface.
> 4. **Fold L2 into D-517's format redesign as ONE envelope-format decision.**
>    D-517 (zero-copy) is UNBLOCKED and actionable. Landing compression now
>    and reshaping the format for zero-copy later is the twice-built shape
>    ADR-0162's own DA red-team warned about. The finished form decides the
>    rodata format once: zero-copy eager core region (uncompressed), flate
>    lazy lib regions + .clj sources (ADR-0163's region blob is already cut
>    for exactly this). Also consider **format compaction** (varint operands,
>    cross-region constant-pool dedup) *inside* that same redesign — it
>    shrinks the blob with no decompression copy and no RSS cost;
>    compression-of-a-bloated-format vs designing-a-compact-format is
>    precisely a smallest-diff-vs-finished-form fork.
> 5. **Re-score L4 on safety, not perf.**
> 6. **Also touch D-277**, the standing eager-comprehensiveness-vs-size
>    tension row that F-013 clause 4 names — else the ledger contradicts the
>    SSOT.
>
> This expands the cycle. **Recommend it anyway, citing F-002** — every added
> piece is the difference between "we wrote down that size matters" and "size
> cannot silently rot again," and the draft's own motivating incident is a
> pure vigilance failure.
>
> - **Breaks**: heavier cycle; the per-component budget needs a repeatable
>   measurement recipe that must be maintained as composition shifts; genuine
>   over-engineering risk for a solo project if the gate is made blocking
>   rather than warn-mostly — keep only the README-drift check hard-fail.
>
> ## Alternative 3 — wildcard: attack the mass, and build per-symbol
> observability instead of a total-bytes ratchet
>
> The draft's ADOPT-now levers total ~1.6MB and mostly nibble the 17% that is
> data + overhead, while **44% of the binary is zwasm** and gets only "file a
> CODEV request". The wildcard inverts the emphasis: (a) make the durable
> artifact of this cycle a **per-symbol size report tool** (nm/segment diff,
> checked-in per release) so any future +5% is *localized* the day it lands,
> not just detected; (b) open a real CODEV size campaign against zwasm with
> measured targets — the 691KB monolithic emit.compile (single biggest symbol
> in the whole product), plus comptime-gating component-model surfaces cljw
> never calls — since the user co-develops zwasm, this is far more tractable
> than for a normal dependency; (c) run a cljw-side monomorphization dedup
> sweep off the report (std.sort instantiations 0.22MB, std.fmt, container
> instantiations).
>
> - **Better than the draft**: targets where the bytes actually are; the
>   report tool is recurrence-prevention that *names the culprit*; the dedup
>   sweep is durable cljw-side work no compression lever ever reaches.
> - **Breaks**: cross-repo — zwasm's timeline isn't cljw's to schedule, and
>   the SHA pin bump is user-gated, so the headline −MB has no landing date
>   cljw controls; an emitter rewrite risks JIT perf regressions; the
>   nm-based tooling is platform-fiddly (the 9.5MB is a macOS arm64 number,
>   the shipped-artifact Linux numbers are unmeasured and may differ — the
>   ADR should say which platform its numbers and ratchet bind to).
>
> Alt 2 and Alt 3's observability/CODEV pieces compose; if forced to one,
> Alt 2.
>
> ## (a) Is the two-tier budget honest or rationalization?
>
> **As drafted, rationalization — fixable.** Three tells: (1) the ceiling is
> reverse-engineered from the measurement — a budget that never constrains
> anything at birth isn't a budget, it's a description; what makes the new
> line rot-proof where the old one wasn't? (2) the ~7MB "target" is
> current-minus-known-levers — approximately the *floor*, leaving no headroom
> for F-013/F-014-mandated growth, so it will be quietly missed the same way
> 3.8MB was; honest forms: per-component budgets with explicit headroom, or a
> ceiling anchored to a user-facing rationale. (3) the retreat is unexplained
> — 5MB → 10MB doubles the top-line without stating why the old number was
> wrong; the F-001 arithmetic is a complete, honest, even flattering
> explanation. Also verify the peer number against a current bb release
> before publishing — shipping an unverified peer number in the same commit
> that fixes your own unverified number would be poetic.
>
> ## (b) Missing / mis-scored levers
>
> L4 is mis-scored — the blocker is safety, not perf: ReleaseSmall on the
> zwasm module strips bounds/overflow checks from **the code that parses
> attacker-controlled .wasm bytes** — the one component where ReleaseSafe's
> checks earn their keep most. L1's cost is asserted, not measured — probe a
> panic in a stripped unwind-less build first (measure-first is the standing
> directive). Bytecode/format compaction is absent — its absence manufactures
> the L2-vs-zero-copy conflict. Drop-the-raw-.clj is unexamined — the ledger
> must state what reads it at runtime and give it a disposition. TLS
> feature-gating: absent — correct disposition is almost certainly REJECT
> (F-013/F-014), but a comprehensive ledger should say so. Monomorphization
> dedup: absent despite being named in the measurement. Linker-level levers:
> state dead-strip status rather than silently assume. Platform binding:
> declare the reference platform.
>
> ## (c) Does the governance prevent README-rot recurrence? **No** (as
> drafted).
>
> (1) It's the same mechanism class that already failed — bench/history.yaml
> recorded binary_size_bytes all along; nothing *compared* the prose claim to
> the measurement. The fix is the comparison: a pre-tag check that greps
> README's size claim and fails on >10% drift — this repo's exact house
> pattern, and F-013 clause 3 is the in-project law for it. (2) "Investigate"
> has no actor — unless the ratchet is a script, it fires zero times. (3) +5%
> per release at monthly cadence compounds to ~1.8x/year — sanctioned creep;
> state the ratchet-vs-ceiling interplay.
>
> ## Verdict
>
> The draft's measurement work is excellent and its L3/L7 rejections are
> right. Its three soft spots: the budget is drawn around the tape measure
> instead of derived (fix with the F-001 arithmetic + per-component budgets),
> the governance is vigilance re-labeled as mechanism (fix with a ~30-line
> pre-tag check), and the ledger under-weights safety (L4) and misses the
> cljw-actionable heavy levers (format compaction, monomorphization dedup)
> while ADOPTing a compression lever that risks rebuilding the D-517 format
> twice. Alternative 2 keeps everything the draft got right and closes those
> three; recommend it despite the larger cycle, per F-002.

The accepted Decision above **is** Alt 2 with Alt 3's report tool and CODEV
campaign composed in; every (a)/(b)/(c) critique item was folded (F-001
arithmetic stated, per-component budgets with headroom, `size_claims` gate,
L4 re-scored on safety, L1 probed before ADOPT, compaction added to L2, L8/L9
dispositions grounded, platform binding declared, peer number measured).

## Consequences

- Binary-size claims can no longer rot silently: the full gate fails on >10%
  README drift, and each release's CHANGELOG entry records the measured bytes.
- The old "small binary" marketing number is retired honestly; the story
  becomes "9.5 MB single static binary including a Wasm JIT engine, ~7.5×
  smaller than babashka; ~7.6-7.8 MB after the queued levers".
- D-517's format redesign becomes the single owner of every embedded-data
  byte decision (zero-copy + compression + compaction), preventing a
  twice-built format.
- The zwasm budget line creates the first cross-repo size contract; the CODEV
  request (L5) carries measured targets instead of a vague "make it smaller".
- Risk: the per-component budget table requires re-measurement discipline at
  budget-relevant moments (release, big feature). Mitigation: the report tool
  makes a measurement a one-command act; the gate keeps at least the headline
  honest even if a component drifts between audits.

## Revision history

- **2026-07-16 (same day, campaign start)**: L1 landed (O-052) — shipped
  ReleaseSafe 9,469,816 → 8,731,096 B; unwind/overhead budget line re-set to
  0.3 MB per the Decision's own re-set clause; derived ceiling ≈ 12 → ≈ 11 MB
  (≈ 10.3 MB once L2 lands). Public comparison page
  `docs/works/binary_size.md` (measured 2026-07-16 industry survey) landed as
  the narrative-posture realization of Decision §5.

## Affected files

- `scripts/binary_size_report.sh` (new — report + check modes)
- `test/run_all.sh` (`size_claims` step; stale comment rewritten)
- `README.md` (honest size + verified peer comparison)
- `.dev/ROADMAP.md` (top-line + §10.3 amendments, §17 procedure)
- `.dev/debt.yaml` (D-515 re-narrow, D-277 update, D-517 L2 fold-in)
- `.dev/handover.md` (resume pointer)
