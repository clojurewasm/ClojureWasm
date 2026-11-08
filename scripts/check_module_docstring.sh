#!/usr/bin/env bash
# scripts/check_module_docstring.sh
#
# Verifies that every new `src/**/*.zig` file opens with the canonical
# two-line module-docstring header per `memory 20260909235200-7c602907 (module_docstring)`:
#
#   // SPDX-License-Identifier: EPL-2.0
#   //! <one-line summary of what this module is for>
#
# Mode: informational (Wave-16 introduction; closes D-022 partially).
# Future cycle promotes to PreToolUse:Bash hook on `git commit` once
# the heuristic stabilises.
#
# Modes:
#   default   — scan every `src/**/*.zig` and report files missing the
#                two-line opener. Exit 0; report to stdout.
#   --check   — same scan, exit 1 if any file fails.
#   --staged  — only scan files that are currently staged (`git diff
#                --cached --name-only --diff-filter=A`). Used by a
#                future pre-commit hook.
#
# Exemptions:
#   - `src/main.zig` is exempt — entry point with a different
#     documentation convention (Juicy Main per zig 0.16).
#   - Test-only files (none in cw v1 today; placeholder).

set -u
set -o pipefail

cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

MODE="report"
case "${1:-}" in
  --check)  MODE="check"  ;;
  --staged) MODE="staged" ;;
esac

if [[ "$MODE" == "staged" ]]; then
  FILES=$(git diff --cached --name-only --diff-filter=A 2>/dev/null | grep -E '^src/.*\.zig$' || true)
else
  FILES=$(find src -name '*.zig' -type f 2>/dev/null || true)
fi

if [[ -z "$FILES" ]]; then
  [[ "$MODE" != "staged" ]] && echo "no src/**/*.zig files found"
  exit 0
fi

violations=0
violation_list=()

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  [[ "$f" == "src/main.zig" ]] && continue

  line1=""
  line2=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ -z "$line1" ]]; then
      line1="$line"
    elif [[ -z "$line2" ]]; then
      line2="$line"
      break
    fi
  done < "$f"

  ok=0
  if [[ "$line1" == "// SPDX-License-Identifier: EPL-2.0" ]] && \
     [[ "$line2" == //!* ]]; then
    ok=1
  fi

  if [[ $ok -eq 0 ]]; then
    violations=$((violations + 1))
    violation_list+=("$f")
  fi
done <<< "$FILES"

if [[ $violations -eq 0 ]]; then
  echo "OK module docstring present on all checked files ($(echo "$FILES" | wc -l | tr -d ' ') scanned)"
  exit 0
fi

echo "$violations file(s) missing canonical 2-line module docstring:"
for f in "${violation_list[@]}"; do
  echo "  - $f"
done
echo ""
echo "Canonical form (per memory 20260909235200-7c602907 (module_docstring)):"
echo "  // SPDX-License-Identifier: EPL-2.0"
echo "  //! <one-line summary>"

if [[ "$MODE" == "check" || "$MODE" == "staged" ]]; then
  exit 1
fi
exit 0
