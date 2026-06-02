---
paths:
  - "src/eval/node.zig"
  - "src/eval/backend/tree_walk.zig"
  - "src/eval/backend/vm.zig"
  - "src/eval/backend/vm/**.zig"
  - "src/lang/diff_test.zig"
---

# Dual-backend parity discipline

Auto-loaded when editing the analyzer Node union or either backend
(TreeWalk / VM). Codifies the contract from
[ADR-0036](../../.dev/decisions/0036_dual_backend_parity_contract.md):
every new analyzer Node variant lands TreeWalk arm + VM compile arm
+ VM dispatch arm + ≥1 differential test case in the same commit.
The PreToolUse hook
[`scripts/check_dual_backend_parity.sh`](../../scripts/check_dual_backend_parity.sh)
mechanises the body-discipline + marker-form layer of the contract;
the compiler's exhaustive `switch (Node)` in `vm/compiler.zig`
already enforces arm presence at build time.

## Why this rule exists

ADR-0005 declared dual-backend differential testing as cw v1's
correctness oracle. F-002 makes "the finished form wins" project
law. The compiler-enforced exhaustive switch in
`src/eval/backend/vm/compiler.zig` ensures that every Node variant
has *some* arm in the VM compiler — but a `return error.NotImplemented`
body silently passes the build, and a `_ = some_field;` line
silently drops a significant analyser field. The differential test
layer covers only the variants someone wrote a case for; new
variants without diff coverage never trip CI.

cw v0 carried the same drift class and ate weeks of late-cycle
catch-up time. cw v1's discipline machinery (PreToolUse hooks +
Devil's-advocate mandate) needed an explicit rule for "new
analyzer Node → both backends in same commit." This file is that
rule.

## The contract

A commit that adds a variant to the `Node` union in
`src/eval/node.zig` MUST also, in the same commit:

1. Add the TreeWalk eval arm in `src/eval/backend/tree_walk.zig`.
2. Add the VM compile arm in `src/eval/backend/vm/compiler.zig`.
3. Add the VM dispatch arm in `src/eval/backend/vm.zig` (when a
   new opcode is introduced).
4. Add at least one differential test case in
   `src/lang/diff_test.zig` exercising the new variant.

A commit that adds a new `op_*` to `src/eval/backend/vm/opcode.zig`
MUST also, in the same commit, add the matching dispatch arm in
`src/eval/backend/vm.zig` (the dispatch switch is exhaustive over
the `Opcode` enum, so the compiler enforces this — but the rule
records the expectation for code review).

A commit that adds or modifies a VM compile arm body MUST NOT
ship the body as a silent gap. Two shapes count as silent gaps:

- `return error.NotImplemented;` (or any error variant whose
  message does not surface to the user via the catalog).
- `_ = some_field;` (a discard that drops a field the TreeWalk
  arm honours).

Either shape requires a `VM-DEFER:` marker (see below). The hook
blocks pushes whose commits contain either shape without a
matching marker.

## VM-DEFER marker

When a VM compile arm cannot ship its real implementation in the
introducing cycle — typically because the bytecode shape depends
on a design choice owned by a future Phase row — the arm may
ship as a transient stub or a documented field-drop provided the
line directly above carries:

```zig
// VM-DEFER: <one-line why> [refs: D-NNN, feature_deps.yaml#<key>]
```

The marker mirrors `// PROVISIONAL:` shape from
[`provisional_marker.md`](provisional_marker.md):

- **Single line**. Multi-line rationale belongs in the
  `feature_deps.yaml` entry body or the `.dev/debt.yaml` row.
- **`[refs:` block mandatory**. At least one `D-NNN` (debt row)
  AND at least one `feature_deps.yaml#<key>` (entry name).
  Multiple refs comma-separated.
- **`<key>`** is the entry's `name:` field verbatim (e.g.
  `runtime/vm/dispatch_family`, `runtime/vm/ns_filter`).
- **Placed directly above** the affected statement; no blank line
  between marker and code.
