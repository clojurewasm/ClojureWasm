#!/usr/bin/env bash
# scripts/check_dual_backend_parity.sh
#
# PreToolUse hook on Bash that blocks `git push` when any unpushed
# commit ships a VM compile arm body as a silent gap without a
# `// VM-DEFER:` marker, or when a VM-DEFER marker is malformed
# (missing the `[refs: D-NNN, feature_deps.yaml#<key>]` block).
#
# Discipline source: .claude/rules/dual_backend_parity.md +
# .dev/decisions/0036_dual_backend_parity_contract.md.
# Sibling hook: scripts/check_provisional_sync.sh (PROVISIONAL marker
# discipline) — the present hook adapts the same shape.
#
# Scope (paths inspected for body discipline):
#   - src/eval/backend/vm/compiler.zig
#   - src/eval/backend/vm.zig
#   - src/eval/backend/vm/*.zig
#   - src/eval/backend/tree_walk.zig
#
# What counts as a silent gap:
#   - A line matching `return error\.NotImplemented` without a
#     `// VM-DEFER:` marker on the line directly above.
#
# Marker form check (applied to all newly-added VM-DEFER lines):
#   - Must contain `[refs:` block.
#   - Must contain at least one `D-NNN` reference.
#   - Must contain at least one `feature_deps.yaml#` reference.
#
# Modes:
#   default            (hook): reads hook payload from stdin, only
#                              acts when the command is `git push`,
#                              checks @{u}..HEAD (or all HEAD when
#                              no upstream).
#   --test-range RANGE          : run check directly on the given git
#                                 commit range. Used by self-tests.
#   --test-staged               : run check on the staged index vs
#                                 HEAD (= what would land in the
#                                 next commit). Used by quick local
#                                 sanity checks.
#
# Exit codes:
#   0  pass (or non-push command in default mode)
#   1  internal error (bad input)
#   2  hook blocked the push

set -u
set -o pipefail

# --- 0. Shared helpers ------------------------------------------------------
source "$(dirname "$0")/hook_lib.sh"

# --- 1. Parse args ----------------------------------------------------------

MODE="hook"
TEST_RANGE=""
case "${1:-}" in
  --test-range)
    MODE="test_range"
    TEST_RANGE="${2:?--test-range requires a range arg}"
    shift 2 || true
    ;;
  --test-staged)
    MODE="test_staged"
    shift
    ;;
esac

hook_cd_project_root

# --- 2. In hook mode, only act on `git push` --------------------------------

if [[ "$MODE" == "hook" ]]; then
  hook_read_command
  hook_is_git_push || exit 0
fi

# --- 3. Helpers -------------------------------------------------------------

# Is this path subject to dual-backend parity body-discipline?
is_parity_scope() {
  local p="$1"
  case "$p" in
    src/eval/backend/vm/compiler.zig) return 0 ;;
    src/eval/backend/vm.zig)          return 0 ;;
    src/eval/backend/vm/*.zig)        return 0 ;;
    src/eval/backend/tree_walk.zig)   return 0 ;;
    *) return 1 ;;
  esac
}

# Walk a git diff range, find any post-image line matching the body-
# discipline pattern, and verify the line directly above is a
# `// VM-DEFER:` marker.
#
# Strategy: rather than parsing the unified diff (which conflates
# context vs added lines and loses line-of-line continuity for the
# above-line check), inspect the post-image of each in-scope file
# at the range's tip and grep for the pattern. This is conservative
# — it flags pre-existing un-marked NotImplemented bodies, which is
# exactly what T1 asks for. False positives in this direction are
# desired (= existing drift surfaces).
#
# Args:
#   $1 — git range (e.g. "main..HEAD" or "--cached" or "HEAD").
# Returns lines via stdout: "<file>:<line>:<rendered>" for each
# violation. Empty stdout = pass.
collect_unmarked_notimpl() {
  local range="$1"
  # File set: any in-scope file the range touches.
  local files=()
  while IFS= read -r f; do
    is_parity_scope "$f" && files+=("$f")
  done < <(git diff --name-only "$range" 2>/dev/null)
  [[ ${#files[@]} -eq 0 ]] && return 0

  # For each touched in-scope file, fetch its post-image at the
  # range tip and walk the lines.
  local tip
  case "$range" in
    --cached) tip="" ;;     # working index — use file as-is on disk
    *)
      # The tip is whatever git diff considers the "to" side. For
      # `A..B` that's B; for `A...B` that's B as well; for `--cached`
      # we use the working tree above; for `HEAD` (single rev) we
      # use HEAD; for any other form we just take whichever ref
      # follows `..`.
      if [[ "$range" == *..* ]]; then
        tip="${range##*..}"
      else
        tip="$range"
      fi
      ;;
  esac

  for f in "${files[@]}"; do
    local content
    if [[ -z "$tip" ]]; then
      [[ -f "$f" ]] || continue
      content="$(cat "$f")"
    else
      content="$(git show "$tip:$f" 2>/dev/null)" || continue
    fi
    [[ -z "$content" ]] && continue

    # Walk lines; track the previous line for the above-line check.
    local prev=""
    local lineno=0
    while IFS= read -r line; do
      lineno=$((lineno + 1))
      if [[ "$line" =~ return[[:space:]]+error\.NotImplemented ]]; then
        # Check prev is a VM-DEFER marker (allowing leading
        # whitespace). The marker syntax: `// VM-DEFER:` (with at
        # least one space after the slashes).
        if ! [[ "$prev" =~ ^[[:space:]]*//[[:space:]]+VM-DEFER: ]]; then
          printf '%s:%d: unmarked `return error.NotImplemented` (line above: %q)\n' \
            "$f" "$lineno" "$prev"
        fi
      fi
      prev="$line"
    done <<< "$content"
  done
}

