#!/usr/bin/env bash
# test/e2e/phase16_bfs_queue_gc.sh — D-556-class BFS queue-corruption pin
# (user report 2026-07-07, vm backend).
#
# A 2-list FIFO BFS queue ([state path] pairs pushed via `into` from a
# `for`+:let+:when lazy seq, requeued with `reverse`, next to a growing
# `visited` set) decayed mid-loop: `(first front)` returned a raw Long
# instead of the [state path] vector ("CORRUPT head= 3 type= Long", or
# downstream `-nth on Long` / `+: got nil`). Root cause was the D-556
# unrooted-analysis-constants class: the vm's not-yet-executed fn literal
# pool was collectable, so a mid-loop collect recycled queue elements.
# Fixed by the persist-analysis-roots arc (2026-07-07); this pins the
# whole-program shape on the shipped binary, at the default GC threshold
# AND at CLJW_GC_THRESHOLD_MB=1 (frequent collects — the aggressive mode
# the original report reproduced under).
#
# `for` cannot live in the diff oracle (bootstrap-closure harness blind
# spot, D-234 note in src/lang/diff_test.zig), so this e2e + the
# bfs_queue clj corpus line are the standing coverage.
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

FIXTURE="test/e2e/fixtures/bfs_queue_gc.clj"
WANT='WON path= [3 3 3 3 3 3 3 3 3 3]'

# (1) default GC threshold — the shape the user's original report hit.
assert_eq 'bfs_queue_default' "$(timeout 120 "$BIN" "$FIXTURE")" "$WANT"

# (2) 1 MB threshold — frequent collects; a resurfacing rooting hole in the
# queue / visited-set / fn-literal-pool path corrupts deterministically here.
assert_eq 'bfs_queue_thr1mb' "$(CLJW_GC_THRESHOLD_MB=1 timeout 120 "$BIN" "$FIXTURE")" "$WANT"

echo "ALL phase16_bfs_queue_gc PASS"
