#!/usr/bin/env bash
# check_capability_claims.sh — every "we can do X" claim carries a status marker
# whose PLANNED form names a live debt owner (ADR-0177).
#
#   bash scripts/check_capability_claims.sh          # gate mode (default)
#   bash scripts/check_capability_claims.sh --list    # show every marker found
#
# Two invariants, both fail-closed:
#
#   1. Every `<!--claim:planned:D-NNN-->` marker names a debt id that EXISTS
#      and is still OPEN in `.dev/debt.yaml` (`active:` or `standing:`). A
#      planned claim whose owner was discharged is a claim with nobody left to
#      build it — which is how "planned" quietly becomes "abandoned, still
#      advertised".
#   2. The forbidden-phrase list does not appear UNMARKED in a claim-bearing
#      document. These are phrases the 2026-08-04 audit found asserting, in the
#      present tense, capabilities that do not exist.
#
# Why this exists (ADR-0177 / the 2026-08-04 cross-project audit): ROADMAP §1.1
# stated "runs on Cloudflare Workers / Fastly / Fermyon Spin" as a fact while
# `build.zig` had no `wasm32` target at all, §1.2 axis 1 called a Wasm Component
# "a first-class output" that was never built, and §10.3 set a cold-start target
# for that nonexistent artifact. Every one of those sentences sat outside any
# gate. Its sibling `binary_size_report.sh --check` covers NUMERIC claims; this
# covers CAPABILITY claims. Together they are the answer to zwasm's
# `2026-08-03-ungated-negative-doc-claim-rotted-into-a-lie` lesson.
#
# Deliberately NOT a general English-prose checker: it is a fixed, curated
# phrase list plus a marker-integrity check. A heuristic "does this sentence
# claim a capability?" scanner over a 1600-line ROADMAP would false-positive
# constantly and get disabled, which is worse than no gate.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=gate
[[ "${1:-}" == "--list" ]] && MODE=list

CLAIM_FILES="${CLAIM_FILES:-.dev/ROADMAP.md README.md docs/landscape.md}"
DEBT=.dev/debt.yaml

# Phrases that asserted an unbuilt capability in the present tense. Each entry
# is `pattern|why`. A document may still discuss the topic — it just may not
# assert it without a status marker on the same line.
FORBIDDEN=(
  'runs on Cloudflare Workers|cljw has no wasm32 build; it cannot run as a Wasm guest (D-552)'
  'compiles to WebAssembly itself|there is no wasm32 target in build.zig (D-552)'
  'makes Wasm Component a first-class output|cljw consumes components, it does not emit one (D-552)'
)

fail=0
found_markers=0

# --- invariant 1: planned markers name a live debt owner -------------------
while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    file="${hit%%:*}"
    rest="${hit#*:}"
    lineno="${rest%%:*}"
    id=$(grep -oE 'claim:planned:D-[0-9]+' <<<"$hit" | sed -n 1p | sed 's/claim:planned://')
    found_markers=$((found_markers + 1))
    [[ "$MODE" == list ]] && echo "    planned  $file:$lineno  -> $id"

    if ! grep -qE "^  - id: \"?$id\"?" "$DEBT"; then
        echo "capability_claims: $file:$lineno marks a claim planned under $id, but $id is not a row in $DEBT" >&2
        fail=1
        continue
    fi
    # An owner that has been discharged can no longer be the owner of a claim.
    if awk -v id="$id" '
        $0 ~ "^discharged:" { in_d = 1 }
        in_d && $0 ~ "^  - id: \"?" id "\"?" { print "yes"; exit }
    ' "$DEBT" | grep -q yes; then
        echo "capability_claims: $file:$lineno is planned under $id, but $id is DISCHARGED in $DEBT." >&2
        echo "  Either the capability shipped (mark it <!--claim:shipped-->) or it needs a live owner." >&2
        fail=1
    fi
done < <(grep -rn 'claim:planned:' $CLAIM_FILES 2>/dev/null || true)

if [[ "$MODE" == list ]]; then
    grep -rn 'claim:shipped' $CLAIM_FILES 2>/dev/null | while IFS= read -r hit; do
        echo "    shipped  ${hit%%:*}:$(printf '%s' "${hit#*:}" | cut -d: -f1)"
    done
    exit 0
fi

# --- invariant 2: no unmarked forbidden phrase -----------------------------
for entry in "${FORBIDDEN[@]}"; do
    pattern="${entry%%|*}"
    why="${entry#*|}"
    while IFS= read -r hit; do
        [[ -z "$hit" ]] && continue
        # A line that carries a status marker has been consciously classified.
        if grep -q 'claim:planned:\|claim:shipped' <<<"$hit"; then
            continue
        fi
        echo "capability_claims: unmarked capability claim — \"$pattern\"" >&2
        echo "  at $(printf '%s' "$hit" | cut -d: -f1-2)" >&2
        echo "  why it is wrong: $why" >&2
        echo "  Fix the sentence, or classify it on the same line with" >&2
        echo "  <!--claim:shipped--> / <!--claim:planned:D-NNN-->." >&2
        fail=1
    done < <(grep -rn "$pattern" $CLAIM_FILES 2>/dev/null || true)
done

if [[ "$fail" -ne 0 ]]; then
    exit 1
fi
echo "    capability_claims: ${found_markers} planned claim(s) have live debt owners; no unmarked forbidden phrase"
