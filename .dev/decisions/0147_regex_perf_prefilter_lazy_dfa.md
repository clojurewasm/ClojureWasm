# ADR-0147 — Regex perf: borrow-and-adapt the literal-prefilter + lazy-DFA techniques into cljw's Pike-NFA, equivalence-locked (goal = properly incorporate the optimizations, not just beat Python)

- **Status**: **Accepted** (2026-06-16). Stages 1 (O-034/O-035) + 2 (O-036 leading
  first-byte prefilter) committed + WIRED (the default matcher win). Stage 3 (lazy DFA)
  was built as decided = **Alternative 2 — forward + reverse lazy DFA** (`dfa.zig`,
  equivalence-locked vs the Pike VM), **but NOT wired** — direct measurement (§ Stage 3
  measured outcome) showed the wired DFA *regresses* regex_count (17→23 ms) and sparse
  `\d+` (0.05→0.47 s) vs the S2-prefiltered Pike VM, because the DFA's forward scan does
  not use the S2 prefilter (visits every byte) and its reverse pass is uncached. The DFA
  stays a committed, correct, RESERVED engine (D-449); the Pike VM + S2 prefilter remains
  the default matcher. Alt 1 (anchored-restart-only) re-rejected as cycle-budget-defer;
  Alt 3 (anchors/`\b` in the DFA state) is a follow-up ADR.
  Authored 2026-06-15 as the next-session bridge (user-directed "腰を据えて … 工夫をしっかり入れ込む").
- **Relates to**: ADR-0031 (regex engine choice — Pike NFA over backtracking, the
  reserved lazy-DFA design `src/runtime/regex/dfa.zig`), ADR-0145 (regex after sieve +
  nested_update, with the cross-lang equivalence audit as the gate — DONE), F-002
  (finished-form: do the optimization properly), F-011 (clj-equivalence — locked by
  the 48-golden corpus), F-015 (completion-grade), the perf campaign §9.2.S /
  memory `perf-beat-python-every-bench`.
- **Audit (the ADR-0145 gate, DONE)**: `private/notes/9.2.S-regex-equivalence-audit.md`
  + `test/diff/clj_corpus/regex_equivalence.txt` (48 goldens, committed = the F-011
  optimization-safe surface).

## Context

`regex_count` (cljw 45ms vs py 26ms = 1.74×) is the last open Python-loser. cljw's
matcher is a **Pike NFA** (Thompson thread-list VM, non-backtracking, ReDoS-immune,
ADR-0031) in `src/runtime/regex/{compile,match,value}.zig`; re-seq is eager (`.clj`).
The cross-lang equivalence audit is done (GO): 48/48 vs clj; cljw's 5 gaps (reluctant
quantifiers, lookbehind, named groups, backrefs, `\A\z\Z`, POSIX `[[:class:]]`) all
**raise NotImplemented (never silently wrong)**.

**User direction (2026-06-15): do this properly.** The goal is NOT "barely beat
Python" — it is to **incorporate the proven fast-regex techniques into cljw's
architecture**, adapting (not using) the Zig/C/Rust references. "どうせやるなら
しっかり." So this ADR sets the *full* approach, staged, rather than the audit's
minimal 3-lever path.

## What the fast engines actually do (research synthesis, 2026-06-15)