- **Removed (not commented-out) on discharge.** The whole point
  of the marker is grep-discoverability; a commented-out marker
  cannot be discovered.

### Example — VM compile arm transient stub

```zig
// VM-DEFER: deftype VM bytecode shape pending row 7.6 MethodCallNode design [refs: D-073, feature_deps.yaml#runtime/vm/dispatch_family]
.deftype_node => return error.NotImplemented,
```

### Example — VM compile arm field-drop

```zig
fn compileNs(self: *Compiler, n: node_mod.NsNode) Error!void {
    // VM-DEFER: ns :refer-clojure filter pending NsNode filter extension [refs: D-073, feature_deps.yaml#runtime/vm/ns_filter]
    _ = n.refer_clojure;
    const name_val = try string_mod.alloc(self.rt, n.name);
    const idx = try self.addConstant(name_val);
    try self.emit(.op_in_ns, idx);
}
```

### Discharge

The discharging commit's diff shows:

- Marker line removed from the source arm.
- The arm body now lowers the construct for real (or, for a
  field-drop, now consumes the field).
- The matching `feature_deps.yaml` entry's `status:` flips from
  `provisional` to `landed`, and `provisional_markers:` list is
  emptied.
- The matching `.dev/debt.yaml` entry's barrier predicate flips to
  satisfied (or the entry moves to the `discharged:` list).
- ≥1 differential test case added covering the newly-landed VM
  arm (per contract point 4).

The hook (`scripts/check_dual_backend_parity.sh`) verifies the
marker form + body-discipline layer; the `feature_deps.yaml` +
`.dev/debt.yaml` discharge sync is verified by the existing
`scripts/check_provisional_sync.sh` (the shape is identical).

## VM-DEFER vs PROVISIONAL

| Concern              | PROVISIONAL                                                         | VM-DEFER                                                                                                          |
|----------------------|---------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------|
| Shape                | Intermediate semantics that ride a chicken-and-egg layer dependency | Backend asymmetry where TreeWalk has real semantics and VM is stubbed/field-dropped pending a future Phase choice |
| Close-out trigger    | Upstream layer feature lands                                        | Future Phase row decides the bytecode shape                                                                       |
| Source SSOT          | `feature_deps.yaml` entry's `provisional_markers:` list             | `feature_deps.yaml` entry's `provisional_markers:` list (same shape — re-used for parity tracking)               |
| Hook                 | `scripts/check_provisional_sync.sh`                                 | `scripts/check_dual_backend_parity.sh`                                                                            |
| Bad Smell preventing | Silent default-shift                                                | Dual-backend drift                                                                                                |

The two markers coexist; nothing prevents a single
`feature_deps.yaml` entry from carrying both a PROVISIONAL marker
(for the layer dependency aspect) and a VM-DEFER marker (for the
backend parity aspect). Today no entry does — but the shape is
deliberately compatible.

## Discovery criterion (per `framework_completion.md`)

The mechanical recipe the hook + Step 0.6 re-laying both use:

```sh
# All Node variants (LHS of the union(enum)):
grep -nE '^\s+[a-z_]+_node\s*:' src/eval/node.zig

# All TreeWalk arms:
grep -nE '\.[a-z_]+_node\s*=>' src/eval/backend/tree_walk.zig

# All VM compile arms (compileNode switch):
grep -nE '\.[a-z_]+_node\s*=>' src/eval/backend/vm/compiler.zig

# All VM-DEFER markers in vm/compiler.zig:
grep -nE '^\s*//\s*VM-DEFER:' src/eval/backend/vm/compiler.zig

# All silent-gap candidates in vm/compiler.zig:
grep -nE 'return error\.NotImplemented' src/eval/backend/vm/compiler.zig
grep -nE '^\s+_ = n\.' src/eval/backend/vm/compiler.zig
```

The first three lists should produce the same Node variant tag
set (LHS of `=>`). Any tag in TreeWalk but absent from VM
compiler is a parity gap.

The last two lists are silent-gap candidates; each line should
have a `// VM-DEFER:` marker on the line directly above it.

