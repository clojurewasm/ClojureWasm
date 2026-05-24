# 0031 — Regex engine choice for ClojureWasm

- **Status**: Accepted
- **Date**: 2026-05-25
- **Author**: Shota Kudo (drafted + accepted by the autonomous
  loop with Devil's-advocate fork)
- **Tags**: phase-6, regex, dependency, java-pattern, exit-criterion

## Context

ROADMAP §9.8 row 6.6 calls for
`runtime/regex/{compile,match}.zig` +
`runtime/java/util/regex/Pattern.zig` +
`lang/primitive/regex.zig` so the Phase 6 exit criterion
`(re-find #"\d+" "abc123")` → `"123"` is met. The regex
literal reader (`#"..."`) already lands a `regex` Tag Value
(Phase 4); only the engine + matcher is missing.

JVM Clojure delegates entirely to `java.util.regex.Pattern`.
That is one of the largest single dependencies in Clojure
core's IFn surface — `re-find` / `re-matches` / `re-seq` /
`re-groups` / `replace` / `split` all flow through it. The
cw v1 engine has to cover at minimum:

- Character classes (`\d`, `\w`, `\s`, `[a-z]`, `[^abc]`).
- Quantifiers (`?`, `*`, `+`, `{n,m}`, lazy `*?` `+?`).
- Anchors (`^`, `$`, `\b`).
- Grouping (`(...)`, `(?:...)`, `(?<name>...)`).
- Alternation (`|`).
- Java-compatible backslash escapes and `(?i)` flag.

The decision is which engine to ship.

## Decision

**Adopt Alternative 2 — Two-tier (lazy-DFA cache over Pike-NFA)
with explicit `Program` IR boundary.** Pure-Zig in-tree
implementation (F-001 clean), with a `runtime/regex/compile.zig`
parser → AST → `Program` IR pipeline, a Thompson / Pike VM in
`runtime/regex/match.zig` as the correctness baseline, and a
lazy DFA cache in `runtime/regex/dfa.zig` for the no-capture /
anchored fast paths. `runtime/regex/exec.zig` dispatches per
call site.

This is the finished-form-clean choice per F-002: the IR
boundary + two-tier matcher is what cw v1 will want by Phase
10+ regardless (regex appears in macro expansion, namespace
parsing, edn reader, spec.alpha-style validators). Paying once
now avoids a depth-4 Supersedes rewrite later. The 3-5 cycles
versus Alternative 1's 1 cycle is absorbed by the per-task
TDD loop without ceremony — CLAUDE.md's priority chain puts
F-002 above Phase 6 schedule pressure.

**Post-acceptance follow-up** (debt row, not blocking): the
Devil's-advocate subagent surfaced Alternative 3 (reader-time
intern + AST walker + content-addressed `Program` cache) as a
genuinely Clojure-shaped framing — "patterns are immutable
interned values, like keywords" — that composes beautifully
with `comptime`-lifted core regex literals. Promoting the
Alternative-2 `Program` to live in an Alternative-3-style
intern cache is a single non-breaking refactor that can land
post-Phase 6.6 once measurement justifies. Recorded as a
recall-trigger debt row at Phase 10+ planning.

### Candidate engines

| Engine                               | Pros                                                                                                 | Cons                                                                                                                                 |
|--------------------------------------|------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------|
| **A. Custom-min (in-tree Zig)**      | Zero dependency. Fits F-001 (zwasm v2 standalone). Matches deftype/numeric tower in-tree philosophy. | Re-implementing Java's Pattern surface is a large engineering bill. Subtle semantic gaps surface as conformance test failures later. |
| **B. zig-regex (3rd-party)**         | Already exists; saves ~1500 LOC. Active maintenance.                                                 | New dependency, Zig 0.16 compat unknown; PCRE-ish syntax may diverge from Java's; would need a syntax-translation layer.             |
| **C. PCRE C bind via build.zig.zon** | Most feature-complete; near-direct mapping to Java's Pattern.                                        | C dependency violates F-001 zwasm v2 standalone goal. Wasm Component target (Phase 19) is complicated by it.                         |

