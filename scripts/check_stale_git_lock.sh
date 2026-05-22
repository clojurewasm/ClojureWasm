#!/usr/bin/env bash
# check_stale_git_lock.sh — PreToolUse: Bash hook.
# Removes .git/index.lock if older than 60s and no git process holds it.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
LOCK="$REPO_ROOT/.git/index.lock"

if [[ ! -f "$LOCK" ]]; then
    exit 0
fi

NOW=$(date +%s)
# stat is platform-specific; try -f (macOS) first, fall back to -c (Linux).
LOCK_MTIME=$(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null)
AGE=$(( NOW - LOCK_MTIME ))

if (( AGE > 60 )); then
    if pgrep -f "git" >/dev/null 2>&1; then
        echo "[check_stale_git_lock] WARN: .git/index.lock is ${AGE}s old, but a git process is running. Skipping."
        exit 0
    fi
    echo "[check_stale_git_lock] Removing stale lock (age: ${AGE}s)"
    rm -f "$LOCK"
fi

exit 0
