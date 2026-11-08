#!/usr/bin/env bash
# check_release_deps.sh — normal/release build configuration is offline-safe.
#
# `--system` disables package fetching. Fresh local/global caches make this a
# real cold configure rather than a cached build-script replay. If build.zig
# ever eagerly imports a development dependency again, this command fails
# before printing its help (CLJW-RELEASE-FETCH).

set -euo pipefail

cd "$(dirname "$0")/.."

scratch=$(mktemp -d "${TMPDIR:-/tmp}/cljw-release-deps.XXXXXX")
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT

mkdir -p "$scratch/system" "$scratch/local-cache" "$scratch/global-cache"

zig build \
    --system "$scratch/system" \
    --cache-dir "$scratch/local-cache" \
    --global-cache-dir "$scratch/global-cache" \
    --help >/dev/null

echo "    release_deps: cold default build configured with package fetching disabled"
