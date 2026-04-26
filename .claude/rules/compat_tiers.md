---
paths:
  - "src/lang/**/*.zig"
  - "src/lang/**/*.clj"
  - ".dev/compat_tiers.yaml"
  - ".dev/decisions/*.md"
---

# Clojure compatibility tier rules

Auto-loaded when editing anything in `src/lang/` or `.dev/compat_tiers.yaml`.
Authoritative version of the tier policy in ROADMAP §6.

## The four tiers

| Tier | Meaning                                               | Test bar                                           |
|------|-------------------------------------------------------|----------------------------------------------------|
| **A** | Full semantic compat. Upstream tests pass as-is.      | Upstream-ported tests **must be green**.           |
| **B** | Same names/shapes; v2-native impl. Same observed behaviour. | Upstream-ported with `;; CLJW:` markers per per-test difference. |
| **C** | Best-effort with documented gaps.                     | Limited subset only; gaps listed in the doc.       |
| **D** | Not provided. Throws `UnsupportedException`.          | Just the throw-message test.                       |

Tier per namespace lives in `.dev/compat_tiers.yaml` (single source of truth).

## Forbidden: ad-hoc workarounds

Do **NOT** add a Tier-D-specific branch to existing `.clj` or `.zig` to
make a third-party library "kind of work". The two allowed paths are:

1. **Promote with an ADR**: write `.dev/decisions/NNNN-promote-<name>.md`
   placing the namespace at Tier A/B/C, with reason / tests / impact.
2. **Implement as a Wasm Component pod**: out-of-process, loaded via
   `(require '[lib :as l :pod "x.wasm"])`. No core code change required.

If you find yourself wanting to write `if cljw then ...` somewhere — STOP
and pick path 1 or 2.

## Tier movement rules

| Movement | When                                                          | Required artifact            |
|----------|---------------------------------------------------------------|------------------------------|
| → A      | Upstream test passes verbatim                                 | ADR + green ported test     |
| A → B    | A JVM-specific behaviour requires a `;; CLJW:` annotation     | ADR + annotated tests       |
| C → B    | Documented gap closed                                         | ADR + green tests            |
| D → C    | At least one caller (test) works with partial impl            | ADR + subset tests           |
| → D      | Removing prior support                                        | ADR (rare; usually one-way down is permanent) |

## Test-port naming convention

Every file under `test/upstream/` starts with:

```clojure
;; CLJW: Tier A from <upstream relative path>
```

Per-test deviation:

```clojure
(deftest behaves-this-way
  ;; CLJW: <reason this differs from JVM>
  (is (= ... ...)))
```

**NEVER work around a failing upstream test.** The choice is implement-the-feature
or write-a-tier-demotion-ADR. Commenting out / `:skip` alone is not
acceptable.

## Verification

`scripts/tier_check.sh` (added when `.dev/compat_tiers.yaml` is first
populated) verifies that:

- Every namespace listed in `compat_tiers.yaml` has a backing implementation
  (a Zig file under `src/lang/` or a `.clj` under `src/lang/clj/`).
- Every Tier-A namespace has at least one ported upstream test.
- Every Tier-D entry has its `UnsupportedException` shim test.
