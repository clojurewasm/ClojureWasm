---
paths:
  - "src/**/*.zig"
  - "src/**/*.clj"
  - "build.zig"
  - "build.zig.zon"
  - "test/e2e/**/*.sh"
  - "feature_deps.yaml"
  - ".dev/debt.yaml"
---

# Provisional marker comments

Auto-loaded when editing any source file. Codifies the
**mechanised visibility** layer for provisional behaviour —
intermediate states that exist because "the other side is not
yet ready" (language-implementation chicken-and-egg). Marker
comments are the in-code anchor of the lifecycle; the SSOT is
[`feature_deps.yaml`](../../feature_deps.yaml) + a
[`.dev/debt.yaml`](../../.dev/debt.yaml) row.

## Why this rule exists

Language implementations grow in layers (Layer 0 = host code,
Layer 1 = primitives, Layer 2 = `.clj` defns over primitives,
Layer 3 = full `(ns ...)` macro). Until a layer is complete,
upper layers ride **provisional behaviour** in lower layers —
e.g. `evalInNs` auto-refers `rt/` and `clojure.core` because
the proper `(ns ...)` macro has not landed.

Provisional behaviour is unavoidable. Forgetting that it is
provisional is not. Silent default-shift smell
(`.dev/principle.md`) emerges when a provisional default
calcifies into 「とりあえず動く」 forever because nothing in
the code points at "this is temporary; here is the close-out".

The marker comment is the in-code anchor. Combined with
`feature_deps.yaml` and `.dev/debt.yaml`, the lifecycle is
mechanically auditable:

1. **Introduce** provisional behaviour ⇒ add marker + open
   `feature_deps.yaml` entry + open `.dev/debt.yaml` row (one
   commit; hook enforces sync).
2. **Stay aware** while it persists ⇒ `audit_scaffolding`
   reports marker count + 14-day-stale markers per Phase
   boundary; per-task notes include a `## 暫定ログ` section
   recording introduction / discharge / surprise this cycle.
3. **Discharge** when the upstream feature lands ⇒ remove
   marker + close `feature_deps.yaml` entry's
   `provisional_markers` list + close `.dev/debt.yaml` row
   (same commit; hook enforces sync).

## Canonical form

```zig
// PROVISIONAL: <one-line why> [refs: D-NNN, feature_deps.yaml#<key>]
```

```clojure
;; PROVISIONAL: <one-line why> [refs: D-NNN, feature_deps.yaml#<key>]
```

Rules:

- **Single line**. Multi-line rationale belongs in the
  `feature_deps.yaml` entry's body or the `.dev/debt.yaml` row.
- **`refs:` block is mandatory** and lists at least one
  `D-NNN` (debt row) AND at least one
  `feature_deps.yaml#<key>` (entry name). Multiple refs
  comma-separated.
- **`<key>`** is the entry's `name:` field verbatim
  (e.g. `clojure.core/select-keys`,
  `runtime/eval/in_ns_auto_refer`).
- **Placed directly above** the provisional code, no blank
  line between marker and the affected statement.
- **Removed on discharge**, not commented-out. The whole
  point of the marker is grep-discoverability.

## Examples

### Introduce (Zig)

The marker is one source line. Editors may wrap visually; do
not split with `//` continuations.

```zig
// PROVISIONAL: in-ns auto-refers rt/ pending (ns ...) macro [refs: D-071, feature_deps.yaml#runtime/eval/in_ns_auto_refer]
if (env.findNs("rt")) |rt_ns| {
    try env.referAll(rt_ns, env.current_ns.?);
}
```

### Introduce (Clojure)

`clojure.set/join` ships 2-arity only; the 3-arity
`[xrel yrel km]` body requires multi-arity `fn*` dispatch
(D-070) and will land when D-070 closes.

```clojure
;; PROVISIONAL: 2-arity only pending multi-arity fn* dispatch [refs: D-070, feature_deps.yaml#clojure.set/join]
(def join
  (fn* [xrel yrel]
    ...body...))
```

**Counter-example — what is NOT provisional.** Variadic with
internal arity discrimination (e.g. `(fn* [& args] (if (= 0
(count args)) ... ...))`) is the **finished form** for
"fold over N args" — no different-body-per-arity dispatch is
needed, so D-070 is not blocking it. Such a body would be a
false-positive marker and should NOT be tagged PROVISIONAL.
See `feature_deps.yaml#clojure.core/merge` notes for the
re-classification precedent (spike 2.3, 2026-05-26).

### Discharge (one commit removes marker + closes refs)

The discharging commit's diff shows:
- Marker line removed from source.
- `feature_deps.yaml` entry's `provisional_markers:` list
  emptied (or the whole entry's `status:` flipped from
  `provisional` to `landed`).
- `.dev/debt.yaml` entry moved from the `active:` list to the
  `discharged:` list (or a status update on the entry).

The hook (`scripts/check_provisional_sync.sh`) verifies all
three edits ride the same commit.

## Distinguishing PROVISIONAL from FIXME / TODO / XXX

- **`PROVISIONAL:`** — intentional intermediate state with a
  named close-out plan in `feature_deps.yaml` + `.dev/debt.yaml`.
  Lifecycle is mechanised.
- **`TODO:`** — forbidden in this project (TODO smell per
  `.dev/principle.md`). Use `PROVISIONAL:` if there is a real
  close-out plan; otherwise the work belongs in the current
  commit.
- **`FIXME:` / `XXX:`** — not used; same rationale as `TODO:`.

If a piece of code legitimately needs to flag a bug or design
issue with no close-out plan yet, file a `.dev/debt.yaml` row
first, then mark with `PROVISIONAL:` referring to the new row.
A marker without `refs:` is rejected by the hook.

