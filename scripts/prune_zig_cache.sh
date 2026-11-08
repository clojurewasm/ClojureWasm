#!/usr/bin/env bash
# prune_zig_cache.sh — keep the Zig build cache under a size cap before it is
# saved, so "always cache" does not become "cache grows forever".
#
#   bash scripts/prune_zig_cache.sh              # prune to the default cap
#   ZIG_CACHE_CAP_MB=1200 bash scripts/prune_zig_cache.sh
#   bash scripts/prune_zig_cache.sh --dry-run    # report, delete nothing
#
# WHY
# CI saves `.zig-cache` on every run (see .github/workflows/ci.yml — the key
# carries the run id so each run's build products survive, including a red
# run's). Zig never garbage-collects its own cache: each distinct build
# configuration writes a fresh `o/<hash>` directory and nothing ever removes
# one. Measured 2026-08-19: 40 entries, 465 MB, ~11.6 MB each, and a gate
# builds ~5 configurations. Left alone that is ~60 MB added per run — the
# cache would grow until it evicted every other cache in the repo's 10 GB
# budget, which is the bloat the caching was supposed to remove.
#
# SAFE BY CONSTRUCTION
# Zig's cache is content-addressed: a missing entry can only ever cause a
# REBUILD, never a wrong build. So the worst outcome of pruning too much is a
# slower run, and the worst outcome of a bug here is the status quo ante.
#
# POLICY
# Delete whole `o/<hash>` directories, oldest mtime first, until the tree fits
# the cap. `o/` is >95% of the bytes (465 MB of 490 MB); `h/`, `z/` and `c/`
# are small and are left alone. Entries are evicted by age rather than by use
# because Zig does not touch an entry it merely reads — there is no usage
# signal to sort on. A generous cap means eviction is rare, and when it does
# fire it costs one rebuild of a configuration nobody has built lately.
set -euo pipefail
cd "$(dirname "$0")/.."

CAP_MB="${ZIG_CACHE_CAP_MB:-1500}"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

CACHE=".zig-cache"
[ -d "$CACHE/o" ] || { echo "prune_zig_cache: no $CACHE/o — nothing to do"; exit 0; }

size_mb() { du -sm "$1" 2>/dev/null | cut -f1; }

# mtime, portably. Probe the flavour ONCE rather than trying GNU-then-BSD per
# call: GNU `stat -f %m X` prints filesystem info to STDOUT and only then exits
# non-zero, so a `stat -f … || stat -c …` chain does not fall through cleanly —
# it returns the fallback's output CONCATENATED after that noise. (That bug
# made this script's first draft read 240 "entries" out of 40 directories.)
if stat -c %Y . >/dev/null 2>&1; then
    mtime() { stat -c %Y "$1"; }          # GNU coreutils
else
    mtime() { stat -f %m "$1"; }          # BSD / macOS
fi

before=$(size_mb "$CACHE")
if [ "$before" -le "$CAP_MB" ]; then
    echo "prune_zig_cache: ${before} MB <= ${CAP_MB} MB cap — nothing to prune"
    exit 0
fi

echo "prune_zig_cache: ${before} MB > ${CAP_MB} MB cap — evicting oldest o/ entries"

# Oldest first. `find -printf` is GNU-only, so read mtime per entry portably.
freed=0
removed=0
# `sim` tracks what the tree WOULD measure after the removals so far, so a
# --dry-run reports the same set the real run deletes. Re-measuring the whole
# tree per iteration would work for the real run but never shrinks under
# --dry-run, and the report would then list every entry in the cache.
sim=$before
while IFS= read -r entry; do
    [ "$sim" -le "$CAP_MB" ] && break
    mb=$(size_mb "$entry")
    if [ "$DRY" -eq 1 ]; then
        echo "  would remove $entry (${mb} MB)"
    else
        rm -rf "$entry"
    fi
    sim=$(( sim - mb ))
    freed=$(( freed + mb ))
    removed=$(( removed + 1 ))
done < <(
    for d in "$CACHE"/o/*/; do
        [ -d "$d" ] || continue
        ts=$(mtime "$d" 2>/dev/null || echo 0)
        case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
        printf '%s\t%s\n' "$ts" "${d%/}"
    done | sort -n | cut -f2-
)

after=$(size_mb "$CACHE")
echo "prune_zig_cache: removed ${removed} entr$([ "$removed" -eq 1 ] && echo y || echo ies), ${before} MB -> ${after} MB"