### Devil's-advocate brief (paste into next session's subagent fork)

> Devil's advocate this ADR. The active F-NNN constraints from
> `.dev/project_facts.md` are:
>
> - F-001: zwasm v2 standalone (no JVM runtime dep).
> - F-002: finished-form-clean wins over smallest-diff.
> - F-009: feature-implementation neutral (impl in
>   runtime/regex/, Java surface in runtime/java/util/regex/,
>   Clojure peer in lang/primitive/regex.zig).
>
> Produce 3 alternative shapes **within those constraints**
> (one smallest-diff, one finished-form-clean, one wildcard);
> for each, name what it does better than candidates A / B / C
> and what it breaks. Do NOT propose alternatives that violate
> F-001 (no C deps, no JVM deps). If the only finished-form-
> clean option requires violating F-001, record that finding
> as the leading entry of Alternatives considered so the main
> loop sees it, but do not ask the loop to halt — F-NNN
> amendment is a user action.

The subagent's output is reflected verbatim into the
"Alternatives considered" section below before the next
session flips `Status: Accepted`.

## Alternatives considered

*Devil's-advocate `general-purpose` subagent output, reflected
verbatim per CLAUDE.md § ADR-level designs are handled inline.*

### Alternative 1 — Thompson-NFA with Java-syntax frontend, single-file core (smallest-diff)

