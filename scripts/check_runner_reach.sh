#!/usr/bin/env bash
# Every runnable script in the repository must have a row in test/units.list.
#
# Exits non-zero on: a script with no row, a row naming a script that does not
# exist, a duplicate id, or a row still tagged `todo:`. A script that should
# not run in the suite gets a row with gated=no AND a settled kind saying why
# — an exclusion is declared, never an absence and never indefinite.
#
# Usage: bash scripts/check_runner_reach.sh
set -uo pipefail
cd "$(dirname "$0")/.."
REGISTRY="test/units.list"

[ -f "$REGISTRY" ] || { echo "check_runner_reach: no $REGISTRY" >&2; exit 1; }

rows=$(grep -vE '^\s*(#|$)' "$REGISTRY")
ids=$(printf '%s\n' "$rows" | cut -d'|' -f1)
cmds=$(printf '%s\n' "$rows" | cut -d'|' -f5-)

rc=0

dupes=$(printf '%s\n' "$ids" | sort | uniq -d)
if [ -n "$dupes" ]; then
    echo "check_runner_reach: duplicate ids:" >&2
    printf '  %s\n' $dupes >&2
    rc=1
fi

# Scripts a contributor could plausibly invoke. Libraries (sourced, never run)
# and the registry's own front door are excluded by name.
mapfile -t runnable < <(
    ls scripts/check_*.sh scripts/*gate*.sh scripts/perf.sh scripts/verify_projects.sh \
       scripts/mutation/run.sh scripts/zone_check.sh scripts/binary_size_report.sh \
       bench/*.sh test/golden/run.sh test/clj/run_tier_a.sh 2>/dev/null | sort -u
)

missing=""
for s in "${runnable[@]}"; do
    grep -qF -- "$s" <<<"$cmds" || missing="$missing $s"
done
if [ -n "$missing" ]; then
    echo "check_runner_reach: runnable but unregistered — add a row to $REGISTRY:" >&2
    printf '  %s\n' $missing >&2
    rc=1
fi

# A row must name a file that exists, or the registry is lying about coverage.
gone=""
while IFS= read -r c; do
    for tok in $c; do
        case "$tok" in
            scripts/*|test/*|bench/*)
                [ -e "$tok" ] || gone="$gone $tok" ;;
        esac
    done
done <<< "$cmds"
if [ -n "$gone" ]; then
    echo "check_runner_reach: registry names files that do not exist:" >&2
    printf '  %s\n' $gone >&2
    rc=1
fi

# An exclusion carries a SETTLED kind (hook / authoring / on-demand / dormant /
# timing / measurement / network / config / internal / meta / via-gate), or the
# script goes. `todo:` is the unsettled tag, and it fails here rather than
# being reported and lived with — the count reached zero on 2026-08-18 and a
# report nobody has to act on is how it got to twelve.
todo=$(printf '%s\n' "$rows" | awk -F'|' '$4 ~ /todo/ {print "  " $1 "  (" $4 ")"}')
if [ -n "$todo" ]; then
    echo "check_runner_reach: $(printf '%s\n' "$todo" | wc -l | tr -d ' ') unresolved exclusion(s) tagged todo:" >&2
    printf '%s\n' "$todo" >&2
    echo "  Resolve each: gate it (gated=yes), delete the script, or give it a" >&2
    echo "  settled kind — the registry header lists them." >&2
    rc=1
fi

if [ "$rc" -eq 0 ]; then
    echo "check_runner_reach: $(printf '%s\n' "$ids" | wc -l | tr -d ' ') units, every runnable script registered"
fi
exit $rc
