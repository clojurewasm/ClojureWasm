#!/usr/bin/env bash
# scripts/check_changelog_reachability.sh
#
# CHANGELOG.md is the release-history SSOT. Two ways it can lie:
#
# 1. A shipped release has no heading of its own. v1.14.9, v1.14.10 and
#    v1.14.11 appended their entries under `## [1.14.8]` and nothing noticed
#    (fixed by bba2e79f). Every `vX.Y.Z` tag reachable from HEAD, from v1.0.0
#    on, must have a `## [X.Y.Z] - YYYY-MM-DD` heading, and only untagged
#    releases between the newest tag and the version build.zig.zon names may
#    sit between `## [Unreleased]` and the newest tag's heading.
#
# 2. `[Unreleased]` describes something that has already shipped. An entry
#    that is also present in the newest tag's own `[Unreleased]` section went
#    out in that release while still reading as forthcoming.
#
# Both need the release tags. A clone without them (CI's shallow checkout)
# reports that and passes; the local gate, which has the tags, is where
# this bites.
#
# Informational by default (exit 0). Pass --gate to exit 1 on a violation.
set -euo pipefail
cd "$(dirname "$0")/.."

CHANGELOG=CHANGELOG.md
gate=0
[ "${1:-}" = "--gate" ] && gate=1

# Tags that shipped before this check existed and never got a heading; their
# entries were folded under the next heading that exists. Frozen: a new tag
# missing its heading is a violation, never a new row here.
HISTORIC_HEADINGLESS="1.10.7 1.10.8 1.10.9 1.10.10 1.10.11 1.10.12 1.10.13 1.10.15 1.10.17 1.13.4"

# The CHANGELOG starts at 1.0.0; the 0.x tags predate it.
HEADING_FLOOR="1.0.0"

violations=0

violation() {
  echo "check_changelog_reachability: VIOLATION -- $1" >&2
  violations=$((violations + 1))
}

if [ ! -f "$CHANGELOG" ]; then
  violation "$CHANGELOG is missing."
  [ "$gate" -eq 1 ] && exit 1
  exit 0
fi

release_tags="$(git tag --sort=-v:refname --merged HEAD 2>/dev/null \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)"
newest_tag="$(printf '%s\n' "$release_tags" | sed -n 1p)"

# ---- 1. every release tag has its own dated heading ------------------------

# Version of each `## [X.Y.Z] - YYYY-MM-DD` heading, in file order.
dated_headings="$(sed -nE 's/^## \[([0-9]+\.[0-9]+\.[0-9]+)\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$/\1/p' "$CHANGELOG")"
# Every `## ` heading after `## [Unreleased]`, verbatim, in file order.
headings_after_unreleased="$(awk '
  /^## \[Unreleased\]/ { seen = 1; next }
  seen && /^## / { print }
' "$CHANGELOG")"

if [ -z "$newest_tag" ]; then
  echo "check_changelog_reachability: ok, no release tag reachable from HEAD (shallow clone?), heading check skipped"
