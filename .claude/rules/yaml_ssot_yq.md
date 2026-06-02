---
paths:
  - .dev/debt.yaml
  - compat_tiers.yaml
  - placement.yaml
  - feature_deps.yaml
---

# Querying the YAML SSOTs with `yq` (shell-escaping + cookbook)

Auto-loaded when editing a structured YAML SSOT (`.dev/debt.yaml`,
`compat_tiers.yaml`, `placement.yaml`, `feature_deps.yaml`). Codifies the
`yq` query + shell-escaping idioms so no session re-derives them. The SSOT
for the *content* of each file is the file; this rule is the SSOT for *how
to read/edit it from a shell*.

## Flavor

**mikefarah Go `yq` v4** (NOT the python `yq`/`jq` wrapper). Confirmed
v4.53.2. Key consequences: expression syntax is jq-like but its own; `-r`
emits raw (unquoted) scalars; `env(NAME)` reads a shell env var; `-i`
edits in place.

## Golden rule for shell-escaping (this is the whole trick)

1. **Single-quote the entire yq expression.** yq expressions are full of
   `|`, `()`, `[]`, `.`, `==`, `"`, and zsh-`NOMATCH` glob metachars
   (`[`, `?`, `*`). Single quotes neutralise all of it — the only safe
   default (mirrors `~/.claude/CLAUDE.md` § シェル実行時のクォート規則).

   ```sh
   yq -r '.active[] | select(.category == "polymorphism") | .id' .dev/debt.yaml
   ```
   Literal double-quotes for string *values* sit fine inside the single
   quotes — no escaping.

2. **Pass shell variables via `env(VAR)`, NEVER string-interpolation.**
   The fragile form `yq "... == \"$x\""` forces double-quoting the whole
   expression (so every `[`/`*`/`"` inside now needs escaping) and breaks
   on values containing quotes. The robust form keeps the expression
   single-quoted and injects the value out-of-band:

   ```sh
   # ✅ robust — expression stays single-quoted, value passed as env
   DROW="D-203" yq -r '.active[] | select(.id == env(DROW)) | .status' .dev/debt.yaml
   # ❌ fragile — nested quotes, breaks on metachars / quotes in $drow
   yq -r ".active[] | select(.id == \"$drow\") | .status" .dev/debt.yaml
   ```

3. **`yq -i` (in-place) PRESERVES comments and `|-` block scalars**
   (verified v4.53.2 — header comments + every barrier block survived a
   field edit). So scalar-field updates are safe to automate:

   ```sh
   DROW="D-203" yq -i '(.active[] | select(.id == env(DROW)) | .last_reviewed) = "2026-06-02"' .dev/debt.yaml
   ```
   BUT for **new multi-line prose** (a fresh `barrier:`/`resolution:`
   block), hand-edit with the Edit tool — authoring a block scalar through
   `yq -i` string assignment is awkward and easy to mis-indent.

## debt.yaml cookbook (the recurring queries)

Structure: two top-level lists `active:` / `discharged:`. Active entries:
`id` / `status` / `category` / `barrier` (+ optional `quality_floor` /
`last_reviewed`). Discharged: `id` / `discharged_at` / `resolution`.

```sh
# counts
yq -r '.active | length' .dev/debt.yaml
yq -r '.discharged | length' .dev/debt.yaml

# all active ids
yq -r '.active[].id' .dev/debt.yaml

# one entry's field (escaping-free var)
DROW="D-203" yq -r '.active[] | select(.id == env(DROW)) | .barrier' .dev/debt.yaml

# filter by category / status substring
yq -r '.active[] | select(.category == "polymorphism") | .id' .dev/debt.yaml
yq -r '.active[] | select(.status | test("blocked-by")) | .id' .dev/debt.yaml

# quality-loop floor backlog (the F-010 drain list)
yq -r '.active[] | select(has("quality_floor")) | .id + " :: " + .quality_floor' .dev/debt.yaml

# is an id discharged? (in discharged: OR an active entry marked DISCHARGED)
DROW="D-018"; yq -r '.discharged[].id, (.active[] | select(.status | test("DISCHARGED|Discharged")) | .id)' .dev/debt.yaml | grep -qx "$DROW" && echo discharged || echo open

# next free numeric id (ignores D-014a-style suffixes)
grep -oE 'D-[0-9]+' .dev/debt.yaml | sort -t- -k2 -n | tail -1
```

Note: `check_debt_id_refs.sh` does the phantom/undefined-id gate with
plain `rg` over the file (any `D-NNN` anywhere counts as "defined"), so
that check does NOT need yq — keep it grep-based.

## Other SSOTs (same idioms)

- `compat_tiers.yaml` / `placement.yaml`: same single-quote + `env()`
  rules. `placement.yaml` automation lives in
  `scripts/check_placement_status.sh`; `feature_deps.yaml` in
  `scripts/check_provisional_sync.sh` + `audit_scaffolding/CHECKS.md`.
- `bench/history` schema (ADR-0044) is queried in
  `scripts/check_bench_regression.sh` — mirror the `env()` idiom there for
  any var-parameterised query.

## Scope (forward-looking — like `orphan_prevention.md` / `zig_tips.md`)

This is a **reference** rule: it guides *future* yq usage, it does not gate
or mandate a one-shot retrofit. Existing scripts that still use the fragile
string-splice form work today because their interpolated values are
controlled (no metachars): `scripts/check_bench_regression.sh:55,85`
(`'"$MACHINE_ID"'` / `'"$LOCK_ID"'` splices) and
`scripts/check_placement_status.sh:63,68` (`\"$status\"`). Harden these to
`env()` **opportunistically** when next touching those files — not as a
standalone churn.

## Related

- `~/.claude/CLAUDE.md` § シェル実行時のクォート規則 — the general zsh
  `NOMATCH` / single-quote rule this distils for yq.
- `.claude/rules/debt_dedup.md` — debt.yaml dedup discipline (links here).
- `.claude/skills/audit_scaffolding/CHECKS.md` — the yq-based discharged
  check (canonical worked example).
