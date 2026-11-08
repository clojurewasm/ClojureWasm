#!/usr/bin/env bash
# scripts/lib_build_lock.sh
#
# SSOT for "one `zig build` at a time on this machine". Two concurrent builds
# share one `.zig-cache` and drove load average to ~34 on 2026-08-12.
#
#     source "$(dirname "$0")/lib_build_lock.sh"
#     with_build_lock zig build -Dwasm -Doptimize=ReleaseSafe
#
#   build_lock_acquire [TIMEOUT_SECS]  — block until the lock is ours (default
#                                        1800). Re-entrant: a nested call
#                                        inside a holder is a no-op.
#   build_lock_release                 — release if this shell took it.
#   with_build_lock CMD...             — acquire, run CMD, release (even on
#                                        failure); returns CMD's status.
#
# The library installs NO signal trap: a `trap ... EXIT` here would replace the
# sourcing script's own cleanup trap. Prefer `with_build_lock`; a caller using
# the bare acquire/release pair owns its own trap.
#
# Re-entrancy travels through the exported `CLJW_BUILD_LOCK_HELD`, so a child
# process started by a holder does not deadlock against its own parent.
[[ -n "${LIB_BUILD_LOCK_LOADED:-}" ]] && return 0
LIB_BUILD_LOCK_LOADED=1

BUILD_LOCK_DIR="${BUILD_LOCK_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.dev/.build.lock}"
_build_lock_mine=0

build_lock_acquire() {
  [ "${CLJW_BUILD_LOCK_HELD:-0}" = 1 ] && return 0
  local limit="${1:-1800}" waited=0
  mkdir -p "$(dirname "$BUILD_LOCK_DIR")"
  while ! mkdir "$BUILD_LOCK_DIR" 2>/dev/null; do
    if [ "$waited" = 0 ]; then
      echo "build lock: another build holds $BUILD_LOCK_DIR — waiting" >&2
    fi
    waited=$((waited + 5))
    if [ "$waited" -gt "$limit" ]; then
      echo "build lock: timed out after ${limit}s waiting for $BUILD_LOCK_DIR (stale? rmdir it)" >&2
      return 1
    fi
    sleep 5
  done
  _build_lock_mine=1
  export CLJW_BUILD_LOCK_HELD=1
}

build_lock_release() {
  [ "$_build_lock_mine" = 1 ] || return 0
  rmdir "$BUILD_LOCK_DIR" 2>/dev/null || true
  _build_lock_mine=0
  export CLJW_BUILD_LOCK_HELD=0
}

with_build_lock() {
  build_lock_acquire || return 1
  local rc=0
  "$@" || rc=$?
  build_lock_release
  return "$rc"
}
