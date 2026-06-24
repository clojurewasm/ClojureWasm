#!/usr/bin/env bash
# test/e2e/phase7_extend_host_type.sh
#
# D-478: extend-protocol/extend-type TO a concrete host type whose cljw value
# has a native tag — clojure.lang.Namespace (.ns), clojure.lang.IRef (atom/
# agent/ref/var), java.lang.Throwable (.ex_info), java.lang.Class
# (.type_descriptor). The impl distributes over the tag via rt/__native-type
# (the same mechanism as IPersistentVector/ISeq/Named), so a namespace / ref /
# exception / class VALUE dispatches the extended method. Surfaced by clojure.datafy
# (Datafiable over IRef/Namespace/Throwable/Class) — datafy's own bundling is
# deferred on a GC-deinit ordering bug (D-481); this generic capability is the win.
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

P='(defprotocol D (descr [x]))
   (extend-protocol D
     clojure.lang.Namespace (descr [n] [:ns (ns-name n)])
     clojure.lang.IRef (descr [r] [:ref (deref r)])
     java.lang.Throwable (descr [t] [:err (ex-message t)]))'

assert_eq 'ns'    "$("$BIN" -e "(do $P (descr (create-ns (quote my.ns))))")" '[:ns my.ns]'
assert_eq 'atom'  "$("$BIN" -e "(do $P (descr (atom 7)))")"                  '[:ref 7]'
assert_eq 'ref'   "$("$BIN" -e "(do $P (descr (ref 9)))")"                   '[:ref 9]'
assert_eq 'throw' "$("$BIN" -e "(do $P (descr (ex-info \"boom\" {})))")"     '[:err "boom"]'

# A non-extended value still misses (no Object default here) — dispatch is by tag.
assert_eq 'miss'  "$("$BIN" -e "(do $P (try (descr 5) (catch Throwable e :no-impl)))")" ':no-impl'

# clojure.datafy (the bundled consumer, re-landed after D-481): Object default + host-type arms.
assert_eq 'datafy_scalar' "$("$BIN" -e '(do (require (quote [clojure.datafy])) (clojure.datafy/datafy 5))')" '5'
assert_eq 'datafy_atom'   "$("$BIN" -e '(do (require (quote [clojure.datafy])) (clojure.datafy/datafy (atom 42)))')" '[42]'
assert_eq 'datafy_ns'     "$("$BIN" -e '(do (require (quote [clojure.datafy])) (:name (clojure.datafy/datafy (create-ns (quote zz.top)))))')" 'zz.top'

echo "ALL phase7_extend_host_type PASS"
