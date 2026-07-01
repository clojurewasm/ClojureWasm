# audit_scaffolding — check list

Each check has a category, a command (or grep recipe), and a severity
guideline. Run each in order and accumulate findings.

## A. Staleness — does the doc still describe reality?

### A1. ROADMAP §5 directory tree vs filesystem

```sh
# Compare paths listed in §5 with `find . -type f`
# Findings: paths in §5 that don't exist; paths on disk that aren't in §5
```

Severity: **block** if a load-bearing path is missing from disk, **soon**
if disk has a file that §5 doesn't anticipate.

### A2. ROADMAP §9 phase table vs `.dev/handover.md` "Current state"

```sh
grep -E '^\| [0-9]+ +\|.*\| (DONE|IN-PROGRESS|PENDING)' .dev/ROADMAP.md
grep -A 3 '## Current state' .dev/handover.md
```

Severity: **block** if they disagree.

### A3. `[x]` task SHAs in §9.X exist in git history

```sh
# Extract SHAs from §9.X expanded task table; verify each with `git rev-parse`
```

Severity: **block** if SHA is referenced but not reachable.

### A4. ja doc front-matter `commits:` SHAs all exist

```sh
for f in docs/ja/learn_clojurewasm/[0-9][0-9][0-9][0-9]_*.md; do
  python3 -c "import re,sys
fm = open('$f').read().split('---')[1]
for m in re.finditer(r'^\s*-\s+(\S+)', fm, re.M):
    print('$f', m.group(1))" \
  | while read file sha; do
      git rev-parse --verify "$sha" >/dev/null 2>&1 || echo "MISSING: $file → $sha"
    done
done
```

Severity: **block** for any MISSING.

### A5. handover.md "Last paired commit" matches `git log`

```sh
# Parse handover.md for the last paired commit SHA / subject; compare
# against the most recent docs(ja): commit found by `git log --grep`.
```

Severity: **block** on mismatch.

### A5b. handover.md framing compliance (per `.claude/rules/handover_framing.md`)

```sh
wc -l .dev/handover.md                       # ≤ 100 lines
grep -nE 'コンテキスト圧があるため|キリがいい|自然な区切り|natural break|good stopping point|この辺で一旦停止|Phase boundary reached AND|If above ~60%|context budget|/compact' .dev/handover.md
grep -c '^## Just landed' .dev/handover.md   # ≤ 1
grep -nE '^## Future .* shopping list|^## Notes for the next session' .dev/handover.md
```

Severity: **block** on length > 100, forbidden phrase hit, `Just
landed` count > 1, or any forbidden structural pattern.

### A6. ROADMAP / SKILL / CLAUDE references to files that exist

