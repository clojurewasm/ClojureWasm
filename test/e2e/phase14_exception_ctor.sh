#!/usr/bin/env bash
# test/e2e/phase14_exception_ctor.sh
#
# D-198 / clj-parity C5: host-class Throwable-family CONSTRUCTORS —
# `(Exception. msg)` / `(RuntimeException. msg)` / `(Throwable. msg)`. cljw
# has no JVM class hierarchy (ADR-0059), so each mints an `.ex_info` tagged
# with the class name (ex_info bridge, ADR-0060); throw/catch/getMessage +
# the isSubclassOf hierarchy + instance? all work. `.getMessage`/catch were
# the earlier partial discharge; this adds the constructors.
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# Constructors + .getMessage.
assert_eq 'exc_msg'   "$("$BIN" -e '(.getMessage (Exception. "x"))')"          '"x"'
assert_eq 'rte_msg'   "$("$BIN" -e '(.getMessage (RuntimeException. "r"))')"   '"r"'
assert_eq 'thr_msg'   "$("$BIN" -e '(.getMessage (Throwable. "t"))')"          '"t"'

# throw → catch (by own class, by superclass, by Throwable).
assert_eq 'catch_self'  "$("$BIN" -e '(try (throw (Exception. "boom")) (catch Exception e (.getMessage e)))')" '"boom"'
assert_eq 'catch_super' "$("$BIN" -e '(try (throw (RuntimeException. "r")) (catch Exception e (.getMessage e)))')" '"r"'
assert_eq 'catch_thr'   "$("$BIN" -e '(try (throw (Exception. "e")) (catch Throwable e (.getMessage e)))')" '"e"'

# instance? rides the isSubclassOf hierarchy.
assert_eq 'inst_exc'  "$("$BIN" -e '(instance? Exception (Exception. "x"))')"   'true'
assert_eq 'inst_thr'  "$("$BIN" -e '(instance? Throwable (RuntimeException. "r"))')" 'true'
assert_eq 'inst_rte'  "$("$BIN" -e '(instance? RuntimeException (Exception. "x"))')" 'false'

# D-213: (class e) reports the value's SPECIFIC exception class (simple name
# per AD-003), not a generic "ex_info". ex-info → ExceptionInfo; ctor classes;
# caught catalog errors carry their Kind-derived class.
assert_eq 'cls_exinfo' "$("$BIN" -e '(str (class (ex-info "m" {})))')"          '"ExceptionInfo"'
assert_eq 'cls_exc'    "$("$BIN" -e '(str (class (Exception. "x")))')"          '"Exception"'
assert_eq 'cls_rte'    "$("$BIN" -e '(str (class (RuntimeException. "r")))')"   '"RuntimeException"'
assert_eq 'cls_div0'   "$("$BIN" -e '(try (/ 1 0) (catch Throwable e (str (class e))))')" '"ArithmeticException"'
assert_eq 'cls_nth'    "$("$BIN" -e '(try (nth [] 5) (catch Throwable e (str (class e))))')" '"IndexOutOfBoundsException"'
# Distinct exception types → distinct classes; same type → one interned class.
assert_eq 'cls_same'   "$("$BIN" -e '(= (class (ex-info "a" {})) (class (ex-info "b" {})))')" 'true'
assert_eq 'cls_diff'   "$("$BIN" -e '(= (class (Exception. "x")) (class (RuntimeException. "y")))')" 'false'

echo "ALL phase14_exception_ctor PASS"
