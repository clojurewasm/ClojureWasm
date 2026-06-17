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
emits raw (unquoted) scalars; `-i` edits in place. Reading a shell env var
has TWO forms with a critical difference: **`strenv(NAME)` injects the value
as an opaque string; `env(NAME)` TYPE-PARSES the value as YAML first.** Use
`strenv()` for any string value — `env()` silently breaks on prose (see the
Golden rule below). This is the single most common yq footgun in this repo.

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

2. **Pass shell variables via `strenv(VAR)`, NEVER string-interpolation.**
   The fragile form `yq "... == \"$x\""` forces double-quoting the whole
   expression (so every `[`/`*`/`"` inside now needs escaping) and breaks
   on values containing quotes. The robust form keeps the expression
   single-quoted and injects the value out-of-band:

   ```sh
   # ✅ robust — expression stays single-quoted, value passed as strenv
   DROW="D-203" yq -r '.active[] | select(.id == strenv(DROW)) | .status' .dev/debt.yaml
   # ❌ fragile — nested quotes, breaks on metachars / quotes in $drow
   yq -r ".active[] | select(.id == \"$drow\") | .status" .dev/debt.yaml
   ```

   **`strenv()` not `env()` — this is the footgun that made yq "useless"
   for editing prose fields.** `env(VAR)` type-parses the value as YAML to
   infer its type, so a value containing two-or-more `: ` (colon-space)
   sequences — i.e. EVERY `status:` / `barrier:` / `resolution:` prose
   field in `debt.yaml` — fails YAML map parsing with
   `mapping values are not allowed in this context`, and the assignment is
   **silently dropped** (the field keeps its old value, exit non-zero).
   `strenv(VAR)` treats the value as an opaque string and is immune.
   Verified v4.53.2:

   ```sh
   # ❌ env() — dies on multi-colon prose, field UNCHANGED
   V='Part 1: foo. Part 2: bar.' yq -i '(.active[0].status) = env(V)' f.yaml
   #   → Error: yaml: line 1, column N: mapping values are not allowed …
   # ✅ strenv() — opaque string, assignment lands
   V='Part 1: foo. Part 2: bar.' yq -i '(.active[0].status) = strenv(V)' f.yaml
   ```

   Use `env(VAR)` ONLY when you deliberately want the value typed as a
   number / bool / null (rare). For ids, dates, categories, and all prose,
   `strenv(VAR)` is the default.

3. **`yq -i` (in-place) PRESERVES comments and `|-` block scalars**
   (verified v4.53.2 — header comments + every barrier block survived a
   field edit). So scalar-field updates are safe to automate:

   ```sh
   DROW="D-203" yq -i '(.active[] | select(.id == strenv(DROW)) | .last_reviewed) = "2026-06-02"' .dev/debt.yaml
   # Single-line prose field (status / one-line barrier): strenv() works —
   S='DISCHARGED 2026-06-09 — landed; Part 1: x. Part 2: y.' \
     DROW="D-356" yq -i '(.active[] | select(.id == strenv(DROW)) | .status) = strenv(S)' .dev/debt.yaml
   ```
   `strenv()` makes single-line prose assignment safe (the colon footgun is
   gone). BUT for a **new multi-line block scalar** (a fresh `barrier: |-`
   /`resolution: |-` block spanning several lines), still hand-edit with the
   Edit tool — `yq -i` emits a single-line double-quoted scalar (no `|-`
   block), so it round-trips correctly but reflows the prose onto one line
   and loses the block formatting. Use Edit when the block shape matters.

