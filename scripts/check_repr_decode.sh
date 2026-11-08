#!/usr/bin/env bash
# scripts/check_repr_decode.sh — collection representation-encapsulation guard.
#
# Born from Discussion #12: `valueSetToForm` decoded a set's backing map as an
# ArrayMap unconditionally, so a 9+-element set literal (promoted to a HashMap
# backing) segfaulted macroexpansion. The same misread was then found live in
# multimethod hierarchy dispatch (silently gone at the 9th defmethod), the
# http client (9-entry :headers rejected) and the http server (>8 response
# headers dropped). One bug, five sites, three symptom faces.
#
# The class: code OUTSIDE src/runtime/collection/ decoding a collection's
# backing-representation struct directly. The representation (array vs HAMT,
# promotion boundaries) is the collection module's private business; everyone
# else iterates via the generic accessors (`map.forEachEntry`,
# `set.forEachElem`, `count`, `get`, …), which handle every backing.
#
# What it does:
#   1. HARD: flag any `decodePtr(*const <mod>.<ReprStruct>)` outside
#      src/runtime/collection/ whose line (or the line above) does not carry a
#      `repr-decode-ok:` waiver. Violations beyond BASELINE fail --gate.
#   2. WARN (informational, never fails): a lone one-representation tag test
#      (`== .array_map` with no `hash_map` nearby) — the guard-shape that is
#      memory-safe but drops semantics past the promotion boundary.
#
# Waiver form (line above or same line; keep it greppable):
#   // repr-decode-ok: <why this site may know the representation> [refs: …]
#
# Modes:
#   bash scripts/check_repr_decode.sh           informational; always exits 0
#   bash scripts/check_repr_decode.sh --strict  exit 1 on any violation
#   bash scripts/check_repr_decode.sh --gate    exit 1 if violations > BASELINE

set -euo pipefail

BASELINE=0
MODE="${1:-info}"

cd "$(dirname "$0")/.."

# Representation structs private to src/runtime/collection/. Matching on the
# TYPE name (not the import alias) is deliberate: files alias the module as
# map_collection / map_mod / set_mod / …, but the struct names are unique in
# the tree today.
REPR_TYPES='ArrayMap|PersistentHashMap|HamtMapNode|HashCollisionMapNode|PersistentHashSet|SortedMap|SortedSet|RbNode|Vector|TailNode|HamtNode'

violations=0
while IFS= read -r hit; do
    file="${hit%%:*}"
    rest="${hit#*:}"
    line="${rest%%:*}"
    # Waiver on the flagged line or the line above.
    if sed -n "$((line > 1 ? line - 1 : 1)),${line}p" "$file" | grep -q 'repr-decode-ok:'; then
        continue
    fi
    echo "REPR-DECODE: $hit"
    violations=$((violations + 1))
done < <(grep -rnE "decodePtr\(\*(const )?[A-Za-z_]+\.(${REPR_TYPES})\)" src \
           --include='*.zig' | grep -v '^src/runtime/collection/' || true)

if [ "$violations" -gt 0 ]; then
    echo "check_repr_decode: $violations un-waived representation decode(s) outside src/runtime/collection/."
    echo "  Iterate via the generic accessors (map.forEachEntry / set.forEachElem / count / get)"
    echo "  — they handle every backing, incl. past the ArrayMap→HashMap promotion at 9 entries."
    echo "  A site that legitimately must know the representation takes an inline waiver:"
    echo "    // repr-decode-ok: <why> [refs: …]"
else
    echo "check_repr_decode: no un-waived representation decodes outside src/runtime/collection/"
fi

# Secondary, WARN-only: single-representation tag tests with no dual-backing
# awareness on the same line. Catches the guard-shape (semantics silently
# dropped past promotion) once the decode itself is gone. Deliberately not a
# gate: printers/serializers legitimately scope by tag.
warns=$(grep -rnE '[=!]= *\.array_map' src --include='*.zig' \
    | grep -v '^src/runtime/collection/' | grep -v 'hash_map' | grep -v 'repr-decode-ok:' || true)
if [ -n "$warns" ]; then
    echo
    echo "WARN (informational) — lone .array_map tag tests (no hash_map on the line):"
    printf '%s\n' "$warns" | sed 's/^/  /'
fi

case "$MODE" in
    --strict) [ "$violations" -eq 0 ] || exit 1 ;;
    --gate)   [ "$violations" -le "$BASELINE" ] || exit 1 ;;
    *) ;;
esac
exit 0