```sh
# Extract every backticked path / link target; verify each with `test -e`
grep -hoE '`[^`]+\.(md|zig|sh|yaml|json|nix)`' \
  .claude/CLAUDE.md README.md .dev/ROADMAP.md .claude/skills/*/SKILL.md \
  | sort -u | while read p; do
      f=$(echo "$p" | tr -d '`')
      test -e "$f" || echo "DEAD: $p"
    done
```

Severity: **block** for any DEAD.

## B. Bloat — has a file outgrown its purpose?

### B1. File line count vs soft limit

```sh
wc -l .claude/CLAUDE.md README.md .dev/ROADMAP.md .dev/README.md \
      .claude/skills/*/SKILL.md .claude/rules/*.md
```

Soft limits (rule of thumb):
- `.claude/CLAUDE.md`: ~100 lines (always loaded; bigger = context cost)
- `.dev/handover.md`: **hard 100-line limit** per
  [`handover_framing.md`](../../rules/handover_framing.md)
- `.claude/rules/*.md`: ~200 lines each
- `.claude/skills/*/SKILL.md`: ~150 lines each (split body into adjacent files)
- `.dev/ROADMAP.md`: ~1500 lines (reference doc, can be large)
- `docs/ja/learn_clojurewasm/NNNN_*.md`: 200–400 lines (story-sized)

Severity: **watch** at 80% of limit, **soon** above.

### B2. Duplicated authoritative claims

```sh
# Same fact in 3+ files = drift candidate. Examples to grep for:
grep -lF 'source-bearing' .claude/CLAUDE.md .dev/ROADMAP.md .claude/skills/*/SKILL.md
grep -lF 'commit pairing'  .claude/CLAUDE.md .dev/ROADMAP.md .claude/skills/*/SKILL.md
grep -lF 'Rule 1' .claude/skills/*/SKILL.md scripts/check_learning_doc.sh .claude/CLAUDE.md
```

Severity: **soon** if any rule/term lives canonically in 2+ places (not
counting a 1-line pointer in .claude/CLAUDE.md / ROADMAP back to the canonical
source). Designate ONE canonical and replace others with pointers.

## C. Lies — does the doc make absolute claims that reality contradicts?

### C1. "Active" gates in ROADMAP §11.6 actually wired

```sh
# For each row marked Active, verify the wiring:
# - Gate #1 (learning-doc) → is `bash scripts/check_learning_doc.sh` listed in .claude/settings.json hooks?
# - Gate #2 (zone_check)   → is `scripts/zone_check.sh --gate` invoked from test/run_all.sh?
# - Gate #3 (zig build test) → is it in test/run_all.sh?
```

Severity: **block** if Active claim is unwired.

### C2. .claude/CLAUDE.md "Read-only reference clones" actually exist

```sh
# Synced with .dev/reference_clones.md + .claude/settings.json
# additionalDirectories. If a path drifts, fix one of those two and
# refresh this list.
for path in \
  ~/Documents/OSS/clojure \
  ~/Documents/OSS/babashka \
  ~/Documents/OSS/zig \
  ~/Documents/OSS/spec.alpha \
  ~/Documents/OSS/wasmtime \
  ~/Documents/OSS/malli \
  ~/Documents/OSS/mattpocock_skills; do
    test -d "$path" || echo "MISSING REF: $path"
done
```

Severity: **soon** for missing.

### C3. README claims that build / test / run work

```sh
zig build && zig build test && timeout 5 zig build run >/dev/null
```

Severity: **block** on failure.

## D. False positives — do triggers fire when they shouldn't?

### D1. `.claude/rules/*.md` paths frontmatter matches existing files

```sh
for r in .claude/rules/*.md; do
  paths=$(awk '/^paths:/{p=1;next} p && /^---/{exit} p{print}' "$r" | sed 's/[ "-]*//g')
  # Verify at least one repo file matches each glob
done
```

Severity: **soon** if a rule's paths match nothing (rule never loads).

### D2. Gate script `is_source_path` matches as intended

```sh
# Spot-check: feed the gate via stdin with synthetic JSON for various staged sets:
# - .dev/decisions/README.md only         → should NOT trigger (meta)
# - .dev/decisions/0000_template.md only  → should NOT trigger (template)
# - .dev/decisions/0001_foo.md only       → SHOULD trigger
# - src/main.zig + docs/ja/learn_clojurewasm/9999_x.md      → SHOULD block (Rule 1)
```

Severity: **block** on any deviation from intended behaviour.

### D3. Skill descriptions trigger on intended phrases only

Manual inspection: read each skill's `description:` field. Does it
trigger on plausible adjacent topics that should NOT activate it? If a
skill description is too broad (e.g. "trigger when committing"), narrow
it; if too narrow (e.g. "trigger only when user says exactly X"),
broaden it.

Severity: **watch** unless a real misfire has been observed.

## E. Coverage — what isn't covered yet?

### E1. Phase tasks without expected files

```sh
# For Phase X §9.X, list tasks. For each [x] task, verify the named
# file exists. For each [ ] task, verify the named file does NOT yet
# exist (otherwise the task is implicitly already done).
```

Severity: **soon** on inconsistency.

### E2. Quality gates without owning skill / script

```sh
# Each row in §11.6 Active should name a script or skill that owns it.
# Planned rows should name the phase that will activate them.
```

Severity: **watch** for missing ownership.

## E2. Provisional marker health

PROVISIONAL marker comments (`.claude/rules/provisional_marker.md`)
are the in-code anchor for intermediate states. `audit_scaffolding`
tracks their count, age, and SSOT-sync.

### E2.1 Total marker count + per-file distribution

```sh
rg --no-heading -n 'PROVISIONAL:' src/ build.zig build.zig.zon test/e2e/ \
  | sed 's/:[0-9]*:.*//' \
  | sort | uniq -c | sort -rn
```

Severity: **watch** if count climbs > 10 net over a Phase boundary
without matching discharge commits; **soon** if any single file
carries > 3 markers (= concentrated rot).

### E2.2 Marker / data/feature_deps.yaml / debt.yaml cross-reference

Every marker's `[refs: D-NNN, feature_deps.yaml#<key>]` must point
at a real debt row + real yaml entry:

```sh
# Fail-loud (D-546): a missing SSOT must FAIL, never read empty (= false "no drift").
for f in .dev/debt.yaml data/feature_deps.yaml; do
  test -f "$f" || { echo "E2 FAIL: SSOT $f missing"; exit 1; }
done
# Markers in source
# Note: ripgrep's `-E` flag is encoding (NOT "extended regex" like grep);
# use plain `-o` and rely on default Rust regex syntax. The character class
# `[^]]+` is accepted by Rust regex without escaping the closing `]`.
rg --no-heading -o 'PROVISIONAL:.*\[refs: ([^]]+)\]' src/ \
  | sed -E 's/.*\[refs: ([^]]+)\].*/\1/' \
  | tr ',' '\n' | sed 's/^ *//' | sort -u > /tmp/marker_refs.txt

# Refs that exist in debt.yaml
grep -oE 'D-[0-9]+' .dev/debt.yaml | sort -u > /tmp/debt_refs.txt

# Refs that exist in data/feature_deps.yaml
grep -E '^  - name:' data/feature_deps.yaml \
  | sed -E 's/.*- name: *(.+)/feature_deps.yaml#\1/' \
  | sort -u > /tmp/yaml_refs.txt

# Cross-check
comm -23 \
  <(grep -E '^(D-[0-9]+|feature_deps\.yaml#)' /tmp/marker_refs.txt) \
  <(cat /tmp/debt_refs.txt /tmp/yaml_refs.txt | sort -u)
```

