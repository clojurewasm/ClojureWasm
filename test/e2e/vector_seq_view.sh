#!/usr/bin/env bash
# test/e2e/vector_seq_view.sh
#
# `(seq v)` / `(rest v)` / `(next v)` over a vector are an `.array_seq` VIEW
# (runtime/collection/array_seq.zig, O-058), not the eager PersistentList copy
# they used to build. A view holds its backing alive, so allocating hard while
# a seq is live must not disturb what reading through that seq answers.
#
# The 75 observable-surface pins (print form, seq?/sequential?/coll?, class
# name, meta, walk termination, `=`/hash with the list AND the vector, map key,
# set dedup, count/nth, the seq library, nesting, scale) moved to
# test/clj/suites/vector_seq_view_test.clj — they are expression-value
# assertions and cost one process there instead of 75.
#
# THIS case cannot move. CLJW_GC_TORTURE=1 is read at PROCESS START, and a
# suite running inside cljw cannot set it for itself. Layer 2 exists for
# exactly this: what needs the process, not what merely used one.
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# Under GC torture every allocation is a collection point, so a view whose
# backing is not properly rooted loses it mid-walk.
assert_eq 'view_survives_gc_torture' \
  "$(CLJW_GC_TORTURE=1 "$BIN" -e '(let [s (seq (vec (range 300)))] (dotimes [_ 50] (vec (range 300))) [(count s) (last s) (reduce + 0 s)])' 2>/dev/null)" \
  '[300 299 44850]'

echo "=== vector_seq_view: GC-torture rooting pin green (surface pins in test/clj/suites/vector_seq_view_test.clj) ==="
