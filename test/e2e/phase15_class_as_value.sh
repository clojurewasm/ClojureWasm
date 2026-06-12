#!/usr/bin/env bash
# test/e2e/phase15_class_as_value.sh — host/exception class names as values
# (D-232). A bare host/exception class symbol (`Exception`, `ExceptionInfo`,
# `clojure.lang.ExceptionInfo`) now resolves to the same TypeDescriptor value
# `(class e)` returns, so `(= (class e) SomeException)` works (clj parity) —
# the analyzer class-as-value path (native classes already worked) is extended
# to the host_class exception registry via rt.exceptionDescriptor. Surfaced by
# clojure.test-clojure.fn `(fails-with-cause? clojure.lang.ExceptionInfo …)`.
# clj-grounded for FQCN / java.lang (corpus class_as_value); the simple
# clojure.lang name is a cljw leniency (clj needs the FQCN/import). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# FQCN class value equals (class e)
assert_eq 'fqcn-exinfo' \
  "$("$BIN" -e '(= (class (ex-info "x" {})) clojure.lang.ExceptionInfo)' 2>&1 | tail -1)" \
  'true'

# java.lang simple name (auto-imported in clj too)
assert_eq 'java-lang-simple' \
  "$("$BIN" -e '(= (class (Exception. "y")) Exception)' 2>&1 | tail -1)" \
  'true'

# distinct classes are not equal
assert_eq 'distinct-classes' \
  "$("$BIN" -e '(= (class (Exception. "y")) clojure.lang.ExceptionInfo)' 2>&1 | tail -1)" \
  'false'

# cljw leniency: a simple clojure.lang exception name resolves without an
# import (clj would need clojure.lang.ExceptionInfo) — consistent with cljw's
# import-free simple-name exception handling in catch / instance?.
assert_eq 'simple-clojure-lang-lenient' \
  "$("$BIN" -e '(= (class (ex-info "x" {})) ExceptionInfo)' 2>&1 | tail -1)" \
  'true'

# class? recognises a bare class symbol value
assert_eq 'class-predicate' \
  "$("$BIN" -e '(class? RuntimeException)' 2>&1 | tail -1)" \
  'true'

echo "OK — phase15_class_as_value (5 cases) green"
