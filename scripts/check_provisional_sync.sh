#!/usr/bin/env bash
# scripts/check_provisional_sync.sh
#
# PreToolUse hook on Bash that blocks `git push` when any unpushed
# commit changes a PROVISIONAL: marker in a source-bearing file
# without also editing feature_deps.yaml AND .dev/debt.yaml in the
# same commit. Additionally rejects PROVISIONAL: marker text that
# lacks a well-formed `[refs: D-NNN, feature_deps.yaml#<key>]` block.
#
# Discipline source: .claude/rules/provisional_marker.md.
# Deterministic enforcement layer behind the probabilistic
# CLAUDE.md / rule prose.
#
# Source-bearing scope for marker detection:
#   - src/**             (Zig + .clj)
#   - build.zig, build.zig.zon
#   - test/e2e/**.sh
#
# Modes:
#   default            (hook): reads hook payload from stdin, only
#                              acts when the command is `git push`,
#                              checks @{u}..HEAD (or all HEAD when
#                              no upstream).
#   --test-range RANGE          : run check directly on the given git
#                                 commit range. Used by self-tests.
#   --test-staged               : run check on the staged index
#                                 vs HEAD (= what would land in the
#                                 next commit). Used by quick local
#                                 sanity checks.
#
# Exit codes:
#   0  pass (or non-push command in default mode)
#   1  internal error (bad input)
#   2  hook blocked the push

set -u
set -o pipefail

# --- 0. Shared helpers (Wave 16 hook_lib.sh extraction) ----------------------
source "$(dirname "$0")/hook_lib.sh"

# --- 1. Parse args -----------------------------------------------------------

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

# --- 2. In hook mode, only act on `git push` ---------------------------------

if [[ "$MODE" == "hook" ]]; then
  hook_read_command
  hook_is_git_push || exit 0
fi

# --- 3. Helpers --------------------------------------------------------------

# Is this path subject to PROVISIONAL marker enforcement?
is_marker_scope() {
  local p="$1"
  case "$p" in
    src/*.zig|src/*.clj|build.zig|build.zig.zon|test/e2e/*.sh)
      return 0 ;;
    src/*/*)
      # any nested file under src/
      case "$p" in
        *.zig|*.clj) return 0 ;;
        *)           return 1 ;;
      esac
      ;;
    *)
      return 1 ;;
  esac
}

# Read +PROVISIONAL: and -PROVISIONAL: line counts from a diff range.
# Only counts lines whose file is in marker scope.
count_marker_changes() {
  local range="$1"
  local total_add=0 total_del=0
  local current_file=""
  local in_scope=0

  while IFS= read -r line; do
    case "$line" in
      "diff --git "*)
        # Extract the post-image path: "diff --git a/foo b/foo"
        current_file="${line#diff --git a/* b/}"
        if is_marker_scope "$current_file"; then
          in_scope=1
        else
          in_scope=0
        fi
        ;;
      "+++ "*|"--- "*) ;;  # ignore the file header lines
      "+"*)
        if [[ $in_scope -eq 1 ]] && [[ "$line" == *PROVISIONAL:* ]]; then
          total_add=$((total_add + 1))
        fi
        ;;
      "-"*)
        if [[ $in_scope -eq 1 ]] && [[ "$line" == *PROVISIONAL:* ]]; then
          total_del=$((total_del + 1))
        fi
        ;;
    esac
  done < <(git diff --no-color "$range")

  echo "$total_add $total_del"
}

# Verify every newly-added PROVISIONAL marker line in `range` carries
# a well-formed `[refs: D-NNN, feature_deps.yaml#<key>]` block.
malformed_markers() {
  local range="$1"
  local current_file=""
  local in_scope=0
  local bad=()

  while IFS= read -r line; do
    case "$line" in
      "diff --git "*)
        current_file="${line#diff --git a/* b/}"
        if is_marker_scope "$current_file"; then
          in_scope=1
        else
          in_scope=0
        fi
        ;;
      "+++ "*|"--- "*) ;;
      "+"*)
        if [[ $in_scope -eq 1 ]] && [[ "$line" == *PROVISIONAL:* ]]; then
          # Must contain `[refs:` with at least one D-NNN AND at
          # least one feature_deps.yaml#.
          local body="${line#+}"
          if ! [[ "$body" == *'[refs:'* ]]; then
            bad+=("$current_file :: $body")
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