## Skeleton vs transient stub vs PROVISIONAL vs permanent no-op

(Wave 16 W16-6 fold of `no_op_stub_forbidden.md` — the time-axis
distinction between "final shape" and "development trajectory" is
the central invariant; preserve verbatim.)

The cw v1 codebase commits to:

> **No Tier A / B / C feature may ship in a form where the user
> sees success while the runtime silently drops the intended
> semantics.**

The verb is "ship": the rule is about what lands in the **final
shape** of the feature, not about the development trajectory.

| Shape                                                                                   | Rule   | Why                                                                     |
|-----------------------------------------------------------------------------------------|--------|-------------------------------------------------------------------------|
| Skeleton struct that Phase N+ rewrites into a real impl                                 | **OK** | Reservation lowers later surface ripple. ADR-0004 day-1 enum.           |
| Function body that raises `feature_not_supported`                                       | **OK** | Explicit user signal. Transient — disappears when the real impl lands. |
| Function body that **runs** with intermediate semantics + carries `PROVISIONAL:` marker | **OK** | Marker + yaml entry + debt row triad makes the lifecycle auditable.     |
| Function body that returns the input unchanged                                          | **NG** | Pretends to work, drops semantics silently. The user builds on a lie.   |
| Macro that expands to `nil` or to its body without effect                               | **NG** | Same shape — user code compiles and runs, semantics are gone.          |

The third row is where the **`PROVISIONAL:` marker** earns its
keep: the function DOES run with intermediate semantics (= not a
`feature_not_supported` raise), and the marker + SSOT triad
record that the intermediate behaviour is intentional + has a
close-out predicate. Without the marker, the third row collapses
into the fourth (= permanent no-op).

### Boundary rules

A **skeleton** is permitted when any of:
- Only the struct type definition exists (no function declared yet).
- A function is declared but its body is exactly
  `return error_catalog.raise(.unsupported_feature, loc, .{ .name = "<form>" });`
  (per ADR-0018), or for internal-only paths
  `return error.NotImplemented;` / `@panic("...")` with a developer-
  visible comment naming the future task.

A **transient stub** is permitted when the function ships an
explicit error rather than fake-running.

A **PROVISIONAL behaviour** is permitted when the function runs
with intermediate semantics AND carries the `PROVISIONAL:` marker
+ yaml entry + debt row triad (this is the new third row).

A **permanent no-op** is **forbidden** when:
- A function is declared and executes the argument without the
  intended semantics (e.g., `dosync` body executed without snapshot
  isolation).
- A function returns a default value that masks the missing feature.
- A macro expands to `nil` or to its body without effect.

The boundary is **what the user observes** + **whether the
intermediate state is mechanically tracked**.

### Examples

Forbidden:
```zig
pub fn dosync(rt: *Runtime, body: Value) !Value {
    return eval(rt, body);   // ❌ no snapshot isolation; ships as STM that isn't STM
}
```

Allowed (transient stub):
```zig
pub fn dosync(rt: *Runtime, loc: SourceLocation, body: Value) !Value {
    _ = rt;
    _ = body;
    return error_catalog.raise(.unsupported_feature, loc, .{ .name = "dosync" });
}
```

Allowed (PROVISIONAL — runs intermediate semantics with the triad):
```zig
// PROVISIONAL: in-ns auto-refers rt/ pending (ns ...) macro [refs: D-071, feature_deps.yaml#runtime/eval/in_ns_auto_refer]
if (env.findNs("rt")) |rt_ns| {
    try env.referAll(rt_ns, env.current_ns.?);
}
```

### Why (Shota's original directive, preserved)

- A stub that "works" misleads users into building code that breaks
  later.
- STM (`dosync` without snapshot isolation) and locking (`locking`
  without lock) are common offenders in JVM-non-equivalent runtimes.
- cw v1 commits to either a real implementation, an explicit error,
  or a PROVISIONAL-tracked intermediate.
- Skeleton-then-rewrite **is** how the codebase grows; the only
  thing forbidden is shipping a lie.

### Enforcement

- `scripts/check_no_op_stub.sh` — heuristic scan (currently
  informational; W16-2 refreshed the activation criterion).
- `scripts/check_provisional_sync.sh` — PROVISIONAL marker + SSOT
  triad sync (hard gate at push time).
- ADR-0004 / ADR-0012 / ADR-0023 endorse skeleton-then-rewrite for
  day-1 reservations.

## Marker scope

The rule applies to source files in the directories where
provisional behaviour is meaningful:

- `src/**` (every Zig + `.clj` source)
- `build.zig`, `build.zig.zon`
- `test/e2e/**.sh` (test-side workarounds also qualify)

Configuration files, documentation, and generated artefacts
(`.zig-cache/`, `zig-out/`) are out of scope.

## Cross-references

- [`.dev/principle.md`](../../.dev/principle.md) — the Bad
  Smell catalogue this rule operationalises (Silent
  default-shift, Smallest-diff bias, Reservation-as-bias,
  Progress-pressure).
- [`feature_deps.yaml`](../../feature_deps.yaml) — the SSOT
  for provisional entries (`status: provisional` + the
  `provisional_markers` list).
- [`.dev/debt.yaml`](../../.dev/debt.yaml) — the SSOT for the
  close-out plan (one row per provisional, named by `D-NNN`).
- [`scripts/check_provisional_sync.sh`](../../scripts/check_provisional_sync.sh)
  — the enforcement hook (PreToolUse on `git push`).
- [`bootstrap_essence.md`](bootstrap_essence.md) — why
  provisional behaviour is the default mode of language
  implementation, not the exception.
