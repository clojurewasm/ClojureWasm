#!/usr/bin/env bash
# test/e2e/phase7_definterface.sh
#
# definterface (2026-06-21) — retires the last analyzer staged-unsupported wedge
# form. cljw has no JVM, so `(definterface Name sigs…)` lowers to a `defprotocol`
# (expandDefinterface → expandDefprotocol): a 0-method `(definterface Marker)`
# becomes a marker protocol (instance?/satisfies? true, deftype implements it); a
# method interface's methods reach a deftype impl via `.m` interop dispatch.
# clj-faithful membership test is `instance?` (satisfies? on a definterface throws
# an NPE in clj — cljw is more permissive). Surfaced by core.match's protocols.clj.
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# Marker interface (0 methods): instance? true on an implementing deftype, false otherwise.
assert_eq 'marker_instance'  "$("$BIN" -e '(do (definterface IMarker) (deftype T [] IMarker) (instance? IMarker (T.)))')" 'true'
assert_eq 'marker_neg'       "$("$BIN" -e '(do (definterface IMarker) (deftype T [] IMarker) (instance? IMarker 5))')" 'false'

# Method interface: the deftype impl is reachable via `.m` interop dispatch.
assert_eq 'method_getv'  "$("$BIN" -e '(do (definterface IBox (getv [])) (deftype B [x] IBox (getv [this] x)) (.getv (B. 42)))')" '42'
assert_eq 'method_arg'   "$("$BIN" -e '(do (definterface IBox (addv [n])) (deftype B [x] IBox (addv [this n] (+ x n))) (.addv (B. 42) 8))')" '50'
assert_eq 'method_inst'  "$("$BIN" -e '(do (definterface IBox (getv [])) (deftype B [x] IBox (getv [this] x)) (instance? IBox (B. 1)))')" 'true'

# A deftype implementing both a definterface and a defprotocol.
assert_eq 'mixed' "$("$BIN" -e '(do (definterface IA (av [])) (defprotocol IB (bv [this])) (deftype M [] IA (av [this] :a) IB (bv [this] :b)) [(.av (M.)) (bv (M.))])')" '[:a :b]'

echo "ALL phase7_definterface PASS"
