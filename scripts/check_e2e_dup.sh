#!/usr/bin/env bash
# Guard: no two test/e2e/*.sh scripts may be byte-identical.
#
# Incident 2026-05-31: phase14_hierarchy.sh was silently overwritten with a
# byte-copy of phase7_multimethod.sh (a botched edit in a later commit). The
# runner globs test/e2e/phase*.sh, so the gate ran phase7's suite twice and
# stayed green while the hierarchy feature lost ALL e2e coverage — a silent
# scaffold lie by the permanent_noop_forbidden standard. This check makes that
# whole class loud: a clobbered/templated e2e that only re-runs another suite
# now fails the gate instead of hiding inside a passing count.
#
# Uses `git hash-object` for content identity (same blob hash ⇒ identical
# bytes), falling back to `shasum` outside a git tree. bash 3.2 compatible
# (no associative arrays — macOS host runs the system bash).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$SCRIPT_DIR/../test/e2e"
cd "$E2E_DIR" || { echo "check_e2e_dup: cannot cd to $E2E_DIR" >&2; exit 1; }

hash_of() {
    git hash-object "$1" 2>/dev/null || shasum "$1" | awk '{print $1}'
}

sums=""
for f in *.sh; do
    [ -e "$f" ] || continue
    sums+="$(hash_of "$f") $f"$'\n'
done

dups="$(printf '%s' "$sums" | awk 'NF{print $1}' | sort | uniq -d)"
if [[ -n "$dups" ]]; then
    echo "check_e2e_dup: FAIL — byte-identical e2e scripts (a clobbered suite silently re-runs another):" >&2
    while IFS= read -r h; do
        [ -n "$h" ] || continue
        printf '%s' "$sums" | awk -v h="$h" '$1==h {print "    "$2}' >&2
    done <<< "$dups"
    echo "  Fill in the clobbered script with its real cases, or delete it." >&2
    exit 1
fi

count="$(printf '%s' "$sums" | awk 'NF' | wc -l | tr -d ' ')"
echo "check_e2e_dup: OK ($count scripts, all distinct)"
exit 0
