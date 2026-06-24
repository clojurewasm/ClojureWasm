#!/usr/bin/env bash
# test/e2e/phase14_extend_abstract_base.sh — D-534: extend-protocol/extend-type
# onto the abstract collection bases `clojure.lang.APersistentSet` and
# `clojure.lang.IPersistentList` distributes the impl over the native set / list
# tags (the same native-tag distribution IPersistentVector → vector already had).
# algo.monads' writer-monad protocol extends onto these; before the fix a cljw
# set/list value couldn't dispatch a protocol extended via the abstract base, and
# the target itself raised "Unable to resolve symbol: clojure.lang.APersistentSet".
# Values oracle-verified vs clj (set print order is AD-001, so values are `=`).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# extend-protocol onto APersistentSet + IPersistentList + IPersistentVector — each
# native collection value dispatches the user protocol via native-tag distribution.
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol Wadd (wadd [c v]))
(extend-protocol Wadd
  clojure.lang.IPersistentVector (wadd [c v] (conj c v))
  clojure.lang.IPersistentList  (wadd [c v] (conj c v))
  clojure.lang.APersistentSet   (wadd [c v] (conj c v)))
(print [(wadd [1 2] 3) (wadd (list 1 2) 3) (contains? (wadd #{1 2} 3) 3)])
EOF
)
assert_eq "extend_abstract_bases" "$got" "[[1 2 3] (3 1 2) true]"

echo "ALL phase14_extend_abstract_base PASS"