## Scope clarification

- The rule applies to commits that touch backend dispatch files
  (paths listed in this rule's frontmatter). A commit that does
  not touch any backend file is out of scope (the hook short-
  circuits on the file list).
- The rule does NOT require diff coverage for every existing
  Node variant retroactively — only for variants whose VM arm is
  fully working (not VM-DEFER) AND that are added or modified in
  the commit. T1's 11-case land is a one-time retrofit per the
  framework_completion §C discipline.
- TreeWalk-only paths (e.g. test-only helpers, REPL surface) are
  out of scope. The rule targets the analyzer-Node → backend
  contract specifically.

## Counter-examples

❌ Land a new `MethodCallNode` variant in `node.zig` + TreeWalk
arm + Phase 7 row 7.6 ADR; defer the VM arm "to next cycle"
without a VM-DEFER marker. The hook blocks the push.

❌ Add `return error.NotImplemented` to an existing VM compile
arm body without a `VM-DEFER:` marker line above. The hook
blocks the push.

❌ Add a `VM-DEFER:` marker without the `[refs:` block. The
hook blocks the push.

❌ Discharge a VM-DEFER marker without adding the diff coverage
case. The hook does not currently block this (it could be added
as a future enhancement); reviewer catches.

✅ Land MethodCallNode + TreeWalk arm + VM compile arm + new
opcode `op_method_call` + VM dispatch arm + diff case in one
commit. Hook passes.

✅ Land MethodCallNode + TreeWalk arm + VM compile arm shipped as
`// VM-DEFER: method dispatch ABI pending row 7.6.b design
[refs: D-073, feature_deps.yaml#runtime/vm/dispatch_family]` +
return error.NotImplemented + matching debt row + yaml entry.
Hook passes.

## Enforcement

`scripts/check_dual_backend_parity.sh` runs as a PreToolUse:Bash
hook on `git push` (registered in `.claude/settings.json`
alongside `check_provisional_sync.sh`, `check_smell_audit.sh`,
etc.). It walks each unpushed commit's range and checks:

1. **Body discipline**: any line in
   `src/eval/backend/vm/compiler.zig` matching
   `return error.NotImplemented` or `_ = n\.\w+;` must have a
   `// VM-DEFER:` marker on the line directly above.
2. **Marker form**: any newly-added `VM-DEFER:` marker line must
   contain a `[refs: …]` block with at least one `D-NNN`
   reference AND at least one `feature_deps.yaml#<key>` reference.

The hook supports the same `--test-range RANGE` and
`--test-staged` modes as `check_provisional_sync.sh`. It is
exercised in practice by the per-commit push gate (a malformed or
missing marker on a dual-backend change is rejected at push time);
a dedicated self-test script is not yet written (tracked W-010).

## Cross-references

- [ADR-0036](../../.dev/decisions/0036_dual_backend_parity_contract.md)
  — the parity contract this rule operationalises.
- [ADR-0005](../../.dev/decisions/0005_dual_backend_differential_oracle.md)
  — foundational dual-backend ADR.
- [ADR-0021](../../.dev/decisions/0021_test_taxonomy.md) — test
  taxonomy (Layer 3 differential lives in `src/lang/diff_test.zig`).
- [`provisional_marker.md`](provisional_marker.md) — sibling
  marker class whose shape VM-DEFER mirrors.
- [`framework_completion.md`](framework_completion.md) —
  discovery + sweep + retrofit-in-same-cycle discipline.
- [`.dev/principle.md`](../../.dev/principle.md) — Bad Smell
  catalogue ("Dual-backend drift" entry).
- [`.dev/debt.yaml`](../../.dev/debt.yaml) D-073 — VM backend parity
  cluster.
- [`scripts/check_dual_backend_parity.sh`](../../scripts/check_dual_backend_parity.sh)
  — the enforcement hook.
- [`scripts/check_provisional_sync.sh`](../../scripts/check_provisional_sync.sh)
  — the shape template the new hook adapts.