else
  missing=""
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    v="${tag#v}"
    # Below the floor: sort -V puts the smaller version first.
    [ "$(printf '%s\n%s\n' "$v" "$HEADING_FLOOR" | sort -V | sed -n 1p)" = "$v" ] \
      && [ "$v" != "$HEADING_FLOOR" ] && continue
    case " $HISTORIC_HEADINGLESS " in *" $v "*) continue ;; esac
    grep -qxF "$v" <<<"$dated_headings" || missing="$missing $tag"
  done <<< "$release_tags"

  if [ -n "$missing" ]; then
    violation "release tag(s) with no '## [X.Y.Z] - YYYY-MM-DD' heading:$missing"
    echo "  Give each shipped release its own heading, holding the entries it shipped." >&2
  fi

  newest_v="${newest_tag#v}"

  # A heading above the newest tag's names a release this clone has no tag
  # for: the pending one build.zig.zon names (stamped before the release
  # workflow tags it, which on a mirror races the CI run on the same merge),
  # or one a mirror never tagged (clojurewasm/ClojureWasm has no v1.15.2, its
  # release job failed first). Each must be dated, newer than the newest tag,
  # no newer than build.zig.zon, and untagged.
  pending_v="$(sed -nE 's/^[[:space:]]*\.version = "([0-9]+\.[0-9]+\.[0-9]+)",[[:space:]]*$/\1/p' build.zig.zon 2>/dev/null | sed -n 1p)"
  found_newest=0
  while IFS= read -r heading; do
    [ -n "$heading" ] || continue
    case "$heading" in
      "## [$newest_v] - "*) found_newest=1; break ;;
    esac
    hv="$(sed -nE 's/^## \[([0-9]+\.[0-9]+\.[0-9]+)\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$/\1/p' <<<"$heading")"
    if [ -n "$hv" ] && [ -n "$pending_v" ] \
      && ! git rev-parse -q --verify "refs/tags/v$hv" >/dev/null \
      && [ "$(printf '%s\n%s\n' "$newest_v" "$hv" | sort -V | sed -n 2p)" = "$hv" ] \
      && [ "$(printf '%s\n%s\n' "$hv" "$pending_v" | sort -V | sed -n 2p)" = "$pending_v" ]; then
      echo "check_changelog_reachability: ok, [$hv] is an untagged release between $newest_tag and build.zig.zon's $pending_v"
      continue
    fi
    violation "'$heading' sits above $newest_tag's dated heading but is not an untagged release between $newest_tag and build.zig.zon's ${pending_v:-<none>}."
    echo "  The newest release goes directly under [Unreleased]." >&2
    found_newest=1
    break
  done <<< "$headings_after_unreleased"
  if [ "$found_newest" -eq 0 ]; then
    violation "no '## [$newest_v] - YYYY-MM-DD' heading after [Unreleased]."
  fi
fi

# ---- 2. nothing under [Unreleased] has already shipped ----------------------

# Body of the `## [Unreleased]` section, content lines only. Blank lines and
# structural headings (including Added/Changed/Fixed) carry no release claim.
unreleased_body() {
  awk '
    /^## \[Unreleased\]/ { in_section = 1; next }
    /^## / { in_section = 0 }
    in_section && NF && $0 !~ /^[[:space:]]*#+[[:space:]]/ { print }
  '
}

head_body="$(unreleased_body < "$CHANGELOG")"

if [ -z "$head_body" ]; then
  echo "check_changelog_reachability: ok, [Unreleased] is empty, nothing can have shipped early"
elif [ -z "$newest_tag" ]; then
  echo "check_changelog_reachability: ok, no release tag reachable from HEAD to compare [Unreleased] against"
else
  tag_body="$(git show "${newest_tag}:${CHANGELOG}" 2>/dev/null | unreleased_body || true)"
  # Lines claimed as unreleased at HEAD that were ALREADY in the tag's
  # [Unreleased], i.e. they shipped in $newest_tag.
  shipped=""
  if [ -n "$tag_body" ]; then
    shipped="$(comm -12 \
      <(printf '%s\n' "$head_body" | sed 's/^[[:space:]]*//' | sort -u) \
      <(printf '%s\n' "$tag_body"  | sed 's/^[[:space:]]*//' | sort -u))"
  fi
  if [ -n "$shipped" ]; then
    count="$(printf '%s\n' "$shipped" | grep -c . || true)"
    violation "$count [Unreleased] line(s) already shipped in $newest_tag:"
    printf '%s\n' "$shipped" | sed -n 1,20p | sed 's/^/    /' >&2
    echo "  Move them under a '## [${newest_tag#v}]' heading (or the release they belong to)." >&2
  else
    echo "check_changelog_reachability: ok, no [Unreleased] entry has shipped in $newest_tag"
  fi
fi

if [ "$violations" -gt 0 ]; then
  [ "$gate" -eq 1 ] && exit 1
  exit 0
fi
[ -n "$newest_tag" ] && echo "check_changelog_reachability: ok, every release tag through $newest_tag has its own heading"
exit 0
