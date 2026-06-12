#!/usr/bin/env bash
# test/e2e/phase14_deftype_indexed.sh — clojure.lang.Indexed deftype marker
# (D-397, D-271/D-280 family). A deftype declaring clojure.lang.Indexed with
# `(nth [self i])` routes `nth` to Indexed/-nth, which `nthFn`'s else-arm already
# dispatches on a typed_instance (D-089 row 8.6) — a REAL win. (The 3-arg
# `(nth coll i not-found)` on a typed_instance stays the nthFn dispatch follow-up:
# the else-arm dispatches a 2-arg -nth only.) Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

DT='(deftype IV [v]
  clojure.lang.Indexed
  (nth [self i] (nth v i)))'
run() { "$BIN" - <<EOF 2>&1 | tail -1
$DT
$1
EOF
}

assert_eq 'nth-dispatch'   "$(run '(prn (nth (IV. [10 20 30]) 1))')"   '20'
assert_eq 'nth-dispatch-0' "$(run '(prn (nth (IV. [7 8 9]) 0))')"      '7'

echo "OK — phase14_deftype_indexed (2 cases) green"
