#!/usr/bin/env bash
# check_no_op_stub.sh — pre-commit gate.
# Heuristic lint for forbidden no-op stub patterns in src/.
# Per Shota's directive: "if implemented, must be real; no-op redirect forbidden".
#
# Phase 5+ activation by design. Phase 4 entry: informational only.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Patterns considered no-op stubs (Phase 5+ activation):
#   1. fn body that immediately returns the only argument unchanged
#   2. fn body that wraps the body argument in a no-op block
#   3. comment "no-op" or "stub" near impl without explicit ADR reference
#
# Skeleton boundary: struct definition only OR fn body that is exactly
# `return error.NotImplemented;` or `@panic("Phase N: see ADR-NNNN");`
# is allowed (see JVM_TO_ZIG §2 原則 4).
echo "[check_no_op_stub] informational mode (Phase 4 entry); full heuristic activates at Phase 5."
exit 0
