#!/usr/bin/env bash
# scripts/check_accepted_divergences.sh
#
# Auto-defense for the accepted-clj-divergence SSOT (.dev/accepted_divergences.yaml).
# An "accepted divergence" is a behaviour where cljw INTENTIONALLY differs from
# JVM Clojure (rule: memory 20260909234822-74759eeb (accepted_divergences)). This gate makes the
# ledger trustworthy so a divergence cannot (a) be added without a justification
# or (b) drift out of sync with the docs / its pinning test.
#
# Checks:
#   1. SSOT is well-formed YAML with a non-empty `accepted:` list.
#   2. Every entry has a non-empty `derives_from` (no lazy "just accept it").
#   3. Every entry's `pin` test path(s) exist (locks the divergent cljw
#      behaviour against accidental change). Entries whose pin starts with
#      "none" are exempt (value-dependent / identity-hash cases).
#   4. COVERAGE.md's "Acceptable divergences" section points at this SSOT
#      (no duplicated prose list that could drift).
#
# Informational by default (exit 0). Pass --gate to exit 1 on a violation.
set -euo pipefail
cd "$(dirname "$0")/.."

SSOT=.dev/accepted_divergences.yaml
COVERAGE=test/diff/clj_corpus/COVERAGE.md
gate=0
[ "${1:-}" = "--gate" ] && gate=1
bad=0

if [ ! -f "$SSOT" ]; then
  echo "check_accepted_divergences: MISSING $SSOT"
  [ "$gate" = 1 ] && exit 1
  exit 0
fi

# 1. Well-formed + non-empty.
n=$(yq -r '.accepted | length' "$SSOT" 2>/dev/null || echo "ERR")
if [ "$n" = "ERR" ] || [ -z "$n" ]; then
  echo "check_accepted_divergences: $SSOT is not well-formed YAML"
  [ "$gate" = 1 ] && exit 1
  exit 0
fi
if [ "$n" -lt 1 ]; then
  echo "check_accepted_divergences: $SSOT has an empty accepted: list"
  bad=1
fi

ids=$(yq -r '.accepted[].id' "$SSOT" 2>/dev/null || true)
for id in $ids; do
  # 2. derives_from present.
  df=$(ID="$id" yq -r '.accepted[] | select(.id == env(ID)) | .derives_from // ""' "$SSOT" 2>/dev/null || true)
  if [ -z "${df// /}" ]; then
    echo "check_accepted_divergences: $id has no derives_from (every accepted divergence needs a justifying invariant/ADR)"
    bad=1
  fi
  # 3. pin paths exist (skip "none ..." pins).
  pin=$(ID="$id" yq -r '.accepted[] | select(.id == env(ID)) | .pin // ""' "$SSOT" 2>/dev/null || true)
  case "$pin" in
    none*|None*|NONE*) : ;;  # value-dependent / identity — exempt by design
    *)
      # Verify each path-looking token (test/...{.txt,.sh,.zig,.clj}) exists.
      # `.clj` is in the list because pins are migrating to cljw-native
      # clojure.test suites (test/clj/suites/*.clj). Without it a repointed pin
      # extracts ZERO paths, the loop below never runs, and the divergence
      # silently degrades from "pinned and verified" to "pinned in prose" —
      # a vacated check that reports success.
      for p in $(printf '%s\n' "$pin" | grep -oE '[A-Za-z0-9_./-]+\.(txt|sh|zig|clj)' || true); do
        if [ ! -e "$p" ]; then
          echo "check_accepted_divergences: $id pin path does not exist: $p"
          bad=1
        fi
      done
      ;;
  esac
done

# 4. COVERAGE.md points at the SSOT (no drifting duplicate prose list).
if [ -f "$COVERAGE" ]; then
  if ! grep -q 'accepted_divergences.yaml' "$COVERAGE"; then
    echo "check_accepted_divergences: $COVERAGE 'Acceptable divergences' must point at $SSOT (it is the SSOT)"
    bad=1
  fi
fi

if [ "$bad" = 1 ]; then
  echo "check_accepted_divergences: VIOLATIONS found (see above)"
  [ "$gate" = 1 ] && exit 1
  exit 0
fi
echo "check_accepted_divergences: ok — $n accepted divergence(s), all justified + pinned + in sync"
