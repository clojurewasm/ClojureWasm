#!/usr/bin/env bash
# test/e2e/phase14_deftype_ireduce.sh — clojure.lang.IReduceInit deftype marker
# (D-399, the clojure.lang.* marker-family big-bang clean subset). A deftype
# declaring clojure.lang.IReduceInit with `(reduce [self f init] …)` routes to
# cljw's IReduce/-reduce, which `reduce`'s fast-path already dispatches on a
# typed_instance (D-069 — cljw collapses JVM's IReduce+IReduceInit into one
# arity-overloaded -reduce) — a REAL win. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

DT='(deftype RV [v]
  clojure.lang.IReduceInit
  (reduce [self f init] (reduce f init v)))'
run() { "$BIN" - <<EOF 2>&1 | tail -1
$DT
$1
EOF
}

assert_eq 'reduce-dispatch'  "$(run '(prn (reduce + 0 (RV. [1 2 3 4])))')"          '10'
assert_eq 'reduce-into'      "$(run '(prn (into [] (RV. [5 6 7])))')"               '[5 6 7]'

echo "OK — phase14_deftype_ireduce (2 cases) green"
