#!/usr/bin/env bash
# test/e2e/phase14_catch_fqcn_exceptions.sh — catch by FULLY-QUALIFIED exception
# class name (D-398). clj accepts both `(catch AssertionError e …)` and the FQCN
# `(catch java.lang.AssertionError e …)`. cljw's FQCN→simple map (host_class.zig
# FQCN_MAP) was missing 3 names that ARE in the hierarchy ENTRIES table:
# java.lang.AssertionError (assert throws it), java.lang.ReflectiveOperationException,
# java.lang.ClassNotFoundException — so the FQCN form raised "not a known exception
# type". Surfaced by clojure.tools.trace (extend-type java.lang.AssertionError). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

assert_eq 'fqcn-assertion-error' \
  "$("$BIN" -e '(try (assert false) (catch java.lang.AssertionError e :caught))' 2>&1 | tail -1)" ':caught'
assert_eq 'simple-assertion-error' \
  "$("$BIN" -e '(try (assert false) (catch AssertionError e :caught))' 2>&1 | tail -1)" ':caught'
# FQCN AssertionError also catches via its Error/Throwable supertype (FQCN)
assert_eq 'fqcn-error-super' \
  "$("$BIN" -e '(try (assert false) (catch java.lang.Error e :caught))' 2>&1 | tail -1)" ':caught'
# ClassNotFoundException FQCN (clojure.math.numeric-tower catches it for optional classes)
assert_eq 'fqcn-cnfe' \
  "$("$BIN" -e '(try (throw (ex-info "x" {})) (catch java.lang.ClassNotFoundException e :cnfe) (catch Throwable e :other))' 2>&1 | tail -1)" ':other'

echo "OK — phase14_catch_fqcn_exceptions (4 cases) green"
