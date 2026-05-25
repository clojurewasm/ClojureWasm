---
paths:
  - "src/**/*.zig"
  - "src/**/*.clj"
  - "build.zig"
  - "build.zig.zon"
  - "test/e2e/**/*.sh"
  - "feature_deps.yaml"
  - ".dev/debt.md"
---

# Provisional marker comments

Auto-loaded when editing any source file. Codifies the
**mechanised visibility** layer for provisional behaviour —
intermediate states that exist because "the other side is not
yet ready" (language-implementation chicken-and-egg). Marker
comments are the in-code anchor of the lifecycle; the SSOT is
[`feature_deps.yaml`](../../feature_deps.yaml) + a
[`.dev/debt.md`](../../.dev/debt.md) row.

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
`feature_deps.yaml` and `.dev/debt.md`, the lifecycle is
mechanically auditable:

1. **Introduce** provisional behaviour ⇒ add marker + open
   `feature_deps.yaml` entry + open `.dev/debt.md` row (one
   commit; hook enforces sync).
2. **Stay aware** while it persists ⇒ `audit_scaffolding`
   reports marker count + 14-day-stale markers per Phase
   boundary; per-task notes include a `## 暫定ログ` section
   recording introduction / discharge / surprise this cycle.
3. **Discharge** when the upstream feature lands ⇒ remove
   marker + close `feature_deps.yaml` entry's
   `provisional_markers` list + close `.dev/debt.md` row
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
  `feature_deps.yaml` entry's body or the `.dev/debt.md` row.
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
- `.dev/debt.md` row moved from `## Active` to `## Discharged`
  (or a status update on the row).

The hook (`scripts/check_provisional_sync.sh`) verifies all
three edits ride the same commit.

## Distinguishing PROVISIONAL from FIXME / TODO / XXX

- **`PROVISIONAL:`** — intentional intermediate state with a
  named close-out plan in `feature_deps.yaml` + `.dev/debt.md`.
  Lifecycle is mechanised.
- **`TODO:`** — forbidden in this project (TODO smell per
  `.dev/principle.md`). Use `PROVISIONAL:` if there is a real
  close-out plan; otherwise the work belongs in the current
  commit.
- **`FIXME:` / `XXX:`** — not used; same rationale as `TODO:`.

If a piece of code legitimately needs to flag a bug or design
issue with no close-out plan yet, file a `.dev/debt.md` row
first, then mark with `PROVISIONAL:` referring to the new row.
A marker without `refs:` is rejected by the hook.

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
- [`.dev/debt.md`](../../.dev/debt.md) — the SSOT for the
  close-out plan (one row per provisional, named by `D-NNN`).
- [`scripts/check_provisional_sync.sh`](../../scripts/check_provisional_sync.sh)
  — the enforcement hook (PreToolUse on `git push`).
- [`bootstrap_essence.md`](bootstrap_essence.md) — why
  provisional behaviour is the default mode of language
  implementation, not the exception.