**Better than A/B/C**: Ships a working Phase 6.6 exit in one to two TDD cycles by adopting the classic Thompson NFA construction (Russ Cox's "Regular Expression Matching Can Be Simple And Fast"), which is the smallest correct engine that covers the full Phase 6.6 surface without backtracking pathologies. Unlike candidate A's loosely-scoped "custom-min" framing, this commits to a specific algorithm with a known LOC budget (~600-900 LOC, smaller than A's 800-1500 estimate) and a known correctness story. Unlike B, no third-party Zig 0.16 compatibility risk and no PCRE-vs-Java syntax translation layer. Unlike C, no libc / no build.zig.zon native dep — pure Zig, F-001 clean. The Thompson construction also gives `re-seq` linear-time scanning for free (no catastrophic backtracking), which a naive recursive-descent matcher under "custom-min" might botch.

**Trades off**: No backreferences (`\1`), no lookaround (`(?=...)`, `(?<!...)`) — Thompson NFA cannot express them. JVM Clojure exposes both via `java.util.regex.Pattern`, so a small slice of Tier B / C compatibility is forfeited until a follow-up phase bolts on a backtracking fallback path. Named groups (`(?<name>...)`) work because they're just labelled capturing groups, not backrefs. Unicode property classes (`\p{L}`) are deferred to a later cycle (ASCII + `\d \w \s` only at Phase 6.6 exit). Performance is worst-case O(n·m) which is correct but not Hyperscan-tier; that's fine for a Clojure runtime where regex isn't the hot path.

**File-by-file shape**:

- `runtime/regex/compile.zig`: Parser produces an AST (`Node` tagged union: Lit / Class / Concat / Alt / Star / Plus / Quest / Group / Anchor), then a single-pass NFA builder emits a flat `[]Inst` instruction array (`Char`, `Range`, `Match`, `Jmp`, `Split`, `Save`). Java-syntax aware from day one: `(?i)`, `\d \w \s \b`, `[...]`, `{n,m}`, `(?:...)`, `(?<name>...)`. ~400 LOC.
- `runtime/regex/match.zig`: Pike VM (Thompson with thread list) — two `Thread` lists (current/next), each thread carries a PC + capture-slot snapshot (small fixed-size array to avoid per-step allocation for the common case of ≤8 groups). `find` / `match` / `seq` / `groups` all reduce to one VM driver with different anchoring + iteration policies. ~300 LOC.
- `runtime/java/util/regex/Pattern.zig`: Thin wrapper exposing JVM-shaped `compile` / `matcher` / `Matcher.find` / `Matcher.group` over the in-tree NFA. Owns the compiled `Program` slice; `Matcher` is a borrow + VM state.
- `lang/primitive/regex.zig`: Clojure-side `re-find` / `re-matches` / `re-seq` / `re-groups` / `re-pattern` / `clojure.string/replace` + `split` dispatch into `java.util.regex.Pattern`. Reader-emitted regex Tag Value carries a pointer to the compiled `Program`.

**Work split**: 1-cycle: parser + AST + NFA emit + Pike VM + `re-find` green on `(re-find #"\d+" "abc123")` → `"123"`. Follow-up cycles: `re-matches` / `re-seq` / `re-groups`, named groups, `(?i)` flag plumbing, `clojure.string/replace` + `split`, error messages aligned with JVM `PatternSyntaxException`.

### Alternative 2 — Two-tier (DFA-cached over NFA) with explicit IR boundary (finished-form-clean)

**Better than A/B/C**: Treats the engine as a small compiler with an explicit IR (`Program`) that is decoupled from both the parser and the runtime matcher. This is the shape JVM `java.util.regex.Pattern` evolves toward in practice (compiled `Node` graph) and is what cw v1 will *want* by Phase 10+ when regex shows up in macro expansion / spec.alpha-style validators / namespace parsing. The two-tier matcher — a fast on-demand DFA cache (subset construction memoized per state) backed by the NFA fallback for stateful features — gives near-Hyperscan throughput on the common `re-seq` / `re-find` cases while preserving correctness for `(?i)`, anchors, and (eventually) backreferences via the NFA path. This is what RE2 and Go's `regexp` ship, and it's the shape the codebase will not regret in 5 phases. F-001 is preserved (still pure Zig, no C dep). F-002 is honoured (finished-form wins): the eventual rewrite from "custom-min" to "real engine" is avoided by paying once now.

**Trades off**: 2-4× the initial LOC of Alternative 1 (~1500-2000 LOC including DFA cache, state interning, and IR optimiser passes). Three-to-five cycles instead of one to ship the Phase 6.6 exit criterion. DFA state cache needs an eviction policy (LRU on a fixed-size table) to avoid pathological memory growth on adversarial inputs — that's a real design surface, not a footnote. Capture groups in DFA mode require a tagged-DFA variant (Laurikari's TDFA) or a fall-back-to-NFA-on-capture strategy; the latter is simpler and is what RE2 does, but it means the DFA fast path only helps `re-find`-without-groups and `clojure.string/split`. Higher initial cognitive load for whoever opens the file next.

**File-by-file shape**:

- `runtime/regex/compile.zig`: Parser → AST → IR (`Program`) with explicit `Inst` union, plus an IR optimiser (dead-state elimination, character-class merging, anchor hoisting). Exposed as `compile(pattern: []const u8, flags: Flags) !Program`. ~700 LOC.
- `runtime/regex/match.zig`: Thread-based NFA matcher (Pike VM) as the correctness baseline. ~350 LOC.
- `runtime/regex/dfa.zig`: Lazy DFA with on-the-fly subset construction, state-cache table keyed by sorted NFA-state-set hash, capped at e.g. 256 states with reset-on-overflow falling back to NFA. ~400 LOC.
- `runtime/regex/exec.zig`: Dispatcher choosing DFA vs NFA per call site (anchored + no-groups + no-backrefs → DFA; otherwise NFA). ~150 LOC.
- `runtime/java/util/regex/Pattern.zig`: JVM-shaped `Pattern` / `Matcher` over `exec.zig`. `Matcher.find` picks executor; `Matcher.group` always uses the NFA path (no DFA capture).
- `lang/primitive/regex.zig`: Same as Alternative 1, but the reader can stash a hint flag on the Tag Value indicating whether the pattern is DFA-eligible (computed at compile time) so `clojure.string/split` short-circuits to the fast path.

**Work split**: 1-cycle: parser + AST + IR + NFA path only, `(re-find #"\d+" "abc123")` → `"123"` green via NFA. 2-cycle: DFA cache + dispatcher, validate `re-seq` throughput on a synthetic 1 MB log-line input. 3-cycle: capture-group plumbing, named groups, `re-groups`, `clojure.string/replace`. 4-cycle: `(?i)` (compile-time case-folding into character classes — no runtime cost), `\b`, `(?:...)`. 5-cycle: error messages aligned with `PatternSyntaxException`, debt row for backreferences (NFA-only follow-up).

### Alternative 3 — Reader-time compile + content-addressed Program cache, AST-driven (wildcard)

**Better than A/B/C**: Reframes "the regex engine" as "an interned compile result that the reader produces once per literal." Every `#"..."` literal in the source program goes through the parser **at read time**, lands an immutable `Program` in a process-global content-addressed cache (keyed by the SHA-256 or 64-bit FNV of the pattern source + flags), and the runtime Tag Value is just a pointer + length into that cache. Three structural wins fall out:

1. The compile cost is paid once per literal across the entire program lifetime — `re-find` in a hot loop never re-parses.
2. `clojure.core` itself has a known finite set of regex literals (`clojure.string/replace`'s internal `\\` handling, ns parser, edn reader); these are *all* compilable at AOT time, lifted into the binary as `comptime`-built `Program` constants. No runtime compile cost for the standard library at all.
3. The matcher can be **AST-walking** instead of VM-driven for the small-pattern common case. JVM Clojure regex patterns are overwhelmingly short (≤ 30 chars, ≤ 5 nodes); a recursive `match(node, input, pos, captures)` over the AST is ~200 LOC, has no VM dispatch overhead, and inlines well. The Pike VM is only built for patterns that opt in via a complexity heuristic (alternation count + Kleene star count > threshold), so the engine has *two* matchers, picked at compile time, both small.

The "AST not bytecode" choice is the genuinely unconventional bit — every textbook engine compiles to bytecode-ish IR because that's what RE2 / PCRE / Go does, but those engines amortise compile cost over throughput, which is the wrong target for a Clojure runtime where most patterns match short strings dozens to hundreds of times.

**Trades off**: The compile-time cache adds a synchronisation surface (write-once map). On a single-threaded Phase 6 runtime this is trivial; once Phase 11+ adds threads it needs proper handling (one `Mutex`, or an immutable map swapped via CAS). The AST-walker doesn't handle catastrophic backtracking — `(a+)+b` against `aaaa...` blows up; the complexity heuristic must catch this at compile time and route to the Pike VM, which means the heuristic is now load-bearing for correctness. Memory: every distinct regex literal in the program's history lives forever in the cache (no eviction); for a typical Clojure program this is bounded (tens to low hundreds of patterns) but it's a real footprint. Reader-time compile means a malformed `#"..."` throws at read time, not match time — a *better* behaviour than JVM Clojure (which only fails on first use), but it's a visible semantic difference users may notice.

**File-by-file shape**:

- `runtime/regex/compile.zig`: Parser producing an immutable AST (`Node` tagged union, arena-allocated into the cache's arena). Computes complexity heuristic and stamps `Program.kind = .ast_walk | .pike_vm`. The Pike VM `Inst[]` is only emitted when needed. Exposes `intern(pattern, flags) !*const Program` against the global cache. ~500 LOC.
- `runtime/regex/match.zig`: Two matchers in one file. `matchAst(prog, input)` is a recursive walker (~250 LOC). `matchPike(prog, input)` is the Thompson VM for opt-in patterns (~250 LOC). Dispatcher is a one-line `switch (prog.kind)`. Both share a small `Captures` struct.
- `runtime/regex/cache.zig`: Process-global `PatternCache` — a `std.HashMap([]const u8, *const Program)` keyed by `pattern ++ flags` bytes, backed by a dedicated `ArenaAllocator` so `Program` lifetime equals process lifetime. ~80 LOC.
- `runtime/java/util/regex/Pattern.zig`: `Pattern.compile(s)` is `cache.intern(s, .{})`. `Matcher` is a value type holding `*const Program` + capture state — no heap allocation for matchers. JVM-shaped API on top.
- `lang/primitive/regex.zig`: Reader change (touches `lang/reader.zig` by reference): on `#"..."` token, call `cache.intern(...)` immediately and emit a Tag Value holding the `*const Program`. `re-find` / `re-matches` / `re-seq` / `re-groups` / `clojure.string/replace` + `split` all dereference the program pointer directly — no compile dispatch on the call path.

**Work split**: 1-cycle: AST + recursive walker + cache + `intern` + reader integration + Phase 6.6 exit green. The Pike VM is **not** built in cycle 1; the complexity heuristic just rejects patterns it can't handle yet (debt row). 2-cycle: Pike VM for alternation-heavy / star-nested patterns, heuristic refinement. 3-cycle: capture groups in both matchers, `re-groups`, named groups. 4-cycle: `(?i)` via compile-time case-folding into the AST (the AST walker gets the folded form for free), `\b`, anchors. 5-cycle: `comptime`-lifted core patterns (a small build-time codegen step that scans `lang/core/*.clj` for `#"..."` literals and emits a `const _: Program = ...;` for each one — pure structural cleanup, optional). Backreferences and lookaround land as a separate Phase 8+ debt row.

### Devil's-advocate recommendation

In the main loop's shoes I'd take **Alternative 2 (two-tier with explicit IR)**. F-002 explicitly says finished-form-clean wins over smallest-diff, and the two-tier shape is what cw v1 will *want* by Phase 10+ regardless — building it now avoids the depth-4 rewrite when regex turns out to be on the macro expansion hot path. The IR boundary also pays back immediately by making the parser, optimiser, and matcher independently testable (one of the smells Alternative 1 risks is "parser and matcher fused into one tangle that's hard to refactor later"). The 3-5 cycles versus 1 cost is real, but the project priority order in CLAUDE.md (project_facts F-002 > ROADMAP > ADRs) puts the final shape ahead of Phase 6 schedule pressure, and the per-task TDD loop absorbs the extra cycles without ceremony.

That said, Alternative 3's reader-time intern + AST-walker is the one I'd genuinely want to think harder about if I had another hour — the "patterns are immutable interned values, like keywords" framing is much more Clojure-shaped than "patterns are little compiled programs you re-derive at runtime", and it composes beautifully with `comptime`-lifted core patterns. If the main loop has bandwidth for one structural revision later, "promote the Alternative 2 `Program` to live in an Alternative-3-style intern cache" is a single non-breaking refactor — that's the path I'd plan for. The main loop is not bound by this recommendation; the choice is between Alternative 2 today (finished-form-clean immediately) versus Alternative 1 today + structural revision later (smallest-diff first, surgery follows when the smell sensor fires). Both are defensible; the F-002 reading favours 2.

## Consequences (provisional)

Depending on the engine chosen, Phase 6.6 implementation work
is:

- Candidate A: 800-1500 LOC across `runtime/regex/`,
  spread over 3-5 cycles.
- Candidate B: 200-400 LOC for the bind + syntax translation,
  1-2 cycles, plus a `build.zig.zon` edit and the Wasm
  Component compat note.
- Candidate C: 100-200 LOC for the cgo-ish bind, 1 cycle —
  but F-001 conflict.

Once accepted, the regex Tag's `Value` extracts pattern bytes
and engine state through `runtime/regex/compile.zig` ;
`re-find` / `re-matches` / `re-seq` / `replace` / `split`
flow through `runtime/regex/match.zig` and surface in
`lang/primitive/regex.zig`. The Java surface
`runtime/java/util/regex/Pattern.zig` is a thin Backend
marker (`impl-only`) per ADR-0029 D4.

## Affected files (provisional)

- `runtime/regex/compile.zig` (new)
- `runtime/regex/match.zig` (new)
- `runtime/java/util/regex/Pattern.zig` (new)
- `lang/primitive/regex.zig` (new)
- `compat_tiers.yaml` (new fqn entry: `java.util.regex.Pattern`)
- `build.zig.zon` (if candidate B accepted)
- `lang/bootstrap.zig` (register the new primitives)

## Revision history

- 2026-05-25 (Proposed → Accepted, same session): Devil's-advocate
  `general-purpose` subagent forked with the embedded brief. Output
  reflected verbatim into "Alternatives considered". Main loop
  selected Alternative 2 (two-tier IR + lazy-DFA over Pike-NFA)
  per F-002 finished-form-clean wins. Alternative 3 logged as
  post-acceptance follow-up (recall-trigger debt at Phase 10+).
