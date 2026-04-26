#!/usr/bin/env bash
# scripts/check_learning_doc.sh
#
# Pre-commit gate that enforces the source-commit → doc-commit pairing.
#
# Workflow:
#   1. Source commit:  git add src/...  &&  git commit -m "feat(...): ..."
#   2. Doc commit:     write docs/ja/NNNN-<slug>.md with `commit: <SHA from step 1>`
#                       git add docs/ja/...  &&  git commit -m "docs(ja): NNNN — ..."
#
# Wired as a Claude Code PreToolUse hook on Bash (settings.json). Safe
# no-op for any non-`git commit` Bash invocation.
#
# See .claude/skills/code-learning-doc/SKILL.md for the full skill.

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
  # `src/*.zig|build.zig|build.zig.zon` are obvious source-bearing changes.
  # Real ADRs (`.dev/decisions/NNNN-<slug>.md`) also count; the README and
  # the 0000 template under `.dev/decisions/` do NOT (meta-metadata).
  case "$1" in
    src/*.zig|build.zig|build.zig.zon)        return 0 ;;
    .dev/decisions/0000-*.md)                  return 1 ;;
    .dev/decisions/[0-9][0-9][0-9][0-9]-*.md) return 0 ;;
    *)                                         return 1 ;;
  esac
}

is_doc_path() {
  [[ "$1" =~ ^docs/ja/[0-9]{4}-.+\.md$ ]]
}

# --- 4. Classify this commit -------------------------------------------------
STAGED="$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)"
[[ -z "$STAGED" ]] && exit 0

this_has_source=0
this_has_doc=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if is_source_path "$f"; then this_has_source=1; fi
  if is_doc_path   "$f"; then this_has_doc=1;   fi
done <<< "$STAGED"

# --- 5. Classify HEAD --------------------------------------------------------
prev_has_source=0
prev_has_doc=0
LAST_FILES="$(git log -1 --name-only --format= HEAD 2>/dev/null || true)"
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if is_source_path "$f"; then prev_has_source=1; fi
  if is_doc_path   "$f"; then prev_has_doc=1;   fi
done <<< "$LAST_FILES"

prev_is_unpaired_source=0
if [ $prev_has_source -eq 1 ] && [ $prev_has_doc -eq 0 ]; then
  prev_is_unpaired_source=1
fi

# --- 6. Rule 1: doc commits must not contain source -------------------------
if [ $this_has_doc -eq 1 ] && [ $this_has_source -eq 1 ]; then
  cat >&2 <<'EOF'
✗ commit blocked by scripts/check_learning_doc.sh

A learning-doc commit must NOT also contain source-bearing files
(src/*.zig, build.zig, build.zig.zon, .dev/decisions/*.md). Split into
two commits:

    git commit -m "feat(...): ..."   # source only (commit N)
    git commit -m "docs(ja): ..."    # docs/ja/NNNN-*.md only (commit N+1)

Mixing them defeats the SHA-pairing scheme.
EOF
  exit 1
fi

# --- 7. Rule 2: previous source commit must be paired in this commit -------
if [ $prev_is_unpaired_source -eq 1 ] && [ $this_has_doc -eq 0 ]; then
  prev_sha="$(git log -1 --format=%h HEAD)"
  last_idx="$(ls docs/ja/ 2>/dev/null | grep -oE '^[0-9]{4}' | sort -n | tail -1 || echo "0000")"
  next="$(printf '%04d' $((10#$last_idx + 1)))"
  cat >&2 <<EOF
✗ commit blocked by scripts/check_learning_doc.sh

The previous commit (${prev_sha}) added source-bearing files but no
learning doc accompanied it. The next commit MUST be the paired doc:

    docs/ja/${next}-<slug>.md   with front matter \`commit: ${prev_sha}\`

Skill / template: .claude/skills/code-learning-doc/SKILL.md

The commit you are attempting now stages something else, which would
leave the source commit unpaired permanently.
EOF
  exit 1
fi

exit 0