# Does the range's file list include feature_deps.yaml?
range_touches_yaml() {
  git diff --name-only "$1" 2>/dev/null | grep -qE '^feature_deps\.yaml$'
}

# Does the range's file list include .dev/debt.yaml?
range_touches_debt() {
  git diff --name-only "$1" 2>/dev/null | grep -qE '^\.dev/debt\.ya?ml$'
}

# --- 4. Build the range to inspect -------------------------------------------

case "$MODE" in
  hook)
    UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo '')"
    if [[ -n "$UPSTREAM" ]]; then
      REV_RANGE="$UPSTREAM..HEAD"
    else
      # First push — every commit on HEAD
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
      # `git rev-list HEAD` includes the root commit, whose parent does not
      # exist. Use the empty-tree object as parent for that case so the diff
      # walk still works without raising "fatal: bad revision" (review
      # finding F5).
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

# --- 5. Inspect each range ---------------------------------------------------

FAIL=0
FAIL_MSGS=()

for range in "${RANGES[@]}"; do
  counts="$(count_marker_changes "$range")"
  add="${counts% *}"
  del="${counts#* }"

  # Always check form on additions (regardless of sync)
  malformed="$(malformed_markers "$range")"
  if [[ -n "$malformed" ]]; then
    FAIL=1
    FAIL_MSGS+=("$range: malformed PROVISIONAL marker(s)")
    FAIL_MSGS+=("$malformed")
  fi

  # Sync check: any marker change requires yaml + debt update in same range
  if [[ $((add + del)) -gt 0 ]]; then
    yaml_ok=0; debt_ok=0
    if range_touches_yaml "$range"; then yaml_ok=1; fi
    if range_touches_debt "$range"; then debt_ok=1; fi
    if [[ $yaml_ok -eq 0 ]] || [[ $debt_ok -eq 0 ]]; then
      FAIL=1
      FAIL_MSGS+=("$range: marker changes (+$add/-$del) without yaml($yaml_ok)/debt($debt_ok) sync")
    fi
  fi
done

# --- 6. Report + exit --------------------------------------------------------

if [[ $FAIL -eq 0 ]]; then
  exit 0
fi

cat >&2 <<'EOF'
✗ push blocked by scripts/check_provisional_sync.sh

A commit changes one or more PROVISIONAL: markers in source-bearing
files (src/**/*.zig, src/**/*.clj, build.zig*, test/e2e/*.sh)
without the matching SSOT edits in the same commit, or introduces
a malformed marker.

Required canonical marker shape (see .claude/rules/provisional_marker.md):
    // PROVISIONAL: <one-line why> [refs: D-NNN, feature_deps.yaml#<key>]
    ;; PROVISIONAL: <one-line why> [refs: D-NNN, feature_deps.yaml#<key>]

The `[refs: ...]` block must include at least one D-NNN reference
AND at least one feature_deps.yaml#<key> reference.

When introducing OR discharging a PROVISIONAL marker the commit
must also touch:
    feature_deps.yaml  (the matching entry's provisional_markers
                        list or new entry)
    .dev/debt.yaml       (the matching D-NNN row or new row)

To recover:
  1. Decide whether you are introducing, moving, or discharging a
     provisional behaviour.
  2. Add / update the feature_deps.yaml entry (set status,
     provisional_markers field).
  3. Open / close the .dev/debt.yaml row.
  4. Amend the commit (`git commit --amend`) and re-attempt push.

Findings:
EOF
for m in "${FAIL_MSGS[@]}"; do
  printf '  %s\n' "$m" >&2
done

cat >&2 <<'EOF'

(Discipline source: .claude/rules/provisional_marker.md +
.dev/principle.md Silent default-shift entry.)
EOF

exit 2
