#!/usr/bin/env bash
# test/e2e/phase14_macro_shadow_builtin.sh — a user/lib macro that SHADOWS a
# builtin-macro name runs its OWN body, not the builtin (D-476). Two coupled
# fixes: (1) expandIfMacro consults the Zig builtin table only for a nil-root
# MARKER Var (a user defmacro has a callable root), so `m/or` runs mylib/or;
# (2) caseTest emits the QUALIFIED `rt/or`, so case-lowering stays hygienic in a
# namespace that shadows `or` (clojure.spec.alpha excludes+redefines or/and).
# Surfaced by the clojure.spec.alpha port (s/or, strict s/and). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

run() { "$BIN" - <<EOF 2>&1 | tail -1
$1
EOF
}

# (1) a lib macro shadowing `or` runs its own body via alias
assert_eq 'lib-macro-shadow-or' \
  "$(run '(ns mylib (:refer-clojure :exclude [or])) (defmacro or [& xs] (list (quote quote) (cons :MY xs))) (ns user (:require [mylib :as m])) (prn (m/or 1 2))')" \
  '(:MY 1 2)'

# (2) case-lowering stays hygienic in a namespace that redefines `or` — the
# multi-constant clause must still test correctly (it emits rt/or, not the local or)
assert_eq 'case-hygiene-in-or-shadow-ns' \
  "$(run '(ns sh (:refer-clojure :exclude [or])) (defmacro or [& _] :SPEC-OR) (prn (case 2 (1 2 3) :lo 4 :hi :def))')" \
  ':lo'

# builtin or/and/case regressions (unqualified, in a normal ns)
assert_eq 'builtin-or' "$(run '(prn (or false 5))')" '5'
assert_eq 'builtin-and' "$(run '(prn (and 1 2 3))')" '3'
assert_eq 'builtin-case-group' "$(run '(prn (case 3 (1 2) :a (3 4) :b :d))')" ':b'
