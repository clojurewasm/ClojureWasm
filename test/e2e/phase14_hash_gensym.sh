#!/usr/bin/env bash
# test/e2e/phase14_hash_gensym.sh — hash (expose equal.valueHash) + gensym
# (unique symbols). hash's exact value is cljw-internal (not JVM-bit-equal),
# so assert PROPERTIES: deterministic, integer, equal-keys-equal-hash.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
# hash
assert_eq 'hash_det'  "$("$BIN" -e '(= (hash :a) (hash :a))')"          'true'
assert_eq 'hash_int'  "$("$BIN" -e '(integer? (hash :a))')"            'true'
assert_eq 'hash_diff' "$("$BIN" -e '(not= (hash :a) (hash :b))')"      'true'
assert_eq 'hash_str'  "$("$BIN" -e '(= (hash "x") (hash "x"))')"       'true'
assert_eq 'hash_eqc'  "$("$BIN" -e '(= (hash 5) (hash 5))')"           'true'
# gensym
assert_eq 'gen_sym'   "$("$BIN" -e '(symbol? (gensym))')"             'true'
assert_eq 'gen_uniq'  "$("$BIN" -e '(not= (gensym) (gensym))')"       'true'
assert_eq 'gen_pfx'   "$("$BIN" -e '(subs (name (gensym "foo")) 0 3)')" '"foo"'
assert_eq 'gen_dpfx'  "$("$BIN" -e '(subs (name (gensym)) 0 3)')"     '"G__"'
echo "OK — phase14_hash_gensym smoke (9 cases) green"
