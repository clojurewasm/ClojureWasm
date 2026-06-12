#!/usr/bin/env bash
# test/e2e/phase14_deftype_ideref.sh — clojure.lang.IDeref / IPending as direct
# deftype supertypes (the deref-able interface family). `deref`/`@` consult a
# typed_instance's IDeref/-deref; `realized?` consults IPending/-realized?.
# Found driving clojure.core.memoize (RetryingDelay impls both, memoize.clj:33).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

FIX=/tmp/phase14_ideref_$$.clj
cat > "$FIX" <<'CLJ'
(deftype Box [v]
  clojure.lang.IDeref
  (deref [_] v)
  clojure.lang.IPending
  (isRealized [_] true))
(println "deref" (deref (->Box 42)))
(println "at" @(->Box 7))
(println "realized" (realized? (->Box 1)))
CLJ
out="$("$BIN" "$FIX" 2>&1)"
rm -f "$FIX"
assert_eq 'deref'    "$(printf '%s' "$out" | grep '^deref'    | tail -1)" 'deref 42'
assert_eq 'at'       "$(printf '%s' "$out" | grep '^at'       | tail -1)" 'at 7'
assert_eq 'realized' "$(printf '%s' "$out" | grep '^realized' | tail -1)" 'realized true'

# IDeref-only deftype (no IPending) still derefs.
DO="$("$BIN" -e '(deftype D [v] clojure.lang.IDeref (deref [_] (* v 2))) (deref (->D 5))' 2>&1 | tail -1)"
assert_eq 'ideref_only' "$DO" '10'

echo "OK — phase14_deftype_ideref (4 cases) green"
