# Phase 7 entry prereq triad — operational driver

> **Read this BEFORE starting any §9.9 row.** Handover Resume contract
> routes here. This document is self-contained: a cold session reading
> from CLAUDE.md + handover.md + this file should have everything
> needed to execute T1 → T2 → T3 without re-deriving context from
> prior chat.
>
> Created 2026-05-26 at HEAD `8d4841c` (after Phase 7.1 dispatch ABI
> landing). All file:line references are valid at that HEAD; subsequent
> commits may shift line numbers, so use grep over symbolic names rather
> than relying on the cited lines.

## Why this document exists

End of 2026-05-26 session, after Phase 7.1 (dispatch ABI) landed, a
deep retrospective surfaced 3 structural prereqs that should land
**before** any §9.9 Phase 7 row past 7.1. Each one is a Phase 7 entry
concern that becomes substantially more expensive to address after
even one downstream row (7.2 multimethod / 7.3 defprotocol / 7.4
defrecord) lands. The user explicitly approved injection into the
next session's Resume contract rather than mid-session execution
because mid-late-session decision quality degrades and these are
each depth-2-or-higher decisions requiring fresh Devil's-advocate
fork context.

Source of the 3 items: 2026-05-26 session retrospective discussion
between user + autonomous loop. Each item maps to a real structural
debt visible in the current code; none are speculative.

## Triad ordering rationale

Execute **strictly in this order**:

1. **T1**: VM backend parity catch-up + dual-backend-parity rule + hook.
2. **T2**: Symbol heap Value implementation (F-004 Group A slot 1).
3. **T3**: ADR-0035 D9 second amendment — `(:refer-clojure)` semantic
   in cw v1 includes rt.

Why this order:

- **T1 first** because the catch-up cycle is mechanical bookkeeping
  on existing analyzer nodes (RequireNode, NsNode), and the rule +
  hook landing prevents T2/T3's source changes from re-introducing
  VM gaps. Doing T1 second or third would force re-touching T2/T3's
  diff.
- **T2 second** because Symbol heap Value unlocks several T3
  implementation choices (e.g., if `(refer 'rt)` becomes user-callable,
  it needs to accept a symbol arg; without Symbol Value, T3 has to
  pick a workaround). Symbol Value also unlocks 7.3 / 7.4 / 7.7 / 7.8
  downstream.
- **T3 third** because the `(:refer-clojure)` semantic widening
  depends on `(refer ...)` runtime fn shape, which depends on Symbol
  Value (T2).

Total triad estimate: **3-5 cycles** (T1 = 1-2 / T2 = 1-2 / T3 = 1).