4. **Appending a NEW entry with `+=` writes its scalars UNQUOTED — which
   breaks any quote-anchored grep.** `yq -i '.active += [{"id":"D-439", …}]'`
   emits `- id: D-439` (plain scalar, NO quotes), even though every
   hand-written row is `- id: "D-439"`. The hazard is not the YAML (both
   parse) — it is that the **next-free-id recipe and the phantom-audit recipe
   grep `id: "D-` (with the quote)**, so they SILENTLY UNDERCOUNT the unquoted
   rows. A 2026-06-14 incident: three `+=`-appended rows (D-437/438/439) were
   unquoted, the next-id grep returned 436, and the next append would have
   re-used a live id (duplicate). Mitigations, in order of preference:
   - **Prefer the Edit tool to add a new debt/AD row** — hand-write the
     `- id: "D-NNN"` block so it matches the quoted convention (and a fresh
     `barrier: |-` block keeps its shape, per item 3). This is the default.
   - If you DO use `+=`, **force double-quote style on the id in the same
     call**: `yq -i '.active += [{"id":"D-439"}] | (.active[-1].id) style="double"'`
     (or normalize after: `sed -i '' -E 's/^( *- id: )(D-[0-9]+)$/\1"\2"/' f`).
   - The **next-id / phantom recipes below are now quote-TOLERANT** (`id: "?D-`)
     so they survive an unquoted row — but quoting on write is still required
     so the file stays consistent + greppable by other tools.

## debt.yaml cookbook (the recurring queries)

Structure: **three** top-level lists `active:` / `standing:` / `discharged:`
(NOT two — `standing:` holds epics/campaigns the loop does not auto-drain).
Active + standing entries: `id` / `status` / `category` / `barrier` (+ optional
`quality_floor` / `last_reviewed`). **Discharged is MIXED-schema** (verified
2026-06-17): ~199 rows reuse the active shape (`status` starting `DISCHARGED …`
+ `category`/`barrier`/`last_reviewed`), ~155 use the lighter `discharged_at` /
`resolution`. So a moved-from-active row keeps its `status` block (no reformat
needed); only hand-author `discharged_at`/`resolution` when writing a fresh
discharge. Query both shapes with `(.status // .resolution)`.

