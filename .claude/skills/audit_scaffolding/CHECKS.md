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

### A6. ROADMAP / SKILL / CLAUDE references to files that exist

```sh
# Extract every backticked path / link target; verify each with `test -e`
grep -hoE '`[^`]+\.(md|zig|sh|yaml|json|nix)`' \
  CLAUDE.md README.md .dev/ROADMAP.md .claude/skills/*/SKILL.md \
  | sort -u | while read p; do
      f=$(echo "$p" | tr -d '`')
      test -e "$f" || echo "DEAD: $p"
    done
```

Severity: **block** for any DEAD.

## B. Bloat — has a file outgrown its purpose?

### B1. File line count vs soft limit

```sh
wc -l CLAUDE.md README.md .dev/ROADMAP.md .dev/README.md \
      .claude/skills/*/SKILL.md .claude/rules/*.md
```

Soft limits (rule of thumb):
- `CLAUDE.md`: ~100 lines (always loaded; bigger = context cost)
- `.claude/rules/*.md`: ~200 lines each
- `.claude/skills/*/SKILL.md`: ~150 lines each (split body into adjacent files)
- `.dev/ROADMAP.md`: ~1500 lines (reference doc, can be large)
- `docs/ja/learn_clojurewasm/NNNN_*.md`: 200–400 lines (story-sized)

Severity: **watch** at 80% of limit, **soon** above.

### B2. Duplicated authoritative claims

```sh
# Same fact in 3+ files = drift candidate. Examples to grep for:
grep -lF 'source-bearing' CLAUDE.md .dev/ROADMAP.md .claude/skills/*/SKILL.md
grep -lF 'commit pairing'  CLAUDE.md .dev/ROADMAP.md .claude/skills/*/SKILL.md
grep -lF 'Rule 1' .claude/skills/*/SKILL.md scripts/check_learning_doc.sh CLAUDE.md
```

Severity: **soon** if any rule/term lives canonically in 2+ places (not
counting a 1-line pointer in CLAUDE.md / ROADMAP back to the canonical
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

### C2. CLAUDE.md "Read-only reference clones" actually exist

```sh
for path in \
  ~/Documents/MyProducts/ClojureWasm \
  ~/Documents/MyProducts/ClojureWasmFromScratch_v1_ref \
  ~/Documents/OSS/clojure ~/Documents/OSS/babashka ~/Documents/OSS/zig; do
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

## F. Agent scratch hygiene (`private/`)

`private/` is **gitignored agent scratch**, not a source of truth.
The audit only checks scratch volume and audit-report cadence — it
does **not** scan `private/` for "unadopted" proposals (anything
load-bearing must already live in ROADMAP / ADR / `docs/ja/` /
handover, per CLAUDE.md "Working agreement").

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
