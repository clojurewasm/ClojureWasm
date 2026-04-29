#!/usr/bin/env bash
# scripts/check_learning_doc.sh
#
# Pre-commit gate that enforces the source-commit → doc-commit pairing.
# A single doc may cover any number of source commits since the previous
# doc, listed via `commits:` (YAML list) in the doc's front matter.
#
# Workflow:
#   1. Source commits (one or many):
#        git add src/...  &&  git commit -m "feat(...): ..."
#        git add src/...  &&  git commit -m "refactor(...): ..."
#        ...
#   2. Doc commit (covers all unpaired source commits since the last doc):
#        write docs/ja/learn_clojurewasm/NNNN_<slug>.md with front matter
#          commits:
#            - <SHA1>   (oldest unpaired source)
#            - <SHA2>
#            - ...
#        git add docs/ja/...  &&  git commit -m "docs(ja): NNNN — ..."
#
# Wired as a Claude Code PreToolUse hook on Bash (settings.json). Safe
# no-op for any non-`git commit` Bash invocation.
#
# Rules:
#   1. A commit that stages a docs/ja/learn_clojurewasm/NNNN_*.md MUST NOT also stage
#      source-bearing files (mixing defeats SHA pairing).
#   2. A doc commit's `commits:` field MUST cover every source-bearing
#      commit since the previous doc commit. Extra SHAs are allowed
#      (voluntary documentation of non-source commits).
#
# See .claude/skills/code_learning_doc/SKILL.md for the full skill.

set -euo pipefail

# --- 1. Read the Claude Code hook payload from stdin -------------------------
INPUT="$(cat)"

COMMAND="$(printf '%s' "$INPUT" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    sys.exit(0)
print((data.get("tool_input") or {}).get("command", "") or "")
' 2>/dev/null || echo "")"

# --- 2. Only enforce on `git commit` -----------------------------------------
if ! printf '%s' "$COMMAND" | grep -qE '(^|[ ;&|])git[[:space:]]+commit([[:space:]]|$)'; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

# --- 3. Helpers --------------------------------------------------------------
is_source_path() {
  case "$1" in
    src/*.zig|build.zig|build.zig.zon)        return 0 ;;
    .dev/decisions/0000_*.md)                  return 1 ;;
    .dev/decisions/[0-9][0-9][0-9][0-9]_*.md) return 0 ;;
    *)                                         return 1 ;;
  esac
}

is_doc_path() {
  [[ "$1" =~ ^docs/ja/learn_clojurewasm/[0-9]{4}_.+\.md$ ]]
}

# --- 4. Classify this commit -------------------------------------------------
# "Source-bearing" counts any add / modify / rename to a source path.
# "Doc commit" requires ADDING a new docs/ja/learn_clojurewasm/NNNN_*.md (modifications to
# existing docs are treated as plain edits and do not trigger Rule 2).
STAGED="$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)"
[[ -z "$STAGED" ]] && exit 0

ADDED="$(git diff --cached --name-only --diff-filter=A 2>/dev/null || true)"

this_has_source=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if is_source_path "$f"; then this_has_source=1; break; fi
done <<< "$STAGED"

this_has_doc=0
new_doc_path=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if is_doc_path "$f"; then this_has_doc=1; new_doc_path="$f"; break; fi
done <<< "$ADDED"

# --- 5. Rule 1: doc + source mixing is forbidden ---------------------------
if [ $this_has_doc -eq 1 ] && [ $this_has_source -eq 1 ]; then
  cat >&2 <<'EOF'
✗ commit blocked by scripts/check_learning_doc.sh (Rule 1)

A learning-doc commit must NOT also contain source-bearing files
(src/*.zig, build.zig, build.zig.zon, .dev/decisions/NNNN_*.md).
Split into two commits:

    git commit -m "feat(...): ..."   # source only (any number)
    git commit -m "docs(ja): ..."    # the learning doc only
EOF
  exit 2
fi

# Non-doc commits are unconditionally allowed: source can accumulate
# unpaired indefinitely; the doc commit will reconcile when it arrives.
if [ $this_has_doc -eq 0 ]; then
  exit 0
fi

# --- 6. Rule 2: doc must cover all unpaired source commits -----------------

# Walk back from HEAD collecting unpaired source-bearing SHAs (oldest first).
# Stop at the first commit that itself added a learning doc; everything at
# or before it is paired.
expected="$(python3 - "$new_doc_path" <<'PY'
import re, subprocess, sys

def commit_files(sha):
    out = subprocess.run(
        ["git", "show", "--name-only", "--format=", sha],
        capture_output=True, text=True, check=False,
    )
    return [f for f in out.stdout.splitlines() if f]

def is_source(f):
    if re.match(r"^src/.+\.zig$", f):       return True
    if f in ("build.zig", "build.zig.zon"): return True
    if re.match(r"^\.dev/decisions/0000_.+\.md$", f): return False
    if re.match(r"^\.dev/decisions/[0-9]{4}_.+\.md$", f): return True
    return False

def added_doc(sha):
    out = subprocess.run(
        ["git", "show", "--name-only", "--format=", "--diff-filter=A", sha],
        capture_output=True, text=True, check=False,
    )
    for f in out.stdout.splitlines():
        if re.match(r"^docs/ja/learn_clojurewasm/[0-9]{4}_.+\.md$", f):
            return True
    return False

shas = subprocess.run(
    ["git", "log", "--format=%H", "HEAD"],
    capture_output=True, text=True, check=False,
).stdout.splitlines()

unpaired = []
for sha in shas:
    if added_doc(sha):
        break
    files = commit_files(sha)
    if any(is_source(f) for f in files):
        unpaired.append(sha[:7])

print("\n".join(reversed(unpaired)))
PY
)"

# Parse `commits:` from the new doc's front matter (block or inline form).
covered="$(python3 - "$new_doc_path" <<'PY'
import re, sys

path = sys.argv[1]
with open(path) as f:
    text = f.read()

m = re.match(r"^---\n(.*?)\n---", text, re.DOTALL)
fm = m.group(1) if m else ""

commits = []
inline = re.search(r"^commits:\s*\[(.*)\]\s*$", fm, re.MULTILINE)
if inline:
    commits = [x.strip().strip("\"'") for x in inline.group(1).split(",") if x.strip()]
else:
    in_block = False
    for line in fm.splitlines():
        if re.match(r"^commits:\s*$", line):
            in_block = True
            continue
        if in_block:
            m2 = re.match(r"^\s*-\s*(\S+)", line)
            if m2:
                commits.append(m2.group(1).strip("\"'"))
            elif line.strip() and not line.startswith(" "):
                break

print("\n".join(c[:7] for c in commits))
PY
)"

# Verify: every expected SHA appears in covered
missing=""
while IFS= read -r sha; do
  [[ -z "$sha" ]] && continue
  if ! grep -qx "$sha" <<< "$covered"; then
    missing="${missing}${sha} "
  fi
done <<< "$expected"

if [[ -n "$missing" ]]; then
  cat >&2 <<EOF
✗ commit blocked by scripts/check_learning_doc.sh (Rule 2)

The learning doc ${new_doc_path} does not cover every unpaired source commit.

Missing from \`commits:\`: ${missing}

Expected (oldest → newest):
$(echo "$expected" | sed 's/^/  - /')

Listed in doc front matter:
$(echo "$covered" | sed 's/^/  - /')

Edit the doc's \`commits:\` block to include all of the above and re-stage.
EOF
  exit 2
fi

exit 0