After triad lands, resume §9.9 at row 7.0 (boundary review chain) or
skip directly to 7.2 if 7.0's work is considered absorbed by the triad
itself (the triad's VM parity catch-up satisfies 7.0's "Phase tracker
+ bench sweep" portion mechanically).

---

## T1: VM backend parity catch-up + rule landing

### Why now — diagnosis

cw v1 ships **dual backend** as a foundational promise (ADR-0005 +
test/diff/cases.yaml differential test layer). The tree_walk backend
is default; the VM backend is opt-in via `-Dbackend=vm`. Both must
produce equal Values for the same source per ADR-0005.

Reality at HEAD `8d4841c`:

- VM backend works for the ~22 opcodes that landed through Phase 4
  (op_const / op_load_local / op_store_local / op_def / op_get_var /
  op_jump / op_jump_if_false / op_call / op_ret / op_pop / op_dup /
  op_throw / op_make_fn / op_recur / op_invoke_builtin /
  op_push_handler / op_pop_handler / op_match_class / op_in_ns /
  op_vector_literal / op_map_literal / op_set_literal / op_require)
  — see `src/eval/backend/vm/opcode.zig`.
- **Each new analyzer Node added since Phase 6.16.b-4 has shipped
  with VM compiler arms that raise `error.NotImplemented` for
  non-trivial cases**:
  - `RequireNode` (Phase 6.16.b-4 sub-cycle c.4 + c.5): `compileRequire`
    at `src/eval/backend/vm/compiler.zig` raises `error.NotImplemented`
    when `n.alias != null or n.refers.len > 0`. The bare-symbol shape
    works; libspec doesn't.
  - `NsNode` (Phase 6.16.b-4 sub-cycle c.7): `compileNs` treats the
    bare form identically to `op_in_ns` (ignoring `n.refer_clojure`
    correctly because the underlying `op_in_ns` already auto-refers
    clojure.core); but any future `(ns foo (:refer-clojure :exclude
    [...]))` filter would silently drop the filter on VM.
  - Future `MethodCallNode` (row 7.6 lands this): the survey already
    flags `error.NotImplemented` as the planned VM arm.
- Hidden consequence: differential test at Layer 3 only covers the
  paths that BOTH backends implement. Adding a `(ns foo (:refer-clojure :exclude [reduce]))` test to `cases.yaml` would expose the gap, but
  no such test exists today — silent regression.

The drift is real. Past cw history (cw v0.5.0) had the same pattern
emerge late in Phase 7-10 and ate weeks of catch-up time. cw v1's
discipline machinery (hooks + Devil's-advocate) was supposed to
prevent this, but no rule explicitly covers "new analyzer node →
both backends in same commit." T1 lands that rule.

### Survey brief (paste this verbatim to `general-purpose` subagent)

```
You are running Step 0 (Survey) for ClojureWasm v1 Phase 7 entry
prereq T1 — VM backend parity catch-up + dual-backend-parity rule
landing.

Working dir: <repo-root>/
Branch: cw-from-scratch
HEAD baseline: ~8d4841c (or whatever current HEAD is)

Write a 200-400 line survey to
private/notes/phase7-T1-survey.md. Cite file:line throughout.

Coverage:

1. Current VM backend state inventory:
   - All opcodes in src/eval/backend/vm/opcode.zig (Opcode enum)
   - All dispatch arms in src/eval/backend/vm.zig
   - All compile arms in src/eval/backend/vm/compiler.zig
   - Map each analyzer Node variant (src/eval/node.zig) to its VM
     compile arm: present-and-complete / present-but-partial-with-
     NotImplemented / absent. Produce a table.

2. Current differential test surface:
   - test/diff/cases.yaml content + how many cases
   - src/lang/diff_test.zig structure
   - which Node variants are NOT yet exercised by any diff case

3. Analyzer Node variants needing VM catch-up (the deliverables):
   - RequireNode :as / :refer libspec (compileRequire at
     vm/compiler.zig — raises NotImplemented today)
   - NsNode :refer-clojure :exclude / :only (compileNs — silently
     drops filter today; harmless until ns macro takes filters)
   - Future MethodCallNode (row 7.6) — must land both at once per
     new rule

4. Rule landing plan (.claude/rules/dual_backend_parity.md):
   - Triggering scope: any source commit that adds a variant to
     node.zig::Node union OR adds a compileXxx fn to vm/compiler.zig
     OR adds an op_xxx to vm/opcode.zig — must include the matching
     siblings in same commit
   - Discovery criterion (per framework_completion.md):
     `grep "pub fn compile" src/eval/backend/vm/compiler.zig` vs
     `grep '\.[a-z_]*_node =>' src/eval/backend/tree_walk.zig` —
     any tree_walk arm without a vm/compiler arm is a gap
   - Sweep result: run the discovery criterion at HEAD, list gaps
   - Retrofit plan: each gap gets fixed in the same cycle that
     introduces the rule

5. Hook landing plan (scripts/check_dual_backend_parity.sh):
   - PreToolUse on git push
   - Per push: walk each commit's range, check the discovery
     criterion above, fail if a new Node variant lacks a VM
     compiler arm OR if compileXxx body contains `error.NotImplemented`
     without an explicit reference to the OWNING debt row
   - Allow-list: known-deferred VM arms get an inline marker
     `// VM-DEFER: <reason> [refs: D-NNN]` that bypasses the gate
     (similar in spirit to PROVISIONAL marker discipline)

6. ADR-0036 (new ADR) draft outline — see "ADR-0036 draft skeleton"
   below.

7. F-NNN envelope check: F-002 (dual backend is finished form,
   not optional) + F-007 (no chapter cadence resumption) + F-009
   (impl neutrality — VM compiler stays in eval/backend/vm/, no
   cross-layer leak).

8. Risks + Bad Smells:
   - Framework-incomplete: introducing rule without retrofit =
     2-tier population (new Nodes follow rule, old gaps stay) —
     T1 explicitly avoids this by retrofitting in same cycle.
   - Cascade: the catch-up commit touches every existing Node
     variant the discovery criterion flags — large diff. Mitigate
     by splitting into T1.a (retrofit cycle) + T1.b (rule + hook
     landing). Devil's-advocate may recommend single-commit
     instead.
   - Reservation-as-bias: adding op_method_call before row 7.6
     lands the MethodCallNode would be premature; T1 only covers
     EXISTING Node variants that lack VM parity, not future ones.

DIVERGENCE per textbook_survey.md Guard 2: state one cw v1
intentional difference from cw v0's dual-backend handling.
Candidate: cw v1 enforces parity via PreToolUse hook + ADR-0036
contract, whereas cw v0 used ad-hoc "land tree_walk first, fix
VM later" pattern that produced the drift cw v0.5.0 still
carries. cw v1's hook prevents the drift mechanically.

Implementer next moves: 5-10 numbered bullets.
```

### Step 0.6 considerations (main-agent re-laying)

After survey returns, main-agent verifies:

- Discovery criterion is mechanical (not opinionated) — same node
  variant grep must produce same result every run.
- Allow-list marker pattern (`VM-DEFER:`) mirrors PROVISIONAL marker
  discipline so existing tooling pattern (check_provisional_sync.sh)
  can be a template for check_dual_backend_parity.sh.
- Surveyed retrofit scope matches what the survey actually inventories
  — do not skip nodes the survey missed.
- ADR-0036 numbering is correct (max + 1 of existing ADRs at issue
  time; do NOT pre-reserve).

### Devil's-advocate brief (depth-2 mandatory; paste verbatim)

```
Devil's advocate this proposal: ClojureWasm v1 Phase 7 entry prereq
T1 — land "VM backend parity for all current analyzer Nodes" +
introduce ADR-0036 "dual-backend parity contract" + ship
.claude/rules/dual_backend_parity.md + ship
scripts/check_dual_backend_parity.sh as a PreToolUse hook on git
push that blocks commits adding a tree_walk Node arm without the
matching VM compiler arm.

Concrete mechanism:

1. Retrofit existing gaps in same commit: RequireNode's `:as` /
   `:refer` libspec arms get real op_require_with_libspec encoding
   (operand width may need extension to carry alias name + refer
   list as constant-pool refs); NsNode's `:exclude` / `:only`
   filters get op_ns_with_filter or similar. Differential test
   cases added for each.
2. ADR-0036 records: every new analyzer Node variant must land
   tree_walk eval arm + VM compile arm + VM dispatch arm + at
   least one differential test case in same commit. Allow-list
   marker `// VM-DEFER: <reason> [refs: D-NNN]` permits explicit
   deferral with a tracked debt row.
3. Rule .claude/rules/dual_backend_parity.md codifies the
   discipline + cross-references the hook script. Cited in
   principle.md Bad Smell catalogue as a new "Dual-backend drift"
   smell.
4. Hook scripts/check_dual_backend_parity.sh runs at git push;
   walks commit range; uses discovery criterion (grep node.zig
   Node variants vs vm/compiler.zig compile arms); blocks if
   asymmetry detected + commit does not carry VM-DEFER marker.
5. The catch-up cycle lands as 1 commit covering retrofit +
   ADR + rule + hook + tests; smell-audit depth 2 (new ADR +
   new rule cluster).

F-NNN envelope:
- F-002: dual backend is finished form per ADR-0005; cw v1
  cannot drop the promise. Smallest-diff "just fix gaps without
  rule" is the smell we want to prevent.
- F-007: no chapter cadence resumption.
- F-009: rule + hook live in .claude/ + scripts/; no
  src/lang/ or src/runtime/ surface widening.

Existing decisions:
- ADR-0005 dual backend.
- ADR-0021 test layer taxonomy (Layer 3 differential).
- ADR-0023 phase_at_least_N comptime stubs (orthogonal — stubs
  gate by phase, parity gates by Node variant).
- D-073 cluster row in .dev/debt.md (this proposal closes D-073
  + amends its barrier predicate to "parity rule landed").

Produce 3 alternatives within the F-NNN envelope:

Alt 1 — smallest-diff: just retrofit existing gaps in same commit,
defer rule + hook to a later cycle. Pros: smaller diff, fast.
Cons: drift recurs at next Node addition — exactly the smell.

Alt 2 — finished-form-clean (may match proposal): proposal as-is,
OR cleaner = also rewrite vm/compiler.zig's switch over Node to
an exhaustive switch (no `else =>` arm) so any new Node variant
becomes a compile error in vm/compiler.zig until handled. This
turns the discipline from "hook enforces at push time" to
"compiler enforces at build time" — much earlier feedback.

Alt 3 — wildcard: kill VM backend entirely; declare tree_walk +
future JIT (Phase 17) as the only path; relinquish dual backend
promise. Pros: eliminates VM gap class permanently. Cons:
relinquishes ADR-0005 + invalidates Layer 3 differential test
infrastructure; arguably violates F-002 (dual backend WAS the
finished form; abandoning it is post-hoc smallest-diff).

Recommend one. Cite F-NNN reasoning. If recommendation requires
violating F-NNN, lead with that finding.

Word limit: 800.
```

### ADR-0036 draft skeleton (after Devil's-advocate selects)

```markdown
# 0036 — Dual-backend parity contract (Phase 7 entry)

**Status**: Accepted (Devil's-advocate fork landed YYYY-MM-DD)
**Date**: YYYY-MM-DD
**Author**: Shota Kudo (drafted with Claude autonomous loop)
**Tags**: phase-7-entry, dual-backend, VM, tree-walk, parity,
F-002

## Context

[Cite: ADR-0005 declared dual backend; ADR-0021 Layer 3
differential test; D-073 cluster row; phase7_entry_prereq_triad.md
T1 driver. Describe the drift seen at Phase 6.16.b-4 + 6.16.c
+ 6.16.d + 7.1 where VM compile arms shipped as NotImplemented.]

## Decision

### D1: Parity contract

[Every new analyzer Node variant lands tree_walk arm + VM compile
arm + VM dispatch arm + ≥1 differential test in same commit.]

### D2: Allow-list marker

[`// VM-DEFER: <reason> [refs: D-NNN]` permits explicit deferral
with tracked debt; mirrors PROVISIONAL marker shape.]

### D3: Discovery + enforcement

[scripts/check_dual_backend_parity.sh + .claude/rules/dual_backend_parity.md;
PreToolUse:Bash hook on git push.]

### D4: Retrofit in same cycle

[RequireNode :as/:refer; NsNode filters; differential test
additions.]

## Alternatives considered

[Devil's-advocate fork verbatim — Alt 1 smallest-diff /
Alt 2 finished-form-clean (compiler-enforce exhaustive switch) /
Alt 3 wildcard (kill VM).]

## Selection rationale

[Why selected; F-NNN reasoning.]

## Consequences

[Positive: drift eliminated. Negative: cycle cost ~1.5x. Closes
D-073 cluster; amends barrier predicate.]

## Affected files

[List.]

## Revision history

- YYYY-MM-DD issued + accepted.
```

### Rule + hook outlines

`.claude/rules/dual_backend_parity.md` skeleton:

```markdown
# Dual-backend parity discipline

Auto-loaded when editing src/eval/node.zig, src/eval/backend/
tree_walk.zig, or src/eval/backend/vm/* files.

## The rule

Any commit that adds a variant to the `Node` union in
`src/eval/node.zig` MUST also:

1. Add the tree_walk eval arm in `src/eval/backend/tree_walk.zig`
2. Add the VM compile arm in `src/eval/backend/vm/compiler.zig`
3. Add the VM dispatch arm in `src/eval/backend/vm.zig` (if a
   new opcode is needed)
4. Add ≥1 differential case in `test/diff/cases.yaml`

Exceptions: add `// VM-DEFER: <reason> [refs: D-NNN]` inline
comment with a `.dev/debt.md` row tracking the deferred work.

## Why

[ADR-0036 reasoning; cw v0 drift history; etc.]

## Enforcement

scripts/check_dual_backend_parity.sh blocks `git push` when
asymmetry detected.
```

`scripts/check_dual_backend_parity.sh` outline:

```bash
#!/usr/bin/env bash
# scripts/check_dual_backend_parity.sh
#
# PreToolUse hook on Bash. Blocks `git push` when a commit adds
# a Node variant to src/eval/node.zig without the matching tree_walk
# + vm/compiler + vm dispatch arms in same commit.
# Allow-list: `// VM-DEFER:` inline comments bypass.

set -u
set -o pipefail
source "$(dirname "$0")/hook_lib.sh"

# Pattern from check_provisional_sync.sh: hook_read_command +
# hook_is_git_push; iterate commit range; for each, grep
# node.zig diff for new Node variant + grep vm/compiler.zig
# diff for matching compileXxx; fail if asymmetry.

# Discovery criterion:
#   tree_walk arms = grep -E '\.[a-z_]+_node =>' src/eval/backend/tree_walk.zig
#   vm compile arms = grep -E 'fn compile[A-Z]' src/eval/backend/vm/compiler.zig
#   The intersection must be 1:1 modulo VM-DEFER markers.

# [implementation TBD per Step 1 plan]
```

### Acceptance criteria

T1 done when:

- All existing analyzer Nodes have full VM compile arms OR an
  explicit `VM-DEFER:` marker.
- ADR-0036 Accepted with Devil's-advocate verbatim embedding.
- `.claude/rules/dual_backend_parity.md` lives + auto-loads on
  the relevant paths.
- `scripts/check_dual_backend_parity.sh` exists + wired in
  `.claude/settings.json` PreToolUse:Bash hooks alongside
  check_provisional_sync.sh.
- Mac + OrbStack gates green.
- D-073 cluster row in `.dev/debt.md` amends barrier predicate
  to "ADR-0036 contract enforced" (or Discharged if Devil's-
  advocate recommendation eliminates the need).

---

## T2: Symbol heap Value impl (F-004 Group A slot 1)

### Why now — diagnosis

cw v1 reader produces symbol Forms; analyzer extracts them in
`analyzeSymbol`. But `(quote sym)` cannot evaluate to a Value
because **cw v1 has no Symbol heap Value yet** (F-004 reserves
Group A slot 1 — see `.dev/project_facts.md` F-004 section).

Concrete current behavior:
- `src/eval/analyzer/analyzer.zig:620` raises
  `feature_not_supported "Quoted symbol as Value"` in `formToValue`
  for `.symbol` Forms.
- Phase 6.16.b-4 sub-cycle c.4 was forced to ship `require` as
  an **analyzer special form** (not the JVM-shape runtime fn)
  because `(require 'clojure.set)` would otherwise fail at
  `formToValue` on the quoted symbol. See ADR-0035 D2 amendment
  Revision history.
- Phase 6.16.c Group E shipped `macroexpand-all` as a `throw`-stub
  for the same reason chain (symbol Value gap → reader metadata
  `^:unsupported` shorthand gap → declare-only path unreachable).

Phase 7 cascades the gap:
- **7.3 defprotocol**: parses `(defprotocol P (m [x]))` — needs
  `'P` + `'m` as runtime values.
- **7.4 defrecord**: parses `(defrecord Foo [x y])` — needs `'Foo`
  + `'x` + `'y` as values.
- **7.5 reify**: anonymous protocol method bodies that reference
  symbol-bound captures.
- **7.7 extend-type**: `(extend-type Foo P (m [x] ...))` — needs
  symbol args.
- **7.8 multi-arity fn***: `(fn* ([x] body) ([x y] body))` —
  arg-vector symbols may need runtime introspection.

Without Symbol Value, each of these forces an analyzer-only
special-form workaround. The cumulative cost of 5 special-form
workarounds is much higher than one Symbol Value impl cycle.

Phase 7 entry is the **natural landing window** because:
- F-004 reserves the slot already; no spec collision.
- Keyword interner (`src/runtime/keyword.zig`, 303 lines) provides
  a working pattern to copy.
- Symbol Value impl is ~200-300 LOC self-contained.

### Survey brief

```
You are running Step 0 (Survey) for ClojureWasm v1 Phase 7 entry
prereq T2 — Symbol heap Value impl (F-004 Group A slot 1).

Working dir: <repo-root>/
Branch: cw-from-scratch
HEAD: ~current

Write a 200-400 line survey to private/notes/phase7-T2-survey.md.

Coverage:

1. F-004 Group A slot 1 spec:
   - .dev/project_facts.md F-004 section — quote the symbol slot
     reservation verbatim
   - structure_plan.md if it carries Symbol-related notes

2. Current state at HEAD:
   - src/eval/form.zig — SymbolRef shape (ns + name)
   - src/eval/analyzer/analyzer.zig formToValue — line that
     raises feature_not_supported on .symbol Form
   - All call sites that would benefit if Symbol Value landed:
     grep for `Quoted symbol as Value` + `\\.symbol \\=>` arms
     in analyzer / tree_walk / vm

3. Keyword interner pattern (src/runtime/keyword.zig):
   - Heap struct shape (Keyword struct + HeapHeader)
   - Interner registry on Runtime (KeywordInterner)
   - intern(rt, ns, name) entry point + lock wrapping
   - asKeyword(val) decode
   - registerGcHooks + finaliser
   - This is the template Symbol Value should follow

4. NaN-box tag allocation:
   - src/runtime/value/heap_tag.zig — current Tag enum
   - F-004 says Group A slot 1 = symbol; check if a Tag entry
     exists today and is unused (Phase 4 day-1 enum reservation
     pattern per ADR-0004)

5. Tag dispatch sites that need updates:
   - src/runtime/print.zig::printValue — add .symbol arm rendering
     `(ns/)?name` (no leading colon)
   - Equality semantics — interned symbols compare by pointer
   - src/eval/analyzer/analyzer.zig::formToValue — switch from
     raise to intern + return

6. Downstream callers that get unblocked:
   - Phase 7.3 defprotocol analyzer (symbol parsing)
   - Phase 7.4 defrecord analyzer
   - Phase 7.7 extend-type analyzer
   - `require` runtime fn migration (ADR-0035 D2 second amendment;
     special form → runtime fn possible)
   - `(quote sym)` eval succeeds
   - `(name 'sym)` in core.zig nameFn — add the symbol arm
   - `gensym` runtime impl (no more arena-only)
   - `macroexpand-all` Pattern A defn possible (T3 amendment lands
     in same vicinity)

7. Symbol-specific semantics decisions:
   - Interning policy: intern by (ns, name) tuple like keyword?
     Or non-interned (each (quote sym) creates fresh)?
   - Metadata on symbols (^:dynamic etc.): defer (Phase 7+
     metadata layer) or include in Symbol struct?
   - `clojure.core/symbol` constructor: 1-arg + 2-arg, mirror keyword
   - `clojure.core/symbol?` predicate (currently in core.zig:symbolQ
     dispatches on tag — already works against heap_tag.symbol if
     impl lands)

8. F-NNN envelope: F-004 (slot reserved) + F-002 (finished form,
   no half-impl) + F-009 (impl in runtime/symbol.zig parallel to
   keyword.zig).

9. ADR-0037 (new ADR) draft outline.

DIVERGENCE: pick one cw v1 vs cw v0 vs JVM intentional diff.
Candidate: cw v1 may choose pointer-eq interning (matching
keyword) where JVM uses Symbol.intern but stores per-instance
metadata, requiring per-Value-not-per-Pointer equality.

Implementer next moves: 5-10 bullets.
```

### Step 0.6 considerations

- F-004 amendment NOT needed (slot is already reserved); this
  T2 lands the actual impl. No user-facing F-NNN spec drift.
- Verify keyword interner mutex pattern is appropriate for
  symbol (concurrency story is same).
- Confirm no existing code path assumes "no symbol Value exists"
  — grep for `feature_not_supported.*Quoted symbol` to find all
  shim sites.

### Devil's-advocate brief (depth-2 mandatory)

```
Devil's advocate this proposal: implement Symbol heap Value
(F-004 Group A slot 1) as cw v1 Phase 7 entry prereq T2.

Concrete mechanism:

1. New file src/runtime/symbol.zig parallel to runtime/keyword.zig:
   - pub const Symbol = struct { header, ns: ?[]const u8, name,
     hash_cache } extern struct
   - pub const SymbolInterner = struct (mutex-protected table)
   - pub fn intern(rt, ns, name) !Value
   - pub fn find(rt, ns, name) ?Value
   - pub fn asSymbol(val) *const Symbol
   - registerGcHooks + finaliser
2. Tag slot: src/runtime/value/heap_tag.zig — confirm/add
   Tag.symbol = 1 (Group A slot 1 per F-004); update any
   exhaustive switch sites
3. Runtime field: src/runtime/runtime.zig — symbols:
   SymbolInterner (parallel to keywords field; init in
   Runtime.init; deinit in Runtime.deinit)
4. printValue branch in src/runtime/print.zig — render symbol
   as `ns/name` or `name`, no leading colon
5. formToValue branch in src/eval/analyzer/analyzer.zig:620 —
   replace raise with `keyword_mod.equiv-fn for symbol_mod.intern
   (rt, sym.ns, sym.name)` (note: needs rt access from analyzer;
   currently analyzer has rt parameter — verify)
6. core.zig: add `symbol` Tier-A primitive (1-arg or 2-arg, mirror
   keyword fn shape); extend nameFn to handle .symbol tag
7. Unit tests in symbol.zig (intern roundtrip, eq via pointer,
   etc.)
8. e2e test: (quote sym) prints as sym; (symbol "foo")
   roundtrips; (= 'foo 'foo) returns true; (name 'ns/x) → "x"

F-NNN envelope:
- F-004 reserves Group A slot 1 (this is the impl, not the spec
  decision — spec already user-confirmed)
- F-002 finished form: do full intern + GC integration + print +
  eq; partial impl is smell
- F-007 chapter cadence dormant
- F-009 impl in runtime/symbol.zig neutral; lang/primitive
  surface lands separately

Existing decisions:
- F-004 (Group A slot 1 reserved)
- Keyword interner pattern (src/runtime/keyword.zig)
- ADR-0035 D2 (require became special form because Symbol Value
  was missing — this T2 reverses that constraint)

Produce 3 alternatives within F-NNN envelope:

Alt 1 — smallest-diff: ship Symbol Value WITHOUT interning (each
quoted symbol creates fresh heap value; eq compares strings).
Pros: simpler impl, no interner needed, no concurrency. Cons:
loses pointer-eq semantic Clojure depends on; slower eq at every
call site.

Alt 2 — finished-form-clean: proposal as-is — intern by (ns, name)
tuple mirroring keyword; pointer-eq fast path; full GC
integration; concurrency-ready mutex.

Alt 3 — wildcard: defer Symbol Value to Phase 8 OR Phase 11
self-hosting milestone where compiler reads source. Pros: avoids
T2 entirely in Phase 7. Cons: forces 5 Phase 7 rows (7.3 / 7.4 /
7.5 / 7.7 / 7.8) into workaround mode each; cumulative cost
likely > T2's cost.

Recommend one within envelope.

Word limit: 800.
```

### ADR-0037 draft skeleton

```markdown
# 0037 — Symbol heap Value impl (F-004 Group A slot 1)

**Status**: Accepted (Devil's-advocate fork landed YYYY-MM-DD)
**Date**: YYYY-MM-DD
**Author**: Shota Kudo (drafted with Claude autonomous loop)
**Tags**: phase-7-entry, symbol, heap-value, F-004, interner

## Context

[F-004 reserved Group A slot 1 for Symbol; impl landed at Phase 7
entry because cumulative downstream cost (5 rows) exceeds direct
impl cost. ADR-0035 D2 first amendment shipped require as special
form pending this Value impl.]

## Decision

### D1: Pointer-eq interning (mirror keyword)
### D2: New file runtime/symbol.zig + Tag slot
### D3: Runtime.symbols: SymbolInterner field
### D4: formToValue intern + printValue branch + nameFn extension
### D5: clojure.core/symbol + symbol? primitives

## Alternatives considered

[Devil's-advocate verbatim]

## Selection rationale

## Consequences

[Unblocks: require runtime fn migration possible (ADR-0035 D2
second amendment may follow); defprotocol / defrecord / extend-type
parsing; macroexpand-all Pattern A; gensym runtime impl; (name
'sym).]

## Affected files

## Revision history

- YYYY-MM-DD issued + accepted.
```

### Acceptance criteria

T2 done when:

- `src/runtime/symbol.zig` exists + parallel to keyword.zig
- `Runtime.symbols: SymbolInterner` field initialized
- Tag.symbol = 1 (Group A slot 1) wired
- `printValue` renders symbol correctly
- `formToValue` interns instead of raising
- `clojure.core/symbol` + `symbol?` (already exists for tag check) work
- `(quote sym)` evaluates; `(= 'foo 'foo)` is true; `(name 'ns/x)` is `"x"`
- ADR-0037 Accepted with Devil's-advocate verbatim
- Mac + OrbStack gates green
- ADR-0035 D2 Revision history adds second amendment note
  (optional — can defer to a follow-up cycle that actually
  migrates `require` from special form to runtime fn)

---

## T3: ADR-0035 D9 second amendment — `(:refer-clojure)` semantic

### Why now — diagnosis

ADR-0035 D9 first amendment (Phase 6.16.b-4 sub-cycle d, commit
`a762ca9`) re-classified the rt + clojure.core auto-refer in
`evalInNs` / `op_in_ns` as "load-bearing convenience" instead of
"PROVISIONAL pending finished form." This was honest given that
core.clj uses rt primitives (`count` / `conj` / `reduce` / `assoc`)
unqualified throughout, so removing the auto-refer would have
required mass-qualifying ~50+ sites in core.clj.

But the re-classification left an **asymmetry**:

| Resolution path                         | Mechanism                                                 | Visible in source?        |
|-----------------------------------------|-----------------------------------------------------------|---------------------------|
| user/ → clojure.core                   | `bootstrap.zig` `referAll(clojure.core, user)` at boot    | ✓ explicit               |
| user/ → rt                             | `primitive.zig::registerAll` `referAll(rt, user)` at boot | ✓ explicit               |
| clojure.set/walk/string → clojure.core | `(ns foo (:refer-clojure))` macro fires referAll          | ✓ explicit via .clj head |
| clojure.set/walk/string → rt           | `evalNs` / `evalInNs` auto-refer (silent)                 | ✗ implicit               |
| user `(in-ns 'foo)` → rt + cc          | `evalInNs` auto-refer (silent)                            | ✗ implicit               |

A reader of `clojure.set/union`'s body using `reduce` cannot grep
`referAll` to find where `reduce` becomes visible — it's in
`evalNs` Zig code, not the `.clj` source. This is the "規律がわからん"
shape the user flagged.

The user's 3-option framing from this session:

**(A) Full rt elimination**: move all rt primitives to clojure.core
ns; eliminate rt as user-visible. Cleanest finished form. Cost:
mass-qualify or full re-intern of ~30+ primitives, refactor 4
`.clj` files, touch every registerAll fn. Estimated 1-2 cycles,
high coordination cost.

**(B) `(:refer-clojure)` semantic widening**: in cw v1 specifically,
`(:refer-clojure)` directive refers BOTH clojure.core AND rt
namespaces into the entering ns. Documented as cw v1 divergence
from JVM (where rt doesn't exist). evalInNs / op_in_ns auto-refer
blocks get removed because `(ns ...)` macro expansion fires
referAll for both rt and clojure.core explicitly. User `(in-ns
'foo)` becomes a naked switch (user must call `(refer 'rt)` +
`(refer 'clojure.core)` explicitly — or use `(ns ...)`). Cost:
single amendment + evalNs/evalInNs simplification. Estimated 1 cycle.

**(C) Current state + docstring strengthening**: leave behavior
as-is; add a clear docstring in evalInNs explaining the auto-refer
is intentional convenience. Cheapest. Leaves "規律がわからん"
unsolved.

User's recommendation in this session: **(B) at Phase 7 entry**.
(A) deferred to Phase 10-11 entry when Tier A polish provides
budget for the elimination.

### Survey brief

```
You are running Step 0 (Survey) for ClojureWasm v1 Phase 7 entry
prereq T3 — ADR-0035 D9 second amendment for (:refer-clojure)
semantic widening in cw v1 to include rt.

Working dir: <repo-root>/
Branch: cw-from-scratch
HEAD: ~current

Write a 200-400 line survey to private/notes/phase7-T3-survey.md.

Coverage:

1. Current evalNs / evalInNs / op_in_ns implementation:
   - src/eval/backend/tree_walk.zig evalInNs body (line range
     ~266-281 at HEAD 8d4841c; verify current line)
   - src/eval/backend/tree_walk.zig evalNs body (line range
     ~290-310)
   - src/eval/backend/vm.zig op_in_ns dispatch arm (line range
     ~314-340)
   - src/eval/backend/vm/compiler.zig compileNs (line range
     ~370-390)
   - All cite the rt + clojure.core auto-refer blocks

2. ADR-0035 D9 first amendment text (2026-05-26 sub-cycle d):
   - Read .dev/decisions/0035_require_spec.md Revision history
   - Quote the D9 amendment re-classification rationale
   - Note: D9 first amendment KEPT the auto-refer; this T3 is
     the SECOND amendment that adjusts the semantic

3. (:refer-clojure) directive flow:
   - src/eval/analyzer/special_forms.zig::analyzeNs (line range
     ~200-260) — how :refer-clojure is currently parsed
   - NsNode.refer_clojure field — currently bool; T3 may extend
     to enum { yes, no, with_exclude, with_only } depending on
     filter support landing
   - For T3 minimum, just verify the bool is honored by evalNs +
     compileNs

4. Cross-ns refer paths inventory:
   - bootstrap.zig::loadCore end-of-loop refer fan-out (post-
     amendment-1: refers clojure.core → user only)
   - primitive.zig::registerAll referAll(rt, user)
   - macro_transforms.zig::registerInto referAll(rt, user)
   - evalInNs auto-refer (rt + clojure.core)
   - evalNs auto-refer (rt + clojure.core when refer_clojure
     true)
   - op_in_ns auto-refer (rt + clojure.core)
   - 6 site total

5. T3 (B) option mechanics — refer-clojure widening:
   - evalNs: when refer_clojure = true, fire BOTH referAll(rt,
     here) AND referAll(clojure.core, here) explicitly inside
     evalNs body. evalNs becomes the SOLE site of the refer for
     `.clj` heads. Already does both via the current auto-refer
     block (no behavior change here).
   - evalInNs: REMOVE the auto-refer block. User `(in-ns 'foo)`
     becomes a naked ns switch. User must explicitly refer.
   - op_in_ns: REMOVE the auto-refer block in vm.zig (mirror of
     evalInNs).
   - compileNs: stays as op_in_ns + emit op_refer(rt) +
     op_refer(clojure.core) if refer_clojure (new opcode needed
     OR inline as op_invoke_builtin call into a new
     refer-ns builtin).
   - bootstrap.zig: stays — user/ ns is not a `.clj` file, so
     its refers come from boot-time fan-out (no .clj head fires
     for it).
   - primitive.zig + macro_transforms.zig: stay — boot-time
     user/ population.
   - 4 .clj heads: stay at `(ns foo (:refer-clojure))` — gain
     explicit rt refer via the widened semantic; no source
     change needed.

6. Test impact:
   - All existing e2e tests pass IF user code uses `(ns ...)` or
     stays in user/ where boot-time fan-out covers refers.
   - Tests that use `(in-ns 'other-ns)` and then call rt primitives
     unqualified WILL BREAK. Search test/e2e/ for `(in-ns`:
     - test/e2e/phase6_16_b_4_private_leaf.sh L?? — uses (in-ns
       'clojure.core) then -map-eager unqualified. Since
       clojure.core is the target ns, the leaf is same-ns so
       passes. But if it called e.g. `count` unqualified, it
       would break.
   - Survey lists all (in-ns) sites in tests and predicts impact.
   - Decision: do tests need rewriting, or does evalInNs need a
     softer rule (e.g., keep clojure.core refer, drop only rt
     refer)?

7. F-NNN envelope:
   - F-002: finished form; asymmetry removal is the goal
   - F-009: impl in runtime/eval/ stays; no surface widening
   - No F-NNN violation; this is intra-impl cleanup

8. ADR-0035 Revision history: append D9 second amendment with
   full Devil's-advocate verbatim. Do NOT create a new ADR;
   amend in place per ADR governance.

DIVERGENCE: cw v1 (:refer-clojure) semantic includes rt by
default; JVM doesn't have rt namespace so the divergence is
purely cw v1 internal.

Implementer next moves: 5-10 bullets.
```

### Step 0.6 considerations

- Verify (in-ns) test sites won't break catastrophically before
  committing T3. If many tests break, consider keeping evalInNs's
  clojure.core auto-refer (= partial (B) — drop only rt auto-
  refer, keep clojure.core) as a softer landing.
- ADR-0035 amendment is depth-2 (in-place amendment to existing
  D9 of an Accepted ADR); Devil's-advocate fork mandatory.
- Coordinate with T1's parity rule — adding a new `op_refer`
  opcode (if chosen) must land tree_walk + VM compile + VM
  dispatch + differential test all together per T1's contract.

### Devil's-advocate brief

```
Devil's advocate this proposal: ADR-0035 D9 second amendment for
ClojureWasm v1. Widen the `(:refer-clojure)` directive's cw v1
semantic to refer BOTH clojure.core AND rt namespaces into the
entering ns. Remove the rt + clojure.core auto-refer blocks from
evalInNs / op_in_ns. User `(in-ns 'foo)` becomes a naked ns
switch. `(ns ...)` macro expansion remains the canonical entry
to a ns with refers.

Concrete mechanism: see T3 mechanism in
.dev/phase7_entry_prereq_triad.md §T3.

Existing decisions:
- ADR-0035 D9 first amendment (sub-cycle d, 2026-05-26 commit
  a762ca9) — re-classified the auto-refer as load-bearing
  convenience instead of removing it. This T3 is the second
  amendment that adjusts the trade-off.
- ADR-0035 D1 (:refer-clojure) parser landed in analyzeNs (Phase
  6.16.b-4 sub-cycle c.7).
- core.clj uses rt primitives unqualified throughout; sub-cycle d
  Devil's-advocate Alt 2 found full rt removal requires mass-
  qualify of ~50 sites. T3 (B) avoids mass-qualify by widening
  :refer-clojure semantic instead.

F-NNN envelope:
- F-002 finished form: T3 removes the "implicit auto-refer"
  asymmetry — `.clj` source's refer comes from the (ns ...)
  head, not from Zig magic
- F-007 chapter cadence dormant
- F-009 neutrality

Produce 3 alternatives within envelope:

Alt 1 — smallest-diff: option (C) from user discussion — keep
behavior, strengthen docstring only. Cheap; leaves asymmetry
visible only as a comment.

Alt 2 — finished-form-clean: option (B) from user discussion as
proposal — (:refer-clojure) widening + auto-refer block removal.
OR cleaner = option (A) full rt elimination; move all primitives
to clojure.core; eliminate rt as user-visible. (A) is the
ultimate finished form but ~50 site mass-qualify; defer.

Alt 3 — wildcard: invert the semantic — make rt visible to ALL
namespaces by default (no refer needed); `(:refer-clojure)`
becomes additive over the always-rt-base. Pros: matches JVM
mental model where built-ins always work. Cons: cw v1's
clojure.core/-map-eager privacy (sub-cycle a, ADR-0033 D4
amendment) depends on cross-ns access control; making rt
always-visible would interact weirdly with private leaf
discipline.

Recommend one. F-NNN reasoning. Lead with violations if any.

Word limit: 800.
```

### ADR-0035 D9 second amendment skeleton

Append to `.dev/decisions/0035_require_spec.md` Revision history:

```markdown
- 2026-MM-DD D9 second amendment (Phase 7 entry T3) — widen
  cw v1 `(:refer-clojure)` semantic to include rt namespace +
  remove auto-refer blocks from evalInNs / op_in_ns.

  Rationale: D9 first amendment (sub-cycle d, commit a762ca9)
  re-classified the rt + clojure.core auto-refer in evalInNs /
  op_in_ns as "load-bearing convenience" — honest but left an
  asymmetry where `.clj` source could not grep-trace where rt
  primitives became visible (the referAll happens in Zig, not
  source). This second amendment removes the asymmetry by:

  - Widening the cw v1 `(:refer-clojure)` directive semantic
    to refer BOTH clojure.core AND rt into the entering ns.
    `.clj` heads `(ns foo (:refer-clojure))` thus install both
    refers explicitly via the analyzer special form.
  - Removing the rt + clojure.core auto-refer blocks from
    evalInNs (tree_walk) + op_in_ns (VM dispatch). User
    `(in-ns 'foo)` becomes a naked ns switch; user must
    explicitly `(refer 'rt)` or use `(ns foo (:refer-clojure))`.
  - Bootstrap fan-out (primitive.zig::registerAll +
    macro_transforms.zig::registerInto + bootstrap.zig end-of-
    loop refer of clojure.core into user/) stays — user/ is not
    a `.clj` file, so its initial refers must come from boot-
    time setup.

  cw v1 divergence from JVM: JVM has no `rt` ns; the widened
  `(:refer-clojure)` semantic is cw-specific. ADR-0033 D4
  private leaf semantics in clojure.core unaffected (private
  check is per-Var-ns, not per-refer-source).

  Devil's-advocate fork (depth-2, fresh context) verbatim:

  [paste Devil's-advocate output here]

  Selected: Alt 2 / option (B). Full rt elimination (option (A))
  deferred to Phase 10-11 entry when Tier A polish provides
  budget for the mass-qualify cost.

  Affected files (modified):
  - src/eval/backend/tree_walk.zig evalInNs (remove auto-refer
    block)
  - src/eval/backend/vm.zig op_in_ns dispatch (remove auto-refer
    block)
  - src/eval/backend/tree_walk.zig evalNs (verify it still
    explicitly refers rt + clojure.core when refer_clojure true;
    no behavioral change but docstring update)
  - src/eval/backend/vm/compiler.zig compileNs (if op_refer or
    similar landed, emit it; otherwise mark VM-DEFER per T1
    contract)
```

### Acceptance criteria

T3 done when:

- evalInNs body is `env.current_ns = findOrCreateNs(...); return nil_val;`
- op_in_ns dispatch body is mirror of above
- evalNs explicitly fires `referAll(rt, here)` + `referAll(clojure.core, here)` when `refer_clojure` true (docstring updated to note this is the SOLE source of refer for `.clj` heads)
- ADR-0035 D9 second amendment in Revision history with Devil's-advocate verbatim
- All existing e2e tests pass (or test rewrite landing in same cycle if survey found breakages)
- Mac + OrbStack gates green

---

## References (verified at HEAD `8d4841c`)

### Tracked design SSOTs

- [`CLAUDE.md`](../CLAUDE.md) — § Project spirit / § Autonomous Workflow / § The only stop
- [`.dev/project_facts.md`](project_facts.md) — F-001..F-009 (especially F-002 finished-form, F-004 Group A slot 1, F-009 neutrality)
- [`.dev/principle.md`](principle.md) — Bad Smell catalogue, Devil's-advocate mandate, four depths of revision
- [`.dev/structure_plan.md`](structure_plan.md) — anticipated directory tree Phase 5-20
- [`.dev/ROADMAP.md`](ROADMAP.md) §9.9 — Phase 7 task table (this triad lands BEFORE row 7.2)

### Tracked ADRs

- [`.dev/decisions/0005_*.md`](decisions/) — dual backend (T1's foundational reference)
- [`.dev/decisions/0008_protocol_dispatch_unify.md`](decisions/0008_protocol_dispatch_unify.md) — Phase 7.1 dispatch ABI amendment 1 just landed
- [`.dev/decisions/0021_*.md`](decisions/) — test layer taxonomy (T1's Layer 3 differential test reference)
- [`.dev/decisions/0023_comptime_stub_pattern.md`](decisions/0023_comptime_stub_pattern.md) — phase_at_least_N stubs (T1 orthogonal)
- [`.dev/decisions/0033_clojure_ns_placement_naming_polymorphism.md`](decisions/0033_clojure_ns_placement_naming_polymorphism.md) — D4 private leaf semantics (T3 must not break)
- [`.dev/decisions/0035_require_spec.md`](decisions/0035_require_spec.md) — T3 amends this ADR's D9 in place

### Tracked debt + provisional triad

- [`.dev/debt.md`](debt.md) — D-073 (VM parity cluster; T1 closes / amends) + D-058 / D-063 / D-071 (Discharged Phase 6.16.b-4) + D-078 (string RED defer) + D-079 (host-class aggregator) + D-080 (clojure.zip deferral)
- [`feature_deps.yaml`](../feature_deps.yaml) — 5 remaining provisional entries; T3 may discharge `runtime/eval/in_ns_auto_refer` if option (B) lands cleanly

### Source files (file:line at HEAD; verify with grep before edit)

- `src/runtime/keyword.zig` (303 lines) — T2 template for SymbolInterner
- `src/runtime/dispatch.zig` (371 lines) — Phase 7.1 dispatch fn landed here
- `src/runtime/dispatch/method_table.zig` (164 lines) — CallSite skeleton
- `src/eval/backend/vm/compiler.zig` (934 lines) — T1 retrofit target
- `src/eval/backend/vm/opcode.zig` (207 lines) — T1 opcode additions land here
- `src/eval/backend/vm.zig` (903 lines) — T1 dispatch arms + T3 op_in_ns mod
- `src/eval/backend/tree_walk.zig` — T3 evalInNs mod (search for `fn evalInNs`)
- `src/eval/analyzer/analyzer.zig` — T2 formToValue mod (search for `Quoted symbol as Value`)
- `src/eval/analyzer/special_forms.zig` — analyzeNs at ~L200-260
- `src/lang/primitive/core.zig` — T2 adds `symbol` + extends `nameFn`
- `src/lang/bootstrap.zig` — T3 may or may not touch end-of-loop fan-out
- `src/lang/primitive.zig` — T3 boot-time referAll(rt, user) site (keep)
- `src/lang/macro_transforms.zig` — same
- `src/lang/clj/clojure/{core,set,string,walk}.clj` — T3 .clj heads (no change if (B); change if (A))

### Tracked rules (auto-loaded)

- [`.claude/rules/provisional_marker.md`](../.claude/rules/provisional_marker.md) — T1's allow-list marker `VM-DEFER:` mirrors PROVISIONAL: shape
- [`.claude/rules/framework_completion.md`](../.claude/rules/framework_completion.md) — T1 must satisfy discovery criterion + sweep + retrofit in same cycle
- [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md) — handover discipline (this doc routes from handover)
- [`.claude/rules/extended_challenge.md`](../.claude/rules/extended_challenge.md) — applies only on user stop
- [`.claude/rules/textbook_survey.md`](../.claude/rules/textbook_survey.md) — Step 0 / Step 0.6 / DIVERGENCE shape

### Existing PreToolUse hook (T1 template)

- `scripts/check_provisional_sync.sh` + `scripts/hook_lib.sh` — T1's check_dual_backend_parity.sh follows the same shape

---

## Cold-start verification checklist (Step 1 on resume)

When `/continue` fires after this commit + handover update, verify
in order:

1. [ ] SessionStart hook prints handover.md content
2. [ ] handover Resume contract names "First commit MUST be: read
       `.dev/phase7_entry_prereq_triad.md` and execute T1 → T2 → T3"
3. [ ] handover Cold-start reading order lists this file
4. [ ] This file (`.dev/phase7_entry_prereq_triad.md`) opens
       cleanly + all internal `[`text`](path)` links resolve
5. [ ] `private/notes/phase7-7.1-survey.md` exists (sibling
       artifact from this session; T1 may reference its
       findings)
6. [ ] `git log --oneline -5` shows `8d4841c` (or descendant) as
       Phase 7.1 landing
7. [ ] `bash test/run_all.sh` Mac gate green (baseline confirm)
8. [ ] `orb run -m my-ubuntu-amd64 bash -c 'bash test/run_all.sh'`
       Linux gate green
9. [ ] Phase tracker in ROADMAP.md §9.9 shows Phase 7 IN-PROGRESS
       + row 7.1 [x]
10. [ ] No active TaskList items left over from previous session
11. [ ] Start T1 by spawning the general-purpose subagent with
        the T1 Survey brief above (paste verbatim)

If any check fails, the FIRST resume task is to repair before
starting T1.

---

## What this triad does NOT cover (intentional out-of-scope)

- Phase 7.0 boundary review chain (audit_scaffolding + simplify +
  security-review fan-out) — runs AFTER triad lands, OR can be
  considered absorbed into T1's catch-up cycle if its scope
  expands to include the relevant audits.
- Phase 7.2 multimethod through 7.15 — proceeds AFTER triad lands.
- D-005 JIT go/no-go (Phase 17) — separate decision, no impact.
- D-079 host-class aggregator — separate, Phase 6.16+ or Phase 7
  task on its own.
- D-080 clojure.zip 28 vars — separate, gated on T2 (Symbol Value
  unlocks deftype/defrecord which is also a clojure.zip prereq).

## Status

- Created: 2026-05-26
- Author: Claude autonomous loop (drafted with user direction at
  session end of Phase 7.1 landing)
- HEAD baseline: `8d4841c`
- Lifecycle: this doc is **operational** during Phase 7 entry.
  After T1 + T2 + T3 all land, the doc becomes archival; move to
  `.dev/archive/` (do not delete — Phase 7 design narrative).