> **Precedence footgun (cost a re-derivation 2026-06-17).** `|` binds TIGHTER
> than `,`, so `.active[],.standing[] | select(…)` means `.active[]` (RAW) AND
> `(.standing[] | select(…))` — the select silently applies to only the LAST
> stream and every active row dumps unfiltered (looks like "select matched
> everything"). **Always parenthesize the union**: `(.active[],.standing[]) |
> select(…)`. Same for any `(.a[],.b[],.c[]) | …` across the three sections.

```sh
# counts
yq -r '.active | length' .dev/debt.yaml
yq -r '.discharged | length' .dev/debt.yaml

# all active ids
yq -r '.active[].id' .dev/debt.yaml

# one entry's field (escaping-free var)
DROW="D-203" yq -r '.active[] | select(.id == strenv(DROW)) | .barrier' .dev/debt.yaml

# find a row by id ACROSS all 3 sections (note the PARENS — see precedence footgun)
DROW="D-386" yq -r '(.active[],.standing[],.discharged[]) | select(.id == strenv(DROW)) | .id + " | " + (.status // .resolution)' .dev/debt.yaml

# active rows whose status is actually DISCHARGED (misfiled — belong in discharged:)
yq -r '.active[] | select(.status | test("^DISCHARGED|^Discharged")) | .id' .dev/debt.yaml

# filter by category / status substring
yq -r '.active[] | select(.category == "polymorphism") | .id' .dev/debt.yaml
yq -r '.active[] | select(.status | test("blocked-by")) | .id' .dev/debt.yaml

# quality-loop floor backlog (the F-010 drain list)
yq -r '.active[] | select(has("quality_floor")) | .id + " :: " + .quality_floor' .dev/debt.yaml

# is an id discharged? (in discharged: OR an active entry marked DISCHARGED)
DROW="D-018"; yq -r '.discharged[].id, (.active[] | select(.status | test("DISCHARGED|Discharged")) | .id)' .dev/debt.yaml | grep -qx "$DROW" && echo discharged || echo open

# highest existing id → next free is +1. PREFER the yq form — it reads the PARSED
# `.id` values, so it is immune to quote-style drift (an unquoted `+=`-appended row
# is counted; see Golden-rule #4):
yq -r '.active[].id, .standing[].id, .discharged[].id' .dev/debt.yaml | grep -oE '[0-9]+' | sort -n | tail -1
# grep fallback — MUST scope to the `id:` field (a bare `grep -oE 'D-[0-9]+'` also
# matches D-NNN in PROSE/cross-refs → a phantom too-high number) AND be
# quote-TOLERANT (`"?`) so an unquoted `+=` row is not undercounted:
grep -oE 'id: "?D-[0-9]+' .dev/debt.yaml | grep -oE '[0-9]+' | sort -n | tail -1
```

Note: `check_debt_id_refs.sh` does the phantom/undefined-id gate with
plain `rg` over the file (any `D-NNN` anywhere counts as "defined"), so
that check does NOT need yq — keep it grep-based. **Known blind spot**: a
typo'd reference that itself looks like a `D-NNN` (e.g. a stray `D-NNNN`)
appears in its own prose, so the "appears somewhere → defined" rule counts
it as defined and the gate does NOT flag it. The id-scoped next-id recipe
above is the robust cross-check (a phantom never has an `id:` row); to
audit for phantoms, diff the set of referenced ids against the set of
`id:`-defined ids:
`comm -23 <(grep -oE 'D-[0-9]+' .dev/debt.yaml | sort -u) <(yq -r '.active[].id, .standing[].id, .discharged[].id' .dev/debt.yaml | sort -u)`
prints any referenced-but-undefined id (empty = clean). (The defined-id side uses
`yq` so it is quote-style-agnostic per Golden-rule #4; a grep fallback must use
`id: "?D-`.)

## Auditing the SSOTs (run these when asked to audit, or after bulk yq edits)

```sh
# (1) Well-formedness — every SSOT must parse:
for f in .dev/debt.yaml .dev/accepted_divergences.yaml compat_tiers.yaml \
         placement.yaml feature_deps.yaml host_interfaces.yaml; do
  yq -e '.' "$f" >/dev/null 2>&1 && echo "OK   $f" || echo "FAIL $f"; done

# (2) Duplicate ids (a stray body-less `- id: "D-NNN"` from a botched edit parses
#     fine but duplicates a real entry — yq well-formedness does NOT catch it):
yq -r '.active[].id, .standing[].id, .discharged[].id' .dev/debt.yaml | sort | uniq -d   # empty = clean
yq -r '.[][].id' .dev/accepted_divergences.yaml 2>/dev/null | sort | uniq -d

# (3) Quote-style drift — unquoted ids from `+=` appends (Golden-rule #4):
grep -nE '^\s*-? *id: [^"'"'"' ]' .dev/debt.yaml   # empty = all quoted
```

The 2026-06-14 audit caught both classes: a stray `- id: "D-396"` (a body-less
duplicate of the real discharged row, from a prior botched edit — recipe 2) and
three unquoted `+=`-appended ids (recipe 3). yq `.' parses both, so these need the
dedicated dup/quote recipes, not just a well-formedness check.

## Other SSOTs (same idioms)

- `compat_tiers.yaml` / `placement.yaml`: same single-quote + `strenv()`
  rules. `placement.yaml` automation lives in
  `scripts/check_placement_status.sh`; `feature_deps.yaml` in
  `scripts/check_provisional_sync.sh` + `audit_scaffolding/CHECKS.md`.
- `bench/history` schema (ADR-0044) is queried in
  `scripts/check_bench_regression.sh` — mirror the `strenv()` idiom there for
  any var-parameterised query.

## Scope (forward-looking — like `orphan_prevention.md` / `zig_tips.md`)

This is a **reference** rule: it guides *future* yq usage, it does not gate
or mandate a one-shot retrofit. Existing scripts that still use the fragile
string-splice form work today because their interpolated values are
controlled (no metachars): `scripts/check_bench_regression.sh:55,85`
(`'"$MACHINE_ID"'` / `'"$LOCK_ID"'` splices) and
`scripts/check_placement_status.sh:63,68` (`\"$status\"`). Harden these to
`strenv()` **opportunistically** when next touching those files — not as a
standalone churn. (The two `env(ID)` reads in
`scripts/check_accepted_divergences.sh:50,56` compare against an `id` token
with no `: `, so `env()` does not break there — but `strenv()` is the safer
form to adopt next time that file is touched.)

## Related

- `~/.claude/CLAUDE.md` § シェル実行時のクォート規則 — the general zsh
  `NOMATCH` / single-quote rule this distils for yq.
- `.claude/rules/debt_dedup.md` — debt.yaml dedup discipline (links here).
- `.claude/skills/audit_scaffolding/CHECKS.md` — the yq-based discharged
  check (canonical worked example).
