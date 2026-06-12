#!/usr/bin/env bash
# test/e2e/phase14_deftype.sh — deftype as a macro (ADR-0066, D-087). deftype
# now binds Name + the positional ->Name constructor and applies its protocol
# body (it previously dropped the body silently and never bound ->Name). It is
# NOT a map (kind-gated, unlike defrecord). clj-grounded.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# ->Name positional constructor + field access
assert_eq 'ctor_field'  "$("$BIN" -e '(do (deftype P [x y]) (.x (->P 7 9)))')"        '7'
# protocol body is applied (was silently dropped before)
assert_eq 'proto_body'  "$("$BIN" -e '(do (defprotocol IFoo (foo [t])) (deftype T [v] IFoo (foo [_] (.v _))) (foo (->T 42)))')" '42'
# instance? against the deftype Name
assert_eq 'instance'    "$("$BIN" -e '(do (defprotocol IFoo (foo [t])) (deftype T [v] IFoo (foo [_] 1)) (instance? T (->T 1)))')" 'true'
# deftype is NOT a map — keyword lookup of a field returns nil (kind-gated)
assert_eq 'not_a_map'   "$("$BIN" -e '(do (deftype T [v]) (:v (->T 5)))')"             'nil'
# (Name. args) interop constructor still works alongside ->Name
assert_eq 'dot_ctor'    "$("$BIN" -e '(do (deftype P [x y]) (.y (P. 3 4)))')"          '4'
# multi-field, multi-method protocol body
assert_eq 'multi'       "$("$BIN" -e '(do (defprotocol IPt (sx [t]) (sy [t])) (deftype Pt [a b] IPt (sx [_] (.a _)) (sy [_] (.b _))) [(sx (->Pt 1 2)) (sy (->Pt 1 2))])')" '[1 2]'
# both backends agree (parity; also covers the former op_deftype-vs-primitive registration)
assert_eq 'compare'     "$("$BIN" --compare -e '(do (deftype P [x] ) (.x (->P 11)))' | tail -1)" 'OK 11'

echo "OK — phase14_deftype (7 cases) green"
