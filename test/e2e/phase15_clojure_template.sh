#!/usr/bin/env bash
# test/e2e/phase15_clojure_template.sh — the bundled clojure.template namespace
# (apply-template / do-template, Stuart Sierra). A small standard ns over
# clojure.walk that cljw did not bundle; surfaced as a require gap by honeysql's
# honey.sql. Now embedded (bootstrap.zig FILES + lookupEmbeddedFile). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# apply-template substitutes argv symbols with values inside a quoted expr
assert_eq 'apply-template' \
  "$("$BIN" -e "(require '[clojure.template :as t]) (t/apply-template '[x] '(+ x x) '[5])" 2>&1 | tail -1)" \
  '(+ 5 5)'

# do-template expands to (do expr…) over partitioned values; the do yields last
assert_eq 'do-template' \
  "$("$BIN" -e "(require 'clojure.template) (clojure.template/do-template [x y] (+ x y) 1 2 10 20)" 2>&1 | tail -1)" \
  '30'

echo "OK — phase15_clojure_template (2 cases) green"