Findings: any line printed = a marker references a row / entry
that does not exist. Severity: **block** — broken SSOT pointer.

### E2.3 Stale provisional markers (>14 days)

```sh
for f in $(rg -l 'PROVISIONAL:' src/ build.zig build.zig.zon test/e2e/); do
  while IFS=: read -r file line content; do
    last_commit=$(git log -1 --format=%cs -L "${line},${line}:${file}" 2>/dev/null | head -1)
    [[ -z "$last_commit" ]] && continue
    age_days=$(( ( $(date +%s) - $(date -j -f %Y-%m-%d "$last_commit" +%s 2>/dev/null || date -d "$last_commit" +%s) ) / 86400 ))
    if [[ $age_days -gt 14 ]]; then
      echo "$file:$line  $age_days days  $content"
    fi
  done < <(rg --no-heading -n 'PROVISIONAL:' "$f")
done
```

Severity: **watch** for any line printed. A stale marker is not
itself a problem — many provisionals legitimately wait for upstream
features that will not land this phase. But each row should be
checked against its `.dev/debt.yaml` close-out predicate; flip from
"waiting" to "actionable" if the upstream landed.

### E2.4 data/feature_deps.yaml ↔ marker round-trip

For every `status: provisional` entry in `data/feature_deps.yaml`, the
`provisional_markers:` field should match `rg 'feature_deps.yaml#<name>' src/`:

