# 0040 — VM bytecode shape for the deftype-family + method-dispatch cluster

- **Status**: Accepted (Devil's-advocate fork landed 2026-05-26)
- **Date**: 2026-05-26
- **Author**: Shota Kudo (drafted with Claude autonomous loop)
- **Tags**: vm, bytecode, opcode, dispatch, callsite-cache, F-002, F-003,
  D-073, ADR-0036

## Context

Phase 7 entry's ADR-0036 (dual_backend_parity contract) carved 5
VM-DEFER sites in `src/eval/backend/vm/compiler.zig` for the
deftype-family analyzer Node variants — `deftype_node`,
`ctor_call_node`, `field_access_node`, `compileRequire` libspec
branch, `compileNs` filter — pending the bytecode shape decisions
each requires. Row 7.6 cycle 1 (commit `40268e2`) added a 6th site,
`method_call_node`, when it landed the `(.method instance args)`
TreeWalk surface + analyzer arm.

Row 7.6 cycle 4 discharges 4 of the cluster's 5 sites:

- `deftype_node` (a)
- `ctor_call_node` (b)
- `field_access_node` (c)
- `method_call_node` (f, new in cycle 1)

Sub-sites (d) `require_libspec` and (e) `ns_filter` are out-of-scope
— they have their own follow-up cycles per ADR-0036 + D-073 row.

## Decision

Adopt **Shape 1 + Shape 1.b** from the row 7.6 survey
(`private/notes/phase7-7.6-survey.md` §5): **4 dedicated opcodes +
CallSite side-table on BytecodeChunk**.

### New opcodes (4)

- `op_deftype` (0x18) — operand = constants index of a heap
  `TypeDescriptorRef` Value (pre-built at analyzer time by
  `runtime/type_descriptor.zig::registerType`). Dispatch reads the
  descriptor pointer and the VM equivalent of `evalDeftype` is a
  no-op (descriptor already registered in `rt.types` by the
  analyzer-time `registerType` call); the op pushes `nil` onto the
  stack to match the TreeWalk return value.
- `op_ctor_call` (0x19) — operand = packed `(name_idx << 8) |
  arg_count`. `name_idx` is the constants-index of a String holding
  the type name. Pops `arg_count` values, looks up the descriptor
  via `rt.types.get(name)`, and calls `allocInstance`.
- `op_field_access` (0x1A) — operand = constants-index of the field
  name String. Pops the receiver, walks `descriptor.field_layout`
  linearly, returns the matching field value (or raises
  `symbol_unresolved`).
- `op_method_call` (0x1B) — operand = `call_site_idx` into the new
  `BytecodeChunk.call_sites: []*CallSite` side-table. The CallSite
  carries the method-name slice + the cached `MethodEntry` pointer
  + `cached_generation`. Pops `arg_count` (encoded into the
  call_site entry) + receiver, dispatches through
  `cs.lookupWithCache(td, null, method_name, generation)` then
  `vt.callFn(rt, env, method_val, args, loc)`.

### BytecodeChunk extension

`src/eval/backend/vm/opcode.zig::BytecodeChunk` grows one slice:

```zig
pub const BytecodeChunk = struct {
    instructions: []const Instruction,
    constants: []const Value,
    call_sites: []const CallSiteEntry = &.{},
};

pub const CallSiteEntry = struct {
    method_name: []const u8,
    arg_count: u16,
    cache: method_table.CallSite = .{},
};
```

Analyzer-arena-owned (chunk lifetime = analyzer arena lifetime).
The slice is empty for chunks that contain no method-call sites
(zero overhead for the common case).

CallSite cache survives across calls into the same chunk (the
chunk is shared by all invocations of the function). When
`rt.protocol_generation` advances (new `extend-type` lands), the
cache's `cached_generation` mismatch triggers a re-lookup —
identical semantics to the TreeWalk path in row 7.3.

### `lookupMethod` shape

Cycle 1's optional-`protocol_name` extension (Path A2) was a
prerequisite: the `.method` form does not name a protocol, so VM
dispatch passes `null` for the protocol_name. The op_method_call
arm calls `cs.lookupWithCache(td, null, method_name, generation)`.
Today `CallSite.lookupWithCache` takes `protocol_name: []const u8`
non-optional; cycle 4 widens it to `?[]const u8` to mirror
`TypeDescriptor.lookupMethod`.

## Consequences

### Positive

- F-002: finished form per the survey's Shape 1+1.b
  recommendation. Opcode count (4) matches AST-variant count (4)
  — each opcode names a single AST shape, simpler dispatch loop
  branching.
- ADR-0036 dual_backend_parity contract honoured for the 4 cluster
  sites. Diff_test cases land in `src/lang/diff_test.zig`
  exercising each opcode.
- CallSite cache integration from day 1 on the VM side; matches
  the row 7.3 TreeWalk path's monomorphic-per-site cache contract.
- Phase 17 JIT lowering surface: each opcode maps to one IR node
  cleanly; the side-table CallSite layout mirrors HotSpot's inline
  cache shape, making the eventual JIT inline-cache port a direct
  data structure migration rather than an opcode rewrite.

### Negative

- 4 opcodes vs the DA-recommended 2 (Alt 2 below). The DA's argument
  that "opcodes name evaluation strategies, not AST shapes" has
  merit. Trade-off acknowledged: descriptor-side field-accessor
  MethodEntry synthesis (Alt 2's prerequisite) requires extending
  MethodEntry with a synthetic-accessor variant — non-trivial
  shape change vs. the simple "one MethodEntry per declared
  method" finished form. F-003 supports deferring the unification
  to a future cycle when synthetic-accessor MethodEntries become
  load-bearing for another reason.
- `BytecodeChunk` grows a slice field (~16 bytes per chunk via
  `[]const CallSiteEntry` slice header; zero per chunk that
  doesn't use `.method`).

### Neutral

- F-003: defers PIC (polymorphic inline cache) shape to Phase 17.
- F-004: CallSite is heap-side (no NaN-box slot).
- F-006: side-table slice is analyzer-arena-owned, no GC root
  pressure (CallSite contents are pointers into descriptor table
  which is GPA-rooted via Env per row 7.3).

## Alternatives considered

(Devil's-advocate fork output reflected verbatim, 2026-05-26)

### Alt 1 — Smallest-diff: extend `op_call` + a `MethodHandle` builtin

Zero new opcodes. Analyzer lowers `(.m inst args)` into
`(rt/__dispatch-method <method_name> inst args...)` and emits
`op_invoke_builtin <arity>`. `deftype_node` lowers to
`(rt/__make-descriptor ...)` + `op_def`. `ctor_call_node` lowers
to `(rt/__construct <descriptor> args...)` + `op_invoke_builtin`.
CallSite caches live in the builtin's per-name interning table
(one CallSite per `(receiver-type, method-name)` pair,
runtime-global).

**Better than others**: smallest patch in `compiler.zig` (4 arms
become 4 `lowerToBuiltin` calls; no `opcode.zig` extension). VM
dispatch loop is untouched. Diff under ~200 LOC.

**Breaks**: (1) Loses **per-call-site monomorphism** — the
survey's central row-7.3 invariant. The runtime-global cache is
megamorphic by construction; F-002's "finished-form wins"
forbids regressing dispatch quality for diff size.
(2) Reintroduces the v0 `__java-method` shape the survey
explicitly DIVERGENCE-marked. (3) Phase 17 JIT cannot inline
through an `op_invoke_builtin` veneer without re-introducing the
opcode anyway → **net rewrite cost grows**.

**F-NNN impact**: F-002 violated (smallest-diff bias smell).
F-003 neutral. F-004/F-006 neutral.

### Alt 2 — DA-recommended: **2 opcodes** + Shape 1.b side-table

Add **2** opcodes (not 4): `op_dispatch_method` (covers
`method_call_node` AND `field_access_node` — field read = zero-arg
method call against the descriptor's field-accessor entry, a
synthetic MethodEntry that reads `field_layout[i]`); `op_construct`
covers `ctor_call_node`. `deftype_node` lowers via `op_const
<descriptor-value>` + `op_def` (no new opcode).

**Better than others**: (1) Opcode count = dispatch-shape count
(2), not site count (4) — matches the **finished-form rule that
opcodes name evaluation strategies, not AST shapes**.
(2) Field-access-as-zero-arg-method collapses the arity-2-vs-method-call
ambiguity (survey §4) into the descriptor. (3) Side-table
CallSite (Shape 1.b) is fixed-size opcodes, JIT-friendly, and
matches HotSpot's inline-cache layout — Phase 17 lowering is a
direct port.

**Breaks**: `BytecodeChunk` grows a slice field. `TypeDescriptor`
must synthesize zero-arg field-accessor MethodEntries at
`deftype` time — small extension to row 7.3 `method_table.zig`.
The arity-2 ambiguity (survey §4) must be resolved as
**Option B** (descriptor lookup wins), which is a behaviour
change from 5.12.a for the FieldAccessNode arm — but ADR-0036
already names row 7.6 as the discharge point so this is in-scope.

**F-NNN impact**: F-002 ✓ (finished-form wins over Alt 1's diff).
F-003 ✓ (defers PIC to Phase 17). F-004 neutral. F-006 ✓.

**Why NOT selected**: Synthesizing field-accessor MethodEntries
requires either (a) extending `MethodEntry` with a
synthetic-accessor variant (= shape-change to a row 7.3
load-bearing struct), or (b) per-field BuiltinFn allocation at
registerType time (= every defrecord allocates N BuiltinFn
closures). Both routes pay a structural cost that the cycle 4
scope did not budget for. Per F-003 the unification is a
finished-form goal but deferred; ADR-0040 lands the 4-opcode
shape today and a future cycle (when synthetic-accessor MethodEntries
become load-bearing for another reason) can collapse the two
opcodes via a clean shape migration. Recorded as the leading
runner-up alternative.

### Alt 3 — Wildcard: PIC inline cache (Shape 1.a) from day 1

4 dedicated opcodes (Shape 1), but each `op_method_call` carries
a **variable-sized inline cache** appended in-line after the
opcode: `[opcode u8][method_idx u16][cache_entry_count u8][CacheEntry...]`.
Cache entries are `(type_id u32, method_ptr u64)` pairs grown
in-place at dispatch time (up to 4 = polymorphic, then megamorphic
fallback). Bytecode stream becomes variable-width.

**Better than others**: Genuinely zero-indirection cache hit — no
side-table lookup, no chunk field access. Matches V8 / SpiderMonkey
inline-cache layout exactly. If Phase 17 JIT goes PIC-first, this
is the destination.

**Breaks**: Variable-width opcodes break `Instruction` struct
(currently `{ opcode, u16 operand }` fixed) —
`BytecodeChunk.instructions` becomes `[]u8` flat stream
prematurely (the opcode.zig docstring explicitly defers this to
Phase 17+). The dispatch loop's PC-advance becomes opcode-dependent.
ADR-0036 diff_test machinery would need to compare bytecode
streams positionally rather than by-instruction. Heavy migration
cost paid before the JIT exists to justify it.

**F-NNN impact**: F-002 ✗ (finished-form for Phase 7 is
monomorphic + side-table per row 7.3; PIC is Phase 17's call).
F-003 ✗ (decision-seizure — locks Phase 17's PIC shape before
its owner reviews). F-004 neutral. F-006 neutral.

### DA recommendation

Alt 2. The survey's lean (Shape 1+1.b) is right but under-justifies
relative to Alt 2's opcode-count collapse. Main loop overrode the
DA recommendation per the synthetic-accessor cost argument above
(F-003 deferral); Alt 2 stays as the leading runner-up for the
future synthesis cycle.

## Affected files

- `src/eval/backend/vm/opcode.zig` — add 4 opcodes (0x18..0x1B),
  add `CallSiteEntry` struct, extend `BytecodeChunk` with
  `call_sites` field.
- `src/eval/backend/vm/compiler.zig` — replace the 4 VM-DEFER
  arms with real compile arms emitting the new opcodes; build
  the `call_sites` side-table during compile.
- `src/eval/backend/vm.zig` — add 4 dispatch arms in the main
  bytecode loop.
- `src/runtime/dispatch/method_table.zig` —
  `CallSite.lookupWithCache` widens `protocol_name` to
  `?[]const u8` (mirrors row 7.6 cycle 1's `lookupMethod`
  widening).
- `src/lang/diff_test.zig` — add ≥1 diff_test case per opcode
  exercising the dispatch parity contract per ADR-0036.
- `feature_deps.yaml` — `runtime/vm/dispatch_family` entry's
  `status:` flips from `provisional` to `landed` for the
  4 cluster sites; the 2 remaining sites (`require_libspec`,
  `ns_filter`) keep their open markers.
- `.dev/debt.md` D-073 row — annotate the 4-site discharge.

## References

- `.dev/decisions/0036_dual_backend_parity_contract.md` — the
  contract this cycle 4 honours.
- `.dev/decisions/0008_protocol_dispatch.md` — protocol dispatch
  + CallSite cache semantics (row 7.3 amendments incl. amendment
  3 binding here).
- `.dev/project_facts.md` — F-002, F-003.
- `.dev/principle.md` — Reservation-as-bias smell (Alt 1's failure
  mode).
- `private/notes/phase7-7.6-survey.md` §3 + §5 + §6 cycle 4.
- ADR-0036 D5 — the cluster-discharge cycle this ADR realises.
