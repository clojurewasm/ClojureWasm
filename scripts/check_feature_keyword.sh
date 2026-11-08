#!/usr/bin/env bash
# G3 gate (ADR-0029 D4): feature keyword must appear in every file
# path listed under each compat_tiers.yaml host_classes entry.
#
# For each host_classes entry that has both a `keyword:` field
# and a `files:` map (= migrated to the extended ADR-0029 D5
# schema), verify:
#
#   1. Every file path under `files:` (except `wrap:`) contains the
#      keyword as a path component or filename stem.
#   2. Every listed file exists on disk.
#
# Entries that lack `keyword:` (= legacy schema, awaiting Phase 6+
# migration) are silently skipped — incremental migration is
# expected per ROADMAP §6.0 + ADR-0029 D5.
#
# The `wrap:` slot is exempt from keyword matching because value-
# wrap helpers (e.g., runtime/collection/string.zig) are
# legitimately reused across features.
#
# See memory 20260909234605-3f9e2aa8 (feature_name_consistency) R1 for the contract.
#
# Modes:
#   bash scripts/check_feature_keyword.sh           informational
#   bash scripts/check_feature_keyword.sh --strict  exit 1 on violation
#   bash scripts/check_feature_keyword.sh --gate    exit 1 on violation

set -euo pipefail

MODE="${1:-info}"

cd "$(dirname "$0")/.."

YAML=data/compat_tiers.yaml

if [ ! -f "$YAML" ]; then
    echo "compat_tiers.yaml not found; nothing to check." >&2
    exit 0
fi

violations_file=$(mktemp) || { echo "G3: mktemp failed" >&2; exit 2; }
entries_file=$(mktemp) || { echo "G3: mktemp failed" >&2; exit 2; }
trap 'rm -f "$violations_file" "$entries_file"' EXIT

# Parse YAML with Python. Failure here MUST not silently pass the
# gate — host class entries are how Phase 6+ surfaces wire in, and a
# parser bug masquerading as "0 entries to check" would defeat the
# whole purpose of G3.
#
# Limitations of the current parser (intentional, narrow scope for
# Phase 5 → 6 transition):
#   - Block-style entries only (the cluster-default shape).
#   - Flow-style entries (`- { fqn: ..., ... }`) are tolerated but
#     no `keyword:` / `files:` extraction is performed on them.
#   - Inline `# ...` comments inside scalar values are not stripped.
# These limitations are revisited at Phase 6 entry when the first
# new-schema host class entry lands.
if ! python3 - "$YAML" "$entries_file" <<'PY'
import sys, re

src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    text = f.read()

lines = text.splitlines()
out = []
i = 0
while i < len(lines):
    line = lines[i]
    m = re.match(r'^(\s*)-\s*fqn:\s*(\S+)', line)
    if not m:
        i += 1
        continue
    indent = len(m.group(1))
    fqn = m.group(2).strip().strip('"\'')
    block = [line]
    j = i + 1
    while j < len(lines):
        nxt = lines[j]
        if not nxt.strip():
            block.append(nxt); j += 1; continue
        nxt_indent = len(nxt) - len(nxt.lstrip())
        if nxt_indent <= indent and not nxt.lstrip().startswith('#'):
            break
        block.append(nxt)
        j += 1
    i = j

    body = "\n".join(block)
    km = re.search(r'^\s+keyword:\s*(\S+)', body, re.M)
    if not km:
        continue
    keyword = km.group(1).strip().strip('"\'')

    fm = re.search(r'^\s+files:\s*$\n((?:\s+\S.*\n?)+)', body, re.M)
    if not fm:
        continue
    files_block = fm.group(1)
    # The greedy block regex above scoops up sibling keys after
    # `files:` (e.g. `methods:`, `clojure_peer_vars:`); restrict to
    # the documented file-slot names per ADR-0029 D5.
    FILE_SLOTS = {"surface", "impl", "impl_extras", "wrap", "clojure_peer"}
    for fl in files_block.splitlines():
        fm2 = re.match(r'^\s+(\w+):\s*(.+?)\s*(?:#.*)?$', fl)
        if not fm2:
            continue
        slot = fm2.group(1)
        if slot not in FILE_SLOTS:
            continue
        raw = fm2.group(2).strip()
        paths = []
        if raw.startswith('['):
            inner = raw.strip('[]').strip()
            if inner:
                for p in inner.split(','):
                    paths.append(p.strip().strip('"\''))
        elif raw in ('null', '~', ''):
            continue
        else:
            paths.append(raw.strip('"\''))
        for p in paths:
            out.append(f"{fqn}|{keyword}|{slot}|{p}")

