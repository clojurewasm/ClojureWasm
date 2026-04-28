#!/usr/bin/env bash
# scripts/check_md_tables.sh
#
# Pre-commit gate: every staged *.md file must already be aligned by
# `md-table-align`. We don't run a PostToolUse formatter on every Edit
# (too noisy); we run a single gate at commit time, which is the
# cheapest place to catch drift.
#
# Hook contract: invoked as a Claude Code PreToolUse hook on Bash
# (.claude/settings.json). Reads the JSON payload from stdin, no-ops
# unless the command being run is `git commit`.
#
# Failure modes:
#   - md-table-align not installed → block with install guide (exit 1).
#   - One or more staged *.md files would change → block with the
#     filenames and a one-liner fix command (exit 1).
#
# md-table-align is shipped via bbin from
# https://github.com/chaploud/babashka-utilities.

set -euo pipefail

# --- 1. Read the Claude Code hook payload ------------------------------------
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

# --- 3. Collect staged *.md files (added or modified, not deleted) -----------
STAGED_MD="$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null \
             | grep -E '\.md$' || true)"

[[ -z "$STAGED_MD" ]] && exit 0

# --- 4. Tool availability ----------------------------------------------------
if ! command -v md-table-align >/dev/null 2>&1; then
  cat >&2 <<'EOF'
[md-table-gate] md-table-align is not on PATH.

This repo enforces Markdown table alignment at commit time. Install
the CLI via bbin:

  # one-time: install bbin (Linux / macOS via Homebrew)
  brew install babashka/brew/bbin
  echo 'export PATH="$PATH:$HOME/.local/bin"' >> ~/.bashrc

  # install the tool
  bbin install io.github.chaploud/babashka-utilities

After installation `md-table-align --help` should print a usage screen.
Then re-run your `git commit`.

If you cannot install bbin right now, you can also bypass via:
  git -c core.hooksPath=/dev/null commit ...
…but please don't make a habit of it; chapters that drift here are
painful to clean up later.
EOF
  exit 2
fi

# --- 5. Per-file check -------------------------------------------------------
BAD=()
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  # Skip files that disappeared between staging and now (rare).
  [[ -f "$f" ]] || continue
  if ! md-table-align --check "$f" >/dev/null 2>&1; then
    BAD+=("$f")
  fi
done <<< "$STAGED_MD"

if (( ${#BAD[@]} == 0 )); then
  exit 0
fi

# --- 6. Block, with a one-liner fix ------------------------------------------
{
  echo "[md-table-gate] The following staged *.md files have misaligned tables:"
  for f in "${BAD[@]}"; do
    echo "  - $f"
  done
  echo
  echo "Fix and re-stage:"
  echo
  printf '  md-table-align'
  for f in "${BAD[@]}"; do
    printf ' %q' "$f"
  done
  printf ' && git add'
  for f in "${BAD[@]}"; do
    printf ' %q' "$f"
  done
  printf '\n'
} >&2

exit 2