# Verify every newly-added `// VM-DEFER:` marker line in the
# range's diff carries a well-formed
# `[refs: D-NNN, feature_deps.yaml#<key>]` block.
malformed_markers() {
  local range="$1"
  local current_file=""
  local in_scope=0
  local bad=()

  while IFS= read -r line; do
    case "$line" in
      "diff --git "*)
        current_file="${line#diff --git a/* b/}"
        if is_parity_scope "$current_file"; then
          in_scope=1
        else
          in_scope=0
        fi
        ;;
      "+++ "*|"--- "*) ;;
      "+"*)
        if [[ $in_scope -eq 1 ]] && [[ "$line" == *"VM-DEFER:"* ]]; then
          local body="${line#+}"
          if ! [[ "$body" == *'[refs:'* ]]; then
            bad+=("$current_file :: missing [refs: block :: $body")
          elif ! [[ "$body" =~ D-[0-9]+ ]]; then
            bad+=("$current_file :: missing D-NNN :: $body")
          elif ! [[ "$body" == *feature_deps.yaml#* ]]; then
            bad+=("$current_file :: missing feature_deps.yaml# :: $body")
          fi
        fi
        ;;
    esac
  done < <(git diff --no-color "$range")

  if [[ ${#bad[@]} -gt 0 ]]; then
    printf '%s\n' "${bad[@]}"
  fi
}

# --- 4. Build the range to inspect ------------------------------------------

case "$MODE" in
  hook)
    UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo '')"
    if [[ -n "$UPSTREAM" ]]; then
      REV_RANGE="$UPSTREAM..HEAD"
    else
      REV_RANGE="HEAD"
    fi
    REV_OUT="$(git rev-list "$REV_RANGE" 2>&1)" || {
      echo "internal: git rev-list $REV_RANGE failed — failing closed" >&2
      echo "$REV_OUT" >&2
      exit 1
    }
    RANGES=()
    while IFS= read -r sha; do
      [[ -z "$sha" ]] && continue
      if git rev-parse --verify "$sha^" >/dev/null 2>&1; then
        RANGES+=("$sha^..$sha")
      else
        empty_tree="$(git hash-object -t tree --stdin </dev/null)"
        RANGES+=("$empty_tree..$sha")
      fi
    done <<< "$REV_OUT"
    ;;
  test_range)
    RANGES=("$TEST_RANGE")
    ;;
  test_staged)
    RANGES=("--cached")
    ;;
esac

if [[ ${#RANGES[@]} -eq 0 ]]; then
  exit 0
fi

# --- 5. Inspect each range --------------------------------------------------

FAIL=0
FAIL_MSGS=()

for range in "${RANGES[@]}"; do
  unmarked="$(collect_unmarked_notimpl "$range")"
  if [[ -n "$unmarked" ]]; then
    FAIL=1
    FAIL_MSGS+=("$range: unmarked silent gap(s)")
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      FAIL_MSGS+=("  $line")
    done <<< "$unmarked"
  fi

  malformed="$(malformed_markers "$range")"
  if [[ -n "$malformed" ]]; then
    FAIL=1
    FAIL_MSGS+=("$range: malformed VM-DEFER marker(s)")
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      FAIL_MSGS+=("  $line")
    done <<< "$malformed"
  fi
done

# --- 6. Report + exit -------------------------------------------------------

if [[ $FAIL -eq 0 ]]; then
  exit 0
fi

cat >&2 <<'EOF'
✗ push blocked by scripts/check_dual_backend_parity.sh

A commit ships a VM compile arm body as a silent gap without a
`// VM-DEFER:` marker, OR introduces a malformed VM-DEFER marker
that lacks the required `[refs: D-NNN, feature_deps.yaml#<key>]`
block.

Required canonical marker shape (see .claude/rules/dual_backend_parity.md):
    // VM-DEFER: <one-line why> [refs: D-NNN, feature_deps.yaml#<key>]
    return error.NotImplemented;

The `[refs: ...]` block must include at least one D-NNN reference
AND at least one feature_deps.yaml#<key> reference.

When introducing a VM compile arm that cannot land its real
implementation in the current cycle, the commit must:

  1. Add the `// VM-DEFER:` marker directly above the body line
     (no blank line between).
  2. Add (or amend) the matching `feature_deps.yaml` entry
     (`status: provisional`, `provisional_markers:` lists the
     source location).
  3. Add (or amend) the matching `.dev/debt.yaml` row with a
     close-out barrier predicate.

When discharging a VM-DEFER (the real impl lands), remove the
marker entirely (do not comment-out), flip the yaml entry to
`landed`, and discharge the debt row.

Findings:
EOF
for m in "${FAIL_MSGS[@]}"; do
  printf '  %s\n' "$m" >&2
done

cat >&2 <<'EOF'

(Discipline source: .claude/rules/dual_backend_parity.md +
.dev/decisions/0036_dual_backend_parity_contract.md +
.dev/principle.md "Dual-backend drift" entry.)
EOF

exit 2