Engine families: **backtracking** (PCRE/Python `sre`/Java — feature-rich, ReDoS,
O(2ⁿ)) · **Thompson-NFA / Pike VM** (grep/RE2-fallback/**cljw** — linear, ReDoS-immune,
captures+`\b` are the cost) · **DFA** (RE2/grep/Rust — fastest table-walk, no captures,
O(2ᵐ) build blowup). The fast safe engines (RE2, Rust `regex`/burntsushi, the Zig
`ezi-gex`) layer these techniques, by ROI:

1. **Literal prefilter (biggest practical win)** — extract the pattern's determinable
   leading literal/class and SKIP via fast byte search to candidate positions; run the
   engine only there. `\d+` → memchr/byte-class-scan to the next digit. memchr/Two-Way
   (single literal, SIMD rare-byte), Teddy (multi-literal, `pshufb`), Aho-Corasick (huge
   sets). **This is why Python/Java's `findall` is fast — the prefilter, not the VM.**
2. **Lazy DFA** (RE2/grep core) — build the DFA on-the-fly, cache visited states, fall
   back to NFA on cache thrash. ~DFA speed, no O(2ᵐ) build. cljw's ADR-0031 reserved
   `dfa.zig` for exactly this.
3. **Two-pass for captures** — find match bounds with the fast DFA, extract captures with
   the NFA only inside the matched region.
4. **reverse-DFA two-pass** (ezi-gex) — "prone" patterns (`\w+@\w+`, start-everywhere) use
   forward-end + reverse-leftmost-start; "non-prone consuming loops" (`\w+`, `\d+` — the
   bench) use **anchored-restart on the eager-DFA frozen table** (one pass).
5. **NFA opts** — sparse states + literal tries + UTF-8 minimal DFAs (Daciuk) to kill the
   ε-closure cost that dominates a naive Thompson VM.
6. **SIMD + zero-alloc** — prefilters are SIMD; caller-supplied Scratch (no per-match alloc).

## Decision (Proposed — the approach)

Keep cljw's **Pike NFA as the safe base** (ReDoS-immune, F-011, ADR-0031 — do NOT
reintroduce backtracking) and **incorporate the techniques in stages**, each
**equivalence-locked** by the 48-golden corpus (48/48 after every change) + the diff
oracle, each **measured** (`bench/benchmarks/35_regex_count`):

- **Stage 1 — the supporting shaves** (equivalence-neutral, quick): (a) `seen`
  generation-counter in `match.zig` `tryMatchAt` (O(1) clear vs per-position `@memset`);
  (b) a `rt/re-find-all` Zig primitive backing `re-seq` (one pass, one ThreadList reuse,
  removes the ~10ms `.clj` layer). Audit measured (a) at 45→41.5ms.
- **Stage 2 — the literal/first-byte/class PREFILTER** (the beat-Python lever): extract
  the Program's determinable leading byte-set at compile time (a 256-bit bitmap on the
  `Program`); `findFrom` skips to the next position whose byte is in that set instead of
  restarting `tryMatchAt` everywhere. Disabled when no leading set is determinable
  (`.`/`^`/wide alternation). Equivalence-neutral (only skips provably-non-startable
  positions). Borrow the SIMD byte-scan shape from `ezi-gex/src/engine/memmem.zig` +
  `backends/literal.zig` (rare-byte `@Vector` masks) — re-derive in cljw's Zig 0.16
  idiom; a scalar byte-class scan is the portable floor, SIMD the accelerator.
- **Stage 3 — the lazy DFA** (the structural ceiling, ADR-0031's reserved `dfa.zig`): an
  on-the-fly DFA over the byte automaton with a bounded state cache + NFA fallback;
  anchored-restart for `\w+`/`\d+`-shaped consuming loops (ezi-gex's `auto` routing). This
  is the "しっかり" half — it makes cljw's regex fast across patterns, not just the bench.
  Captures still ride the Pike VM (two-pass: DFA bounds → NFA captures-in-region).
- **NO-GO**: backtracking (ReDoS), a machine-code JIT (ADR-0145 / cross-platform), a
  fully-compiled eager DFA for untrusted patterns (O(2ᵐ) build). Reluctant quantifiers +
  the `compile.zig:22-23` stale lookaround-doc are an optional parity-gap follow-up
  (D-051/D-447), pairing naturally with the engine work.

## Borrow-and-adapt discipline (references, NOT dependencies)

cljw does NOT depend on or vendor any Zig regex lib — it **reads the references for the
algorithm + re-derives** in cljw's own engine (`no_copy_from_v1` spirit extended to OSS
refs; the 48-golden corpus is the F-011 equivalence proof that the re-derivation is
correct). Cloned / available references (`.dev/reference_clones.md` § Perf-reference):

- **`~/Documents/OSS/ezi-gex/`** (cloned 2026-06-15) — a Zig Thompson-NFA engine with
  Literal Prefilter + Lazy/Eager DFA + Teddy + zero-alloc, WASM-compatible. **Targets Zig
  0.17.0-dev — will NOT compile on stable 0.16** (so it is a *source blueprint*, not a
  dependency). The directly-applicable files: `src/engine/memmem.zig` (2-byte rare-byte
  SIMD), `src/engine/teddy.zig`, `src/engine/simd.zig`, `src/engine/backends/{literal,
  dfa,edfa,pikevm,auto}.zig`, `src/engine/redos.zig`.
- **burntsushi `regex-internals`** (https://burntsushi.net/regex-internals/) + the Rust
  `regex-automata` architecture — the authoritative meta-engine design (PikeVM + lazy DFA
  + bounded backtracker + one-pass + literal prefilters + Teddy).
- **RE2** (Google) — the safe-non-backtracking lazy-DFA design (refuses backrefs, like
  cljw). **CPython `Modules/_sre`** (the `SRE_OP_LITERAL` prefix scan) + **OpenJDK
  `java.util.regex`** (`BnM` Boyer-Moore prefilter) — clone on demand.

## Process (the implementing session)

Per the user's workflow preference (2026-06-15): **the main agent does the
design-exploration + measurement DIRECTLY** (read `ezi-gex`/RE2/burntsushi, reason,
measure-first), NOT via a survey/DA fork — premise errors hide in forked summaries (the
ADR-0146 filter-chain lesson: a forked survey propagated a wrong "depth-bound" premise
that direct measurement falsified). Reserve forks for the **well-specified mechanical
implementation** (the build-iterate-test loop, once the design + the prefilter byte-set
extraction are settled by direct reasoning). Each stage: design directly → implement
(self or fork) → diff oracle + corpus 48/48 + bench re-measure → commit. Stamp this ADR
Accepted (with the Devil's-advocate pass on the lazy-DFA structural choice) when Stage 2
or 3 is committed; Stages can land as separate commits under this one ADR.

## Alternatives considered (Stage 3 lazy-DFA structural choice — Devil's-advocate pass, 2026-06-16)

Forked `general-purpose` subagent, fresh context, briefed with the F-002 / F-011 /
F-015 / ADR-0031 envelope. Output reflected verbatim:

> ### Alternative 1 — smallest-diff: the proposed minimal slice, but with the leftmost-start bug made explicit
>
> **What it is (concrete).** A new `src/runtime/regex/dfa.zig` implementing an on-the-fly cached lazy DFA whose state is the sorted NFA PC-set in priority order with cut-on-match (leftmost-first). It handles only **anchor-free, look-free, capture-free consuming** patterns; the compiler tags each program with a `dfa_eligible: bool` (set false the moment an `anchor`/`look`/`save` Inst appears, or `$`/`\b` IR is emitted). `find` walks leftmost-start by **anchored-restart from each S2-prefilter candidate position**: at candidate `i`, run the DFA forward from `i`; on a match-state, record the end; the first candidate that produces any match wins the leftmost rule because S2 already enumerates candidates in increasing position order. Transitions are cached in caller-owned scratch keyed by `(state_id, byte_class)` using ezi-gex's byte-equivalence-class compression of the 256-alphabet. The Pike VM stays the base and the sole capture engine.
>
> **What it does better than the proposed minimal slice.** Essentially nothing in capability — it *is* the proposed slice — but it removes the brief's one buried hazard: "leftmost-start via anchored-restart from S2 candidates" is only correct when **every** match start coincides with an S2-prefilter member byte. That is true for a leading exact first-byte set (the only S2 form that currently exists), false the instant S2 grows a more permissive prefilter (e.g. a memchr-of-literal-substring anywhere, or a `.`-leading pattern that disables the prefilter entirely → candidate set = all positions → the restart is Θ(n²) again). This alternative pins that down: it asserts `dfa_eligible ⟹ S2 produced an exact-leading-byte-set candidate stream`, and DECLINEs to the Pike VM whenever S2 is in its degenerate all-positions mode. So it is the same constant-factor win as proposed but with the correctness precondition made a compile-time gate instead of an implicit assumption.
>
> **What it breaks / risks.** It cements the O(n²) worst-case class (brief acknowledges this — the current Pike `find` is already Θ(n²) on `\d+x` over a long digit run). It ships a *second* engine that must be kept byte-identical to the first forever, doubling the surface the diff oracle must cover, while delivering only a constant-factor improvement on the eligible subset. Under F-002 this is the textbook smallest-diff bias: it leaves the actual quadratic differentiator (the reverse DFA) unbuilt and creates a permanent two-engine maintenance tax for a constant.
>
> **Equivalence-lock story.** DFA state = priority-ordered PC-set with cut-on-match ⟹ leftmost-first identical to the Pike VM by construction (same thread-priority discipline, just memoised). The lock is mechanical: feed every eligible pattern in the 51-golden corpus through *both* dfa.zig and the Pike VM in the dual-backend oracle and assert identical spans; add a fuzz harness that generates random eligible patterns + inputs and diffs the two engines (cheap because both are in-process). The `dfa_eligible` gate guarantees ineligible patterns never reach the new path, so the corpus's anchor/look/capture goldens are untouched.
>
> ### Alternative 2 — finished-form-clean: forward + reverse lazy DFA, true O(input) `find`
>
> **What it is (concrete).** Build the full ezi-gex shape: dfa.zig hosts **two** lazy DFAs over the same byte-level `Inst` IR — a forward DFA and a **reverse DFA** compiled from the program run backwards (reverse each Inst's edges; swap match/start roles). `find` is the classic two-pass RE2 algorithm: (1) forward lazy DFA from the start of input (or from the first S2 candidate) until it reaches a match state → this yields the match **end** offset `e` in O(input) with no restart; (2) reverse lazy DFA from `e` walking backwards until *its* match state → yields the leftmost **start** offset `s`. Both DFAs are lazy/cached in caller-owned scratch with byte-equivalence-class alphabet compression and the priority-ordered cut-on-match state representation for leftmost-first. The eligibility gate is the same (anchor-free / look-free / capture-free consuming patterns); on a hit, the Pike VM is invoked **once** over the now-known `[s, e)` window for capture extraction (two-pass span-then-capture, exactly as the brief frames the Pike VM's residual role). Anchors that are *program-global* (`\A`, `\z`, fully-anchored patterns) are cheap to fold into the forward/reverse start conditions and can stay eligible; only *interior* position-dependent constructs (`\b` mid-pattern, `$` as interior multiline, lookarounds) force DECLINE.
>
> **What it does better than the proposed minimal slice.** It kills the quadratic. `\d+x` over a megabyte of digits is O(input) instead of Θ(n²) — this is the *entire* reason the brief cites the reverse DFA as "crucially" part of ezi-gex, and the reason the minimal slice is explicitly a constant-factor-only win. It also removes the dependency on S2's candidate stream being exact-leading-byte-only: the forward DFA scans from position 0 (or memchr-skips to the first plausible byte) and finds the end in one pass regardless of how permissive the prefilter is, so it composes cleanly with any future S2 enhancement instead of silently regressing when S2 grows. It makes `find` and `re-find-all` (Stage 1's one-pass driver) both linear, which is the throughput story Stage 3 was opened to deliver.
>
> **What it breaks / risks.** The reverse DFA is the genuinely hard part: compiling the reverse program correctly (especially around zero-width and greedy/lazy quantifier priority) is where leftmost-*longest* vs leftmost-*first* subtleties bite, and a reverse-pass priority bug produces a *wrong start offset* that the forward-only tests won't catch. Two cached DFAs double the scratch-memory footprint and the cache-eviction policy must be defined (lazy DFAs can blow their state cache on adversarial-but-non-backtracking inputs → need a "cache full ⟹ flush, or fall back to Pike VM" path, which is itself a correctness-neutral but must-be-tested branch). Risk: the reverse pass interacts with byte-equivalence classes (the reverse alphabet's classes are not the forward classes) — two class tables to derive and keep consistent.
>
> **Equivalence-lock story.** Strongest of the three. The forward DFA's end-offset is locked against the Pike VM's match-end (run both, diff). The reverse DFA's start-offset is locked against the Pike VM's match-start. Critically, because the Pike VM remains the capture engine and is invoked over `[s, e)` on every hit, the *final returned match including all groups* is always produced by the existing, already-corpus-locked Pike VM — the DFA only narrows the window the Pike VM runs over, so a DFA span bug manifests as "Pike VM given the wrong window → group offsets shift" and is caught by the existing 51-golden corpus the moment any golden is eligible. Add: (a) a property test asserting `dfa.find(p,s) == pike.find(p,s)` over fuzzed eligible inputs including the pathological `\d+x`-class quadratic triggers, and (b) an oracle assertion that the cache-full fallback path produces identical spans to the no-fallback path.
>
> ### Alternative 3 — wildcard: lazy DFA over the *full* IR via an in-DFA-state position/assertion lattice (anchors & word-boundaries eligible)
>
> **What it is (concrete).** Drop the eligibility gate's anchor/look exclusions by encoding position-dependent assertions **into the DFA state itself**, the way RE2/Rust-`regex` handle `^`, `$`, and `\b`. The DFA alphabet is extended from "byte class" to "byte class × entry-context", where entry-context is a small bitset capturing the facts an assertion can test at a position: `was-prev-byte-word`, `is-at-text-start`, `is-at-text-end`, `is-at-line-start`, `is-at-line-end`. The lazy state-construction step, when it crosses an `anchor`/`look` Inst, consults the current entry-context bits to decide whether the zero-width assertion passes, and the cached transition key becomes `(state_id, byte_class, context_bits)`. This makes `^`, `$`, `\A`, `\z`, `\b`, `\B`, and multiline anchors all **DFA-eligible** — only true *lookahead/lookbehind over arbitrary sub-patterns* (which cljw's `look` Inst may or may not generalise to) stays on the Pike VM. Combined with the Alt-2 forward+reverse pair, almost the entire non-capturing regex surface runs on the linear DFA.
>
> **What it does better.** Maximal coverage: the common real-world patterns the minimal slice DECLINEs — `^\d+$`, `\bword\b`, `foo$` — all get the linear DFA + reverse-start treatment, so anchored line-scans over big inputs go linear too, not just the bare `\d+` case. This is the closest to "a real production regex engine" and the strongest answer to the user's "腰を据えて工夫をしっかり入れ込む" directive. It also subsumes Alt 2 (Alt 2 is this with the context lattice pinned to the empty set).
>
> **What it breaks / risks.** Highest complexity and the sharpest equivalence cliff. `\b` semantics must match JVM Clojure's `java.util.regex` Unicode word-boundary definition exactly — if cljw's IR is byte-level (the brief says it is) but Java's `\b` is codepoint/Unicode-property-level, then a byte-granular `was-prev-byte-word` bit is **wrong for multibyte UTF-8** and would silently diverge on non-ASCII (an F-011 violation). This is the leading risk and it is *not* hypothetical: it is the exact place a byte-level DFA and a Unicode-aware oracle disagree. The context-bit lattice also multiplies the cache key cardinality (state × class × context), worsening the cache-blowup pressure from Alt 2. And the reverse DFA + context bits together is the most subtle correctness territory in the whole engine.
>
> **Equivalence-lock story.** Same forward/reverse-vs-Pike-VM diffing as Alt 2, **plus** a mandatory dedicated `\b`/anchor sub-corpus that includes non-ASCII / multibyte inputs (the failure surface), diffed against the JVM oracle directly — not just against the Pike VM, because if cljw's *own* Pike VM `\b` is also byte-granular then DFA-vs-Pike agreement would be a false green (both wrong, identically). The lock therefore must be DFA-vs-`clj`-oracle on the word-boundary sub-corpus, and the eligibility gate must DECLINE any `\b` pattern whose input is detected non-ASCII until the Unicode-word-boundary semantics are proven byte-identical to Java.
>
> ### Recommendation
>
> **Build Alternative 2 (forward + reverse lazy DFA).** Per F-002, the finished-form-clean shape wins and cycle/LOC is not a constraint, so the minimal slice (Alt 1) is rejected outright: it is a constant-factor win that leaves the project's actual quadratic differentiator — the reverse DFA the brief itself flags as "crucial" — unbuilt, while imposing a permanent two-engine maintenance tax; choosing it on effort grounds would be the forbidden cycle-budget-defer smell. Alt 2 delivers the true O(input) `find` that is the entire point of Stage 3, composes cleanly with future S2 work, and has the strongest equivalence-lock because the Pike VM stays the corpus-locked capture engine over a DFA-narrowed window. Alt 3 is the genuinely-finished production shape and the right *follow-up*, but its `\b`/anchor coverage rides on resolving the byte-level-IR-vs-Unicode-word-boundary semantics (a real F-011 exposure that must be proven against the `clj` oracle, not the Pike VM, before any `\b` pattern is admitted) — so it should be a separate ADR after Alt 2's forward/reverse machinery is locked, not folded into this slice.
>
> **Note (not a halt):** none of the three requires violating an F-NNN as proposed. Alt 3 *contains* a latent F-011 violation (byte-granular `\b` on multibyte input) that is avoided by its eligibility gate DECLINEing non-ASCII `\b` until proven — flagging it here as the leading finding so the loop scopes Alt 3 around it rather than discovering it in the oracle.

**Main-loop decision**: Alt 2. The DA's recommendation aligns with F-002; Alt 1 was the
loop's initial (cycle-budget-driven) instinct and is re-rejected per CLAUDE.md's
cycle-budget-defer rule. Alt 3 → a follow-up ADR (the byte-vs-Unicode `\b` exposure is
its scoping constraint; cljw's `\b` is currently `isWordByte` = ASCII-only in
`match.zig`, so the Alt-3 sub-corpus must diff against `clj`, not the Pike VM). Stage 3
builds the forward + reverse lazy DFA in `src/runtime/regex/dfa.zig`, span-only, with the
Pike VM as the two-pass capture engine + the DECLINE fallback. **Reverse-DFA scope note**:
cljw's current Pike-VM `find` is itself per-position anchored-restart (same Θ(n²) class),
so even a forward-only milestone is not a regression — but per the DA the *committed* S3
form is the forward+reverse pair, not a forward-only intermediate.

## Stage 3 measured outcome (2026-06-16 — measurement falsified the "DFA wins" premise)

The Alt-2 forward+reverse lazy DFA was built and equivalence-locked (`dfa.zig`:
`find` == Pike VM span over a 120-pair fuzz matrix + leftmost-first + quadratic-shape
cases). It was then WIRED behind a Regex-Value-cached `LazyDfa` (eligible programs;
captures via two-pass Pike-VM `matchAnchored`) — clj-equivalence held (full corpus
3120/3120, captures correct, anchors→Pike fallback). **But the wired DFA REGRESSED
perf** (ReleaseSafe, measured directly):

| workload                           | S2-prefiltered Pike VM | wired lazy DFA | result          |
|------------------------------------|------------------------|----------------|-----------------|
| regex_count (dense `\d+`, 10000×) | 17 ms                  | 23 ms          | **~35% slower** |
| sparse `\d+` (~4000-char, 20000×) | 0.05 s                 | 0.47 s         | **~9× slower** |

**Why** (the falsified premise): the DA's recommendation assumed the DFA's O(input)
`find` would win. It does not, for cljw's regime, because (1) the DFA's forward scan
does NOT use the S2 leading-byte prefilter — it visits *every* byte, where the
prefilter skips to candidate-start bytes (the whole sparse win); (2) the reverse pass
is uncached (recomputes the closure per backward step); (3) for cljw's typical SHORT
regex inputs the forward+reverse two-pass overhead exceeds a single prefiltered Pike
pass. The DFA's asymptotic edge only materialises on huge / pathological inputs cljw
rarely sees, and even there it would need the prefilter integrated into its forward
scan to compete. This mirrors the ADR-0146 lesson: a forked/textbook premise ("the
reverse DFA is the point") that **direct measurement falsified**.

**Decision**: do NOT wire the DFA (a regression is not shippable; regex_count was
already CLOSED by S1+S2). The wire-in (Regex-Value cache + `findLeftmost`/`collectBounds`
dispatch) was reverted; `dfa.zig` stays committed as a correct, equivalence-locked,
RESERVED engine. Re-wiring requires (a) integrating the S2 prefilter into the DFA's
forward `findEnd` start-scan + (b) caching the reverse transitions, and even then likely
only wins above a large input-size gate — tracked as **D-449** with a review trigger (if
no huge-input workload + the optimization is not pursued, remove `dfa.zig` rather than
let it rot as dead code). The S2-prefiltered Pike VM is the finished-form default matcher
for cljw's workloads.

## Consequences

- The regex unit is a **multi-cycle engine unit** done properly (prefilter → lazy DFA),
  not a one-cycle alloc shave. Stage 2 (prefilter) is the beat-Python milestone; Stage 3
  (lazy DFA) is the "incorporate the optimization" goal (fast across patterns).
- F-011 is held by the 48-golden corpus (48/48 after every change) + the diff oracle.
  cljw stays ReDoS-immune (no backtracking) and cross-platform (no machine code).
- New tracked refs: `ezi-gex` cloned; ADR-0031's `dfa.zig` finally built in Stage 3.
- A follow-up debt **D-447** (regex parity gaps: reluctant quantifiers / lookbehind /
  named groups / backrefs / `\A\z\Z` / POSIX classes — currently NotImplemented) is the
  home for the equivalence gaps the perf work does not need but can opportunistically
  close (reluctant quantifiers pair with the engine work).

## Affected files (the implementing session)

- `src/runtime/regex/match.zig` (seen-gen, the prefilter byte-scan in `findFrom`),
  `compile.zig` (leading byte-set extraction onto `Program` + the stale doc fix),
  `dfa.zig` (Stage 3 lazy DFA), `value.zig`.
- `src/lang/primitive/regex.zig` + `src/lang/clj/clojure/core.clj` (`rt/re-find-all` +
  re-seq re-point).
- `test/diff/clj_corpus/regex_equivalence.txt` (extend as gaps close, anti-D-177) +
  `.dev/optimizations.md` (O-NNN rows). `.dev/debt.yaml` D-447 (parity gaps).
