#!/usr/bin/env bash
# test/e2e/phase15_defmethod_destructure.sh — destructuring defmethod params
# (D-232). defmethod lowered its body to `fn*` (raw, symbol-only params), so a
# destructuring method param (`(defmethod m :k [a [b c]] …)` /
# `(defmethod m :k [{:keys [x]}] …)`) raised "fn* parameter must be a symbol".
# Fixed: defmethod now emits `fn` (the destructure-lowering macro). Surfaced by
# clojure.test-helper's assert-expr methods. clj-grounded. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# associative destructure in a method param
assert_eq 'assoc-param' \
  "$("$BIN" -e '(defmulti foo (fn [x] (:t x))) (defmethod foo :pair [{:keys [a b]}] (+ a b)) (foo {:t :pair :a 3 :b 4})' 2>&1 | tail -1)" \
  '7'

# nested sequential destructure with _, & rest, :as (the test-helper shape)
assert_eq 'nested-seq-param' \
  "$("$BIN" -e '(defmulti bar (fn [m form] m)) (defmethod bar :x [msg [_ a b & rest :as form]] [msg a b rest form]) (bar :x [:tag 1 2 3 4])' 2>&1 | tail -1)" \
  '[:x 1 2 (3 4) [:tag 1 2 3 4]]'

# a plain symbol-param method still dispatches (no regression)
assert_eq 'symbol-param-regress' \
  "$("$BIN" -e '(defmulti baz class) (defmethod baz Long [n] (* n 2)) (baz 21)' 2>&1 | tail -1)" \
  '42'

echo "OK — phase15_defmethod_destructure (3 cases) green"
