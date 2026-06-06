#!/usr/bin/env bash
# G4 gate (ADR-0102, F-013): the deftype/reify host-supertype marker set is a
# closed-set SSOT, not a hand-grown allowlist. Enforces that recognition in code
# cannot grow library-by-library (the 個別最適化 entry F-013 clause 3 forbids).
#
# SSOT-of-record: host_interfaces.yaml (reviewable closed set + derives_from).
# Single in-code read point: src/runtime/host_interface.zig (a StaticStringMap).
#
# Checks:
#   (i)  set-bound  — every name recognised in host_interface.zig has a row in
#        host_interfaces.yaml (so a name cannot be recognised without a closed-
#        set row whose derives_from justifies it as language-defined).
#   (ii) over-claim — every host_interfaces.yaml row marked `recognised: true`
#        is actually present in the code table (no row claiming coverage it
#        lacks — the anti-D-177 false-positive discipline).
#   (iii) no floating wire — every method with `status: wired` names a
#        non-empty `wires_to` (a wired method must point at a real surface).
#
# See .dev/decisions/0102_host_interface_ssot.md + F-013 + .dev/principle.md
# "Ad-hoc-pass smell".
#
# Modes:
#   bash scripts/check_host_interface.sh           informational
#   bash scripts/check_host_interface.sh --strict  exit 1 on violation
#   bash scripts/check_host_interface.sh --gate    exit 1 on violation

set -euo pipefail

MODE="${1:-info}"
cd "$(dirname "$0")/.."

YAML=host_interfaces.yaml
ZIG=src/runtime/host_interface.zig

fail=0
note() { echo "host_interface: $*"; }

if [ ! -f "$YAML" ] || [ ! -f "$ZIG" ]; then
    echo "host_interface SSOT or module missing ($YAML / $ZIG)." >&2
    exit 1
fi
if ! command -v yq >/dev/null 2>&1; then
    echo "host_interface: yq not found; skipping (install mikefarah yq)." >&2
    exit 0
fi

# Names recognised in code: the StaticStringMap keys in the MARKERS block.
code_names=$(sed -n '/const MARKERS = /,/^});/p' "$ZIG" \
    | grep -oE '\.\{ "[^"]+"' | grep -oE '"[^"]+"' | tr -d '"' | sort -u)

# Names + recognised-rows in the SSOT.
yaml_names=$(yq -r '.interfaces[].name' "$YAML" | sort -u)
yaml_recognised=$(yq -r '.interfaces[] | select(.recognised == true) | .name' "$YAML" | sort -u)

# (i) set-bound: code ⊆ yaml.
while IFS= read -r n; do
    [ -z "$n" ] && continue
    if ! grep -qxF "$n" <<<"$yaml_names"; then
        note "VIOLATION (set-bound): code recognises '$n' but it has no row in $YAML."
        fail=1
    fi
done <<<"$code_names"

# (ii) over-claim: every recognised:true row is in code.
while IFS= read -r n; do
    [ -z "$n" ] && continue
    if ! grep -qxF "$n" <<<"$code_names"; then
        note "VIOLATION (over-claim): $YAML row '$n' is recognised:true but absent from the $ZIG table."
        fail=1
    fi
done <<<"$yaml_recognised"

# (iii) route soundness: every `status: wired` method must name a real route —
#   - a protocol_remap target (`wires_to_protocol`) that EXISTS as a cljw
#     `(defprotocol …)` (the anti-個別最適化 lever: a name cannot be recognised
#     without a generic protocol behind it), OR
#   - a method-family description (`wires_to`, e.g. Object/toString → str consult).
# A wired method with neither is a floating wire.
wired=$(yq -r '.interfaces[] as $i | ($i.methods // {}) | to_entries[] | select(.value.status == "wired") | ($i.name + "|" + .key + "|" + (.value.wires_to_protocol // "") + "|" + (.value.wires_to // ""))' "$YAML" 2>/dev/null || true)
if [ -n "$wired" ]; then
    while IFS='|' read -r iname mname wproto wdesc; do
        [ -z "$iname" ] && continue
        if [ -n "$wproto" ]; then
            if ! grep -rqE "\(defprotocol[[:space:]]+$wproto([[:space:]]|\()" src/lang/clj/ 2>/dev/null; then
                note "VIOLATION (route-soundness): $iname/$mname wires to protocol '$wproto' which is not a (defprotocol …) in src/lang/clj/."
                fail=1
            fi
        elif [ -z "$wdesc" ]; then
            note "VIOLATION (floating-wire): $iname/$mname is status:wired but names no wires_to_protocol or wires_to."
            fail=1
        fi
    done <<<"$wired"
fi

if [ "$fail" -eq 0 ]; then
    note "OK — $(wc -w <<<"$code_names" | tr -d ' ') recognised name(s) ⊆ $(wc -l <<<"$yaml_names" | tr -d ' ') SSOT row(s); no over-claim; no floating wire."
fi

if [ "$fail" -ne 0 ] && { [ "$MODE" = "--gate" ] || [ "$MODE" = "--strict" ]; }; then
    exit 1
fi
exit 0
