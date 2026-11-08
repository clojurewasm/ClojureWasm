#!/usr/bin/env bash
# scripts/check_provisional_sync.sh
#
# PreToolUse hook on Bash that blocks `git push` when any unpushed
# commit changes a PROVISIONAL: marker in a source-bearing file
# without also editing feature_deps.yaml AND .dev/debt.yaml in the
# same commit. Additionally rejects PROVISIONAL: marker text that
# lacks a well-formed `[refs: D-NNN, feature_deps.yaml#<key>]` block.
#
# Discipline source: memory 20260909234453-094762cc (provisional_marker).
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
#   --gate                      : sweep the WORKING TREE (no git range,
#                                 no hook payload). Every PROVISIONAL:
#                                 marker in scope must carry a
#                                 well-formed
#                                 `[refs: D-NNN, feature_deps.yaml#<key>]`
#                                 block whose D-NNN resolves to a row in
#                                 .dev/debt.yaml and whose key resolves
#                                 to an entry in feature_deps.yaml. This
#                                 is the batch-suite form of the marker
#                                 invariant — it holds regardless of what
#                                 any commit did, so the discipline is
#                                 checkable where hooks do not run (CI,
#                                 the full gate). Mirrors the
#                                 two-entry-point shape of
#                                 scripts/check_clj_attribution.sh.
#
#                                 The COMMIT-COUPLING half of this hook
#                                 (marker change => feature_deps.yaml +
#                                 .dev/debt.yaml edited in the SAME
#                                 commit) stays hook-only on purpose: a
#                                 tree sweep cannot see commits, and
#                                 asserting it from --gate would be a
#                                 claim the check cannot make.
#
# The diff walk and the tree sweep share ONE marker validator
# (`marker_refs_defect`) — a second, mode-local copy is exactly the
# drift this hook exists to prevent.
#
# Exit codes:
#   0  pass (or non-push command in default mode)
#   1  internal error (bad input)
#   2  hook blocked the push / --gate found a violation

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
  --gate)
    MODE="gate"
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

# SSOT locations. feature_deps.yaml moved under data/ (its header is the
# schema doc); resolve it instead of hard-coding, so the hook path and the
# --gate path can never disagree about where the SSOT lives.
FEATURE_DEPS=""
for _cand in data/feature_deps.yaml feature_deps.yaml .dev/feature_deps.yaml; do
  if [[ -f "$_cand" ]]; then FEATURE_DEPS="$_cand"; break; fi
done
DEBT_YAML=".dev/debt.yaml"

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

# --- 3a. Shared predicates (ONE validator, two call paths) ------------------
#
# The diff walk (hook / --test-*) and the working-tree sweep (--gate) must
# agree on what a malformed marker is, so both call `marker_refs_defect`.

