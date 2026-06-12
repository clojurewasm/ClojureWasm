#!/usr/bin/env bash
# test/e2e/phase14_auto_keyword.sh — `::name` / `::alias/name` auto-resolved
# keywords (D-195). The reader flags `::` (it is namespace-unaware); the
# analyzer resolves against the current ns (or a require alias). Surfaced by
# the multimethod/hierarchy clj-diff sweep, where `(map name (ancestors ::x))`
# diverged because `::x` was read as a keyword literally named `:x`.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_eq 'name'       "$("$BIN" -e '(name ::foo)')"            '"foo"'
assert_eq 'namespace'  "$("$BIN" -e '(namespace ::foo)')"       '"user"'
assert_eq 'print'      "$("$BIN" -e '(str ::foo)')"             '":user/foo"'
assert_eq 'eq_qual'    "$("$BIN" -e '(= ::foo :user/foo)')"     'true'
assert_eq 'eq_self'    "$("$BIN" -e '(= ::foo ::foo)')"         'true'
assert_eq 'map_key'    "$("$BIN" -e '(get {::k 42} ::k)')"      '42'
assert_eq 'keyword_q'  "$("$BIN" -e '(keyword? ::foo)')"        'true'
# auto-resolved keywords drive multimethod hierarchy (the original sweep gap)
assert_eq 'derive_isa' "$("$BIN" -e '(do (derive ::dog ::animal) (isa? ::dog ::animal))')" 'true'
assert_eq 'parents'    "$("$BIN" -e '(do (derive ::sq ::shape) (first (map name (parents ::sq))))')" '"shape"'
# ::alias/name resolves a require alias (alias must exist before the form)
got=$(printf '%s\n' '(require (quote [clojure.set :as s]))' '(prn (str ::s/foo))' | "$BIN" - | grep 'clojure.set')
assert_eq 'alias'      "$got" '":clojure.set/foo"'
echo "OK — phase14_auto_keyword smoke (10 cases) green"
