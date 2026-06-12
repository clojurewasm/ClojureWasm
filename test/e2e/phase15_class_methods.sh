#!/usr/bin/env bash
# test/e2e/phase15_class_methods.sh — java.lang.Class instance methods on the
# `(class x)` value (D-311) + java.util.* collection-interface `instance?`.
# `(class x)` returns a `.type_descriptor`; its instance methods
# (.isArray/.getName/.getSimpleName/.isInstance) were unimplemented, and
# `(instance? java.util.Map x)` raised class_name_unknown. Surfaced by
# clojure.core.unify's `composite?` (`(-> x class .isArray)` + java.util.Map).
# Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# java.lang.Class instance methods
assert_eq 'isArray-false' "$("$BIN" -e '(.isArray (class [1 2]))' 2>&1 | tail -1)"             'false'
assert_eq 'isArray-true'  "$("$BIN" -e '(.isArray (class (int-array 3)))' 2>&1 | tail -1)"     'true'
assert_eq 'getName'       "$("$BIN" -e '(.getName (class "x"))' 2>&1 | tail -1)"               '"String"'
assert_eq 'getSimpleName' "$("$BIN" -e '(.getSimpleName (class [1]))' 2>&1 | tail -1)"         '"PersistentVector"'
assert_eq 'isInstance'    "$("$BIN" -e '(.isInstance (class "a") "b")' 2>&1 | tail -1)"        'true'

# java.util.* collection-interface instance? (clj-verified membership)
assert_eq 'util-Map-map'   "$("$BIN" -e '(instance? java.util.Map {:a 1})' 2>&1 | tail -1)"     'true'
assert_eq 'util-Map-vec'   "$("$BIN" -e '(instance? java.util.Map [1])' 2>&1 | tail -1)"        'false'
assert_eq 'util-List-vec'  "$("$BIN" -e '(instance? java.util.List [1])' 2>&1 | tail -1)"       'true'
assert_eq 'util-Set'       "$("$BIN" -e '(instance? java.util.Set #{1})' 2>&1 | tail -1)"       'true'
assert_eq 'util-Coll-map'  "$("$BIN" -e '(instance? java.util.Collection {:a 1})' 2>&1 | tail -1)" 'false'
assert_eq 'util-Coll-vec'  "$("$BIN" -e '(instance? java.util.Collection [1])' 2>&1 | tail -1)" 'true'

echo "OK — phase15_class_methods (11 cases) green"