```sh
test -f data/feature_deps.yaml || { echo "E2.4 FAIL: SSOT data/feature_deps.yaml missing"; exit 1; }  # D-546 fail-loud
# Note: the rg pattern below anchors with a trailing terminator class so a
# prefix match (e.g. `feature_deps.yaml#clojure.set/rename` substring-matching
# `feature_deps.yaml#clojure.set/rename-keys`) does NOT double-count
# (review finding F2). `\b` would also work but is more permissive on `?`/`!`
# suffixes that Clojure identifiers carry.
yq '.entries[] | select(.status == "provisional") | .name' data/feature_deps.yaml \
  | while read name; do
      decl=$(yq ".entries[] | select(.name == \"$name\") | .provisional_markers[]" data/feature_deps.yaml 2>/dev/null | wc -l)
      grep=$(rg --no-heading -c "feature_deps\.yaml#${name}([], \t]|\$)" src/ 2>/dev/null \
             | awk -F: '{s+=$2} END {print s+0}')
      if [[ $decl -ne $grep ]]; then
        echo "$name: yaml declares $decl marker(s), source has $grep"
      fi
    done
```

Severity: **block** if mismatch — the marker SSOT has drifted from
the source ground truth.

### E2.5 status-drift scan

For each `status: provisional` yaml entry, check whether all its
`requires_features:` are `landed` AND all its `requires_debts:` are
discharged. If yes, the entry is a candidate for `provisional →
landed` reclassification.

```sh
test -f data/feature_deps.yaml || { echo "E2.5 FAIL: SSOT data/feature_deps.yaml missing"; exit 1; }  # D-546 fail-loud
# For each provisional entry: walk its requires_features + requires_debts;
# if all features landed and all debts discharged, propose reclassify.
yq -r '.entries[] | select(.status == "provisional") | .name' data/feature_deps.yaml \
  | while read name; do
      pending_features=$(yq -r ".entries[] | select(.name == \"$name\") | .requires_features[]?" data/feature_deps.yaml \
        | while read req; do
            status=$(yq -r ".entries[] | select(.name == \"$req\") | .status" data/feature_deps.yaml)
            [[ "$status" != "landed" ]] && echo "$req:$status"
          done)
      pending_debts=$(yq -r ".entries[] | select(.name == \"$name\") | .requires_debts[]?" data/feature_deps.yaml \
        | while read drow; do
            # Discharged entries live under `discharged:` (or an `active:`
            # entry whose status starts DISCHARGED). Echo $drow only if NOT yet discharged.
            yq -r '.discharged[].id, (.active[] | select(.status | test("DISCHARGED|Discharged")) | .id)' .dev/debt.yaml \
              | grep -qx "$drow" || echo "$drow"
          done)
      if [[ -z "$pending_features" && -z "$pending_debts" ]]; then
        echo "  - $name: all requires satisfied → reclassify candidate"
      fi
    done
```

Severity: **soon** for each candidate (= eligible-for-reclassify
notice; do not block but surface in next audit report).

### E2.6 stale Phase reference scan (Stale-phase-ref smell)

Scan source / scripts / `.claude/rules` for `Phase \d+` references and
cross-check against ROADMAP §9 phase tracker.

```sh
# Extract Phase numbers cited in source-bearing + script files
rg --no-heading -no '\bPhase \d+(\.\d+)*(\+|\b)' src/ scripts/ .claude/rules/ \
  | sed -E 's/.*:Phase ([0-9.]+).*/\1/' | sort -u | head -20

# For each cited phase, check ROADMAP §9 status. A reference to a
# DONE phase + an "until / informational only / entry" qualifier in
# the same line is a strong stale-phase smell.
rg --no-heading -n 'Phase \d+ entry: informational|until Phase \d+|Phase \d+\+? target' \
  src/ scripts/ .claude/rules/ 2>/dev/null
