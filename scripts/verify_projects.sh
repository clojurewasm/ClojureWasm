#!/usr/bin/env bash
# scripts/verify_projects.sh — real-world library regression sweep.
#
# Runs every test/conformance/verified_projects/<lib>/ through `cljw -M:verify` — the project's
# own deps.edn resolves the lib (git coordinates), and its `:verify` alias's
# `:main-opts ["-m" "verify"]` runs `verify/-main` (D-309 run mode). The
# PRESENCE of a
# test/conformance/verified_projects/<lib>/ dir is the committed claim "this library loads +
# works on cljw"; this script re-checks that claim, so a later change that
# breaks a previously-working lib is caught (the F-010 regression-detection
# role the convergence campaign Stage 1.3 / F-013 ladder feeds).
#
# NETWORK-DEPENDENT (git clone, cached under $CLJW_HOME/gitlibs) — so it is
# NOT part of the per-commit gate (test/run_all.sh). Run it on demand and at
# Phase boundaries (where network is available). The per-commit deps.edn
# mechanism test stays hermetic in test/e2e/phase14_deps_edn.sh (local bare
# repo). See test/conformance/verified_projects/README.md for the convention.
#
# Usage:  bash scripts/verify_projects.sh            # all projects
#         bash scripts/verify_projects.sh medley     # one project (by dir name)
set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib_cljw_bin.sh"
BIN="$PWD/zig-out/bin/cljw"
cljw_bin_require "$BIN" verify_projects
if ! command -v git >/dev/null 2>&1; then
    echo "SKIP verify_projects: git not on PATH (deps.edn :git/url needs git)"
    exit 0
fi
CACHE="${CLJW_HOME:-$HOME/.cljw}"
filter="${1:-}"
fails=0; n=0
for dir in test/conformance/verified_projects/*/; do
    name="$(basename "$dir")"
    [ -f "$dir/deps.edn" ] && [ -f "$dir/verify.clj" ] || continue
    [ -z "$filter" ] || [ "$filter" = "$name" ] || continue
    n=$((n + 1))
    if out="$(cd "$dir" && CLJW_HOME="$CACHE" timeout 180 "$BIN" -M:verify 2>&1)"; then
        msg="$(printf '%s' "$out" | grep '^OK' | tail -1)"
        echo "PASS $name -> ${msg:-ok}"
    else
        echo "FAIL $name"
        printf '%s\n' "$out" | tail -6 | sed 's/^/    /'
        fails=$((fails + 1))
    fi
done
echo "verified_projects: $((n - fails))/$n passed"
[ "$fails" -eq 0 ]
