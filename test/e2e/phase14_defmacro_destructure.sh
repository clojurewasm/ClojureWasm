#!/usr/bin/env bash
# test/e2e/phase14_defmacro_destructure.sh
#
# D-390 (P4 finding, grammarly/perseverance load): a `defmacro` whose parameter
# is a destructuring pattern (`[{:keys [a]} & body]`) failed at ANALYZE time with
# "fn* parameter must be a symbol". clj's defmacro expands to a `defn` (which
# destructures); cljw's defmacro lowering built a `fn*` DIRECTLY, bypassing the
# fn-macro destructuring layer, so the raw `{:keys [a]}` map reached fn*, which
# requires plain symbols. Fix: lower defmacro through `fn` (the destructuring
# macro), not `fn*`. defn/fn destructuring already worked — only defmacro didn't.
#
# NOTE: a macro must be DEFINED in a separate top-level form before it is USED
# (cljw analyses a whole `(do …)` before evaluating it, so a same-`do`
# define-then-call sees the macro var's root binding unset). The fixture uses
# separate top-level forms; this is a cljw evaluation-model property, not part of
# this bug.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

got="$("$BIN" - <<'CLJ' 2>&1
(defmacro m1 [{:keys [a]}] a)                      ;; map-destructured param
(defmacro m2 [{:keys [a]} & body] (cons '+ (cons a body)))  ;; destr + rest
(defmacro m3 [[x y]] (list '+ x y))                ;; vector-destructured param
(defmacro m4 [x] x)                                ;; plain param (regression)
(defmacro m5 ([x] x) ([{:keys [a]} _] a))          ;; multi-arity, destr arity
(println (m1 {:a 9}))
(println (m2 {:a 1} 2 3))
(println (m3 [4 5]))
(println (m4 7))
(println (m5 1))
(println (m5 {:a 2} :ignored))
CLJ
)"
want=$'9\n6\n9\n7\n1\n2'

[[ "$got" == "$want" ]] || fail "defmacro_destructure: got '$got', want '$want'"
echo "PASS defmacro_destructure (6 assertions)"
echo "OK — phase14_defmacro_destructure green"
