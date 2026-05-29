#!/usr/bin/env bash
# Zone dependency checker.
#
# Enforces the layering rules in .claude/rules/zone_deps.md:
#   Layer 0 (runtime/) must NOT import from Layer 1+ (eval/, lang/, modules/, app/)
#   Layer 1 (eval/)    must NOT import from Layer 2+ (lang/, modules/, app/)
#   Layer 2 (lang/)    must NOT import from Layer 3 (app/)
#
# Plus the ADR-0029 D2 surface rule (G1):
#   Any file under runtime/ that is NOT in runtime/java/** or
#   runtime/cljw/** must NOT import from runtime/java/** or
#   runtime/cljw/**.  Surface layers call the neutral impl layer;
#   the reverse is forbidden.
#
# Modes:
#   bash scripts/zone_check.sh           informational; always exits 0
#   bash scripts/zone_check.sh --strict  exit 1 on any violation
#   bash scripts/zone_check.sh --gate    exit 1 if violations exceed BASELINE
#
# Test blocks (everything after the first `test "..."` line in a file)
# are skipped — test code may legitimately cross zones.

set -euo pipefail

BASELINE=0
MODE="${1:-info}"

cd "$(dirname "$0")/.."

# Sets ZONE to the layer number (0-3), or "x" for out-of-tree paths.
# Returns via a global (not stdout) so callers avoid a subshell fork
# per import — the inner loop runs ~hundreds of times.
zone_of() {
    case "$1" in
        src/runtime/*)            ZONE=0 ;;
        src/eval/*)               ZONE=1 ;;
        src/lang/*)               ZONE=2 ;;
        src/app/*|src/main.zig)   ZONE=3 ;;
        modules/*)                ZONE=2 ;;
        *)                        ZONE="x" ;;
    esac
}

# Collapses '.' / '..' segments in "$1"; result (repo-root-relative,
# equivalent to the former `cd … && pwd | realpath --relative-to`
# dance) in the global NORM. Pure bash — no subshell forks. The old
# form forked echo/sed/dirname/cd/pwd/realpath PER import (~hundreds),
# which cost ~15s over the tree; this brings the scan under ~1s.
# (Relies on bash word-splitting on IFS=/, so this script is bash-only.)
normalize_path() {
    local seg oldIFS="$IFS"
    local -a out=()
    IFS='/'
    for seg in $1; do
        case "$seg" in
            ''|.) ;;
            ..) [ "${#out[@]}" -gt 0 ] && unset 'out[${#out[@]}-1]' ;;
            *)  out+=("$seg") ;;
        esac
    done
    IFS="$oldIFS"
    NORM=""
    for seg in "${out[@]}"; do NORM="$NORM/$seg"; done
    NORM="${NORM#/}"
}

violations_file=$(mktemp)
trap "rm -f $violations_file" EXIT

# `find` returns 0 even when no files match; `|| true` is for safety.
files="$(find src modules -name '*.zig' 2>/dev/null || true)"

for file in $files; do
    zone_of "$file"; src_zone="$ZONE"
    [ "$src_zone" = "x" ] && continue
    file_dir="${file%/*}"

    # One awk pass per file: stop at the first `test "…"` line (test
    # code may legitimately cross zones), emit only `.zig` @import lines
    # as `NR:content`. Path resolution + zone math is pure bash below.
    while IFS= read -r entry; do
        lineno="${entry%%:*}"
        content="${entry#*:}"
        [[ "$content" =~ @import\(\"([^\"]+)\"\) ]] || continue
        import_path="${BASH_REMATCH[1]}"
        case "$import_path" in
            std|builtin) continue ;;
        esac

        # Resolve the imported file relative to the importing file.
        normalize_path "$file_dir/$import_path"
        rel="$NORM"

        zone_of "$rel"; tgt_zone="$ZONE"
        [ "$tgt_zone" = "x" ] && continue

        if [ "$src_zone" -lt "$tgt_zone" ]; then
            echo "$file:$lineno: zone $src_zone imports zone $tgt_zone ($import_path)" \
                >> "$violations_file"
        fi

            # G1 (ADR-0029 D2): runtime/ non-surface importing surface
            case "$file" in
                src/runtime/java/*|src/runtime/cljw/*) ;;  # surface itself: OK
                src/runtime/*)
                    case "$rel" in
                        src/runtime/java/*|src/runtime/cljw/*)
                            echo "$file:$lineno: G1/ADR-0029 D2: non-surface runtime/ imports surface ($import_path)" \
                                >> "$violations_file"
                            ;;
                    esac
                    ;;
            esac

            # G1 (ADR-0029 D2): lang/primitive/ must not call surface
            # (must reach the shared neutral impl directly per F-009).
            case "$file" in
                src/lang/primitive/*)
                    case "$rel" in
                        src/runtime/java/*|src/runtime/cljw/*)
                            echo "$file:$lineno: G1/ADR-0029 D2/F-009: lang/primitive imports surface ($import_path)" \
                                >> "$violations_file"
                            ;;
                    esac
                    ;;
            esac

            # §9.11 row 9.1: modules/ MUST NOT import lang/ or app/
            # (zone_deps.md rule + ROADMAP §A1). Layer-number arithmetic
            # alone treats modules and lang as peers at layer 2; the
            # explicit forbid lives here.
            case "$file" in
                modules/*)
                    case "$rel" in
                        src/lang/*|src/app/*|src/main.zig)
                            echo "$file:$lineno: zone_deps.md: modules/ imports forbidden zone ($import_path)" \
                                >> "$violations_file"
                            ;;
                    esac
                    ;;
            esac

            # G1 (ADR-0029 D2): cross-surface horizontal calls
            case "$file" in
                src/runtime/java/*)
                    case "$rel" in
                        src/runtime/cljw/*)
                            echo "$file:$lineno: G1/ADR-0029 D2: java/ imports cljw/ ($import_path)" \
                                >> "$violations_file"
                            ;;
                    esac
                    ;;
                src/runtime/cljw/*)
                    case "$rel" in
                        src/runtime/java/*)
                            echo "$file:$lineno: G1/ADR-0029 D2: cljw/ imports java/ ($import_path)" \
                                >> "$violations_file"
                            ;;
                    esac
                    ;;
            esac
    done < <(awk '/^test "/{exit} /@import\("[^"]+\.zig"\)/{print NR ":" $0}' "$file")
done

count=$(wc -l < "$violations_file" | tr -d ' ')

if [ "$count" -gt 0 ]; then
    cat "$violations_file"
    echo
    echo "$count zone violation(s) found."
fi

case "$MODE" in
    --strict)
        if [ "$count" -gt 0 ]; then exit 1; fi
        ;;
    --gate)
        if [ "$count" -gt "$BASELINE" ]; then
            echo "Gate failed: $count > BASELINE=$BASELINE" >&2
            exit 1
        fi
        ;;
    *)
        echo "(informational mode: exit 0 regardless of violations)"
        ;;
esac

exit 0