```

Severity: **soon** when a referenced Phase has DONE-flipped in
ROADMAP §9. The cite ages into a lie — refresh wording or remove.

### E2.7 telltale-pattern provisional + comment-drift sweep

Find candidate **unmarked** provisional behaviour AND "drift from finished-form"
encoded in comments (ADR-0089: doc/debt sweeps only catch *written-down* debt;
code comments encode much more — `stub` / `single-threaded so fine` /
`eager-inline` that were never promoted to `debt.yaml`). The
`.claude/rules/framework_completion.md` discovery-criterion shape this implements.
For an EXHAUSTIVE pass over the (large) tree, fan out read-only subagents by
module subtree (each fresh-context) to classify *every* comment; the grep below
is the candidate-finder seed.

```sh
# Telltale patterns that hint at intermediate / not-finished-form state. Each
# hit needs classification: provisional / tier-staging / skeleton / stale-doc /
# false-positive. Widened 2026-06-04 (ADR-0089) with the comment-drift tokens
# (stub / single-threaded / eager-inline / skeleton) the doc/debt sweep misses.
# Note: alternation pipes are ripgrep / Rust-regex literal `|`, NOT `\|`.
rg --no-heading -in 'until Phase \d+|stands in for|for now|substitute|temporarily|placeholder|TBD|stub|single-threaded|eager-inline|skeleton|not yet (impl|support|wired)|will (land|swap)' \
  src/ test/e2e/ 2>/dev/null \
  | grep -v 'PROVISIONAL:' \
  | grep -v '^\s*//.*PROVISIONAL'
# Stale-API drift (Zig 0.16 removals referenced in comments/plans — the §7.1
# class of finding; cross-ref `.claude/rules/zig_tips.md`):
rg --no-heading -in 'std\.Thread\.(Pool|Mutex|Condition|Semaphore)|std\.io\.|binding_stack\.zig' \
  src/ 2>/dev/null | grep -v 'gone in\|removed in\|0\.16'

# Cross-check: any feature_not_supported raise that points at a future
# Phase but lacks a corresponding debt row?
rg --no-heading -n 'feature_not_supported' src/ 2>/dev/null \
  | awk -F: '{print $1}' | sort -u
```

Severity: **soon** for each hit — main agent classifies. Hits that
turn out to be real provisional become marker + yaml + debt rows in
the same cycle as the audit (per
`.claude/rules/framework_completion.md`).

### E2.8 watch_findings.md re-evaluation

For each row in `.dev/watch_findings.md` `## Active`, parse
`Revisit trigger` and Last reviewed. If `Last reviewed > 14 days
ago` OR if the trigger predicate is testably true, the row needs
re-evaluation this audit pass.

```sh
# Crude: list rows with Last reviewed in the row's last cell
# (YYYY-MM-DD format). Re-evaluation is currently human-judgement;
# script just surfaces the candidate set.
awk -F'|' '/^\| W-[0-9]+/ {date=$NF; gsub(/ /,"",date); print "  - "$2" ("date")"}' \
  .dev/watch_findings.md 2>/dev/null

# Manual re-evaluation: for each W-NNN, read the Revisit trigger and
# decide whether it has fired. If yes, escalate to active work
# (move to Discharged or open a new debt row); if no, refresh the
# Last reviewed date.
```

Severity: **watch** — no automated decision; just resurfaces the
deferred set so the loop doesn't forget about it.

## F. Agent scratch hygiene (`private/`)

`private/` is **gitignored agent scratch**, not a source of truth.
The audit only checks scratch volume and audit-report cadence — it
does **not** scan `private/` for "unadopted" proposals (anything
load-bearing must already live in ROADMAP / ADR / `docs/ja/` /
handover, per .claude/CLAUDE.md "Working agreement").

### F1. Per-task notes hygiene

```sh
ls private/notes/ 2>/dev/null | wc -l
```

Severity: **watch** if > 30 notes accumulated without being digested
into chapters. The right action is: write the chapters; the wrong
action is to delete the notes.

### F2. Scaffolding audit reports themselves rotting

```sh
ls private/audit-*.md 2>/dev/null | tail -5
```

If the most recent audit is older than 2 phase boundaries: **watch**
(audit cadence drift).

---

## Reporting format

Aggregate findings from all checks into the report described in
`SKILL.md` (block / soon / watch sections). Include the check ID
(A1, B2, F1, etc.) so the user can re-run individual checks for
verification.