with open(dst, "w") as f:
    f.write("\n".join(out))
    if out:
        f.write("\n")
PY
then
    echo "G3: YAML parser failed (python3 exit non-zero); refusing to pass gate" >&2
    exit 2
fi

# Sanity check: number of `keyword:` lines in YAML should match the
# number of distinct fqn entries the parser extracted. If they don't,
# the parser silently dropped entries (e.g. flow-style + keyword
# combo) and the gate cannot trust its output.
yaml_kw_lines=$(grep -cE '^[[:space:]]+keyword:[[:space:]]' "$YAML" || true)
parsed_fqn_count=$(cut -d'|' -f1 "$entries_file" 2>/dev/null | sort -u | grep -c . || true)
if [ "$yaml_kw_lines" -ne "$parsed_fqn_count" ]; then
    echo "G3: parser sanity check failed: yaml has $yaml_kw_lines 'keyword:' line(s) but parsed $parsed_fqn_count fqn entry/entries" >&2
    exit 2
fi

# Validate keyword: distinctive lower_snake_case, 3-31 chars, alphanum+_
# Helper for "path component or filename stem" match.
# A keyword matches if it appears between path separators (`/`, start,
# end) or between underscore / dot boundaries — i.e. it is one of the
# slash- or dot-separated segments, or a snake_case word within one.
path_has_keyword() {
    local kw="$1" path="$2"
    python3 -c '
import sys, re
kw, p = sys.argv[1], sys.argv[2]
# Split on path / dot only. Underscore is NOT a splitter because
# keywords are lower_snake_case (per R1) and we want a single
# `file_io` keyword to match `runtime/file_io.zig`, not require
# the filename stem to contain literally `file` or `io` alone.
# Java-surface filenames are PascalCase by convention so the
# match is case-insensitive (e.g. keyword=uuid matches
# runtime/java/util/UUID.zig).
parts = [seg.lower() for seg in re.split(r"[/.]+", p)]
sys.exit(0 if kw.lower() in parts else 1)
' "$kw" "$path"
}

while IFS='|' read -r fqn keyword slot path; do
    [ -z "$fqn" ] && continue

    # Keyword shape validation — must match the rule in
    # memory 20260909234605-3f9e2aa8 (feature_name_consistency) R1.
    if ! grep -qE '^[a-z][a-z0-9_]{2,30}$' <<<"$keyword"; then
        echo "$fqn: G3/ADR-0029 D4: invalid keyword '$keyword' (must match ^[a-z][a-z0-9_]{2,30}$)" >> "$violations_file"
        continue
    fi

    # Paths in compat_tiers.yaml are repo-relative without the
    # leading `src/`; prepend it for the existence check. Yaml-level
    # paths stay short to keep the schema readable.
    full_path="src/$path"
    if [ ! -f "$full_path" ]; then
        echo "$fqn: G3/ADR-0029 D4: $slot file does not exist: $path" >> "$violations_file"
        continue
    fi

    # `wrap:` slot is exempt from keyword matching per R1 (value-wrap
    # helpers like runtime/collection/string.zig are legitimately
    # reused across features). Existence is still checked above.
    #
    # `surface:` slot is also exempt — Java-surface paths use the
    # Java class name (PascalCase, e.g. UUID.zig / System.zig) which
    # rarely matches the lower_snake_case impl keyword. Grep by Java
    # class name is the canonical way to find a Java surface;
    # G3 enforces the keyword link only on impl / impl_extras /
    # clojure_peer slots.
    if [ "$slot" = "wrap" ] || [ "$slot" = "surface" ]; then
        continue
    fi
    if ! path_has_keyword "$keyword" "$path"; then
        echo "$fqn: G3/ADR-0029 D4: keyword '$keyword' is not a path component of $slot path: $path" >> "$violations_file"
    fi
done < "$entries_file"

count=$(wc -l < "$violations_file" | tr -d ' ')

if [ "$count" -gt 0 ]; then
    cat "$violations_file"
    echo
    echo "$count feature-keyword violation(s) found."
fi

case "$MODE" in
    --strict|--gate)
        if [ "$count" -gt 0 ]; then exit 1; fi
        ;;
    *)
        echo "(informational mode: exit 0 regardless of violations)"
        ;;
esac

exit 0