# Marker-form predicate: does this PROVISIONAL line carry a well-formed
# `[refs: D-NNN, feature_deps.yaml#<key>]` block? Echoes the defect
# reason; EMPTY output means well-formed.
marker_refs_defect() {
  local body="$1"
  if ! [[ "$body" == *'[refs:'* ]]; then
    echo "missing [refs: block"
  elif ! [[ "$body" =~ D-[0-9]+ ]]; then
    echo "missing D-NNN"
  elif ! [[ "$body" == *feature_deps.yaml#* ]]; then
    echo "missing feature_deps.yaml#"
  fi
}

# The `[refs: ...]` payload of a marker line (empty when absent).
marker_refs_block() {
  local body="$1"
  if [[ "$body" =~ \[refs:([^]]*)\] ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Does `.dev/debt.yaml` define this row id? Exact match on the `- id:`
# scalar (quoted or bare), not a substring grep: a short id must not
# resolve via a longer one that merely shares its prefix.
debt_id_defined() {
  awk -v k="$1" '
    /^[[:space:]]*-[[:space:]]*id:[[:space:]]*/ {
      v = $0
      sub(/^[[:space:]]*-[[:space:]]*id:[[:space:]]*/, "", v)
      gsub(/^"|"$/, "", v); gsub(/[[:space:]]+$/, "", v)
      if (v == k) found = 1
    }
    END { exit(found ? 0 : 1) }
  ' "$DEBT_YAML"
}

# Does feature_deps.yaml define this entry name? Exact match, same reason.
feature_key_defined() {
  awk -v k="$1" '
    /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
      v = $0
      sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", v)
      gsub(/^"|"$/, "", v); gsub(/[[:space:]]+$/, "", v)
      if (v == k) found = 1
    }
    END { exit(found ? 0 : 1) }
  ' "$FEATURE_DEPS"
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
          # least one feature_deps.yaml#. Same predicate --gate applies
          # to every marker in the tree.
          local body="${line#+}"
          local defect
          defect="$(marker_refs_defect "$body")"
          [[ -n "$defect" ]] && bad+=("$current_file :: $defect :: $body")
        fi
        ;;
    esac
  done < <(git diff --no-color "$range")

  if [[ ${#bad[@]} -gt 0 ]]; then
    printf '%s\n' "${bad[@]}"
  fi
}

# Does the range's file list include feature_deps.yaml? Matched at the
# resolved SSOT path ($FEATURE_DEPS, today data/feature_deps.yaml) — the
# literal `^feature_deps\.yaml$` this used to grep for stopped matching
# when the SSOT moved under data/, which made the sync half unsatisfiable.
range_touches_yaml() {
  [[ -n "$FEATURE_DEPS" ]] || return 1
  git diff --name-only "$1" 2>/dev/null | grep -qxF "$FEATURE_DEPS"
}

# Does the range's file list include .dev/debt.yaml?
range_touches_debt() {
  git diff --name-only "$1" 2>/dev/null | grep -qE '^\.dev/debt\.ya?ml$'
}

# Failure report shared by both entry points. Consumes $HEADLINE and
# $FAIL_MSGS; never returns (exits 2).
report_failure() {
  echo "$HEADLINE" >&2
  cat >&2 <<'EOF'

A PROVISIONAL: marker in a source-bearing file (src/**/*.zig,
src/**/*.clj, build.zig*, test/e2e/*.sh) is malformed, cites a
ref that does not resolve, or — in hook mode — changed without
the matching SSOT edits in the same commit.

Required canonical marker shape (see memory 20260909234453-094762cc (provisional_marker)):
    // PROVISIONAL: <one-line why> [refs: D-NNN, feature_deps.yaml#<key>]
    ;; PROVISIONAL: <one-line why> [refs: D-NNN, feature_deps.yaml#<key>]

The `[refs: ...]` block must include at least one D-NNN reference
AND at least one feature_deps.yaml#<key> reference, and both must
name a live row / entry.

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

(Discipline source: memory 20260909234453-094762cc (provisional_marker) +
memory 20260901172301-1919d835, the Silent default-shift smell.)
EOF
  exit 2
}

# --- 3b. --gate: working-tree sweep ------------------------------------------
#
# No git range, no hook payload: enumerate the in-scope files ON DISK and
# validate every PROVISIONAL marker they carry — form (the shared
# `marker_refs_defect`) plus resolution of each cited D-NNN / feature key
# against the two SSOTs. Conservative by design: it flags pre-existing
# drift, not just what the current commit touched. The commit-coupling
# half is NOT asserted here (see the header) — a tree sweep cannot see
# commits.

if [[ "$MODE" == "gate" ]]; then
  if [[ -z "$FEATURE_DEPS" ]]; then
    echo "internal: feature_deps.yaml not found (looked in data/, ./, .dev/) — failing closed" >&2
    exit 1
  fi
  if [[ ! -f "$DEBT_YAML" ]]; then
    echo "internal: $DEBT_YAML not found — failing closed" >&2
    exit 1
  fi

  GATE_FILES=()
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    is_marker_scope "$f" && GATE_FILES+=("$f")
  done < <( { find src -type f \( -name '*.zig' -o -name '*.clj' \) 2>/dev/null
              ls -1 build.zig build.zig.zon 2>/dev/null
              find test/e2e -type f -name '*.sh' 2>/dev/null; } | sort )

  FAIL_MSGS=()
  marker_total=0

  # Guarded: `"${arr[@]}"` on an empty array is an unbound-variable error
  # under `set -u` on the macOS-shipped bash (3.2) the gate also runs on.
  if [[ ${#GATE_FILES[@]} -gt 0 ]]; then
    while IFS= read -r hit; do
      [[ -z "$hit" ]] && continue
      file="${hit%%:*}"; rest="${hit#*:}"
      lineno="${rest%%:*}"; body="${rest#*:}"
      marker_total=$((marker_total + 1))

      defect="$(marker_refs_defect "$body")"
      if [[ -n "$defect" ]]; then
        FAIL_MSGS+=("$file:$lineno: $defect :: $body")
        continue
      fi

      refs="$(marker_refs_block "$body")"
      for id in $(printf '%s' "$refs" | grep -oE 'D-[0-9]+' | sort -u); do
        debt_id_defined "$id" || FAIL_MSGS+=("$file:$lineno: $id has no row in $DEBT_YAML :: $body")
      done
      for key in $(printf '%s' "$refs" | grep -oE 'feature_deps\.yaml#[A-Za-z0-9_./-]+' | sed 's|^feature_deps\.yaml#||' | sort -u); do
        feature_key_defined "$key" || FAIL_MSGS+=("$file:$lineno: feature_deps.yaml#$key has no entry in $FEATURE_DEPS :: $body")
      done
    done < <(grep -Hn 'PROVISIONAL:' "${GATE_FILES[@]}" 2>/dev/null || true)
  fi

  if [[ ${#FAIL_MSGS[@]} -eq 0 ]]; then
    echo "    provisional_sync: $marker_total PROVISIONAL marker(s) across ${#GATE_FILES[@]} in-scope source file(s); each carries [refs: D-NNN, feature_deps.yaml#<key>] resolving to $DEBT_YAML + $FEATURE_DEPS"
    exit 0
  fi

  HEADLINE="✗ gate failed: scripts/check_provisional_sync.sh (working-tree sweep)"
  report_failure
fi

# --- 4. Build the range to inspect -------------------------------------------

case "$MODE" in
  hook)
    # Commits not yet on any remote branch. Replaces `@{u}..HEAD`, which
    # re-flagged already-published commits on a cross-branch push
    # ([CLJW-SMELLHOOK]); hook_unpushed_shas fails closed on a git error.
    REV_OUT="$(hook_unpushed_shas)"
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

HEADLINE="✗ push blocked by scripts/check_provisional_sync.sh"
report_failure
