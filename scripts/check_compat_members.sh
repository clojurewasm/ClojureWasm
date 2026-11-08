#!/usr/bin/env bash
# scripts/check_compat_members.sh — the compat_tiers member-truth gate
# (ADR-0174 D9, F-013 clause 3 / F-014 clause 2).
#
# data/compat_tiers.yaml's per-class `methods:` / `static_fields:` lists
# rotted in BOTH directions before ADR-0174 (Long/MAX_VALUE worked but was
# unlisted; MessageDigest/getInstance was listed but absent). A one-time
# refresh re-rots without a mechanical gate, so this script re-derives the
# code truth from `(cljw.internal/__dump-host-classes)` (every registered
# host descriptor's static fields + members, incl. the per-tag native
# descriptors that carry String/Long instance methods) and asserts, for
# every yaml class that declares a `files.surface`:
#
#   (a) every yaml-listed member EXISTS on the registered descriptor
#       (no over-claim — the D-177/MessageDigest lie class);
#   (b) every descriptor member is yaml-listed (no silent unlisted
#       member — the Long/MAX_VALUE rot class); `<init>` is exempt
#       (constructors are class_corpus territory, not the member list);
#   (c) no `opaque_members:` entry is actually implemented (an OPAQUE
#       row claims "deliberately absent" — implementing it must flip
#       the row back to `methods:`).
#
# Exit 0 = ledger honest; 1 = at least one drift, listed per class.

set -uo pipefail
cd "$(dirname "$0")/.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
command -v yq >/dev/null || { echo "check_compat_members: yq required" >&2; exit 1; }

run_bounded() {
    if command -v timeout >/dev/null 2>&1; then timeout 30 "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout 30 "$@"
    else "$@"; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

run_bounded "$BIN" -e '(print (cljw.internal/__dump-host-classes))' 2>/dev/null > "$tmp/dump.txt"
[ -s "$tmp/dump.txt" ] || { echo "check_compat_members: empty dump (cljw failed?)" >&2; exit 1; }

# Per-class member sets from the dump: "F name" and "M name" lines keyed by fqcn.
awk '$1=="F"||$1=="M"{print $2" "$3}' "$tmp/dump.txt" | sort -u > "$tmp/dump_members.txt"

# The yaml's surface-class universe (fqn + the three lists), one JSON per line.
yq -o=json -I=0 '[.. | select(has("fqn") and (.files.surface != null)) | {"fqn": .fqn, "methods": (.methods // []), "static_fields": (.static_fields // []), "opaque_members": (.opaque_members // [])}] | .[]' data/compat_tiers.yaml > "$tmp/classes.jsonl"

fails=0
while IFS= read -r row; do
    fqn=$(yq -p=json '.fqn' <<<"$row")
    # `.. style="double"`-free lists coerce TRUE/FALSE to booleans — read as raw strings.
    yq -p=json -o=tsv '[.methods[]] + [.static_fields[]] | map(. style="double")' <<<"$row" 2>/dev/null | tr '\t' '\n' | grep -v '^$' | sort -u > "$tmp/yaml_members.txt" || true
    yq -p=json -o=tsv '[.opaque_members[]] | map(. style="double")' <<<"$row" 2>/dev/null | tr '\t' '\n' | grep -v '^$' | sort -u > "$tmp/opaque.txt" || true
    # A native-backed class's instance methods live on the per-tag native
    # descriptor, dumped under its SIMPLE name (Pattern/UUID/String/…) —
    # union both keys for the class's code-truth set.
    simple="${fqn##*.}"
    # <init> (class_corpus territory) + the universal Object methods
    # (toString/equals/hashCode — dispatched generically, not per-class rows)
    # are exempt on BOTH sides.
    awk -v c="$fqn" -v s="$simple" '$1==c||$1==s{print $2}' "$tmp/dump_members.txt" | grep -vE '^(<init>|toString|equals|hashCode)$' | sort -u > "$tmp/code_members.txt" || true
    grep -vE '^(<init>|toString|equals|hashCode)$' "$tmp/yaml_members.txt" > "$tmp/yaml_members2.txt" || true
    mv "$tmp/yaml_members2.txt" "$tmp/yaml_members.txt"

    if ! grep -q "^CLASS $fqn\$" "$tmp/dump.txt"; then
        echo "DRIFT [$fqn] declared in compat_tiers.yaml but NOT registered in rt.types"
        fails=$((fails + 1))
        continue
    fi
    # (a) yaml ⊆ code
    over=$(comm -23 "$tmp/yaml_members.txt" "$tmp/code_members.txt")
    if [ -n "$over" ]; then
        echo "DRIFT [$fqn] listed but not implemented (over-claim): $(echo "$over" | tr '\n' ' ')"
        fails=$((fails + 1))
    fi
    # (b) code ⊆ yaml
    unlisted=$(comm -13 "$tmp/yaml_members.txt" "$tmp/code_members.txt")
    if [ -n "$unlisted" ]; then
        echo "DRIFT [$fqn] implemented but unlisted: $(echo "$unlisted" | tr '\n' ' ')"
        fails=$((fails + 1))
    fi
    # (c) opaque ∩ code = ∅
    both=$(comm -12 "$tmp/opaque.txt" "$tmp/code_members.txt")
    if [ -n "$both" ]; then
        echo "DRIFT [$fqn] OPAQUE row is actually implemented: $(echo "$both" | tr '\n' ' ')"
        fails=$((fails + 1))
    fi
done < "$tmp/classes.jsonl"

total=$(wc -l < "$tmp/classes.jsonl" | tr -d ' ')
# A broken/unparsable yaml yields an empty universe — that is a failure,
# not a vacuous pass (the first refresh attempt hit exactly this).
if [ "$total" -eq 0 ]; then
    echo "check_compat_members: 0 surface classes extracted — yaml broken?" >&2
    exit 1
fi
if [ "$fails" -gt 0 ]; then
    echo "check_compat_members: $fails drift(s) across $total surface classes" >&2
    exit 1
fi
echo "check_compat_members: ok — $total surface classes, member lists match the code"
