#!/usr/bin/env bash
# scripts/run_remote_ubuntu.sh — drive the cw v1 test/run_all.sh
# gate on the ubuntunote SSH host (native x86_64 Linux, real
# hardware).
#
# Replacement for the OrbStack `my-ubuntu-amd64` path retired
# per ADR-0049. Mirrors zwasm v2's
# `scripts/run_remote_ubuntu.sh`: `git fetch + reset --hard` the
# ubuntunote clone to the latest pushed `origin/main`,
# then run `nix develop --command bash test/run_all.sh`.
#
# Usage:
#   bash scripts/run_remote_ubuntu.sh                          # default: full gate on main
#   bash scripts/run_remote_ubuntu.sh --branch NAME            # gate an arbitrary branch (feature-branch verification)
#
# Prerequisites:
#   - SSH alias `ubuntunote` (see `.dev/ubuntunote_setup.md`).
#   - cw repository cloned at
#     `~/Documents/MyProducts/ClojureWasmFromScratch` with
#     `origin` pointing at `https://github.com/clojurewasm/ClojureWasm`.
#   - Nix (Determinate Systems installer) on ubuntunote so
#     `nix develop` reads the project's `flake.nix` and provides
#     Zig 0.16.0.
#
# Failure attribution: each remote step (preflight / sync /
# gate) emits a labelled `[run_remote_ubuntu] FAIL: <step>` line
# on stderr before exiting; the autonomous loop's log scan
# localises which phase broke without a full re-run.

set -euo pipefail
cd "$(dirname "$0")/.."

REMOTE_DIR="Documents/MyProducts/ClojureWasmFromScratch"
REMOTE_BRANCH="main"
if [ "${1:-}" = "--branch" ]; then
    if [ -z "${2:-}" ]; then
        echo "[run_remote_ubuntu] FAIL: --branch requires a branch name" >&2
        exit 2
    fi
    REMOTE_BRANCH="$2"
    shift 2
fi

die_step() {
    echo "[run_remote_ubuntu] FAIL: $1" >&2
    exit 1
}

# 1. Preflight — clone exists, nix reachable. `bash -lc` sources
#    /etc/profile.d/nix*.sh (Determinate installer profile) so
#    `nix` resolves from a non-interactive SSH session without
#    relying on the user's .bashrc.
echo "[run_remote_ubuntu] preflight (clone + nix reachable) ..."
ssh ubuntunote bash -lc "'
    test -d $REMOTE_DIR || exit 11
    command -v nix >/dev/null 2>&1 || exit 12
'" || {
    rc=$?
    case "$rc" in
        11) die_step "preflight — remote clone $REMOTE_DIR missing (see .dev/ubuntunote_setup.md)" ;;
        12) die_step "preflight — nix not in remote PATH (Determinate Nix install / profile missing)" ;;
        *)  die_step "preflight — ssh exit $rc (host unreachable, key auth, …)" ;;
    esac
}

# 2. Sync — fetch + reset + echo the landed SHA so logs record
#    exactly what was tested.
echo "[run_remote_ubuntu] sync ubuntunote:~/$REMOTE_DIR to origin/$REMOTE_BRANCH ..."
remote_sha="$(ssh ubuntunote bash -lc "'
    cd $REMOTE_DIR || exit 21
    git fetch origin $REMOTE_BRANCH >&2 || exit 22
    git checkout $REMOTE_BRANCH >&2 || exit 23
    git reset --hard origin/$REMOTE_BRANCH >&2 || exit 24
    git rev-parse --short HEAD
'")" || {
    rc=$?
    case "$rc" in
        21) die_step "sync — cd $REMOTE_DIR failed" ;;
        22) die_step "sync — git fetch origin failed (network / auth)" ;;
        23) die_step "sync — git checkout $REMOTE_BRANCH failed" ;;
        24) die_step "sync — git reset --hard origin/$REMOTE_BRANCH failed" ;;
        *)  die_step "sync — ssh exit $rc" ;;
    esac
}
echo "[run_remote_ubuntu] remote HEAD: $remote_sha"

# 3. Run the full gate via the project's Nix flake. cw's gate
#    entry-point is `bash test/run_all.sh` (not `zig build test`):
#    the script orchestrates unit + e2e + bench + scan layers.
echo "[run_remote_ubuntu] nix develop --command bash test/run_all.sh ..."
ssh ubuntunote bash -lc "'
    cd $REMOTE_DIR && nix develop --command bash test/run_all.sh
'" || die_step "gate — test/run_all.sh failed on ubuntunote (HEAD=$remote_sha)"

echo "[run_remote_ubuntu] OK (HEAD=$remote_sha)."
