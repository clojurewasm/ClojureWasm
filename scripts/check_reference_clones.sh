#!/usr/bin/env bash
# check_reference_clones.sh — every reference clone this repo CLAIMS is live
# must actually be there (D-565).
#
#   bash scripts/check_reference_clones.sh
#
# `.dev/reference_clones.md` is the SSOT for "read this codebase when surveying
# X". A Step-0 survey brief points a subagent at those paths; a path that is
# not there produces a survey that quietly skips its ground truth and reports
# success anyway. That is the failure this checks for.
#
# History: the 2026-07-28 onboarding audit found `~/Documents/OSS/zig/` listed
# as a live Zig-stdlib reference while being absent even on the maintainer
# machine — so the "confirm the idiom against the stdlib" step of every Zig
# survey had been dead for an unknown length of time. Sweeping for it by hand
# found two MORE (`wasmtime/`, `openjdk24/`), which is why this is a gate and
# not a one-off fix: the list rots silently, and only an executed check
# notices.
#
# Exemption: a path that is a RECIPE rather than a claim (clone it when you
# need it — a multi-GB repo nobody should keep resident) carries
# `<!--ref:on-demand-->` in its bullet, and must supply the clone command so
# the recipe is runnable. Exemptions are visible in the source and greppable.
#
# Skips entirely when `~/Documents/OSS` does not exist: a fresh clone by an
# external contributor has no reference clones by design, and the whole point
# of D-565 is that such a clone builds and tests green. This gate is a
# maintainer-side truth check, not an onboarding requirement.
set -euo pipefail
cd "$(dirname "$0")/.."

DOC=".dev/reference_clones.md"
ROOT="$HOME/Documents/OSS"
MARKER='<!--ref:on-demand-->'

if [[ ! -d "$ROOT" ]]; then
    echo "    reference_clones: skipped — $ROOT absent (fresh clone; reference clones are maintainer-side)"
    exit 0
fi

missing=0
ondemand=0
present=0

# A claim is a BULLET, not a line: the marker sits on the bullet's first line
# and the clone command on a continuation line under it. Join each bullet with
# its indented continuations so both are judged together.
while IFS=$'\t' read -r lineno block; do
    [[ -z "$lineno" ]] && continue
    while read -r claim; do
        [[ -z "$claim" ]] && continue
        dir="${claim/#\~/$HOME}"
        if [[ -e "$dir" ]]; then
            present=$((present + 1))
            continue
        fi
        if [[ "$block" == *"$MARKER"* ]]; then
            if [[ "$block" != *"git clone"* ]]; then
                echo "reference_clones: $DOC:$lineno marks $claim on-demand but gives no 'git clone' command." >&2
                echo "  An on-demand row is a RECIPE — without the command it is just a dead path with a note." >&2
                missing=$((missing + 1))
            else
                ondemand=$((ondemand + 1))
            fi
            continue
        fi
        missing=$((missing + 1))
        echo "reference_clones: $DOC:$lineno claims $claim as a live reference, but it does not exist." >&2
        echo "  → $(printf '%s' "$block" | sed 's/^[[:space:]]*//' | cut -c1-100)" >&2
    done < <(printf '%s\n' "$block" | grep -oE '~/Documents/OSS/[A-Za-z0-9._-]+' | sed 's|/$||' | sort -u)
done < <(awk '
    /^[^ \t]/ || /^- / {
        if (buf != "") print start "\t" buf
        buf = $0; start = NR; next
    }
    /^[ \t]+/ { buf = buf " " $0; next }
    { if (buf != "") print start "\t" buf; buf = ""; }
    END { if (buf != "") print start "\t" buf }
' "$DOC")

if [[ "$missing" -gt 0 ]]; then
    echo "  Fix by cloning it, deleting the claim, or marking the bullet $MARKER with a 'git clone' command." >&2
    echo "  Do not leave a survey pointed at a path that is not there." >&2
    exit 1
fi
echo "    reference_clones: ${present} live path(s) present, ${ondemand} on-demand recipe(s)"
