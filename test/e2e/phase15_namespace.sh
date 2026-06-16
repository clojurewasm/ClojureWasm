#!/usr/bin/env bash
# test/e2e/phase15_namespace.sh — Namespace-as-value + *ns* + ns-reflection
# (D-230, ADR-0083). *ns* is a first-class .ns Value; ns-name/the-ns/find-ns/
# all-ns/create-ns/ns-interns/ns-publics/ns-map/ns-resolve read the Env ns graph.
# Locks AD-010 (#object[Namespace "name"] print) + AD-011 (clojure.core interns
# omit rt-referred primitives). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# *ns* + str/pr (AD-010). `-e` pr-prints the result value, so a bare `*ns*`
# renders via printNamespace; a raw string needs (println …).
assert_eq 'ns-name'   "$("$BIN" -e '(ns-name *ns*)' 2>&1 | tail -1)" 'user'
assert_eq 'str-ns'    "$("$BIN" -e '(str *ns*)' 2>&1 | tail -1)" '"user"'
assert_eq 'pr-ns'     "$("$BIN" -e '*ns*' 2>&1 | tail -1)" '#object[Namespace "user"]'
# identity: same name -> same value
assert_eq 'identity'  "$("$BIN" -e '(= *ns* (the-ns (quote user)))' 2>&1 | tail -1)" 'true'
# find-ns / create-ns / the-ns
assert_eq 'find-miss' "$("$BIN" -e '(find-ns (quote nope))' 2>&1 | tail -1)" 'nil'
assert_eq 'create'    "$("$BIN" -e '(ns-name (create-ns (quote my.app)))' 2>&1 | tail -1)" 'my.app'
# in-ns switches *ns* (the .ns Value tracks current_ns via setCurrentNs).
# Must use FULLY-QUALIFIED clojure.core/*ns*: in-ns creates a BARE ns with no
# clojure.core refer, so bare `*ns*` is unresolvable there — clj throws too
# (verified), and cljw matches since D-374 unrolled top-level `do` (each child
# analyzed in the post-in-ns ns). The fully-qualified var resolves regardless.
assert_eq 'in-ns'     "$("$BIN" -e '(do (in-ns (quote foo.bar)) clojure.core/*ns*)' 2>&1 | tail -1)" '#object[Namespace "foo.bar"]'
# ns-resolve -> var-value
assert_eq 'resolve'   "$("$BIN" -e '(ns-resolve (quote clojure.core) (quote map))' 2>&1 | tail -1)" "#'clojure.core/map"
# ns-interns sees a fresh def (user-ns exactness)
assert_eq 'interns'   "$("$BIN" -e '(do (def zzz 7) (contains? (ns-interns *ns*) (quote zzz)))' 2>&1 | tail -1)" 'true'
# AD-011: clojure.core ns-publics omits rt-referred primitive `reduce`, but ns-map includes it
assert_eq 'ad011-pub' "$("$BIN" -e '(contains? (ns-publics (the-ns (quote clojure.core))) (quote reduce))' 2>&1 | tail -1)" 'false'
assert_eq 'ad011-map' "$("$BIN" -e '(contains? (ns-map (the-ns (quote clojure.core))) (quote reduce))' 2>&1 | tail -1)" 'true'

# intern: programmatic Var creation (clojure.core/intern). 3-arity sets the root;
# 2-arity leaves an existing Var untouched / creates an unbound one. Returns the Var.
assert_eq 'intern-3ary'  "$("$BIN" -e '(deref (intern (create-ns (quote foo.iv)) (quote x) 42))' 2>&1 | tail -1)" '42'
assert_eq 'intern-ret'   "$("$BIN" -e '(intern (create-ns (quote foo.iv5)) (quote q) 1)' 2>&1 | tail -1)" "#'foo.iv5/q"
assert_eq 'intern-2ary-keeps' "$("$BIN" -e '(do (intern (create-ns (quote foo.iv6)) (quote k) 5) (deref (intern (the-ns (quote foo.iv6)) (quote k))))' 2>&1 | tail -1)" '5'
assert_eq 'intern-2ary-var'   "$("$BIN" -e '(do (intern (create-ns (quote foo.iv4)) (quote w)) (find-var (quote foo.iv4/w)))' 2>&1 | tail -1)" "#'foo.iv4/w"

echo "OK — phase15_namespace (15 cases) green"
